import Foundation

/// Low Power Mode (ProcessInfo power-state notification) and screen unlock
/// (`com.apple.screenIsUnlocked` distributed notification). Event-driven, no timers.
final class SystemStateMonitor {
    enum Event {
        case lowPowerMode(Bool)
        case unlocked
    }

    var onEvent: ((Event) -> Void)?
    private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    func start() {
        guard tokens.isEmpty else { return }
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let nc = NotificationCenter.default
        tokens.append((nc, nc.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil,
                                          queue: .main) { [weak self] _ in self?.powerStateChanged() }))
        let dnc = DistributedNotificationCenter.default()
        tokens.append((dnc, dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil,
                                            queue: .main) { [weak self] _ in self?.onEvent?(.unlocked) }))
    }

    deinit { tokens.forEach { $0.0.removeObserver($0.1) } }

    private func powerStateChanged() {
        let now = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard now != lowPower else { return }
        lowPower = now
        onEvent?(.lowPowerMode(now))
    }
}
