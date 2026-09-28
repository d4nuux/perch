import Foundation

/// One widget on the lock screen. Raw values are persisted; don't rename.
enum LockWidget: String, CaseIterable, Identifiable {
    case nowPlaying, battery, weather, nextEvent, bluetooth

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nowPlaying: "Now Playing"
        case .battery: "Battery"
        case .weather: "Weather"
        case .nextEvent: "Next Event"
        case .bluetooth: "Bluetooth Devices"
        }
    }

    var symbol: String {
        switch self {
        case .nowPlaying: "play.circle"
        case .battery: "battery.75"
        case .weather: "cloud.sun"
        case .nextEvent: "calendar"
        case .bluetooth: "airpods"
        }
    }
}

enum LockCardStyle: String, CaseIterable, Identifiable {
    case frosted, clear, solid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .frosted: "Frosted"
        case .clear: "Clear"
        case .solid: "Solid"
        }
    }
}

/// Lock-screen widget options (UserDefaults-backed). The master on/off stays in
/// `AppSettings.lockScreenWidgets`.
final class LockScreenSettings: ObservableObject {
    static let shared = LockScreenSettings()
    private let d = UserDefaults.standard

    /// Display order of all widgets (enabled or not).
    @Published var order: [LockWidget] { didSet { d.set(order.map(\.rawValue), forKey: K.order) } }
    @Published var enabled: Set<LockWidget> { didSet { d.set(enabled.map(\.rawValue), forKey: K.enabled) } }
    @Published var cardStyle: LockCardStyle { didSet { d.set(cardStyle.rawValue, forKey: K.style) } }
    /// Points; positive moves the widgets down from their default spot below the clock.
    @Published var verticalOffset: Double { didSet { d.set(verticalOffset, forKey: K.offset) } }
    /// Prevent idle display sleep while locked (IOPM assertion held only while locked).
    @Published var keepAwake: Bool { didSet { d.set(keepAwake, forKey: K.keepAwake) } }
    /// Also show the widgets while the screensaver runs.
    @Published var showOnScreensaver: Bool { didSet { d.set(showOnScreensaver, forKey: K.screensaver) } }

    static let offsetRange: ClosedRange<Double> = -200...200

    private enum K {
        static let order = "lockScreen.order"
        static let enabled = "lockScreen.enabled"
        static let style = "lockScreen.cardStyle"
        static let offset = "lockScreen.verticalOffset"
        static let keepAwake = "lockScreen.keepAwake"
        static let screensaver = "lockScreen.showOnScreensaver"
    }

    private init() {
        d.register(defaults: [
            K.order: LockWidget.allCases.map(\.rawValue),
            // Next Event is off by default: event titles would be visible on the locked screen.
            K.enabled: [LockWidget.nowPlaying, .battery, .weather, .bluetooth].map(\.rawValue),
            K.style: LockCardStyle.frosted.rawValue,
            K.offset: 0.0,
            K.keepAwake: false,
            K.screensaver: false,
        ])
        var o = (d.stringArray(forKey: K.order) ?? []).compactMap(LockWidget.init(rawValue:))
        o = o.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        o += LockWidget.allCases.filter { !o.contains($0) }
        order = o
        enabled = Set((d.stringArray(forKey: K.enabled) ?? []).compactMap(LockWidget.init(rawValue:)))
        cardStyle = LockCardStyle(rawValue: d.string(forKey: K.style) ?? "") ?? .frosted
        verticalOffset = min(max(d.double(forKey: K.offset), Self.offsetRange.lowerBound), Self.offsetRange.upperBound)
        keepAwake = d.bool(forKey: K.keepAwake)
        showOnScreensaver = d.bool(forKey: K.screensaver)
    }

    func isEnabled(_ w: LockWidget) -> Bool { enabled.contains(w) }

    func setEnabled(_ w: LockWidget, _ on: Bool) {
        if on { enabled.insert(w) } else { enabled.remove(w) }
    }

    /// Moves `w` by `delta` positions (-1 up, +1 down), clamped.
    func move(_ w: LockWidget, by delta: Int) {
        guard let i = order.firstIndex(of: w) else { return }
        let j = min(max(i + delta, 0), order.count - 1)
        guard i != j else { return }
        order.swapAt(i, j)
    }
}
