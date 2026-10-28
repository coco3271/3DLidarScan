import Foundation
import simd

/// How fast the phone moves while recording, smoothed, with a verdict for the HUD.
/// Gaussian splats need sharp, overlapping frames: walking speed is fine, a quick pan smears
/// every frame. Thresholds are for a 1920-wide frame at indoor exposures (~1/60 s).
struct MotionMonitor {
  enum Level: Int, Comparable {
    case good, fast, tooFast
    static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
  }

  /// smoothed linear speed (m/s) and turn rate (rad/s)
  private(set) var speed: Float = 0
  private(set) var turnRate: Float = 0
  /// predicted motion smear of the latest frame, in pixels at 1920 wide
  private(set) var blurPixels: Float = 0
  private(set) var level: Level = .good
  private var last: (time: TimeInterval, pose: simd_float4x4)?

  /// a slow walk is ~0.3–0.5 m/s; turning in place ~20–30°/s
  static let fastSpeed: Float = 0.6, tooFastSpeed: Float = 0.9
  static let fastTurn: Float = 0.6, tooFastTurn: Float = 1.0 // rad/s (~35°/s, ~57°/s)
  static let fastBlur: Float = 6, tooFastBlur: Float = 10

  /// Feed every recorded frame. `fx1920` is the focal length in pixels at 1920 wide.
  mutating func add(time: TimeInterval, pose: simd_float4x4, exposure: TimeInterval, fx1920: Float) {
    defer { last = (time, pose) }
    guard let last, time > last.time else { return }
    let dt = Float(time - last.time)
    guard dt < 0.5 else { return } // a gap (pause, interruption): don't count it as motion
    let v = simd_distance(simd_make_float3(pose.columns.3), simd_make_float3(last.pose.columns.3)) / dt
    let w = Self.angle(pose, last.pose) / dt
    // exponential smoothing over ~0.3 s, so one jittery frame doesn't flash the warning
    let a = min(1, dt / 0.3)
    speed += (v - speed) * a
    turnRate += (w - turnRate) * a
    blurPixels = (w + v / 1.5) * fx1920 * Float(exposure)
    level = Self.classify(speed: speed, turnRate: turnRate, blur: blurPixels, previous: level)
  }

  /// With hysteresis: leaving a level needs a 20 % margin, so the banner doesn't flicker
  static func classify(speed: Float, turnRate: Float, blur: Float, previous: Level) -> Level {
    func over(_ x: Float, _ limit: Float, _ current: Bool) -> Bool { x > (current ? limit * 0.8 : limit) }
    if over(speed, tooFastSpeed, previous == .tooFast) || over(turnRate, tooFastTurn, previous == .tooFast)
        || over(blur, tooFastBlur, previous == .tooFast) { return .tooFast }
    if over(speed, fastSpeed, previous >= .fast) || over(turnRate, fastTurn, previous >= .fast)
        || over(blur, fastBlur, previous >= .fast) { return .fast }
    return .good
  }

  /// angle between the two cameras' viewing directions (radians)
  static func angle(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
    acos(min(1, max(-1, simd_dot(simd_make_float3(a.columns.2), simd_make_float3(b.columns.2)))))
  }

  /// 0…1 for the speed meter: 1 = at the "too fast" limit
  var meter: Float {
    max(speed / Self.tooFastSpeed, turnRate / Self.tooFastTurn, blurPixels / Self.tooFastBlur)
  }

  mutating func reset() { self = MotionMonitor() }
}
