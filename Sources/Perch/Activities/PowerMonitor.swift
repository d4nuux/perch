import Foundation
import IOKit.ps

/// Power-source transitions from `IOPSNotificationCreateRunLoopSource` (no polling).
/// Emits plug / unplug, low-battery crossings (thresholds supplied by the caller), "fully charged"
/// (100%, or charging stopped at a charge limit), and in-place updates when a time estimate arrives.
final class PowerMonitor {
    enum Event {
        case pluggedIn(Snapshot)
        case unplugged(Snapshot)
        case low(level: Int, critical: Bool)
        case fullyCharged(Snapshot)
        /// Same AC state, something changed (level, time estimate).
        case updated(Snapshot)
    }

    struct Snapshot: Equatable {
        var level: Int
        var onAC: Bool
        var isCharging = false
        var isCharged = false
        /// Minutes; nil while macOS is still calculating or not applicable.
        var minutesToEmpty: Int? = nil
        var minutesToFull: Int? = nil
    }

    /// Descending low-battery thresholds; the last one is the critical one.
    var thresholds: () -> [Int] = { [20, 10] }
    var onEvent: ((Event) -> Void)?
    private var source: CFRunLoopSource?
    private var last: Snapshot?
    /// Thresholds already announced in the current discharge cycle.
    private var fired: Set<Int> = []
    /// Charging was seen since the last plug-in, so a stop means a limit / full was reached.
    private var sawCharging = false
    private var announcedFull = false

    func start() {
        guard source == nil else { return }
        last = Self.read()
        if let s = last {
            // Don't warn at launch about a threshold / full state that existed before we started.
            if !s.onAC { fired = Set(thresholds().filter { s.level <= $0 }) }
            announcedFull = s.onAC && Self.isFull(s, sawCharging: true)
            sawCharging = s.isCharging
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
        let prev = last
        defer { last = now }
        let ts = thresholds()
        if let prev, prev.onAC != now.onAC {
            if now.onAC {
                sawCharging = now.isCharging
                // Plugged in while already full: the plug-in peek is enough.
                announcedFull = Self.isFull(now, sawCharging: false)
                onEvent?(.pluggedIn(now))
            } else {
                onEvent?(.unplugged(now))
            }
        } else if let prev, prev != now {
            onEvent?(.updated(now))
        }
        if now.onAC {
            // Re-arm a threshold once we've charged back above it.
            fired = fired.filter { now.level <= $0 }
            if now.isCharging { sawCharging = true }
            if !announcedFull, Self.isFull(now, sawCharging: sawCharging) {
                announcedFull = true
                onEvent?(.fullyCharged(now))
            }
            return
        }
        let crossed = ts.filter { now.level <= $0 && !fired.contains($0) }
        if !crossed.isEmpty {
            fired.formUnion(ts.filter { now.level <= $0 })
            let critical = ts.last.map { now.level <= $0 } ?? false
            onEvent?(.low(level: now.level, critical: critical))
        }
    }

    /// 100%, IOPS "Is Charged", or charging stopped on AC at 80%+ (Optimized Charging / charge limit).
    static func isFull(_ s: Snapshot, sawCharging: Bool) -> Bool {
        guard s.onAC else { return false }
        if s.level >= 100 || s.isCharged { return true }
        return sawCharging && !s.isCharging && s.level >= 80
    }

    /// Internal battery state, read directly from IOKit. nil when there's no battery.
    static func read() -> Snapshot? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for src in list {
            guard let d = IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            let level = Swift.min(Swift.max(max > 0 ? cur * 100 / max : cur, 0), 100)
            let onAC = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            // -1 = still calculating; 0 = not applicable (e.g. time to full while not charging).
            func minutes(_ key: String) -> Int? {
                guard let m = d[key] as? Int, m > 0, m < 60 * 48 else { return nil }
                return m
            }
            return Snapshot(level: level, onAC: onAC, isCharging: charging,
                            isCharged: d[kIOPSIsChargedKey] as? Bool ?? false,
                            minutesToEmpty: onAC ? nil : minutes(kIOPSTimeToEmptyKey),
                            minutesToFull: charging ? minutes(kIOPSTimeToFullChargeKey) : nil)
        }
        return nil
    }
}
