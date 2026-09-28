import AppKit
import Combine

/// Charging, low battery, Bluetooth device and track-change live activities. (Owned by the Activities agent.)
///
/// Each source is event-driven (IOPS run-loop source, IOBluetooth notifications, Combine on
/// NowPlaying), so there are no timers and idle CPU stays at zero.
final class ActivityService {
    private let context: NotchContext
    private let presenter: ActivityPresenter
    private let power = PowerMonitor()
    private let bluetooth = BluetoothMonitor()
    private var track: TrackChangeMonitor?
    private var cancellables: Set<AnyCancellable> = []

    init(context: NotchContext) {
        self.context = context
        presenter = ActivityPresenter(model: context.model)

        power.onEvent = { [weak self] event in self?.handlePower(event) }
        power.start()

        bluetooth.onEvent = { [weak self] event in self?.handleBluetooth(event) }
        // Start IOBluetooth lazily: touching it triggers the Bluetooth TCC prompt, so don't do it
        // while the feature is switched off.
        context.settings.$bluetoothActivity
            .removeDuplicates()
            .filter { $0 }
            .first()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.bluetooth.start() }
            .store(in: &cancellables)

        track = TrackChangeMonitor(nowPlaying: context.nowPlaying) { [weak self] in self?.handleTrackChange() }
    }

    // MARK: Charging / low battery

    private func handlePower(_ event: PowerMonitor.Event) {
        guard context.settings.chargingActivity else { return }
        switch event {
        case .pluggedIn(let level):
            presenter.present(ActivityViews.charging(level: level), rank: .power, duration: 2.5)
        case .unplugged(let level):
            presenter.present(ActivityViews.unplugged(level: level), rank: .power, duration: 2.5)
        case .low(let level):
            presenter.present(ActivityViews.lowBattery(level: level), rank: .lowBattery, duration: 4)
        }
    }

    // MARK: Bluetooth

    private func handleBluetooth(_ event: BluetoothMonitor.Event) {
        guard context.settings.bluetoothActivity else { return }
        switch event {
        case .connected(let device):
            presenter.present(ActivityViews.bluetooth(device, connected: true), rank: .bluetooth, duration: 3)
        case .batteryUpdated(let device):
            // Only refresh in place if the connect peek is still on screen.
            presenter.update(ActivityViews.bluetooth(device, connected: true), duration: 2)
        case .disconnected(let device):
            presenter.present(ActivityViews.bluetooth(device, connected: false), rank: .bluetooth, duration: 1.8)
        }
    }

    // MARK: Track change

    private func handleTrackChange() {
        let np = context.nowPlaying
        guard context.settings.trackChangeActivity, np.isPlaying, !np.title.isEmpty else { return }
        presenter.present(ActivityViews.trackPeek(np), rank: .track, duration: 3, queueable: false)
    }
}
