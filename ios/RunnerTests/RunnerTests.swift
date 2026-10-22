import XCTest
@testable import Runner

final class RunnerTests: XCTestCase {
  private var folder: URL!
  private var store: ScanStore!

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
    let data = Data(#"{"walls":[{"fixture":true}],"doors":[],"windows":[],"objects":[]}"#.utf8)
    _ = try store.complete(id, roomData: data, counts: ["walls": 1, "doors": 0, "windows": 0, "objects": 0]) {
      _ = try JSONSerialization.jsonObject(with: $0)
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
}
