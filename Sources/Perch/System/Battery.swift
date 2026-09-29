import Foundation
import IOKit.ps

final class Battery: ObservableObject {
    @Published var level = 100
    @Published var isCharging = false
    @Published var hasBattery = false
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for src in list {
            guard let d = IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            // Assign only on change: every @Published write re-renders observers.
            let lvl = max > 0 ? cur * 100 / max : cur
            let charging = (d[kIOPSIsChargingKey] as? Bool ?? false)
                || (d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
            if !hasBattery { hasBattery = true }
            if level != lvl { level = lvl }
            if isCharging != charging { isCharging = charging }
            return
        }
        if hasBattery { hasBattery = false }
    }
}
