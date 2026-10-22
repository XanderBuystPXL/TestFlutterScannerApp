import ARKit
import CoreImage
import Foundation
import ImageIO

final class CaptureFrameWriter {
  private let root: URL
  private let scanID: String
  private let queue = DispatchQueue(label: "be.aproxx.capture.writer", qos: .userInitiated)
  private let slots = DispatchSemaphore(value: 2)
  private let lock = NSLock()
  private let context = CIContext(options: [.cacheIntermediates: false])
  private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
  private var role = "train"
  private var accepting = true
  private var lastSelectedTime = -Double.infinity
  private var nextFrame = 1
  private var trainCount = 0
  private var validationCount = 0
  private var missingDepth = 0
  private var limitedTracking = 0
  private var busyDrops = 0
  private var failure: Error?
  private var positions: [[Double]] = []
  private var firstTimestamp: Double?
  private var lastTimestamp: Double?
  private var lastTracking = ""
  private var timeOrigin: Double?
  private var jsonl: FileHandle?
  var onFailure: ((Error) -> Void)?
  var onEvent: ((String, [String: Any]) -> Void)?

  init(root: URL, scanID: String) throws {
    self.root = root
    self.scanID = scanID
    for name in ["rgb", "depth", "confidence", "roomplan"] {
      try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    let url = root.appendingPathComponent("frames.jsonl")
    guard FileManager.default.createFile(atPath: url.path, contents: nil,
      attributes: [.protectionKey: FileProtectionType.complete]) else {
      throw CaptureFormat.error("Could not create the frame log. Check available storage.")
    }
    jsonl = try FileHandle(forWritingTo: url)
  }

  deinit { try? jsonl?.close() }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock(); defer { lock.unlock() }; return body()
  }

  func stats() -> (train: Int, validation: Int, missing: Int) {
    locked { (trainCount, validationCount, missingDepth) }
  }

  func beginValidation() { locked { role = "validation" } }
  func stop() { locked { accepting = false } }

  func saveLiveRoom(_ data: Data) throws {
    try data.write(to: root.appendingPathComponent("roomplan/live-room.json"), options: [.atomic, .completeFileProtection])
  }

  func discard(_ completion: @escaping () -> Void) {
    stop()
    queue.async { [self] in
      try? jsonl?.close(); jsonl = nil
      DispatchQueue.main.async(execute: completion)
    }
  }

  private static func matrix(_ value: simd_float3x3) -> [[Double]] {
    CaptureFormat.rows((0..<3).map { column in (0..<3).map { Double(value[column][$0]) } })
  }

  private static func matrix(_ value: simd_float4x4) -> [[Double]] {
    CaptureFormat.rows((0..<4).map { column in (0..<4).map { Double(value[column][$0]) } })
  }

  func observe(_ frame: ARFrame) {
    // Only this call reads ARFrame. The bounded writer retains its pixel buffers, never ARFrame itself.
    if timeOrigin == nil { timeOrigin = frame.timestamp }
    let timestamp = frame.timestamp - timeOrigin!
    let state: String
    switch frame.camera.trackingState {
    case .normal: state = "normal"
    case .notAvailable: state = "not_available"
    case .limited(let reason): state = "limited_\(String(describing: reason))"
    }
    let change = locked { () -> Bool in
      if state == lastTracking { return false }; lastTracking = state; return true
    }
    if change { onEvent?("tracking_state", ["state": state, "timestamp_seconds": timestamp]) }
    if state == "limited_relocalizing" {
      reportFailure(CaptureFormat.error("ARKit is relocalising. Start a new scan to avoid mixing coordinate spaces.")); return
    }
    guard state == "normal" else { locked { limitedTracking += 1 }; return }
    guard let depth = frame.sceneDepth, let confidence = depth.confidenceMap else {
      locked { missingDepth += 1 }; return
    }
    let selected: (Int, String)? = locked {
      guard accepting, failure == nil, timestamp - lastSelectedTime >= 1.0 / 3.0 else { return nil }
      guard slots.wait(timeout: .now()) == .success else { busyDrops += 1; return nil }
      lastSelectedTime = timestamp
      let id = nextFrame; nextFrame += 1
      return (id, role)
    }
    guard let (index, frameRole) = selected else { return }
    if index > 1800 {
      slots.signal(); reportFailure(CaptureFormat.error("The capture reached 1800 frames. Use a shorter single-room scan.")); return
    }
    let image = frame.capturedImage
    let depthBuffer = depth.depthMap
    let confidenceBuffer = confidence
    let intrinsics = Self.matrix(frame.camera.intrinsics)
    let pose = Self.matrix(frame.camera.transform)
    let resolution = frame.camera.imageResolution
    let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
    guard width == Int(resolution.width), height == Int(resolution.height),
          intrinsics.flatMap({ $0 }).allSatisfy({ $0.isFinite }),
          pose.flatMap({ $0 }).allSatisfy({ $0.isFinite }) else {
      slots.signal(); reportFailure(CaptureFormat.error("Camera calibration does not match the captured image.")); return
    }
    queue.async { [self] in
      defer { slots.signal() }
      guard locked({ failure == nil }) else { return }
      autoreleasepool {
        do {
          let name = String(format: "frame-%06d", index)
          let rgbPath = "rgb/\(name).jpg", depthPath = "depth/\(name).f32", confidencePath = "confidence/\(name).u8"
          let options: [CIImageRepresentationOption: Any] = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.95]
          guard let jpeg = context.jpegRepresentation(of: CIImage(cvPixelBuffer: image), colorSpace: colorSpace, options: options) else {
            throw CaptureFormat.error("Could not encode the camera image as sRGB JPEG.")
          }
          let dw = CVPixelBufferGetWidth(depthBuffer), dh = CVPixelBufferGetHeight(depthBuffer)
          guard CVPixelBufferGetPixelFormatType(depthBuffer) == kCVPixelFormatType_DepthFloat32,
                CVPixelBufferGetPixelFormatType(confidenceBuffer) == kCVPixelFormatType_OneComponent8,
                CVPixelBufferGetWidth(confidenceBuffer) == dw, CVPixelBufferGetHeight(confidenceBuffer) == dh else {
            throw CaptureFormat.error("Unexpected LiDAR depth/confidence pixel-buffer format.")
          }
          let packedDepth = try packed(depthBuffer, bytesPerPixel: 4)
          let packedConfidence = try packed(confidenceBuffer, bytesPerPixel: 1)
          let validFraction = packedDepth.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Double in
            var valid = 0
            for pixel in 0..<(dw * dh) {
              let z = Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: pixel * 4, as: UInt32.self)))
              if z.isFinite && z > 0.10 && z < 12 && packedConfidence[pixel] >= 1 { valid += 1 }
            }
            return Double(valid) / Double(dw * dh)
          }
          guard validFraction >= 0.02 else { locked { missingDepth += 1 }; return }
          try jpeg.write(to: root.appendingPathComponent(rgbPath), options: [.atomic, .completeFileProtection])
          try packedDepth.write(to: root.appendingPathComponent(depthPath), options: [.atomic, .completeFileProtection])
          try packedConfidence.write(to: root.appendingPathComponent(confidencePath), options: [.atomic, .completeFileProtection])
          var depthK = intrinsics
          for column in 0..<3 {
            depthK[0][column] *= Double(dw) / Double(width)
            depthK[1][column] *= Double(dh) / Double(height)
          }
          let row: [String: Any] = [
            "frame_id": name, "room_id": scanID, "coordinate_space_id": scanID,
            "segment_id": frameRole, "role": frameRole, "timestamp_seconds": timestamp,
            "rgb_path": rgbPath, "rgb_size_px": [width, height], "intrinsics": intrinsics,
            "camera_to_world": pose, "tracking_state": "normal", "image_transform": "identity",
            "depth_valid_fraction": validFraction,
            "depth": ["path": depthPath, "width": dw, "height": dh, "encoding": "float32-le",
              "units": "metres", "convention": "positive_camera_z", "source": "sceneDepth",
              "timestamp_seconds": timestamp, "intrinsics": depthK, "rgb_mapping": "scaled_intrinsics_no_crop"],
            "confidence": ["path": confidencePath, "width": dw, "height": dh, "encoding": "uint8",
              "labels": ["0": "low", "1": "medium", "2": "high"]]
          ]
          let line = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data([10])
          guard let log = jsonl else { throw CaptureFormat.error("The frame log was closed before capture finished.") }
          try log.write(contentsOf: line)
          locked {
            if frameRole == "train" {
              trainCount += 1; positions.append([pose[0][3], pose[1][3], pose[2][3]])
            } else { validationCount += 1 }
            if firstTimestamp == nil { firstTimestamp = timestamp }
            lastTimestamp = timestamp
          }
        } catch { reportFailure(error) }
      }
    }
  }

  private func packed(_ buffer: CVPixelBuffer, bytesPerPixel: Int) throws -> Data {
    guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
      throw CaptureFormat.error("Could not lock a LiDAR pixel buffer.")
    }
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let pointer = CVPixelBufferGetBaseAddress(buffer) else { throw CaptureFormat.error("Empty LiDAR pixel buffer.") }
    let stride = CVPixelBufferGetBytesPerRow(buffer), height = CVPixelBufferGetHeight(buffer)
    return try CaptureFormat.packRows(Data(bytes: pointer, count: stride * height),
      rowBytes: CVPixelBufferGetWidth(buffer) * bytesPerPixel, stride: stride, height: height)
  }

  private func reportFailure(_ error: Error) {
    let first = locked { () -> Bool in
      guard failure == nil else { return false }; failure = error; accepting = false; return true
    }
    if first { DispatchQueue.main.async { [weak self] in self?.onFailure?(error) } }
  }

  func finish(_ completion: @escaping (Result<[String: Any], Error>) -> Void) {
    stop()
    queue.async { [self] in
      do {
        try jsonl?.synchronize(); try jsonl?.close(); jsonl = nil
        if let error = locked({ failure }) { throw error }
        let report: [String: Any] = locked {
          var span = 0.0
          if !positions.isEmpty {
            let extents = (0..<3).map { axis in positions.map { $0[axis] }.max()! - positions.map { $0[axis] }.min()! }
            span = sqrt(extents.reduce(0) { $0 + $1 * $1 })
          }
          return ["train_frames": trainCount, "validation_frames": validationCount,
            "saved_frames": trainCount + validationCount, "missing_depth_observations": missingDepth,
            "limited_tracking_observations": limitedTracking, "writer_busy_drops": busyDrops,
            "training_camera_span_metres": span, "target_frames_per_second": 3,
            "jpeg_quality": 0.95, "colour_space": "sRGB", "image_transform": "identity",
            "depth_source": "sceneDepth", "first_timestamp_seconds": firstTimestamp ?? 0,
            "last_timestamp_seconds": lastTimestamp ?? 0,
            "minimum_train_frames": CaptureFormat.minimumTrainFrames,
            "minimum_validation_frames": CaptureFormat.minimumValidationFrames]
        }
        try CaptureFormat.validateCaptureReport(report)
        DispatchQueue.main.async { completion(.success(report)) }
      } catch { DispatchQueue.main.async { completion(.failure(error)) } }
    }
  }
}
