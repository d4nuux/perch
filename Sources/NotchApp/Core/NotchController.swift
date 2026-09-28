import AppKit
import Combine
import SwiftUI

final class NotchPanel: NSPanel {
    // Never take keyboard focus from the user's app; buttons work without key status.
    override var canBecomeKey: Bool { false }
}

/// One notch panel on one screen. All hosts share the same model/service objects.
private final class ScreenHost {
    let panel: NotchPanel
    let state: NotchScreen
    var screenFrame: CGRect = .zero
    var hidden = false
    /// When the pointer entered this notch (for the hover-open delay).
    var hoverSince: TimeInterval?

    init(panel: NotchPanel, state: NotchScreen) {
        self.panel = panel
        self.state = state
    }

    var displayID: CGDirectDisplayID { state.displayID }
}

final class NotchController {
    static let panelSize = CGSize(width: 720, height: 260)
    private static let fastInterval: TimeInterval = 1.0 / 30.0
    private static let slowInterval: TimeInterval = 1.0 / 10.0
    /// Pointer closer than this to any notch keeps the tracker at 30Hz.
    private static let nearDistance: CGFloat = 160

    let model = NotchModel()
    let nowPlaying = NowPlaying()
    let battery = Battery()
    let shelf = Shelf()
    let settings = AppSettings.shared
    let display = DisplaySettings.shared
    private var calendar: CalendarService!
    private var services: [AnyObject] = []
    /// hosts[0] always uses `primaryPanel` (the one in NotchContext, so gestures keep working).
    private let primaryPanel: NotchPanel
    private var hosts: [ScreenHost] = []
    private let fullscreen = FullscreenMonitor()
    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?
    private var timerInterval: TimeInterval = 0
    private var collapseWork: DispatchWorkItem?
    private let pinned = ProcessInfo.processInfo.environment["NOTCH_PIN"] != nil

    init() {
        primaryPanel = Self.makePanel()

        let context = NotchContext(model: model, nowPlaying: nowPlaying, battery: battery,
                                   shelf: shelf, settings: settings, panel: primaryPanel)
        calendar = CalendarService(context: context)
        services = [
            HUDService(context: context),
            ActivityService(context: context),
            GestureService(context: context),
            LockScreenService(context: context),
        ]

        hosts = [makeHost(panel: primaryPanel)]

        fullscreen.onChange = { [weak self] in self?.layout() }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.layout() }

        // Any display setting change re-lays out (cheap; coalesced while a slider drags).
        display.objectWillChange
            .debounce(for: .milliseconds(16), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.layout() }
            .store(in: &cancellables)

        observeIdleInputs()
        installDragMonitors()
        layout()
        setTimer(interval: Self.fastInterval)
    }

    // MARK: Panels

    private static func makePanel() -> NotchPanel {
        let panel = NotchPanel(
            contentRect: CGRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func makeHost(panel: NotchPanel) -> ScreenHost {
        let state = NotchScreen(displayID: 0, notchSize: model.notchSize, isSimulated: false)
        let root = NotchView()
            .environmentObject(model)
            .environmentObject(nowPlaying)
            .environmentObject(battery)
            .environmentObject(shelf)
            .environmentObject(settings)
            .environmentObject(calendar)
            .environmentObject(display)
            .environmentObject(state)
        let hostView = NSHostingView(rootView: root)
        hostView.frame = CGRect(origin: .zero, size: Self.panelSize)
        panel.contentView = hostView
        return ScreenHost(panel: panel, state: state)
    }

    /// Rebuilds the panel set for the target screens and positions each one.
    private func layout() {
        fullscreen.setEnabled(display.hideInFullscreen)
        let screens = Screens.targets(display)

        // Reuse hosts by display ID; hosts[0] (primary panel) takes the first target screen.
        var old = Array(hosts.dropFirst())
        var next: [ScreenHost] = [hosts[0]]
        for screen in screens.dropFirst() {
            if let i = old.firstIndex(where: { $0.displayID == screen.displayID }) {
                next.append(old.remove(at: i))
            } else {
                next.append(makeHost(panel: Self.makePanel()))
            }
        }
        for h in old { h.panel.orderOut(nil); h.panel.close() }
        hosts = next

        guard !screens.isEmpty else {
            // No usable screen (e.g. clamshell reconfiguration, or simulated notch off on a notch-less Mac).
            hosts[0].hidden = true
            hosts[0].panel.orderOut(nil)
            model.close()
            return
        }

        for (h, screen) in zip(hosts, screens) {
            let id = screen.displayID
            let (size, simulated) = Screens.notchSize(for: screen, display)
            if h.state.displayID != id { h.state.displayID = id }
            if h.state.notchSize != size { h.state.notchSize = size }
            if h.state.isSimulated != simulated { h.state.isSimulated = simulated }
            h.screenFrame = screen.frame

            let f = screen.frame, p = Self.panelSize
            h.panel.setFrame(CGRect(x: f.midX - p.width / 2, y: f.maxY - p.height,
                                    width: p.width, height: p.height), display: true)
            h.panel.sharingType = display.hideFromCapture ? .none : .readOnly

            let hide = display.hideInFullscreen && fullscreen.fullscreenDisplays.contains(id)
            h.hidden = hide
            if hide {
                h.panel.orderOut(nil)
            } else if !h.panel.isVisible {
                h.panel.orderFrontRegardless()
            }
        }

        model.primaryDisplay = hosts[0].displayID
        if model.notchSize != hosts[0].state.notchSize { model.notchSize = hosts[0].state.notchSize }
        if model.isExpanded, !hosts.contains(where: { !$0.hidden && $0.displayID == model.expandedDisplay }) {
            model.close()
        }
    }

    // MARK: Mouse tracking

    private func setTimer(interval: TimeInterval) {
        guard interval != timerInterval else { return }
        timerInterval = interval
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.trackMouse() }
        t.tolerance = interval * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Screen-space rect a host's notch currently occupies (plus some slack for hovering).
    private func activeRect(_ h: ScreenHost, idleExtra: CGFloat) -> CGRect {
        let f = h.screenFrame
        let open = model.isOpen(on: h.displayID)
        let size = model.size(notch: h.state.notchSize, expanded: open, idleExtra: idleExtra)
        let w = size.width + (open ? 20 : 30)
        let ht = size.height + (open ? 20 : 8)
        return CGRect(x: f.midX - w / 2, y: f.maxY - ht, width: w, height: ht)
    }

    // MARK: Drag detection (event-driven)

    private var dragMonitors: [Any] = []
    /// Drag pasteboard change count at the last mouse-up; a content drag bumps it.
    private var dragBaseline = NSPasteboard(name: .drag).changeCount
    /// Left button is down and has moved since the last mouse-up.
    private var mouseDragging = false
    /// This drag carries content (file, text...). A plain click-drag (selection, window move) doesn't.
    private var isDraggingContent = false
    /// Uptime of the last drag-pasteboard read during the current drag (rate limit).
    private var lastDragCheck: TimeInterval = 0

    private func installDragMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.dragEvent(e) }) {
            dragMonitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            self?.dragEvent(e); return e
        }) {
            dragMonitors.append(l)
        }
    }

    private func dragEvent(_ e: NSEvent) {
        if e.type == .leftMouseUp {
            // Plain clicks never touch the drag pasteboard, so only re-read it after a drag.
            if mouseDragging { dragBaseline = NSPasteboard(name: .drag).changeCount }
            mouseDragging = false
            isDraggingContent = false
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if !mouseDragging {
            mouseDragging = true
            lastDragCheck = now
            isDraggingContent = NSPasteboard(name: .drag).changeCount != dragBaseline
        } else if !isDraggingContent, now - lastDragCheck >= 0.1 {
            // The source app writes the drag pasteboard a few points after the drag starts, so
            // keep checking (≤10Hz, only during an undecided drag) until it shows up.
            lastDragCheck = now
            isDraggingContent = NSPasteboard(name: .drag).changeCount != dragBaseline
        }
    }

    // MARK: Idle state (cached)

    /// Collapsed idle width; recomputed only when its inputs change, and once a minute for
    /// time-based calendar transitions (event started/ended).
    private var idleExtra: CGFloat = 0

    private func observeIdleInputs() {
        let triggers: [AnyPublisher<Void, Never>] = [
            nowPlaying.$isPlaying.map { _ in () }.eraseToAnyPublisher(),
            nowPlaying.$hidesCollapsedActivity.map { _ in () }.eraseToAnyPublisher(),
            calendar.$events.map { _ in () }.eraseToAnyPublisher(),
            display.$idleContent.map { _ in () }.eraseToAnyPublisher(),
            Timer.publish(every: 60, tolerance: 10, on: .main, in: .common).autoconnect()
                .map { _ in () }.eraseToAnyPublisher(),
        ]
        // @Published fires in willSet: hop one run-loop turn so resolve() reads the new values.
        Publishers.MergeMany(triggers)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.recomputeIdle() }
            .store(in: &cancellables)
        recomputeIdle()
    }

    private func recomputeIdle() {
        idleExtra = IdleState.resolve(display.idleContent, nowPlaying: nowPlaying, calendar: calendar).extraWidth
    }

    private func trackMouse() {
        let mouse = NSEvent.mouseLocation
        let now = ProcessInfo.processInfo.systemUptime
        if isDraggingContent, NSEvent.pressedMouseButtons & 1 == 0 {
            isDraggingContent = false // missed mouse-up (e.g. released over a secure input field)
            mouseDragging = false
        }
        let dragging = isDraggingContent

        var hovered: ScreenHost?
        var nearest = CGFloat.infinity
        for (i, h) in hosts.enumerated() {
            guard !h.hidden else {
                if !h.panel.ignoresMouseEvents { h.panel.ignoresMouseEvents = true }
                continue
            }
            let rect = activeRect(h, idleExtra: idleExtra)
            let inside = (pinned && i == 0) || rect.contains(mouse)
            if h.panel.ignoresMouseEvents == inside { h.panel.ignoresMouseEvents = !inside }
            if inside, hovered == nil { hovered = h }
            nearest = min(nearest, Self.distance(mouse, rect))

            let growing = inside && !model.isOpen(on: h.displayID)
            if h.state.isHovering != growing {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { h.state.isHovering = growing }
            }
            if !inside { h.hoverSince = nil }
        }
        model.pointerDisplay = hovered?.displayID
            ?? NSScreen.screens.first(where: { $0.frame.contains(mouse) })?.displayID

        if let h = hovered {
            if model.isOpen(on: h.displayID) {
                collapseWork?.cancel()
                collapseWork = nil
            } else if dragging || (settings.openOnHover && !model.suppressHoverOpen
                                   && model.activity?.isInteractive != true) {
                let since = h.hoverSince ?? now
                h.hoverSince = since
                if dragging || now - since >= display.hoverDelay {
                    collapseWork?.cancel()
                    collapseWork = nil
                    model.open(tab: dragging ? .shelf : nil, on: h.displayID)
                }
            }
        } else if model.suppressHoverOpen {
            model.suppressHoverOpen = false
        }

        let overOpen = hovered.map { model.isOpen(on: $0.displayID) } ?? false
        if overOpen { model.holdOpenUntil = nil }
        let held = (model.holdOpenUntil ?? .distantPast) > Date()
        if model.isExpanded, !overOpen, !pinned, !held, collapseWork == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.model.close()
                self.collapseWork = nil
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }

        // 30Hz only while something is happening near a notch; 10Hz otherwise.
        let busy = model.isExpanded || collapseWork != nil || hovered != nil || nearest < Self.nearDistance
        setTimer(interval: busy ? Self.fastInterval : Self.slowInterval)
    }

    private static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }
}
