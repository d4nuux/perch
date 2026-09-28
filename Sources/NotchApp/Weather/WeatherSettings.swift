import Foundation
import SwiftUI

/// Weather preferences (UserDefaults-backed). Snapshots are always °C; format with `format(_:)`.
final class WeatherSettings: ObservableObject {
    static let shared = WeatherSettings()
    private let d = UserDefaults.standard

    /// Use CoreLocation; when off (or location denied) the manual city is used.
    @Published var useCurrentLocation: Bool { didSet { d.set(useCurrentLocation, forKey: "weather.useLocation") } }
    @Published var city: String { didSet { d.set(city, forKey: "weather.city") } }
    @Published var fahrenheit: Bool { didSet { d.set(fahrenheit, forKey: "weather.fahrenheit") } }

    private init() {
        d.register(defaults: [
            "weather.useLocation": true, "weather.city": "",
            "weather.fahrenheit": Locale.current.measurementSystem == .us,
        ])
        useCurrentLocation = d.bool(forKey: "weather.useLocation")
        city = d.string(forKey: "weather.city") ?? ""
        fahrenheit = d.bool(forKey: "weather.fahrenheit")
    }

    /// "18°" in the chosen unit, from °C.
    func format(_ celsius: Double) -> String {
        let v = fahrenheit ? celsius * 9 / 5 + 32 : celsius
        return "\(Int(v.rounded()))°"
    }
}

/// Weather rows for Settings (embedded in CalendarSettingsSection).
struct WeatherSettingsSection: View {
    @ObservedObject var settings = WeatherSettings.shared
    @ObservedObject var weather = WeatherService.shared
    @StateObject private var cityDraft = CityDraft()

    var body: some View {
        Picker("Temperature unit", selection: $settings.fahrenheit) {
            Text("°C").tag(false)
            Text("°F").tag(true)
        }
        .pickerStyle(.segmented)
        Toggle("Use current location for weather", isOn: $settings.useCurrentLocation)
        HStack {
            TextField(settings.useCurrentLocation ? "Fallback city" : "City", text: $cityDraft.text)
                .onSubmit(commit)
            Button("Set", action: commit).disabled(cityDraft.text == settings.city)
        }
        if let status = weather.statusText {
            Text(status).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func commit() {
        settings.city = cityDraft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        WeatherService.shared.refresh(force: true)
    }
}

/// Text field buffer so geocoding happens on submit, not per keystroke.
private final class CityDraft: ObservableObject {
    @Published var text = WeatherSettings.shared.city
}
