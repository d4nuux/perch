import Foundation

/// One day of forecast (location's local calendar day).
struct WeatherDay: Codable, Equatable {
    /// Day key "yyyy-MM-dd" in the forecast location's time zone.
    var day: String
    var high: Double, low: Double  // °C
    var code: Int
    var symbol: String
    var summary: String
    var sunrise: Date?, sunset: Date?
}

/// Open-Meteo forecast API (no key): request URL, decoding, WMO code mapping. Pure Foundation so a
/// CLI probe can compile it standalone.
enum OpenMeteo {
    static func url(latitude: Double, longitude: Double) -> URL {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: String(format: "%.4f", latitude)),
            .init(name: "longitude", value: String(format: "%.4f", longitude)),
            .init(name: "current", value: "temperature_2m,weather_code,is_day"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset"),
            .init(name: "hourly", value: "precipitation_probability"),
            .init(name: "forecast_days", value: "7"),
            .init(name: "forecast_hours", value: "12"),
            .init(name: "timezone", value: "auto"),
            .init(name: "timeformat", value: "unixtime"),
        ]
        return c.url!
    }

    private struct Response: Decodable {
        struct Current: Decodable {
            let time: Double
            let temperature_2m: Double
            let weather_code: Int
            let is_day: Int?
        }
        struct Hourly: Decodable {
            let time: [Double]
            let precipitation_probability: [Double?]
        }
        struct Daily: Decodable {
            let time: [Double]
            let weather_code: [Int?]
            let temperature_2m_max: [Double?]
            let temperature_2m_min: [Double?]
            let sunrise: [Double?]
            let sunset: [Double?]
        }
        let utc_offset_seconds: Int
        let current: Current
        let hourly: Hourly?
        let daily: Daily
    }

    struct Result {
        var snapshot: WeatherSnapshot
        var days: [WeatherDay]
        var code: Int
        var isDay: Bool
    }

    static func parse(_ data: Data, locationName: String, now: Date = Date()) throws -> Result {
        let r = try JSONDecoder().decode(Response.self, from: data)
        let offset = r.utc_offset_seconds
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!

        var days: [WeatherDay] = []
        let d = r.daily
        for i in d.time.indices {
            guard let hi = d.temperature_2m_max[safe: i] ?? nil,
                  let lo = d.temperature_2m_min[safe: i] ?? nil else { continue }
            let code = (d.weather_code[safe: i] ?? nil) ?? 0
            let local = Date(timeIntervalSince1970: d.time[i] + Double(offset))
            let c = utc.dateComponents([.year, .month, .day], from: local)
            days.append(WeatherDay(
                day: String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0),
                high: hi, low: lo, code: code,
                symbol: symbol(for: code, isDay: true), summary: summary(for: code),
                sunrise: (d.sunrise[safe: i] ?? nil).map { Date(timeIntervalSince1970: $0) },
                sunset: (d.sunset[safe: i] ?? nil).map { Date(timeIntervalSince1970: $0) }))
        }

        // "Today" = the day containing the current observation, in the location's time zone.
        let curLocal = utc.dateComponents([.year, .month, .day],
                                          from: Date(timeIntervalSince1970: r.current.time + Double(offset)))
        let todayKey = String(format: "%04d-%02d-%02d", curLocal.year ?? 0, curLocal.month ?? 0, curLocal.day ?? 0)
        let today = days.first { $0.day == todayKey } ?? days.first

        // Precipitation chance: max over the next 6 hours.
        var chance = 0.0
        if let h = r.hourly {
            let end = now.timeIntervalSince1970 + 6 * 3600
            for (i, t) in h.time.enumerated() where t + 3600 > now.timeIntervalSince1970 && t < end {
                if let p = h.precipitation_probability[safe: i] ?? nil { chance = max(chance, p) }
            }
        }

        let code = r.current.weather_code
        let isDay = (r.current.is_day ?? 1) == 1
        let snap = WeatherSnapshot(
            temperature: r.current.temperature_2m,
            high: today?.high ?? r.current.temperature_2m,
            low: today?.low ?? r.current.temperature_2m,
            symbol: symbol(for: code, isDay: isDay),
            summary: summary(for: code),
            precipitationChance: min(max(chance / 100, 0), 1),
            sunrise: today?.sunrise, sunset: today?.sunset,
            locationName: locationName)
        return Result(snapshot: snap, days: days, code: code, isDay: isDay)
    }

    // MARK: WMO weather codes (https://open-meteo.com/en/docs)

    static func symbol(for code: Int, isDay: Bool) -> String {
        switch code {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1: return isDay ? "sun.max.fill" : "moon.fill"
        case 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55: return "cloud.drizzle.fill"
        case 56, 57, 66, 67: return "cloud.sleet.fill"
        case 61, 63: return "cloud.rain.fill"
        case 65: return "cloud.heavyrain.fill"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
        case 80, 81: return isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        case 82: return "cloud.heavyrain.fill"
        case 95: return isDay ? "cloud.sun.bolt.fill" : "cloud.moon.bolt.fill"
        case 96, 99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    static func summary(for code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1: return "Mostly clear"
        case 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45: return "Fog"
        case 48: return "Freezing fog"
        case 51: return "Light drizzle"
        case 53: return "Drizzle"
        case 55: return "Heavy drizzle"
        case 56, 57: return "Freezing drizzle"
        case 61: return "Light rain"
        case 63: return "Rain"
        case 65: return "Heavy rain"
        case 66, 67: return "Freezing rain"
        case 71: return "Light snow"
        case 73: return "Snow"
        case 75: return "Heavy snow"
        case 77: return "Snow grains"
        case 80: return "Light showers"
        case 81: return "Showers"
        case 82: return "Heavy showers"
        case 85, 86: return "Snow showers"
        case 95: return "Thunderstorm"
        case 96, 99: return "Thunderstorm with hail"
        default: return "Unknown"
        }
    }

    /// "yyyy-MM-dd" for `date` in the given calendar (the user's, for matching calendar days).
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

fileprivate extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
