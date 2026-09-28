import SwiftUI

private let secondary = Color.white.opacity(0.55)

/// Content of the Calendar tab in the open notch (~556x110 under the header).
struct CalendarTab: View {
    @EnvironmentObject var calendar: CalendarService
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Group {
            if !settings.calendarEnabled {
                placeholder(icon: "calendar", text: "Calendar is turned off in Settings")
            } else if calendar.access == .granted {
                HStack(spacing: 16) {
                    WeekStrip().frame(width: 210)
                    Divider().overlay(.white.opacity(0.15))
                    DayEventList()
                }
            } else {
                accessPrompt
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var accessPrompt: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 20)).foregroundStyle(secondary)
            Text("NotchApp needs access to your calendars")
                .font(.system(size: 12)).foregroundStyle(secondary)
            Button { calendar.requestAccessOrOpenSettings() } label: {
                Text("Allow calendar access")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(.white.opacity(0.18)))
            }
            .buttonStyle(.plain)
        }
    }

    private func placeholder(icon: String, text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 20))
            Text(text).font(.system(size: 12))
        }
        .foregroundStyle(secondary)
    }
}

/// Month title + 7-day strip; today highlighted, tap to select a day.
private struct WeekStrip: View {
    @EnvironmentObject var calendar: CalendarService

    var body: some View {
        let cal = Calendar.current
        let count = calendar.events(on: calendar.selectedDay).count
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(calendar.selectedDay, format: .dateTime.month(.wide).year())
                    .font(.system(size: 13, weight: .semibold))
                Text("\(dayLabel(calendar.selectedDay)) · \(count == 0 ? "No" : "\(count)") event\(count == 1 ? "" : "s")")
                    .font(.system(size: 11)).foregroundStyle(secondary)
            }
            HStack(spacing: 2) {
                ForEach(calendar.weekDays, id: \.self) { day in
                    let isToday = cal.isDate(day, inSameDayAs: calendar.today)
                    let isSelected = cal.isDate(day, inSameDayAs: calendar.selectedDay)
                    Button { calendar.select(day) } label: {
                        VStack(spacing: 3) {
                            Text(day, format: .dateTime.weekday(.narrow))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(isToday ? .white : secondary)
                            Text(day, format: .dateTime.day())
                                .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(isToday && !isSelected ? Color.red : .white)
                            Circle()
                                .fill(calendar.hasEvents(on: day) ? secondary : .clear)
                                .frame(width: 3, height: 3)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isSelected ? (isToday ? Color.red.opacity(0.85) : .white.opacity(0.18)) : .clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private func dayLabel(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInTomorrow(day) { return "Tomorrow" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide))
    }
}

/// Scrolling list of the selected day's events (all-day first).
private struct DayEventList: View {
    @EnvironmentObject var calendar: CalendarService

    var body: some View {
        let items = calendar.events(on: calendar.selectedDay)
        let allDay = items.filter(\.isAllDay)
        let timed = items.filter { !$0.isAllDay }
        if items.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "calendar.badge.checkmark").font(.system(size: 18))
                Text("No events").font(.system(size: 12))
            }
            .foregroundStyle(secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    if !allDay.isEmpty {
                        FlowChips(events: allDay)
                    }
                    ForEach(timed) { EventRow(event: $0) }
                }
                .padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

/// All-day events as compact chips on one scrolling line.
private struct FlowChips: View {
    let events: [CalendarEvent]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("ALL-DAY").font(.system(size: 9, weight: .semibold)).foregroundStyle(secondary)
                ForEach(events) { e in
                    Text(e.title)
                        .font(.system(size: 11, weight: .medium)).lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(e.tint.opacity(0.35)))
                }
            }
        }
    }
}

private struct EventRow: View {
    @EnvironmentObject var calendar: CalendarService
    let event: CalendarEvent

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            let past = event.end <= ctx.date
            let live = event.start <= ctx.date && !past
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(event.tint).frame(width: 3, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(timeRange + (live ? " · now" : ""))
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                if event.joinURL != nil, !past {
                    JoinButton { calendar.join(event) }
                }
            }
            .opacity(past ? 0.45 : 1)
        }
    }

    private var timeRange: String {
        let f = Date.FormatStyle.dateTime.hour().minute()
        return "\(event.start.formatted(f)) – \(event.end.formatted(f))"
    }
}

struct JoinButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "video.fill").font(.system(size: 9, weight: .semibold))
                Text("Join").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(Color.green.opacity(0.85)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: Live activity pieces

/// "in 5m" / "now", re-rendered each minute.
struct CountdownText: View {
    let start: Date

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            let mins = Int((start.timeIntervalSince(ctx.date) / 60).rounded(.up))
            Text(mins <= 0 ? "now" : "in \(mins)m")
                .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                .foregroundStyle(mins <= 0 ? Color.green : .white)
        }
    }
}

/// Below-the-notch strip of the upcoming-meeting activity.
struct UpcomingEventBanner: View {
    let event: CalendarEvent
    let onJoin: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5).fill(event.tint).frame(width: 3, height: 16)
            Text(event.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Spacer(minLength: 6)
            if event.joinURL != nil { JoinButton(action: onJoin) }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }
}
