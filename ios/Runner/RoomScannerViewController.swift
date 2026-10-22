import ARKit
import AVFoundation
import UIKit

#if !targetEnvironment(simulator)
import RoomPlan

final class RoomScannerViewController: UIViewController, RoomCaptureViewDelegate, RoomCaptureSessionDelegate {
  var onEvent: ((String, [String: Any]) -> Void)?
  var onRoom: ((CapturedRoom, [String: Any]) -> Void)?
  var onCancel: (() -> Void)?
  var onFailure: ((String, String, Error?) -> Void)?

  private let session = ARSession()
  private let writer: CaptureFrameWriter
  private var captureView: RoomCaptureView!
  private let finishButton = UIButton(type: .system)
  private let checkButton = UIButton(type: .system)
  private let cancelButton = UIButton(type: .system)
  private let statusLabel = UILabel()
  private var finishing = false
  private var resolved = false
  private var checkPass = false
  private var timeout: DispatchWorkItem?
  private var timer: Timer?
  private var processedRoom: CapturedRoom?
  private var latestLiveRoom: CapturedRoom?
  private var captureReport: [String: Any]?
  private var lastInstruction = ""
  private var lastFrameTimestamp = -Double.infinity
  private var lastFreshFrame = ProcessInfo.processInfo.systemUptime
  private var startedAt = ProcessInfo.processInfo.systemUptime

  init(root: URL, scanID: String) throws {
    writer = try CaptureFrameWriter(root: root, scanID: scanID)
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("Use init(root:scanID:).") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    isModalInPresentation = true
    let configuration = ARWorldTrackingConfiguration()
    configuration.worldAlignment = .gravity
    configuration.frameSemantics.insert(.sceneDepth)
    // RoomPlan's iOS 17 shared-session API requires a running world-tracking session first.
    session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    captureView = RoomCaptureView(frame: .zero, arSession: session)
    captureView.delegate = self
    captureView.captureSession.delegate = self
    captureView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(captureView)
    writer.onEvent = { [weak self] event, detail in self?.onEvent?(event, detail) }
    writer.onFailure = { [weak self] error in self?.fail("capture_data_failed", error.localizedDescription, error) }

    finishButton.setTitle("Finish", for: .normal)
    finishButton.titleLabel?.font = .boldSystemFont(ofSize: 18)
    finishButton.isEnabled = false
    finishButton.addTarget(self, action: #selector(finishScan), for: .touchUpInside)
    checkButton.setTitle("Record check pass", for: .normal)
    checkButton.isEnabled = false
    checkButton.addTarget(self, action: #selector(startCheckPass), for: .touchUpInside)
    cancelButton.setTitle("Cancel", for: .normal)
    cancelButton.addTarget(self, action: #selector(cancelScan), for: .touchUpInside)
    statusLabel.text = "Walk around the room and photograph its walls, floor and furniture."
    statusLabel.numberOfLines = 0
    statusLabel.textAlignment = .center
    statusLabel.font = .preferredFont(forTextStyle: .callout)
    let buttons = UIStackView(arrangedSubviews: [cancelButton, finishButton])
    buttons.distribution = .fillEqually
    let controls = UIStackView(arrangedSubviews: [statusLabel, checkButton, buttons])
    controls.axis = .vertical
    controls.spacing = 8
    controls.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(controls)
    NSLayoutConstraint.activate([
      captureView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      captureView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      captureView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      captureView.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -8),
      controls.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      controls.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
      controls.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
      buttons.heightAnchor.constraint(equalToConstant: 44),
      checkButton.heightAnchor.constraint(equalToConstant: 44)
    ])
    NotificationCenter.default.addObserver(self, selector: #selector(backgrounded),
      name: UIApplication.didEnterBackgroundNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(cameraInterrupted),
      name: AVCaptureSession.wasInterruptedNotification, object: nil)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !finishing && !resolved else { return }
    onEvent?("capture_started", ["depth_source": "sceneDepth", "target_frames_per_second": 3])
    guard !resolved else { return }
    captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
    // Preserve the existing ARSession and its tracking origin if RoomPlan changes frame semantics.
    if let active = session.configuration as? ARWorldTrackingConfiguration,
       !active.frameSemantics.contains(.sceneDepth) {
      active.frameSemantics.insert(.sceneDepth)
      session.run(active, options: [])
      onEvent?("scene_depth_semantics_restored", [:])
    }
    startedAt = ProcessInfo.processInfo.systemUptime
    lastFreshFrame = startedAt
    // Poll currentFrame rather than replacing RoomPlan's private ARSession delegate.
    // Every saved RGB/depth/pose record is taken from exactly the same ARFrame.
    timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.observeFrame() }
  }

  deinit { timeout?.cancel(); timer?.invalidate(); NotificationCenter.default.removeObserver(self) }

  private func observeFrame() {
    guard !finishing && !resolved else { return }
    let now = ProcessInfo.processInfo.systemUptime
    if let frame = session.currentFrame, frame.timestamp > lastFrameTimestamp {
      lastFrameTimestamp = frame.timestamp
      lastFreshFrame = now
      writer.observe(frame)
    }
    let stats = writer.stats()
    if now - lastFreshFrame > 15 {
      fail("capture_interrupted", "ARKit stopped delivering fresh camera frames. Start a new scan.", nil); return
    }
    if stats.train == 0 && now - startedAt > 20 {
      fail("depth_unavailable", "No usable RGB/LiDAR pairs arrived within 20 seconds. Check lighting, tracking and LiDAR support, then retry.", nil); return
    }
    checkButton.isEnabled = !checkPass && stats.train >= CaptureFormat.minimumTrainFrames
    finishButton.isEnabled = checkPass && stats.validation >= CaptureFormat.minimumValidationFrames
    if checkPass {
      statusLabel.text = "Check pass: \(stats.validation) frames. Walk a short route around the room, then Finish."
    } else {
      statusLabel.text = "Room capture: \(stats.train) images with depth. Cover the room, then tap Record check pass."
    }
  }

  @objc private func startCheckPass() {
    guard !finishing && !resolved && !checkPass else { return }
    checkPass = true
    checkButton.isEnabled = false
    checkButton.setTitle("Recording check pass", for: .normal)
    writer.beginValidation()
    onEvent?("validation_pass_started", ["mapping_shared_with_training": true])
  }

  @objc private func finishScan() {
    guard !finishing && !resolved else { return }
    do {
      guard let liveRoom = latestLiveRoom else { throw CaptureFormat.error("No live RoomPlan geometry is available. Continue scanning the walls.") }
      let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try writer.saveLiveRoom(encoder.encode(liveRoom))
    } catch { fail("file_write_failed", error.localizedDescription, error); return }
    finishing = true
    timer?.invalidate()
    finishButton.isEnabled = false
    checkButton.isEnabled = false
    statusLabel.text = "Finishing the room and saving images and depth..."
    onEvent?("finish_requested", [:])
    guard !resolved else { return }
    writer.finish { [weak self] result in
      guard let self = self, !self.resolved else { return }
      switch result {
      case .success(let report): self.captureReport = report; self.completeIfReady()
      case .failure(let error): self.fail("capture_data_failed", error.localizedDescription, error)
      }
    }
    let work = DispatchWorkItem { [weak self] in
      self?.fail("processing_timeout", "Capture processing did not finish within 90 seconds. Please retry.", nil)
    }
    timeout = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: work)
    captureView.captureSession.stop()
  }

  private func completeIfReady() {
    guard !resolved, let room = processedRoom, let report = captureReport else { return }
    resolved = true
    timeout?.cancel()
    onRoom?(room, report)
  }

  @objc private func cancelScan() {
    guard !resolved else { return }
    shutDown()
    writer.discard { [weak self] in self?.onCancel?() }
  }

  @objc private func backgrounded() {
    fail("capture_interrupted", "Capture was interrupted when the app went to the background. Start a new scan.", nil)
  }

  @objc private func cameraInterrupted() { fail("capture_interrupted", "The camera was interrupted. Start a new scan.", nil) }

  func shutDown() {
    resolved = true; writer.stop(); timer?.invalidate(); timeout?.cancel()
    captureView?.captureSession.stop(); session.pause()
  }

  private func fail(_ code: String, _ message: String, _ error: Error?) {
    guard !resolved else { return }; shutDown()
    writer.discard { [weak self] in self?.onFailure?(code, message, error) }
  }

  func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
    if let error = error {
      DispatchQueue.main.async { [weak self] in self?.fail("capture_failed", error.localizedDescription, error) }
      return false
    }
    return true
  }

  func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self, !self.resolved else { return }
      if let error = error { self.fail("capture_failed", error.localizedDescription, error); return }
      guard self.finishing else { self.fail("capture_interrupted", "Capture ended before Finish. Start a new scan.", nil); return }
      self.processedRoom = processedResult; self.completeIfReady()
    }
  }

  func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self, !self.resolved else { return }
      if let error = error { self.fail("capture_failed", error.localizedDescription, error) }
      else if !self.finishing { self.fail("capture_interrupted", "Capture stopped unexpectedly.", nil) }
    }
  }

  func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self, !self.finishing, !self.resolved else { return }
      self.latestLiveRoom = room
    }
  }

  func captureSession(_ session: RoomCaptureSession, didAdd room: CapturedRoom) {
    captureSession(session, didUpdate: room)
  }

  func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
    let text = String(describing: instruction)
    DispatchQueue.main.async { [weak self] in
      guard let self = self, !self.resolved, self.lastInstruction != text else { return }
      self.lastInstruction = text; self.onEvent?("roomplan_instruction", ["instruction": text])
    }
  }
}
#endif
