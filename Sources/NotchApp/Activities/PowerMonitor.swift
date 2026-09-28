import Foundation
import IOKit.ps

/// Power-source transitions from `IOPSNotificationCreateRunLoopSource` (no polling).
/// Emits plug / unplug transitions and low-battery crossings at 20% and 10%.
final class PowerMonitor {
    enum Event {
        case pluggedIn(level: Int)
        case unplugged(level: Int)
        case low(level: Int)
    }

    struct Snapshot: Equatable {
        var level: Int
        var onAC: Bool
    }

    static let lowThresholds = [20, 10]

    var onEvent: ((Event) -> Void)?
    private var source: CFRunLoopSource?
    private var last: Snapshot?
    /// Thresholds already announced in the current discharge cycle.
    private var fired: Set<Int> = []

    func start() {
        guard source == nil else { return }
        last = Self.read()
        if let s = last, !s.onAC {
            // Don't warn at launch about a threshold that was crossed before we started.
            fired = Set(Self.lowThresholds.filter { s.level <= $0 })
        }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<PowerMonitor>.fromOpaque(ctx).takeUnretainedValue().changed()
        }, ctx)?.takeRetainedValue() else { return }
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
    }

    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }

    private func changed() {
        guard let now = Self.read() else { last = nil; return }
        process(now)
    }

    /// State machine step; separated from IOKit so it can be exercised in isolation.
    func process(_ now: Snapshot) {
        defer { last = now }
        if let prev = last, prev.onAC != now.onAC {
            onEvent?(now.onAC ? .pluggedIn(level: now.level) : .unplugged(level: now.level))
        }
        if now.onAC {
            // Re-arm a threshold once we've charged back above it.
            fired = fired.filter { now.level <= $0 }
            return
        }
        let crossed = Self.lowThresholds.filter { now.level <= $0 && !fired.contains($0) }
        if !crossed.isEmpty {
            fired.formUnion(Self.lowThresholds.filter { now.level <= $0 })
            onEvent?(.low(level: now.level))
        }
    }

    /// Internal battery level and AC state, read directly from IOKit. nil when there's no battery.
    static func read() -> Snapshot? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for src in list {
            guard let d = IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            let level = max > 0 ? cur * 100 / max : cur
            let onAC = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            return Snapshot(level: Swift.min(Swift.max(level, 0), 100), onAC: onAC)
        }
        return nil
    }
}
