import AppKit
import Combine
import SwiftUI

/// Widgets shown on the lock screen: battery pill + now-playing card below the clock.
///
/// Lock/unlock comes from the distributed `com.apple.screenIsLocked` / `screenIsUnlocked`
/// notifications. On lock, a never-key, non-activating panel is ordered in (alpha 0), moved into a
/// SkyLight space at the lock-screen absolute level, then faded in. On unlock it is ordered out
/// immediately and content subscriptions are dropped. If SkyLight is unavailable, nothing happens.
final class LockScreenService {
    private let context: NotchContext
    private let widgetModel = LockScreenWidgetModel()
    private var panel: LockScreenPanel?
    private var isLocked = false
    private var isShowing = false
    private var contentSubs = Set<AnyCancellable>()
    private var subs = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    private static let windowHeight: CGFloat = 200

    init(context: NotchContext) {
        self.context = context
        widgetModel.onCommand = { [weak nowPlaying = context.nowPlaying] cmd in nowPlaying?.send(cmd) }

        let dnc = DistributedNotificationCenter.default()
        observers.append(dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) {
            [weak self] _ in self?.setLocked(true)
        })
        observers.append(dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) {
            [weak self] _ in self?.setLocked(false)
        })
        // Backstop in case an unlock notification is missed (fast user switching, sleep/wake).
        let wnc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(wnc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.setLocked(Self.sessionIsLocked())
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.layout() })

        context.settings.$lockScreenWidgets
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &subs)

        // Launched while already locked (e.g. login item after a crash): pick that up.
        if Self.sessionIsLocked() { DispatchQueue.main.async { [weak self] in self?.setLocked(true) } }
    }

    deinit {
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        panel?.orderOut(nil)
    }

    private static func sessionIsLocked() -> Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (d["CGSSessionScreenIsLocked"] as? Bool) ?? ((d["CGSSessionScreenIsLocked"] as? Int) ?? 0 != 0)
    }

    private func setLocked(_ locked: Bool) {
        guard locked != isLocked else { return }
        isLocked = locked
        update()
    }

    private func update() {
        let wantShown = isLocked && context.settings.lockScreenWidgets && SkyLightBridge.shared.isAvailable
        if wantShown { show() } else { hide() }
    }

    // MARK: Show / hide

    private func show() {
        guard !isShowing else { return }
        subscribeContent()
        let p = panel ?? makePanel()
        panel = p
        layout()
        p.alphaValue = 0
        p.ignoresMouseEvents = false
        p.orderFrontRegardless()   // never makeKey: the password field keeps focus
        guard SkyLightBridge.shared.delegate(p) else {
            // Could not move it to the lock level: don't leave a stray window on the desktop.
            p.orderOut(nil)
            contentSubs.removeAll()
            return
        }
        isShowing = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            p.animator().alphaValue = 1
        }
    }

    private func hide() {
        contentSubs.removeAll()
        guard let p = panel else { isShowing = false; return }
        // Synchronous and immediate: never delay or animate over the unlock transition.
        p.ignoresMouseEvents = true
        p.alphaValue = 0
        p.orderOut(nil)
        isShowing = false
    }

    private func makePanel() -> LockScreenPanel {
        let p = LockScreenPanel(contentRect: CGRect(x: 0, y: 0, width: LockScreenWidgetsView.width,
                                                    height: Self.windowHeight),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovable = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = true
        p.level = .screenSaver
        p.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.animationBehavior = .none
        let host = FirstMouseHostingView(rootView: LockScreenWidgetsView(model: widgetModel))
        host.frame = p.contentRect(forFrameRect: p.frame)
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        return p
    }

    /// Centered horizontally, top edge ~34% down the screen: below the lock-screen date/clock,
    /// well above the avatar / password field.
    private func layout() {
        guard let p = panel else { return }
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
        guard let f = screen?.frame else { return }
        let w = LockScreenWidgetsView.width, h = Self.windowHeight
        let top = f.maxY - f.height * 0.34
        p.setFrame(CGRect(x: f.midX - w / 2, y: top - h, width: w, height: h), display: true)
    }

    // MARK: Content

    private func subscribeContent() {
        contentSubs.removeAll()
        let np = context.nowPlaying, b = context.battery, m = widgetModel

        np.$title.combineLatest(np.$artist, np.$isPlaying)
            .receive(on: DispatchQueue.main)
            .sink { title, artist, playing in
                m.title = title
                m.artist = artist
                m.isPlaying = playing
                m.hasTrack = !title.isEmpty
            }
            .store(in: &contentSubs)
        np.$artwork
            .receive(on: DispatchQueue.main)
            .sink { m.artwork = $0 }
            .store(in: &contentSubs)
        b.$level.combineLatest(b.$isCharging, b.$hasBattery)
            .receive(on: DispatchQueue.main)
            .sink { level, charging, has in
                m.batteryLevel = level
                m.isCharging = charging
                m.hasBattery = has
            }
            .store(in: &contentSubs)

        // Battery polls every 20 s; refresh now so the pill isn't stale on lock.
        b.refresh()
    }
}
