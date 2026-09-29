import AppKit
import Combine

/// Optional chime on the hour (off by default). A single one-shot timer armed for the next hour
/// while enabled; nothing runs when off.
final class HourlyChime {
    static let shared = HourlyChime()
    private var timer: Timer?
    private var cancellable: AnyCancellable?

    private init() {
        cancellable = CalendarSettings.shared.$hourlyChime
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] on in on ? self?.arm() : self?.disarm() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            if CalendarSettings.shared.hourlyChime { self?.arm() } // re-align after sleep
        }
    }

    private func arm() {
        timer?.invalidate()
        let now = Date()
        guard let next = Calendar.current.dateInterval(of: .hour, for: now)?.end else { return }
        let t = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            // Skip if we woke late (don't chime at 10:37 for 10:00).
            if abs(Date().timeIntervalSince(next)) < 30 { NSSound(named: "Tink")?.play() }
            self?.arm()
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func disarm() {
        timer?.invalidate()
        timer = nil
    }
}
