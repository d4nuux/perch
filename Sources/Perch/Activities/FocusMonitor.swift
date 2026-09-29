import Foundation

/// Focus (Do Not Disturb) on / off, with the mode's name and symbol when available.
///
/// Sources, all event-driven:
/// - `_NSDoNotDisturbEnabledNotification` / `…DisabledNotification` distributed notifications
///   (no entitlement or TCC needed; carry no mode info).
/// - `~/Library/DoNotDisturb/DB/{Assertions,ModeConfigurations}.json`, watched with a vnode
///   DispatchSource. These are TCC-protected: readable only when Perch has Full Disk Access.
///   Without it we report a generic "Focus On / Off".
/// (DNDStateService / FCActivityManager and INFocusStatusCenter need entitlements we can't sign with.)
final class FocusMonitor {
    struct Mode: Equatable {
        let id: String
        let name: String
        let symbol: String
    }

    enum Event {
        case changed(on: Bool, mode: Mode?)
    }

    var onEvent: ((Event) -> Void)?

    static let dbURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/DoNotDisturb/DB", isDirectory: true)
    private var dirSource: DispatchSourceFileSystemObject?
    private var reloadWork: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []

    private struct State: Equatable {
        var on: Bool
        var mode: Mode?
        /// Came from the assertion file (authoritative for "off" too).
        var fromFile: Bool
    }
    private var state: State?

    /// True when the DB is readable (Full Disk Access granted).
    private(set) var hasDetails = false

    func start() {
        guard observers.isEmpty else { return }
        let dnc = DistributedNotificationCenter.default()
        observers.append(dnc.addObserver(forName: .init("_NSDoNotDisturbEnabledNotification"),
                                         object: nil, queue: .main) { [weak self] _ in self?.systemNotified(on: true) })
        observers.append(dnc.addObserver(forName: .init("_NSDoNotDisturbDisabledNotification"),
                                         object: nil, queue: .main) { [weak self] _ in self?.systemNotified(on: false) })
        watchDirectory()
        // Baseline, silently.
        if let m = Self.readActiveMode() {
            hasDetails = true
            state = State(on: m.active != nil, mode: m.active, fromFile: true)
        }
    }

    deinit {
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        dirSource?.cancel()
    }

    // MARK: Sources

    private func systemNotified(on: Bool) {
        // The DB write can land just after the notification; give it a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            if let file = Self.readActiveMode() {
                self.hasDetails = true
                if on, let m = file.active {
                    self.apply(State(on: true, mode: m, fromFile: true))
                    return
                }
                if !on, file.active == nil {
                    self.apply(State(on: false, mode: self.state?.mode, fromFile: true))
                    return
                }
            }
            // No details (or a scheduled Focus with no assertion record).
            self.apply(State(on: on, mode: on ? nil : self.state?.mode, fromFile: false))
        }
    }

    private func watchDirectory() {
        let fd = open(Self.dbURL.path, O_EVTONLY)
        guard fd >= 0 else { return } // EPERM without Full Disk Access
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                            eventMask: [.write, .rename, .delete, .link],
                                                            queue: .main)
        src.setEventHandler { [weak self] in self?.scheduleReload() }
        src.setCancelHandler { close(fd) }
        src.resume()
        dirSource = src
    }

    private func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reloadFromFile() }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func reloadFromFile() {
        guard let file = Self.readActiveMode() else { return }
        hasDetails = true
        if let m = file.active {
            apply(State(on: true, mode: m, fromFile: true))
        } else if state?.fromFile == true, state?.on == true {
            // Only an assertion we saw in the file can be ended by the file; a scheduled Focus
            // (on via notification, no record) must be ended by the notification.
            apply(State(on: false, mode: state?.mode, fromFile: true))
        }
    }

    private func apply(_ new: State) {
        let old = state
        state = new
        guard let old else {
            onEvent?(.changed(on: new.on, mode: new.mode))
            return
        }
        if old.on != new.on || (new.on && old.mode?.id != new.mode?.id && new.mode != nil) {
            onEvent?(.changed(on: new.on, mode: new.mode))
        }
    }

    // MARK: DB parsing

    /// nil when the DB can't be read. `active` is nil when no Focus assertion is active.
    struct FileState { let active: Mode? }

    static func readActiveMode(in dir: URL = dbURL) -> FileState? {
        guard let aData = try? Data(contentsOf: dir.appendingPathComponent("Assertions.json")),
              let assertions = try? JSONSerialization.jsonObject(with: aData) else { return nil }
        var ids: [String] = []
        collectAssertionModeIDs(assertions, into: &ids)
        guard let id = ids.last else { return FileState(active: nil) }
        let configs = (try? Data(contentsOf: dir.appendingPathComponent("ModeConfigurations.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) }
        var found: [String: Any]?
        if let configs { found = findMode(id, in: configs) }
        let name = (found?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? defaultName(id)
        let symbol = (found?["symbolImageName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? defaultSymbol(id)
        return FileState(active: Mode(id: id, name: name, symbol: symbol))
    }

    /// Mode identifiers of the records under every `storeAssertionRecords` array.
    private static func collectAssertionModeIDs(_ obj: Any, into ids: inout [String]) {
        if let dict = obj as? [String: Any] {
            for (k, v) in dict {
                if k == "storeAssertionRecords", let records = v as? [[String: Any]] {
                    for r in records {
                        let details = r["assertionDetails"] as? [String: Any]
                        if let id = details?["assertionDetailsModeIdentifier"] as? String { ids.append(id) }
                    }
                } else {
                    collectAssertionModeIDs(v, into: &ids)
                }
            }
        } else if let arr = obj as? [Any] {
            arr.forEach { collectAssertionModeIDs($0, into: &ids) }
        }
    }

    /// The `mode` dictionary whose `modeIdentifier` is `id`.
    private static func findMode(_ id: String, in obj: Any) -> [String: Any]? {
        if let dict = obj as? [String: Any] {
            if dict["modeIdentifier"] as? String == id, dict["name"] != nil || dict["symbolImageName"] != nil {
                return dict
            }
            for v in dict.values { if let m = findMode(id, in: v) { return m } }
        } else if let arr = obj as? [Any] {
            for v in arr { if let m = findMode(id, in: v) { return m } }
        }
        return nil
    }

    static func defaultSymbol(_ id: String) -> String {
        let table: [(String, String)] = [
            ("mode.default", "moon.fill"), ("sleep", "bed.double.fill"), ("bedtime", "bed.double.fill"),
            ("work", "briefcase.fill"), ("personal", "person.fill"), ("driving", "car.fill"),
            ("reduceInterruptions", "sparkles"), ("gaming", "gamecontroller.fill"),
            ("mindfulness", "brain.head.profile"), ("reading", "book.fill"), ("fitness", "figure.run"),
            ("workout", "figure.run"),
        ]
        return table.first { id.hasSuffix($0.0) || id.contains(".\($0.0)") }?.1 ?? "moon.fill"
    }

    static func defaultName(_ id: String) -> String {
        if id.hasSuffix("mode.default") { return "Do Not Disturb" }
        if id.contains("sleep") || id.hasSuffix("bedtime") { return "Sleep" }
        if id.hasSuffix("reduceInterruptions") { return "Reduce Interruptions" }
        let last = id.split(separator: ".").last.map(String.init) ?? "Focus"
        return last.prefix(1).uppercased() + last.dropFirst()
    }
}
