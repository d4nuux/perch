import SwiftUI

/// LockScreen rows for the Settings window (a Form section). Owner: LockScreen agent.
/// The master "Lock screen widgets" toggle lives in AppSettings; these are the per-widget options.
struct LockScreenSettingsSection: View {
    @ObservedObject private var s = LockScreenSettings.shared

    var body: some View {
        ForEach(s.order) { w in row(w) }

        if s.isEnabled(.nextEvent) {
            Text("Event titles are visible to anyone who can see your locked screen. Uses existing calendar access only.")
                .font(.caption).foregroundStyle(.secondary)
        }

        Picker("Card style", selection: $s.cardStyle) {
            ForEach(LockCardStyle.allCases) { Text($0.title).tag($0) }
        }

        LabeledContent("Vertical position") {
            HStack(spacing: 8) {
                Slider(value: $s.verticalOffset, in: LockScreenSettings.offsetRange, step: 10)
                    .frame(width: 180)
                Button("Reset") { s.verticalOffset = 0 }
                    .disabled(s.verticalOffset == 0)
            }
        }

        Toggle("Keep display awake while locked", isOn: $s.keepAwake)
            .help("Prevents idle display sleep only while the screen is locked. Uses more power.")
        Toggle("Show widgets over the screensaver", isOn: $s.showOnScreensaver)
    }

    private func row(_ w: LockWidget) -> some View {
        let i = s.order.firstIndex(of: w) ?? 0
        return HStack(spacing: 8) {
            Image(systemName: w.symbol).frame(width: 20)
            Text(w.title)
            Spacer()
            Button { s.move(w, by: -1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless).disabled(i == 0).help("Move up")
            Button { s.move(w, by: 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless).disabled(i == s.order.count - 1).help("Move down")
            Toggle(w.title, isOn: Binding(get: { s.isEnabled(w) }, set: { s.setEnabled(w, $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}
