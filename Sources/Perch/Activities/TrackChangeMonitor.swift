import Combine
import Foundation

/// Fires when NowPlaying's (title, artist) changes to a new non-empty track.
/// The value(s) seen during the first seconds after launch only establish the baseline.
final class TrackChangeMonitor {
    private var cancellable: AnyCancellable?
    private let startedAt = Date()
    private static let launchGrace: TimeInterval = 3

    init(nowPlaying: NowPlaying, onChange: @escaping () -> Void) {
        cancellable = nowPlaying.$title
            .combineLatest(nowPlaying.$artist)
            .map { "\($0)\u{1F}\($1)" }
            // NowPlaying assigns title and artist back to back (and re-assigns every second);
            // debounce collapses the pair, removeDuplicates drops the no-op refreshes.
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .removeDuplicates()
            .dropFirst()
            .sink { [startedAt] key in
                guard Date().timeIntervalSince(startedAt) > Self.launchGrace,
                      !key.hasPrefix("\u{1F}") else { return } // empty title
                onChange()
            }
    }
}
