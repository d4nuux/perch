import Foundation

/// Gesture preferences (UserDefaults-backed). The on/off switch itself is `AppSettings.gesturesEnabled`.
final class GestureSettings: ObservableObject {
    static let shared = GestureSettings()
    private let d = UserDefaults.standard

    /// Distance (in scroll points) a swipe must travel before it acts.
    enum Sensitivity: Int, CaseIterable, Identifiable {
        case high = 25, medium = 40, low = 60
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .high: "High"
            case .medium: "Medium"
            case .low: "Low"
            }
        }
    }

    /// Reverse every swipe direction (by default directions follow the fingers,
    /// regardless of the system "Natural scrolling" setting).
    @Published var reverseDirection: Bool { didSet { d.set(reverseDirection, forKey: "gesture.reverse") } }
    @Published var haptics: Bool { didSet { d.set(haptics, forKey: "gesture.haptics") } }
    /// Swipe up on the collapsed notch dismisses the current live activity.
    @Published var swipeToDismiss: Bool { didSet { d.set(swipeToDismiss, forKey: "gesture.swipeToDismiss") } }
    @Published var sensitivity: Sensitivity { didSet { d.set(sensitivity.rawValue, forKey: "gesture.threshold") } }

    private init() {
        d.register(defaults: [
            "gesture.reverse": false, "gesture.haptics": true,
            "gesture.swipeToDismiss": true, "gesture.threshold": Sensitivity.medium.rawValue,
        ])
        reverseDirection = d.bool(forKey: "gesture.reverse")
        haptics = d.bool(forKey: "gesture.haptics")
        swipeToDismiss = d.bool(forKey: "gesture.swipeToDismiss")
        sensitivity = Sensitivity(rawValue: d.integer(forKey: "gesture.threshold")) ?? .medium
    }
}
