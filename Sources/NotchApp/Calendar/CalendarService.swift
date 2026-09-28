import AppKit
import Combine
import EventKit
import SwiftUI

/// A calendar event, snapshotted from EventKit.
struct CalendarEvent: Identifiable {
    /// Unique per occurrence (recurring events share `eventIdentifier`).
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let color: CGColor
    let joinURL: URL?

    var tint: Color { Color(cgColor: color) }
}

/// Calendar events + upcoming-meeting live activity. (Owned by the Calendar agent.)
/// Gated by `settings.calendarEnabled`. Refreshes on `.EKEventStoreChanged`, day change, wake,
/// and once a minute (a single timer aligned to minute boundaries).
final class CalendarService: ObservableObject {
    enum Access { case notDetermined, granted, denied }

    static let activityKey = "calendar.upcoming"
    static let privacyURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!

    @Published private(set) var access: Access = .notDetermined
    /// Events overlapping the visible week plus tomorrow, sorted (all-day first, then by start).
    @Published private(set) var events: [CalendarEvent] = []
    @Published private(set) var today = Calendar.current.startOfDay(for: Date())
    @Published var selectedDay = Calendar.current.startOfDay(for: Date())

    private let context: NotchContext
    private var store = EKEventStore()
    private var enabled = false
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var cancellables = Set<AnyCancellable>()
    private var requesting = false
    /// Alert keys already shown ("<event id>|soon" / "|now") -> event start, for pruning.
    private var fired: [String: Date] = [:]
    private var alertWork: DispatchWorkItem?

    init(context: NotchContext) {
        self.context = context
        context.settings.$calendarEnabled
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] on in self?.setEnabled(on) }
            .store(in: &cancellables)
    }

    deinit { stop() }

    // MARK: Public

    /// The 7 days of the week containing today (locale's first weekday).
    var weekDays: [Date] {
        let cal = Calendar.current
        let start = cal.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    func events(on day: Date) -> [CalendarEvent] {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        return events.filter { $0.start < dayEnd && ($0.end > dayStart || $0.start >= dayStart) }
    }

    func hasEvents(on day: Date) -> Bool { !events(on: day).isEmpty }

    func select(_ day: Date) { selectedDay = Calendar.current.startOfDay(for: day) }

    /// Tab button: prompts if never asked, otherwise opens System Settings > Privacy > Calendars.
    func requestAccessOrOpenSettings() {
        if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            requestAccess()
        } else {
            NSWorkspace.shared.open(Self.privacyURL)
        }
    }

    func join(_ event: CalendarEvent) {
        guard let url = event.joinURL else { return }
        NSWorkspace.shared.open(url)
        context.model.dismissActivity(key: Self.activityKey)
    }

    // MARK: Lifecycle

    private func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on { start() } else { stop() }
    }

    private func start() {
        let nc = NotificationCenter.default
        let wnc = NSWorkspace.shared.notificationCenter
        observers = [
            (nc, nc.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
                self?.reload()
            }),
            (nc, nc.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
                self?.tick()
            }),
            (wnc, wnc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.tick()
            }),
        ]

        // Single repeating timer, fired just after each minute boundary (covers midnight too).
        let now = Date()
        let next = Calendar.current.dateInterval(of: .minute, for: now)?.end ?? now.addingTimeInterval(60)
        let t = Timer(fire: next.addingTimeInterval(0.5), interval: 60, repeats: true) { [weak self] _ in
            self?.tick()
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t

        checkAccess(prompt: true)
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        alertWork?.cancel()
        alertWork = nil
        events = []
        context.model.dismissActivity(key: Self.activityKey)
    }

    private func tick() {
        guard enabled else { return }
        let day = Calendar.current.startOfDay(for: Date())
        if day != today {
            today = day
            selectedDay = day
        }
        checkAccess(prompt: false)
    }

    // MARK: Access

    private func checkAccess(prompt: Bool) {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            // Granted later via System Settings: a fresh store picks up the new permission.
            if access != .granted { store = EKEventStore() }
            access = .granted
            reload()
        case .notDetermined:
            access = .notDetermined
            if prompt { requestAccess() }
        default: // denied, restricted, writeOnly
            access = .denied
            events = []
        }
    }

    private func requestAccess() {
        guard !requesting else { return }
        requesting = true
        store.requestFullAccessToEvents { [weak self] granted, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.requesting = false
                self.access = granted ? .granted : .denied
                if granted { self.reload() }
            }
        }
    }

    // MARK: Fetch

    private func reload() {
        guard enabled, access == .granted else { return }
        let cal = Calendar.current
        let days = weekDays
        guard let first = days.first, let last = days.last,
              let weekEnd = cal.date(byAdding: .day, value: 1, to: last),
              let tomorrowEnd = cal.date(byAdding: .day, value: 2, to: today) else { return }
        let predicate = store.predicateForEvents(withStart: min(first, today),
                                                 end: max(weekEnd, tomorrowEnd), calendars: nil)
        events = store.events(matching: predicate)
            .filter { ev in
                ev.status != .canceled
                    && ev.attendees?.first(where: { $0.isCurrentUser })?.participantStatus != .declined
            }
            .map { ev in
                let start = ev.startDate ?? Date.distantPast
                return CalendarEvent(
                    id: "\(ev.eventIdentifier ?? ev.calendarItemIdentifier)|\(start.timeIntervalSinceReferenceDate)",
                    title: (ev.title?.isEmpty == false ? ev.title! : "Untitled"),
                    start: start,
                    end: ev.endDate ?? start,
                    isAllDay: ev.isAllDay,
                    color: ev.calendar?.cgColor ?? NSColor.systemBlue.cgColor,
                    joinURL: MeetingLink.find(in: [ev.url?.absoluteString, ev.location, ev.notes])
                )
            }
            .sorted { a, b in
                if a.isAllDay != b.isAllDay { return a.isAllDay }
                if a.start != b.start { return a.start < b.start }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
        evaluateAlerts()
    }

    // MARK: Upcoming-meeting alert

    private func evaluateAlerts() {
        alertWork?.cancel()
        alertWork = nil
        guard enabled, access == .granted else { return }
        let now = Date()
        fired = fired.filter { $0.value > now.addingTimeInterval(-86_400) }

        var due: (event: CalendarEvent, isNow: Bool)?
        for e in events where !e.isAllDay {
            let lead = e.start.timeIntervalSince(now)
            let soonKey = e.id + "|soon", nowKey = e.id + "|now"
            // "now": from start until 5 min in (or the event's end, if shorter).
            let nowWindow = min(300, max(60, e.end.timeIntervalSince(e.start)))
            if lead <= 0, -lead < nowWindow, fired[nowKey] == nil { due = (e, true); break }
            if lead > 0, lead <= 300, fired[soonKey] == nil, fired[nowKey] == nil { due = (e, false); break }
        }
        guard let due else { return }

        let model = context.model
        if model.isExpanded || model.activity?.key.hasPrefix("hud.") == true {
            schedule(after: 3)
            return
        }
        fired[due.event.id + "|soon"] = due.event.start
        if due.isNow { fired[due.event.id + "|now"] = due.event.start }
        model.present(makeActivity(due.event), duration: 8)
        // Another event may be due at the same time: check again once this one is gone.
        schedule(after: 8.5)
    }

    private func schedule(after seconds: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in self?.evaluateAlerts() }
        alertWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func makeActivity(_ event: CalendarEvent) -> LiveActivity {
        LiveActivity(key: Self.activityKey, extraWidth: 110) {
            Image(systemName: "calendar")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(event.tint)
        } trailing: {
            CountdownText(start: event.start)
        }
        .withBelow(height: 34) {
            UpcomingEventBanner(event: event) { [weak self] in self?.join(event) }
        }
        .interactive()
    }
}
