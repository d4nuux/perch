import SwiftUI

enum HUDBarStyle: String, CaseIterable, Identifiable {
    case solid, accent, gradient, segmented, glow, decibel
    var id: String { rawValue }
    var title: String {
        switch self {
        case .solid: "White"
        case .accent: "Accent color"
        case .gradient: "Gradient"
        case .segmented: "Segmented"
        case .glow: "Glow"
        case .decibel: "Decibel"
        }
    }
}

enum HUDAnimationSpeed: String, CaseIterable, Identifiable {
    case instant, fast, smooth
    var id: String { rawValue }
    var title: String {
        switch self {
        case .instant: "Instant"
        case .fast: "Fast"
        case .smooth: "Smooth"
        }
    }
    /// nil = no animation.
    var animation: Animation? {
        switch self {
        case .instant: nil
        case .fast: .spring(response: 0.16, dampingFraction: 0.95)
        case .smooth: .spring(response: 0.4, dampingFraction: 0.85)
        }
    }
}

/// HUD preferences (UserDefaults-backed). Main thread; HUDService mirrors what the tap thread needs.
/// `AppSettings.hudEnabled` stays the master switch.
final class HUDSettings: ObservableObject {
    static let shared = HUDSettings()
    private let d = UserDefaults.standard

    @Published var volumeEnabled: Bool { didSet { d.set(volumeEnabled, forKey: K.volume) } }
    @Published var brightnessEnabled: Bool { didSet { d.set(brightnessEnabled, forKey: K.brightness) } }
    @Published var keyboardEnabled: Bool { didSet { d.set(keyboardEnabled, forKey: K.keyboard) } }
    /// Brief HUD when the default output device changes (e.g. AirPods take over).
    @Published var showDeviceChanges: Bool { didSet { d.set(showDeviceChanges, forKey: K.deviceChanges) } }
    /// One bar style for every HUD. When off, each HUD has its own style.
    @Published var linkStyles: Bool { didSet { d.set(linkStyles, forKey: K.link) } }
    @Published var style: HUDBarStyle { didSet { d.set(style.rawValue, forKey: K.style) } }
    @Published var volumeStyle: HUDBarStyle { didSet { d.set(volumeStyle.rawValue, forKey: K.volumeStyle) } }
    @Published var brightnessStyle: HUDBarStyle { didSet { d.set(brightnessStyle.rawValue, forKey: K.brightnessStyle) } }
    @Published var keyboardStyle: HUDBarStyle { didSet { d.set(keyboardStyle.rawValue, forKey: K.keyboardStyle) } }
    @Published var animation: HUDAnimationSpeed { didSet { d.set(animation.rawValue, forKey: K.animation) } }
    @Published var showPercentage: Bool { didSet { d.set(showPercentage, forKey: K.percentage) } }
    @Published var showLabel: Bool { didSet { d.set(showLabel, forKey: K.label) } }
    /// Seconds the HUD stays up after the last change, 1...3.
    @Published var duration: Double { didSet { d.set(duration, forKey: K.duration) } }
    /// Per-HUD: handle keys while the screen is locked. Off = the system OSD handles them there.
    @Published var volumeOnLockScreen: Bool { didSet { d.set(volumeOnLockScreen, forKey: K.volumeLock) } }
    @Published var brightnessOnLockScreen: Bool { didSet { d.set(brightnessOnLockScreen, forKey: K.brightnessLock) } }
    @Published var keyboardOnLockScreen: Bool { didSet { d.set(keyboardOnLockScreen, forKey: K.keyboardLock) } }
    /// Per-HUD: step aside (system OSD) while a Focus is on.
    @Published var volumeHideInFocus: Bool { didSet { d.set(volumeHideInFocus, forKey: K.volumeFocus) } }
    @Published var brightnessHideInFocus: Bool { didSet { d.set(brightnessHideInFocus, forKey: K.brightnessFocus) } }
    @Published var keyboardHideInFocus: Bool { didSet { d.set(keyboardHideInFocus, forKey: K.keyboardFocus) } }
    /// How brightness keys drive an external display under the pointer.
    @Published var externalBrightness: ExternalBrightnessMode {
        didSet { d.set(externalBrightness.rawValue, forKey: K.external) }
    }

    private enum K {
        static let volume = "hud.volumeEnabled", brightness = "hud.brightnessEnabled", keyboard = "hud.keyboardEnabled"
        static let deviceChanges = "hud.showDeviceChanges", link = "hud.linkStyles", style = "hud.style"
        static let volumeStyle = "hud.volumeStyle", brightnessStyle = "hud.brightnessStyle"
        static let keyboardStyle = "hud.keyboardStyle", animation = "hud.animation"
        static let percentage = "hud.showPercentage", label = "hud.showLabel", duration = "hud.duration"
        static let volumeLock = "hud.volumeOnLockScreen", brightnessLock = "hud.brightnessOnLockScreen"
        static let keyboardLock = "hud.keyboardOnLockScreen", volumeFocus = "hud.volumeHideInFocus"
        static let brightnessFocus = "hud.brightnessHideInFocus", keyboardFocus = "hud.keyboardHideInFocus"
        static let external = "hud.externalBrightness"
    }

    private init() {
        d.register(defaults: [
            K.volume: true, K.brightness: true, K.keyboard: true, K.deviceChanges: true, K.link: true,
            K.style: HUDBarStyle.solid.rawValue, K.volumeStyle: HUDBarStyle.solid.rawValue,
            K.brightnessStyle: HUDBarStyle.solid.rawValue, K.keyboardStyle: HUDBarStyle.solid.rawValue,
            K.animation: HUDAnimationSpeed.fast.rawValue, K.percentage: false, K.label: false, K.duration: 1.5,
            K.volumeLock: true, K.brightnessLock: true, K.keyboardLock: true,
            K.volumeFocus: false, K.brightnessFocus: false, K.keyboardFocus: false,
            K.external: ExternalBrightnessMode.auto.rawValue,
        ])
        let defaults = UserDefaults.standard
        func style(_ key: String) -> HUDBarStyle { HUDBarStyle(rawValue: defaults.string(forKey: key) ?? "") ?? .solid }
        volumeEnabled = d.bool(forKey: K.volume)
        brightnessEnabled = d.bool(forKey: K.brightness)
        keyboardEnabled = d.bool(forKey: K.keyboard)
        showDeviceChanges = d.bool(forKey: K.deviceChanges)
        linkStyles = d.bool(forKey: K.link)
        self.style = style(K.style)
        volumeStyle = style(K.volumeStyle)
        brightnessStyle = style(K.brightnessStyle)
        keyboardStyle = style(K.keyboardStyle)
        animation = HUDAnimationSpeed(rawValue: d.string(forKey: K.animation) ?? "") ?? .fast
        showPercentage = d.bool(forKey: K.percentage)
        showLabel = d.bool(forKey: K.label)
        duration = min(max(d.double(forKey: K.duration), 1), 3)
        volumeOnLockScreen = d.bool(forKey: K.volumeLock)
        brightnessOnLockScreen = d.bool(forKey: K.brightnessLock)
        keyboardOnLockScreen = d.bool(forKey: K.keyboardLock)
        volumeHideInFocus = d.bool(forKey: K.volumeFocus)
        brightnessHideInFocus = d.bool(forKey: K.brightnessFocus)
        keyboardHideInFocus = d.bool(forKey: K.keyboardFocus)
        externalBrightness = ExternalBrightnessMode(rawValue: d.string(forKey: K.external) ?? "") ?? .auto
    }

    func showsOnLockScreen(_ kind: HUDKind) -> Bool {
        switch kind {
        case .volume: volumeOnLockScreen
        case .brightness: brightnessOnLockScreen
        case .keyboard: keyboardOnLockScreen
        }
    }

    func hidesInFocus(_ kind: HUDKind) -> Bool {
        switch kind {
        case .volume: volumeHideInFocus
        case .brightness: brightnessHideInFocus
        case .keyboard: keyboardHideInFocus
        }
    }

    func isEnabled(_ kind: HUDKind) -> Bool {
        switch kind {
        case .volume: volumeEnabled
        case .brightness: brightnessEnabled
        case .keyboard: keyboardEnabled
        }
    }

    func barStyle(for kind: HUDKind) -> HUDBarStyle {
        if linkStyles { return style }
        switch kind {
        case .volume: return volumeStyle
        case .brightness: return brightnessStyle
        case .keyboard: return keyboardStyle
        }
    }
}
