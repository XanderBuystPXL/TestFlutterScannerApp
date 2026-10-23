import ARKit
import AVFoundation
import UIKit
import simd

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
  private let coverageMap = CoverageMapView()
  private let progressView = UIProgressView(progressViewStyle: .default)
  private let guidance = CaptureGuidance()
  private let guidanceQueue = DispatchQueue(label: "be.aproxx.capture.guidance", qos: .userInitiated)
  private var guidanceSnapshot: GuidanceSnapshot?
  private var coaching: String?
  private var coachingBlocksFinish = false
  private var trackingPrompt: String?
  private var qualityPrompt: String?
  private var photoNeedsLight = false
  private var movingTooFast = false
  private var finishingWarning = ""
  private var lastSurfaceUpdate = -Double.infinity
  private var warnedAboutCoverage = false
  private let cancelButton = UIButton(type: .system)
  private let statusLabel = UILabel()
  private var finishing = false
  private var resolved = false
  private var timeout: DispatchWorkItem?
  private var timer: Timer?
  private var processedRoom: CapturedRoom?
  private var latestLiveRoom: CapturedRoom?
  private var captureReport: [String: Any]?
  private var lastInstruction = ""
  private var lastFrameTimestamp = -Double.infinity
  private var lastFreshFrame = ProcessInfo.processInfo.systemUptime
  private var startedAt = ProcessInfo.processInfo.systemUptime

  private var captureConditionMessage: String? {
    if let trackingPrompt = trackingPrompt { return trackingPrompt }
    if movingTooFast { return "Move more slowly. Photos pause during fast turns or movement." }
    if coachingBlocksFinish { return coaching }
    if photoNeedsLight { return qualityPrompt }
    return nil
  }

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
    writer.onQualityHint = { [weak self] hint, needsLight in
      self?.qualityPrompt = hint; self?.photoNeedsLight = needsLight
    }
    writer.onMotionHint = { [weak self] value in self?.movingTooFast = value }
    writer.onAccepted = { [weak self] frame in
      guard let self = self else { return }
      self.guidanceQueue.async { [weak self] in
        guard let self = self else { return }
        self.guidance.add(frame)
        let snapshot = self.guidance.snapshot()
        DispatchQueue.main.async { [weak self] in self?.showGuidance(snapshot) }
      }
    }

    finishButton.setTitle("Finish", for: .normal)
    finishButton.titleLabel?.font = .boldSystemFont(ofSize: 18)
    finishButton.isEnabled = false
    finishButton.addTarget(self, action: #selector(finishScan), for: .touchUpInside)
    cancelButton.setTitle("Cancel", for: .normal)
    cancelButton.addTarget(self, action: #selector(cancelScan), for: .touchUpInside)
    statusLabel.text = "Walk around the room and photograph its walls, floor and furniture."
    statusLabel.numberOfLines = 0
    statusLabel.textAlignment = .center
    statusLabel.font = .preferredFont(forTextStyle: .callout)
    let buttons = UIStackView(arrangedSubviews: [cancelButton, finishButton])
    buttons.distribution = .fillEqually
    let controls = UIStackView(arrangedSubviews: [statusLabel, progressView, buttons])
    controls.axis = .vertical
    controls.spacing = 8
    controls.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(controls)
    coverageMap.translatesAutoresizingMaskIntoConstraints = false
    coverageMap.isAccessibilityElement = true
    coverageMap.accessibilityLabel = "Coverage map: green areas have overlapping views; orange areas need more views."
    view.addSubview(coverageMap)
    NSLayoutConstraint.activate([
      captureView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      captureView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      captureView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      captureView.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -8),
      controls.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      controls.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
      controls.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
      buttons.heightAnchor.constraint(equalToConstant: 44),
      coverageMap.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
      coverageMap.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
      coverageMap.widthAnchor.constraint(equalToConstant: 160),
      coverageMap.heightAnchor.constraint(equalToConstant: 180)
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
      switch frame.camera.trackingState {
      case .normal: trackingPrompt = nil
      default: trackingPrompt = "Hold the phone steady and point at a textured area until tracking recovers."
      }
      writer.observe(frame)
    }
    let stats = writer.stats()
    if now - lastFreshFrame > 15 {
      fail("capture_interrupted", "ARKit stopped delivering fresh camera frames. Start a new scan.", nil); return
    }
    if stats.train == 0 && now - startedAt > 20 {
      fail("depth_unavailable", "No usable RGB/LiDAR pairs arrived within 20 seconds. Check lighting, tracking and LiDAR support, then retry.", nil); return
    }
    finishButton.isEnabled = stats.train >= CaptureGuidance.minimumFrames
    if let snapshot = guidanceSnapshot { showGuidance(snapshot) }
  }

  private func showGuidance(_ snapshot: GuidanceSnapshot) {
    guard !finishing && !resolved else { return }
    guidanceSnapshot = snapshot
    let advisory = snapshot.ready ? (qualityPrompt ?? coaching) : nil
    statusLabel.text = captureConditionMessage ?? advisory ?? snapshot.message
    progressView.progress = Float(snapshot.progress)
    progressView.accessibilityLabel = "Scan guidance progress for detected walls and floor"
    coverageMap.snapshot = snapshot
    // One capture action: Start launches every stream; Finish saves their shared package.
    // Quality warnings belong in guidance/the finish review, not another recording stage.
    finishButton.setTitle("Finish", for: .normal)
  }

  @objc private func finishScan() {
    guard !finishing && !resolved else { return }
    guard guidanceSnapshot?.ready == true && captureConditionMessage == nil else {
      let canSave = (guidanceSnapshot?.report["camera_span_metres"] as? Double ?? 0) >= CaptureFormat.minimumCameraSpanMetres
      let explanation = canSave ? "You can keep scanning, or save the current files with a coverage warning. Reconstruction quality is not verified." : "Move to another position before saving. Your current views remain in this scan."
      let reason = captureConditionMessage ?? guidanceSnapshot?.message ?? "Continue scanning the walls and floor."
      let alert = UIAlertController(title: "More views recommended", message: reason + "\n\n" + explanation, preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: "Keep scanning", style: .cancel))
      let save = UIAlertAction(title: "Save with warning", style: .default) { [weak self] _ in
        guard let self = self else { return }; self.warnedAboutCoverage = true; self.stopAndSave()
      }
      if canSave { alert.addAction(save) }
      present(alert, animated: true); return
    }
    stopAndSave()
  }

  private func stopAndSave() {
    guard !finishing && !resolved else { return }
    do {
      guard let liveRoom = latestLiveRoom else { throw CaptureFormat.error("No live RoomPlan geometry is available. Continue scanning the walls.") }
      let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try writer.saveLiveRoom(encoder.encode(liveRoom))
      let surfaces = Self.guidanceSurfaces(liveRoom)
      guidanceQueue.async { [weak self] in self?.guidance.setSurfaces(surfaces) }
    } catch { fail("file_write_failed", error.localizedDescription, error); return }
    finishingWarning = captureConditionMessage ?? ""
    finishing = true
    timer?.invalidate()
    finishButton.isEnabled = false
    statusLabel.text = "Finishing the room and saving images and depth..."
    onEvent?("finish_requested", [:])
    guard !resolved else { return }
    writer.finish { [weak self] result in
      guard let self = self, !self.resolved else { return }
      switch result {
      case .success(let report):
        self.guidanceQueue.async { [weak self] in
          guard let self = self else { return }
          let quality = self.guidance.snapshot().report
          DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.resolved else { return }
            var assessedReport = report
            assessedReport["guidance"] = quality
            assessedReport["coverage_warning_acknowledged"] = self.warnedAboutCoverage
            assessedReport["image_quality_warning_at_finish"] = self.finishingWarning
            self.onEvent?("coverage_assessed", quality)
            self.captureReport = assessedReport; self.completeIfReady()
          }
        }
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
      let now = ProcessInfo.processInfo.systemUptime
      guard now - self.lastSurfaceUpdate >= 1 else { return }
      self.lastSurfaceUpdate = now
      let surfaces = Self.guidanceSurfaces(room)
      self.guidanceQueue.async { [weak self] in
        guard let self = self else { return }; self.guidance.setSurfaces(surfaces)
        let snapshot = self.guidance.snapshot()
        DispatchQueue.main.async { [weak self] in self?.showGuidance(snapshot) }
      }
    }
  }

  private static func guidanceSurfaces(_ room: CapturedRoom) -> [GuidanceSurface] {
      var surfaces: [GuidanceSurface] = []
      for (kind, values) in [("wall", room.walls), ("floor", room.floors)] {
        for (index, surface) in values.enumerated() {
          let t = surface.transform
          let matrix = simd_double4x4(columns: (
            SIMD4(Double(t[0].x), Double(t[0].y), Double(t[0].z), Double(t[0].w)),
            SIMD4(Double(t[1].x), Double(t[1].y), Double(t[1].z), Double(t[1].w)),
            SIMD4(Double(t[2].x), Double(t[2].y), Double(t[2].z), Double(t[2].w)),
            SIMD4(Double(t[3].x), Double(t[3].y), Double(t[3].z), Double(t[3].w))))
          surfaces.append(GuidanceSurface(id: surface.identifier.uuidString, kind: kind,
            label: "\(kind.capitalized) \(index + 1)", transform: matrix,
            size: SIMD3(Double(surface.dimensions.x), Double(surface.dimensions.y), Double(surface.dimensions.z))))
        }
      }
      return surfaces
  }

  func captureSession(_ session: RoomCaptureSession, didAdd room: CapturedRoom) {
    captureSession(session, didUpdate: room)
  }

  func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
    let text = String(describing: instruction)
    DispatchQueue.main.async { [weak self] in
      guard let self = self, !self.resolved, self.lastInstruction != text else { return }
      self.lastInstruction = text
      self.coachingBlocksFinish = instruction != .normal && instruction != .lowTexture
      switch instruction {
      case .normal: self.coaching = nil
      case .slowDown: self.coaching = "Move more slowly so the pictures stay clear."
      case .turnOnLight: self.coaching = "Increase the room lighting before continuing."
      case .moveCloseToWall: self.coaching = "Move closer to the wall."
      case .moveAwayFromWall: self.coaching = "Step further away from the wall."
      case .lowTexture: self.coaching = "Point towards a corner or furniture to help tracking."
      @unknown default: self.coaching = nil
      }
      self.onEvent?("roomplan_instruction", ["instruction": text])
    }
  }
}

private final class CoverageMapView: UIView {
  var snapshot: GuidanceSnapshot? { didSet { setNeedsDisplay() } }
  override func draw(_ rect: CGRect) {
    guard let context = UIGraphicsGetCurrentContext() else { return }
    UIColor.black.withAlphaComponent(0.78).setFill(); UIBezierPath(roundedRect: rect, cornerRadius: 12).fill()
    let font: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: UIColor.white]
    ("Walls + floor estimate" as NSString).draw(at: CGPoint(x: 8, y: 6), withAttributes: font)
    ("Green: seen   Orange: revisit" as NSString).draw(at: CGPoint(x: 8, y: rect.height-18), withAttributes: font)
    guard let snapshot = snapshot else { return }
    let points = snapshot.surfaces.flatMap { $0.targets }
    guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
          let minZ = points.map(\.z).min(), let maxZ = points.map(\.z).max() else { return }
    let scale = min((Double(rect.width)-24) / max(1, maxX-minX), (Double(rect.height)-60) / max(1, maxZ-minZ))
    func project(_ p: SIMD3<Double>) -> CGPoint {
      CGPoint(x: 12 + (p.x-minX)*scale, y: 30 + (p.z-minZ)*scale)
    }
    for surface in snapshot.surfaces {
      for (index, point) in surface.targets.enumerated() {
        let color: UIColor = snapshot.coveredSamples[surface.id]?.contains(index) == true ? .systemGreen : .systemOrange
        context.setFillColor(color.withAlphaComponent(surface.kind == "floor" ? 0.45 : 1).cgColor)
        let p = project(point); context.fillEllipse(in: CGRect(x: p.x-2, y: p.y-2, width: 4, height: 4))
      }
      if surface.id == snapshot.missingID, let point = surface.targets.first {
        (surface.label as NSString).draw(at: project(point), withAttributes: font)
      }
    }
    if let camera = snapshot.camera {
      let position = SIMD3(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)
      let forward = position - SIMD3(camera.columns.2.x, camera.columns.2.y, camera.columns.2.z)*0.35
      let p = project(position), q = project(forward)
      context.setFillColor(UIColor.systemCyan.cgColor); context.fillEllipse(in: CGRect(x: p.x-4, y: p.y-4, width: 8, height: 8))
      context.setStrokeColor(UIColor.systemCyan.cgColor); context.setLineWidth(3)
      context.move(to: p); context.addLine(to: q); context.strokePath()
    }
  }
}
#endif
