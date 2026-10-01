import EventKit
import Foundation
import MapKit

/// Calendar options (UserDefaults-backed).
final class CalendarSettings: ObservableObject {
    static let shared = CalendarSettings()
    private let d = UserDefaults.standard

    enum Layout: String, CaseIterable { case week, agenda }
    enum Transport: String, CaseIterable {
        case driving, walking, transit
        var mk: MKDirectionsTransportType {
            switch self {
            case .driving: return .automobile
            case .walking: return .walking
            case .transit: return .transit
            }
        }
        var symbol: String {
            switch self {
            case .driving: return "car.fill"
            case .walking: return "figure.walk"
            case .transit: return "tram.fill"
            }
        }
        var verb: String {
            switch self {
            case .driving: return "drive"
            case .walking: return "walk"
            case .transit: return "by transit"
            }
        }
    }

    static let leadChoices = [1, 2, 5, 10, 15]

    /// Calendar identifiers the user switched off (new calendars show by default).
    @Published var hiddenCalendars: Set<String> { didSet { d.set(Array(hiddenCalendars), forKey: "cal.hidden") } }
    @Published var alertLeadMinutes: Int { didSet { d.set(alertLeadMinutes, forKey: "cal.leadMinutes") } }
    @Published var alertAtStart: Bool { didSet { d.set(alertAtStart, forKey: "cal.alertAtStart") } }
    @Published var alertSound: Bool { didSet { d.set(alertSound, forKey: "cal.alertSound") } }
    @Published var quietDuringEvents: Bool { didSet { d.set(quietDuringEvents, forKey: "cal.quietDuringEvents") } }
    @Published var layout: Layout { didSet { d.set(layout.rawValue, forKey: "cal.layout") } }
    @Published var showWeather: Bool { didSet { d.set(showWeather, forKey: "cal.showWeather") } }
    @Published var timeToLeave: Bool { didSet { d.set(timeToLeave, forKey: "cal.timeToLeave") } }
    @Published var transport: Transport { didSet { d.set(transport.rawValue, forKey: "cal.transport") } }
    @Published var leaveBufferMinutes: Int { didSet { d.set(leaveBufferMinutes, forKey: "cal.leaveBuffer") } }
    @Published var hourlyChime: Bool { didSet { d.set(hourlyChime, forKey: "cal.hourlyChime") } }

    private init() {
        d.register(defaults: [
            "cal.leadMinutes": 5, "cal.alertAtStart": true, "cal.alertSound": false,
            "cal.quietDuringEvents": false, "cal.layout": Layout.week.rawValue, "cal.showWeather": true,
            "cal.timeToLeave": true, "cal.transport": Transport.driving.rawValue, "cal.leaveBuffer": 5,
            "cal.hourlyChime": false,
        ])
        hiddenCalendars = Set(d.stringArray(forKey: "cal.hidden") ?? [])
        alertLeadMinutes = d.integer(forKey: "cal.leadMinutes")
        alertAtStart = d.bool(forKey: "cal.alertAtStart")
        alertSound = d.bool(forKey: "cal.alertSound")
        quietDuringEvents = d.bool(forKey: "cal.quietDuringEvents")
        layout = Layout(rawValue: d.string(forKey: "cal.layout") ?? "") ?? .week
        showWeather = d.bool(forKey: "cal.showWeather")
        timeToLeave = d.bool(forKey: "cal.timeToLeave")
        transport = Transport(rawValue: d.string(forKey: "cal.transport") ?? "") ?? .driving
        leaveBufferMinutes = min(max(d.integer(forKey: "cal.leaveBuffer"), 0), 30)
        hourlyChime = d.bool(forKey: "cal.hourlyChime")
    }

    // MARK: Calendar list for Settings

    struct CalendarInfo: Identifiable {
        let id: String
        let title: String
        let source: String
        let color: CGColor
    }

    @Published private(set) var calendars: [CalendarInfo] = []
    private var listStore: EKEventStore?

    /// Reloads the calendar list (only when access was already granted; never prompts).
    func loadCalendars() {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { calendars = []; return }
        let store = listStore ?? EKEventStore()
        listStore = store
        calendars = store.calendars(for: .event)
            .map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title,
                                source: $0.source?.title ?? "", color: $0.cgColor) }
            .sorted { ($0.source, $0.title) < ($1.source, $1.title) }
    }

    func setShown(_ id: String, _ shown: Bool) {
        if shown { hiddenCalendars.remove(id) } else { hiddenCalendars.insert(id) }
    }
}
