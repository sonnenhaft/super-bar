import AppKit
import CoreLocation

@MainActor final class LocationWeather: NSObject, @preconcurrency CLLocationManagerDelegate {
  private var manager: CLLocationManager?
  private lazy var geocoder = CLGeocoder()
  private var task: Task<Void, Never>?
  private var timer: Timer?
  private var requesting = false
  private var previousLocation: CLLocation?
  var changed: (() -> Void)?
  private(set) var name: String?
  private(set) var temperature: Double?
  private(set) var notice = ""
  var allowed: Bool {
    manager?.authorizationStatus == .authorizedAlways
  }
  func start() {
    guard manager == nil else { return }
    let manager = CLLocationManager()
    self.manager = manager
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyKilometer
    refresh()
    timer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
  }
  func permit() {
    guard let manager else { return }
    if manager.authorizationStatus == .notDetermined {
      manager.requestWhenInUseAuthorization()
    } else if !allowed {
      if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
        NSWorkspace.shared.open(url)
      }
    } else { refresh() }
  }
  func refresh() {
    guard let manager, allowed, !requesting, task == nil else { return }
    requesting = true
    notice = "Locating…"
    changed?()
    manager.requestLocation()
  }
  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    if allowed { refresh() }
    else {
      requesting = false
      task?.cancel()
      task = nil
      geocoder.cancelGeocode()
      name = nil
      temperature = nil
      previousLocation = nil
      notice = ""
      changed?()
    }
  }
  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    requesting = false
    notice = "Location unavailable · Retry"
    changed?()
  }
  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    requesting = false
    guard let location = locations.last, location.horizontalAccuracy >= 0,
      abs(location.timestamp.timeIntervalSinceNow) < 300 else {
      notice = "Location unavailable · Retry"
      changed?()
      return
    }
    task?.cancel()
    task = Task {
      defer { task = nil; changed?() }
      let coordinate = location.coordinate
      let places = try? await geocoder.reverseGeocodeLocation(location)
      guard !Task.isCancelled else { return }
      name = places?.first?.locality ?? places?.first?.name
        ?? String(format: "%.2f, %.2f", coordinate.latitude, coordinate.longitude)
      if previousLocation.map({ location.distance(from: $0) > 2000 }) ?? true {
        temperature = nil
      }
      previousLocation = location
      notice = "Updating weather…"
      changed?()
      do {
        var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        url.queryItems = [
          URLQueryItem(name: "latitude", value: String(coordinate.latitude)),
          URLQueryItem(name: "longitude", value: String(coordinate.longitude)),
          URLQueryItem(name: "current", value: "temperature_2m"),
          URLQueryItem(name: "temperature_unit", value: "celsius"),
        ]
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url.url!, timeoutInterval: 20))
        try Task.checkCancellation()
        guard (response as? HTTPURLResponse)?.statusCode == 200,
          let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let current = json["current"] as? [String: Any],
          let value = current["temperature_2m"] as? Double, value.isFinite
        else { throw LGError(message: "Weather unavailable") }
        temperature = value
        notice = ""
      } catch {
        if !Task.isCancelled {
          temperature = nil
          notice = "Weather unavailable · Retry"
        }
      }
    }
  }
}
