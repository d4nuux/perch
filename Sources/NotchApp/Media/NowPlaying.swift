import AppKit
import Combine

/// Playback position, split out of `NowPlaying` so the 1 s tick only re-renders views that show
/// progress (they observe `nowPlaying.clock`), not everything observing `NowPlaying`.
final class PlaybackClock: ObservableObject {
    @Published fileprivate(set) var position: Double = 0
}

/// What's playing, system-wide. Source is picked in MediaSettings: Automatic uses MediaRemote (any
/// app, incl. browsers) through `MediaRemoteSource`, falling back to Spotify / Music over AppleScript
/// if the helper can't run; "Music only" / "Spotify only" use AppleScript for that app.
/// AppleScript runs on a background queue so a permission prompt never freezes the UI.
final class NowPlaying: ObservableObject {
    struct Player { let name: String; let bundleID: String }
    static let spotify = Player(name: "Spotify", bundleID: "com.spotify.client")
    static let music = Player(name: "Music", bundleID: "com.apple.Music")
    static let players = [spotify, music]

    enum ShuffleState { case unknown, off, on }
    enum RepeatState { case unknown, off, one, all }

    /// Display title (cleaned up when that setting is on). `rawTitle` is what the source reported.
    @Published var title = ""
    @Published private(set) var rawTitle = ""
    @Published var artist = ""
    @Published private(set) var album = ""
    @Published var isPlaying = false { didSet { if isPlaying != oldValue { updateTicker() } } }
    /// Ticks every second while playing. Observe this (or `$position` on it) to show progress.
    let clock = PlaybackClock()
    /// Current position; not published (see `clock`).
    var position: Double { clock.position }
    @Published var duration: Double = 0
    @Published var appIcon: NSImage?
    @Published var artwork: NSImage? { didSet { if artwork !== oldValue { updateAccent() } } }
    /// Bundle id of the app that's playing (for browsers, the browser itself). Empty if none.
    @Published private(set) var sourceBundleID = ""
    /// Tint derived from the artwork; nil when there's no artwork, it's monochrome, or the
    /// "artwork color" setting is off.
    @Published private(set) var accentColor: NSColor?
    /// Dark top/bottom colors for the "gradient" artwork style; nil otherwise or without artwork.
    @Published private(set) var backdropColors: [NSColor]?
    /// Current track is explicit (badge setting on and known). False while unknown.
    @Published private(set) var isExplicit = false
    /// Bumped when one track replaces another (not on first load, not when the same track re-emits).
    @Published private(set) var trackChanges = 0
    /// The app that's playing is the frontmost app.
    @Published private(set) var sourceIsFrontmost = false
    /// "Hide while source app is frontmost" is on and it is: collapsed live activity should hide.
    @Published private(set) var hidesCollapsedActivity = false
    @Published private(set) var shuffle: ShuffleState = .unknown
    @Published private(set) var repeatMode: RepeatState = .unknown
    @Published private(set) var isLiked: Bool?
    /// Enabled MediaRemote command ids for the current source (empty when unknown / AppleScript).
    @Published private(set) var supportedCommands: Set<Int> = []

    var hasTrack: Bool { !title.isEmpty }
    /// Collapsed live activity should show (playing and not hidden by the frontmost-app setting).
    var showsCollapsedActivity: Bool { isPlaying && !hidesCollapsedActivity }

    private let settings = MediaSettings.shared
    private var cancellables: Set<AnyCancellable> = []
    private var active: Player?
    /// Main thread only (`refresh()` hands a copy to the background query).
    private var artworkKey = ""
    private var ticker: Timer?
    private var ticks = 0
    private let queue = DispatchQueue(label: "notchapp.nowplaying")
    /// Main thread only. A hung player / pending Automation prompt blocks the queue; don't pile
    /// up queries behind it.
    private var refreshing = false
    private var refreshAgain = false

    private let remote = MediaRemoteSource()
    private var remoteUnavailable = false
    private var useRemote = true
    /// Players polled over AppleScript when not using MediaRemote.
    private var scriptPlayers: [Player] = []
    private var remoteState = MediaRemoteSource.State()
    private var remoteArtwork: NSImage?
    /// Position anchor, extrapolated while playing.
    private var anchor = (elapsed: 0.0, at: Date(), rate: 1.0)
    /// AppleScript extras (shuffle/repeat/favorite) are read per track only after the user used one
    /// of those controls for that app in MediaRemote mode, so no Automation prompt appears unasked.
    private var scriptExtrasApproved: Set<String> = []
    private var accentWork = 0
    private let explicitLookup = ExplicitLookup()

    init() {
        remote.onUpdate = { [weak self] state in self?.applyRemote(state) }
        remote.onUnavailable = { [weak self] in
            guard let self else { return }
            self.remoteUnavailable = true
            if self.settings.source == .automatic { self.applySource() }
        }

        // Settings publish in willSet; hop to the next main-loop turn so reads see the new value.
        settings.$source.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applySource() }.store(in: &cancellables)
        settings.$ignoredSources.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.useRemote else { return }
                self.applyRemote(self.remoteState)
            }.store(in: &cancellables)
        settings.$cleanTitles.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateDisplayTitle() }.store(in: &cancellables)
        settings.$artworkColor.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateAccent() }.store(in: &cancellables)
        settings.$artworkStyle.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateAccent() }.store(in: &cancellables)
        settings.$explicitBadge.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateExplicit() }.store(in: &cancellables)
        settings.$hideWhileSourceFrontmost.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateFrontmost() }.store(in: &cancellables)

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) {
            [weak self] _ in self?.updateFrontmost()
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self, !self.useRemote,
                      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      self.scriptPlayers.contains(where: { $0.bundleID == app.bundleIdentifier }) else { return }
                self.refresh()
            }
        }
        // Spotify and Music broadcast every play/pause/track change: no need to poll them.
        let dnc = DistributedNotificationCenter.default()
        for name in ["com.spotify.client.PlaybackStateChanged", "com.apple.Music.playerInfo"] {
            dnc.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                guard let self, !self.useRemote else { return }
                self.refresh()
            }
        }

        applySource()
    }

    // MARK: Source selection

    private func applySource() {
        let wantRemote = settings.source == .automatic && !remoteUnavailable
        clear()
        remoteArtwork = nil
        artworkKey = ""
        artwork = nil
        if wantRemote {
            useRemote = true
            scriptPlayers = []
            remote.start()
        } else {
            remote.stop()
            useRemote = false
            switch settings.source {
            case .automatic: scriptPlayers = Self.players
            case .music: scriptPlayers = [Self.music]
            case .spotify: scriptPlayers = [Self.spotify]
            }
            refresh()
        }
    }

    // MARK: MediaRemote

    /// Sources (notably browsers) report an empty track for a moment while skipping to the next
    /// one. Hold the current track briefly so the player doesn't flash "nothing playing".
    private var pendingEmpty: DispatchWorkItem?

    private func applyRemote(_ s: MediaRemoteSource.State) {
        pendingEmpty?.cancel(); pendingEmpty = nil
        if s.title.isEmpty, hasTrack, useRemote {
            let work = DispatchWorkItem { [weak self] in
                self?.pendingEmpty = nil
                self?.applyRemoteNow(s)
            }
            pendingEmpty = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
            return
        }
        applyRemoteNow(s)
    }

    private func applyRemoteNow(_ s: MediaRemoteSource.State) {
        remoteState = s
        remoteState.artwork = nil
        if let art = s.artwork { remoteArtwork = art }
        guard useRemote else { return }
        settings.noteSource(s.bundleID)
        if !s.bundleID.isEmpty, settings.ignoredSources.contains(s.bundleID) {
            clear()
            if artwork != nil { artwork = nil }
            return
        }
        if artwork !== remoteArtwork { artwork = remoteArtwork }
        setTrack(title: s.title, artist: s.artist, album: s.album, bundleID: s.bundleID)
        let playing = s.isPlaying && !s.title.isEmpty
        assign(\.duration, s.duration)
        anchor = (s.elapsed, s.timestamp, s.rate > 0 ? s.rate : 1)
        isPlaying = playing
        tick()
        assign(\.supportedCommands, s.commands ?? [])
        if let m = s.shuffleMode { assign(\.shuffle, m == 1 ? .off : (m > 1 ? .on : .unknown)) }
        if let m = s.repeatMode { assign(\.repeatMode, m == 1 ? .off : m == 2 ? .one : m == 3 ? .all : .unknown) }
        if let l = s.isLiked { assign(\.isLiked, l) }
    }

    // MARK: Track state

    private func setTrack(title raw: String, artist: String, album: String, bundleID: String) {
        let changed = raw != rawTitle || artist != self.artist || bundleID != sourceBundleID
        // Keyed on the title: some sources fill in the artist a beat later for the same track.
        if raw != rawTitle, !rawTitle.isEmpty, !raw.isEmpty { trackChanges &+= 1 }
        assign(\.rawTitle, raw)
        assign(\.artist, artist)
        assign(\.album, album)
        updateDisplayTitle()
        if bundleID != sourceBundleID {
            sourceBundleID = bundleID
            appIcon = bundleID.isEmpty ? nil : NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                .map { NSWorkspace.shared.icon(forFile: $0.path) }
            updateFrontmost()
        }
        if changed {
            shuffle = .unknown; repeatMode = .unknown; isLiked = nil
            if let p = scriptPlayer, !useRemote || scriptExtrasApproved.contains(p.bundleID) { fetchScriptExtras(p) }
        }
        updateExplicit()
    }

    /// Explicit flag: MediaRemote's when the source sets it, a "(Explicit)" title tag, else iTunes lookup.
    private func updateExplicit() {
        guard settings.explicitBadge, !rawTitle.isEmpty else {
            explicitLookup.cancel()
            assign(\.isExplicit, false)
            return
        }
        if useRemote, let e = remoteState.isExplicit {
            explicitLookup.cancel()
            assign(\.isExplicit, e)
            return
        }
        if rawTitle.range(of: #"[\(\[]\s*explicit\s*[\)\]]"#, options: [.regularExpression, .caseInsensitive]) != nil {
            explicitLookup.cancel()
            assign(\.isExplicit, true)
            return
        }
        let key = rawTitle + "|" + artist
        let cached = explicitLookup.request(title: TitleCleaner.clean(rawTitle), artist: artist) { [weak self] e in
            guard let self, self.rawTitle + "|" + self.artist == key, self.settings.explicitBadge else { return }
            self.assign(\.isExplicit, e)
        }
        assign(\.isExplicit, cached ?? (explicitKey == key ? isExplicit : false))
        explicitKey = key
    }
    private var explicitKey = ""

    private func updateDisplayTitle() {
        assign(\.title, settings.cleanTitles ? TitleCleaner.clean(rawTitle) : rawTitle)
    }

    private func clear() {
        active = nil
        isPlaying = false
        for kp in [\NowPlaying.title, \.rawTitle, \.artist, \.album] { assign(kp, "") }
        setPosition(0); assign(\.duration, 0)
        if appIcon != nil { appIcon = nil }
        if !sourceBundleID.isEmpty { sourceBundleID = ""; updateFrontmost() }
        shuffle = .unknown; repeatMode = .unknown; isLiked = nil
        assign(\.supportedCommands, [])
        updateExplicit()
    }

    private func assign<T: Equatable>(_ kp: ReferenceWritableKeyPath<NowPlaying, T>, _ value: T) {
        if self[keyPath: kp] != value { self[keyPath: kp] = value }
    }

    private func setPosition(_ p: Double) {
        if clock.position != p { clock.position = p }
    }

    // MARK: Position ticking (a 1 s timer only while playing)

    private func updateTicker() {
        if isPlaying, ticker == nil {
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
            t.tolerance = 0.2
            RunLoop.main.add(t, forMode: .common)
            ticker = t
        } else if !isPlaying {
            ticker?.invalidate()
            ticker = nil
        }
    }

    private func tick() {
        var p = anchor.elapsed
        if isPlaying { p += Date().timeIntervalSince(anchor.at) * anchor.rate }
        if duration > 0 { p = min(p, duration) }
        setPosition(max(p, 0))
        // AppleScript players don't broadcast seeks made in the app; resync occasionally.
        ticks += 1
        if !useRemote, isPlaying, ticks % 15 == 0 { refresh() }
    }

    // MARK: Frontmost / accent

    private func updateFrontmost() {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        assign(\.sourceIsFrontmost, !sourceBundleID.isEmpty && front == sourceBundleID)
        assign(\.hidesCollapsedActivity, settings.hideWhileSourceFrontmost && sourceIsFrontmost)
    }

    private func updateAccent() {
        accentWork += 1
        let work = accentWork
        // Mono style: no color anywhere (tint, glow, collapsed equalizer fall back to white).
        let wantAccent = settings.artworkColor && settings.artworkStyle != .mono
        let wantBackdrop = settings.artworkStyle == .gradient
        guard wantAccent || wantBackdrop, let art = artwork else {
            if accentColor != nil { accentColor = nil }
            if backdropColors != nil { backdropColors = nil }
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let c = wantAccent ? ArtworkColor.accent(for: art) : nil
            let b = wantBackdrop ? ArtworkColor.backdrop(for: art) : nil
            DispatchQueue.main.async {
                guard let self, self.accentWork == work else { return }
                if self.accentColor != c { self.accentColor = c }
                if self.backdropColors != b { self.backdropColors = b }
            }
        }
    }

    // MARK: Commands

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
        runScript(p, "tell application \"\(p.name)\" to \(command)")
    }

    var canSeek: Bool { duration > 0 && (!useRemote || supportedCommands.isEmpty || supportedCommands.contains(24)) }

    /// Jump to `seconds` in the current track.
    func seek(to seconds: Double) {
        let t = max(0, duration > 0 ? min(seconds, duration) : seconds)
        if useRemote {
            remote.send("seek \(t)")
        } else if let p = active {
            runScript(p, "tell application \"\(p.name)\" to set player position to \(t)", refreshAfter: false)
        } else { return }
        anchor = (t, Date(), anchor.rate)
        setPosition(t)
    }

    /// Music/Spotify is the source: shuffle/repeat/favorite go through AppleScript (state is readable).
    private var scriptPlayer: Player? {
        if !useRemote { return active }
        return Self.players.first { $0.bundleID == sourceBundleID }
    }

    var canShuffle: Bool { scriptPlayer != nil || supportedCommands.contains(6) || supportedCommands.contains(26) }
    var canRepeat: Bool { scriptPlayer != nil || supportedCommands.contains(7) || supportedCommands.contains(25) }
    /// Spotify's AppleScript dictionary has no like/save, so it's only Music or a MediaRemote source.
    var canLike: Bool { scriptPlayer?.bundleID == Self.music.bundleID || (scriptPlayer == nil && supportedCommands.contains(21)) }

    func toggleShuffle() {
        if let p = scriptPlayer {
            scriptExtrasApproved.insert(p.bundleID)
            let src = p.name == "Spotify"
                ? "tell application \"Spotify\"\nset shuffling to not shuffling\nreturn shuffling as string\nend tell"
                : "tell application \"Music\"\nset shuffle enabled to not shuffle enabled\nreturn shuffle enabled as string\nend tell"
            shuffle = shuffle == .on ? .off : .on
            runScript(p, src, refreshAfter: false) { [weak self] out in
                if let out { self?.shuffle = out == "true" ? .on : .off }
            }
        } else if supportedCommands.contains(26), shuffle != .unknown {
            remote.send("setshuffle \(shuffle == .on ? 1 : 3)")
            shuffle = shuffle == .on ? .off : .on
        } else {
            remote.send("shuffle")
            if shuffle != .unknown { shuffle = shuffle == .on ? .off : .on }
        }
    }

    func cycleRepeat() {
        let next: RepeatState = switch repeatMode { case .off, .unknown: .all; case .all: .one; case .one: .off }
        if let p = scriptPlayer {
            scriptExtrasApproved.insert(p.bundleID)
            let src: String
            if p.name == "Spotify" { // boolean only: off <-> all
                src = "tell application \"Spotify\"\nset repeating to not repeating\nreturn repeating as string\nend tell"
            } else {
                let v = next == .all ? "all" : next == .one ? "one" : "off"
                src = "tell application \"Music\"\nset song repeat to \(v)\nreturn song repeat as string\nend tell"
            }
            repeatMode = p.name == "Spotify" ? (repeatMode == .all ? .off : .all) : next
            runScript(p, src, refreshAfter: false) { [weak self] out in
                guard let out else { return }
                self?.repeatMode = switch out { case "true", "all": .all; case "one": .one; default: .off }
            }
        } else if supportedCommands.contains(25), repeatMode != .unknown {
            remote.send("setrepeat \(next == .off ? 1 : next == .one ? 2 : 3)")
            repeatMode = next
        } else {
            remote.send("repeat")
            if repeatMode != .unknown { repeatMode = next }
        }
    }

    func toggleLike() {
        if let p = scriptPlayer {
            guard p.bundleID == Self.music.bundleID else { return }
            scriptExtrasApproved.insert(p.bundleID)
            isLiked = !(isLiked ?? false)
            runScript(p, Self.musicToggleFavorite, refreshAfter: false) { [weak self] out in
                if let out { self?.isLiked = out == "true" }
            }
        } else if supportedCommands.contains(21) {
            remote.send("like")
            isLiked = true
        }
    }

    /// Brings the playing app forward; for browsers, focuses the tab whose title has the track.
    func openSource() {
        let bundleID = sourceBundleID, raw = rawTitle
        guard !bundleID.isEmpty else { return }
        let activate = {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: cfg)
        }
        guard BrowserTabs.supports(bundleID), !raw.isEmpty else { activate(); return }
        queue.async {
            let found = BrowserTabs.focus(bundleID: bundleID, containing: raw)
            if !found { DispatchQueue.main.async(execute: activate) }
        }
    }

    var sourceIsBrowser: Bool { BrowserTabs.supports(sourceBundleID) }

    // MARK: AppleScript

    private static let musicToggleFavorite = """
    tell application "Music"
        try
            set favorited of current track to not (favorited of current track)
            return favorited of current track as string
        on error
            set loved of current track to not (loved of current track)
            return loved of current track as string
        end try
    end tell
    """

    private func runScript(_ p: Player, _ src: String, refreshAfter: Bool = true,
                           completion: ((String?) -> Void)? = nil) {
        queue.async { [weak self] in
            let out = Self.run(src)?.stringValue
            DispatchQueue.main.async {
                completion?(out)
                if refreshAfter, let self, !self.useRemote { self.refresh() }
            }
        }
    }

    private func fetchScriptExtras(_ p: Player) {
        let src = p.name == "Spotify"
            ? "tell application \"Spotify\" to return (shuffling as string) & \"|\" & (repeating as string) & \"|\""
            : """
            tell application "Music"
                set f to ""
                try
                    set f to favorited of current track as string
                on error
                    try
                        set f to loved of current track as string
                    end try
                end try
                return (shuffle enabled as string) & "|" & (song repeat as string) & "|" & f
            end tell
            """
        let key = rawTitle
        queue.async { [weak self] in
            guard let parts = Self.run(src)?.stringValue?.components(separatedBy: "|"), parts.count == 3 else { return }
            DispatchQueue.main.async {
                guard let self, self.rawTitle == key else { return }
                self.shuffle = parts[0] == "true" ? .on : .off
                self.repeatMode = switch parts[1] { case "true", "all": .all; case "one": .one; default: .off }
                self.isLiked = parts[2].isEmpty ? nil : parts[2] == "true"
            }
        }
    }

    func refresh() {
        guard !useRemote else { return }
        guard !refreshing else { refreshAgain = true; return }
        refreshing = true
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let candidates = scriptPlayers
        let knownKey = artworkKey
        queue.async { [weak self] in
            guard let self else { return }
            var result: (Player, [String])?
            for p in candidates where running.contains(p.bundleID) {
                guard let parts = Self.query(p) else { continue }
                if parts[0] == "playing" { result = (p, parts); break }
                if result == nil { result = (p, parts) }
            }
            var art: NSImage??
            var key = knownKey
            if let (p, parts) = result, "\(p.name)|\(parts[1])|\(parts[2])" != knownKey {
                key = "\(p.name)|\(parts[1])|\(parts[2])"
                art = .some(Self.fetchArtwork(p))
            } else if result == nil {
                key = ""
                art = .some(nil)
            }
            DispatchQueue.main.async {
                self.refreshing = false
                guard !self.useRemote, candidates.map(\.bundleID) == self.scriptPlayers.map(\.bundleID) else { return }
                self.artworkKey = key
                if let art { self.artwork = art }
                if let (p, parts) = result { self.apply(p, parts) } else { self.clear() }
                if self.refreshAgain { self.refreshAgain = false; self.refresh() }
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
        setTrack(title: parts[1], artist: parts[2], album: "", bundleID: p.bundleID)
        assign(\.duration, Double(parts[4].replacingOccurrences(of: ",", with: ".")) ?? 0)
        anchor = (Double(parts[3].replacingOccurrences(of: ",", with: ".")) ?? 0, Date(), 1)
        isPlaying = parts[0] == "playing"
        tick()
    }
}
