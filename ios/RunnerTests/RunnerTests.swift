import XCTest
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
    try FileManager.default.createDirectory(at: root.appendingPathComponent("roomplan"), withIntermediateDirectories: true)
    try roomData.write(to: root.appendingPathComponent("room.json"))
    try roomData.write(to: root.appendingPathComponent("roomplan/live-room.json"))
    try Data("synthetic frame log; not a capture".utf8).write(to: root.appendingPathComponent("frames.jsonl"))
    try Data("synthetic USDZ storage fixture".utf8).write(to: root.appendingPathComponent("roomplan/room.usdz"))
    try Data("{}".utf8).write(to: root.appendingPathComponent("roomplan/node-map.json"))
    let report: [String: Any] = ["train_frames": 20, "validation_frames": 10, "training_camera_span_metres": 0.5]
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
}
