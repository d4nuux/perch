import CoreGraphics
import SwiftUI

/// Shared UI state for the notch. Feature modules talk to the notch only through this type.
final class NotchModel: ObservableObject {
    enum Tab: CaseIterable { case home, calendar, shelf }

    @Published var isExpanded = false
    @Published var tab: Tab = .home
    @Published var dropTargeted = false
    /// Set when a gesture closes the notch under the cursor; hover won't reopen until the mouse leaves.
    var suppressHoverOpen = false
    /// Opened without the pointer (URL scheme, menu bar): don't auto-collapse before this time
    /// unless the pointer visits and leaves the notch.
    var holdOpenUntil: Date?
    /// True while something asks for quiet (e.g. user is in a meeting and chose "disable activities
    /// during events"). Non-essential activities (activity.*) should not present while set; HUDs still do.
    @Published var quietMode = false
    /// Notch size of the primary panel's screen (each panel also has its own `NotchScreen.notchSize`).
    @Published var notchSize = CGSize(width: 190, height: 32)
    /// Display whose notch is open. Only one panel is expanded at a time (with "All displays").
    @Published var expandedDisplay: CGDirectDisplayID?
    /// Set by the controller: display under/nearest the pointer, and the primary panel's display.
    /// `open()` without an explicit display opens there.
    var pointerDisplay: CGDirectDisplayID?
    var primaryDisplay: CGDirectDisplayID?
    /// The live activity currently shown around the closed notch (HUDs, charging, etc.).
    @Published private(set) var activity: LiveActivity?

    static let expandedSize = CGSize(width: 600, height: 170)
    static let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.76)
    static let closeAnimation = Animation.spring(response: 0.34, dampingFraction: 0.9)
    static let tabAnimation = Animation.easeInOut(duration: 0.18)

    private var dismissWork: DispatchWorkItem?
    private var deadline: Date?
    /// An interactive activity (e.g. meeting alert) temporarily covered by another one; restored after.
    private var suspended: (activity: LiveActivity, remaining: TimeInterval?)?

    func currentSize(isPlaying: Bool) -> CGSize {
        size(notch: notchSize, expanded: isExpanded, idleExtra: isPlaying ? 84 : 0)
    }

    /// Shape size for a panel with the given notch. `idleExtra` = width added by idle content.
    func size(notch: CGSize, expanded: Bool, idleExtra: CGFloat) -> CGSize {
        if expanded { return Self.expandedSize }
        if let a = activity {
            return CGSize(width: notch.width + a.extraWidth, height: notch.height + a.belowHeight)
        }
        return CGSize(width: notch.width + idleExtra, height: notch.height)
    }

    /// True if the panel on `display` should render expanded.
    func isOpen(on display: CGDirectDisplayID) -> Bool {
        isExpanded && (expandedDisplay ?? primaryDisplay ?? display) == display
    }

    // MARK: Open / close

    /// Opens on `display`, else the display under the pointer, else the primary one. If another
    /// display's notch is open, it moves there (that one collapses).
    func open(tab: Tab? = nil, on display: CGDirectDisplayID? = nil) {
        if let tab { self.tab = tab }
        let target = display ?? pointerDisplay ?? primaryDisplay
        if isExpanded {
            if let target, target != expandedDisplay {
                withAnimation(Self.openAnimation) { expandedDisplay = target }
            }
            return
        }
        expandedDisplay = target
        withAnimation(Self.openAnimation) { isExpanded = true }
    }

    func close() {
        guard isExpanded else { return }
        withAnimation(Self.closeAnimation) { isExpanded = false }
    }

    func selectTab(offset: Int) {
        let all = Tab.allCases
        let i = all.firstIndex(of: tab) ?? 0
        let next = min(max(i + offset, 0), all.count - 1)
        withAnimation(Self.tabAnimation) { tab = all[next] }
    }

    // MARK: Live activities

    /// Shows `activity` around the closed notch. Presenting an activity with the same `key` as the
    /// current one updates it in place and restarts its timer, so repeated volume-key presses don't
    /// re-animate. `duration: nil` keeps it until `dismissActivity(key:)`.
    /// Must be called on the main thread.
    func present(_ activity: LiveActivity, duration: TimeInterval? = 2.0) {
        dismissWork?.cancel()
        if let current = self.activity, current.key != activity.key, current.isInteractive {
            suspended = (current, deadline.map { max($0.timeIntervalSinceNow, 3) })
        }
        deadline = duration.map { Date().addingTimeInterval($0) }
        if self.activity?.key == activity.key {
            self.activity = activity
        } else {
            withAnimation(Self.openAnimation) { self.activity = activity }
        }
        guard let duration else { return }
        let work = DispatchWorkItem { [weak self] in self?.dismissActivity(key: activity.key) }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func dismissActivity(key: String) {
        if suspended?.activity.key == key { suspended = nil }
        guard activity?.key == key else { return }
        if let s = suspended {
            suspended = nil
            present(s.activity, duration: s.remaining)
            return
        }
        deadline = nil
        withAnimation(Self.closeAnimation) { activity = nil }
    }
}
