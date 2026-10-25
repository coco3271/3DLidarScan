import Foundation
import simd

/// Which surfaces the photos have captured well, kept as a sparse grid of 5 cm voxels.
///
/// Every photo is saved together with the LiDAR depth frame from the same moment. Each depth
/// pixel is a point that photo actually saw, and it is always the *nearest* surface along that
/// ray, so anything hidden behind something else never counts as photographed. A photo adds
/// to the voxels its depth points fall in, more when it was taken close up (more detail).
/// The live scan view colors the LiDAR mesh from these scores: red = needs photos,
/// amber = almost, green = captured.
///
/// Thread-safe: photos are added on a background queue while the mesh is colored elsewhere.
final class CoverageMap: @unchecked Sendable {
  static let voxelSize: Float = 0.05
  /// score at which a surface counts as captured: one photo from ≤ 1.2 m, or a few from farther
  static let goodScore: Float = 1
  /// scores stop growing here (more photos of a well-covered spot don't need to show)
  static let maxScore: Float = 2

  private var cells: [Int64: Float] = [:]
  private let lock = NSLock()
  private var _version = 0

  /// bumps whenever photos change the scores (so the mesh knows to recolor)
  var version: Int { lock.withLock { _version } }
  var voxelCount: Int { lock.withLock { cells.count } }

  /// A point this close to a voxel face (as a fraction of the voxel) also counts for the
  /// neighbor: LiDAR noise of ~1 cm must not split one wall between two voxel layers
  static let boundaryMargin: Float = 0.3

  /// Pack a world position's voxel index into 64 bits (21 bits per axis: ±52 km at 5 cm)
  static func key(_ p: SIMD3<Float>) -> Int64 { packed(cell(p)) }

  private static func cell(_ p: SIMD3<Float>) -> SIMD3<Float> {
    // clamp first: Int64(nan or ±inf) would trap
    let q = (p / voxelSize).rounded(.down)
    return SIMD3(q.x.isFinite ? q.x : 0, q.y.isFinite ? q.y : 0, q.z.isFinite ? q.z : 0)
      .clamped(lowerBound: SIMD3(repeating: -1e6), upperBound: SIMD3(repeating: 1e6))
  }

  /// voxel indices (whole numbers as floats) → one 64-bit key
  private static func packed(_ c: SIMD3<Float>) -> Int64 {
    let mask: Int64 = 0x1F_FFFF
    return (Int64(c.x) & mask) | ((Int64(c.y) & mask) << 21) | ((Int64(c.z) & mask) << 42)
  }

  /// The voxel holding p plus, on each axis where p is near a face, the neighbor across it
  /// (1 to 8 keys)
  static func keys(around p: SIMD3<Float>) -> [Int64] {
    let c = cell(p)
    let frac = p / voxelSize - c
    var options: [[Float]] = []
    for a in 0..<3 {
      if !frac[a].isFinite { options.append([c[a]]) }
      else if frac[a] < boundaryMargin { options.append([c[a], c[a] - 1]) }
      else if frac[a] > 1 - boundaryMargin { options.append([c[a], c[a] + 1]) }
      else { options.append([c[a]]) }
    }
    var out: [Int64] = []
    for x in options[0] { for y in options[1] { for z in options[2] { out.append(packed(SIMD3(x, y, z))) } } }
    return out
  }

  /// How much one view of a surface `distance` meters away is worth: full credit up close,
  /// fading out by 3.5 m (too far to resolve detail)
  static func weight(distance d: Float) -> Float {
    if d <= 1.2 { return 1 }
    if d >= 3.5 { return 0 }
    return 1 - (d - 1.2) / 2.3
  }

  /// red (0), amber (1) or green (2) for a coverage score
  static func band(_ score: Float) -> Int { score <= 0.05 ? 0 : score < goodScore ? 1 : 2 }

  /// Add one photo's view. Each voxel counts the photo once, at its best (closest) weight.
  func add(_ points: [(position: SIMD3<Float>, weight: Float)]) {
    var best: [Int64: Float] = [:]
    best.reserveCapacity(points.count / 4)
    for (p, w) in points where w > 0 {
      for k in Self.keys(around: p) where w > best[k, default: 0] { best[k] = w }
    }
    guard !best.isEmpty else { return }
    lock.withLock {
      for (k, w) in best { cells[k] = min(Self.maxScore, cells[k, default: 0] + w) }
      _version += 1
    }
  }

  func score(at p: SIMD3<Float>) -> Float { lock.withLock { cells[Self.key(p)] ?? 0 } }

  /// Scores for many points under one lock (coloring a whole mesh anchor)
  func scores(for points: [SIMD3<Float>]) -> [Float] {
    lock.withLock { points.map { cells[Self.key($0)] ?? 0 } }
  }

  func reset() { lock.withLock { cells.removeAll(); _version += 1 } }
}

/// One LiDAR depth frame as plain values: meters along the camera axis, row-major
struct DepthSample {
  var width: Int
  var height: Int
  var depth: [Float]
  /// ARKit confidence per pixel (0 low, 1 medium, 2 high), or nil
  var confidence: [UInt8]?
  /// intrinsics scaled to the depth map's resolution
  var intrinsics: simd_float3x3
  /// camera-to-world; camera looks down -Z, +Y up (sensor orientation)
  var cameraToWorld: simd_float4x4

  /// The world points this frame saw, with how much each is worth for photo coverage.
  /// `step` skips pixels (2 = every other row/column: ~12k points from 256×192).
  func pointsSeen(step: Int = 2, minConfidence: UInt8 = 1) -> [(position: SIMD3<Float>, weight: Float)] {
    let fx = intrinsics.columns.0.x, fy = intrinsics.columns.1.y
    let cx = intrinsics.columns.2.x, cy = intrinsics.columns.2.y
    var out: [(position: SIMD3<Float>, weight: Float)] = []
    out.reserveCapacity((width / step) * (height / step))
    for v in stride(from: 0, to: height, by: step) {
      for u in stride(from: 0, to: width, by: step) {
        let i = v * width + u
        if let confidence, confidence[i] < minConfidence { continue }
        let d = depth[i]
        guard d.isFinite, d > 0.1 else { continue }
        let w = CoverageMap.weight(distance: d)
        guard w > 0 else { continue }
        // pixel → camera space (ARKit: x right, y up, looking down -z) → world
        let cam = SIMD4<Float>((Float(u) - cx) / fx * d, -(Float(v) - cy) / fy * d, -d, 1)
        let world = cameraToWorld * cam
        out.append((SIMD3(world.x, world.y, world.z), w))
      }
    }
    return out
  }
}

/// How a mesh's triangles split into coverage bands, plus how much of it is captured
struct MeshCoverage {
  /// triangle vertex indices per band (red, amber, green)
  var bands: [[UInt32]] = [[], [], []]
  var capturedVertices = 0
  var totalVertices = 0

  /// `scores` per vertex; a triangle takes the average of its three vertices
  init(triangles: [UInt32], scores: [Float]) {
    totalVertices = scores.count
    capturedVertices = scores.reduce(0) { $0 + ($1 >= CoverageMap.goodScore ? 1 : 0) }
    var i = 0
    while i + 2 < triangles.count {
      let a = triangles[i], b = triangles[i + 1], c = triangles[i + 2]
      if Int(max(a, b, c)) < scores.count {
        let s = (scores[Int(a)] + scores[Int(b)] + scores[Int(c)]) / 3
        bands[CoverageMap.band(s)].append(contentsOf: [a, b, c])
      }
      i += 3
    }
  }
}
