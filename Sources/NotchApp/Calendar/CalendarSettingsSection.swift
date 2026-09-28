import SwiftUI

/// Calendar rows for the Settings window (a Form section). Owner: Calendar agent.
/// Persist new options in your own ObservableObject in this folder; don't grow Core/AppSettings.
struct CalendarSettingsSection: View {
    @ObservedObject var s = CalendarSettings.shared

    var body: some View {
        Picker("Calendar tab layout", selection: $s.layout) {
            Text("Week strip").tag(CalendarSettings.Layout.week)
            Text("Agenda").tag(CalendarSettings.Layout.agenda)
        }
        calendarList
        Picker("Alert before events", selection: $s.alertLeadMinutes) {
            ForEach(CalendarSettings.leadChoices, id: \.self) { Text("\($0) min").tag($0) }
        }
        Toggle("Alert when events start", isOn: $s.alertAtStart)
        Toggle("Play sound with alerts", isOn: $s.alertSound)
        Toggle("Disable activities during events", isOn: $s.quietDuringEvents)
            .help("While an accepted, timed event is in progress, other live activities stay hidden. HUDs still show.")
        Toggle("Time to leave", isOn: $s.timeToLeave)
            .help("For events with a physical address, alerts when it's time to leave based on travel time from your location.")
        if s.timeToLeave {
            Picker("Travel by", selection: $s.transport) {
                Text("Driving").tag(CalendarSettings.Transport.driving)
                Text("Walking").tag(CalendarSettings.Transport.walking)
                Text("Transit").tag(CalendarSettings.Transport.transit)
            }
            Stepper("Extra buffer: \(s.leaveBufferMinutes) min", value: $s.leaveBufferMinutes, in: 0...30, step: 5)
        }
        Toggle("Hourly chime", isOn: $s.hourlyChime)
        Toggle("Show weather in Calendar", isOn: $s.showWeather)
        if s.showWeather {
            WeatherSettingsSection()
        }
    }

    @ViewBuilder private var calendarList: some View {
        if s.calendars.isEmpty {
            LabeledContent("Calendars", value: "Grant calendar access to choose")
                .onAppear { s.loadCalendars() }
        } else {
            DisclosureGroup("Calendars shown (\(s.calendars.count - s.calendars.filter { s.hiddenCalendars.contains($0.id) }.count)/\(s.calendars.count))") {
                ForEach(s.calendars) { c in
                    Toggle(isOn: Binding(get: { !s.hiddenCalendars.contains(c.id) },
                                         set: { s.setShown(c.id, $0) })) {
                        HStack(spacing: 6) {
                            Circle().fill(Color(cgColor: c.color)).frame(width: 8, height: 8)
                            Text(c.title)
                            if !c.source.isEmpty {
                                Text(c.source).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .onAppear { s.loadCalendars() }
        }
    }
}
