import Foundation

/// User preferences, persisted in UserDefaults. Every feature reads its toggle from here.
/// (Don't use @State/@AppStorage-style macros: the Command Line Tools SDK lacks the SwiftUI macro plugin.)
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var openOnHover: Bool { didSet { d.set(openOnHover, forKey: "openOnHover") } }
    @Published var gesturesEnabled: Bool { didSet { d.set(gesturesEnabled, forKey: "gesturesEnabled") } }
    @Published var hudEnabled: Bool { didSet { d.set(hudEnabled, forKey: "hudEnabled") } }
    @Published var chargingActivity: Bool { didSet { d.set(chargingActivity, forKey: "chargingActivity") } }
    @Published var bluetoothActivity: Bool { didSet { d.set(bluetoothActivity, forKey: "bluetoothActivity") } }
    @Published var trackChangeActivity: Bool { didSet { d.set(trackChangeActivity, forKey: "trackChangeActivity") } }
    @Published var calendarEnabled: Bool { didSet { d.set(calendarEnabled, forKey: "calendarEnabled") } }
    @Published var lockScreenWidgets: Bool { didSet { d.set(lockScreenWidgets, forKey: "lockScreenWidgets") } }
    @Published var launchAtLogin: Bool { didSet { d.set(launchAtLogin, forKey: "launchAtLogin") } }

    private init() {
        d.register(defaults: [
            "openOnHover": true, "gesturesEnabled": true, "hudEnabled": true,
            "chargingActivity": true, "bluetoothActivity": true, "trackChangeActivity": true,
            "calendarEnabled": true, "lockScreenWidgets": true, "launchAtLogin": false,
        ])
        openOnHover = d.bool(forKey: "openOnHover")
        gesturesEnabled = d.bool(forKey: "gesturesEnabled")
        hudEnabled = d.bool(forKey: "hudEnabled")
        chargingActivity = d.bool(forKey: "chargingActivity")
        bluetoothActivity = d.bool(forKey: "bluetoothActivity")
        trackChangeActivity = d.bool(forKey: "trackChangeActivity")
        calendarEnabled = d.bool(forKey: "calendarEnabled")
        lockScreenWidgets = d.bool(forKey: "lockScreenWidgets")
        launchAtLogin = d.bool(forKey: "launchAtLogin")
    }
}
