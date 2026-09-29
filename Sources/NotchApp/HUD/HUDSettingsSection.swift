import SwiftUI

/// HUD rows for the Settings window (a Form section). Owner: HUD agent.
struct HUDSettingsSection: View {
    @ObservedObject private var s = HUDSettings.shared

    var body: some View {
        Toggle("Volume HUD", isOn: $s.volumeEnabled)
        Toggle("Show output device changes", isOn: $s.showDeviceChanges)
            .disabled(!s.volumeEnabled)
            .help("Briefly shows the new output device, e.g. when AirPods connect.")
        Toggle("Brightness HUD", isOn: $s.brightnessEnabled)
        Toggle("Keyboard backlight HUD", isOn: $s.keyboardEnabled)
        ruleRow("Show on lock screen",
                help: "Off: while the screen is locked, keys go to macOS and the system OSD shows.",
                $s.volumeOnLockScreen, $s.brightnessOnLockScreen, $s.keyboardOnLockScreen)
        ruleRow("Hide during Focus",
                help: "While a Focus is on, keys go to macOS and the system OSD shows.",
                $s.volumeHideInFocus, $s.brightnessHideInFocus, $s.keyboardHideInFocus)
        Picker("External display brightness", selection: $s.externalBrightness) {
            ForEach(ExternalBrightnessMode.allCases) { Text($0.title).tag($0) }
        }
        .disabled(!s.brightnessEnabled)
        .help("Brightness keys adjust the display under the pointer. DDC talks to the monitor directly "
              + "(Apple Silicon); BetterDisplay uses its CLI when the app is running. Auto tries DDC first.")
        Toggle("Link HUD styles", isOn: $s.linkStyles)
            .help("One bar style for every HUD. Turn off to pick a style per HUD.")
        if s.linkStyles {
            stylePicker("Bar style", $s.style)
        } else {
            stylePicker("Volume bar", $s.volumeStyle)
            stylePicker("Brightness bar", $s.brightnessStyle)
            stylePicker("Keyboard bar", $s.keyboardStyle)
        }
        Picker("Animation", selection: $s.animation) {
            ForEach(HUDAnimationSpeed.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        Toggle("Show percentage", isOn: $s.showPercentage)
        Toggle("Show label", isOn: $s.showLabel)
            .help("\"Brightness\", \"Keyboard\", or the output device name for volume.")
        LabeledContent("Duration") {
            HStack {
                Slider(value: $s.duration, in: 1...3, step: 0.5)
                Text(String(format: "%.1f s", s.duration))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }

    private func ruleRow(_ title: String, help: String, _ volume: Binding<Bool>, _ brightness: Binding<Bool>,
                         _ keyboard: Binding<Bool>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 12) {
                Toggle("Volume", isOn: volume).disabled(!s.volumeEnabled)
                Toggle("Brightness", isOn: brightness).disabled(!s.brightnessEnabled)
                Toggle("Keyboard", isOn: keyboard).disabled(!s.keyboardEnabled)
            }
            .toggleStyle(.checkbox)
        }
        .help(help)
    }

    private func stylePicker(_ title: String, _ binding: Binding<HUDBarStyle>) -> some View {
        Picker(title, selection: binding) {
            ForEach(HUDBarStyle.allCases) { Text($0.title).tag($0) }
        }
    }
}
