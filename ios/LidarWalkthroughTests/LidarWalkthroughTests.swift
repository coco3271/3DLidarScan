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
}
