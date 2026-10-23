import CryptoKit
import Foundation

enum CaptureFormat {
  static let name = "aproxx.iphone-scan"
  static let version = 2
  static let minimumTrainFrames = 20
  static let minimumValidationFrames = 10
  static let minimumCameraSpanMetres = 0.20

  static func error(_ message: String) -> NSError {
    NSError(domain: "RoomPlanDeviceTest.Package", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message])
  }

  /// SIMD is column-major; files explicitly contain rows acting on column vectors.
  static func rows(_ columns: [[Double]]) -> [[Double]] {
    guard let count = columns.first?.count else { return [] }
    return (0..<count).map { row in columns.map { $0[row] } }
  }

  static func packRows(_ padded: Data, rowBytes: Int, stride: Int, height: Int) throws -> Data {
    guard rowBytes > 0, stride >= rowBytes, height > 0, stride <= Int.max / height,
          padded.count >= stride * height else { throw error("Invalid pixel-buffer row layout.") }
    var result = Data(capacity: rowBytes * height)
    for row in 0..<height { result.append(padded[(row * stride)..<(row * stride + rowBytes)]) }
    return result
  }

  static func readJSON(_ url: URL) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
      throw error("Expected a JSON object in \(url.lastPathComponent).")
    }
    return object
  }

  static func writeJSON(_ value: [String: Any], to url: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
      .write(to: url, options: [.atomic, .completeFileProtection])
  }

  static func fingerprint(_ url: URL) throws -> [String: Any] {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    var size = 0
    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
      hash.update(data: data)
      size += data.count
    }
    return ["bytes": size, "sha256": hash.finalize().map { String(format: "%02x", $0) }.joined()]
  }

  static func relativePayloadPath(_ file: URL, under root: URL) throws -> String {
    // iOS can expose /var and /private/var aliases for the same sandbox. Never
    // subtract character counts from paths supplied by different URL APIs.
    let base = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
    let parts = file.resolvingSymlinksInPath().standardizedFileURL.pathComponents
    guard parts.count > base.count, Array(parts.prefix(base.count)) == base else {
      throw error("A payload file resolved outside its scan directory.")
    }
    let relative = parts.dropFirst(base.count)
    guard relative.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
      throw error("Invalid scan payload path.")
    }
    return relative.joined(separator: "/")
  }

  static func fileError(_ underlying: Error, stage: String, path: String) -> NSError {
    let native = underlying as NSError
    return NSError(domain: "RoomPlanDeviceTest.Package", code: 2, userInfo: [
      NSLocalizedDescriptionKey: "\(stage) failed for \(path): \(native.localizedDescription)",
      NSUnderlyingErrorKey: native, "stage": stage, "relativePath": path
    ])
  }

  static func payloadFiles(_ root: URL) throws -> [(String, URL)] {
    let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
    var enumerationError: Error?
    guard let iterator = FileManager.default.enumerator(at: canonicalRoot,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles],
      errorHandler: { _, error in enumerationError = error; return false }) else {
      throw error("Could not enumerate the scan package.")
    }
    var files: [(String, URL)] = []
    for case let url as URL in iterator {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isSymbolicLink != true else { throw error("Scan packages must not contain symbolic links.") }
      guard values.isRegularFile == true else { continue }
      let path = try relativePayloadPath(url, under: canonicalRoot)
      if path.hasSuffix(".zip") || path.hasSuffix(".tmp") { continue }
      files.append((path, url.resolvingSymlinksInPath().standardizedFileURL))
    }
    if let failure = enumerationError { throw fileError(failure, stage: "enumeration", path: ".") }
    return files.sorted { $0.0 < $1.0 }
  }

  static func validateFrameFiles(root: URL, report: [String: Any], files: [(String, URL)]) throws {
    let inventory = Dictionary(uniqueKeysWithValues: files)
    let continuous = report["capture_mode"] as? String == "continuous_guided"
    let data = try Data(contentsOf: root.appendingPathComponent("frames.jsonl"))
    var assets = Set<String>()
    var train = 0, validation = 0
    for line in data.split(separator: 10) where !line.isEmpty {
      guard let frame = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
            let id = frame["frame_id"] as? String,
            id.range(of: "^frame-[0-9]{6}$", options: .regularExpression) != nil,
            let role = frame["role"] as? String, ["train", "validation", "capture"].contains(role),
            let rgb = frame["rgb_path"] as? String,
            let depth = frame["depth"] as? [String: Any], let depthPath = depth["path"] as? String,
            let confidence = frame["confidence"] as? [String: Any], let confidencePath = confidence["path"] as? String,
            let width = depth["width"] as? Int, let height = depth["height"] as? Int,
            width > 0, height > 0, width <= Int.max / height / 4 else {
        throw error("The saved frame index is incomplete or malformed.")
      }
      let expected = ["rgb/\(id).jpg", "depth/\(id).f32", "confidence/\(id).u8"]
      guard [rgb, depthPath, confidencePath] == expected else { throw error("Unexpected asset paths in \(id).") }
      for (index, path) in expected.enumerated() {
        guard assets.insert(path).inserted else { throw error("Duplicate frame asset: \(path)") }
        guard let source = inventory[path] else {
          throw fileError(error("The recorded asset is missing from the capture."), stage: "frame validation", path: path)
        }
        do {
          let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
          let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
          let expectedSize = index == 1 ? width * height * 4 : width * height
          let sizeIsValid = index == 0 ? size > 0 : size == expectedSize
          guard sizeIsValid else {
            let description = index == 0 ? "nonempty JPEG" : "\(expectedSize) bytes"
            throw error("Expected \(description), found \(size) bytes.")
          }
        } catch { throw fileError(error, stage: "frame validation", path: path) }
      }
      guard (continuous ? role == "capture" : role != "capture") else { throw error("Frame role does not match capture mode.") }
      if role != "validation" { train += 1 } else { validation += 1 }
    }
    guard let expectedTrain = report["train_frames"] as? Int,
          let expectedValidation = report["validation_frames"] as? Int,
          let expectedTotal = report["saved_frames"] as? Int,
          train == expectedTrain, validation == expectedValidation, train + validation == expectedTotal else {
      throw error("Recorded frame counts do not match the saved frame index.")
    }
  }

  static func validateCaptureReport(_ report: [String: Any], requireGuidance: Bool = true) throws {
    if report["capture_mode"] as? String == "continuous_guided" {
      guard let total = report["capture_frames"] as? Int, total >= CaptureGuidance.minimumFrames,
            report["train_frames"] as? Int == total, report["saved_frames"] as? Int == total,
            report["validation_frames"] as? Int == 0,
            let span = report["training_camera_span_metres"] as? Double, span.isFinite, span >= minimumCameraSpanMetres else {
        throw error("Capture at least 30 usable views and move between positions before saving.")
      }
      if requireGuidance {
        guard let guidance = report["guidance"] as? [String: Any],
              guidance["algorithm"] as? String == "observed_surface_depth_agreement_v1",
              guidance["coverage_passed"] is Bool, guidance["saved_frames"] as? Int == total,
              let measured = guidance["camera_span_metres"] as? Double,
              measured.isFinite, abs(measured - span) < 0.0001 else {
          throw error("The saved coverage assessment is missing or does not match the recorded frames.")
        }
      }
      return
    }
    guard let train = report["train_frames"] as? Int, train >= minimumTrainFrames,
          let validation = report["validation_frames"] as? Int, validation >= minimumValidationFrames else {
      throw error("Capture at least \(minimumTrainFrames) training frames and \(minimumValidationFrames) check-pass frames before finishing.")
    }
    guard let span = report["training_camera_span_metres"] as? Double,
          span.isFinite, span >= minimumCameraSpanMetres else {
      throw error("Walk around the room: the training camera must move at least 20 cm. Rotating in one spot is insufficient.")
    }
  }

  /// Metadata normalization adapted from the supplied 0.2.2 patch; room.json stays unchanged.
  static func normalisedNodeMap(_ data: Data) throws -> Data {
    let object: Any
    if let json = try? JSONSerialization.jsonObject(with: data) { object = json }
    else {
      do { object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) }
      catch { throw self.error("RoomPlan node metadata is neither JSON nor a property list.") }
    }
    guard let mapping = object as? [String: Any], mapping.values.allSatisfy({ $0 is String }) else {
      throw error("RoomPlan node metadata must map node names to identifier strings.")
    }
    return try JSONSerialization.data(withJSONObject: mapping, options: [.prettyPrinted, .sortedKeys])
  }

  /// Called only after capture has drained and RoomPlan files have been written.
  static func finalise(root: URL, scanID: String, device: [String: Any],
                       counts: [String: Int], report: [String: Any]) throws -> URL {
    try validateCaptureReport(report)
    let continuous = report["capture_mode"] as? String == "continuous_guided"
    let surfaceCoveragePassed = (report["guidance"] as? [String: Any])?["coverage_passed"] as? Bool == true
    let qualityStatus = continuous ?
      (surfaceCoveragePassed ? "estimated_surface_coverage_passed_reconstruction_unverified" : "needs_more_views_reconstruction_unverified") :
      "capture_sanity_passed_alignment_and_reconstruction_require_device_acceptance"
    let diagnosticsURL = root.appendingPathComponent("diagnostics.json")
    var diagnostics = try readJSON(diagnosticsURL)
    diagnostics["state"] = "packaging"
    diagnostics.removeValue(forKey: "error")
    diagnostics.removeValue(forKey: "completedAt")
    diagnostics["counts"] = counts
    diagnostics["capture"] = report
    try writeJSON(diagnostics, to: diagnosticsURL)
    let originalRoom = try Data(contentsOf: root.appendingPathComponent("room.json"))
    try RoomJSONValidator.validate(originalRoom, expectedCounts: counts)
    // Normalize before hashing, for new captures and retries of retained incomplete captures.
    let nodeURL = root.appendingPathComponent("roomplan/node-map.json")
    let originalNodes = try Data(contentsOf: nodeURL)
    let jsonNodes = try normalisedNodeMap(originalNodes)
    if originalNodes != jsonNodes { try jsonNodes.write(to: nodeURL, options: [.atomic, .completeFileProtection]) }
    try validateFrameFiles(root: root, report: report, files: payloadFiles(root))

    let manifest: [String: Any] = [
      "format": name, "schema_version": continuous ? version : 1, "scan_id": scanID, "room_id": scanID,
      "created_at": diagnostics["createdAt"] ?? ScanStore.timestamp(), "completed_at": ScanStore.timestamp(),
      "device": device, "capture": report,
      "coordinate_system": ["coordinate_space_id": scanID, "units": "metres", "world": "arkit_right_handed_y_up",
        "camera": "arkit_right_up_back", "matrix_layout": "rows_acting_on_column_vectors",
        "image_axes": "right_down", "image_orientation": "native_sensor_unrotated_unmirrored",
        "cv_camera_basis": [[1,0,0,0],[0,-1,0,0],[0,0,-1,0],[0,0,0,1]],
        "world_alignment": "gravity", "timestamp_origin": "first_observed_arframe_relative_seconds"],
      "files": ["frames": "frames.jsonl", "events": "events.jsonl", "room": "room.json",
        "usdz": "roomplan/room.usdz", "node_map": "roomplan/node-map.json", "live_room": "roomplan/live-room.json", "checksums": "checksums.json"],
      "roomplan_alignment": "compare_live_and_processed_geometry_then_verify_against_sensor_cloud_no_assumed_identity",
      "validation_protocol": continuous ? "continuous_capture_no_user_selected_holdout" : "withheld_rgb_depth_shared_arkit_and_roomplan_mapping",
      "privacy": ["contains_raw_interior_photos": true, "automatically_redacted": false,
                  "automatic_upload": false, "excluded_from_device_backup": true],
      "quality_status": qualityStatus
    ]
    try writeJSON(manifest, to: root.appendingPathComponent("manifest.json"))
    // Diagnostics inside the ZIP describe the data commit. Sharing is enabled only after ZIP succeeds.
    diagnostics["state"] = "completed"
    diagnostics["completedAt"] = manifest["completed_at"]
    diagnostics["updatedAt"] = manifest["completed_at"]
    var events = diagnostics["events"] as? [[String: Any]] ?? []
    events.append(["timestamp": ScanStore.timestamp(), "name": "room_written_and_read_back",
      "details": ["byteMatch": true, "bytes": originalRoom.count,
                  "validation": "full_capture_package_with_sha256"]])
    diagnostics["events"] = events
    try writeJSON(diagnostics, to: diagnosticsURL)
    let eventData = try events.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) + Data([10]) }
      .reduce(into: Data()) { $0.append($1) }
    try eventData.write(to: root.appendingPathComponent("events.jsonl"), options: [.atomic, .completeFileProtection])

    var hashes: [String: Any] = [:]
    // Keep each actual enumerated URL through read-back; do not reconstruct it
    // by appending a sliced path to a potentially different sandbox URL spelling.
    let sources = try payloadFiles(root).filter { $0.0 != "checksums.json" }
    for (path, url) in sources {
      do { hashes[path] = try fingerprint(url) }
      catch { throw fileError(error, stage: "checksum", path: path) }
    }
    try writeJSON(["algorithm": "sha256", "files": hashes], to: root.appendingPathComponent("checksums.json"))
    for (path, source) in sources {
      let expected = hashes[path] as! [String: Any]
      let actual: [String: Any]
      do { actual = try fingerprint(source) }
      catch { throw fileError(error, stage: "checksum read-back", path: path) }
      guard actual["sha256"] as? String == expected["sha256"] as? String else {
        throw error("Checksum read-back failed for \(path).")
      }
    }
    let archive = root.appendingPathComponent("scan-\(scanID).zip")
    try ScanArchive.write(root: root, to: archive)
    return archive
  }
}

/// Small streaming ZIP writer. Stored entries preserve JPEG/data bytes; no third-party SDK is bundled.
enum ScanArchive {
  private static let crcTable: [UInt32] = (0..<256).map { value in
    var crc = UInt32(value)
    for _ in 0..<8 { crc = (crc & 1) == 1 ? 0xEDB88320 ^ (crc >> 1) : crc >> 1 }
    return crc
  }

  private static func number<T: FixedWidthInteger>(_ value: T) -> Data {
    var value = value.littleEndian
    return withUnsafeBytes(of: &value) { Data($0) }
  }

  private static func crc(_ url: URL) throws -> (UInt32, UInt32) {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var crc: UInt32 = 0xFFFFFFFF
    var bytes: UInt64 = 0
    while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
      bytes += UInt64(data.count)
      guard bytes < UInt64(UInt32.max) else { throw CaptureFormat.error("Scan file is too large for the ZIP format.") }
      for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
    }
    return (crc ^ 0xFFFFFFFF, UInt32(bytes))
  }

  static func write(root: URL, to destination: URL) throws {
    let files = try CaptureFormat.payloadFiles(root)
    guard files.count < Int(UInt16.max) else { throw CaptureFormat.error("Too many scan files for ZIP export.") }
    let temporary = destination.appendingPathExtension("tmp")
    guard FileManager.default.createFile(atPath: temporary.path, contents: nil,
      attributes: [.protectionKey: FileProtectionType.complete]) else {
      throw CaptureFormat.error("Could not create the export archive. Check available storage.")
    }
    let output = try FileHandle(forWritingTo: temporary)
    defer { try? output.close(); try? FileManager.default.removeItem(at: temporary) }
    var directory = Data()
    for (path, url) in files {
      let checked: (UInt32, UInt32)
      do { checked = try crc(url) }
      catch { throw CaptureFormat.fileError(error, stage: "ZIP checksum", path: path) }
      let (checksum, size) = checked
      let name = Data(path.utf8)
      let offset = try output.offset()
      guard offset < UInt64(UInt32.max), name.count < Int(UInt16.max) else { throw CaptureFormat.error("Scan ZIP is too large.") }
      var header = number(UInt32(0x04034B50)) + number(UInt16(20)) + number(UInt16(0x0800))
      header += number(UInt16(0)) + number(UInt16(0)) + number(UInt16(33)) + number(checksum)
      header += number(size) + number(size) + number(UInt16(name.count)) + number(UInt16(0)) + name
      try output.write(contentsOf: header)
      let input: FileHandle
      do { input = try FileHandle(forReadingFrom: url) }
      catch { throw CaptureFormat.fileError(error, stage: "ZIP read", path: path) }
      do {
        while let data = try input.read(upToCount: 1_048_576), !data.isEmpty { try output.write(contentsOf: data) }
        try input.close()
      } catch { try? input.close(); throw error }
      var central = number(UInt32(0x02014B50)) + number(UInt16(20)) + number(UInt16(20)) + number(UInt16(0x0800))
      central += number(UInt16(0)) + number(UInt16(0)) + number(UInt16(33)) + number(checksum)
      central += number(size) + number(size) + number(UInt16(name.count))
      central += number(UInt16(0)) + number(UInt16(0)) + number(UInt16(0)) + number(UInt16(0))
      central += number(UInt32(0)) + number(UInt32(offset)) + name
      directory += central
    }
    let start = try output.offset()
    guard start + UInt64(directory.count) + 22 < UInt64(UInt32.max) else { throw CaptureFormat.error("Scan ZIP exceeds 4 GB; scan a smaller room.") }
    try output.write(contentsOf: directory)
    var end = number(UInt32(0x06054B50)) + number(UInt16(0)) + number(UInt16(0))
    end += number(UInt16(files.count)) + number(UInt16(files.count))
    end += number(UInt32(directory.count)) + number(UInt32(start)) + number(UInt16(0))
    try output.write(contentsOf: end)
    try output.synchronize()
    try output.close()
    if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
    try FileManager.default.moveItem(at: temporary, to: destination)
  }
}
