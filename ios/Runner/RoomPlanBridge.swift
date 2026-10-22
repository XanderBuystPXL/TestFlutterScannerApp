import AVFoundation
import Flutter
import UIKit
#if !targetEnvironment(simulator)
import RoomPlan
#endif

final class RoomPlanBridge {
  private weak var presenter: UIViewController?
  private var channel: FlutterMethodChannel!
  private var store: ScanStore?
  private var storageWarning: String?
  private var pendingResult: FlutterResult?
  private var activeID: String?
  #if !targetEnvironment(simulator)
  private var scanner: RoomScannerViewController?
  #endif

  init(controller: FlutterViewController) {
    presenter = controller
    do {
      store = try ScanStore()
      try store?.recoverInterruptedAttempts()
    } catch {
      storageWarning = "Could not prepare scan storage: \(error.localizedDescription)"
    }
    channel = FlutterMethodChannel(name: "be.aproxx.roomplan_device_test/scanner",
                                   binaryMessenger: controller.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "scanner_unavailable", message: "The scanner is unavailable.", details: nil))
        return
      }
      switch call.method {
      case "getStatus": result(self.status())
      case "startScan": self.startScan(result)
      case "shareLatestResult": self.share(diagnosticsOnly: false, result: result)
      case "shareDiagnostics": self.share(diagnosticsOnly: true, result: result)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private var supported: Bool {
    #if targetEnvironment(simulator)
    return false
    #else
    return RoomCaptureSession.isSupported
    #endif
  }

  private var supportMessage: String {
    supported ? "RoomPlan is supported on this device."
      : "RoomPlan needs a real LiDAR-capable iPhone or iPad. The simulator cannot scan."
  }

  private var permission: String {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: return "authorized"
    case .notDetermined: return "not_determined"
    case .denied: return "denied"
    case .restricted: return "restricted"
    @unknown default: return "unknown"
    }
  }

  private func requireStore() throws -> ScanStore {
    if let store = store { return store }
    let created = try ScanStore()
    try created.recoverInterruptedAttempts()
    store = created
    storageWarning = nil
    return created
  }

  private func status() -> [String: Any] {
    var value: [String: Any] = ["supported": supported, "supportMessage": supportMessage,
                                "cameraPermission": permission, "hasDiagnostics": false]
    do {
      let store = try requireStore()
      if let scan = try store.latestCompleted() { value["latestScan"] = scan }
      if let attempt = try store.latestAttempt() {
        value["hasDiagnostics"] = true
        value["latestAttemptState"] = attempt["state"]
      }
    } catch {
      storageWarning = "Could not read scan storage: \(error.localizedDescription)"
    }
    if let warning = storageWarning { value["storageWarning"] = warning }
    return value
  }

  private func deviceInfo() -> [String: Any] {
    var system = utsname()
    uname(&system)
    let hardware = withUnsafeBytes(of: &system.machine) { bytes in
      String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
    return ["model": UIDevice.current.model, "hardwareIdentifier": hardware,
            "systemVersion": UIDevice.current.systemVersion,
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "unknown"]
  }

  private func startScan(_ result: @escaping FlutterResult) {
    guard pendingResult == nil, presenter?.presentedViewController == nil else {
      result(FlutterError(code: "busy", message: "Close the current scanner or share sheet first.", details: nil))
      return
    }
    guard presenter?.viewIfLoaded?.window != nil else {
      result(FlutterError(code: "scanner_unavailable", message: "The app is not ready to present the scanner.", details: nil))
      return
    }
    do {
      activeID = try requireStore().begin(device: deviceInfo(),
        support: ["roomPlanSupported": supported, "minimumIOS": "17.0"], permission: permission)
    } catch {
      result(FlutterError(code: "file_write_failed", message: "Could not create scan files: \(error.localizedDescription)", details: nil))
      return
    }
    pendingResult = result
    guard supported else {
      fail("unsupported_device", supportMessage)
      return
    }
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: presentScanner()
    case .notDetermined:
      guard record("camera_permission_requested", state: "requesting_permission") else { return }
      AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
        DispatchQueue.main.async {
          guard let self = self, self.pendingResult != nil else { return }
          guard self.record("camera_permission_result", details: ["cameraPermission": self.permission]) else { return }
          if granted { self.presentScanner() }
          else { self.fail("permission_denied", "Camera access was denied. Enable Camera in iPhone Settings for RoomPlan Test, then retry.") }
        }
      }
    case .denied:
      fail("permission_denied", "Camera access is denied. Enable Camera in iPhone Settings for RoomPlan Test, then retry.")
    case .restricted:
      fail("permission_restricted", "Camera access is restricted by this device's settings.")
    @unknown default:
      fail("permission_denied", "Camera permission could not be determined.")
    }
  }

  @discardableResult
  private func record(_ event: String, state: String? = nil, details: [String: Any] = [:]) -> Bool {
    guard let id = activeID else { return false }
    do {
      try requireStore().record(id, event: event, state: state, details: details)
      return true
    } catch {
      storageWarning = "Diagnostic write failed: \(error.localizedDescription)"
      fail("file_write_failed", "Could not save diagnostics. Check available storage and retry.", error)
      return false
    }
  }

  private func presentScanner() {
    guard UIApplication.shared.applicationState == .active else {
      fail("capture_interrupted", "Return to the app and start a new scan.")
      return
    }
    #if !targetEnvironment(simulator)
    let controller = RoomScannerViewController()
    scanner = controller
    controller.modalPresentationStyle = .fullScreen
    controller.onEvent = { [weak self] event, details in
      let state = event == "finish_requested" ? "processing" : event == "capture_started" ? "scanning" : nil
      self?.record(event, state: state, details: details)
    }
    controller.onCancel = { [weak self] in
      guard let self = self, self.record("cancel_requested", state: "cancelled") else { return }
      self.resolve(["status": "cancelled"])
    }
    controller.onFailure = { [weak self] code, message, error in self?.fail(code, message, error) }
    controller.onRoom = { [weak self] room in self?.save(room) }
    presenter?.present(controller, animated: true)
    #else
    fail("unsupported_device", supportMessage)
    #endif
  }

  #if !targetEnvironment(simulator)
  private func save(_ room: CapturedRoom) {
    guard let id = activeID else { return }
    guard !room.walls.isEmpty else {
      fail("empty_scan", "RoomPlan found no walls. Scan the walls and corners before tapping Finish.")
      return
    }
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let counts = ["walls": room.walls.count, "doors": room.doors.count,
                    "windows": room.windows.count, "objects": room.objects.count,
                    "openings": room.openings.count, "floors": room.floors.count]
      let summary = try requireStore().complete(id, roomData: encoder.encode(room), counts: counts) { data in
        let decoded = try JSONDecoder().decode(CapturedRoom.self, from: data)
        guard decoded.identifier == room.identifier,
              decoded.walls.count == room.walls.count,
              decoded.doors.count == room.doors.count,
              decoded.windows.count == room.windows.count,
              decoded.objects.count == room.objects.count else {
          throw NSError(domain: "RoomPlanDeviceTest.Export", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The saved room did not match the captured result."])
        }
      }
      resolve(["status": "completed", "scan": summary])
    } catch {
      fail("file_write_failed", "The room could not be saved and read back: \(error.localizedDescription)", error)
    }
  }
  #endif

  private func fail(_ code: String, _ message: String, _ underlying: Error? = nil) {
    guard pendingResult != nil else { return }
    let error = underlying ?? NSError(domain: "RoomPlanDeviceTest.Capture", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: message])
    if let id = activeID {
      do {
        try requireStore().record(id, event: "attempt_failed", state: "failed",
          details: ["message": message], error: error, errorCode: code)
      } catch {
        storageWarning = "The diagnostic log could not be updated: \(error.localizedDescription)"
      }
    }
    resolve(FlutterError(code: code, message: message, details: nil))
  }

  private func resolve(_ value: Any) {
    guard let result = pendingResult else { return }
    pendingResult = nil
    activeID = nil
    #if !targetEnvironment(simulator)
    let controller = scanner
    controller?.shutDown()
    scanner = nil
    if let controller = controller, controller.presentingViewController != nil {
      controller.dismiss(animated: true) { result(value) }
      return
    }
    #endif
    result(value)
  }

  private func share(diagnosticsOnly: Bool, result: @escaping FlutterResult) {
    guard pendingResult == nil, let presenter = presenter, presenter.presentedViewController == nil else {
      result(FlutterError(code: "busy", message: "Close the current screen before sharing.", details: nil))
      return
    }
    do {
      let store = try requireStore()
      let urls: [URL]
      if diagnosticsOnly { urls = [try store.latestDiagnosticsURL()] }
      else { urls = try store.resultURLs() }
      let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil)
      controller.popoverPresentationController?.sourceView = presenter.view
      controller.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX,
        y: presenter.view.bounds.midY, width: 1, height: 1)
      controller.completionWithItemsHandler = { _, _, _, error in
        if let error = error {
          result(FlutterError(code: "share_failed", message: error.localizedDescription, details: nil))
        } else { result(nil) }
      }
      presenter.present(controller, animated: true)
    } catch {
      result(FlutterError(code: "share_failed", message: error.localizedDescription, details: nil))
    }
  }
}
