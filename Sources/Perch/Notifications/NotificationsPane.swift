import AppKit
import SwiftUI

/// Apps listed in "Choose apps": suggestions that are installed, plus every app usernoted knows.
final class NotificationAppList: ObservableObject {
    static let shared = NotificationAppList()

    struct Entry: Identifiable {
        let info: AppInfo
        let count: Int
        var id: String { info.bundleID }
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var readFromDB = false
    private let queue = DispatchQueue(label: "perch.notifications.apps", qos: .utility)

    /// Re-reads the app table (only with Full Disk Access). Icons and names resolve off main.
    func reload() {
        queue.async { [weak self] in
            var counts: [String: Int] = [:]
            var fromDB = false
            if NotificationDBLocation.hasFullDiskAccess, let url = NotificationDBLocation.resolve(),
               let db = NotificationDB(url: url) {
                for a in db.apps() { counts[a.bundleID.lowercased(), default: 0] += a.count }
                db.close()
                fromDB = true
            }
            var ids = AppCatalog.suggested
            for id in counts.keys.sorted() where !ids.contains(id) { ids.append(id) }
            let own = (Bundle.main.bundleIdentifier ?? "local.notchapp").lowercased()
            let entries = ids.compactMap { id -> Entry? in
                guard id != own, !id.hasPrefix("_system_center_") else { return nil }
                let info = AppInfo.lookup(id)
                guard info.isInstalled else { return nil }
                return Entry(info: info, count: counts[id] ?? 0)
            }
            .sorted { a, b in
                let ra = Self.rank(a.info.bundleID), rb = Self.rank(b.info.bundleID)
                return ra != rb ? ra < rb : a.info.name.localizedCaseInsensitiveCompare(b.info.name) == .orderedAscending
            }
            DispatchQueue.main.async {
                self?.entries = entries
                self?.readFromDB = fromDB
            }
        }
    }

    private static func rank(_ id: String) -> Int {
        if AppCatalog.emailApps.contains(id) { return 0 }
        if AppCatalog.isBrowser(id) { return 1 }
        if AppCatalog.chatApps.contains(id) { return 2 }
        return 3
    }
}

/// Settings › Notifications.
struct NotificationsPane: View {
    @ObservedObject var settings = NotificationSettings.shared
    @ObservedObject var apps = NotificationAppList.shared
    @ObservedObject var permissions = PermissionCenter.shared

    private var hasAccess: Bool { permissions.state(.fullDiskAccess) == .granted }

    var body: some View {
        SettingsPage(.notifications, accessory: {
            Toggle("Enabled", isOn: $settings.enabled).toggleStyle(.switch).labelsHidden()
                .help("Mirror notifications into the notch")
        }) {
            Section {
                PermissionRow(permission: .fullDiskAccess)
                if settings.enabled, !hasAccess {
                    SettingNote(text: "Perch reads the Notification Center database, which macOS only allows with "
                                + "Full Disk Access. Add Perch in Privacy & Security › Full Disk Access.",
                                symbol: "exclamationmark.triangle.fill", tint: .orange)
                }
            } header: {
                SectionHeader("Access")
            } footer: {
                SectionFooter("Perch only reads new notifications as they arrive. Nothing is stored on disk or sent anywhere.")
            }

            Group {
                Section {
                    SettingPicker("Mirror", selection: $settings.filter, segmented: true) {
                        ForEach(NotificationSettings.Filter.allCases) { Text($0.title).tag($0) }
                    }
                    if settings.filter == .email {
                        SettingNote(text: "Mail, Outlook, Spark, Superhuman and other mail apps, plus webmail "
                                    + "(Gmail, Outlook.com, …) in Chrome, Safari, Edge, Arc and their web apps.")
                    } else {
                        ForEach(apps.entries) { AppToggleRow(entry: $0, settings: settings) }
                        SettingToggle("Browsers: webmail only",
                                      detail: "For browsers above, mirror only Gmail, Outlook.com and other webmail sites.",
                                      isOn: $settings.browsersWebmailOnly)
                    }
                } header: {
                    SectionHeader("Apps")
                } footer: {
                    if settings.filter == .chosen, !apps.readFromDB {
                        SectionFooter("More apps appear here once Perch has Full Disk Access.")
                    }
                }

                Section("Preview") {
                    SettingSlider("Show for", value: $settings.duration, in: NotificationSettings.durationRange,
                                  step: 1, default: NotificationSettings.defaultDuration,
                                  format: { "\(Int($0)) s" })
                    SettingToggle("Copy button for one-time codes",
                                  detail: "Verification codes get a Copy button right in the notch.",
                                  isOn: $settings.detectCodes)
                    SettingToggle("Show previews on lock screen",
                                  detail: "Off: only the app name and \u{201C}New message\u{201D} while locked.",
                                  isOn: $settings.previewsWhenLocked)
                    SettingToggle("Play sound", detail: "A soft tick when a notification appears.", isOn: $settings.sound)
                }

                Section {
                    SettingRow("Avoid double banners",
                               detail: "Turn off banners for these apps in System Settings › Notifications.") {
                        Button("Open Notifications…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                        }
                    }
                } header: {
                    SectionHeader("Tip")
                }
            }
            .disabled(!settings.enabled)
        }
        .onAppear {
            permissions.refresh()
            apps.reload()
        }
    }
}

private struct AppToggleRow: View {
    let entry: NotificationAppList.Entry
    @ObservedObject var settings: NotificationSettings

    var body: some View {
        let id = entry.info.bundleID
        Toggle(isOn: Binding(get: { settings.isChosen(id) }, set: { settings.setChosen(id, $0) })) {
            HStack(spacing: 10) {
                AppIcon(image: entry.info.icon, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.info.name)
                    Text(detail).font(SettingsMetrics.detailFont).foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.switch)
    }

    private var detail: String {
        let id = entry.info.bundleID
        var parts: [String] = []
        if AppCatalog.emailApps.contains(id) { parts.append("Email") }
        else if AppCatalog.isBrowser(id) { parts.append("Browser") }
        else if AppCatalog.chatApps.contains(id) { parts.append("Chat") }
        if entry.count > 0 { parts.append("\(entry.count) in Notification Center") }
        return parts.isEmpty ? id : parts.joined(separator: " · ")
    }
}
