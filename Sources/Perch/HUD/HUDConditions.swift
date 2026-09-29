import CoreGraphics
import Foundation

/// Screen-lock and Focus state for the per-HUD rules. Event-driven, main thread; `onChange` fires
/// after either flips. Read-only: nothing here changes system state.
///
/// Lock: `com.apple.screenIsLocked` / `screenIsUnlocked` distributed notifications, baseline from
/// `CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]`.
/// Focus: `_NSDoNotDisturbEnabledNotification` / `…Disabled…` (the same signal FocusMonitor uses; it
/// has no shared state to read). Baseline from `~/Library/DoNotDisturb/DB/Assertions.json` when
/// readable (Full Disk Access); otherwise assumed off until the first notification.
final class HUDConditions {
    private(set) var isLocked = false
    private(set) var isFocusOn = false
    var onChange: (() -> Void)?
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        isLocked = Self.sessionIsLocked()
        isFocusOn = Self.focusAssertionActive() ?? false
        let dnc = DistributedNotificationCenter.default()
        let table: [(String, (HUDConditions) -> Void)] = [
            ("com.apple.screenIsLocked", { $0.set(locked: true) }),
            ("com.apple.screenIsUnlocked", { $0.set(locked: false) }),
            ("_NSDoNotDisturbEnabledNotification", { $0.set(focus: true) }),
            ("_NSDoNotDisturbDisabledNotification", { $0.set(focus: false) }),
        ]
        for (name, action) in table {
            observers.append(dnc.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                if let self { action(self) }
            })
        }
        onChange?()
    }

    deinit { observers.forEach { DistributedNotificationCenter.default().removeObserver($0) } }

    private func set(locked: Bool) {
        guard locked != isLocked else { return }
        isLocked = locked
        onChange?()
    }

    private func set(focus: Bool) {
        guard focus != isFocusOn else { return }
        isFocusOn = focus
        onChange?()
    }

    static func sessionIsLocked() -> Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let b = d["CGSSessionScreenIsLocked"] as? Bool { return b }
        return (d["CGSSessionScreenIsLocked"] as? Int ?? 0) != 0
    }

    /// nil when the DnD DB isn't readable. True when any Focus assertion record exists.
    static func focusAssertionActive() -> Bool? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")
        guard let data = try? Data(contentsOf: url), let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        func any(_ o: Any) -> Bool {
            if let d = o as? [String: Any] {
                if let r = d["storeAssertionRecords"] as? [Any], !r.isEmpty { return true }
                return d.values.contains(where: any)
            }
            if let a = o as? [Any] { return a.contains(where: any) }
            return false
        }
        return any(obj)
    }
}
