import AppKit
import ServiceManagement
import SwiftUI

/// Settings window: System Settings-style sidebar + grouped form panes. (Owned by the Settings agent.)
enum SettingsWindow {
    private static var window: NSWindow?

    static func show(pane: SettingsPane? = nil) {
        if let pane { SettingsNavigation.shared.pane = pane }
        if window == nil {
            let host = NSHostingController(rootView: SettingsRoot())
            host.sizingOptions = []
            let w = NSWindow(contentViewController: host)
            w.title = "NotchApp Settings"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.toolbarStyle = .unified
            w.setContentSize(NSSize(width: 780, height: 600))
            w.contentMinSize = NSSize(width: 700, height: 460)
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

/// SettingsView with the environment objects it needs.
struct SettingsRoot: View {
    var body: some View {
        SettingsView()
            .environmentObject(AppSettings.shared)
            .environmentObject(LaunchAtLogin.shared)
            .environmentObject(GestureSettings.shared)
            .environmentObject(SettingsNavigation.shared)
    }
}

enum SettingsPaneGroup: String, CaseIterable, Identifiable {
    case notch, features, app
    var id: String { rawValue }
    var title: String {
        switch self {
        case .notch: "Notch"
        case .features: "Features"
        case .app: "App"
        }
    }
    var panes: [SettingsPane] { SettingsPane.allCases.filter { $0.group == self } }
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

    var subtitle: String {
        switch self {
        case .general: "How the notch opens, and how NotchApp starts."
        case .display: "Where the notch appears, its size, and when it gets out of the way."
        case .media: "The Now Playing player: source, controls and artwork."
        case .visualizer: "The animated bars next to the notch while music plays."
        case .huds: "Replace the system volume, brightness and keyboard overlays."
        case .activities: "Brief alerts in the notch for battery, devices, Focus and more."
        case .calendar: "Upcoming events, meeting alerts and local weather."
        case .lockScreen: "Widgets shown on the lock screen, under the clock."
        case .gestures: "Trackpad swipes on the notch."
        case .permissions: "What NotchApp can access. Nothing is requested until you allow it."
        case .about: "Version, URL scheme and onboarding."
        }
    }

    /// Extra search terms (setting names inside the pane).
    var keywords: [String] {
        switch self {
        case .general: ["hover", "open", "launch", "login", "startup", "menu bar", "icon"]
        case .display: ["screen", "monitor", "external", "simulated", "width", "height", "size", "hover",
                        "delay", "grow", "fullscreen", "mission control", "game", "screen sharing", "recording",
                        "outline", "blur", "idle", "now playing"]
        case .media: ["music", "spotify", "player", "source", "controls", "shuffle", "repeat", "artwork",
                      "explicit", "title", "ignore", "browser"]
        case .visualizer: ["waveform", "bars", "spectrum", "audio", "wave"]
        case .huds: ["volume", "brightness", "keyboard", "backlight", "bar", "style", "osd", "ddc",
                     "betterdisplay", "external", "percentage", "duration", "focus", "lock"]
        case .activities: ["battery", "charging", "low power", "bluetooth", "airpods", "focus", "track",
                           "unlock", "devices"]
        case .calendar: ["events", "meeting", "alert", "time to leave", "travel", "chime", "weather",
                         "temperature", "city", "location", "agenda", "week"]
        case .lockScreen: ["widgets", "lock", "screensaver", "awake", "card"]
        case .gestures: ["swipe", "trackpad", "haptic", "sensitivity", "reverse"]
        case .permissions: ["privacy", "accessibility", "calendar", "bluetooth", "location", "automation",
                            "audio", "reset"]
        case .about: ["version", "build", "url", "onboarding", "quit"]
        }
    }

    var group: SettingsPaneGroup {
        switch self {
        case .general, .display, .gestures: .notch
        case .media, .visualizer, .huds, .activities, .calendar, .lockScreen: .features
        case .permissions, .about: .app
        }
    }

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return title.lowercased().contains(q) || keywords.contains { $0.contains(q) }
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

/// Selected pane; shared so `SettingsWindow.show(pane:)` and URLs can jump to one. Remembered across launches.
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    private static let key = "settings.lastPane"

    @Published var pane: SettingsPane {
        didSet { UserDefaults.standard.set(pane.rawValue, forKey: Self.key) }
    }
    /// Sidebar search text.
    @Published var query = ""

    private init() {
        pane = SettingsPane(rawValue: UserDefaults.standard.string(forKey: Self.key) ?? "") ?? .general
    }
}

struct SettingsView: View {
    @EnvironmentObject var nav: SettingsNavigation

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: SettingsMetrics.sidebarWidth, ideal: SettingsMetrics.sidebarWidth,
                                                max: 280)

        } detail: {
            SettingsPaneView(pane: nav.pane)
                .id(nav.pane)
                .navigationTitle(nav.pane.title)
        }
        .searchable(text: $nav.query, placement: .sidebar, prompt: "Search")
        .toolbar(removing: .sidebarToggle)
        .frame(minWidth: 700, minHeight: 460)
    }

    private var sidebar: some View { SettingsSidebar() }
}

/// Sidebar: panes grouped into Notch / Features / App, filtered by the search field.
struct SettingsSidebar: View {
    @EnvironmentObject var nav: SettingsNavigation

    var body: some View {
        List(selection: selection) {
            let groups = SettingsPaneGroup.allCases
                .map { ($0, $0.panes.filter { $0.matches(nav.query) }) }
                .filter { !$0.1.isEmpty }
            ForEach(groups, id: \.0) { group, panes in
                Section(group.title) {
                    ForEach(panes) { pane in
                        Label {
                            Text(pane.title).lineLimit(1)
                        } icon: {
                            SettingsIcon(symbol: pane.symbol, color: pane.color)
                        }
                        .tag(pane)
                    }
                }
            }
            if groups.isEmpty {
                Text("No results").foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .onChange(of: nav.query) { _, q in
            // Jump to the first match while typing.
            let hits = SettingsPane.allCases.filter { $0.matches(q) }
            if !q.isEmpty, let first = hits.first, !hits.contains(nav.pane) { nav.pane = first }
        }
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
        case .display: SettingsPage(.display) { DisplaySettingsSection() }
        case .media: SettingsPage(.media) { MediaSettingsSection() }
        case .visualizer: SettingsPage(.visualizer) { WaveformSettingsSection() }
        case .huds:
            SettingsPage(.huds, accessory: { masterSwitch($settings.hudEnabled) }) {
                HUDSettingsSection().disabled(!settings.hudEnabled)
            }
        case .activities: SettingsPage(.activities) { ActivitiesSettingsSection() }
        case .calendar:
            SettingsPage(.calendar) {
                Section {
                    SettingToggle("Calendar & meeting alerts",
                                  detail: "Shows the Calendar tab and alerts before events start.",
                                  isOn: $settings.calendarEnabled)
                }
                CalendarSettingsSection()
            }
        case .lockScreen:
            SettingsPage(.lockScreen, accessory: { masterSwitch($settings.lockScreenWidgets) }) {
                LockScreenSettingsSection().disabled(!settings.lockScreenWidgets)
            }
        case .gestures: GesturesPane()
        case .permissions: PermissionsPane()
        case .about: AboutPane()
        }
    }

    private func masterSwitch(_ isOn: Binding<Bool>) -> some View {
        Toggle("Enabled", isOn: isOn).toggleStyle(.switch).labelsHidden().help("Turn this feature on or off")
    }
}

/// Kept for callers that wrap rows in a single grouped section.
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
        SettingsPage(.general) {
            Section("Opening") {
                SettingToggle("Open on hover",
                              detail: settings.openOnHover
                                  ? "Rest the pointer on the notch to open it. Adjust the delay in Display."
                                  : "Click the notch to open it.",
                              isOn: $settings.openOnHover)
            }
            Section("Startup") {
                launchAtLoginRow
                SettingToggle("Show in menu bar", detail: "A menu bar icon with Open, Settings… and Quit.",
                              isOn: $settings.menuBarIcon)
            }
        }
    }

    @ViewBuilder private var launchAtLoginRow: some View {
        SettingToggle("Launch at login", detail: login.statusText, isOn: $settings.launchAtLogin)
        if login.status == .requiresApproval {
            SettingRow("Needs approval", detail: "Allow NotchApp in System Settings › General › Login Items.") {
                Button("Open Login Items…") { login.openLoginItemsSettings() }
            }
        }
        if let error = login.lastError {
            SettingNote(text: error, symbol: "exclamationmark.triangle.fill", tint: .red)
        }
    }
}

struct GesturesPane: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var gestures: GestureSettings

    var body: some View {
        SettingsPage(.gestures, accessory: {
            Toggle("Swipe gestures", isOn: $settings.gesturesEnabled).toggleStyle(.switch).labelsHidden()
        }) {
            Section {
                gestureMap
            } header: {
                SectionHeader("Swipes")
            }
            Group {
                Section("Live activities") {
                    SettingToggle("Swipe up to dismiss", detail: "Swipe up on the closed notch to hide the current activity.",
                                  isOn: $gestures.swipeToDismiss)
                    SettingToggle("Swipe sideways to cycle",
                                  detail: "When several activities are recent (page dots show), swipe sideways on the "
                                      + "closed notch to switch between them. Takes precedence over skipping tracks.",
                                  isOn: $gestures.swipeToCycle)
                }
                Section("Feel") {
                    SettingPicker("Sensitivity", detail: "How far a swipe travels before it acts.",
                                  selection: $gestures.sensitivity, segmented: true) {
                        ForEach(GestureSettings.Sensitivity.allCases) { Text($0.title).tag($0) }
                    }
                    SettingToggle("Reverse swipe direction",
                                  detail: "By default swipes follow your fingers, whatever the Natural scrolling setting.",
                                  isOn: $gestures.reverseDirection)
                    SettingToggle("Haptic feedback", detail: "A light tap on the trackpad when a swipe registers.",
                                  isOn: $gestures.haptics)
                }
            }
            .disabled(!settings.gesturesEnabled)
        }
    }

    private var gestureMap: some View {
        let rows: [(String, String, String)] = [
            ("arrow.down", "Swipe down", "Open the notch"),
            ("arrow.up", "Swipe up", "Close the notch"),
            ("arrow.left.and.right", "Swipe sideways, closed", "Skip to the previous or next track"),
            ("arrow.left.and.right.square", "Swipe sideways, open", "Switch tabs"),
        ]
        return ForEach(rows, id: \.1) { symbol, title, action in
            LabeledContent {
                Text(action).foregroundStyle(.secondary)
            } label: {
                SettingLabel(title: title, symbol: symbol)
            }
            .opacity(settings.gesturesEnabled ? 1 : 0.5)
        }
    }
}

struct AboutPane: View {
    var body: some View {
        GeometryReader { geo in
            Form {
                Section {
                    VStack(spacing: 8) {
                        AppIconView(size: 72)
                        Text("NotchApp").font(.system(size: 20, weight: .semibold))
                        Text(Self.build == Self.shortVersion ? "Version \(Self.shortVersion)"
                                                            : "Version \(Self.shortVersion) · Build \(Self.build)")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                Section("URL scheme") {
                    ForEach(Self.urls, id: \.0) { url, what in
                        LabeledContent {
                            Text(what).foregroundStyle(.secondary)
                        } label: {
                            Text(url).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                }
                Section {
                    SettingRow("Onboarding", detail: "The welcome tour and permission checklist.") {
                        Button("Show Again") { OnboardingWindow.show() }
                    }
                    SettingRow("Quit NotchApp", detail: "Removes the notch until you open the app again.") {
                        Button("Quit") { NSApp.terminate(nil) }
                    }
                }
            }
            .formStyle(.grouped)
            .contentMargins(.horizontal, max(SettingsMetrics.minSideMargin,
                                             (geo.size.width - SettingsMetrics.maxContentWidth) / 2),
                            for: .scrollContent)
        }
    }

    static let urls: [(String, String)] = [
        ("notchapp://open", "Open the notch"),
        ("notchapp://open/home", "Open on Home"),
        ("notchapp://open/calendar", "Open on Calendar"),
        ("notchapp://open/shelf", "Open on Shelf"),
        ("notchapp://close", "Close the notch"),
        ("notchapp://settings", "Open Settings"),
    ]

    static var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? shortVersion
    }

    static var version: String {
        let short = shortVersion, b = build
        return b != short ? "\(short) (\(b))" : short
    }
}

/// App icon: the bundle's icon when it has one, otherwise a drawn black notch tile.
struct AppIconView: View {
    var size: CGFloat = 64

    var body: some View {
        if Bundle.main.infoDictionary?["CFBundleIconFile"] != nil || Bundle.main.infoDictionary?["CFBundleIconName"] != nil {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.24), Color(white: 0.08)], startPoint: .top, endPoint: .bottom))
                .frame(width: size, height: size)
                .overlay(alignment: .top) {
                    NotchShape(topRadius: size * 0.05, bottomRadius: size * 0.1)
                        .fill(.black)
                        .frame(width: size * 0.56, height: size * 0.2)
                        .overlay(alignment: .top) {
                            NotchOutline(topRadius: size * 0.05, bottomRadius: size * 0.1)
                                .stroke(.white.opacity(0.25), lineWidth: 0.75)
                        }
                }
                .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1.5)
        }
    }
}
