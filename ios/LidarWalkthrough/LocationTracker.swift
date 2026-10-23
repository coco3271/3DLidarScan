import CoreLocation
import Foundation

/// GPS + compass for tagging photos and the property itself. Indoors GPS is often 5–30 m
/// off, so every sample carries its accuracy and the AI is told to treat it as approximate.
@MainActor
final class LocationTracker: NSObject, ObservableObject, CLLocationManagerDelegate {
  @Published private(set) var location: CLLocation?
  @Published private(set) var heading: CLHeading?
  @Published private(set) var address: String?
  @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined

  private let manager = CLLocationManager()
  private let geocoder = CLGeocoder()
  private var geocodedAt: CLLocation?

  override init() {
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyBest
    manager.headingFilter = 2
    authorization = manager.authorizationStatus
  }

  func start() {
    if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
    manager.startUpdatingLocation()
    if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
  }

  func stop() {
    manager.stopUpdatingLocation()
    manager.stopUpdatingHeading()
  }

  /// The latest fix if it's recent enough to describe where the phone is now
  var sample: GeoSample? {
    guard let location, location.horizontalAccuracy >= 0, -location.timestamp.timeIntervalSinceNow < 120 else { return nil }
    return GeoSample(location, heading: heading)
  }

  var accuracyText: String {
    guard let location, location.horizontalAccuracy >= 0 else {
      return authorization == .denied || authorization == .restricted ? "GPS off" : "GPS…"
    }
    return "GPS ±\(Int(location.horizontalAccuracy.rounded())) m"
  }

  private func reverseGeocodeIfNeeded(_ location: CLLocation) {
    guard location.horizontalAccuracy >= 0, location.horizontalAccuracy < 100 else { return }
    if let geocodedAt, geocodedAt.distance(from: location) < 50, address != nil { return }
    geocodedAt = location
    geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, _ in
      guard let p = placemarks?.first else { return }
      let street = [p.subThoroughfare, p.thoroughfare].compactMap { $0 }.joined(separator: " ")
      let text = [street, p.locality, p.administrativeArea, p.postalCode, p.country]
        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
      Task { @MainActor in self?.address = text.isEmpty ? nil : text }
    }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let last = locations.last else { return }
    Task { @MainActor in
      // keep the better of a fresh fix and a slightly older but much more accurate one
      if let current = self.location, -current.timestamp.timeIntervalSinceNow < 10,
         current.horizontalAccuracy >= 0, last.horizontalAccuracy > current.horizontalAccuracy * 3 { return }
      self.location = last
      self.reverseGeocodeIfNeeded(last)
    }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
    Task { @MainActor in self.heading = newHeading }
  }

  nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    let status = manager.authorizationStatus
    Task { @MainActor in
      self.authorization = status
      if status == .authorizedWhenInUse || status == .authorizedAlways { self.start() }
    }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
