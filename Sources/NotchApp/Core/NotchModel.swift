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
    /// Screen is locked and the notch is on the lock screen: only Home (music) and activities;
    /// calendar, shelf and settings stay hidden.
    @Published var isLocked = false
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

    /// One entry of the swipe-to-cycle list. `expires == nil` = persistent (until dismissed).
    struct RecentActivity {
        let activity: LiveActivity
        var expires: Date?
        var key: String { activity.key }
    }

    /// Recent / concurrent live activities (charging, Bluetooth, track peek, …), oldest first,
    /// deduped by `LiveActivity.key`, at most `maxRecent`. Expired non-persistent entries are pruned.
    /// HUDs (`hud.*`) are transient and never recorded. Swiping sideways on the closed notch cycles
    /// through these (see `GestureService` for gesture precedence).
    @Published private(set) var recentActivities: [RecentActivity] = []
    /// Slide direction of the in-flight cycle transition: +1 = next (enters from trailing),
    /// -1 = previous, 0 = regular present (crossfade).
    @Published private(set) var cycleDirection = 0
    static let maxRecent = 5
    /// A cycled-to activity stays at least this long, even if it was about to expire.
    static let cycleMinDwell: TimeInterval = 3
    static let cycleAnimation = Animation.spring(response: 0.36, dampingFraction: 0.86)
    /// Height added under the closed notch for the page dots.
    static let pageDotsHeight: CGFloat = 9
    private var pruneWork: DispatchWorkItem?
    private var cycleResetWork: DispatchWorkItem?

    /// Index of the showing activity in `recentActivities`, if it's part of the cycle.
    var cycleIndex: Int? {
        guard let key = activity?.key else { return nil }
        return recentActivities.firstIndex { $0.key == key }
    }

    /// True when page dots should show under the closed notch (current activity + at least one more).
    var showsPageDots: Bool { recentActivities.count > 1 && cycleIndex != nil }

    func currentSize(isPlaying: Bool) -> CGSize {
        size(notch: notchSize, expanded: isExpanded, idleExtra: isPlaying ? 84 : 0)
    }

    /// Shape size for a panel with the given notch. `idleExtra` = width added by idle content.
    func size(notch: CGSize, expanded: Bool, idleExtra: CGFloat) -> CGSize {
        if expanded { return Self.expandedSize }
        if let a = activity {
            let dots = showsPageDots ? Self.pageDotsHeight : 0
            return CGSize(width: notch.width + a.extraWidth, height: notch.height + a.belowHeight + dots)
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
        if isLocked { self.tab = .home } else if let tab { self.tab = tab }
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
        guard !isLocked else { return }
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
            record(activity, expires: deadline)
            self.activity = activity
        } else {
            // Recorded inside the animation so the page dots' extra height springs in with it.
            withAnimation(cycleDirection == 0 ? Self.openAnimation : Self.cycleAnimation) {
                record(activity, expires: deadline)
                self.activity = activity
            }
        }
        guard let duration else { return }
        let work = DispatchWorkItem { [weak self] in self?.dismissActivity(key: activity.key) }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func dismissActivity(key: String) {
        if let i = recentActivities.firstIndex(where: { $0.key == key }) { recentActivities.remove(at: i) }
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

    // MARK: Swipe to cycle

    /// Shows the next (`offset` > 0) or previous recent activity with a slide, wrapping around.
    /// Returns false (nothing happens) unless an activity from the cycle list is showing and there
    /// is at least one other one. Must be called on the main thread.
    @discardableResult
    func cycleActivity(offset: Int) -> Bool {
        prune()
        let n = recentActivities.count
        guard !isExpanded, n > 1, offset != 0, let i = cycleIndex else { return false }
        let target = recentActivities[((i + offset) % n + n) % n]
        let remaining = target.expires.map { max($0.timeIntervalSinceNow, Self.cycleMinDwell) }
        // Set the direction in its own update first so the outgoing view's removal transition
        // already slides the right way, then swap the activity on the next turn.
        cycleDirection = offset > 0 ? 1 : -1
        cycleResetWork?.cancel()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.cycleDirection != 0 else { return }
            self.present(target.activity, duration: remaining)
            let reset = DispatchWorkItem { [weak self] in self?.cycleDirection = 0 }
            self.cycleResetWork = reset
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: reset)
        }
        return true
    }

    private func record(_ activity: LiveActivity, expires: Date?) {
        guard !activity.key.hasPrefix("hud.") else { return }
        if let i = recentActivities.firstIndex(where: { $0.key == activity.key }) {
            recentActivities[i] = RecentActivity(activity: activity, expires: expires)
        } else {
            recentActivities.append(RecentActivity(activity: activity, expires: expires))
        }
        // Drop the oldest entries (never the one being shown).
        while recentActivities.count > Self.maxRecent,
              let i = recentActivities.firstIndex(where: { $0.key != activity.key }) {
            recentActivities.remove(at: i)
        }
        prune()
    }

    /// Removes expired non-persistent entries (other than the showing one, which its own timer
    /// dismisses) and schedules the next prune at the earliest remaining expiry so the dots stay
    /// accurate. One pending work item at most; nothing scheduled when the list has no expiries.
    private func prune() {
        pruneWork?.cancel()
        pruneWork = nil
        let now = Date()
        let current = activity?.key
        let kept = recentActivities.filter { $0.key == current || ($0.expires ?? .distantFuture) > now }
        if kept.count != recentActivities.count {
            withAnimation(Self.closeAnimation) { recentActivities = kept }
        }
        guard let next = kept.filter({ $0.key != current }).compactMap(\.expires).min() else { return }
        let work = DispatchWorkItem { [weak self] in self?.prune() }
        pruneWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(next.timeIntervalSince(now), 0) + 0.05, execute: work)
    }
}
