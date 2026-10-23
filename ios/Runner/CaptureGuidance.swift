import Foundation
import simd

/// Adapted from the supplied 0.2.2 patch. Motion is a blur-risk proxy, not a blur measurement.
struct CaptureMotionGate {
  static let maximumRotationDegreesPerSecond = 60.0
  static let maximumSpeedMetresPerSecond = 1.0
  private var previous: (time: Double, pose: simd_float4x4)?

  mutating func reset() { previous = nil }

  mutating func isSteady(time: Double, pose: simd_float4x4) -> Bool {
    defer { previous = (time, pose) }
    guard let last = previous, time > last.time, time - last.time < 0.5 else { return true }
    let dt = time - last.time
    let rotation = Self.rotationDegrees(from: last.pose, to: pose) / dt
    let moved = pose.columns.3 - last.pose.columns.3
    let speed = Double(simd_length(SIMD3<Float>(moved.x, moved.y, moved.z))) / dt
    return rotation.isFinite && speed.isFinite && rotation <= Self.maximumRotationDegreesPerSecond && speed <= Self.maximumSpeedMetresPerSecond
  }

  static func rotationDegrees(from a: simd_float4x4, to b: simd_float4x4) -> Double {
    func rotation(_ m: simd_float4x4) -> simd_float3x3 {
      simd_float3x3(columns: (SIMD3(m[0].x, m[0].y, m[0].z), SIMD3(m[1].x, m[1].y, m[1].z), SIMD3(m[2].x, m[2].y, m[2].z)))
    }
    let relative = simd_transpose(rotation(a)) * rotation(b)
    let trace = Double(relative[0].x + relative[1].y + relative[2].z)
    return acos(max(-1, min(1, (trace - 1) / 2))) * 180 / .pi
  }
}

/// Engineering coverage estimates for observed surfaces, never a guarantee of splat quality.
struct GuidanceSurface {
  let id: String
  let kind: String
  let label: String
  let transform: simd_double4x4
  let size: SIMD3<Double>

  var targets: [SIMD3<Double>] {
    var result: [SIMD3<Double>] = []
    // Sample the interior, avoiding wall boundaries/corners with unreliable depth.
    for y in 0..<4 { for x in 0..<6 {
      let local = SIMD4<Double>((Double(x) / 5 - 0.5) * size.x * 0.85,
                               (Double(y) / 3 - 0.5) * size.y * 0.85, 0, 1)
      let world = transform * local
      result.append(SIMD3(world.x, world.y, world.z))
    } }
    return result
  }
}

struct GuidanceFrame {
  let timestamp: Double
  let camera: simd_double4x4 // ARKit right/up/back camera, metric world
  let width: Int
  let height: Int
  let fx: Double
  let fy: Double
  let cx: Double
  let cy: Double
  let depth: [Float]
  let confidence: [UInt8]
  let brightness: Double
  let detail: Double

  var position: SIMD3<Double> { SIMD3(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z) }

  func sees(_ point: SIMD3<Double>, view: simd_double4x4? = nil) -> Bool {
    let local = (view ?? camera.inverse) * SIMD4(point.x, point.y, point.z, 1)
    let z = -local.z
    guard z > 0.15 && z < 8 && local.x.isFinite && local.y.isFinite else { return false }
    let imageX = fx * local.x / z + cx, imageY = -fy * local.y / z + cy
    guard imageX.isFinite && imageY.isFinite && imageX >= 0 && imageX < Double(width) &&
          imageY >= 0 && imageY < Double(height) else { return false }
    let u = Int(imageX.rounded()), v = Int(imageY.rounded())
    guard u >= 1 && u < width - 1 && v >= 1 && v < height - 1 else { return false }
    let index = v * width + u
    guard index < depth.count, index < confidence.count, confidence[index] >= 1 else { return false }
    let measured = Double(depth[index])
    // Depth agreement prevents crediting a wall hidden behind furniture.
    return measured.isFinite && abs(measured - z) <= max(0.15, z * 0.04)
  }
}

struct GuidanceSnapshot {
  let ready: Bool
  let message: String
  let progress: Double
  let surfaces: [GuidanceSurface]
  let fractions: [String: Double]
  let coveredSamples: [String: Set<Int>]
  let missingID: String?
  let camera: simd_double4x4?
  let report: [String: Any]
}

/// Owned by one serial queue. Retains bounded, subsampled depth, not ARFrames or RGB.
final class CaptureGuidance {
  static let minimumFrames = 30
  static let minimumSpan = 0.50
  static let wallThreshold = 0.40
  static let floorThreshold = 0.20
  static let viewpointSeparation = 0.20
  private(set) var surfaces: [GuidanceSurface] = []
  private var history: [GuidanceFrame] = []
  private var firstViews: [String: [SIMD3<Double>?]] = [:]
  private var multipleViews: [String: Set<Int>] = [:]
  private var minPosition: SIMD3<Double>?
  private var maxPosition: SIMD3<Double>?
  private var lastCamera: simd_double4x4?
  private var savedFrames = 0
  private var lowDetailFrames = 0

  func setSurfaces(_ value: [GuidanceSurface]) {
    surfaces = value.filter { ($0.kind == "wall" || $0.kind == "floor") &&
      $0.size.x > 0.2 && $0.size.y > 0.2 && $0.transform.columns.3.w.isFinite }
    firstViews.removeAll(); multipleViews.removeAll()
    for frame in history { accumulate(frame) }
  }

  func add(_ frame: GuidanceFrame) {
    savedFrames += 1
    if frame.detail < 8 { lowDetailFrames += 1 }
    minPosition = minPosition.map { simd_min($0, frame.position) } ?? frame.position
    maxPosition = maxPosition.map { simd_max($0, frame.position) } ?? frame.position
    lastCamera = frame.camera
    history.append(frame)
    // At most 1800 subsampled depth grids: bounded by the same limit as capture.
    if history.count > 1800 { history.removeFirst() }
    accumulate(frame)
  }

  private func accumulate(_ frame: GuidanceFrame) {
    let view = frame.camera.inverse
    for surface in surfaces {
      let targets = surface.targets
      var first = firstViews[surface.id] ?? [SIMD3<Double>?](repeating: nil, count: targets.count)
      var multiple = multipleViews[surface.id] ?? []
      for (index, target) in targets.enumerated() where !multiple.contains(index) && frame.sees(target, view: view) {
        if let position = first[index] {
          if simd_distance(position, frame.position) >= Self.viewpointSeparation { multiple.insert(index) }
        } else { first[index] = frame.position }
      }
      firstViews[surface.id] = first; multipleViews[surface.id] = multiple
    }
  }

  func snapshot(coaching: String? = nil, tracking: String? = nil) -> GuidanceSnapshot {
    let span = minPosition.flatMap { lo in maxPosition.map { simd_length($0 - lo) } } ?? 0
    let walls = surfaces.filter { $0.kind == "wall" }
    let floors = surfaces.filter { $0.kind == "floor" }
    var fractions: [String: Double] = [:]
    for surface in surfaces { fractions[surface.id] = Double(multipleViews[surface.id]?.count ?? 0) / 24 }
    let missing = surfaces.filter { fractions[$0.id, default: 0] < ($0.kind == "wall" ? Self.wallThreshold : Self.floorThreshold) }
    let normalized = surfaces.map { min(1, fractions[$0.id, default: 0] / ($0.kind == "wall" ? Self.wallThreshold : Self.floorThreshold)) }
    let coverage = normalized.isEmpty ? 0 : normalized.reduce(0,+) / Double(normalized.count)
    let basic = savedFrames >= Self.minimumFrames && span >= Self.minimumSpan
    let observedRoom = walls.count >= 3 && !floors.isEmpty
    let ready = basic && observedRoom && missing.isEmpty && tracking == nil && coaching == nil
    let target = missing.sorted { fractions[$0.id, default: 0] < fractions[$1.id, default: 0] }.first
    let message: String
    if let tracking = tracking { message = tracking }
    else if let coaching = coaching { message = coaching }
    else if walls.count < 3 { message = "Point at the walls and corners to find the room outline." }
    else if floors.isEmpty { message = "Tilt the phone down to capture the floor." }
    else if let target = target {
      message = target.kind == "floor" ? "Capture more of the floor while walking around the furniture." : "Capture more of \(target.label.lowercased()) from another position. Follow the orange area on the map."
    } else if span < Self.minimumSpan { message = "Walk to another position. Turning in one spot is not enough." }
    else if savedFrames < Self.minimumFrames { message = "Keep scanning with overlapping views of walls, floor and furniture." }
    else { message = "Observed walls and floor have overlapping views. Check the furniture too, then Finish." }
    let rows: [[String: Any]] = surfaces.map { surface in
      ["id": surface.id, "kind": surface.kind, "label": surface.label,
       "multi_view_fraction": fractions[surface.id, default: 0],
       "threshold": surface.kind == "wall" ? Self.wallThreshold : Self.floorThreshold]
    }
    return GuidanceSnapshot(ready: ready, message: message, progress: min(coverage, min(1, Double(savedFrames) / Double(Self.minimumFrames))),
      surfaces: surfaces, fractions: fractions, coveredSamples: multipleViews, missingID: target?.id, camera: lastCamera,
      report: ["algorithm": "observed_surface_depth_agreement_v1", "coverage_passed": basic && observedRoom && missing.isEmpty,
        "saved_frames": savedFrames, "camera_span_metres": span, "minimum_frames": Self.minimumFrames,
        "minimum_camera_span_metres": Self.minimumSpan, "minimum_viewpoint_separation_metres": Self.viewpointSeparation,
        "surfaces": rows, "low_detail_frames": lowDetailFrames,
        "scope": "detected_walls_and_floor_only_furniture_and_unseen_surfaces_require_review",
        "reconstruction_verified": false])
  }
}
