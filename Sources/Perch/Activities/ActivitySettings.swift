import Foundation

/// Activities-module options (the category toggles for charging / Bluetooth / track changes stay in
/// AppSettings). UserDefaults-backed; keys are prefixed "activities.".
final class ActivitySettings: ObservableObject {
    static let shared = ActivitySettings()
    private let d = UserDefaults.standard

    static let thresholdRange = 5...50
    /// Second, critical warning. Also shown while quiet mode is on.
    static let criticalThreshold = 10
    /// Connected Bluetooth devices warn below this level (once per connection).
    static let deviceLowThreshold = 20

    @Published var lowBatteryThreshold: Int {
        didSet {
            let v = min(max(lowBatteryThreshold, Self.thresholdRange.lowerBound), Self.thresholdRange.upperBound)
            if v != lowBatteryThreshold { lowBatteryThreshold = v } // no observer re-entry inside didSet
            d.set(v, forKey: "activities.lowBatteryThreshold")
        }
    }
    @Published var lowBatterySound: Bool { didSet { d.set(lowBatterySound, forKey: "activities.lowBatterySound") } }
    @Published var showTimeRemaining: Bool { didSet { d.set(showTimeRemaining, forKey: "activities.showTimeRemaining") } }
    @Published var hidePercentage: Bool { didSet { d.set(hidePercentage, forKey: "activities.hidePercentage") } }
    @Published var fullyCharged: Bool { didSet { d.set(fullyCharged, forKey: "activities.fullyCharged") } }
    @Published var lowPowerMode: Bool { didSet { d.set(lowPowerMode, forKey: "activities.lowPowerMode") } }
    @Published var deviceLowBattery: Bool { didSet { d.set(deviceLowBattery, forKey: "activities.deviceLowBattery") } }
    @Published var focus: Bool { didSet { d.set(focus, forKey: "activities.focus") } }
    @Published var unlock: Bool { didSet { d.set(unlock, forKey: "activities.unlock") } }
    /// 3D swing-in device symbols, drawn battery with fill / bolt / low pulse, AirPods L/R/case.
    @Published var animatedVisuals: Bool { didSet { d.set(animatedVisuals, forKey: "activities.animatedVisuals") } }

    /// Descending, e.g. [20, 10]; just [t] when the user threshold is at or below the critical one.
    var lowThresholds: [Int] {
        Array(Set([lowBatteryThreshold, min(lowBatteryThreshold, Self.criticalThreshold)])).sorted(by: >)
    }

    private init() {
        d.register(defaults: [
            "activities.lowBatteryThreshold": 20, "activities.lowBatterySound": false,
            "activities.showTimeRemaining": true, "activities.hidePercentage": false,
            "activities.fullyCharged": true, "activities.lowPowerMode": true,
            "activities.deviceLowBattery": true, "activities.focus": true, "activities.unlock": false,
            "activities.animatedVisuals": true,
        ])
        lowBatteryThreshold = min(max(d.integer(forKey: "activities.lowBatteryThreshold"), 5), 50)
        lowBatterySound = d.bool(forKey: "activities.lowBatterySound")
        showTimeRemaining = d.bool(forKey: "activities.showTimeRemaining")
        hidePercentage = d.bool(forKey: "activities.hidePercentage")
        fullyCharged = d.bool(forKey: "activities.fullyCharged")
        lowPowerMode = d.bool(forKey: "activities.lowPowerMode")
        deviceLowBattery = d.bool(forKey: "activities.deviceLowBattery")
        focus = d.bool(forKey: "activities.focus")
        unlock = d.bool(forKey: "activities.unlock")
        animatedVisuals = d.bool(forKey: "activities.animatedVisuals")
    }
}
