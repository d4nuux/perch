import AppKit
import Combine
import CoreLocation
import Foundation

/// Current weather for the user's location. (Owned by the Calendar & Weather agent.)
/// Other features read `WeatherService.shared.current` and observe it; don't modify this API shape.
struct WeatherSnapshot: Equatable {
    var temperature: Double        // °C
    var high: Double, low: Double  // °C, today
    var symbol: String             // SF Symbol name, e.g. "cloud.sun.fill"
    var summary: String            // "Partly cloudy"
    var precipitationChance: Double // 0...1, next hours
    var sunrise: Date?, sunset: Date?
    var locationName: String
}

extension WeatherSnapshot: Codable {}

/// Fetches Open-Meteo every 30 min and on wake, once `start()` has been called by a feature that
/// shows weather. Location: CoreLocation (one-shot, when-in-use) or the manual city from
/// `WeatherSettings` (geocoded once, cached). The last snapshot is cached in UserDefaults.
final class WeatherService: ObservableObject {
    static let shared = WeatherService()
    @Published private(set) var current: WeatherSnapshot?
    /// Daily forecast (7 days from today), for per-day views.
    @Published private(set) var days: [WeatherDay] = []
    /// Human-readable problem, if any ("Set a city in Settings"), for the Settings rows.
    @Published private(set) var statusText: String?

    private static let cacheKey = "weather.cache"
    private static let cityGeoKey = "weather.cityGeo"
    private static let refreshInterval: TimeInterval = 30 * 60

    private let d = UserDefaults.standard
    private var started = false
    private var fetching = false
    private var lastFetch: Date?
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private let geocoder = CLGeocoder()
    /// Reverse-geocoded name for the last fix (re-resolved when moving > 5 km).
    private var placeName: (location: CLLocation, name: String)?

    private struct Cache: Codable {
        var snapshot: WeatherSnapshot
        var days: [WeatherDay]
        var fetchedAt: Date
    }

    private init() {}

    /// Starts fetching (idempotent). Called by any feature that needs weather.
    func start() {
        if !Thread.isMainThread { DispatchQueue.main.async { self.start() }; return }
        guard !started else { return }
        started = true
        loadCache()

        let t = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh(force: true)
        }
        t.tolerance = 120
        RunLoop.main.add(t, forMode: .common)
        timer = t

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .delay(for: .seconds(5), scheduler: RunLoop.main) // let the network come back
            .sink { [weak self] _ in self?.refresh(force: false) }
            .store(in: &cancellables)

        let s = WeatherSettings.shared
        s.$useCurrentLocation.removeDuplicates().dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh(force: true) }
            .store(in: &cancellables)

        refresh(force: false)
    }

    /// Forecast for a calendar day (user's calendar), if within the fetched range.
    func forecast(for date: Date) -> WeatherDay? {
        let key = OpenMeteo.dayKey(date)
        return days.first { $0.day == key }
    }

    /// Fetches now unless the last fetch is recent (`force` ignores that).
    func refresh(force: Bool) {
        guard started else { return }
        if !force, let lastFetch, -lastFetch.timeIntervalSinceNow < 10 * 60 { return }
        guard !fetching else { return }
        fetching = true
        resolveLocation { [weak self] coord, name in
            guard let self else { return }
            guard let coord else {
                self.fetching = false
                return
            }
            self.fetch(coord, name: name)
        }
    }

    // MARK: Location

    private func resolveLocation(_ done: @escaping (CLLocationCoordinate2D?, String) -> Void) {
        let s = WeatherSettings.shared
        guard s.useCurrentLocation else { return resolveCity(done) }
        LocationProvider.shared.request { [weak self] loc in
            guard let self else { return }
            guard let loc else { return self.resolveCity(done) } // denied/unavailable → manual city
            if let p = self.placeName, p.location.distance(from: loc) < 5000 {
                return done(loc.coordinate, p.name)
            }
            self.geocoder.reverseGeocodeLocation(loc) { marks, _ in
                DispatchQueue.main.async {
                    let name = marks?.first.flatMap { $0.locality ?? $0.name } ?? ""
                    if !name.isEmpty { self.placeName = (loc, name) }
                    done(loc.coordinate, name)
                }
            }
        }
    }

    private func resolveCity(_ done: @escaping (CLLocationCoordinate2D?, String) -> Void) {
        let city = WeatherSettings.shared.city.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !city.isEmpty else {
            statusText = WeatherSettings.shared.useCurrentLocation
                ? "Location unavailable. Set a city to use instead." : "Set a city to show weather."
            return done(nil, "")
        }
        if let g = d.dictionary(forKey: Self.cityGeoKey), g["city"] as? String == city,
           let lat = g["lat"] as? Double, let lon = g["lon"] as? Double {
            return done(CLLocationCoordinate2D(latitude: lat, longitude: lon), g["name"] as? String ?? city)
        }
        geocoder.geocodeAddressString(city) { [weak self] marks, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let m = marks?.first, let loc = m.location else {
                    self.statusText = "Couldn't find “\(city)”."
                    return done(nil, "")
                }
                let name = m.locality ?? m.name ?? city
                self.d.set(["city": city, "lat": loc.coordinate.latitude, "lon": loc.coordinate.longitude,
                            "name": name], forKey: Self.cityGeoKey)
                done(loc.coordinate, name)
            }
        }
    }

    // MARK: Fetch

    private func fetch(_ coord: CLLocationCoordinate2D, name: String) {
        let url = OpenMeteo.url(latitude: coord.latitude, longitude: coord.longitude)
        URLSession.shared.dataTask(with: url) { [weak self] data, response, _ in
            let result = data.flatMap { try? OpenMeteo.parse($0, locationName: name) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.fetching = false
                guard let result else {
                    self.statusText = "Weather unavailable right now."
                    return
                }
                self.lastFetch = Date()
                self.statusText = nil
                if self.current != result.snapshot { self.current = result.snapshot }
                if self.days != result.days { self.days = result.days }
                self.saveCache()
            }
        }.resume()
    }

    // MARK: Cache

    private func loadCache() {
        guard let data = d.data(forKey: Self.cacheKey),
              let c = try? JSONDecoder().decode(Cache.self, from: data),
              -c.fetchedAt.timeIntervalSinceNow < 12 * 3600 else { return }
        current = c.snapshot
        days = c.days
        lastFetch = c.fetchedAt
    }

    private func saveCache() {
        guard let current else { return }
        if let data = try? JSONEncoder().encode(Cache(snapshot: current, days: days, fetchedAt: lastFetch ?? Date())) {
            d.set(data, forKey: Self.cacheKey)
        }
    }
}
