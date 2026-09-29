import SwiftUI

/// HUD sections for the Settings window. Owner: HUD agent. The pane header carries the master
/// switch (`AppSettings.hudEnabled`) and disables this whole view when it's off.
struct HUDSettingsSection: View {
    @ObservedObject private var s = HUDSettings.shared

    var body: some View {
        Section("Show a HUD for") {
            SettingToggle("Volume", detail: "Volume keys and mute.", isOn: $s.volumeEnabled)
            if s.volumeEnabled {
                SettingToggle("Output device changes", detail: "Briefly shows the new output device, e.g. when AirPods connect.",
                              isOn: $s.showDeviceChanges)
                    .padding(.leading, 16)
            }
            SettingToggle("Brightness", detail: "Display brightness keys.", isOn: $s.brightnessEnabled)
            SettingToggle("Keyboard backlight", isOn: $s.keyboardEnabled)
        }

        Section {
            HUDPreview(settings: s)
            SettingToggle("Same style for every HUD", detail: "Turn off to pick a bar style per HUD.",
                          isOn: $s.linkStyles)
            if s.linkStyles {
                stylePicker("Bar style", $s.style)
            } else {
                stylePicker("Volume bar", $s.volumeStyle)
                stylePicker("Brightness bar", $s.brightnessStyle)
                stylePicker("Keyboard bar", $s.keyboardStyle)
            }
            SettingToggle("Show percentage", isOn: $s.showPercentage)
            SettingToggle("Show label", detail: "\"Brightness\", \"Keyboard\", or the output device name for volume.",
                          isOn: $s.showLabel)
        } header: {
            SectionHeader("Look")
        }

        Section("Timing") {
            SettingPicker("Animation", detail: "How the bar moves between levels.", selection: $s.animation,
                          segmented: true) {
                ForEach(HUDAnimationSpeed.allCases) { Text($0.title).tag($0) }
            }
            SettingSlider("Stays up for", detail: "After the last key press.", value: $s.duration, in: 1...3,
                          step: 0.5, default: 1.5, format: { String(format: "%.1f s", $0) })
        }

        Section {
            ruleRow("Show on lock screen",
                    detail: "Off: while the screen is locked, keys go to macOS and the system overlay shows.",
                    $s.volumeOnLockScreen, $s.brightnessOnLockScreen, $s.keyboardOnLockScreen)
            ruleRow("Hide during Focus",
                    detail: "While a Focus is on, keys go to macOS and the system overlay shows.",
                    $s.volumeHideInFocus, $s.brightnessHideInFocus, $s.keyboardHideInFocus)
        } header: {
            SectionHeader("Lock screen & Focus")
        }

        Section {
            SettingPicker("Brightness keys", detail: externalDetail, selection: $s.externalBrightness) {
                ForEach(ExternalBrightnessMode.allCases) { Text($0.title).tag($0) }
            }
            .disabled(!s.brightnessEnabled)
        } header: {
            SectionHeader("External displays")
        } footer: {
            SectionFooter("Brightness keys adjust the display under the pointer. DDC talks to the monitor directly "
                          + "(Apple Silicon); BetterDisplay uses its CLI while the app runs. Auto tries DDC first.")
        }
    }

    private var externalDetail: String {
        switch s.externalBrightness {
        case .off: "External displays are left alone."
        case .ddc: "Talk to the monitor over DDC."
        case .betterDisplay: "Use BetterDisplay's command line tool."
        case .auto: "DDC first, then BetterDisplay."
        }
    }

    private func ruleRow(_ title: String, detail: String, _ volume: Binding<Bool>, _ brightness: Binding<Bool>,
                         _ keyboard: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingLabel(title: title, detail: detail)
            HStack(spacing: 16) {
                Toggle("Volume", isOn: volume).disabled(!s.volumeEnabled)
                Toggle("Brightness", isOn: brightness).disabled(!s.brightnessEnabled)
                Toggle("Keyboard", isOn: keyboard).disabled(!s.keyboardEnabled)
            }
            .toggleStyle(.checkbox)
        }
        .padding(.vertical, 2)
    }

    private func stylePicker(_ title: String, _ binding: Binding<HUDBarStyle>) -> some View {
        SettingPicker(title, selection: binding) {
            ForEach(HUDBarStyle.allCases) { Text($0.title).tag($0) }
        }
    }
}

/// Static notch HUD mock-ups using the real HUD views, so style / label / percentage changes show here.
private struct HUDPreview: View {
    @ObservedObject var settings: HUDSettings

    private static let samples: [HUDLevel] = [
        sample(.volume, 0.62), sample(.brightness, 0.45), sample(.keyboard, 0.8),
    ]

    private static func sample(_ kind: HUDKind, _ level: Double) -> HUDLevel {
        let l = HUDLevel(kind: kind)
        l.level = level
        return l
    }

    var body: some View {
        let shown = settings.linkStyles ? [Self.samples[0]] : Self.samples
        VStack(spacing: 8) {
            ForEach(shown, id: \.kind) { state in
                row(state).opacity(settings.isEnabled(state.kind) ? 1 : 0.35)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            LinearGradient(colors: [Color(white: 0.22), Color(white: 0.12)], startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func row(_ state: HUDLevel) -> some View {
        HStack(spacing: 0) {
            HUDLeading(state: state)
            Spacer(minLength: 70)
            HUDTrailing(state: state)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(minWidth: 330)
        .frame(height: 32)
        .background(NotchShape(topRadius: 6, bottomRadius: 12).fill(.black))
        .fixedSize()
        .environment(\.colorScheme, .dark)
    }
}
