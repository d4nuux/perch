import SwiftUI

/// What the collapsed notch shows when no live activity is active.
enum IdleState {
    case none
    case nowPlaying
    case event(CalendarEvent)

    static let nowPlayingExtra: CGFloat = 84
    static let eventExtra: CGFloat = 170

    var extraWidth: CGFloat {
        switch self {
        case .none: 0
        case .nowPlaying: Self.nowPlayingExtra
        case .event: Self.eventExtra
        }
    }

    /// `.calendar` shows the next timed event that is ongoing or starts later today; with none it
    /// falls back to Now Playing (so music still shows between meetings).
    static func resolve(_ mode: DisplaySettings.IdleContent, nowPlaying: NowPlaying,
                        calendar: CalendarService?, now: Date = Date()) -> IdleState {
        switch mode {
        case .none:
            return .none
        case .nowPlaying:
            return nowPlaying.isPlaying ? .nowPlaying : .none
        case .calendar:
            if let calendar, let e = nextEvent(calendar.events, now: now) { return .event(e) }
            return nowPlaying.isPlaying ? .nowPlaying : .none
        }
    }

    static func nextEvent(_ events: [CalendarEvent], now: Date) -> CalendarEvent? {
        let cal = Calendar.current
        guard let endOfDay = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) else { return nil }
        return events
            .filter { !$0.isAllDay && $0.end > now && $0.start < endOfDay }
            .min { $0.start < $1.start }
    }
}

/// Collapsed "next event" rendering: tinted dot + title on the left, time on the right.
struct CollapsedEventView: View {
    let event: CalendarEvent
    let notchWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                Circle().fill(event.tint).frame(width: 6, height: 6)
                Text(event.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: notchWidth)
            // Minute resolution is enough; TimelineView(.everyMinute) wakes once per minute.
            TimelineView(.everyMinute) { ctx in
                Text(Self.label(event, now: ctx.date))
                    .font(.system(size: 11, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .foregroundStyle(.white)
    }

    static func label(_ e: CalendarEvent, now: Date) -> String {
        if e.start <= now { return "Now" }
        let mins = Int(ceil(e.start.timeIntervalSince(now) / 60))
        if mins < 60 { return "in \(mins)m" }
        return e.start.formatted(date: .omitted, time: .shortened)
    }
}
