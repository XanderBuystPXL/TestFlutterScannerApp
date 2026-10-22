import AVFoundation
import UIKit

#if !targetEnvironment(simulator)
import RoomPlan

final class RoomScannerViewController: UIViewController, RoomCaptureViewDelegate, RoomCaptureSessionDelegate {
  var onEvent: ((String, [String: Any]) -> Void)?
  var onRoom: ((CapturedRoom) -> Void)?
  var onCancel: (() -> Void)?
  var onFailure: ((String, String, Error?) -> Void)?

  private let captureView = RoomCaptureView(frame: .zero)
  private let finishButton = UIButton(type: .system)
  private let cancelButton = UIButton(type: .system)
  private let statusLabel = UILabel()
  private var finishing = false
  private var resolved = false
  private var timeout: DispatchWorkItem?
  private var lastInstruction = ""

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    isModalInPresentation = true
    captureView.delegate = self
    captureView.captureSession.delegate = self
    captureView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(captureView)

    finishButton.setTitle("Finish", for: .normal)
    finishButton.titleLabel?.font = .boldSystemFont(ofSize: 18)
    finishButton.addTarget(self, action: #selector(finishScan), for: .touchUpInside)
    cancelButton.setTitle("Cancel", for: .normal)
    cancelButton.addTarget(self, action: #selector(cancelScan), for: .touchUpInside)
    statusLabel.text = "Move slowly and scan the walls and corners."
    statusLabel.numberOfLines = 0
    statusLabel.textAlignment = .center
    statusLabel.font = .preferredFont(forTextStyle: .callout)
    statusLabel.accessibilityTraits = .updatesFrequently
    let buttons = UIStackView(arrangedSubviews: [cancelButton, finishButton])
    buttons.axis = .horizontal
    buttons.distribution = .fillEqually
    let controls = UIStackView(arrangedSubviews: [statusLabel, buttons])
    controls.axis = .vertical
    controls.spacing = 12
    controls.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(controls)
    NSLayoutConstraint.activate([
      captureView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      captureView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      captureView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      captureView.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -8),
      controls.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
      controls.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
      controls.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
      buttons.heightAnchor.constraint(equalToConstant: 48)
    ])
    NotificationCenter.default.addObserver(self, selector: #selector(backgrounded),
      name: UIApplication.didEnterBackgroundNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(cameraInterrupted),
      name: AVCaptureSession.wasInterruptedNotification, object: nil)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !finishing && !resolved else { return }
    onEvent?("capture_started", [:])
    guard !resolved else { return }
    captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
  }

  deinit {
    timeout?.cancel()
    NotificationCenter.default.removeObserver(self)
  }

  @objc private func finishScan() {
    guard !finishing && !resolved else { return }
    finishing = true
    finishButton.isEnabled = false
    statusLabel.text = "Processing room…"
    onEvent?("finish_requested", [:])
    guard !resolved else { return }
    let work = DispatchWorkItem { [weak self] in
      self?.fail("processing_timeout", "RoomPlan did not finish within 90 seconds. Please retry.", nil)
    }
    timeout = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: work)
    captureView.captureSession.stop()
  }

  @objc private func cancelScan() {
    guard !resolved else { return }
    resolved = true
    timeout?.cancel()
    captureView.captureSession.stop()
    onCancel?()
  }

  @objc private func backgrounded() {
    fail("capture_interrupted", "Scanning was interrupted when the app went to the background. Start a new scan.", nil)
  }

  @objc private func cameraInterrupted() {
    fail("capture_interrupted", "Camera capture was interrupted. Start a new scan.", nil)
  }

  func shutDown() {
    resolved = true
    timeout?.cancel()
    captureView.captureSession.stop()
  }

  private func fail(_ code: String, _ message: String, _ error: Error?) {
    guard !resolved else { return }
    resolved = true
    timeout?.cancel()
    captureView.captureSession.stop()
    onFailure?(code, message, error)
  }

  func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
    // RoomPlan calls this on its callback queue. UI/file work is dispatched to main.
    if let error = error {
      DispatchQueue.main.async { [weak self] in
        self?.fail("capture_failed", "RoomPlan could not process the scan: \(error.localizedDescription)", error)
      }
      return false
    }
    return true
  }

  func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self, !self.resolved else { return }
      if let error = error {
        self.fail("capture_failed", "RoomPlan could not finish: \(error.localizedDescription)", error)
        return
      }
      guard self.finishing else {
        self.fail("capture_interrupted", "Capture ended before Finish was selected. Start a new scan.", nil)
        return
      }
      self.resolved = true
      self.timeout?.cancel()
      self.onRoom?(processedResult)
    }
  }

  func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self, !self.resolved else { return }
      if let error = error {
        self.fail("capture_failed", "Room capture failed: \(error.localizedDescription)", error)
      } else if !self.finishing {
        self.fail("capture_interrupted", "Capture stopped unexpectedly. Start a new scan.", nil)
      }
    }
  }

  func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
    let text = String(describing: instruction)
    DispatchQueue.main.async { [weak self] in
      guard let self = self, !self.resolved, self.lastInstruction != text else { return }
      self.lastInstruction = text
      self.onEvent?("roomplan_instruction", ["instruction": text])
    }
  }
}
#endif
