import ARKit
import Foundation

/// Writes ARKit's LiDAR mesh (all ARMeshAnchors) as one binary PLY in world space, in the
/// layout house-capture readers expect:
///   vertex: x y z nx ny nz coverage red green blue inroom
///   face:   vertex_indices class   (ARMeshClassification: 0 none 1 wall 2 floor 3 ceiling
///                                   4 table 5 seat 6 window 7 door)
/// Colors are left neutral: the walkthrough viewer paints the mesh from the photos.
enum MeshExporter {
  static func writePLY(anchors: [ARMeshAnchor], to url: URL) throws -> MeshRecord {
    let vertexCount = anchors.reduce(0) { $0 + $1.geometry.vertices.count }
    let faceCount = anchors.reduce(0) { $0 + $1.geometry.faces.count }
    var header = "ply\nformat binary_little_endian 1.0\ncomment 3D LiDAR Scan: ARKit world space, meters, +Y up\n"
    header += "element vertex \(vertexCount)\nproperty float x\nproperty float y\nproperty float z\n"
    header += "property float nx\nproperty float ny\nproperty float nz\nproperty float coverage\n"
    header += "property uchar red\nproperty uchar green\nproperty uchar blue\nproperty uchar inroom\n"
    header += "element face \(faceCount)\nproperty list uchar uint vertex_indices\nproperty uchar class\nend_header\n"

    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    var out = ByteWriter(handle: handle)
    out.data.append(Data(header.utf8))

    for anchor in anchors {
      let g = anchor.geometry
      let m = anchor.transform
      let r = simd_float3x3(simd_make_float3(m.columns.0), simd_make_float3(m.columns.1), simd_make_float3(m.columns.2))
      let v = g.vertices, n = g.normals
      let vBase = v.buffer.contents().advanced(by: v.offset)
      let nBase = n.buffer.contents().advanced(by: n.offset)
      for i in 0..<v.count {
        let p = vBase.advanced(by: i * v.stride)
        let local = simd_float4(p.load(as: Float.self), p.load(fromByteOffset: 4, as: Float.self), p.load(fromByteOffset: 8, as: Float.self), 1)
        let world = m * local
        var normal = simd_float3(0, 1, 0)
        if i < n.count {
          let q = nBase.advanced(by: i * n.stride)
          normal = simd_normalize(r * simd_float3(q.load(as: Float.self), q.load(fromByteOffset: 4, as: Float.self), q.load(fromByteOffset: 8, as: Float.self)))
        }
        out.f32(world.x); out.f32(world.y); out.f32(world.z)
        out.f32(normal.x); out.f32(normal.y); out.f32(normal.z)
        out.f32(0) // coverage
        out.u8(200); out.u8(200); out.u8(200); out.u8(1)
        try out.flushIfNeeded()
      }
    }

    var offset: UInt32 = 0
    for anchor in anchors {
      let g = anchor.geometry
      let f = g.faces
      let fBase = f.buffer.contents()
      let perFace = f.indexCountPerPrimitive
      let classes = g.classification
      let cBase = classes.map { $0.buffer.contents().advanced(by: $0.offset) }
      for i in 0..<f.count {
        out.u8(3)
        for k in 0..<3 {
          let at = (i * perFace + k) * f.bytesPerIndex
          let index: UInt32 = f.bytesPerIndex == 2
            ? UInt32(fBase.load(fromByteOffset: at, as: UInt16.self))
            : fBase.load(fromByteOffset: at, as: UInt32.self)
          out.u32(index + offset)
        }
        var cls: UInt8 = 0
        if let classes, let cBase, i < classes.count { cls = cBase.load(fromByteOffset: i * classes.stride, as: UInt8.self) }
        out.u8(cls)
        try out.flushIfNeeded()
      }
      offset += UInt32(g.vertices.count)
    }
    try out.flush()
    return MeshRecord(file: "", anchors: anchors.count, vertices: vertexCount, faces: faceCount)
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
