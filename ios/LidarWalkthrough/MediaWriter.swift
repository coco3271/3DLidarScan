import Accelerate
import ARKit
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Encodes photos and LiDAR depth frames off the main thread. Pixels are copied out of
/// ARKit's buffers on the caller's thread (so ARFrames are never retained), then JPEG/DEFLATE
/// encoding and disk writes happen on a serial background queue.
final class MediaWriter: @unchecked Sendable {
  private let queue = DispatchQueue(label: "media-writer", qos: .utility)
  private let ci = CIContext(options: [.cacheIntermediates: false])
  private let lock = NSLock()
  private var _inFlight = 0

  var inFlight: Int {
    lock.lock(); defer { lock.unlock() }
    return _inFlight
  }

  private func begin() { lock.lock(); _inFlight += 1; lock.unlock() }
  private func end() { lock.lock(); _inFlight -= 1; lock.unlock() }

  /// Wait for every queued write to land on disk
  func drain() async {
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in queue.async { c.resume() } }
  }

  // MARK: photos

  /// Render the frame's camera image now; encode + write later. Returns the image size, or nil.
  func writePhoto(_ pixelBuffer: CVPixelBuffer, to url: URL, maxEdge: CGFloat, geo: GeoSample?) -> CGSize? {
    var image = CIImage(cvPixelBuffer: pixelBuffer)
    let longEdge = max(image.extent.width, image.extent.height)
    if longEdge > maxEdge {
      let s = maxEdge / longEdge
      image = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
    }
    let rect = CGRect(x: 0, y: 0, width: image.extent.width.rounded(), height: image.extent.height.rounded())
    guard let cg = ci.createCGImage(image, from: rect) else { return nil }
    begin()
    queue.async {
      defer { self.end() }
      var props: [String: Any] = [
        kCGImageDestinationLossyCompressionQuality as String: 0.92,
        // pixels stay in sensor orientation (that's what the intrinsics describe); viewers rotate
        kCGImagePropertyOrientation as String: 6,
      ]
      if let geo { props[kCGImagePropertyGPSDictionary as String] = Self.gpsDictionary(geo) }
      Self.writeJPEG(cg, to: url, properties: props)
    }
    return CGSize(width: cg.width, height: cg.height)
  }

  static func gpsDictionary(_ g: GeoSample) -> [String: Any] {
    let utc = DateFormatter()
    utc.locale = Locale(identifier: "en_US_POSIX")
    utc.timeZone = TimeZone(identifier: "UTC")
    var d: [String: Any] = [
      kCGImagePropertyGPSLatitude as String: abs(g.latitude),
      kCGImagePropertyGPSLatitudeRef as String: g.latitude >= 0 ? "N" : "S",
      kCGImagePropertyGPSLongitude as String: abs(g.longitude),
      kCGImagePropertyGPSLongitudeRef as String: g.longitude >= 0 ? "E" : "W",
      kCGImagePropertyGPSHPositioningError as String: g.horizontalAccuracy,
    ]
    if let time = g.timestamp {
      utc.dateFormat = "yyyy:MM:dd"
      d[kCGImagePropertyGPSDateStamp as String] = utc.string(from: time)
      utc.dateFormat = "HH:mm:ss.SS"
      d[kCGImagePropertyGPSTimeStamp as String] = utc.string(from: time)
    }
    if let alt = g.altitude {
      d[kCGImagePropertyGPSAltitude as String] = abs(alt)
      d[kCGImagePropertyGPSAltitudeRef as String] = alt < 0 ? 1 : 0
    }
    if let h = g.heading {
      d[kCGImagePropertyGPSImgDirection as String] = h
      d[kCGImagePropertyGPSImgDirectionRef as String] = "T"
    }
    return d
  }

  static func writeJPEG(_ cg: CGImage, to url: URL, properties: [String: Any]) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, cg, properties as CFDictionary)
    CGImageDestinationFinalize(dest)
  }

  // MARK: depth

  /// depth/NNNNN.f16z (Float16 meters, raw DEFLATE), .conf (UInt8 0–2), .jpg (640-wide RGB)
  func writeDepth(_ frame: ARFrame, depth: ARDepthData, folder: URL, name: String, room: Int) -> DepthRecord? {
    let map = depth.depthMap
    let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map)
    let res = frame.camera.imageResolution
    var k = frame.camera.intrinsics
    let scale = Float(w) / Float(res.width)
    k.columns.0.x *= scale; k.columns.1.y *= scale; k.columns.2.x *= scale; k.columns.2.y *= scale
    let rgbScale = 640 / Float(res.width)
    var kc = frame.camera.intrinsics
    kc.columns.0.x *= rgbScale; kc.columns.1.y *= rgbScale; kc.columns.2.x *= rgbScale; kc.columns.2.y *= rgbScale
    let small = CIImage(cvPixelBuffer: frame.capturedImage)
      .transformed(by: CGAffineTransform(scaleX: CGFloat(rgbScale), y: CGFloat(rgbScale)))
    let rgbHeight = (CGFloat(res.height) * CGFloat(rgbScale)).rounded()
    let cg = ci.createCGImage(small, from: CGRect(x: 0, y: 0, width: 640, height: rgbHeight))
    guard let depthData = Self.float16(map) else { return nil }
    let confData = depth.confidenceMap.map(Self.bytes)
    let record = DepthRecord(
      file: "depth/\(name).f16z", confidence: "depth/\(name).conf", rgb: cg == nil ? nil : "depth/\(name).jpg",
      rgbIntrinsics: kc.columnMajor, room: room, timestamp: frame.timestamp,
      width: w, height: h, transform: frame.camera.transform.columnMajor, intrinsics: k.columnMajor,
      pose: CameraPose(frame.camera.transform))
    begin()
    queue.async {
      defer { self.end() }
      // NSData's .zlib is raw DEFLATE (no header), which is what the bundle format specifies
      let packed = (try? (depthData as NSData).compressed(using: .zlib) as Data) ?? depthData
      try? packed.write(to: folder.appendingPathComponent(record.file))
      try? confData?.write(to: folder.appendingPathComponent(record.confidence))
      if let cg, let rgb = record.rgb {
        Self.writeJPEG(cg, to: folder.appendingPathComponent(rgb), properties: [kCGImageDestinationLossyCompressionQuality as String: 0.8])
      }
    }
    return record
  }

  /// Float32 depth map → tightly packed little-endian Float16
  static func float16(_ buffer: CVPixelBuffer) -> Data? {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
    let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
    var src = vImage_Buffer(data: base, height: vImagePixelCount(h), width: vImagePixelCount(w),
                            rowBytes: CVPixelBufferGetBytesPerRow(buffer))
    var out = Data(count: w * h * 2)
    let err = out.withUnsafeMutableBytes { (p: UnsafeMutableRawBufferPointer) -> vImage_Error in
      var dst = vImage_Buffer(data: p.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 2)
      return vImageConvert_PlanarFtoPlanar16F(&src, &dst, vImage_Flags(kvImageNoFlags))
    }
    return err == kvImageNoError ? out : nil
  }

  /// One byte per pixel, rows packed
  static func bytes(_ buffer: CVPixelBuffer) -> Data {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
    let row = CVPixelBufferGetBytesPerRow(buffer)
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return Data() }
    var out = Data(capacity: w * h)
    for y in 0..<h { out.append(base.advanced(by: y * row).assumingMemoryBound(to: UInt8.self), count: w) }
    return out
  }
}
