import CryptoKit
import Foundation

enum CaptureFormat {
  static let name = "aproxx.iphone-scan"
  static let version = 1
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

  static func payloadFiles(_ root: URL) throws -> [(String, URL)] {
    guard let iterator = FileManager.default.enumerator(at: root,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else {
      throw error("Could not enumerate the scan package.")
    }
    var files: [(String, URL)] = []
    for case let url as URL in iterator {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isSymbolicLink != true else { throw error("Scan packages must not contain symbolic links.") }
      guard values.isRegularFile == true else { continue }
      let path = String(url.path.dropFirst(root.path.count + 1))
      if path.hasSuffix(".zip") || path.hasSuffix(".tmp") { continue }
      files.append((path, url))
    }
    return files.sorted { $0.0 < $1.0 }
  }

  static func validateCaptureReport(_ report: [String: Any]) throws {
    guard let train = report["train_frames"] as? Int, train >= minimumTrainFrames,
          let validation = report["validation_frames"] as? Int, validation >= minimumValidationFrames else {
      throw error("Capture at least \(minimumTrainFrames) training frames and \(minimumValidationFrames) check-pass frames before finishing.")
    }
    guard let span = report["training_camera_span_metres"] as? Double,
          span.isFinite, span >= minimumCameraSpanMetres else {
      throw error("Walk around the room: the training camera must move at least 20 cm. Rotating in one spot is insufficient.")
    }
  }

  /// Called only after capture has drained and RoomPlan files have been written.
  static func finalise(root: URL, scanID: String, device: [String: Any],
                       counts: [String: Int], report: [String: Any]) throws -> URL {
    try validateCaptureReport(report)
    let diagnosticsURL = root.appendingPathComponent("diagnostics.json")
    var diagnostics = try readJSON(diagnosticsURL)
    diagnostics["state"] = "packaging"
    diagnostics["counts"] = counts
    diagnostics["capture"] = report
    try writeJSON(diagnostics, to: diagnosticsURL)
    let originalRoom = try Data(contentsOf: root.appendingPathComponent("room.json"))
    try RoomJSONValidator.validate(originalRoom, expectedCounts: counts)

    let manifest: [String: Any] = [
      "format": name, "schema_version": version, "scan_id": scanID, "room_id": scanID,
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
      "validation_protocol": "withheld_rgb_depth_shared_arkit_and_roomplan_mapping",
      "privacy": ["contains_raw_interior_photos": true, "automatically_redacted": false,
                  "automatic_upload": false, "excluded_from_device_backup": true],
      "quality_status": "capture_sanity_passed_alignment_and_reconstruction_require_device_acceptance"
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
    for (path, url) in try payloadFiles(root) where path != "checksums.json" { hashes[path] = try fingerprint(url) }
    try writeJSON(["algorithm": "sha256", "files": hashes], to: root.appendingPathComponent("checksums.json"))
    for (path, value) in hashes {
      let expected = value as! [String: Any]
      let actual = try fingerprint(root.appendingPathComponent(path))
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
      let (checksum, size) = try crc(url)
      let name = Data(path.utf8)
      let offset = try output.offset()
      guard offset < UInt64(UInt32.max), name.count < Int(UInt16.max) else { throw CaptureFormat.error("Scan ZIP is too large.") }
      var header = number(UInt32(0x04034B50)) + number(UInt16(20)) + number(UInt16(0x0800))
      header += number(UInt16(0)) + number(UInt16(0)) + number(UInt16(33)) + number(checksum)
      header += number(size) + number(size) + number(UInt16(name.count)) + number(UInt16(0)) + name
      try output.write(contentsOf: header)
      let input = try FileHandle(forReadingFrom: url)
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
