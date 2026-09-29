import AppKit
import SwiftUI

/// Display rows for the Settings window (a Form section). Owner: Display agent.
/// Persist new options in your own ObservableObject in this folder; don't grow Core/AppSettings.
struct DisplaySettingsSection: View {
    @ObservedObject private var display = DisplaySettings.shared
    @ObservedObject private var app = AppSettings.shared
    @StateObject private var screens = ScreenList()

    var body: some View {
        Section("Where") {
            SettingPicker("Show on", selection: $display.showOn) {
                ForEach(DisplaySettings.ShowOn.allCases) { Text($0.label).tag($0) }
            }
            .onChange(of: display.showOn) { _, mode in
                if mode == .specific, display.specificDisplayName.isEmpty, let first = screens.names.first {
                    specificName.wrappedValue = first
                }
            }
            if display.showOn == .specific {
                SettingPicker("Display", selection: specificName) {
                    ForEach(screens.names, id: \.self) { Text($0).tag($0) }
                    if !display.specificDisplayName.isEmpty, !screens.names.contains(display.specificDisplayName) {
                        Text("\(display.specificDisplayName) (not connected)").tag(display.specificDisplayName)
                    }
                }
            }
            SettingToggle("Simulated notch on displays without one",
                          detail: "Draws a notch-shaped pill under the menu bar on external displays.",
                          isOn: $display.simulateNotch)
            SettingToggle("On the lock screen",
                          detail: "Music controls, volume and brightness, and live activities while locked. Calendar, shelf and settings stay hidden.",
                          isOn: $display.showOnLockScreen)
        }

        Section {
            NotchSizePreview(display: display)
            SettingSlider("Width", value: $display.widthOffset, in: DisplaySettings.widthOffsetRange,
                          default: 0, defaultLabel: "Default", format: signedPoints)
            SettingSlider("Height", value: $display.heightOffset, in: DisplaySettings.heightOffsetRange,
                          default: 0, defaultLabel: "Default", format: signedPoints)
        } header: {
            SectionHeader("Size")
        } footer: {
            SectionFooter("Offsets from the standard size. A hardware notch can grow but never gets smaller than the camera cutout.")
        }

        Section("Behavior") {
            SettingSlider("Hover delay",
                          detail: app.openOnHover ? "How long the pointer rests on the notch before it opens."
                                                  : "Open on hover is off in General.",
                          value: $display.hoverDelay, in: DisplaySettings.hoverDelayRange, step: 0.05,
                          default: 0.15, format: { $0 < 0.001 ? "Instant" : String(format: "%.2f s", $0) })
                .disabled(!app.openOnHover)
            SettingToggle("Grow on hover", detail: "The closed notch swells slightly under the pointer.",
                          isOn: $display.hoverGrow)
            SettingPicker("When idle, show",
                          detail: "Beside the closed notch when no live activity is running. "
                              + "Calendar falls back to Now Playing once today's events are over.",
                          selection: $display.idleContent) {
                ForEach(DisplaySettings.IdleContent.allCases) { Text($0.label).tag($0) }
            }
        }

        Section {
            SettingToggle("When an app is fullscreen", isOn: $display.hideInFullscreen)
            SettingToggle("During Mission Control", detail: "Also App Exposé and Show Desktop. Needs Accessibility access.",
                          isOn: $display.hideInMissionControl)
            SettingToggle("While playing games",
                          detail: "When a game (App Store Games category or Steam) is the frontmost app.",
                          isOn: $display.hideWhileGaming)
            SettingToggle("From screen recordings & sharing",
                          detail: "The notch stays visible to you but is left out of screenshots, recordings and shared screens.",
                          isOn: $display.hideFromCapture)
        } header: {
            SectionHeader("Hide the notch")
        }

        Section("Look") {
            SettingToggle("Contrast outline",
                          detail: "A faint outline around the notch. Helps on dark wallpapers and external displays.",
                          isOn: $display.contrastOutline)
            SettingToggle("Soft bottom edge when open",
                          detail: "The open notch fades out through a blur instead of ending with a hard edge.",
                          isOn: $display.progressiveBlur)
        }
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
}

/// Static preview of the notch: closed (with the size offsets) and open (outline, soft edge).
private struct NotchSizePreview: View {
    @ObservedObject var display: DisplaySettings

    var body: some View {
        let base = Screens.simulatedBaseSize
        let w = max(60, base.width + display.widthOffset)
        let h = max(20, base.height + display.heightOffset)
        HStack(spacing: 12) {
            PreviewBackdrop(height: 92) {
                notch(width: w, height: h, top: 6, bottom: 12, soft: false)
            }
            .overlay(alignment: .bottomLeading) { caption("Closed") }
            PreviewBackdrop(height: 92) {
                openNotch
            }
            .frame(width: 210)
            .overlay(alignment: .bottomLeading) { caption("Open") }
        }
        .padding(.vertical, 4)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: display.widthOffset)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: display.heightOffset)
        .accessibilityHidden(true)
    }

    private var openNotch: some View {
        let soft = display.progressiveBlur
        return ZStack(alignment: .top) {
            notch(width: 160, height: 58 + (soft ? 14 : 0), top: 8, bottom: 16, soft: soft)
            VStack(spacing: 5) {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.3)).frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Capsule().fill(.white.opacity(0.55)).frame(width: 54, height: 4)
                        Capsule().fill(.white.opacity(0.3)).frame(width: 36, height: 4)
                    }
                    Spacer()
                }
                Capsule().fill(.white.opacity(0.2)).frame(height: 3)
            }
            .frame(width: 118)
            .padding(.top, 14)
        }
    }

    private func notch(width: CGFloat, height: CGFloat, top: CGFloat, bottom: CGFloat, soft: Bool) -> some View {
        let mask = LinearGradient(stops: [.init(color: .black, location: 0),
                                          .init(color: .black, location: soft ? 0.72 : 1),
                                          .init(color: .clear, location: 1)],
                                  startPoint: .top, endPoint: .bottom)
        return ZStack {
            NotchShape(topRadius: top, bottomRadius: bottom).fill(.black)
            if display.contrastOutline {
                NotchOutline(topRadius: top, bottomRadius: bottom).stroke(.white.opacity(0.45), lineWidth: 1)
            }
        }
        .frame(width: width + top * 2, height: height)
        .mask(mask)
        .shadow(color: .black.opacity(soft ? 0 : 0.25), radius: 4, y: 2)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(.black.opacity(0.25)))
            .padding(6)
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
