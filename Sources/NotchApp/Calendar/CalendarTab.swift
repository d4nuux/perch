import SwiftUI

private let secondary = Color.white.opacity(0.55)

/// Content of the Calendar tab in the open notch (~556x110 under the header).
struct CalendarTab: View {
    @EnvironmentObject var calendar: CalendarService
    @EnvironmentObject var settings: AppSettings
    @ObservedObject var options = CalendarSettings.shared

    var body: some View {
        Group {
            if !settings.calendarEnabled {
                placeholder(icon: "calendar", text: "Calendar is turned off in Settings")
            } else if calendar.access == .granted, options.layout == .agenda {
                AgendaList()
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
    @ObservedObject var options = CalendarSettings.shared
    @ObservedObject var weather = WeatherService.shared
    @ObservedObject var units = WeatherSettings.shared

    var body: some View {
        let cal = Calendar.current
        let count = calendar.events(on: calendar.selectedDay).count
        let now = cal.isDate(calendar.selectedDay, inSameDayAs: calendar.today) && options.showWeather
            ? weather.current : nil
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(calendar.selectedDay, format: .dateTime.month(.wide).year())
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    if let now {
                        HStack(spacing: 4) {
                            Image(systemName: now.symbol).symbolRenderingMode(.multicolor)
                                .font(.system(size: 12))
                            Text(units.format(now.temperature))
                                .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        }
                        .help(now.summary)
                    }
                }
                HStack(spacing: 6) {
                    Text("\(dayLabel(calendar.selectedDay)) · \(count == 0 ? "No" : "\(count)") event\(count == 1 ? "" : "s")")
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let now {
                        Text("H \(units.format(now.high))  L \(units.format(now.low))").monospacedDigit()
                    }
                }
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
            EmptyDayView(day: calendar.selectedDay, text: "No events")
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

/// Empty day: that day's forecast and sunrise/sunset when weather is on, else a plain placeholder.
private struct EmptyDayView: View {
    let day: Date
    let text: String
    @ObservedObject var options = CalendarSettings.shared
    @ObservedObject var weather = WeatherService.shared
    @ObservedObject var units = WeatherSettings.shared

    var body: some View {
        let isToday = Calendar.current.isDateInToday(day)
        let forecast = options.showWeather ? weather.forecast(for: day) : nil
        let current = options.showWeather && isToday ? weather.current : nil
        if forecast != nil || current != nil {
            let symbol = current?.symbol ?? forecast?.symbol ?? "cloud.fill"
            let summary = current?.summary ?? forecast?.summary ?? ""
            let high = current?.high ?? forecast?.high ?? 0
            let low = current?.low ?? forecast?.low ?? 0
            let sunrise = current?.sunrise ?? forecast?.sunrise
            let sunset = current?.sunset ?? forecast?.sunset
            HStack(spacing: 14) {
                Image(systemName: symbol).symbolRenderingMode(.multicolor).font(.system(size: 30))
                VStack(alignment: .leading, spacing: 3) {
                    Text(current.map { "\(units.format($0.temperature)) · \(summary)" } ?? summary)
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text("H \(units.format(high))  L \(units.format(low))"
                         + ((current?.precipitationChance ?? 0) >= 0.2
                            ? "  ·  \(Int(((current?.precipitationChance ?? 0) * 100).rounded()))% rain" : ""))
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(secondary)
                    if sunrise != nil || sunset != nil {
                        HStack(spacing: 10) {
                            if let sunrise { SunTime(icon: "sunrise.fill", date: sunrise) }
                            if let sunset { SunTime(icon: "sunset.fill", date: sunset) }
                        }
                    }
                    Text(text).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "calendar.badge.checkmark").font(.system(size: 18))
                Text(text).font(.system(size: 12))
            }
            .foregroundStyle(secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct SunTime: View {
    let icon: String
    let date: Date

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon).symbolRenderingMode(.multicolor).font(.system(size: 10))
            Text(date, format: .dateTime.hour().minute())
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(secondary)
        }
    }
}

/// Agenda layout: upcoming events grouped by day, with today's weather in the header row.
private struct AgendaList: View {
    @EnvironmentObject var calendar: CalendarService
    @ObservedObject var options = CalendarSettings.shared
    @ObservedObject var weather = WeatherService.shared
    @ObservedObject var units = WeatherSettings.shared

    var body: some View {
        let cal = Calendar.current
        let now = Date()
        let days = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: calendar.today) }
        let groups: [(day: Date, events: [CalendarEvent])] = days.compactMap { day in
            let evs = calendar.events(on: day).filter { $0.isAllDay || $0.end > now }
            return evs.isEmpty ? nil : (day, evs)
        }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(calendar.today, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if options.showWeather, let w = weather.current {
                    Image(systemName: w.symbol).symbolRenderingMode(.multicolor).font(.system(size: 12))
                    Text(units.format(w.temperature)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    Text("H \(units.format(w.high))  L \(units.format(w.low))")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(secondary)
                }
            }
            if groups.isEmpty {
                EmptyDayView(day: calendar.today, text: "No upcoming events")
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(groups, id: \.day) { g in
                            Text(label(g.day).uppercased())
                                .font(.system(size: 9, weight: .semibold)).foregroundStyle(secondary)
                                .padding(.top, 2)
                            let allDay = g.events.filter(\.isAllDay)
                            if !allDay.isEmpty { FlowChips(events: allDay) }
                            ForEach(g.events.filter { !$0.isAllDay }) { EventRow(event: $0) }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private func label(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInTomorrow(day) { return "Tomorrow" }
        return day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}
