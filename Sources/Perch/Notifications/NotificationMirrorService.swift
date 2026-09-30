import AppKit
import Combine
import OSLog
import SwiftUI

/// Mirrors delivered macOS notifications (email first) into the notch. (Owned by the Notifications agent.)
///
/// Pipeline: usernoted SQLite DB (read-only, needs Full Disk Access) → vnode watcher on db/db-wal
/// (debounced 300ms) → query rows newer than the last seen rec_id → decode plist + classify on a
/// utility queue → filter / present on main. No polling apart from the watcher's 3-minute safety check.
final class NotificationMirrorService {
    private static let log = Logger(subsystem: "Perch", category: "Notifications")
    /// Arrivals closer together than this collapse into one "3 new emails" summary.
    static let burstWindow: TimeInterval = 2
    /// Items older than this (at delivery) are never shown.
    private static let staleAfter: TimeInterval = 120
    /// Queued items (notch open, HUD showing) older than this are dropped instead of shown.
    private static let pendingTTL: TimeInterval = 30

    private let context: NotchContext
    private let settings = NotificationSettings.shared
    private let history = NotificationHistory.shared
    private let ui = NotificationUIState.shared
    private var cancellables: Set<AnyCancellable> = []
    private var model: NotchModel { context.model }

    // Queue-confined state.
    private let queue = DispatchQueue(label: "perch.notifications", qos: .utility)
    private var db: NotificationDB?
    private var dbInode: ino_t?
    private var watcher: NotificationWatcher?
    private var lastSeen: Int64 = 0
    private var seen: [Int64: Date] = [:]
    private var startDate = Date()

    // Main-thread state.
    private var running = false
    private var shown: NotificationPresentation?
    private var lastArrival: Date?
    private var expanded = false
    private var hoverWork: DispatchWorkItem?
    private var pending: [NotificationItem] = [] // newest first

    init(context: NotchContext) {
        self.context = context
        settings.$enabled.removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.evaluate() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .notchPermissionsChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.evaluate() }
            .store(in: &cancellables)
        // Queued items go out once the notch is closed and free.
        Publishers.Merge(model.$activity.map { $0 == nil }.filter { $0 }.map { _ in () },
                         model.$isExpanded.filter { !$0 }.map { _ in () })
            .sink { [weak self] in DispatchQueue.main.async { self?.flush() } }
            .store(in: &cancellables)
    }

    // MARK: Lifecycle

    /// While enabled but lacking Full Disk Access, re-check every few seconds so a grant in
    /// System Settings takes effect without relaunching (TCC sends no notification).
    private var accessRetry: Timer?

    private func evaluate() {
        let access = NotificationDBLocation.hasFullDiskAccess
        let wanted = settings.enabled && access
        if settings.enabled && !access {
            if accessRetry == nil {
                Self.log.info("enabled, waiting for Full Disk Access")
                accessRetry = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.evaluate() }
            }
        } else if let t = accessRetry {
            t.invalidate(); accessRetry = nil
            if access { NotificationCenter.default.post(name: .notchPermissionsChanged, object: nil) }
        }
        guard wanted != running else { return }
        running = wanted
        if wanted {
            queue.async { [weak self] in self?.start() }
        } else {
            queue.async { [weak self] in self?.stop() }
            pending = []
        }
    }

    private func start() {
        guard db == nil else { return }
        guard let url = NotificationDBLocation.resolve() else {
            Self.log.error("usernoted database not found (or not readable)")
            return
        }
        guard openDB(url) else { return }
        lastSeen = db?.maxID() ?? 0 // never replay what's already there
        seen = [:]
        startDate = Date()
        let w = NotificationWatcher(dbURL: url, queue: queue) { [weak self] in self?.poll() }
        w.start()
        watcher = w
        Self.log.info("watching notifications (last id \(self.lastSeen))")
    }

    private func stop() {
        watcher?.stop()
        watcher = nil
        db?.close()
        db = nil
    }

    private func openDB(_ url: URL) -> Bool {
        db?.close()
        db = NotificationDB(url: url)
        var st = stat()
        dbInode = stat(url.path, &st) == 0 ? st.st_ino : nil
        return db != nil
    }

    // MARK: Reading (queue)

    private func poll() {
        guard let current = db else { return }
        // DB file replaced underneath us: reopen (keeps lastSeen; ids stay monotonic in practice).
        var st = stat()
        if stat(current.url.path, &st) == 0, st.st_ino != dbInode {
            guard openDB(current.url) else { return }
        }
        guard let db else { return }
        let now = Date()
        let floor = startDate.addingTimeInterval(-2)
        // Look a few ids back: SQLite reuses the top rowid when the newest record was deleted.
        let records = db.records(after: max(0, lastSeen - 16)) { [seen] id, date in
            seen[id] == date || date < floor || now.timeIntervalSince(date) > Self.staleAfter
        }
        guard !records.isEmpty else { return }
        Self.log.info("db change: \(records.count) new record(s)")
        for r in records {
            seen[r.recID] = r.delivered
            lastSeen = max(lastSeen, r.recID)
        }
        seen = seen.filter { $0.key > lastSeen - 64 }
        let items = records.map { NotificationItem(record: $0, detectCodes: true) }
        DispatchQueue.main.async { [weak self] in self?.receive(items) }
    }

    // MARK: Filtering & presenting (main)

    private func allow(_ item: NotificationItem) -> Bool {
        switch settings.filter {
        case .email:
            return item.kind == .email
        case .chosen:
            var id = item.bundleID
            if id.hasPrefix("com.google.chrome.framework") { id = "com.google.chrome" }
            guard settings.isChosen(id) else { return false }
            if AppCatalog.isBrowser(id), settings.browsersWebmailOnly { return item.kind == .email }
            return true
        }
    }

    private func receive(_ items: [NotificationItem]) {
        guard running else { return }
        for i in items {
            Self.log.info("notification from \(i.bundleID, privacy: .public) kind=\(String(describing: i.kind), privacy: .public) allowed=\(self.allow(i)) quiet=\(self.model.quietMode) blocked=\(self.blocked)")
        }
        let allowed = items.filter(allow).map { settings.detectCodes ? $0 : $0.withoutCode() }
        guard !allowed.isEmpty else { return }
        history.add(allowed)
        guard !model.quietMode else { return }
        let newest = Array(allowed.reversed())
        if blocked {
            pending = Array((newest + pending).prefix(20))
            return
        }
        present(newest, mergeable: true)
    }

    /// The notch is open, or a HUD is showing: queue until it's free.
    private var blocked: Bool {
        model.isExpanded || (model.activity?.key.hasPrefix("hud.") ?? false)
    }

    private func flush() {
        guard running, !pending.isEmpty, !blocked, !model.quietMode else { return }
        let fresh = pending.filter { Date().timeIntervalSince($0.date) < Self.pendingTTL }
        pending = []
        guard !fresh.isEmpty else { return }
        present(fresh, mergeable: false)
    }

    private var redact: Bool { model.isLocked && !settings.previewsWhenLocked }

    private func present(_ newest: [NotificationItem], mergeable: Bool) {
        let now = Date()
        var items = newest
        if mergeable, let s = shown, model.activity?.key == s.key, let last = lastArrival,
           now.timeIntervalSince(last) < Self.burstWindow {
            items += s.items
        }
        lastArrival = now
        let p: NotificationPresentation = items.count == 1
            ? .single(items[0]) : .burst(key: "notif.burst.\(items.last!.id)", items: items)
        let old = shown?.key
        shown = p
        expanded = false
        hoverWork?.cancel()
        model.present(build(p), duration: settings.duration)
        // The previous one would otherwise be restored (interactive activities get suspended) or
        // linger as a duplicate page dot next to its own burst.
        if let old, old != p.key { model.dismissActivity(key: old) }
        if settings.sound { NSSound(named: "Tink")?.play() }
    }

    private func build(_ p: NotificationPresentation) -> LiveActivity {
        NotificationViews.activity(p, expanded: expanded, locked: model.isLocked, redact: redact, actions: actions)
    }

    private var actions: NotificationActions {
        NotificationActions(
            open: { $0.open() },
            copy: { [weak self] in self?.copy($0) },
            dismiss: { [weak self] in self?.dismiss($0) },
            hover: { [weak self] in self?.hover($0, $1) })
    }

    private func dismiss(_ key: String) {
        hoverWork?.cancel()
        if shown?.key == key { shown = nil; expanded = false }
        model.dismissActivity(key: key)
    }

    private func copy(_ item: NotificationItem) {
        guard let code = item.code, !redact else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(code, forType: .string)
        ui.copied.insert(item.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.ui.copied.remove(item.id) }
    }

    /// Hover holds the activity and expands it (3-line body + actions); leaving shrinks it back
    /// and lets it expire shortly after. Exits are debounced: moving between slots isn't a leave.
    private func hover(_ key: String, _ inside: Bool) {
        guard let p = shown, p.key == key, model.activity?.key == key else { return }
        hoverWork?.cancel()
        if inside {
            guard !expanded else { return }
            expanded = true
            withAnimation(NotchModel.openAnimation) { model.present(build(p), duration: nil) }
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.expanded, self.shown?.key == key, self.model.activity?.key == key else { return }
                self.expanded = false
                withAnimation(NotchModel.closeAnimation) { self.model.present(self.build(p), duration: 2.5) }
            }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }
}

extension NotificationItem {
    func withoutCode() -> NotificationItem {
        NotificationItem(id: id, app: app, kind: kind, date: date, primary: primary, secondary: secondary,
                         text: text, host: host, code: nil)
    }
}
