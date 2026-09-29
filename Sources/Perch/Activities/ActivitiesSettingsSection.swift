import SwiftUI

/// Activities sections for the Settings window. Owner: Activities agent.
/// Category toggles for charging / Bluetooth / track changes live in AppSettings; everything else
/// in ActivitySettings.
struct ActivitiesSettingsSection: View {
    @ObservedObject private var app = AppSettings.shared
    @ObservedObject private var opts = ActivitySettings.shared

    var body: some View {
        Section {
            SettingToggle("Charging & battery", detail: "When you plug in or unplug, and when the battery runs low.",
                          isOn: $app.chargingActivity)
            Group {
                SettingToggle("Show time remaining", detail: "Time to empty when you unplug, time to full while charging.",
                              isOn: $opts.showTimeRemaining)
                SettingToggle("Hide percentage", isOn: $opts.hidePercentage)
                SettingToggle("Fully charged alert",
                              detail: "At 100%, or when charging stops at the Optimized Charging / charge limit.",
                              isOn: $opts.fullyCharged)
                SettingStepper("Low battery alert",
                               detail: "A second, critical alert follows at \(ActivitySettings.criticalThreshold)%.",
                               value: $opts.lowBatteryThreshold, in: ActivitySettings.thresholdRange, step: 5,
                               format: { "\($0)%" })
                SettingToggle("Low battery sound", isOn: $opts.lowBatterySound)
            }
            .disabled(!app.chargingActivity)
            SettingToggle("Low Power Mode", detail: "When Low Power Mode turns on or off.", isOn: $opts.lowPowerMode)
        } header: {
            SectionHeader("Battery")
        }

        Section("Devices") {
            SettingToggle("Bluetooth devices", detail: "Headphones, keyboards and mice connecting, with battery level.",
                          isOn: $app.bluetoothActivity)
            SettingToggle("Device low battery warning",
                          detail: "Once per connection, when a connected device drops below \(ActivitySettings.deviceLowThreshold)%.",
                          isOn: $opts.deviceLowBattery)
                .disabled(!app.bluetoothActivity)
            SettingToggle("Animated device visuals",
                          detail: "Devices swing in, the battery fills with a bolt pulse, AirPods show left / right / case.",
                          isOn: $opts.animatedVisuals)
        }

        Section {
            SettingToggle("Focus", detail: "When a Focus mode turns on or off.", isOn: $opts.focus)
            if opts.focus {
                SettingNote(text: "Grant Perch Full Disk Access to show which Focus mode turned on.")
            }
            SettingToggle("Track changes", detail: "The new song's artwork and title when the track changes.",
                          isOn: $app.trackChangeActivity)
            SettingToggle("Unlock", detail: "A brief lock icon when you unlock the Mac.", isOn: $opts.unlock)
        } header: {
            SectionHeader("System")
        }
    }
}
