import CoreMotion
import SwiftUI
import UIKit
import simd

/// How the phone is held, from gravity (works even with the system's rotation lock on).
/// Capture wants landscape: the camera's wide side is horizontal, so each frame sees more of
/// the room (about 65° across instead of 50°) and walls fill the frame edge to edge.
enum HoldOrientation: Equatable {
  case landscape, portrait, flat

  /// gravity in the device frame (CoreMotion: x toward the right edge, y toward the top edge)
  static func classify(gravity g: SIMD3<Double>, previous: HoldOrientation = .landscape) -> HoldOrientation {
    let x = abs(g.x), y = abs(g.y)
    // lying flat (pointing at the floor or ceiling): keep what we had, it's ambiguous
    if max(x, y) < 0.35 { return previous }
    // a 10° dead band so a tilted hold doesn't flicker between the two
    if previous == .landscape { return y > x * 1.2 ? .portrait : .landscape }
    if previous == .portrait { return x > y * 1.2 ? .landscape : .portrait }
    return x >= y ? .landscape : .portrait
  }
}

/// Publishes HoldOrientation from the accelerometer, ~10×/s
@MainActor
final class HoldMonitor: ObservableObject {
  @Published private(set) var hold: HoldOrientation = .flat
  private let motion = CMMotionManager()

  func start() {
    guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
    motion.deviceMotionUpdateInterval = 0.1
    motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
      guard let self, let g = data?.gravity else { return }
      let next = HoldOrientation.classify(gravity: SIMD3(g.x, g.y, g.z), previous: self.hold)
      if next != self.hold { self.hold = next }
    }
  }

  func stop() { motion.stopDeviceMotionUpdates() }
}

/// EXIF orientation for a camera image (sensor pixels) from the camera's pose: which way is up
/// in the picture. 1 = as stored (phone sideways, sensor upright), 3 = upside down,
/// 6 = turn 90° clockwise (phone upright, the usual portrait), 8 = turn 90° counter-clockwise.
func exifOrientation(cameraToWorld t: simd_float4x4) -> Int {
  let right = t.columns.0.y, up = t.columns.1.y // how much the sensor's x / y axes point up
  if abs(up) >= abs(right) { return up >= 0 ? 1 : 3 }
  return right < 0 ? 6 : 8
}

/// Which interface orientations the app allows right now: portrait everywhere, landscape while
/// capturing. SwiftUI can't lock a single screen, so the app delegate asks this.
enum OrientationLock {
  @MainActor static var mask: UIInterfaceOrientationMask = .portrait

  @MainActor static func set(_ mask: UIInterfaceOrientationMask, prefer: UIInterfaceOrientationMask? = nil) {
    self.mask = mask
    for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
      scene.requestGeometryUpdate(.iOS(interfaceOrientations: prefer ?? mask)) { _ in }
      scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
  }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
  func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
    MainActor.assumeIsolated { OrientationLock.mask }
  }
}
