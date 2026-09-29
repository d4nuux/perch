import AppKit
import CoreLocation
import MapKit
import SwiftUI

/// "Time to leave" for the next event with a physical location in the next 3 hours.
/// Driven by CalendarService's minute tick (no timer of its own): the ETA is recomputed at most every
/// 10 minutes and only while such an event exists; location is only requested in that case.
final class TimeToLeave {
    static let activityKey = "calendar.leave"
    private static let horizon: TimeInterval = 3 * 3600
    private static let recompute: TimeInterval = 10 * 60
    /// Heads-up this long before the leave time ("Leave in 12m"), then again at leave time.
    private static let headsUp: TimeInterval = 15 * 60

    private let model: NotchModel
    private let settings = CalendarSettings.shared
    private let geocoder = CLGeocoder()
    private var geoCache: [String: CLLocationCoordinate2D?] = [:]
    private var eta: (eventID: String, transport: CalendarSettings.Transport, travel: TimeInterval, at: Date,
                      dest: CLLocationCoordinate2D)?
    private var computing: String?
    private var fired: [String: Date] = [:]
    /// Pending retry while the notch is busy (expanded / HUD / meeting alert), every 3 s.
    private var retryWork: DispatchWorkItem?

    init(model: NotchModel) { self.model = model }

    func reset() {
        retryWork?.cancel()
        retryWork = nil
        eta = nil
        model.dismissActivity(key: Self.activityKey)
    }

    /// Call on every calendar tick/reload.
    func update(events: [CalendarEvent]) {
        guard settings.timeToLeave else { return reset() }
        let now = Date()
        fired = fired.filter { $0.value > now }
        guard let event = events.first(where: { e in
            !e.isAllDay && e.start > now && e.start.timeIntervalSince(now) < Self.horizon
                && e.physicalLocation != nil
        }) else { return reset() }

        if let eta, eta.eventID == event.id, eta.transport == settings.transport,
           -eta.at.timeIntervalSinceNow < Self.recompute {
            evaluate(event, travel: eta.travel, dest: eta.dest)
        } else {
            computeETA(for: event)
        }
    }

    // MARK: ETA

    private func computeETA(for event: CalendarEvent) {
        guard computing != event.id else { return }
        computing = event.id
        let transport = settings.transport
        destination(for: event) { [weak self] dest in
            guard let self else { return }
            guard let dest else { self.computing = nil; return }
            LocationProvider.shared.request { loc in
                guard let loc else { self.computing = nil; return }
                let req = MKDirections.Request()
                req.source = MKMapItem(placemark: MKPlacemark(coordinate: loc.coordinate))
                req.destination = MKMapItem(placemark: MKPlacemark(coordinate: dest))
                req.transportType = transport.mk
                req.departureDate = Date()
                MKDirections(request: req).calculateETA { resp, _ in
                    DispatchQueue.main.async {
                        self.computing = nil
                        guard let travel = resp?.expectedTravelTime else { return }
                        self.eta = (event.id, transport, travel, Date(), dest)
                        self.evaluate(event, travel: travel, dest: dest)
                    }
                }
            }
        }
    }

    private func destination(for event: CalendarEvent, _ done: @escaping (CLLocationCoordinate2D?) -> Void) {
        if let c = event.coordinate { return done(c) }
        guard let address = event.physicalLocation else { return done(nil) }
        if let cached = geoCache[address] { return done(cached) }
        geocoder.geocodeAddressString(address) { [weak self] marks, _ in
            DispatchQueue.main.async {
                let c = marks?.first?.location?.coordinate
                self?.geoCache[address] = c
                done(c)
            }
        }
    }

    // MARK: Presentation

    /// Same gating as the meeting alert (`calendar.upcoming`): never over the open notch, a HUD or
    /// the meeting alert; retried every 3 s while the alert is still valid (the heads-up until leave
    /// time, "Leave now" until the event starts). The heads-up respects `quietMode`; "Leave now" doesn't.
    private func evaluate(_ event: CalendarEvent, travel: TimeInterval, dest: CLLocationCoordinate2D) {
        retryWork?.cancel()
        retryWork = nil
        let leaveAt = event.start.addingTimeInterval(-travel - Double(settings.leaveBufferMinutes) * 60)
        let now = Date()
        let untilLeave = leaveAt.timeIntervalSince(now)
        guard now < event.start else { return }
        let soonKey = event.id + "|soon", nowKey = event.id + "|now"
        let key: String
        if untilLeave <= 0 {
            guard fired[nowKey] == nil else { return }
            key = nowKey
        } else if untilLeave <= Self.headsUp {
            guard fired[soonKey] == nil else { return }
            // Quiet: skip the heads-up; the minute tick re-checks once quiet ends.
            if model.quietMode { return }
            key = soonKey
        } else { return }
        if model.isExpanded || model.activity.map({ $0.key.hasPrefix("hud.") || $0.key == CalendarService.activityKey }) == true {
            let work = DispatchWorkItem { [weak self] in self?.evaluate(event, travel: travel, dest: dest) }
            retryWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
            return
        }
        fired[soonKey] = event.start
        if key == nowKey { fired[nowKey] = event.start }
        let maps = Self.mapsURL(for: event, dest: dest, transport: settings.transport)
        model.present(makeActivity(event, leaveAt: leaveAt, travel: travel, maps: maps), duration: 10)
    }

    /// Apple Maps directions to the event (address text if it has one, else the coordinate).
    static func mapsURL(for event: CalendarEvent, dest: CLLocationCoordinate2D,
                        transport: CalendarSettings.Transport) -> URL? {
        var c = URLComponents()
        c.scheme = "maps"
        c.host = ""
        let address = event.coordinate == nil ? event.physicalLocation?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let daddr = (address?.isEmpty == false) ? address! : "\(dest.latitude),\(dest.longitude)"
        let flag: String
        switch transport {
        case .driving: flag = "d"
        case .walking: flag = "w"
        case .transit: flag = "r"
        }
        c.queryItems = [URLQueryItem(name: "daddr", value: daddr), URLQueryItem(name: "dirflg", value: flag)]
        return c.url
    }

    private func openMaps(_ url: URL) {
        NSWorkspace.shared.open(url)
        model.dismissActivity(key: Self.activityKey)
    }

    private func makeActivity(_ event: CalendarEvent, leaveAt: Date, travel: TimeInterval, maps: URL?) -> LiveActivity {
        let transport = settings.transport
        let activity = LiveActivity(key: Self.activityKey, extraWidth: 130) {
            Image(systemName: transport.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(event.tint)
        } trailing: {
            LeaveCountdown(leaveAt: leaveAt)
        }
        .withBelow(height: 30) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(event.tint).frame(width: 3, height: 16)
                Text(event.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 6)
                Text("\(Int((travel / 60).rounded(.up))) min \(transport.verb)")
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.55))
                if let maps {
                    Button { [weak self] in self?.openMaps(maps) } label: {
                        Label("Maps", systemImage: "map.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(.white.opacity(0.18)))
                    }
                    .buttonStyle(.plain)
                    .help("Directions in Maps")
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
        }
        return maps == nil ? activity : activity.interactive()
    }
}

/// "Leave in 12m" / "Leave now".
private struct LeaveCountdown: View {
    let leaveAt: Date

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            let mins = Int((leaveAt.timeIntervalSince(ctx.date) / 60).rounded(.up))
            Text(mins <= 0 ? "Leave now" : "Leave in \(mins)m")
                .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                .foregroundStyle(mins <= 0 ? Color.orange : .white)
                .lineLimit(1)
        }
    }
}
