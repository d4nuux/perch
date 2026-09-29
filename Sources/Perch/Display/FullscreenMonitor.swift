import AppKit

/// Tracks which displays currently show a fullscreen app (menu bar hidden).
/// Event-driven: re-checks on space change / app activation / screen change, each followed by a
/// couple of delayed re-checks because the fullscreen transition animates (~0.7s). No polling.
final class FullscreenMonitor {
    private(set) var fullscreenDisplays: Set<CGDirectDisplayID> = []
    var onChange: (() -> Void)?

    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var pending: [DispatchWorkItem] = []
    private var enabled = false

    deinit { setEnabled(false) }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            let ws = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.activeSpaceDidChangeNotification,
                         NSWorkspace.didActivateApplicationNotification] {
                observers.append((ws, ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.scheduleChecks()
                }))
            }
            let nc = NotificationCenter.default
            observers.append((nc, nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                 object: nil, queue: .main) { [weak self] _ in
                self?.scheduleChecks()
            }))
            // No onChange here: the caller (layout) reads `fullscreenDisplays` right after.
            fullscreenDisplays = Self.detect()
        } else {
            observers.forEach { $0.0.removeObserver($0.1) }
            observers = []
            pending.forEach { $0.cancel() }
            pending = []
            fullscreenDisplays = []
        }
    }

    private func scheduleChecks() {
        pending.forEach { $0.cancel() }
        pending = [0.05, 0.5, 1.2].map { delay in
            let w = DispatchWorkItem { [weak self] in self?.check() }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
            return w
        }
    }

    private func check() {
        guard enabled else { return }
        update(Self.detect())
    }

    private func update(_ set: Set<CGDirectDisplayID>) {
        guard set != fullscreenDisplays else { return }
        fullscreenDisplays = set
        onChange?()
    }

    /// A display is fullscreen when the Window Server's menu bar window (layer kCGMainMenuWindowLevel)
    /// is absent on it. Where the menu bar is absent anyway (auto-hide "Always", or a secondary display
    /// without separate Spaces) fall back to "a frontmost-app window covers the whole display".
    static func detect() -> Set<CGDirectDisplayID> {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        let menuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        let autoHide = UserDefaults.standard.bool(forKey: "_HIHideMenuBar")
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let ownPID = ProcessInfo.processInfo.processIdentifier

        var menuBarRects: [CGRect] = []
        var frontRects: [CGRect] = []
        for w in info {
            guard let layer = w[kCGWindowLayer as String] as? Int,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b) else { continue }
            let owner = w[kCGWindowOwnerName as String] as? String
            let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            if layer == menuLevel, owner == "Window Server" {
                menuBarRects.append(rect)
            } else if layer == 0, let pid, pid == frontPID, pid != ownPID {
                frontRects.append(rect)
            }
        }

        // Without "Displays have separate Spaces" only the primary display has a menu bar.
        let separateSpaces = NSScreen.screensHaveSeparateSpaces
        let primaryID = NSScreen.screens.first?.displayID
        var result: Set<CGDirectDisplayID> = []
        for screen in NSScreen.screens {
            let id = screen.displayID
            let bounds = CGDisplayBounds(id) // top-left origin, same space as window bounds
            let coveredByFront = frontRects.contains { r in
                r.minX <= bounds.minX + 1 && r.minY <= bounds.minY + 1
                    && r.maxX >= bounds.maxX - 1 && r.maxY >= bounds.maxY - 1
            }
            if autoHide || (!separateSpaces && id != primaryID) {
                if coveredByFront { result.insert(id) }
            } else {
                let hasMenuBar = menuBarRects.contains { r in
                    abs(r.minY - bounds.minY) < 2 && r.intersects(bounds)
                }
                if !hasMenuBar { result.insert(id) }
            }
        }
        return result
    }
}
