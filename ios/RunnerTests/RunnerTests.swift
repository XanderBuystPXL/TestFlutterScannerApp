import XCTest
import simd
@testable import Runner

final class RunnerTests: XCTestCase {
  private var folder: URL!
  private var store: ScanStore!
  private let roomData = Data(#"{"walls":[{"transform":[[1,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1]],"dimensions":[3,2.5,0]}],"doors":[],"windows":[],"objects":[]}"#.utf8)
  private let counts = ["walls": 1, "doors": 0, "windows": 0, "objects": 0,
                        "openings": 0, "floors": 0]

  override func setUpWithError() throws {
    folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    store = try ScanStore(baseURL: folder)
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: folder)
  }

  private func begin() throws -> String {
    try store.begin(device: ["testFixture": true], support: ["roomPlanSupported": false], permission: "authorized")
  }

  private func complete(_ id: String) throws {
    // Storage fixture only; this is not a real RoomPlan scan or device acceptance evidence.
    _ = try store.complete(id, roomData: roomData, counts: counts) {
      try RoomJSONValidator.validate($0, expectedCounts: self.counts)
    }
  }

  private func captureFixture(_ id: String, train: Int = 20, validation: Int = 10) throws -> [String: Any] {
    let root = try store.directory(id)
    for name in ["rgb", "depth", "confidence", "roomplan"] {
      try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    try roomData.write(to: root.appendingPathComponent("room.json"))
    try roomData.write(to: root.appendingPathComponent("roomplan/live-room.json"))
    try Data("synthetic USDZ storage fixture".utf8).write(to: root.appendingPathComponent("roomplan/room.usdz"))
    try Data("{}".utf8).write(to: root.appendingPathComponent("roomplan/node-map.json"))
    var indexData = Data()
    for index in 1...(train + validation) {
      let name = String(format: "frame-%06d", index)
      let rgb = "rgb/\(name).jpg", depth = "depth/\(name).f32", confidence = "confidence/\(name).u8"
      // File-layout fixtures, not real sensor values or JPEG/USDZ content.
      try Data("synthetic JPEG".utf8).write(to: root.appendingPathComponent(rgb))
      try Data(count: 16).write(to: root.appendingPathComponent(depth))
      try Data(count: 4).write(to: root.appendingPathComponent(confidence))
      let frame: [String: Any] = ["frame_id": name, "role": index <= train ? "train" : "validation", "rgb_path": rgb,
        "depth": ["path": depth, "width": 2, "height": 2], "confidence": ["path": confidence]]
      indexData.append(try JSONSerialization.data(withJSONObject: frame))
      indexData.append(10)
    }
    try indexData.write(to: root.appendingPathComponent("frames.jsonl"))
    return ["train_frames": train, "validation_frames": validation, "saved_frames": train + validation,
            "training_camera_span_metres": 0.5]
  }

  func testCompletedScanSurvivesNewStoreInstance() throws {
    let id = try begin()
    try complete(id)
    let reopened = try ScanStore(baseURL: folder)
    XCTAssertEqual(try reopened.latestCompleted()?["scanId"] as? String, id)
    XCTAssertEqual(try reopened.resultURLs().map(\.lastPathComponent), ["room.json", "diagnostics.json"])
  }

  func testCancellationPreservesEarlierCompletion() throws {
    let completedID = try begin()
    try complete(completedID)
    let cancelledID = try begin()
    try store.record(cancelledID, event: "cancel", state: "cancelled")
    XCTAssertEqual(try store.latestCompleted()?["scanId"] as? String, completedID)
  }

  func testReadbackValidationFailureNeverCommitsScan() throws {
    let id = try begin()
    var validations = 0
    XCTAssertThrowsError(try store.complete(id, roomData: Data(#"{"walls":[{}]}"#.utf8), counts: ["walls": 1]) { _ in
      validations += 1
      if validations == 2 { throw NSError(domain: "FixtureReadback", code: 1) }
    })
    XCTAssertNil(try store.latestCompleted())
    XCTAssertNotEqual(try store.latestAttempt()?["state"] as? String, "completed")
  }

  func testEmptyGeometryIsNotCommitted() throws {
    let id = try begin()
    XCTAssertThrowsError(try store.complete(id, roomData: Data("{}".utf8), counts: ["walls": 0]) { _ in })
    XCTAssertNil(try store.latestCompleted())
  }

  func testInterruptedAttemptIsRecoveredWithoutChangingCompletedScan() throws {
    let completedID = try begin()
    try complete(completedID)
    let id = try begin()
    try store.record(id, event: "started", state: "scanning")
    let reopened = try ScanStore(baseURL: folder)
    try reopened.recoverInterruptedAttempts()
    let diagnostic = try JSONSerialization.jsonObject(with: Data(contentsOf: reopened.diagnosticsURL(id))) as! [String: Any]
    XCTAssertEqual(diagnostic["state"] as? String, "interrupted")
    XCTAssertEqual(try reopened.latestCompleted()?["scanId"] as? String, completedID)
  }

  func testInvalidScanPathIsRejected() {
    XCTAssertThrowsError(try store.directory("../outside"))
  }

  func testUnwritableStorageIsReported() throws {
    let file = folder.appendingPathComponent("not-a-directory")
    try Data("fixture".utf8).write(to: file)
    XCTAssertThrowsError(try ScanStore(baseURL: file))
  }

  func testValidationDoesNotDependOnFrameworkRoomIdentity() throws {
    // The app's scan UUID is separate from any framework-generated room identity.
    // The validator checks encoded geometry, not a newly decoded RoomPlan object's UUID.
    XCTAssertNoThrow(try RoomJSONValidator.validate(roomData, expectedCounts: counts))
  }

  func testOmittedEmptyCollectionsAreAccepted() throws {
    let room = try JSONSerialization.jsonObject(with: roomData) as! [String: Any]
    let wallsOnly = try JSONSerialization.data(withJSONObject: ["walls": room["walls"]!])
    XCTAssertNoThrow(try RoomJSONValidator.validate(wallsOnly, expectedCounts: counts))
  }

  func testWrongEncodedCountNamesTheField() {
    var expected = counts
    expected["windows"] = 1
    XCTAssertThrowsError(try RoomJSONValidator.validate(roomData, expectedCounts: expected)) { error in
      XCTAssertTrue(error.localizedDescription.contains("windows"))
      XCTAssertTrue(error.localizedDescription.contains("captured 1, JSON contains 0"))
    }
  }

  func testOmittedNonEmptyCollectionIsRejected() {
    var expected = counts
    expected["floors"] = 1
    XCTAssertThrowsError(try RoomJSONValidator.validate(roomData, expectedCounts: expected)) { error in
      XCTAssertTrue(error.localizedDescription.contains("floors"))
    }
  }

  func testMissingWallGeometryIsRejected() {
    XCTAssertThrowsError(try RoomJSONValidator.validate(Data(#"{"walls":[{}]}"#.utf8), expectedCounts: counts))
  }

  func testMalformedRoomJSONIsRejected() {
    XCTAssertThrowsError(try RoomJSONValidator.validate(Data("not json".utf8), expectedCounts: counts))
  }

  func testSameLengthChangedBytesAreRejected() {
    let original = Data(#"{"value":1}"#.utf8)
    let changed = Data(#"{"value":2}"#.utf8)
    XCTAssertEqual(original.count, changed.count)
    XCTAssertThrowsError(try RoomJSONValidator.verifyReadBack(changed, matches: original))
  }

  func testSavedBytesMatchOriginalAndLogReadbackStrategy() throws {
    let id = try begin()
    try complete(id)
    XCTAssertEqual(try Data(contentsOf: store.directory(id).appendingPathComponent("room.json")), roomData)
    let log = try JSONSerialization.jsonObject(with: Data(contentsOf: store.diagnosticsURL(id))) as! [String: Any]
    let events = log["events"] as! [[String: Any]]
    let details = events.last?["details"] as? [String: Any]
    XCTAssertEqual(details?["byteMatch"] as? Bool, true)
    XCTAssertEqual(details?["validation"] as? String, "encoded_json_and_exact_readback")
  }

  func testDepthRowsStripPaddingAndRejectInvalidLayouts() throws {
    let padded = Data([1,2,3,4,99,99,5,6,7,8,99,99])
    XCTAssertEqual(try CaptureFormat.packRows(padded, rowBytes: 4, stride: 6, height: 2), Data([1,2,3,4,5,6,7,8]))
    XCTAssertThrowsError(try CaptureFormat.packRows(padded, rowBytes: 8, stride: 6, height: 2))
    XCTAssertThrowsError(try CaptureFormat.packRows(padded, rowBytes: 4, stride: Int.max, height: 2))
  }

  func testMatrixSerializationTransposesSIMDColumns() {
    XCTAssertEqual(CaptureFormat.rows([[1,2,3],[4,5,6],[7,8,9]]), [[1,4,7],[2,5,8],[3,6,9]])
  }

  func testPackageRequiresMovementAndBothPasses() {
    let valid: [String: Any] = ["train_frames": 20, "validation_frames": 10, "training_camera_span_metres": 0.5]
    XCTAssertNoThrow(try CaptureFormat.validateCaptureReport(valid))
    for field in ["train_frames", "validation_frames", "training_camera_span_metres"] {
      var changed = valid; changed[field] = 0
      XCTAssertThrowsError(try CaptureFormat.validateCaptureReport(changed))
    }
  }

  func testMotionGateSkipsFastMotionAndResetsAfterTrackingLoss() {
    func yaw(_ degrees: Float) -> simd_float4x4 {
      simd_float4x4(simd_quatf(angle: degrees * .pi / 180, axis: SIMD3(0, 1, 0)))
    }
    XCTAssertEqual(CaptureMotionGate.rotationDegrees(from: yaw(0), to: yaw(90)), 90, accuracy: 0.01)
    var gate = CaptureMotionGate()
    XCTAssertTrue(gate.isSteady(time: 0, pose: yaw(0)))
    XCTAssertFalse(gate.isSteady(time: 0.05, pose: yaw(10)))
    XCTAssertTrue(gate.isSteady(time: 0.10, pose: yaw(11)))
    var moved = yaw(11); moved.columns.3.x = 0.10
    XCTAssertFalse(gate.isSteady(time: 0.15, pose: moved))
    gate.reset()
    XCTAssertTrue(gate.isSteady(time: 0.20, pose: yaw(90)))
  }

  func testAppleBinaryNodeMetadataBecomesJSONBeforeChecksums() throws {
    let id = try begin(), report = try captureFixture(id), root = try store.directory(id)
    let mapping = ["Wall0": UUID().uuidString, "Door0": UUID().uuidString]
    let plist = try PropertyListSerialization.data(fromPropertyList: mapping, format: .binary, options: 0)
    let url = root.appendingPathComponent("roomplan/node-map.json")
    try plist.write(to: url)
    _ = try CaptureFormat.finalise(root: root, scanID: id, device: [:], counts: counts, report: report)
    XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String], mapping)
    let files = try CaptureFormat.readJSON(root.appendingPathComponent("checksums.json"))["files"] as! [String: Any]
    XCTAssertEqual((files["roomplan/node-map.json"] as? [String: Any])?["sha256"] as? String,
                   try CaptureFormat.fingerprint(url)["sha256"] as? String)
  }

  func testNodeMetadataRejectsNonStringValuesAndArrays() throws {
    let plist = try PropertyListSerialization.data(fromPropertyList: ["Wall0": 3], format: .xml, options: 0)
    XCTAssertThrowsError(try CaptureFormat.normalisedNodeMap(plist))
    XCTAssertThrowsError(try CaptureFormat.normalisedNodeMap(Data("[1,2]".utf8)))
  }

  private func guidanceSurfaces() -> [GuidanceSurface] {
    // Synthetic planes exercise projection/coverage only; not room/device evidence.
    (0..<4).map { i in
      var transform = matrix_identity_double4x4
      transform.columns.3 = SIMD4(Double(i % 3 - 1) * 0.35, 0, -2, 1)
      return GuidanceSurface(id: "surface-\(i)", kind: i == 3 ? "floor" : "wall",
        label: i == 3 ? "Floor 1" : "Wall \(i+1)", transform: transform, size: SIMD3(1, 1, 0))
    }
  }

  private func guidanceFrame(_ index: Int, x: Double, depth: Float = 2, confidence: UInt8 = 2) -> GuidanceFrame {
    var camera = matrix_identity_double4x4; camera.columns.3.x = x
    return GuidanceFrame(timestamp: Double(index)/3, camera: camera, width: 64, height: 48,
      fx: 32, fy: 32, cx: 32, cy: 24, depth: [Float](repeating: depth, count: 64*48),
      confidence: [UInt8](repeating: confidence, count: 64*48), brightness: 100, detail: 50)
  }

  func testGuidanceRequiresTranslationRatherThanStationaryFrameCount() {
    let guidance = CaptureGuidance(); guidance.setSurfaces(guidanceSurfaces())
    for i in 0..<60 { guidance.add(guidanceFrame(i, x: 0)) }
    XCTAssertFalse(guidance.snapshot().ready)
    XCTAssertTrue(guidance.snapshot().fractions.values.allSatisfy { $0 == 0 })
  }

  func testGuidanceCreditsOverlappingViewsAndReplaysNewGeometry() {
    let guidance = CaptureGuidance()
    for i in 0..<30 { guidance.add(guidanceFrame(i, x: Double(i)/29*0.6)) }
    // Geometry arriving later must use already saved views too.
    guidance.setSurfaces(guidanceSurfaces())
    XCTAssertTrue(guidance.snapshot().ready)
    XCTAssertEqual(guidance.snapshot().report["saved_frames"] as? Int, 30)
    XCTAssertFalse(guidance.snapshot().report["reconstruction_verified"] as! Bool)
    XCTAssertFalse(guidance.snapshot(coaching: "Slow down").ready)
    XCTAssertFalse(guidance.snapshot(tracking: "Tracking limited").ready)
  }

  func testGuidanceRejectsLowConfidenceAndOccludedWallSamples() {
    let cases: [(Float, UInt8)] = [(1, 2), (2, 0)]
    for (depth, confidence) in cases {
      let guidance = CaptureGuidance(); guidance.setSurfaces(guidanceSurfaces())
      for i in 0..<30 { guidance.add(guidanceFrame(i, x: Double(i)/29*0.6, depth: depth, confidence: confidence)) }
      XCTAssertFalse(guidance.snapshot().ready)
      XCTAssertTrue(guidance.snapshot().fractions.values.allSatisfy { $0 == 0 })
    }
  }

  func testGuidanceNewUnseenWallAndMissingFloorPreventReady() {
    let guidance = CaptureGuidance(); guidance.setSurfaces(guidanceSurfaces())
    for i in 0..<30 { guidance.add(guidanceFrame(i, x: Double(i)/29*0.6)) }
    XCTAssertTrue(guidance.snapshot().ready)
    guidance.setSurfaces(Array(guidanceSurfaces().prefix(3)))
    XCTAssertFalse(guidance.snapshot().ready)
    XCTAssertTrue(guidance.snapshot().message.contains("floor"))
    var transform = matrix_identity_double4x4; transform.columns.3 = SIMD4(100, 0, -2, 1)
    guidance.setSurfaces(guidanceSurfaces() + [GuidanceSurface(id: "unseen", kind: "wall", label: "Wall 4", transform: transform, size: SIMD3(1,1,0))])
    XCTAssertFalse(guidance.snapshot().ready)
    XCTAssertEqual(guidance.snapshot().missingID, "unseen")
  }

  func testContinuousPackageNeedsAssessmentButNoUserSelectedCheckPass() {
    let guidance = CaptureGuidance(); guidance.setSurfaces(guidanceSurfaces())
    for i in 0..<30 { guidance.add(guidanceFrame(i, x: Double(i)/29*0.6)) }
    var report: [String: Any] = ["capture_mode": "continuous_guided", "train_frames": 30,
      "capture_frames": 30, "validation_frames": 0, "saved_frames": 30,
      "training_camera_span_metres": 0.6, "guidance": guidance.snapshot().report]
    XCTAssertNoThrow(try CaptureFormat.validateCaptureReport(report))
    report.removeValue(forKey: "guidance")
    XCTAssertThrowsError(try CaptureFormat.validateCaptureReport(report))
    XCTAssertNoThrow(try CaptureFormat.validateCaptureReport(report, requireGuidance: false))
  }

  func testContinuousWarningPackagePreservesFilesWithoutClaimingCoveragePass() throws {
    let id = try begin(), root = try store.directory(id)
    var report = try captureFixture(id, train: 30, validation: 0)
    let indexURL = root.appendingPathComponent("frames.jsonl")
    let original = try String(contentsOf: indexURL, encoding: .utf8)
    try original.replacingOccurrences(of: "\"train\"", with: "\"capture\"").write(to: indexURL, atomically: true, encoding: .utf8)
    let guidance = CaptureGuidance()
    for i in 0..<30 { guidance.add(guidanceFrame(i, x: Double(i)/29*0.6)) }
    report["capture_mode"] = "continuous_guided"; report["capture_frames"] = 30
    report["training_camera_span_metres"] = 0.6; report["guidance"] = guidance.snapshot().report
    _ = try CaptureFormat.finalise(root: root, scanID: id, device: ["testFixture": true], counts: counts, report: report)
    let manifest = try CaptureFormat.readJSON(root.appendingPathComponent("manifest.json"))
    XCTAssertEqual(manifest["schema_version"] as? Int, 2)
    XCTAssertEqual(manifest["quality_status"] as? String, "needs_more_views_reconstruction_unverified")
    XCTAssertEqual(try store.latestCompleted()?["scanId"] as? String, id)
    XCTAssertEqual(try store.resultURLs().count, 1)
  }

  func testDeletionRemovesFailedAndCompletedCapturesAndPreservesUnrelatedFiles() throws {
    let id = try begin(); try complete(id)
    let failed = try begin(); try store.record(failed, event: "failed", state: "failed")
    let other = folder.appendingPathComponent("keep.txt")
    try Data("keep".utf8).write(to: other)
    try store.deleteAll()
    XCTAssertTrue(try store.attempts().isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
  }

  func testMissingArchiveNeverBecomesPipelineReady() throws {
    let id = try begin(); try complete(id)
    let url = try store.diagnosticsURL(id)
    var diag = try CaptureFormat.readJSON(url)
    diag["capture"] = ["train_frames": 20]
    try CaptureFormat.writeJSON(diag, to: url)
    XCTAssertNil(try store.latestCompleted())
    try store.recoverInterruptedAttempts()
    XCTAssertEqual(try CaptureFormat.readJSON(url)["state"] as? String, "interrupted")
  }

  func testSHA256KnownVectorAndNativeZIPFixture() throws {
    let fixture = folder.appendingPathComponent("fixture", isDirectory: true)
    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    let text = fixture.appendingPathComponent("payload.txt")
    try Data("123456789".utf8).write(to: text)
    let unicode = fixture.appendingPathComponent("fïle.txt")
    try Data("unicode".utf8).write(to: unicode)
    XCTAssertEqual(try CaptureFormat.fingerprint(text)["sha256"] as? String,
      "15e2b0d3c33891ebb0f1ef609ec419420c20e320ce94c65fbc8c3312448eb225")
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let archive = documents.appendingPathComponent("zip-writer-fixture.zip")
    try ScanArchive.write(root: fixture, to: archive)
    let bytes = try Data(contentsOf: archive)
    XCTAssertEqual(Array(bytes.prefix(4)), [0x50, 0x4b, 0x03, 0x04])
    XCTAssertNotNil(bytes.range(of: Data([0x26, 0x39, 0xF4, 0xCB]))) // Standard CRC32 of 123456789.
    XCTAssertNotNil(bytes.range(of: Data([0x50, 0x4b, 0x05, 0x06])))
    // Codemagic reads this synthetic fixture independently with Python's zipfile.
  }

  func testPackageCommitRequiresArchiveAndRestoresZIPSharing() throws {
    let id = try begin()
    let root = try store.directory(id)
    let report = try captureFixture(id)
    let archive = try CaptureFormat.finalise(root: root, scanID: id, device: ["testFixture": true], counts: counts, report: report)
    XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
    let reopened = try ScanStore(baseURL: folder)
    XCTAssertEqual(try reopened.latestCompleted()?["pipelineReady"] as? Bool, true)
    XCTAssertEqual(try reopened.resultURLs(), [archive])
    let checksums = try CaptureFormat.readJSON(root.appendingPathComponent("checksums.json"))
    let files = checksums["files"] as! [String: Any]
    XCTAssertNotNil(files["room.json"])
    XCTAssertNil(files[archive.lastPathComponent])
    XCTAssertNil(files["checksums.json"])
  }

  func testRelativePayloadPathResolvesAliasAndDirectoryHints() throws {
    let id = try begin()
    _ = try captureFixture(id, train: 32, validation: 77)
    let root = try store.directory(id)
    let alias = folder.appendingPathComponent("short-alias", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
    let depth = root.appendingPathComponent("depth/frame-000075.f32")
    XCTAssertEqual(try CaptureFormat.relativePayloadPath(depth, under: alias), "depth/frame-000075.f32")
    let trailing = URL(fileURLWithPath: root.path + "/", isDirectory: true)
    XCTAssertEqual(try CaptureFormat.relativePayloadPath(depth, under: trailing), "depth/frame-000075.f32")
    let files = try CaptureFormat.payloadFiles(alias)
    XCTAssertEqual(files.first(where: { $0.0 == "depth/frame-000075.f32" })?.1,
                   depth.resolvingSymlinksInPath().standardizedFileURL)
    for (relative, source) in files {
      XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: alias.appendingPathComponent(relative)))
    }
    XCTAssertThrowsError(try CaptureFormat.relativePayloadPath(folder.appendingPathComponent("outside.txt"), under: root))
  }

  func test109FrameCapturePackagesThroughAliasedRoot() throws {
    let id = try begin()
    let report = try captureFixture(id, train: 32, validation: 77)
    let root = try store.directory(id)
    let alias = folder.appendingPathComponent("alias", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
    _ = try CaptureFormat.finalise(root: alias, scanID: id, device: ["testFixture": true], counts: counts, report: report)
    XCTAssertEqual(try store.latestCompleted()?["scanId"] as? String, id)
    let manifest = try CaptureFormat.readJSON(root.appendingPathComponent("checksums.json"))
    let files = manifest["files"] as! [String: Any]
    XCTAssertNotNil(files["depth/frame-000075.f32"])
  }

  func testActuallyMissingDepthFileIsReportedBeforeCompletion() throws {
    let id = try begin()
    let report = try captureFixture(id, train: 32, validation: 77)
    let root = try store.directory(id)
    try FileManager.default.removeItem(at: root.appendingPathComponent("depth/frame-000075.f32"))
    XCTAssertThrowsError(try CaptureFormat.finalise(root: root, scanID: id, device: [:], counts: counts, report: report)) { error in
      XCTAssertEqual((error as NSError).userInfo["relativePath"] as? String, "depth/frame-000075.f32")
      XCTAssertEqual((error as NSError).userInfo["stage"] as? String, "frame validation")
    }
    XCTAssertNil(try store.latestCompleted())
    let diag = try CaptureFormat.readJSON(store.diagnosticsURL(id))
    XCTAssertEqual(diag["state"] as? String, "packaging")
    XCTAssertNil(diag["completedAt"])
    let failure = CaptureFormat.fileError(CaptureFormat.error("missing"), stage: "frame validation", path: "depth/frame-000075.f32")
    try store.record(id, event: "attempt_failed", state: "failed", error: failure, errorCode: "file_write_failed")
    let savedError = try CaptureFormat.readJSON(store.diagnosticsURL(id))["error"] as? [String: Any]
    XCTAssertEqual(savedError?["relativePath"] as? String, "depth/frame-000075.f32")
    XCTAssertEqual(savedError?["stage"] as? String, "frame validation")
  }

  func testTruncatedDepthFileIsRejected() throws {
    let id = try begin()
    let report = try captureFixture(id)
    let root = try store.directory(id)
    try Data(count: 8).write(to: root.appendingPathComponent("depth/frame-000001.f32"))
    XCTAssertThrowsError(try CaptureFormat.finalise(root: root, scanID: id, device: [:], counts: counts, report: report)) { error in
      XCTAssertTrue(error.localizedDescription.contains("16 bytes"))
    }
    XCTAssertNil(try store.latestCompleted())
  }

  func testFailedCaptureCanBeRepackagedWithoutScanningAgain() throws {
    let id = try begin()
    let report = try captureFixture(id)
    let root = try store.directory(id)
    var diag = try CaptureFormat.readJSON(store.diagnosticsURL(id))
    diag["capture"] = report; diag["counts"] = counts; diag["completedAt"] = "stale"
    try CaptureFormat.writeJSON(diag, to: store.diagnosticsURL(id))
    try store.record(id, event: "attempt_failed", state: "failed", error: CaptureFormat.error("Previous packaging failed."))
    XCTAssertEqual(try store.retryCandidate()?["scanId"] as? String, id)
    XCTAssertNil(try CaptureFormat.readJSON(store.diagnosticsURL(id))["completedAt"])
    try store.record(id, event: "export_retry_requested", state: "packaging")
    _ = try CaptureFormat.finalise(root: root, scanID: id, device: [:], counts: counts, report: report)
    XCTAssertEqual(try store.latestCompleted()?["scanId"] as? String, id)
    XCTAssertNil(try CaptureFormat.readJSON(store.diagnosticsURL(id))["error"])
    XCTAssertNil(try store.retryCandidate())
  }

  func testPayloadSymlinkOutsideScanIsRejected() throws {
    let id = try begin()
    let root = try store.directory(id)
    let outside = folder.appendingPathComponent("outside.txt")
    try Data("private".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.txt"), withDestinationURL: outside)
    XCTAssertThrowsError(try CaptureFormat.payloadFiles(root))
  }
}
