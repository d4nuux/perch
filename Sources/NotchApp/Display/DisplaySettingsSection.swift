import AppKit
import SwiftUI

/// Display rows for the Settings window (a Form section). Owner: Display agent.
/// Persist new options in your own ObservableObject in this folder; don't grow Core/AppSettings.
struct DisplaySettingsSection: View {
    @ObservedObject private var display = DisplaySettings.shared
    @ObservedObject private var app = AppSettings.shared
    @StateObject private var screens = ScreenList()

    var body: some View {
        Picker("Show on", selection: $display.showOn) {
            ForEach(DisplaySettings.ShowOn.allCases) { Text($0.label).tag($0) }
        }
        .onChange(of: display.showOn) { _, mode in
            if mode == .specific, display.specificDisplayName.isEmpty, let first = screens.names.first {
                specificName.wrappedValue = first
            }
        }
        if display.showOn == .specific {
            Picker("Display", selection: specificName) {
                ForEach(screens.names, id: \.self) { Text($0).tag($0) }
                if !display.specificDisplayName.isEmpty, !screens.names.contains(display.specificDisplayName) {
                    Text("\(display.specificDisplayName) (not connected)").tag(display.specificDisplayName)
                }
            }
        }
        Toggle("Simulated notch on displays without one", isOn: $display.simulateNotch)
            .help("Draws a notch-shaped pill under the menu bar on external displays.")
        sliderRow("Notch width", value: $display.widthOffset, range: DisplaySettings.widthOffsetRange,
                  step: 1) { "\($0 > 0 ? "+" : "")\(Int($0)) pt" }
        sliderRow("Notch height", value: $display.heightOffset, range: DisplaySettings.heightOffsetRange,
                  step: 1) { "\($0 > 0 ? "+" : "")\(Int($0)) pt" }
        sliderRow("Hover delay", value: $display.hoverDelay, range: DisplaySettings.hoverDelayRange,
                  step: 0.05) { String(format: "%.2f s", $0) }
            .disabled(!app.openOnHover)
        Toggle("Grow on hover", isOn: $display.hoverGrow)
        Toggle("Hide from screen recording & sharing", isOn: $display.hideFromCapture)
        Toggle("Hide when an app is fullscreen", isOn: $display.hideInFullscreen)
        Toggle("Hide during Mission Control", isOn: $display.hideInMissionControl)
            .help("Also App Exposé and Show Desktop. Needs Accessibility access.")
        Toggle("Hide while playing games", isOn: $display.hideWhileGaming)
            .help("Fades the notch out while a game (App Store games category or Steam) is the frontmost app.")
        Toggle("Contrast outline", isOn: $display.contrastOutline)
            .help("Draws a faint outline around the notch. Helps on dark wallpapers and external displays.")
        Toggle("Soft bottom edge when open", isOn: $display.progressiveBlur)
            .help("The open notch fades out through a blur at its bottom edge instead of a hard edge.")
        Picker("When idle show", selection: $display.idleContent) {
            ForEach(DisplaySettings.IdleContent.allCases) { Text($0.label).tag($0) }
        }
        .help("Shown around the closed notch when no live activity is active. "
              + "Calendar falls back to Now Playing when no event is left today.")
    }

    private var specificName: Binding<String> {
        Binding(
            get: { display.specificDisplayName },
            set: { name in
                display.specificDisplayName = name
                if let s = NSScreen.screens.first(where: { $0.localizedName == name }) {
                    display.specificDisplayID = s.displayID
                }
            }
        )
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                           step: Double, format: @escaping (Double) -> String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Slider(value: value, in: range, step: step).frame(minWidth: 160)
                Text(format(value.wrappedValue))
                    .monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
        }
    }
}

/// Connected display names, refreshed when displays change.
private final class ScreenList: ObservableObject {
    @Published private(set) var names: [String] = []
    private var observer: NSObjectProtocol?

    init() {
        refresh()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    private func refresh() {
        var seen = Set<String>()
        names = NSScreen.screens.map(\.localizedName).filter { seen.insert($0).inserted }
    }
}
