import ARKit
import Foundation
import Metal

/// Writes ARKit's LiDAR mesh (all ARMeshAnchors) as one binary PLY in world space, in the
/// layout house-capture readers expect:
///   vertex: x y z nx ny nz coverage red green blue inroom
///   face:   vertex_indices class   (ARMeshClassification: 0 none 1 wall 2 floor 3 ceiling
///                                   4 table 5 seat 6 window 7 door)
/// `coverage` is the photo coverage score (0 = no photo saw it, ≥ 1 = well photographed) and
/// the color shows it like the live scan view: red needs photos, amber almost, green captured.
/// (The walkthrough viewer paints the mesh from the photos themselves.)
enum MeshExporter {
  private static let neutral: (UInt8, UInt8, UInt8) = (200, 200, 200)
  /// red (needs photos), amber, green (captured): same as the live scan view
  private static let bandColors: [(UInt8, UInt8, UInt8)] = [(255, 59, 59), (255, 184, 51), (56, 237, 117)]

  static func writePLY(anchors: [ARMeshAnchor], to url: URL, coverage: CoverageMap? = nil) throws -> MeshRecord {
    var record = try writePLY(pieces: anchors.map(AnchorPiece.init), to: url, coverage: coverage)
    record.anchors = anchors.count
    return record
  }

  /// Several meshes concatenated into one PLY; each piece's face indices are offset past the
  /// vertices of the pieces before it.
  static func writePLY(pieces: [any MeshPiece], to url: URL, coverage: CoverageMap? = nil) throws -> MeshRecord {
    let vertexCount = pieces.reduce(0) { $0 + $1.vertexCount }
    let faceCount = pieces.reduce(0) { $0 + $1.faceCount }
    var header = "ply\nformat binary_little_endian 1.0\ncomment 3D LiDAR Scan: ARKit world space, meters, +Y up\n"
    header += "element vertex \(vertexCount)\nproperty float x\nproperty float y\nproperty float z\n"
    header += "property float nx\nproperty float ny\nproperty float nz\nproperty float coverage\n"
    header += "property uchar red\nproperty uchar green\nproperty uchar blue\nproperty uchar inroom\n"
    header += "element face \(faceCount)\nproperty list uchar uint vertex_indices\nproperty uchar class\nend_header\n"

    guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    var out = ByteWriter(handle: handle)
    out.data.append(Data(header.utf8))

    for piece in pieces {
      let vertices = (0..<piece.vertexCount).map { piece.vertex($0) }
      let scores = coverage?.scores(for: vertices.map(\.0)) ?? []
      for (i, (p, n)) in vertices.enumerated() {
        let score = i < scores.count ? scores[i] : 0
        out.f32(p.x); out.f32(p.y); out.f32(p.z)
        out.f32(n.x); out.f32(n.y); out.f32(n.z)
        out.f32(score)
        let rgb = coverage == nil ? neutral : bandColors[CoverageMap.band(score)]
        out.u8(rgb.0); out.u8(rgb.1); out.u8(rgb.2); out.u8(1)
        try out.flushIfNeeded()
      }
    }
    var offset: UInt32 = 0
    for piece in pieces {
      for i in 0..<piece.faceCount {
        let (a, b, c, cls) = piece.face(i)
        out.u8(3)
        out.u32(a + offset); out.u32(b + offset); out.u32(c + offset)
        out.u8(cls)
        try out.flushIfNeeded()
      }
      offset += UInt32(piece.vertexCount)
    }
    try out.flush()
    return MeshRecord(file: "", anchors: pieces.count, vertices: vertexCount, faces: faceCount)
  }
}

/// One mesh in world space
protocol MeshPiece {
  var vertexCount: Int { get }
  var faceCount: Int { get }
  /// world-space position and unit normal
  func vertex(_ i: Int) -> (SIMD3<Float>, SIMD3<Float>)
  /// triangle vertex indices (local to this piece) and ARMeshClassification raw value
  func face(_ i: Int) -> (UInt32, UInt32, UInt32, UInt8)
}

/// An ARMeshAnchor read straight from its Metal buffers, moved into world space
struct AnchorPiece: MeshPiece {
  private let geometry: ARMeshGeometry
  private let transform: simd_float4x4
  private let rotation: simd_float3x3

  init(_ anchor: ARMeshAnchor) {
    geometry = anchor.geometry
    transform = anchor.transform
    let m = anchor.transform
    rotation = simd_float3x3(simd_make_float3(m.columns.0), simd_make_float3(m.columns.1), simd_make_float3(m.columns.2))
  }

  var vertexCount: Int { geometry.vertices.count }
  var faceCount: Int { geometry.faces.count }

  func vertex(_ i: Int) -> (SIMD3<Float>, SIMD3<Float>) {
    let v = geometry.vertices
    // float3 sources are packed 12-byte records: read the components, never a 16-byte SIMD3
    let p = v.buffer.contents().advanced(by: v.offset + i * v.stride)
    let world = transform * simd_float4(p.load(as: Float.self), p.load(fromByteOffset: 4, as: Float.self), p.load(fromByteOffset: 8, as: Float.self), 1)
    var normal = SIMD3<Float>(0, 1, 0)
    let n = geometry.normals
    if i < n.count {
      let q = n.buffer.contents().advanced(by: n.offset + i * n.stride)
      let local = SIMD3<Float>(q.load(as: Float.self), q.load(fromByteOffset: 4, as: Float.self), q.load(fromByteOffset: 8, as: Float.self))
      if simd_length(local) > 0 { normal = simd_normalize(rotation * local) }
    }
    return (SIMD3(world.x, world.y, world.z), normal)
  }

  func face(_ i: Int) -> (UInt32, UInt32, UInt32, UInt8) {
    let f = geometry.faces
    let base = f.buffer.contents()
    func index(_ k: Int) -> UInt32 {
      let at = (i * f.indexCountPerPrimitive + k) * f.bytesPerIndex
      return f.bytesPerIndex == 2 ? UInt32(base.load(fromByteOffset: at, as: UInt16.self)) : base.load(fromByteOffset: at, as: UInt32.self)
    }
    var cls: UInt8 = 0
    if let c = geometry.classification, i < c.count {
      cls = c.buffer.contents().load(fromByteOffset: c.offset + i * c.stride, as: UInt8.self)
    }
    return (index(0), index(1), index(2), cls)
  }
}

private struct ByteWriter {
  let handle: FileHandle
  var data = Data()

  init(handle: FileHandle) {
    self.handle = handle
    data.reserveCapacity(1 << 22)
  }

  mutating func f32(_ v: Float) { withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
  mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
  mutating func u8(_ v: UInt8) { data.append(v) }

  mutating func flushIfNeeded() throws {
    if data.count >= 1 << 22 { try flush() }
  }

  mutating func flush() throws {
    try handle.write(contentsOf: data)
    data.removeAll(keepingCapacity: true)
  }
}
