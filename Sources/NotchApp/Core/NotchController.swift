import AppKit
import SwiftUI

final class NotchPanel: NSPanel {
    // Never take keyboard focus from the user's app; buttons work without key status.
    override var canBecomeKey: Bool { false }
}

final class NotchController {
    static let panelSize = CGSize(width: 720, height: 260)

    let model = NotchModel()
    let nowPlaying = NowPlaying()
    let battery = Battery()
    let shelf = Shelf()
    let settings = AppSettings.shared
    private let panel: NotchPanel
    private var calendar: CalendarService!
    private var services: [AnyObject] = []
    private var timer: Timer?
    private var collapseWork: DispatchWorkItem?

    init() {
        panel = NotchPanel(
            contentRect: .zero,
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

        let context = NotchContext(model: model, nowPlaying: nowPlaying, battery: battery,
                                   shelf: shelf, settings: settings, panel: panel)
        calendar = CalendarService(context: context)
        services = [
            HUDService(context: context),
            ActivityService(context: context),
            GestureService(context: context),
            LockScreenService(context: context),
        ]

        let root = NotchView()
            .environmentObject(model)
            .environmentObject(nowPlaying)
            .environmentObject(battery)
            .environmentObject(shelf)
            .environmentObject(settings)
            .environmentObject(calendar)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: Self.panelSize)
        panel.contentView = host

        layout()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.layout() }

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.trackMouse()
        }
    }

    /// nil briefly during display reconfiguration (e.g. clamshell), when there are no screens.
    private var screen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func layout() {
        guard let s = screen else { return }
        let insetTop = s.safeAreaInsets.top
        if insetTop > 0,
           let left = s.auxiliaryTopLeftArea, let right = s.auxiliaryTopRightArea {
            model.notchSize = CGSize(width: s.frame.width - left.width - right.width, height: insetTop)
        } else {
            model.notchSize = CGSize(width: 190, height: 32)
        }
        let f = s.frame
        let size = Self.panelSize
        panel.setFrame(CGRect(x: f.midX - size.width / 2, y: f.maxY - size.height,
                              width: size.width, height: size.height), display: true)
    }

    /// Screen-space rect the notch currently occupies (plus some slack for hovering).
    private var activeRect: CGRect {
        guard let f = screen?.frame else { return .null }
        let size = model.currentSize(isPlaying: nowPlaying.isPlaying)
        let w = size.width + (model.isExpanded ? 20 : 30)
        let h = size.height + (model.isExpanded ? 20 : 8)
        return CGRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h)
    }

    private var dragBaseline = NSPasteboard(name: .drag).changeCount

    /// True while the user is dragging something (e.g. a file) — a plain click doesn't count.
    private var isDraggingContent: Bool {
        let count = NSPasteboard(name: .drag).changeCount
        guard NSEvent.pressedMouseButtons & 1 == 1 else { dragBaseline = count; return false }
        return count != dragBaseline
    }

    private func trackMouse() {
        // NOTCH_PIN=1 keeps the panel open, for screenshots while styling.
        let inside = ProcessInfo.processInfo.environment["NOTCH_PIN"] != nil
            || activeRect.contains(NSEvent.mouseLocation)
        panel.ignoresMouseEvents = !inside
        _ = isDraggingContent // keep the drag baseline fresh every tick

        if inside {
            collapseWork?.cancel()
            collapseWork = nil
            let dragging = isDraggingContent
            if !model.isExpanded, dragging || (settings.openOnHover && !model.suppressHoverOpen
                                                  && model.activity?.isInteractive != true) {
                model.open(tab: dragging ? .shelf : nil)
            }
        } else if !inside, model.suppressHoverOpen {
            model.suppressHoverOpen = false
        }
        if !inside, model.isExpanded, collapseWork == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.model.close()
                self.collapseWork = nil
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }
}
