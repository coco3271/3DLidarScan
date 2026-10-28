import AVFoundation
import CoreVideo
import Foundation
import simd

/// Records the scan as a video (HEVC, or H.264 where HEVC isn't available) plus, for every
/// frame written, where the camera was and where it pointed: the input Gaussian splatting
/// needs. Frames are ARKit's own camera images in sensor orientation (landscape, 1920×1440 on
/// most iPhones), so the per-frame intrinsics apply to the video's pixels directly.
///
///   video/room-N.mov    the video
///   video/room-N.json   [VideoFrameRecord] in frame order: frame i of the video = entry i
///
/// Thread-safe: frames arrive on SceneKit's render thread, start/finish come from main.
final class VideoRecorder: @unchecked Sendable {
  let url: URL
  let room: Int
  /// frames closer together than this are skipped (30 fps from ARKit's 60)
  let minInterval: TimeInterval
  private let lock = NSLock()
  private var writer: AVAssetWriter?
  private var input: AVAssetWriterInput?
  private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
  private var frames: [VideoFrameRecord] = []
  private var t0: TimeInterval?
  private var lastTime: TimeInterval = -1
  private var size: (width: Int, height: Int) = (0, 0)
  private var codec = "hevc"
  private var dropped = 0
  private var finished = false
  /// false while the user paused the scan: frames are not written (the video just skips ahead)
  var recording: Bool {
    get { lock.withLock { _recording } }
    set { lock.withLock { _recording = newValue } }
  }
  private var _recording = true

  init(url: URL, room: Int, fps: Double = 30) {
    self.url = url
    self.room = room
    minInterval = 1 / fps - 0.004
    try? FileManager.default.removeItem(at: url)
  }

  var frameCount: Int { lock.withLock { frames.count } }
  var duration: TimeInterval { lock.withLock { (frames.last?.time ?? 0) } }

  /// Append one camera image if it's due. Returns true when it was written.
  @discardableResult
  func append(_ pixels: CVPixelBuffer, timestamp: TimeInterval, transform: simd_float4x4, intrinsics: simd_float3x3,
              exposure: TimeInterval, tracking: String, blurPixels: Float) -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard _recording, !finished, timestamp - lastTime >= minInterval else { return false }
    if writer == nil, !start(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels)) { return false }
    guard let input, let adaptor, input.isReadyForMoreMediaData else {
      dropped += 1 // the encoder is behind: skip this frame rather than stall ARKit
      return false
    }
    if t0 == nil { t0 = timestamp }
    let t = timestamp - (t0 ?? timestamp)
    guard adaptor.append(pixels, withPresentationTime: CMTime(seconds: t, preferredTimescale: 90_000)) else {
      dropped += 1
      return false
    }
    lastTime = timestamp
    frames.append(VideoFrameRecord(index: frames.count, time: t, timestamp: timestamp, transform: transform.columnMajor,
                                   intrinsics: intrinsics.columnMajor, exposure: exposure, tracking: tracking,
                                   blurPixels: blurPixels, pose: CameraPose(transform)))
    return true
  }

  private func start(width: Int, height: Int) -> Bool {
    guard let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
    func settings(_ codec: AVVideoCodecType) -> [String: Any] {
      [AVVideoCodecKey: codec, AVVideoWidthKey: width, AVVideoHeightKey: height,
       AVVideoCompressionPropertiesKey: [
         // ~16 Mbit/s HEVC keeps fine texture (what splats learn from) at ~120 MB per minute
         AVVideoAverageBitRateKey: codec == .hevc ? 16_000_000 : 24_000_000,
         AVVideoMaxKeyFrameIntervalKey: 30,
         AVVideoExpectedSourceFrameRateKey: 30,
         AVVideoAllowFrameReorderingKey: false,
       ]]
    }
    var s = settings(.hevc)
    codec = "hevc"
    if !w.canApply(outputSettings: s, forMediaType: .video) {
      s = settings(.h264)
      codec = "h264"
    }
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: s)
    input.expectsMediaDataInRealTime = true
    guard w.canAdd(input) else { return false }
    w.add(input)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    guard w.startWriting() else { return false }
    w.startSession(atSourceTime: .zero)
    writer = w
    self.input = input
    self.adaptor = adaptor
    size = (width, height)
    return true
  }

  /// Close the file; writes the per-frame poses next to it. Nil when nothing was recorded.
  func finish(folder: URL) async -> VideoRecord? {
    let (writer, input, frames, size, codec, dropped) = lock.withLock { () -> (AVAssetWriter?, AVAssetWriterInput?, [VideoFrameRecord], (width: Int, height: Int), String, Int) in
      finished = true
      return (self.writer, self.input, self.frames, self.size, self.codec, self.dropped)
    }
    guard let writer, let input, !frames.isEmpty else {
      writer?.cancelWriting()
      try? FileManager.default.removeItem(at: url)
      return nil
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { return nil }
    let name = url.deletingPathExtension().lastPathComponent
    let posesFile = "video/\(name).json"
    try? BundleJSON.encoder.encode(frames).write(to: folder.appendingPathComponent(posesFile))
    let span = (frames.last?.time ?? 0)
    return VideoRecord(room: room, file: "video/\(url.lastPathComponent)", frames: posesFile, width: size.width, height: size.height,
                       codec: codec, frameCount: frames.count, duration: span,
                       fps: span > 0 ? Double(frames.count - 1) / span : 0, dropped: dropped)
  }
}
