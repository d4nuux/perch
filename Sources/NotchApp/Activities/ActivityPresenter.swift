import Combine
import Foundation

/// Gatekeeper between the activity sources and `NotchModel.present`.
///
/// Rules:
/// - Never present while the notch is expanded (dropped).
/// - Never replace a foreign activity (`hud.*`, `calendar.*`, …) while it is showing; instead
///   keep the single best pending activity and show it when the notch frees up, unless it
///   has gone stale by then.
/// - Among our own activities, a lower rank never replaces a higher one that is showing.
final class ActivityPresenter {
    enum Rank: Int, Comparable {
        case track = 0, bluetooth, power, lowBattery
        static func < (a: Rank, b: Rank) -> Bool { a.rawValue < b.rawValue }
    }

    static let keyPrefix = "activity."
    /// How long a queued activity may wait before it is considered stale and dropped.
    private static let queueTTL: TimeInterval = 5

    private struct Pending {
        let activity: LiveActivity
        let rank: Rank
        let duration: TimeInterval
        let expires: Date
    }

    private let model: NotchModel
    private var pending: Pending?
    private var shownRank: Rank?
    private var cancellables: Set<AnyCancellable> = []

    init(model: NotchModel) {
        self.model = model
        // @Published fires in willSet; hop once so `model.activity` reflects the new value.
        model.$activity
            .map { $0 == nil }
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in DispatchQueue.main.async { self?.flush() } }
            .store(in: &cancellables)
        model.$isExpanded
            .removeDuplicates()
            .filter { !$0 }
            .sink { [weak self] _ in DispatchQueue.main.async { self?.flush() } }
            .store(in: &cancellables)
    }

    /// Presents `activity` (key must start with `activity.`) subject to the rules above.
    func present(_ activity: LiveActivity, rank: Rank, duration: TimeInterval, queueable: Bool = true) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.present(activity, rank: rank, duration: duration, queueable: queueable) }
            return
        }
        if model.isExpanded { return }
        if canShow(rank: rank) {
            show(activity, rank: rank, duration: duration)
        } else if queueable {
            enqueue(Pending(activity: activity, rank: rank, duration: duration,
                            expires: Date().addingTimeInterval(Self.queueTTL)))
        }
    }

    /// Replaces the activity in place only if one with the same key is currently showing.
    func update(_ activity: LiveActivity, duration: TimeInterval) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.update(activity, duration: duration) }
            return
        }
        guard model.activity?.key == activity.key, !model.isExpanded else { return }
        model.present(activity, duration: duration)
    }

    private func canShow(rank: Rank) -> Bool {
        guard let current = model.activity else { return true }
        guard current.key.hasPrefix(Self.keyPrefix) else { return false } // HUD or another module
        return rank >= (shownRank ?? .track)
    }

    private func show(_ activity: LiveActivity, rank: Rank, duration: TimeInterval) {
        shownRank = rank
        model.present(activity, duration: duration)
    }

    private func enqueue(_ p: Pending) {
        if let cur = pending, cur.expires > Date(), cur.rank > p.rank { return }
        pending = p
    }

    private func flush() {
        guard model.activity == nil else { return }
        shownRank = nil
        guard let p = pending else { return }
        guard p.expires > Date() else { pending = nil; return }
        guard !model.isExpanded else { return }
        pending = nil
        show(p.activity, rank: p.rank, duration: p.duration)
    }
}
