import AppKit
import ApplicationServices
import CoreBluetooth
import CoreLocation
import EventKit
import SwiftUI

/// Privacy permissions NotchApp uses.
enum Permission: String, CaseIterable, Identifiable {
    case accessibility, calendar, automation, bluetooth, location, audioCapture

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: "Accessibility"
        case .calendar: "Calendars"
        case .automation: "Automation"
        case .bluetooth: "Bluetooth"
        case .location: "Location"
        case .audioCapture: "System Audio Recording"
        }
    }

    var detail: String {
        switch self {
        case .accessibility: "Volume & brightness keys, HUDs"
        case .calendar: "Upcoming events and meeting alerts"
        case .automation: "Controlling Music and Spotify"
        case .bluetooth: "Device connect alerts with battery level"
        case .location: "Local weather and travel time"
        case .audioCapture: "Live waveform of what's playing"
        }
    }

    var symbol: String {
        switch self {
        case .accessibility: "accessibility"
        case .calendar: "calendar"
        case .automation: "gearshape.2.fill"
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .location: "location.fill"
        case .audioCapture: "waveform"
        }
    }

    var color: Color {
        switch self {
        case .accessibility: .blue
        case .calendar: .red
        case .automation: .gray
        case .bluetooth: .blue
        case .location: .blue
        case .audioCapture: .pink
        }
    }

    /// Anchor of the matching Privacy & Security pane.
    private var paneAnchor: String {
        switch self {
        case .accessibility: "Privacy_Accessibility"
        case .calendar: "Privacy_Calendars"
        case .automation: "Privacy_Automation"
        case .bluetooth: "Privacy_Bluetooth"
        case .location: "Privacy_LocationServices"
        case .audioCapture: "Privacy_ScreenCapture"
        }
    }

    var settingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(paneAnchor)")!
    }

    /// False for permissions macOS can't report or prompt for ahead of time.
    var canRequest: Bool { self != .automation && self != .audioCapture }
}

enum PermissionState: Equatable {
    case granted, denied, notDetermined, notAllowed, restricted, onDemand

    var label: String {
        switch self {
        case .granted: "Allowed"
        case .denied: "Denied"
        case .notDetermined: "Not requested"
        case .notAllowed: "Not allowed"
        case .restricted: "Restricted"
        case .onDemand: "Requested when used"
        }
    }

    var color: Color {
        switch self {
        case .granted: .green
        case .denied, .restricted: .red
        case .notDetermined, .notAllowed: .orange
        case .onDemand: .secondary
        }
    }
}

extension Notification.Name {
    /// Posted (main thread) when PermissionCenter sees any permission state change.
    static let notchPermissionsChanged = Notification.Name("NotchApp.permissionsChanged")
}

/// Live permission status. Event-driven: refreshes when the app becomes active, when a settings
/// window becomes key, on accessibility-trust changes and after each request — no polling.
final class PermissionCenter: NSObject, ObservableObject, CBCentralManagerDelegate, CLLocationManagerDelegate {
    static let shared = PermissionCenter()

    @Published private(set) var states: [Permission: PermissionState] = [:]

    private var observers: [NSObjectProtocol] = []
    private let eventStore = EKEventStore()
    private var locationManager: CLLocationManager?
    private var bluetoothManager: CBCentralManager?

    private override init() {
        super.init()
        refresh()
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                        queue: .main) { [weak self] _ in self?.refresh() })
        observers.append(nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil,
                                        queue: .main) { [weak self] _ in self?.refresh() })
        // Posted whenever any app's Accessibility trust changes; the TCC db updates shortly after.
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.refresh() }
        })
    }

    func state(_ p: Permission) -> PermissionState { states[p] ?? .notDetermined }

    func refresh() {
        var next: [Permission: PermissionState] = [:]
        for p in Permission.allCases { next[p] = Self.query(p) }
        guard next != states else { return }
        let first = states.isEmpty
        states = next
        // Services never prompt on their own; they start using a permission once it's granted.
        if !first { NotificationCenter.default.post(name: .notchPermissionsChanged, object: nil) }
    }

    private static func query(_ p: Permission) -> PermissionState {
        switch p {
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .notAllowed
        case .calendar:
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess, .authorized: return .granted
            case .writeOnly, .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .notDetermined
            @unknown default: return .notDetermined
            }
        case .bluetooth:
            switch CBManager.authorization {
            case .allowedAlways: return .granted
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .notDetermined
            @unknown default: return .notDetermined
            }
        case .location:
            switch CLLocationManager().authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse: return .granted
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .notDetermined
            @unknown default: return .notDetermined
            }
        case .automation, .audioCapture:
            return .onDemand
        }
    }

    /// Shows the system prompt (or, if already decided, nothing — use `openSettings`).
    func request(_ p: Permission) {
        switch p {
        case .accessibility:
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        case .calendar:
            eventStore.requestFullAccessToEvents { [weak self] _, _ in
                DispatchQueue.main.async { self?.refresh() }
            }
        case .bluetooth:
            // Creating a central manager triggers the prompt; the delegate callback refreshes.
            if bluetoothManager == nil { bluetoothManager = CBCentralManager(delegate: self, queue: .main) }
        case .location:
            if locationManager == nil {
                let m = CLLocationManager()
                m.delegate = self
                locationManager = m
            }
            locationManager?.requestWhenInUseAuthorization()
        case .automation, .audioCapture:
            openSettings(p)
        }
    }

    func openSettings(_ p: Permission) {
        NSWorkspace.shared.open(p.settingsURL)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        refresh()
        // Only needed for the prompt; the Activities module keeps its own manager.
        if CBManager.authorization != .notDetermined { bluetoothManager = nil }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async { self.refresh() }
    }

    // MARK: Reset

    private static var bundleID: String { Bundle.main.bundleIdentifier ?? "local.notchapp" }

    /// Asks for confirmation, runs `tccutil reset All <bundle id>`, then offers to relaunch.
    func confirmAndResetAll() {
        let confirm = NSAlert()
        confirm.messageText = "Reset all permissions?"
        confirm.informativeText = "NotchApp will lose access to Accessibility, Calendars, Bluetooth, Location, "
            + "Automation and audio recording. macOS asks again the next time each one is used."
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "Reset")
        confirm.addButton(withTitle: "Cancel")
        confirm.buttons.first?.hasDestructiveAction = true
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        let (ok, output) = Self.runTCCReset()
        refresh()
        let done = NSAlert()
        if ok {
            done.messageText = "Permissions reset"
            done.informativeText = "Relaunch NotchApp so the change takes full effect."
            done.addButton(withTitle: "Relaunch")
            done.addButton(withTitle: "Later")
            if done.runModal() == .alertFirstButtonReturn { Self.relaunch() }
        } else {
            done.messageText = "Couldn't reset permissions"
            done.informativeText = output.isEmpty ? "tccutil failed." : output
            done.alertStyle = .critical
            done.runModal()
        }
    }

    private static func runTCCReset() -> (Bool, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "All", bundleID]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return (false, error.localizedDescription)
        }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus == 0, out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Starts a fresh instance once this one has exited.
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }
}

/// One status row: icon, name, status, action button.
struct PermissionRow: View {
    let permission: Permission
    @ObservedObject var center = PermissionCenter.shared
    /// Onboarding shows "Allow" (prompt) for undecided permissions; Settings always offers "Open Settings".
    var promptWhenUndecided = false

    var body: some View {
        let state = center.state(permission)
        HStack(spacing: 10) {
            SettingsIcon(symbol: permission.symbol, color: permission.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(permission.title)
                Text(permission.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                Circle().fill(state.color).frame(width: 7, height: 7)
                Text(state.label).font(.caption).foregroundStyle(.secondary)
            }
            if permission.canRequest, state == .notDetermined || (promptWhenUndecided && state == .notAllowed) {
                Button("Allow") { center.request(permission) }.controlSize(.small)
            } else if !promptWhenUndecided || state != .granted {
                Button("Open Settings") { center.openSettings(permission) }.controlSize(.small)
            }
        }
    }
}

struct PermissionsPane: View {
    @ObservedObject var center = PermissionCenter.shared

    var body: some View {
        Form {
            Section {
                ForEach(Permission.allCases) { PermissionRow(permission: $0) }
            } footer: {
                Text("Automation and audio recording can't be checked ahead of time; macOS asks the first time they're used.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Text("Clear every decision so macOS asks again.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset All Permissions…") { center.confirmAndResetAll() }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { center.refresh() }
    }
}
