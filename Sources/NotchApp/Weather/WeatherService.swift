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

final class WeatherService: ObservableObject {
    static let shared = WeatherService()
    @Published private(set) var current: WeatherSnapshot?
    /// Starts fetching (idempotent). Called by any feature that needs weather.
    func start() {}
}
