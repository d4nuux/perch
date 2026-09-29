import Foundation

/// Display / shell preferences (screen targeting, simulated notch, hover, hiding, idle content).
/// UserDefaults-backed; keys are prefixed "display.".
final class DisplaySettings: ObservableObject {
    static let shared = DisplaySettings()

    enum ShowOn: String, CaseIterable, Identifiable {
        case builtIn, main, all, specific
        var id: String { rawValue }
        var label: String {
            switch self {
            case .builtIn: "Built-in display"
            case .main: "Main display"
            case .all: "All displays"
            case .specific: "Specific display"
            }
        }
    }

    enum IdleContent: String, CaseIterable, Identifiable {
        case nowPlaying, calendar, none
        var id: String { rawValue }
        var label: String {
            switch self {
            case .nowPlaying: "Now Playing"
            case .calendar: "Next calendar event"
            case .none: "Nothing"
            }
        }
    }

    static let widthOffsetRange: ClosedRange<Double> = -40...40
    static let heightOffsetRange: ClosedRange<Double> = -8...8
    static let hoverDelayRange: ClosedRange<Double> = 0...1

    private let d = UserDefaults.standard

    @Published var showOn: ShowOn { didSet { d.set(showOn.rawValue, forKey: "display.showOn") } }
    /// localizedName of the chosen display for `.specific` (IDs aren't stable across reboots/ports).
    @Published var specificDisplayName: String { didSet { d.set(specificDisplayName, forKey: "display.specificName") } }
    /// Last seen CGDirectDisplayID for the chosen display; used to disambiguate identical names.
    @Published var specificDisplayID: UInt32 { didSet { d.set(Int(specificDisplayID), forKey: "display.specificID") } }
    @Published var simulateNotch: Bool { didSet { d.set(simulateNotch, forKey: "display.simulateNotch") } }
    @Published var widthOffset: Double { didSet { d.set(widthOffset, forKey: "display.widthOffset") } }
    @Published var heightOffset: Double { didSet { d.set(heightOffset, forKey: "display.heightOffset") } }
    @Published var hoverDelay: Double { didSet { d.set(hoverDelay, forKey: "display.hoverDelay") } }
    @Published var hoverGrow: Bool { didSet { d.set(hoverGrow, forKey: "display.hoverGrow") } }
    @Published var hideFromCapture: Bool { didSet { d.set(hideFromCapture, forKey: "display.hideFromCapture") } }
    @Published var hideInFullscreen: Bool { didSet { d.set(hideInFullscreen, forKey: "display.hideInFullscreen") } }
    /// Hairline white outline around the notch shape (dark wallpapers, simulated notches).
    @Published var contrastOutline: Bool { didSet { d.set(contrastOutline, forKey: "display.contrastOutline") } }
    /// Expanded notch's bottom edge fades out through a blur instead of ending hard.
    @Published var progressiveBlur: Bool { didSet { d.set(progressiveBlur, forKey: "display.progressiveBlur") } }
    /// Fade the notch out while Mission Control / App Exposé / Show Desktop is active.
    @Published var hideInMissionControl: Bool { didSet { d.set(hideInMissionControl, forKey: "display.hideInMissionControl") } }
    /// Fade the notch out while a game is the frontmost app.
    @Published var hideWhileGaming: Bool { didSet { d.set(hideWhileGaming, forKey: "display.hideWhileGaming") } }
    @Published var idleContent: IdleContent { didSet { d.set(idleContent.rawValue, forKey: "display.idleContent") } }

    private init() {
        d.register(defaults: [
            "display.showOn": ShowOn.builtIn.rawValue,
            "display.specificName": "",
            "display.specificID": 0,
            "display.simulateNotch": true,
            "display.widthOffset": 0.0,
            "display.heightOffset": 0.0,
            "display.hoverDelay": 0.15,
            "display.hoverGrow": true,
            "display.hideFromCapture": false,
            "display.hideInFullscreen": true,
            "display.idleContent": IdleContent.nowPlaying.rawValue,
            "display.contrastOutline": false,
            "display.progressiveBlur": false,
            "display.hideInMissionControl": true,
            "display.hideWhileGaming": true,
        ])
        showOn = ShowOn(rawValue: d.string(forKey: "display.showOn") ?? "") ?? .builtIn
        specificDisplayName = d.string(forKey: "display.specificName") ?? ""
        specificDisplayID = UInt32(truncatingIfNeeded: d.integer(forKey: "display.specificID"))
        simulateNotch = d.bool(forKey: "display.simulateNotch")
        widthOffset = d.double(forKey: "display.widthOffset")
        heightOffset = d.double(forKey: "display.heightOffset")
        hoverDelay = d.double(forKey: "display.hoverDelay")
        hoverGrow = d.bool(forKey: "display.hoverGrow")
        hideFromCapture = d.bool(forKey: "display.hideFromCapture")
        hideInFullscreen = d.bool(forKey: "display.hideInFullscreen")
        contrastOutline = d.bool(forKey: "display.contrastOutline")
        progressiveBlur = d.bool(forKey: "display.progressiveBlur")
        hideInMissionControl = d.bool(forKey: "display.hideInMissionControl")
        hideWhileGaming = d.bool(forKey: "display.hideWhileGaming")
        idleContent = IdleContent(rawValue: d.string(forKey: "display.idleContent") ?? "") ?? .nowPlaying
    }
}
