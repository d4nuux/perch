import AppKit
import Combine
import ServiceManagement

/// Keeps `AppSettings.launchAtLogin` and the real `SMAppService.mainApp` registration in sync.
/// Created at launch (see `GestureService.init`) so the toggle reflects reality before the
/// settings window is ever opened.
final class LaunchAtLogin: ObservableObject {
    static let shared = LaunchAtLogin()

    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var lastError: String?

    private let settings = AppSettings.shared
    private var cancellable: AnyCancellable?

    private init() {
        refresh(syncToggle: true)
        // `dropFirst` skips the current value. `receive(on:)` defers until after the property is
        // actually set (@Published emits in willSet), so `refresh` can safely write it back.
        cancellable = settings.$launchAtLogin
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in self?.apply(enabled) }
    }

    var statusText: String {
        switch status {
        case .enabled: "Enabled"
        case .requiresApproval: "Waiting for approval in System Settings"
        case .notRegistered: "Off"
        case .notFound: "Not available (app bundle not found)"
        @unknown default: "Unknown"
        }
    }

    /// Re-reads the service status. With `syncToggle`, the setting is overwritten to match.
    func refresh(syncToggle: Bool = false) {
        status = SMAppService.mainApp.status
        guard syncToggle else { return }
        let actual = status == .enabled || status == .requiresApproval
        if settings.launchAtLogin != actual { settings.launchAtLogin = actual }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func apply(_ enabled: Bool) {
        let service = SMAppService.mainApp
        let registered = service.status == .enabled || service.status == .requiresApproval
        // No-op when already in the requested state (also covers write-backs from `refresh`).
        guard enabled != registered else { status = service.status; return }
        do {
            if enabled { try service.register() } else { try service.unregister() }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        // Reflect what actually happened (e.g. revert the toggle if registration failed).
        refresh(syncToggle: true)
    }
}
