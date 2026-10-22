import Foundation

/// Validate the portable JSON, without constructing another framework-owned room.
enum RoomJSONValidator {
  static func validate(_ data: Data, expectedCounts: [String: Int]) throws {
    guard let room = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw failure("Exported room JSON must contain an object.")
    }
    guard (expectedCounts["walls"] ?? 0) > 0 else {
      throw failure("No walls were captured. Scan more of the room and retry.")
    }
    for name in expectedCounts.keys.sorted() {
      let expected = expectedCounts[name]!
      // Apple may omit an empty collection. A non-empty collection must exist.
      if room[name] == nil && expected == 0 { continue }
      guard let entries = room[name] as? [Any] else {
        throw failure("Exported room JSON is missing the \(name) array (expected \(expected) entries).")
      }
      guard entries.count == expected else {
        throw failure("Exported \(name) count differs: captured \(expected), JSON contains \(entries.count).")
      }
    }
    guard let walls = room["walls"] as? [[String: Any]], !walls.isEmpty else {
      throw failure("Exported walls must contain room geometry.")
    }
    for (index, wall) in walls.enumerated() {
      guard wall["transform"] != nil, wall["dimensions"] != nil else {
        throw failure("Exported wall \(index) is missing its transform or dimensions.")
      }
    }
  }

  static func verifyReadBack(_ saved: Data, matches original: Data) throws {
    guard saved == original else {
      throw failure("The bytes read from room.json differ from the exported JSON (expected \(original.count) bytes, read \(saved.count)).")
    }
  }

  private static func failure(_ message: String) -> NSError {
    NSError(domain: "RoomPlanDeviceTest.Export", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message])
  }
}

/// Only file storage lives here, so simulator tests do not need RoomPlan or a camera.
final class ScanStore {
  let baseURL: URL
  private let manager = FileManager.default
  private let activeStates: Set<String> = ["checking", "requesting_permission", "scanning", "processing", "packaging"]

  init(baseURL: URL? = nil) throws {
    self.baseURL = baseURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("RoomPlanTest", isDirectory: true)
    try manager.createDirectory(at: self.baseURL, withIntermediateDirectories: true)
    var root = self.baseURL
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try root.setResourceValues(values)
    #if !targetEnvironment(simulator)
    try manager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: root.path)
    #endif
  }

  static func timestamp() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
  }

  func directory(_ id: String) throws -> URL {
    guard UUID(uuidString: id) != nil else { throw failure("Invalid scan identifier.") }
    return baseURL.appendingPathComponent(id, isDirectory: true)
  }

  func diagnosticsURL(_ id: String) throws -> URL {
    try directory(id).appendingPathComponent("diagnostics.json")
  }

  private func failure(_ message: String) -> NSError {
    NSError(domain: "RoomPlanDeviceTest.Storage", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message])
  }

  private func read(_ url: URL) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
      throw failure("The saved JSON does not contain an object.")
    }
    return object
  }

  private func write(_ value: [String: Any], to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url, options: [.atomic, .completeFileProtection])
  }

  func begin(device: [String: Any], support: [String: Any], permission: String) throws -> String {
    let id = UUID().uuidString
    let folder = try directory(id)
    try manager.createDirectory(at: folder, withIntermediateDirectories: false)
    let now = Self.timestamp()
    try write([
      "schemaVersion": 1,
      "scanId": id,
      "createdAt": now,
      "updatedAt": now,
      "device": device,
      "support": support,
      "cameraPermission": permission,
      "state": "checking",
      "events": [["timestamp": now, "name": "attempt_created"]]
    ], to: diagnosticsURL(id))
    return id
  }

  func record(_ id: String, event: String, state: String? = nil,
              details: [String: Any] = [:], error: Error? = nil,
              errorCode: String? = nil) throws {
    let url = try diagnosticsURL(id)
    var object = try read(url)
    let now = Self.timestamp()
    var events = object["events"] as? [[String: Any]] ?? []
    events.append(["timestamp": now, "name": event, "details": details])
    object["events"] = events
    object["updatedAt"] = now
    if let state = state {
      object["state"] = state
      if ["failed", "cancelled", "interrupted", "packaging"].contains(state) { object.removeValue(forKey: "completedAt") }
      if state == "packaging" { object.removeValue(forKey: "error") }
    }
    if let permission = details["cameraPermission"] { object["cameraPermission"] = permission }
    if let error = error {
      let native = error as NSError
      var information: [String: Any] = ["code": errorCode ?? "capture_failed", "message": native.localizedDescription,
                                       "domain": native.domain, "nativeCode": native.code]
      for key in ["stage", "relativePath"] { if let value = native.userInfo[key] as? String { information[key] = value } }
      if let underlying = native.userInfo[NSUnderlyingErrorKey] as? NSError {
        information["underlyingDomain"] = underlying.domain; information["underlyingCode"] = underlying.code
      }
      object["error"] = information
    }
    try write(object, to: url)
  }

  func complete(_ id: String, roomData: Data, counts: [String: Int],
                validate: (Data) throws -> Void) throws -> [String: Any] {
    guard (counts["walls"] ?? 0) > 0 else { throw failure("No walls were captured. Scan more of the room and retry.") }
    try validate(roomData)
    let roomURL = try directory(id).appendingPathComponent("room.json")
    try roomData.write(to: roomURL, options: [.atomic, .completeFileProtection])
    let savedData = try Data(contentsOf: roomURL)
    try RoomJSONValidator.verifyReadBack(savedData, matches: roomData)
    try validate(savedData)

    let url = try diagnosticsURL(id)
    var object = try read(url)
    let now = Self.timestamp()
    object["state"] = "completed"
    object["updatedAt"] = now
    object["completedAt"] = now
    object["counts"] = counts
    var events = object["events"] as? [[String: Any]] ?? []
    events.append(["timestamp": now, "name": "room_written_and_read_back",
                   "details": ["bytes": savedData.count, "byteMatch": true,
                               "validation": "encoded_json_and_exact_readback"]])
    object["events"] = events
    // Diagnostics are the commit marker: an orphan room.json is never a completed scan.
    try write(object, to: url)
    return summary(object)
  }

  private func summary(_ object: [String: Any]) -> [String: Any] {
    ["scanId": object["scanId"] ?? "", "completedAt": object["completedAt"] ?? "",
     "counts": object["counts"] ?? [:], "capture": object["capture"] ?? [:],
     "pipelineReady": object["capture"] != nil]
  }

  func attempts() throws -> [[String: Any]] {
    let urls = try manager.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil)
    return urls.compactMap { url -> [String: Any]? in
      guard UUID(uuidString: url.lastPathComponent) != nil else { return nil }
      return try? read(url.appendingPathComponent("diagnostics.json"))
    }.sorted { ($0["createdAt"] as? String ?? "") > ($1["createdAt"] as? String ?? "") }
  }

  func recoverInterruptedAttempts() throws {
    for object in try attempts() {
      guard let state = object["state"] as? String, let id = object["scanId"] as? String else { continue }
      let archive = try directory(id).appendingPathComponent("scan-\(id).zip")
      let missingArchive = state == "completed" && object["capture"] != nil && !manager.fileExists(atPath: archive.path)
      guard activeStates.contains(state) || missingArchive else { continue }
      try record(id, event: "previous_process_ended", state: "interrupted",
                 details: ["message": "The app closed before this attempt finished. Start a new scan."])
    }
  }

  func latestCompleted() throws -> [String: Any]? {
    for object in try attempts() where object["state"] as? String == "completed" {
      guard let id = object["scanId"] as? String,
            let room = try? read(directory(id).appendingPathComponent("room.json")),
            let walls = room["walls"] as? [Any], !walls.isEmpty else { continue }
      let archive = try directory(id).appendingPathComponent("scan-\(id).zip")
      if object["capture"] != nil && !manager.fileExists(atPath: archive.path) { continue }
      return summary(object)
    }
    return nil
  }

  func latestAttempt() throws -> [String: Any]? { try attempts().first }

  func retryCandidate() throws -> [String: Any]? {
    guard let attempt = try latestAttempt(), let id = attempt["scanId"] as? String,
          let state = attempt["state"] as? String, ["failed", "interrupted"].contains(state),
          attempt["capture"] is [String: Any], attempt["counts"] is [String: Any] else { return nil }
    let root = try directory(id)
    for path in ["room.json", "frames.jsonl", "roomplan/live-room.json", "roomplan/room.usdz", "roomplan/node-map.json"] {
      guard manager.fileExists(atPath: root.appendingPathComponent(path).path) else { return nil }
    }
    return attempt
  }

  func resultURLs() throws -> [URL] {
    guard let scan = try latestCompleted(), let id = scan["scanId"] as? String else {
      throw failure("No completed scan is available. Finish a room scan first.")
    }
    if scan["pipelineReady"] as? Bool == true {
      return [try directory(id).appendingPathComponent("scan-\(id).zip")]
    }
    return [try directory(id).appendingPathComponent("room.json"), try diagnosticsURL(id)]
  }

  func latestDiagnosticsURL() throws -> URL {
    guard let attempt = try latestAttempt(), let id = attempt["scanId"] as? String else {
      throw failure("No diagnostic log is available. Start a scan attempt first.")
    }
    return try diagnosticsURL(id)
  }

  func deleteAll() throws {
    for url in try manager.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil) {
      guard UUID(uuidString: url.lastPathComponent) != nil else { continue }
      try manager.removeItem(at: url)
    }
  }
}
