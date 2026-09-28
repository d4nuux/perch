import AppKit

/// What's playing, system-wide. Primary source is MediaRemote (any app, incl. browsers) through
/// `MediaRemoteSource`; if that can't run, falls back to polling Spotify / Music over AppleScript.
/// AppleScript runs on a background queue so a permission prompt never freezes the UI.
final class NowPlaying: ObservableObject {
    struct Player { let name: String; let bundleID: String }
    static let players = [
        Player(name: "Spotify", bundleID: "com.spotify.client"),
        Player(name: "Music", bundleID: "com.apple.Music"),
    ]

    @Published var title = ""
    @Published var artist = ""
    @Published var isPlaying = false
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var appIcon: NSImage?
    @Published var artwork: NSImage?
    private var active: Player?
    private var artworkKey = ""
    private var timer: Timer?
    private let queue = DispatchQueue(label: "notchapp.nowplaying")
    /// Main thread only. A hung player / pending Automation prompt blocks the queue; don't pile
    /// up one query per second behind it.
    private var refreshing = false

    private let remote = MediaRemoteSource()
    private var useRemote = true
    private var remoteState = MediaRemoteSource.State()

    init() {
        remote.onUpdate = { [weak self] state in self?.applyRemote(state) }
        remote.onUnavailable = { [weak self] in self?.startAppleScriptFallback() }
        remote.start()
        // Also ticks the progress position while MediaRemote is the source.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.useRemote { self.tickRemote() } else { self.refresh() }
        }
    }

    private func startAppleScriptFallback() {
        guard useRemote else { return }
        useRemote = false
        refresh()
    }

    private func applyRemote(_ s: MediaRemoteSource.State) {
        remoteState = s
        if let art = s.artwork { artwork = art }
        title = s.title
        artist = s.artist
        isPlaying = s.isPlaying && !s.title.isEmpty
        duration = s.duration
        tickRemote()
        if s.bundleID.isEmpty {
            appIcon = nil
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: s.bundleID) {
            appIcon = NSWorkspace.shared.icon(forFile: url.path)
        }
    }

    private func tickRemote() {
        let s = remoteState
        var p = s.elapsed
        if s.isPlaying { p += Date().timeIntervalSince(s.timestamp) * (s.rate > 0 ? s.rate : 1) }
        if s.duration > 0 { p = min(p, s.duration) }
        position = max(p, 0)
    }

    /// Jump to `seconds` in the current track (MediaRemote only).
    func seek(to seconds: Double) {
        guard useRemote else { return }
        remote.send("seek \(seconds)")
        remoteState.elapsed = seconds
        remoteState.timestamp = Date()
        position = seconds
    }

    var hasTrack: Bool { !title.isEmpty }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        queue.async { [weak self] in
            guard let self else { return }
            var result: (Player, [String])?
            for p in Self.players where running.contains(p.bundleID) {
                guard let parts = Self.query(p) else { continue }
                if parts[0] == "playing" { result = (p, parts); break }
                if result == nil { result = (p, parts) }
            }
            var art: NSImage??
            if let (p, parts) = result, "\(p.name)|\(parts[1])|\(parts[2])" != self.artworkKey {
                self.artworkKey = "\(p.name)|\(parts[1])|\(parts[2])"
                art = .some(Self.fetchArtwork(p))
            } else if result == nil {
                self.artworkKey = ""
                art = .some(nil)
            }
            DispatchQueue.main.async {
                self.refreshing = false
                if let art { self.artwork = art }
                if let (p, parts) = result { self.apply(p, parts) } else { self.clear() }
            }
        }
    }

    private static func run(_ source: String) -> NSAppleEventDescriptor? {
        var err: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&err)
    }

    private static func query(_ p: Player) -> [String]? {
        let durationExpr = p.name == "Spotify" ? "(duration of current track) / 1000" : "duration of current track"
        let src = """
        tell application "\(p.name)"
            if player state is stopped then return "stopped"
            return (player state as string) & "|§|" & (name of current track) & "|§|" & (artist of current track) & "|§|" & (player position as string) & "|§|" & ((\(durationExpr)) as string)
        end tell
        """
        guard let out = run(src)?.stringValue else { return nil }
        let parts = out.components(separatedBy: "|§|")
        return parts.count == 5 ? parts : nil
    }

    private static func fetchArtwork(_ p: Player) -> NSImage? {
        if p.name == "Spotify" {
            guard let s = run("tell application \"Spotify\" to artwork url of current track")?.stringValue,
                  let url = URL(string: s), let data = try? Data(contentsOf: url) else { return nil }
            return NSImage(data: data)
        }
        guard let d = run("tell application \"Music\" to get raw data of artwork 1 of current track")?.data else { return nil }
        return NSImage(data: d)
    }

    private func apply(_ p: Player, _ parts: [String]) {
        active = p
        isPlaying = parts[0] == "playing"
        title = parts[1]
        artist = parts[2]
        position = Double(parts[3].replacingOccurrences(of: ",", with: ".")) ?? 0
        duration = Double(parts[4].replacingOccurrences(of: ",", with: ".")) ?? 0
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: p.bundleID) {
            appIcon = NSWorkspace.shared.icon(forFile: url.path)
        }
    }

    private func clear() {
        active = nil; isPlaying = false; title = ""; artist = ""; position = 0; duration = 0; appIcon = nil
    }

    /// `command` is one of "playpause", "next track", "previous track".
    func send(_ command: String) {
        if useRemote {
            switch command {
            case "playpause": remote.send("toggle")
            case "next track": remote.send("next")
            case "previous track": remote.send("previous")
            default: break
            }
            return
        }
        guard let p = active else { return }
        queue.async { [weak self] in
            _ = Self.run("tell application \"\(p.name)\" to \(command)")
            DispatchQueue.main.async { self?.refresh() }
        }
    }
}
