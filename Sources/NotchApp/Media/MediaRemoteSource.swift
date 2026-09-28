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

    static var helperFiles: (script: String, dylib: String)? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let script = res.appendingPathComponent("media-remote.pl").path
        let dylib = res.appendingPathComponent("MediaRemoteHelper.dylib").path
        let fm = FileManager.default
        return fm.fileExists(atPath: script) && fm.fileExists(atPath: dylib) ? (script, dylib) : nil
    }

    func start() {
        guard let files = Self.helperFiles else { onUnavailable?(); return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [files.script, files.dylib]
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardInput = inp
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            DispatchQueue.main.async { self?.consume(chunk) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.handleExit() }
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

    deinit { process?.terminate() }

    private func handleExit() {
        isRunning = false
        input = nil
        process = nil
        failures += 1
        // Crashed before ever producing data twice in a row: this OS doesn't allow it.
        if !gotData && failures >= 2 { onUnavailable?(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.start() }
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
        return s
    }
}
