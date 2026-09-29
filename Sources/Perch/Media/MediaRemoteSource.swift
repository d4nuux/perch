import AppKit

/// System-wide Now Playing (browsers, Spotify, Music, podcasts…) via the MediaRemote helper that
/// runs inside /usr/bin/perl (see Helper/). Reports on the main thread.
final class MediaRemoteSource {
    struct State {
        var title = "", artist = "", album = "", bundleID = ""
        var isPlaying = false
        var duration: Double = 0, elapsed: Double = 0, rate: Double = 0
        var timestamp = Date()
        var artwork: NSImage??  // .none = unchanged, .some(nil) = no artwork
        /// MRMediaRemoteShuffleMode (1 off, 2 albums, 3 songs) / RepeatMode (1 off, 2 one, 3 all), if exposed.
        var shuffleMode: Int?, repeatMode: Int?
        var isLiked: Bool?
        /// kMRMediaRemoteNowPlayingInfoIsExplicitTrack, if the helper forwards it and the source sets it.
        var isExplicit: Bool?
        /// Enabled MRMediaRemoteCommand ids; nil if the helper couldn't query them.
        var commands: Set<Int>?
    }

    var onUpdate: ((State) -> Void)?
    /// Called once if the helper can't run on this system, so the caller can fall back.
    var onUnavailable: (() -> Void)?
    private(set) var isRunning = false

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var failures = 0
    private var gotData = false
    private var stopped = false
    /// Bumped per launch so a stale process's exit handler can't touch the current one.
    private var generation = 0

    static var helperFiles: (script: String, dylib: String)? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let script = res.appendingPathComponent("media-remote.pl").path
        let dylib = res.appendingPathComponent("MediaRemoteHelper.dylib").path
        let fm = FileManager.default
        return fm.fileExists(atPath: script) && fm.fileExists(atPath: dylib) ? (script, dylib) : nil
    }

    func start() {
        stopped = false
        guard process == nil else { return }
        guard let files = Self.helperFiles else { onUnavailable?(); return }
        generation += 1
        let gen = generation
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [files.script, files.dylib]
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardInput = inp
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            if chunk.isEmpty { h.readabilityHandler = nil; return } // EOF
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.consume(chunk)
            }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.handleExit()
            }
        }
        do {
            try p.run()
            process = p
            input = inp.fileHandleForWriting
            isRunning = true
        } catch {
            onUnavailable?()
        }
    }

    func send(_ command: String) {
        guard let input, let data = (command + "\n").data(using: .utf8) else { return }
        try? input.write(contentsOf: data)
    }

    /// Stops the helper (e.g. the user picked an AppleScript-only source). `start()` resumes.
    func stop() {
        stopped = true
        generation += 1
        process?.terminate()
        process = nil
        input = nil
        buffer.removeAll()
        isRunning = false
    }

    deinit { process?.terminate() }

    private func handleExit() {
        isRunning = false
        input = nil
        process = nil
        failures += 1
        // Crashed before ever producing data twice in a row: this OS doesn't allow it.
        if !gotData && failures >= 2 { onUnavailable?(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.stopped else { return }
            self.start()
        }
    }

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            gotData = true
            failures = 0
            onUpdate?(Self.parse(obj))
        }
    }

    private static func parse(_ o: [String: Any]) -> State {
        var s = State()
        s.title = o["title"] as? String ?? ""
        s.artist = o["artist"] as? String ?? ""
        s.album = o["album"] as? String ?? ""
        s.bundleID = o["bundle"] as? String ?? ""
        s.isPlaying = (o["playing"] as? NSNumber)?.boolValue ?? false
        s.duration = (o["duration"] as? NSNumber)?.doubleValue ?? 0
        s.elapsed = (o["elapsed"] as? NSNumber)?.doubleValue ?? 0
        s.rate = (o["rate"] as? NSNumber)?.doubleValue ?? 0
        s.timestamp = Date(timeIntervalSince1970: (o["timestamp"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970)
        if let b64 = o["artwork"] as? String {
            s.artwork = .some(Data(base64Encoded: b64).flatMap(NSImage.init(data:)))
        }
        s.shuffleMode = (o["shuffle"] as? NSNumber)?.intValue
        s.repeatMode = (o["repeat"] as? NSNumber)?.intValue
        s.isLiked = (o["liked"] as? NSNumber)?.boolValue
        s.isExplicit = (o["explicit"] as? NSNumber)?.boolValue
        if let c = o["commands"] as? [NSNumber] { s.commands = Set(c.map(\.intValue)) }
        return s
    }
}
