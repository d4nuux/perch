import AppKit
import Combine
import CoreBluetooth
import SwiftUI

/// Charging, battery, Low Power Mode, Focus, Bluetooth device, unlock and track-change live
/// activities. (Owned by the Activities agent.)
///
/// Sources are event-driven (IOPS run-loop source, ProcessInfo / distributed notifications, a
/// vnode watch on the Focus DB, IOBluetooth notifications, Combine on NowPlaying). The only timer
/// is a 5-minute Bluetooth battery re-read that runs while a device is connected, because
/// IOBluetooth posts no battery-change notification.
final class ActivityService {
    private let context: NotchContext
    private let opts = ActivitySettings.shared
    private let presenter: ActivityPresenter
    private let power = PowerMonitor()
    private let bluetooth = BluetoothMonitor()
    private let focus = FocusMonitor()
    private let system = SystemStateMonitor()
    private var track: TrackChangeMonitor?
    private var cancellables: Set<AnyCancellable> = []

    /// Set on plug / unplug while macOS is still estimating; the first estimate refreshes the peek.
    private var awaitingEstimate = false
    /// Devices already warned about in their current connection.
    private var deviceLowWarned: Set<String> = []
    private var deviceBatteryTimer: Timer?

    init(context: NotchContext) {
        self.context = context
        presenter = ActivityPresenter(model: context.model)

        power.thresholds = { [opts] in opts.lowThresholds }
        power.onEvent = { [weak self] event in self?.handlePower(event) }
        power.start()

        system.onEvent = { [weak self] event in self?.handleSystem(event) }
        system.start()

        focus.onEvent = { [weak self] event in self?.handleFocus(event) }
        focus.start()

        bluetooth.onEvent = { [weak self] event in self?.handleBluetooth(event) }
        // Start IOBluetooth lazily: touching it triggers the Bluetooth TCC prompt, so don't do it
        // while the feature is switched off, or before the user has decided (onboarding asks).
        context.settings.$bluetoothActivity
            .removeDuplicates()
            .filter { $0 }
            .first()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.startBluetoothIfAllowed() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .notchPermissionsChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.context.settings.bluetoothActivity else { return }
                self.startBluetoothIfAllowed()
            }
            .store(in: &cancellables)

        opts.$deviceLowBattery
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateDeviceBatteryTimer() }
            .store(in: &cancellables)

        track = TrackChangeMonitor(nowPlaying: context.nowPlaying) { [weak self] in self?.handleTrackChange() }
    }

    private func startBluetoothIfAllowed() {
        guard CBManager.authorization != .notDetermined else { return }
        bluetooth.start()
        updateDeviceBatteryTimer()
    }

    // MARK: Charging / battery

    private func handlePower(_ event: PowerMonitor.Event) {
        guard context.settings.chargingActivity else { return }
        let hide = opts.hidePercentage, showTime = opts.showTimeRemaining
        switch event {
        case .pluggedIn(let s):
            awaitingEstimate = showTime && s.minutesToFull == nil
            presenter.present(ActivityViews.charging(level: s.level, minutesToFull: showTime ? s.minutesToFull : nil,
                                                     hidePercent: hide),
                              rank: .power, duration: 3)
        case .unplugged(let s):
            awaitingEstimate = showTime && s.minutesToEmpty == nil
            presenter.present(ActivityViews.unplugged(level: s.level, minutesToEmpty: showTime ? s.minutesToEmpty : nil,
                                                      hidePercent: hide),
                              rank: .power, duration: 3)
        case .updated(let s):
            // Refresh the plug / unplug peek in place once, when the first time estimate lands.
            guard awaitingEstimate else { return }
            let minutes = s.onAC ? s.minutesToFull : s.minutesToEmpty
            guard let minutes else { return }
            awaitingEstimate = false
            let view = s.onAC
                ? ActivityViews.charging(level: s.level, minutesToFull: minutes, hidePercent: hide)
                : ActivityViews.unplugged(level: s.level, minutesToEmpty: minutes, hidePercent: hide)
            presenter.update(view, duration: 2.5)
        case .fullyCharged(let s):
            awaitingEstimate = false
            guard opts.fullyCharged else { return }
            presenter.present(ActivityViews.fullyCharged(level: s.level, hidePercent: hide), rank: .power, duration: 3)
        case .low(let level, let critical):
            let minutes = showTime ? PowerMonitor.read()?.minutesToEmpty : nil
            presenter.present(ActivityViews.lowBattery(level: level, critical: critical, minutesToEmpty: minutes,
                                                       hidePercent: hide),
                              rank: .lowBattery, duration: critical ? 5 : 4, essential: critical)
            if opts.lowBatterySound, !context.model.quietMode || critical {
                (NSSound(named: "Funk") ?? NSSound(named: "Basso"))?.play()
            }
        }
    }

    // MARK: Low Power Mode / unlock

    private func handleSystem(_ event: SystemStateMonitor.Event) {
        switch event {
        case .lowPowerMode(let on):
            guard opts.lowPowerMode else { return }
            presenter.present(ActivityViews.lowPowerMode(on: on), rank: .lowPower, duration: 2.5)
        case .unlocked:
            guard opts.unlock else { return }
            presenter.present(ActivityViews.unlocked(), rank: .unlock, duration: 1.5, queueable: false)
        }
    }

    // MARK: Focus

    private func handleFocus(_ event: FocusMonitor.Event) {
        guard opts.focus else { return }
        switch event {
        case .changed(let on, let mode):
            presenter.present(ActivityViews.focus(on: on, name: mode?.name, symbol: mode?.symbol),
                              rank: .focus, duration: 2.5)
        }
    }

    // MARK: Bluetooth

    private func handleBluetooth(_ event: BluetoothMonitor.Event) {
        defer { updateDeviceBatteryTimer() }
        guard context.settings.bluetoothActivity else { return }
        switch event {
        case .connected(let device):
            deviceLowWarned.remove(device.address)
            if let b = device.battery, shouldWarn(device, level: b) {
                // One combined peek instead of a connect peek immediately replaced by a warning.
                presenter.present(ActivityViews.deviceLowBattery(device, level: b), rank: .deviceBattery, duration: 3.5)
            } else {
                presenter.present(ActivityViews.bluetooth(device, connected: true), rank: .bluetooth, duration: 3)
            }
        case .batteryUpdated(let device):
            if let b = device.battery, shouldWarn(device, level: b) {
                presenter.present(ActivityViews.deviceLowBattery(device, level: b), rank: .deviceBattery, duration: 3.5)
            } else {
                // Only refresh in place if the connect peek is still on screen. Animated, since the
                // AirPods L / R / case row can appear here and grow the notch.
                withAnimation(NotchModel.openAnimation) {
                    presenter.update(ActivityViews.bluetooth(device, connected: true), duration: 2)
                }
            }
        case .disconnected(let device):
            deviceLowWarned.remove(device.address)
            presenter.present(ActivityViews.bluetooth(device, connected: false), rank: .bluetooth, duration: 1.8)
        }
    }

    /// True once per connection, the first time the level is below the device threshold.
    private func shouldWarn(_ d: BluetoothMonitor.Device, level: Int) -> Bool {
        guard opts.deviceLowBattery, level < ActivitySettings.deviceLowThreshold,
              !deviceLowWarned.contains(d.address) else { return false }
        deviceLowWarned.insert(d.address)
        return true
    }

    /// Runs only while something is connected and the warning is enabled.
    private func updateDeviceBatteryTimer() {
        let wanted = context.settings.bluetoothActivity && opts.deviceLowBattery && bluetooth.connectedCount > 0
        if wanted, deviceBatteryTimer == nil {
            let t = Timer(timeInterval: 300, repeats: true) { [weak self] _ in self?.checkDeviceBatteries() }
            t.tolerance = 60
            RunLoop.main.add(t, forMode: .common)
            deviceBatteryTimer = t
        } else if !wanted, let t = deviceBatteryTimer {
            t.invalidate()
            deviceBatteryTimer = nil
        }
    }

    private func checkDeviceBatteries() {
        updateDeviceBatteryTimer()
        guard context.settings.bluetoothActivity, opts.deviceLowBattery else { return }
        for d in bluetooth.connectedDevices() {
            guard let b = d.battery, shouldWarn(d, level: b) else { continue }
            presenter.present(ActivityViews.deviceLowBattery(d, level: b), rank: .deviceBattery, duration: 3.5)
            return
        }
    }

    // MARK: Track change

    private func handleTrackChange() {
        let np = context.nowPlaying
        guard context.settings.trackChangeActivity, np.isPlaying, !np.title.isEmpty else { return }
        presenter.present(ActivityViews.trackPeek(np), rank: .track, duration: 3, queueable: false)
    }
}
