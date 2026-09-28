import AppKit

/// Trackpad swipe gestures on the notch. (Owned by the Settings/Gestures agent.)
///
/// The panel only receives scroll events while the cursor is over the notch (it ignores mouse
/// events otherwise), so a local monitor filtered to that window is enough.
///
/// Collapsed: swipe down opens; swipe up dismisses the live activity (if enabled);
/// horizontal swipe while music plays = next/previous track.
/// Expanded: swipe up closes; horizontal swipe switches tabs.
/// Directions follow the fingers regardless of the system "Natural scrolling" setting
/// (optionally reversed). One action per gesture, dominant axis only, momentum ignored.
final class GestureService {
    private let context: NotchContext
    private let prefs = GestureSettings.shared
    private var monitor: Any?
    /// Movement needed before the gesture's axis is locked.
    private static let axisLockDistance: CGFloat = 8
    /// For precise devices that send no phases: gap that starts a new gesture.
    private static let idleReset: TimeInterval = 0.3

    private enum Axis { case horizontal, vertical }

    private var accum = CGVector.zero
    private var axis: Axis?
    private var triggered = false
    private var lastTimestamp: TimeInterval = 0

    init(context: NotchContext) {
        self.context = context
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private func reset() {
        accum = .zero
        axis = nil
        triggered = false
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard context.settings.gesturesEnabled,
              event.window is NotchPanel,
              event.hasPreciseScrollingDeltas else { return event }

        // Momentum after the fingers lift: never an action; swallow it if this gesture acted.
        if !event.momentumPhase.isEmpty { return triggered ? nil : event }

        let phase = event.phase
        if phase.contains(.mayBegin) { return event }
        if phase.contains(.began) {
            reset()
        } else if phase.isEmpty, event.timestamp - lastTimestamp > Self.idleReset {
            reset()
        }
        lastTimestamp = event.timestamp

        if phase.contains(.ended) || phase.contains(.cancelled) {
            let acted = triggered
            accum = .zero
            axis = nil
            // Keep `triggered` so trailing momentum events are swallowed too; `.began` resets it.
            return acted ? nil : event
        }
        if triggered { return nil }

        // Normalize to finger movement: +y = fingers move down, +x = fingers move right.
        // scrollingDelta follows content, which matches the fingers only with natural scrolling on.
        var sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        if prefs.reverseDirection { sign = -sign }
        accum.dx += event.scrollingDeltaX * sign
        accum.dy += event.scrollingDeltaY * sign

        if axis == nil, max(abs(accum.dx), abs(accum.dy)) >= Self.axisLockDistance {
            axis = abs(accum.dx) > abs(accum.dy) ? .horizontal : .vertical
        }
        guard let axis else { return event }

        if perform(axis: axis, at: event) {
            triggered = true
            if prefs.haptics {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            return nil
        }
        return event
    }

    /// Returns true if an action fired.
    private func perform(axis: Axis, at event: NSEvent) -> Bool {
        let model = context.model
        let t = CGFloat(prefs.sensitivity.rawValue)
        switch axis {
        case .vertical:
            if !model.isExpanded, accum.dy >= t {
                model.open()
                return true
            }
            if !model.isExpanded, accum.dy <= -t, prefs.swipeToDismiss, let activity = model.activity {
                model.dismissActivity(key: activity.key)
                return true
            }
            if model.isExpanded, accum.dy <= -t {
                // Scrolling a list (e.g. the day's events) must not close the notch.
                if isOverScrollView(event, axis: .vertical) { return false }
                model.suppressHoverOpen = true
                model.close()
                return true
            }
        case .horizontal:
            guard abs(accum.dx) >= t else { return false }
            // Fingers moving left = forward.
            let forward = accum.dx < 0
            if model.isExpanded {
                if isOverScrollView(event, axis: .horizontal) { return false }
                let before = model.tab
                model.selectTab(offset: forward ? 1 : -1)
                // At the first/last tab nothing changes; no haptic, let the event through.
                return model.tab != before
            }
            if context.nowPlaying.isPlaying {
                context.nowPlaying.send(forward ? "next track" : "previous track")
                return true
            }
        }
        return false
    }

    /// True if the cursor is over a scroll view that can scroll along `axis` (e.g. the shelf, the
    /// calendar's event list), so swipes there scroll content instead of switching tabs / closing.
    private func isOverScrollView(_ event: NSEvent, axis: Axis) -> Bool {
        guard let content = event.window?.contentView,
              let frameView = content.superview else { return false }
        let point = frameView.convert(event.locationInWindow, from: nil)
        var view = content.hitTest(point)
        while let v = view {
            if let scroll = v as? NSScrollView, let doc = scroll.documentView {
                let scrollable = axis == .horizontal
                    ? doc.frame.width > scroll.contentView.bounds.width + 1
                    : doc.frame.height > scroll.contentView.bounds.height + 1
                if scrollable { return true }
            }
            view = v.superview
        }
        return false
    }
}
