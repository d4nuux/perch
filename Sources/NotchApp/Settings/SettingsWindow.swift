import AppKit
import ServiceManagement
import SwiftUI

/// Settings window. (Owned by the Settings/Gestures agent.)
enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView()
                .environmentObject(AppSettings.shared)
                .environmentObject(LaunchAtLogin.shared))
            host.sizingOptions = []
            let w = NSWindow(contentViewController: host)
            w.title = "NotchApp Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.setContentSize(NSSize(width: 520, height: 440))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        LaunchAtLogin.shared.refresh(syncToggle: true)
        // Accessory (LSUIElement) apps are never frontmost on their own; activate first.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var login: LaunchAtLogin

    var body: some View {
        Form {
            Section("General") {
                Toggle("Open on hover", isOn: $settings.openOnHover)
                    .help("When off, click the notch to open it.")
                Toggle("Swipe gestures", isOn: $settings.gesturesEnabled)
                    .help("Swipe down on the notch to open, up to close, sideways to switch tabs or tracks.")
                launchAtLoginRow
            }
            Section("Live Activities") {
                Toggle("Volume & brightness HUD", isOn: $settings.hudEnabled)
                Toggle("Charging & battery", isOn: $settings.chargingActivity)
                Toggle("Bluetooth devices", isOn: $settings.bluetoothActivity)
                Toggle("Track changes", isOn: $settings.trackChangeActivity)
                Toggle("Calendar alerts", isOn: $settings.calendarEnabled)
            }
            Section("Lock Screen") {
                Toggle("Lock screen widgets", isOn: $settings.lockScreenWidgets)
            }
            Section("About") {
                LabeledContent("Version", value: Self.version)
                HStack {
                    Spacer()
                    Button("Quit NotchApp") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 440)
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

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        if let build = info?["CFBundleVersion"] as? String, build != short { return "\(short) (\(build))" }
        return short
    }
}
