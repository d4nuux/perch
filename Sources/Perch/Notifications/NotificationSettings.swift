import Foundation

/// Notification-mirroring options. UserDefaults-backed; keys are prefixed "notifications.".
final class NotificationSettings: ObservableObject {
    static let shared = NotificationSettings()
    private let d = UserDefaults.standard

    enum Filter: String, CaseIterable, Identifiable {
        case email, chosen
        var id: String { rawValue }
        var title: String {
            switch self {
            case .email: "Only email apps"
            case .chosen: "Choose apps"
            }
        }
    }

    static let durationRange: ClosedRange<Double> = 3...12
    static let defaultDuration: Double = 5
    /// Pre-selected in "Choose apps" (lowercased bundle ids, the form usernoted stores).
    static let defaultChosen: Set<String> = [
        "com.apple.mail", "com.microsoft.outlook", "com.readdle.smartemail-mac", "com.superhuman.electron",
        "com.google.chrome",
    ]

    /// Master switch. Off until the user turns it on (it needs Full Disk Access).
    @Published var enabled: Bool { didSet { d.set(enabled, forKey: "notifications.enabled") } }
    @Published var filter: Filter { didSet { d.set(filter.rawValue, forKey: "notifications.filter") } }
    /// Lowercased bundle ids mirrored in `.chosen` mode.
    @Published var chosenApps: Set<String> {
        didSet { d.set(Array(chosenApps).sorted(), forKey: "notifications.chosenApps") }
    }
    /// Browsers in `.chosen` mode: only webmail sites (Gmail, Outlook.com, …) instead of every site.
    @Published var browsersWebmailOnly: Bool {
        didSet { d.set(browsersWebmailOnly, forKey: "notifications.browsersWebmailOnly") }
    }
    /// Sender, subject and codes while the screen is locked. Off = app name + "New message".
    @Published var previewsWhenLocked: Bool {
        didSet { d.set(previewsWhenLocked, forKey: "notifications.previewsWhenLocked") }
    }
    @Published var duration: Double { didSet { d.set(duration, forKey: "notifications.duration") } }
    @Published var detectCodes: Bool { didSet { d.set(detectCodes, forKey: "notifications.detectCodes") } }
    @Published var sound: Bool { didSet { d.set(sound, forKey: "notifications.sound") } }

    private init() {
        d.register(defaults: [
            "notifications.enabled": false, "notifications.filter": Filter.email.rawValue,
            "notifications.chosenApps": Array(Self.defaultChosen).sorted(),
            "notifications.browsersWebmailOnly": true, "notifications.previewsWhenLocked": false,
            "notifications.duration": Self.defaultDuration, "notifications.detectCodes": true,
            "notifications.sound": false,
        ])
        enabled = d.bool(forKey: "notifications.enabled")
        filter = Filter(rawValue: d.string(forKey: "notifications.filter") ?? "") ?? .email
        chosenApps = Set((d.stringArray(forKey: "notifications.chosenApps") ?? []).map { $0.lowercased() })
        browsersWebmailOnly = d.bool(forKey: "notifications.browsersWebmailOnly")
        previewsWhenLocked = d.bool(forKey: "notifications.previewsWhenLocked")
        let dur = d.double(forKey: "notifications.duration")
        duration = min(max(dur, Self.durationRange.lowerBound), Self.durationRange.upperBound)
        detectCodes = d.bool(forKey: "notifications.detectCodes")
        sound = d.bool(forKey: "notifications.sound")
    }

    func isChosen(_ bundleID: String) -> Bool { chosenApps.contains(bundleID.lowercased()) }

    func setChosen(_ bundleID: String, _ on: Bool) {
        let id = bundleID.lowercased()
        if on { chosenApps.insert(id) } else { chosenApps.remove(id) }
    }
}
