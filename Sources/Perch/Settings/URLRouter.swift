import AppKit

/// Handles `perch://` URLs (`notchapp://` still accepted):
/// `open`, `open/home`, `open/calendar`, `open/shelf`, `close`, `settings`, `settings/<pane>`.
enum URLRouter {
    @discardableResult
    static func handle(_ url: URL, model: NotchModel?) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "perch" || scheme == "notchapp" else { return false }
        // perch://open/shelf → host "open", path "/shelf".
        let parts = ([url.host ?? ""] + url.pathComponents.filter { $0 != "/" })
            .map { $0.lowercased() }.filter { !$0.isEmpty }
        guard let command = parts.first else { return false }
        let arg = parts.dropFirst().first

        switch command {
        case "open":
            guard let model else { return false }
            let tab: NotchModel.Tab?
            switch arg {
            case nil: tab = nil
            case "home": tab = .home
            case "calendar": tab = .calendar
            case "shelf": tab = .shelf
            default: return false
            }
            model.holdOpenUntil = Date().addingTimeInterval(5)
            model.open(tab: tab)
        case "close":
            model?.close()
        case "settings", "preferences":
            let pane = arg.flatMap { a in SettingsPane.allCases.first { $0.rawValue.lowercased() == a } }
            SettingsWindow.show(pane: pane)
        case "onboarding":
            OnboardingWindow.show()
        default:
            return false
        }
        return true
    }
}
