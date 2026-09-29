import SwiftUI

/// Activities rows for the Settings window (a Form section). Owner: Activities agent.
/// Category toggles for charging / Bluetooth / track changes live in AppSettings; everything else
/// in ActivitySettings.
struct ActivitiesSettingsSection: View {
    @ObservedObject private var app = AppSettings.shared
    @ObservedObject private var opts = ActivitySettings.shared

    var body: some View {
        Group {
            Toggle("Charging & battery", isOn: $app.chargingActivity)
            Group {
                Toggle("Show time remaining", isOn: $opts.showTimeRemaining)
                    .help("Time to empty when you unplug, time to full while charging.")
                Toggle("Hide percentage", isOn: $opts.hidePercentage)
                Toggle("Fully charged alert", isOn: $opts.fullyCharged)
                    .help("At 100%, or when charging stops at the Optimized Charging / charge limit.")
                Stepper(value: $opts.lowBatteryThreshold, in: ActivitySettings.thresholdRange, step: 5) {
                    LabeledContent("Low battery alert", value: "\(opts.lowBatteryThreshold)%")
                }
                .help("A second, critical alert follows at \(ActivitySettings.criticalThreshold)%.")
                Toggle("Low battery sound", isOn: $opts.lowBatterySound)
            }
            .disabled(!app.chargingActivity)
            Toggle("Low Power Mode", isOn: $opts.lowPowerMode)
            Toggle("Bluetooth devices", isOn: $app.bluetoothActivity)
            Toggle("Device low battery warning", isOn: $opts.deviceLowBattery)
                .help("Once per connection, when a connected device drops below \(ActivitySettings.deviceLowThreshold)%.")
                .disabled(!app.bluetoothActivity)
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Focus", isOn: $opts.focus)
                Text("Grant NotchApp Full Disk Access to show which Focus mode turned on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Track changes", isOn: $app.trackChangeActivity)
            Toggle("Unlock", isOn: $opts.unlock)
                .help("A brief lock icon when you unlock the Mac.")
            Toggle("Animated device visuals", isOn: $opts.animatedVisuals)
                .help("Devices swing in, the battery fills with a bolt pulse, AirPods show left / right / case.")
        }
    }
}
