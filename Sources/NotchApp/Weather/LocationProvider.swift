import CoreLocation

/// One-shot location fixes on demand (no continuous updates). Never requests authorization itself
/// (onboarding / Settings › Permissions do); callers get nil until access is granted. Main thread only.
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    static let shared = LocationProvider()

    private lazy var manager: CLLocationManager = {
        let m = CLLocationManager()
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyKilometer
        lastStatus = m.authorizationStatus
        return m
    }()
    private var waiters: [(CLLocation?) -> Void] = []
    private(set) var last: CLLocation?
    /// Called on main when location access goes from undecided to granted (e.g. via onboarding),
    /// so features that fell back without a location can refresh.
    var onAuthorized: [() -> Void] = []
    private var lastStatus: CLAuthorizationStatus?

    var isDenied: Bool {
        let s = manager.authorizationStatus
        return s == .denied || s == .restricted
    }

    /// Calls back on main with a location no older than `maxAge`, or nil if unavailable/denied.
    func request(maxAge: TimeInterval = 600, _ completion: @escaping (CLLocation?) -> Void) {
        if let last, -last.timestamp.timeIntervalSinceNow < maxAge { completion(last); return }
        waiters.append(completion)
        guard waiters.count == 1 else { return } // a request is already in flight
        switch manager.authorizationStatus {
        // Never prompt from a background feature: onboarding / Settings › Permissions ask.
        case .notDetermined, .denied, .restricted: finish(nil)
        default: manager.requestLocation()
        }
    }

    private func finish(_ location: CLLocation?) {
        if let location { last = location }
        let w = waiters
        waiters = []
        w.forEach { $0(location ?? last) }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        let was = lastStatus
        lastStatus = status
        if was == .notDetermined, status == .authorizedAlways || status == .authorized {
            DispatchQueue.main.async { [weak self] in self?.onAuthorized.forEach { $0() } }
        }
        guard !waiters.isEmpty else { return }
        switch manager.authorizationStatus {
        case .notDetermined: break
        case .denied, .restricted: finish(nil)
        default: manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finish(locations.last)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(nil)
    }
}
