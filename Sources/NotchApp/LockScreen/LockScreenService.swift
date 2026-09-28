import AppKit
import Combine
import EventKit
import SwiftUI

/// Widgets shown on the lock screen (and optionally over the screensaver), below the clock.
///
/// Lock/unlock comes from the distributed `com.apple.screenIsLocked` / `screenIsUnlocked`
/// notifications, screensaver from `com.apple.screensaver.didstart` / `didstop`. To show, a
/// never-key, non-activating panel is ordered in (alpha 0), moved into a SkyLight space at the
/// lock-screen absolute level, then faded in. To hide it is ordered out immediately and every
/// content subscription, listener and timer is dropped. Any failure (SkyLight, no screen) hides.
final class LockScreenService {
    private let context: NotchContext
    private let prefs = LockScreenSettings.shared
    private let widgetModel = LockScreenWidgetModel()
    private let volume = LockVolume()
    private let events = LockEventReader()
    private let keepAwake = LockKeepAwake()
    private var panel: LockScreenPanel?
    private var isLocked = false
    private var isScreensaver = false
    private var isShowing = false
    private var contentSubs = Set<AnyCancellable>()
    private var contentObservers: [NSObjectProtocol] = []
    private var refreshTimer: Timer?
    private var subs = Set<AnyCancellable>()
    private var distributedObservers: [NSObjectProtocol] = []
    private var localObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    /// Used until the SwiftUI stack has reported its height.
    private static let fallbackHeight: CGFloat = 200

    init(context: NotchContext) {
        self.context = context
        let m = widgetModel
        m.onCommand = { [weak nowPlaying = context.nowPlaying] cmd in nowPlaying?.send(cmd) }
        m.onSeek = { [weak nowPlaying = context.nowPlaying] s in nowPlaying?.seek(to: s) }
        m.onVolume = { [weak volume] v in volume?.set(v) }
        volume.onChange = { [weak m] v in m?.volume = v }

        let dnc = DistributedNotificationCenter.default()
        let distributed: [(String, (LockScreenService) -> Void)] = [
            ("com.apple.screenIsLocked", { $0.setLocked(true) }),
            ("com.apple.screenIsUnlocked", { $0.setLocked(false) }),
            ("com.apple.screensaver.didstart", { $0.setScreensaver(true) }),
            ("com.apple.screensaver.didstop", { $0.setScreensaver(false) }),
        ]
        for (name, action) in distributed {
            distributedObservers.append(dnc.addObserver(forName: .init(name), object: nil, queue: .main) {
                [weak self] _ in if let self { action(self) }
            })
        }
        // Backstop in case an unlock notification is missed (fast user switching, sleep/wake).
        let wnc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(wnc.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                guard let self else { return }
                if n.name == NSWorkspace.sessionDidBecomeActiveNotification { self.isScreensaver = false }
                self.isLocked = Self.sessionIsLocked()
                self.update()
            })
        }
        localObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.isShowing else { return }
            if !self.layout() { self.hide() }
        })

        context.settings.$lockScreenWidgets
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &subs)

        prefs.$order.combineLatest(prefs.$enabled, prefs.$cardStyle)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] order, enabled, style in self?.applyWidgetPrefs(order, enabled, style) }
            .store(in: &subs)
        prefs.$verticalOffset
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.relayoutIfShowing() }
            .store(in: &subs)
        prefs.$keepAwake.combineLatest(prefs.$showOnScreensaver)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.update() }
            .store(in: &subs)
        widgetModel.$contentHeight
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.relayoutIfShowing() }
            .store(in: &subs)

        // Launched while already locked (e.g. login item after a crash): pick that up.
        if Self.sessionIsLocked() { DispatchQueue.main.async { [weak self] in self?.setLocked(true) } }
    }

    deinit {
        distributedObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        localObservers.forEach { NotificationCenter.default.removeObserver($0) }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        keepAwake.held = false
        teardownContent()
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

    private func setScreensaver(_ running: Bool) {
        guard running != isScreensaver else { return }
        isScreensaver = running
        // The screensaver ending without a lock means the user is back: re-check the real state.
        if !running { isLocked = Self.sessionIsLocked() }
        update()
    }

    private var weatherWanted = false

    private func syncWeatherDemand() {
        if weatherWanted && context.settings.lockScreenWidgets {
            WeatherService.shared.acquire("lockscreen")
        } else {
            WeatherService.shared.release("lockscreen")
        }
    }

    private func update() {
        syncWeatherDemand()
        let master = context.settings.lockScreenWidgets
        keepAwake.held = master && isLocked && prefs.keepAwake
        let wantShown = master && SkyLightBridge.shared.isAvailable
            && (isLocked || (isScreensaver && prefs.showOnScreensaver))
        if wantShown { show() } else { hide() }
    }

    private func applyWidgetPrefs(_ order: [LockWidget], _ enabled: Set<LockWidget>, _ style: LockCardStyle) {
        let m = widgetModel
        if m.order != order { m.order = order }
        if m.enabled != enabled { m.enabled = enabled }
        if m.style != style { m.style = style }
        // Warm weather up ahead of the lock so it's there when the screen locks.
        weatherWanted = enabled.contains(.weather)
        syncWeatherDemand()
        if isShowing { subscribeContent() }
    }

    // MARK: Show / hide

    private func show() {
        guard !isShowing else { return }
        let p = panel ?? makePanel()
        panel = p
        guard layout() else { hide(); return }
        subscribeContent()
        p.alphaValue = 0
        p.ignoresMouseEvents = false
        p.orderFrontRegardless()   // never makeKey: the password field keeps focus
        guard SkyLightBridge.shared.delegate(p) else {
            // Could not move it to the lock level: don't leave a stray window on the desktop.
            hide()
            return
        }
        isShowing = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            p.animator().alphaValue = 1
        }
    }

    private func hide() {
        teardownContent()
        isShowing = false
        guard let p = panel else { return }
        // Synchronous and immediate: never delay or animate over the unlock transition.
        p.ignoresMouseEvents = true
        p.alphaValue = 0
        p.orderOut(nil)
    }

    private func makePanel() -> LockScreenPanel {
        let p = LockScreenPanel(contentRect: CGRect(x: 0, y: 0, width: LockScreenWidgetsView.width,
                                                    height: Self.fallbackHeight),
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

    private func relayoutIfShowing() {
        guard isShowing else { return }
        if !layout() { hide() }
    }

    /// Centered horizontally; top edge ~34% down the screen (below the lock-screen date/clock)
    /// plus the user's offset, clamped so it never reaches the avatar / password field area.
    /// Returns false when there's no screen.
    @discardableResult
    private func layout() -> Bool {
        guard let p = panel else { return false }
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
        guard let f = screen?.frame, f.width > 0, f.height > 0 else { return false }
        let w = LockScreenWidgetsView.width
        let h = widgetModel.contentHeight > 0 ? ceil(widgetModel.contentHeight) : Self.fallbackHeight
        var top = f.maxY - f.height * 0.34 - CGFloat(prefs.verticalOffset)
        top = min(top, f.maxY - 40)
        top = max(top, f.minY + f.height * 0.30 + h)   // stay above the login controls
        p.setFrame(CGRect(x: f.midX - w / 2, y: top - h, width: w, height: h), display: isShowing)
        return true
    }

    // MARK: Content

    /// (Re)builds subscriptions for the enabled widgets only.
    private func subscribeContent() {
        teardownContent()
        let np = context.nowPlaying, b = context.battery, m = widgetModel
        let on = prefs.enabled

        if on.contains(.nowPlaying) {
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
            np.$position.combineLatest(np.$duration)
                .receive(on: DispatchQueue.main)
                .sink { pos, dur in
                    m.duration = dur
                    if m.scrub == nil { m.position = pos }
                }
                .store(in: &contentSubs)
            volume.start()
        } else {
            m.hasTrack = false
        }

        if on.contains(.battery) {
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

        if on.contains(.weather) {
            WeatherService.shared.$current
                .receive(on: DispatchQueue.main)
                .sink { m.weather = $0 }
                .store(in: &contentSubs)
        } else {
            m.weather = nil
        }

        if on.contains(.nextEvent) {
            refreshEvent()
            contentObservers.append(NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged, object: nil, queue: .main
            ) { [weak self] _ in self?.refreshEvent() })
        } else {
            m.nextEvent = nil
        }

        if on.contains(.bluetooth) { m.devices = LockBluetooth.devices() } else { m.devices = [] }

        // Private Bluetooth battery values and "next event" rollover have no change notification:
        // one 60 s timer, only while showing and only if one of those widgets is on.
        if on.contains(.bluetooth) || on.contains(.nextEvent) {
            let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.periodicRefresh() }
            t.tolerance = 10
            RunLoop.main.add(t, forMode: .common)
            refreshTimer = t
        }
    }

    private func periodicRefresh() {
        guard isShowing else { return }
        let on = prefs.enabled
        if on.contains(.bluetooth) {
            let d = LockBluetooth.devices()
            if d != widgetModel.devices { widgetModel.devices = d }
        }
        if on.contains(.nextEvent) { refreshEvent() }
    }

    private func refreshEvent() {
        events.fetchNext { [weak self] e in
            guard let self, self.isShowing || self.panel?.isVisible == true,
                  self.prefs.enabled.contains(.nextEvent) else { return }
            if e != self.widgetModel.nextEvent { self.widgetModel.nextEvent = e }
        }
    }

    private func teardownContent() {
        contentSubs.removeAll()
        contentObservers.forEach { NotificationCenter.default.removeObserver($0) }
        contentObservers = []
        refreshTimer?.invalidate()
        refreshTimer = nil
        volume.stop()
        widgetModel.scrub = nil
    }
}
