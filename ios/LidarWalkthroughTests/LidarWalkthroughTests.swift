import CoreLocation
import CoreVideo
import ImageIO
import XCTest
import simd

/// Logic tests for the capture → export pipeline that don't need a LiDAR device. They compile
/// the app's own source files (see project.yml) and run in the iOS Simulator.
///
/// Environment (xcodebuild passes TEST_RUNNER_<NAME> to the tests as <NAME>):
///   FIXTURE_BUNDLE  a house-capture/5 bundle made by tests/make_fake_bundle.py
///   AI_KIT          the repo's ai-kit/ folder (the app bundles it as a resource)
///   OUT_DIR         where to leave swift-walkthrough.html / swift-poses.csv for the browser test
final class LidarWalkthroughTests: XCTestCase {
  private var env: [String: String] { ProcessInfo.processInfo.environment }

  private func fixture() throws -> URL {
    guard let path = env["FIXTURE_BUNDLE"], FileManager.default.fileExists(atPath: path + "/manifest.json") else {
      throw XCTSkip("FIXTURE_BUNDLE not set (run through CI or set TEST_RUNNER_FIXTURE_BUNDLE)")
    }
    return URL(fileURLWithPath: path, isDirectory: true)
  }

  /// A writable copy of the fixture (the builder writes walkthrough.html into the scan folder)
  private func scratchCopy() throws -> URL {
    let src = try fixture()
    let dst = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.copyItem(at: src, to: dst)
    addTeardownBlock { try? FileManager.default.removeItem(at: dst) }
    return dst
  }

  /// Camera pose for a phone held upright at `position`, facing `yaw` (CCW from -Z), tilted by `pitch`
  private func pose(_ position: SIMD3<Float>, yaw: Float, pitch: Float) -> simd_float4x4 {
    let f = SIMD3<Float>(-sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))
    var up = SIMD3<Float>(0, 1, 0)
    up = simd_normalize(up - f * simd_dot(up, f))
    let x = -up, z = -f, y = simd_cross(z, x)
    return simd_float4x4(SIMD4(x, 0), SIMD4(y, 0), SIMD4(z, 0), SIMD4(position, 1))
  }

  // MARK: pose math

  func testCameraPoseUnpacksTheTransform() {
    let t = pose([3.17, -0.06, 0.85], yaw: 1.2, pitch: -0.2)
    let p = CameraPose(t)
    XCTAssertEqual(p.position, [3.17, -0.06, 0.85])
    XCTAssertEqual(p.yaw, 1.2 * 180 / .pi, accuracy: 1e-3)
    XCTAssertEqual(p.pitch, -0.2 * 180 / .pi, accuracy: 1e-3)
    XCTAssertEqual(simd_length(SIMD3(p.direction[0], p.direction[1], p.direction[2])), 1, accuracy: 1e-5)
    // facing straight down -Z is yaw 0
    XCTAssertEqual(CameraPose(pose(.zero, yaw: 0, pitch: 0)).yaw, 0, accuracy: 1e-4)
  }

  func testColumnMajorRoundTripAndMapSpot() {
    let t = pose([1, 2, 3], yaw: -2.5, pitch: 0.3)
    let back = simd_float4x4(columnMajor: t.columnMajor)
    for c in 0..<4 { XCTAssertEqual(simd_distance(t[c], back[c]), 0, accuracy: 1e-6) }
    XCTAssertEqual(t.columnMajor[12...14].map { $0 }, [1, 2, 3], "translation is the last column")
    let spot = MapSpot(t, manual: true)
    XCTAssertEqual(spot.point, SIMD2(1, 3))
    XCTAssertEqual(spot.yaw * 180 / .pi, CameraPose(t).yaw, accuracy: 1e-3)
  }

  // MARK: bundle format

  func testDecodesAHouseCaptureBundle() throws {
    let dir = try fixture()
    let manifest = try BundleJSON.decoder.decode(Manifest.self, from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
    XCTAssertEqual(manifest.format, Manifest.currentFormat)
    XCTAssertEqual(manifest.rooms.count, 2)
    let photos = try BundleJSON.decoder.decode([PhotoRecord].self, from: Data(contentsOf: dir.appendingPathComponent(manifest.photos)))
    XCTAssertEqual(photos.count, manifest.photoCount)
    XCTAssertTrue(photos.allSatisfy { $0.transform.count == 16 && $0.intrinsics.count == 9 && $0.pose != nil && $0.depthFrame != nil })
    let frames = try BundleJSON.decoder.decode([DepthRecord].self,
                                               from: Data(contentsOf: dir.appendingPathComponent(manifest.depthFrames ?? "depth/frames.json")))
    XCTAssertEqual(frames.count, manifest.depthFrameCount)
    // re-encoding keeps the house-capture keys the scan-to-threejs scripts read
    let json = try JSONSerialization.jsonObject(with: BundleJSON.encoder.encode(photos[0])) as! [String: Any]
    for key in ["file", "room", "timestamp", "width", "height", "transform", "intrinsics", "tracking", "manual"] {
      XCTAssertNotNil(json[key], key)
    }
  }

  func testScanPlanReadsWallsAndPhotoSpots() throws {
    let plan = ScanPlan(folder: try fixture())
    XCTAssertEqual(plan.walls.count, 8)
    XCTAssertEqual(plan.openings.filter { $0.kind == "door" }.count, 2)
    XCTAssertEqual(plan.openings.filter { $0.kind == "window" }.count, 1)
    XCTAssertEqual(plan.spots.count, plan.photos.count)
    // walls span the 8 × 4 m house
    let xs = plan.walls.flatMap { [$0.a.x, $0.b.x] }, zs = plan.walls.flatMap { [$0.a.y, $0.b.y] }
    XCTAssertEqual(xs.max()! - xs.min()!, 8, accuracy: 1e-3)
    XCTAssertEqual(zs.max()! - zs.min()!, 4, accuracy: 1e-3)
  }

  func testPosesCSV() throws {
    let dir = try fixture()
    let photos = try BundleJSON.decoder.decode([PhotoRecord].self, from: Data(contentsOf: dir.appendingPathComponent("photos/photos.json")))
    let frames = try BundleJSON.decoder.decode([DepthRecord].self, from: Data(contentsOf: dir.appendingPathComponent("depth/frames.json")))
    let csv = PosesCSV.make(photos: photos, depthFrames: frames)
    let rows = csv.split(separator: "\n").map { $0.split(separator: ",", omittingEmptySubsequences: false) }
    XCTAssertEqual(rows.count, 1 + photos.count + frames.count)
    let columns = PosesCSV.header.split(separator: ",").count
    XCTAssertTrue(rows.allSatisfy { $0.count == columns }, "every row has \(columns) columns")
    let first = rows[1], p = photos[0]
    XCTAssertEqual(String(first[1]), p.file)
    XCTAssertEqual(Float(first[4])!, p.transform[12], accuracy: 1e-3)
    XCTAssertEqual(Float(first[6])!, p.transform[14], accuracy: 1e-3)
    XCTAssertEqual(String(first[14]), p.depthFrame)
    if let dir = env["OUT_DIR"] { try csv.write(toFile: dir + "/swift-poses.csv", atomically: true, encoding: .utf8) }
  }

  // MARK: media

  func testDepthIsStoredAsFloat16() throws {
    var buffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 3, 2, kCVPixelFormatType_DepthFloat32, nil, &buffer), kCVReturnSuccess)
    let pb = try XCTUnwrap(buffer)
    let values: [Float] = [0.25, 1.5, 2.75, 3.0, 4.5, 0.0]
    CVPixelBufferLockBaseAddress(pb, [])
    let base = CVPixelBufferGetBaseAddress(pb)!, row = CVPixelBufferGetBytesPerRow(pb)
    for y in 0..<2 { for x in 0..<3 { base.advanced(by: y * row + x * 4).storeBytes(of: values[y * 3 + x], as: Float.self) } }
    CVPixelBufferUnlockBaseAddress(pb, [])
    let data = try XCTUnwrap(MediaWriter.float16(pb))
    XCTAssertEqual(data.count, 3 * 2 * 2, "rows are packed (no row padding)")
    let halves = data.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
    for (h, want) in zip(halves, values) {
      // decode IEEE half by hand, as Python's '<f2' does
      let e = Int((h >> 10) & 0x1f), f = Float(h & 0x3ff)
      let v: Float = e == 0 ? f / 1024 * pow(2, -14) : (1 + f / 1024) * pow(2, Float(e - 15))
      XCTAssertEqual(v, want, accuracy: 1e-3)
    }
  }

  func testGPSDictionary() {
    var geo = GeoSample(CLLocation(coordinate: .init(latitude: -33.8688, longitude: 151.2093), altitude: -3,
                                   horizontalAccuracy: 6, verticalAccuracy: 2, timestamp: Date(timeIntervalSince1970: 0)), heading: nil)
    geo.heading = 271
    let d = MediaWriter.gpsDictionary(geo)
    XCTAssertEqual(d[kCGImagePropertyGPSLatitudeRef as String] as? String, "S")
    XCTAssertEqual(d[kCGImagePropertyGPSLongitudeRef as String] as? String, "E")
    XCTAssertEqual(d[kCGImagePropertyGPSLatitude as String] as? Double ?? 0, 33.8688, accuracy: 1e-9)
    XCTAssertEqual(d[kCGImagePropertyGPSAltitudeRef as String] as? Int, 1, "below sea level")
    XCTAssertEqual(d[kCGImagePropertyGPSImgDirection as String] as? Double, 271)
    XCTAssertEqual(d[kCGImagePropertyGPSDateStamp as String] as? String, "1970:01:01")
    geo.timestamp = nil // older data without a fix time must not crash
    XCTAssertNil(MediaWriter.gpsDictionary(geo)[kCGImagePropertyGPSDateStamp as String])
  }

  func testShrinkKeepsSensorPixelsAndOrientation() throws {
    let dir = try fixture()
    let photo = try Data(contentsOf: dir.appendingPathComponent("photos/0000.jpg"))
    let small = try XCTUnwrap(WalkthroughBuilder.shrink(photo, edge: 120))
    let src = try XCTUnwrap(CGImageSourceCreateWithData(small as CFData, nil))
    let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any])
    let w = props[kCGImagePropertyPixelWidth as String] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight as String] as? Int ?? 0
    XCTAssertEqual(max(w, h), 120)
    XCTAssertGreaterThan(w, h, "still landscape sensor pixels (intrinsics refer to them)")
    XCTAssertEqual(props[kCGImagePropertyOrientation as String] as? Int, 6)
    XCTAssertNil(WalkthroughBuilder.shrink(photo, edge: 4000), "never upscales")
  }

  // MARK: mesh

  private struct Quad: MeshPiece {
    var y: Float
    var vertexCount: Int { 4 }
    var faceCount: Int { 2 }
    func vertex(_ i: Int) -> (SIMD3<Float>, SIMD3<Float>) { (SIMD3(Float(i % 2), y, Float(i / 2)), SIMD3(0, 1, 0)) }
    func face(_ i: Int) -> (UInt32, UInt32, UInt32, UInt8) { i == 0 ? (0, 1, 2, 2) : (1, 3, 2, 2) }
  }

  func testPLYConcatenatesPiecesWithOffsets() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).ply")
    defer { try? FileManager.default.removeItem(at: url) }
    let record = try MeshExporter.writePLY(pieces: [Quad(y: 0), Quad(y: 2.5)], to: url)
    XCTAssertEqual(record.vertices, 8)
    XCTAssertEqual(record.faces, 4)
    let data = try Data(contentsOf: url)
    let end = try XCTUnwrap(data.range(of: Data("end_header\n".utf8))).upperBound
    let header = String(decoding: data[..<end], as: UTF8.self)
    XCTAssertTrue(header.contains("element vertex 8\n") && header.contains("element face 4\n"))
    XCTAssertEqual(data.count - end, 8 * 32 + 4 * 14, "vertex = 7 floats + 4 bytes, face = 1 + 3×4 + 1 bytes")
    func u32(_ at: Int) -> UInt32 { data.subdata(in: at..<at + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
    func f32(_ at: Int) -> Float { Float(bitPattern: u32(at)) }
    XCTAssertEqual(f32(end + 4 * 32 + 4), 2.5, "second piece's first vertex y")
    let lastFace = end + 8 * 32 + 3 * 14
    XCTAssertEqual(data[lastFace], 3)
    XCTAssertEqual([u32(lastFace + 1), u32(lastFace + 5), u32(lastFace + 9)], [5, 7, 6], "indices offset by the first piece")
    XCTAssertEqual(data[lastFace + 13], 2, "classification = floor")
  }

  // MARK: export

  func testWalkthroughBuilderEmbedsTheScan() throws {
    let dir = try scratchCopy()
    guard let kitPath = env["AI_KIT"] else { throw XCTSkip("AI_KIT not set") }
    let html = try WalkthroughBuilder.build(dir, kit: URL(fileURLWithPath: kitPath, isDirectory: true))
    let text = try String(contentsOf: html, encoding: .utf8)
    XCTAssertTrue(text.contains("<title>12 Test Street</title>"))
    let start = try XCTUnwrap(text.range(of: "<script id=\"data\" type=\"application/json\">")).upperBound
    let end = try XCTUnwrap(text.range(of: "</script>", range: start..<text.endIndex)).lowerBound
    let payload = try JSONSerialization.jsonObject(with: Data(text[start..<end].utf8)) as! [String: Any]
    let files = payload["files"] as! [String: String]
    for key in ["manifest.json", "structure.json", "mesh/room-1.ply", "photos/photos.json", "depth/frames.json"] {
      XCTAssertNotNil(files[key], key)
    }
    let photos = try BundleJSON.decoder.decode([PhotoRecord].self, from: Data(base64Encoded: files["photos/photos.json"]!)!)
    XCTAssertTrue(!photos.isEmpty && photos.allSatisfy { $0.manual && files[$0.file] != nil }, "the tour = shutter photos, all embedded")
    if let out = env["OUT_DIR"] {
      let dest = URL(fileURLWithPath: out).appendingPathComponent("swift-walkthrough.html")
      try? FileManager.default.removeItem(at: dest)
      try FileManager.default.copyItem(at: html, to: dest)
    }
  }

  func testZipFolder() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Scan \(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("photos"), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: dir.appendingPathComponent("manifest.json"))
    defer { try? FileManager.default.removeItem(at: dir) }
    let zip = try ScanExporter.zipFolder(dir)
    defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
    let data = try Data(contentsOf: zip)
    XCTAssertEqual(Array(data.prefix(2)), [0x50, 0x4B], "PK zip signature")
    XCTAssertEqual(zip.lastPathComponent, dir.lastPathComponent + ".zip")
    XCTAssertNotNil(data.range(of: Data("manifest.json".utf8)))
  }

  func testEvenly() {
    XCTAssertEqual(WalkthroughBuilder.evenly(Array(0..<10), 5), [0, 2, 4, 6, 8])
    XCTAssertEqual(WalkthroughBuilder.evenly([1, 2], 5), [1, 2])
  }

  // MARK: photo coverage (the red/green scan mesh)

  func testVoxelKeysAndBoundarySplat() {
    XCTAssertNotEqual(CoverageMap.key([0.01, 0, 0]), CoverageMap.key([0.06, 0, 0]))
    XCTAssertNotEqual(CoverageMap.key([-0.01, 0, 0]), CoverageMap.key([0.01, 0, 0]), "negative side is its own voxel")
    XCTAssertEqual(CoverageMap.key([0.011, 0.02, 0.03]), CoverageMap.key([0.039, 0.04, 0.001]))
    XCTAssertEqual(CoverageMap.keys(around: [0.025, 0.025, 0.025]).count, 1, "center of a voxel: just that voxel")
    let nearFace = CoverageMap.keys(around: [0.001, 0.025, 0.025])
    XCTAssertEqual(nearFace.count, 2)
    XCTAssertTrue(nearFace.contains(CoverageMap.key([-0.01, 0.025, 0.025])), "a wall on a voxel face credits both sides")
    XCTAssertEqual(CoverageMap.keys(around: [0.001, 0.001, 0.049]).count, 8)
    _ = CoverageMap.keys(around: [.nan, .infinity, -.infinity]) // must not trap
  }

  func testWeightFavorsCloseUpViews() {
    XCTAssertEqual(CoverageMap.weight(distance: 0.8), 1)
    XCTAssertEqual(CoverageMap.weight(distance: 1.5), 1)
    XCTAssertEqual(CoverageMap.weight(distance: 2.75), 0.5, accuracy: 1e-5)
    XCTAssertEqual(CoverageMap.weight(distance: 4), 0)
    XCTAssertEqual(CoverageMap.band(0), 0)
    XCTAssertEqual(CoverageMap.band(0.5), 1)
    XCTAssertEqual(CoverageMap.band(1), 2)
  }

  func testEachPhotoCountsOncePerVoxelAndScoresCap() {
    let map = CoverageMap()
    let p = SIMD3<Float>(1.025, 0.025, 0.025)
    map.add([(p, 1), (p + 0.001, 0.5)]) // same photo, same voxel: best weight once
    XCTAssertEqual(map.score(at: p), 1)
    map.add([(p, 1)])
    map.add([(p, 1)])
    XCTAssertEqual(map.score(at: p), CoverageMap.maxScore)
    XCTAssertEqual(map.score(at: [5, 5, 5]), 0)
    let v = map.version
    map.add([])
    XCTAssertEqual(map.version, v, "nothing added, nothing to recolor")
  }

  func testDepthPixelsUnprojectIntoTheWorld() {
    // 3×3 depth at 2 m, principal point at the center pixel, camera 1 m up looking down -Z
    var t = matrix_identity_float4x4
    t.columns.3 = [0, 1, 0, 1]
    let sample = DepthSample(width: 3, height: 3, depth: Array(repeating: 2, count: 9), confidence: nil,
                             intrinsics: simd_float3x3([1, 0, 0], [0, 1, 0], [1, 1, 1]), cameraToWorld: t)
    let pts = sample.pointsSeen(step: 1)
    XCTAssertEqual(pts.count, 9)
    let center = pts[4].position, right = pts[5].position, below = pts[7].position
    XCTAssertEqual(simd_distance(center, [0, 1, -2]), 0, accuracy: 1e-6)
    XCTAssertEqual(simd_distance(right, [2, 1, -2]), 0, accuracy: 1e-6, "image +u = camera +x")
    XCTAssertEqual(simd_distance(below, [0, -1, -2]), 0, accuracy: 1e-6, "image +v (down) = camera -y")
    XCTAssertEqual(pts[0].weight, CoverageMap.weight(distance: 2))
    var lowConfidence = sample
    lowConfidence.confidence = [0, 2, 2, 2, 0, 2, 2, 2, 2]
    XCTAssertEqual(lowConfidence.pointsSeen(step: 1).count, 7, "low-confidence LiDAR pixels are skipped")
  }

  func testMeshCoverageSplitsTrianglesByBand() {
    // triangle scores average their vertices: 2 → green, (2+0+2)/3 = 1.33 → green,
    // (2+0+0)/3 = 0.67 → amber, 0 → red
    let c = MeshCoverage(triangles: [0, 1, 2, 1, 3, 2, 2, 3, 4, 3, 4, 5], scores: [2, 2, 2, 0, 0, 0])
    XCTAssertEqual(c.bands[2], [0, 1, 2, 1, 3, 2])
    XCTAssertEqual(c.bands[1], [2, 3, 4])
    XCTAssertEqual(c.bands[0], [3, 4, 5])
    XCTAssertEqual(c.capturedVertices, 3)
    XCTAssertEqual(c.totalVertices, 6)
    XCTAssertEqual(MeshCoverage(triangles: [0, 1, 9], scores: [1, 1]).bands.flatMap { $0 }, [], "bad indices are skipped")
  }

  func testPLYCarriesCoverageColors() throws {
    let map = CoverageMap()
    map.add([(SIMD3<Float>(0, 0, 0), 1)]) // Quad(y: 0) vertex 0 is at the origin
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("c-\(UUID().uuidString).ply")
    defer { try? FileManager.default.removeItem(at: url) }
    _ = try MeshExporter.writePLY(pieces: [Quad(y: 0)], to: url, coverage: map)
    let data = try Data(contentsOf: url)
    let end = try XCTUnwrap(data.range(of: Data("end_header\n".utf8))).upperBound
    func f32(_ at: Int) -> Float { Float(bitPattern: data.subdata(in: at..<at + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }) }
    XCTAssertEqual(f32(end + 24), 1, "vertex 0 coverage score")
    XCTAssertEqual([data[end + 28], data[end + 29], data[end + 30]], [56, 237, 117], "captured = green")
    XCTAssertEqual(f32(end + 32 * 3 + 24), 0, "vertex 3 was never photographed")
    XCTAssertEqual([data[end + 32 * 3 + 28], data[end + 32 * 3 + 29]], [255, 59], "needs photos = red")
  }

  /// The synthetic scan's photos, through their own LiDAR depth frames, must turn a good part
  /// of its mesh green/amber: same numbers as an independent Python implementation (54 % seen,
  /// 22 % captured with only 14 photos)
  func testFixtureCoverageFromPhotoDepth() throws {
    let dir = try fixture()
    let photos = try BundleJSON.decoder.decode([PhotoRecord].self, from: Data(contentsOf: dir.appendingPathComponent("photos/photos.json")))
    let frames = try BundleJSON.decoder.decode([DepthRecord].self, from: Data(contentsOf: dir.appendingPathComponent("depth/frames.json")))
    let byFile = Dictionary(uniqueKeysWithValues: frames.map { ($0.file, $0) })
    let map = CoverageMap()
    for photo in photos {
      let f = try XCTUnwrap(byFile[photo.depthFrame ?? ""])
      let raw = try (Data(contentsOf: dir.appendingPathComponent(f.file)) as NSData).decompressed(using: .zlib) as Data
      let halves = raw.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
      let depth = halves.map { h -> Float in
        let e = Int((h >> 10) & 0x1f), m = Float(h & 0x3ff)
        return e == 0 ? m / 1024 * pow(2, -14) : (1 + m / 1024) * pow(2, Float(e - 15))
      }
      let k = f.intrinsics
      map.add(DepthSample(width: f.width, height: f.height, depth: depth, confidence: nil,
                          intrinsics: simd_float3x3([k[0], k[1], k[2]], [k[3], k[4], k[5]], [k[6], k[7], k[8]]),
                          cameraToWorld: simd_float4x4(columnMajor: f.transform)).pointsSeen())
    }
    let ply = try Data(contentsOf: dir.appendingPathComponent("mesh/room-1.ply"))
    let end = try XCTUnwrap(ply.range(of: Data("end_header\n".utf8))).upperBound
    let header = String(decoding: ply[..<end], as: UTF8.self)
    let count = Int(header.components(separatedBy: "element vertex ")[1].split(separator: "\n")[0])!
    let vertices = (0..<count).map { i -> SIMD3<Float> in
      ply.subdata(in: end + i * 32..<end + i * 32 + 12).withUnsafeBytes {
        SIMD3($0.loadUnaligned(fromByteOffset: 0, as: Float.self), $0.loadUnaligned(fromByteOffset: 4, as: Float.self),
              $0.loadUnaligned(fromByteOffset: 8, as: Float.self))
      }
    }
    let scores = map.scores(for: vertices)
    let seen = Float(scores.filter { $0 > 0.05 }.count) / Float(count)
    let captured = Float(scores.filter { $0 >= CoverageMap.goodScore }.count) / Float(count)
    XCTAssertEqual(seen, 0.54, accuracy: 0.05)
    XCTAssertEqual(captured, 0.22, accuracy: 0.05)
  }
}
