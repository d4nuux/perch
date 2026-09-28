import AppKit
import ServiceManagement
import SwiftUI

/// Settings window: System Settings-style sidebar + grouped form panes. (Owned by the Settings agent.)
enum SettingsWindow {
    private static var window: NSWindow?

    static func show(pane: SettingsPane? = nil) {
        if let pane { SettingsNavigation.shared.pane = pane }
        if window == nil {
            let host = NSHostingController(rootView: SettingsView()
                .environmentObject(AppSettings.shared)
                .environmentObject(LaunchAtLogin.shared)
                .environmentObject(GestureSettings.shared)
                .environmentObject(SettingsNavigation.shared))
            host.sizingOptions = []
            let w = NSWindow(contentViewController: host)
            w.title = "NotchApp Settings"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 720, height: 520))
            w.contentMinSize = NSSize(width: 640, height: 420)
            w.isReleasedWhenClosed = false
            w.center()
            w.setFrameAutosaveName("NotchAppSettings")
            window = w
        }
        LaunchAtLogin.shared.refresh(syncToggle: true)
        PermissionCenter.shared.refresh()
        // Accessory (LSUIElement) apps are never frontmost on their own; activate first.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, display, media, visualizer, huds, activities, calendar, lockScreen, gestures, permissions, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .display: "Display"
        case .media: "Media"
        case .visualizer: "Visualizer"
        case .huds: "HUDs"
        case .activities: "Live Activities"
        case .calendar: "Calendar & Weather"
        case .lockScreen: "Lock Screen"
        case .gestures: "Gestures"
        case .permissions: "Permissions"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .display: "display"
        case .media: "music.note"
        case .visualizer: "waveform"
        case .huds: "speaker.wave.2.fill"
        case .activities: "bolt.fill"
        case .calendar: "calendar"
        case .lockScreen: "lock.fill"
        case .gestures: "hand.draw.fill"
        case .permissions: "hand.raised.fill"
        case .about: "info"
        }
    }

    var color: Color {
        switch self {
        case .general: .gray
        case .display: .blue
        case .media: .pink
        case .visualizer: .purple
        case .huds: .indigo
        case .activities: .green
        case .calendar: .red
        case .lockScreen: .cyan
        case .gestures: .teal
        case .permissions: .blue
        case .about: .gray
        }
    }
}

/// Selected pane; shared so `SettingsWindow.show(pane:)` and URLs can jump to one.
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var pane: SettingsPane = .general
}

/// White SF Symbol on a colored rounded square, like System Settings.
struct SettingsIcon: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}

struct SettingsView: View {
    @EnvironmentObject var nav: SettingsNavigation

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: selection) { pane in
                Label {
                    Text(pane.title)
                } icon: {
                    SettingsIcon(symbol: pane.symbol, color: pane.color)
                }
                .tag(pane)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            SettingsPaneView(pane: nav.pane)
                .id(nav.pane)
                .navigationTitle(nav.pane.title)
        }
        .frame(minWidth: 640, minHeight: 420)
    }

    /// Non-optional pane binding; ignores deselection (clicking empty sidebar space).
    private var selection: Binding<SettingsPane?> {
        Binding(get: { nav.pane }, set: { if let p = $0 { nav.pane = p } })
    }
}

struct SettingsPaneView: View {
    let pane: SettingsPane
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        switch pane {
        case .general: GeneralPane()
        case .display: FormPane { DisplaySettingsSection() }
        case .media: FormPane { MediaSettingsSection() }
        case .visualizer: FormPane { WaveformSettingsSection() }
        case .huds:
            FormPane {
                Toggle("Volume & brightness HUD", isOn: $settings.hudEnabled)
                HUDSettingsSection()
            }
        case .activities:
            FormPane { ActivitiesSettingsSection() }
        case .calendar:
            FormPane {
                Toggle("Calendar & meeting alerts", isOn: $settings.calendarEnabled)
                CalendarSettingsSection()
            }
        case .lockScreen:
            FormPane {
                Toggle("Lock screen widgets", isOn: $settings.lockScreenWidgets)
                LockScreenSettingsSection()
            }
        case .gestures: GesturesPane()
        case .permissions: PermissionsPane()
        case .about: AboutPane()
        }
    }
}

/// `Form { Section { content } }.formStyle(.grouped)`.
struct FormPane<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        Form { Section { content() } }
            .formStyle(.grouped)
    }
}

// MARK: - Panes

struct GeneralPane: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var login: LaunchAtLogin

    var body: some View {
        Form {
            Section {
                Toggle("Open on hover", isOn: $settings.openOnHover)
                    .help("When off, click the notch to open it.")
                launchAtLoginRow
                Toggle("Show in menu bar", isOn: $settings.menuBarIcon)
                    .help("A menu bar icon with Open, Settings… and Quit.")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var launchAtLoginRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Launch at login", isOn: $settings.launchAtLogin)
            Text(login.statusText).font(.caption).foregroundStyle(.secondary)
            if login.status == .requiresApproval {
                HStack {
                    Text("Allow NotchApp in System Settings › General › Login Items.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Login Items…") { login.openLoginItemsSettings() }
                        .controlSize(.small)
                }
            }
            if let error = login.lastError {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct GesturesPane: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var gestures: GestureSettings

    var body: some View {
        Form {
            Section {
                Toggle("Swipe gestures", isOn: $settings.gesturesEnabled)
                    .help("Swipe down on the notch to open, up to close, sideways to switch tabs or tracks.")
                Group {
                    Toggle("Reverse swipe direction", isOn: $gestures.reverseDirection)
                        .help("By default swipes follow your fingers, whatever the Natural scrolling setting.")
                    Toggle("Haptic feedback", isOn: $gestures.haptics)
                    Toggle("Swipe up to dismiss live activity", isOn: $gestures.swipeToDismiss)
                        .help("Swipe up on the closed notch to hide the current activity.")
                    Picker("Sensitivity", selection: $gestures.sensitivity) {
                        ForEach(GestureSettings.Sensitivity.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                .disabled(!settings.gesturesEnabled)
            } footer: {
                Text("Closed: swipe down to open, sideways to skip tracks. Open: swipe up to close, sideways to switch tabs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct AboutPane: View {
    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    SettingsIcon(symbol: "rectangle.topthird.inset.filled", color: .black, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("NotchApp").font(.headline)
                        Text("Version \(Self.version)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                LabeledContent("URL scheme") {
                    Text("notchapp://open · open/home · open/calendar · open/shelf · close · settings")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Button("Show Onboarding Again") { OnboardingWindow.show() }
                    Spacer()
                    Button("Quit NotchApp") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        if let build = info?["CFBundleVersion"] as? String, build != short { return "\(short) (\(build))" }
        return short
    }
}
