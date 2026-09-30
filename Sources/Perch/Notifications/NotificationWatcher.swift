import Foundation

/// Event-driven watch on the usernoted DB: vnode sources on `db`, `db-wal` and their directory,
/// debounced. usernoted writes new rows to the WAL (and to `db` on checkpoint), so a write/extend
/// on either means "maybe something new". Delete/rename (file replaced, WAL reset) re-arms.
///
/// The only timer is a slow safety check (every ~3 min, generous leeway) that re-arms if a
/// watched file's inode changed without us seeing an event.
final class NotificationWatcher {
    private let dir: URL
    private let names: [String]
    private let queue: DispatchQueue
    private let debounce: TimeInterval
    private let onChange: () -> Void

    private struct Watch {
        let source: DispatchSourceFileSystemObject
        let inode: ino_t
    }

    private var watches: [String: Watch] = [:]
    private var dirSource: DispatchSourceFileSystemObject?
    private var safety: DispatchSourceTimer?
    private var pending: DispatchWorkItem?
    private var running = false

    /// All callbacks (including `onChange`) run on `queue`.
    init(dbURL: URL, queue: DispatchQueue, debounce: TimeInterval = 0.3, onChange: @escaping () -> Void) {
        dir = dbURL.deletingLastPathComponent()
        names = [dbURL.lastPathComponent, dbURL.lastPathComponent + "-wal"]
        self.queue = queue
        self.debounce = debounce
        self.onChange = onChange
    }

    deinit {
        // Sources must be resumed when cancelled; stop() leaves them that way.
        for w in watches.values { w.source.cancel() }
        dirSource?.cancel()
        safety?.cancel()
    }

    /// Call on `queue`.
    func start() {
        guard !running else { return }
        running = true
        armDirectory()
        armFiles()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 180, repeating: 180, leeway: .seconds(60))
        t.setEventHandler { [weak self] in self?.safetyCheck() }
        t.resume()
        safety = t
    }

    /// Call on `queue`.
    func stop() {
        guard running else { return }
        running = false
        pending?.cancel()
        pending = nil
        for w in watches.values { w.source.cancel() }
        watches = [:]
        dirSource?.cancel()
        dirSource = nil
        safety?.cancel()
        safety = nil
    }

    private static func inode(_ path: String) -> ino_t? {
        var st = stat()
        return stat(path, &st) == 0 ? st.st_ino : nil
    }

    private func armDirectory() {
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename],
                                                            queue: queue)
        src.setEventHandler { [weak self] in
            // An entry was created/removed/renamed (WAL recreated, DB replaced): re-arm and look.
            self?.armFiles()
            self?.schedule()
        }
        src.setCancelHandler { Darwin.close(fd) }
        src.resume()
        dirSource = src
    }

    /// Arms a source for every watched file that exists and isn't already watched at its current inode.
    private func armFiles() {
        guard running else { return }
        for name in names {
            let path = dir.appendingPathComponent(name).path
            let ino = Self.inode(path)
            if let w = watches[name], w.inode == ino { continue }
            watches[name]?.source.cancel()
            watches[name] = nil
            guard let ino else { continue }
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .revoke], queue: queue)
            src.setEventHandler { [weak self, weak src] in
                guard let self, let src else { return }
                let ev = src.data
                if !ev.isDisjoint(with: [.delete, .rename, .revoke]) {
                    src.cancel()
                    self.watches[name] = nil
                    // Give the writer a moment to put the replacement in place.
                    self.queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.armFiles() }
                }
                self.schedule()
            }
            src.setCancelHandler { Darwin.close(fd) }
            src.resume()
            watches[name] = Watch(source: src, inode: ino)
        }
    }

    private func schedule() {
        guard running else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            self.onChange()
        }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    private func safetyCheck() {
        guard running else { return }
        if dirSource == nil { armDirectory() }
        let before = watches.mapValues(\.inode)
        armFiles()
        if watches.mapValues(\.inode) != before { schedule() }
    }
}
