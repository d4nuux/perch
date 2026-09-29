import SwiftUI

/// LockScreen sections for the Settings window. Owner: LockScreen agent.
/// The master "Lock screen widgets" switch lives in AppSettings (pane header); these are the per-widget options.
struct LockScreenSettingsSection: View {
    @ObservedObject private var s = LockScreenSettings.shared

    var body: some View {
        Section {
            ForEach(s.order) { w in row(w) }
        } header: {
            SectionHeader("Widgets", detail: "Shown top to bottom in this order. Use the arrows to reorder.")
        } footer: {
            if s.isEnabled(.nextEvent) {
                SectionFooter("Event titles are visible to anyone who can see your locked screen. Uses existing calendar access only.")
            }
        }

        Section("Look") {
            SettingPicker("Card style", selection: $s.cardStyle, segmented: true) {
                ForEach(LockCardStyle.allCases) { Text($0.title).tag($0) }
            }
            SettingSlider("Vertical position", detail: "Move the widgets up or down from their spot under the clock.",
                          value: $s.verticalOffset, in: LockScreenSettings.offsetRange, step: 10, default: 0,
                          defaultLabel: "Default", format: signedPoints)
        }

        Section("Behavior") {
            SettingToggle("Volume slider under Now Playing",
                          detail: "The volume keys work on the lock screen either way.",
                          isOn: $s.showVolume)
            SettingToggle("Keep display awake while locked",
                          detail: "Prevents idle display sleep only while the screen is locked. Uses more power.",
                          isOn: $s.keepAwake)
            SettingToggle("Show widgets over the screensaver", isOn: $s.showOnScreensaver)
        }
    }

    private func row(_ w: LockWidget) -> some View {
        let i = s.order.firstIndex(of: w) ?? 0
        let on = s.isEnabled(w)
        return HStack(spacing: 10) {
            Image(systemName: w.symbol)
                .foregroundStyle(on ? Color.accentColor : .secondary)
                .frame(width: 20)
            Text(w.title).foregroundStyle(on ? .primary : .secondary)
            Spacer()
            HStack(spacing: 2) {
                Button { s.move(w, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(i == 0).help("Move up")
                Button { s.move(w, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(i == s.order.count - 1).help("Move down")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            Toggle(w.title, isOn: Binding(get: { s.isEnabled(w) }, set: { s.setEnabled(w, $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}
