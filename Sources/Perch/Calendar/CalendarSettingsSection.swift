import SwiftUI

/// Calendar sections for the Settings window.
/// Options persist in the folder's own settings object rather than Core/AppSettings.
struct CalendarSettingsSection: View {
    @ObservedObject var s = CalendarSettings.shared
    @ObservedObject private var app = AppSettings.shared

    var body: some View {
        Group {
            Section("Calendar tab") {
                SettingPicker("Layout", selection: $s.layout, segmented: true) {
                    Text("Week strip").tag(CalendarSettings.Layout.week)
                    Text("Agenda").tag(CalendarSettings.Layout.agenda)
                }
                calendarList
                SettingToggle("Show weather", detail: "Today's forecast at the top of the Calendar tab.",
                              isOn: $s.showWeather)
            }

            Section("Alerts") {
                SettingPicker("Alert before events", selection: $s.alertLeadMinutes) {
                    ForEach(CalendarSettings.leadChoices, id: \.self) { Text("\($0) min").tag($0) }
                }
                SettingToggle("Alert when events start", isOn: $s.alertAtStart)
                SettingToggle("Play sound with alerts", isOn: $s.alertSound)
                SettingToggle("Quiet during events",
                              detail: "While an accepted, timed event is in progress, other live activities stay hidden. HUDs still show.",
                              isOn: $s.quietDuringEvents)
                SettingToggle("Hourly chime", detail: "A short chime at the top of every hour.", isOn: $s.hourlyChime)
            }

            Section {
                SettingToggle("Time to leave",
                              detail: "For events with a physical address, alerts when it's time to leave based on travel time from your location.",
                              isOn: $s.timeToLeave)
                if s.timeToLeave {
                    SettingPicker("Travel by", selection: $s.transport, segmented: true) {
                        Label("Driving", systemImage: CalendarSettings.Transport.driving.symbol)
                            .tag(CalendarSettings.Transport.driving)
                        Label("Walking", systemImage: CalendarSettings.Transport.walking.symbol)
                            .tag(CalendarSettings.Transport.walking)
                        Label("Transit", systemImage: CalendarSettings.Transport.transit.symbol)
                            .tag(CalendarSettings.Transport.transit)
                    }
                    SettingStepper("Extra buffer", detail: "Added on top of the travel time.",
                                   value: $s.leaveBufferMinutes, in: 0...30, step: 5, format: { "\($0) min" })
                }
            } header: {
                SectionHeader("Travel")
            }
        }
        .disabled(!app.calendarEnabled)

        Section {
            WeatherSettingsSection()
        } header: {
            SectionHeader("Weather", detail: "Used by the Calendar tab and the Lock Screen.")
        }
    }

    @ViewBuilder private var calendarList: some View {
        if s.calendars.isEmpty {
            SettingRow("Calendars", detail: "Grant calendar access in Permissions to choose which calendars show.") {
                Button("Permissions…") { SettingsNavigation.shared.pane = .permissions }
            }
            .onAppear { s.loadCalendars() }
        } else {
            DisclosureGroup {
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
                    .toggleStyle(.checkbox)
                }
            } label: {
                SettingLabel(title: "Calendars shown",
                             detail: "\(s.calendars.count - s.calendars.filter { s.hiddenCalendars.contains($0.id) }.count) of \(s.calendars.count)")
            }
            .onAppear { s.loadCalendars() }
        }
    }
}
