import AppKit
import ApplicationServices

/// Mission Control / App Exposé state, from the Dock's own Accessibility notifications
/// (`AXExposeShowAllWindows`, `AXExposeShowFrontWindows`, `AXExposeExit`). Event-driven, no polling.
///
/// Needs Accessibility trust (the app already asks for it for the HUDs); without it nothing is
/// detected and the notch simply stays visible. The `com.apple.expose.*` distributed notifications
/// in the Dock binary are commands (posting one *opens* Mission Control), not state signals.
///
/// Safety net for a missed `AXExposeExit`: while active, a 1 Hz check compares the Dock's on-screen
/// windows with the pre-Mission-Control baseline and clears the state once the windows that
/// appeared with Mission Control are gone. The check runs only while Mission Control is showing.
final class MissionControlMonitor {
    private(set) var isActive = false
    var onChange: (() -> Void)?

    private var enabled = false
    private var observer: AXObserver?
    private var dockPID: pid_t = 0
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var retry: DispatchWorkItem?
    private var safetyTimer: Timer?
    private var baseline: Set<CGWindowID> = []
    /// Dock windows that appeared with Mission Control (nil until the first safety tick).
    private var overlayWindows: Set<CGWindowID>?

    private static let enterNotifications = ["AXExposeShowAllWindows", "AXExposeShowFrontWindows"]
    private static let exitNotification = "AXExposeExit"

    deinit { setEnabled(false) }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            let ws = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
                observers.append((ws, ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                    let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    guard app?.bundleIdentifier == "com.apple.dock" else { return }
                    self?.detach()
                    self?.setActive(false)
                    self?.scheduleAttach(after: 1)
                }))
            }
            // Posted when any app's Accessibility trust changes.
            let dnc = DistributedNotificationCenter.default()
            observers.append((dnc, dnc.addObserver(forName: NSNotification.Name("com.apple.accessibility.api"),
                                                   object: nil, queue: .main) { [weak self] _ in
                self?.detach()
                self?.scheduleAttach(after: 1)
            }))
            attach()
        } else {
            observers.forEach { $0.0.removeObserver($0.1) }
            observers = []
            retry?.cancel()
            retry = nil
            detach()
            isActive = false
            stopSafetyTimer()
        }
    }

    private func scheduleAttach(after delay: TimeInterval) {
        retry?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.attach() }
        retry = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func attach() {
        guard enabled, observer == nil, AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return }
        let pid = dock.processIdentifier
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, _, name, refcon in
            guard let refcon else { return }
            let me = Unmanaged<MissionControlMonitor>.fromOpaque(refcon).takeUnretainedValue()
            me.handle(name as String)
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return }
        let element = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var added = 0
        for name in Self.enterNotifications + [Self.exitNotification] {
            if AXObserverAddNotification(obs, element, name as CFString, refcon) == .success { added += 1 }
        }
        guard added > 0 else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        observer = obs
        dockPID = pid
        baseline = Self.dockWindows()
    }

    private func detach() {
        guard let obs = observer else { return }
        let element = AXUIElementCreateApplication(dockPID)
        for name in Self.enterNotifications + [Self.exitNotification] {
            AXObserverRemoveNotification(obs, element, name as CFString)
        }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        observer = nil
        dockPID = 0
    }

    private func handle(_ name: String) {
        if Self.enterNotifications.contains(name) {
            setActive(true)
        } else if name == Self.exitNotification {
            setActive(false)
        }
    }

    private func setActive(_ on: Bool) {
        guard on != isActive else { return }
        if on {
            startSafetyTimer()
        } else {
            stopSafetyTimer()
        }
        isActive = on
        onChange?()
    }

    // MARK: Safety net (only while active)

    private func startSafetyTimer() {
        stopSafetyTimer()
        overlayWindows = nil
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.safetyTick() }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        safetyTimer = t
    }

    private func stopSafetyTimer() {
        safetyTimer?.invalidate()
        safetyTimer = nil
        overlayWindows = nil
        if observer != nil {
            // Re-baseline once the exit animation has finished.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, !self.isActive else { return }
                self.baseline = Self.dockWindows()
            }
        }
    }

    private func safetyTick() {
        let now = Self.dockWindows()
        guard let overlay = overlayWindows else {
            overlayWindows = now.subtracting(baseline)
            return
        }
        // No distinguishable Mission Control windows: can't tell, rely on AXExposeExit alone.
        guard !overlay.isEmpty else { return }
        if now.isDisjoint(with: overlay) { setActive(false) }
    }

    private static func dockWindows() -> Set<CGWindowID> {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        var ids = Set<CGWindowID>()
        for w in info where (w[kCGWindowOwnerName as String] as? String) == "Dock" {
            if let n = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value { ids.insert(n) }
        }
        return ids
    }
}

/// True while the frontmost app is a game: its Info.plist `LSApplicationCategoryType` is
/// `public.app-category.games` or one of the `*-games` subcategories, or it lives in a Steam
/// library (`…/steamapps/common/…`, where many games ship without a category). Re-evaluated only
/// on app activation; results are cached per bundle path.
final class GameMonitor {
    private(set) var isActive = false
    var onChange: (() -> Void)?

    private var enabled = false
    private var observer: NSObjectProtocol?
    private var cache: [String: Bool] = [:]

    deinit { setEnabled(false) }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        let ws = NSWorkspace.shared.notificationCenter
        if on {
            observer = ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                      object: nil, queue: .main) { [weak self] n in
                let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                self?.update(app)
            }
            // No onChange here: the caller (layout) reads `isActive` right after.
            isActive = isGame(NSWorkspace.shared.frontmostApplication)
        } else {
            if let observer { ws.removeObserver(observer) }
            observer = nil
            isActive = false
        }
    }

    private func update(_ app: NSRunningApplication?) {
        let game = isGame(app)
        guard game != isActive else { return }
        isActive = game
        onChange?()
    }

    private func isGame(_ app: NSRunningApplication?) -> Bool {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let url = app.bundleURL else { return false }
        let path = url.path
        if let cached = cache[path] { return cached }
        var game = path.contains("/steamapps/common/")
        if !game,
           let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
           let category = info["LSApplicationCategoryType"] as? String {
            game = Self.isGameCategory(category)
        }
        cache[path] = game
        return game
    }

    static func isGameCategory(_ category: String) -> Bool {
        let c = category.lowercased()
        return c == "public.app-category.games"
            || (c.hasPrefix("public.app-category.") && c.hasSuffix("-games"))
    }
}
