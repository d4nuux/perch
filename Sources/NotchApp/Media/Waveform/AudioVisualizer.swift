import Accelerate
import AppKit
import Combine
import Foundation

/// Live spectrum of system audio output, shared by every `Equalizer`.
///
/// Runs only while (a) at least one visualizer view is on screen (`acquire`/`release`, driven by
/// `Equalizer.onAppear/onDisappear`), (b) something is playing (if a `NowPlaying` is attached), and
/// (c) "Use real audio" is on. Otherwise the tap and aggregate device are destroyed: zero idle cost.
/// If capture fails or only delivers digital silence (what TCC does when audio-capture permission
/// is denied), `isLive` stays false and views fall back to the synthetic animation.
final class AudioVisualizer: ObservableObject {
    static let shared = AudioVisualizer()
    static let bandCount = 12

    enum Status: Equatable { case idle, starting, live, silent, unavailable(String) }

    /// 0...1 per band, low → high frequency. Updated ~30×/s while live.
    @Published private(set) var levels = [Float](repeating: 0, count: bandCount)
    @Published private(set) var status: Status = .idle
    var isLive: Bool { status == .live }

    private var viewers = 0
    /// Main thread: a tap has been requested and not yet torn down.
    private var running = false
    private var isPlaying: Bool?
    private var playingSub: AnyCancellable?
    private var settingsSub: AnyCancellable?
    private var stopWork: DispatchWorkItem?
    /// After a failure / silence timeout, don't retry until this date.
    private var retryAfter = Date.distantPast
    /// Consecutive failed / silent attempts. Backoff 30s, 2m, 10m, then give up until reset
    /// (setting toggled or app activated). Reset on the first live levels.
    private var failures = 0
    private static let backoff: [TimeInterval] = [30, 120, 600]
    private var activateObserver: NSObjectProtocol?

    private let control = DispatchQueue(label: "notchapp.waveform.control")
    private var engine: AnyObject? // SystemAudioTap, control queue only
    private let analyzer = SpectrumAnalyzer(bands: bandCount)

    private init() {
        settingsSub = WaveformSettings.shared.$useRealAudio.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.resetBackoff(); self?.update() }
        }
        activateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.resetBackoff(); self?.update() }
    }

    private func resetBackoff() {
        failures = 0
        retryAfter = .distantPast
    }

    /// Main thread. Schedules the next allowed attempt after a failure / silence.
    private func backOff() {
        failures += 1
        retryAfter = failures <= Self.backoff.count
            ? Date().addingTimeInterval(Self.backoff[failures - 1]) : .distantFuture
    }

    /// Gate on `nowPlaying.isPlaying`. Safe to call repeatedly with the same object.
    func attach(_ nowPlaying: NowPlaying) {
        guard playingSub == nil else { return }
        playingSub = nowPlaying.$isPlaying.removeDuplicates().sink { [weak self] playing in
            guard let self else { return }
            // A new play start may retry early, but still counts toward the backoff limit.
            if playing, self.isPlaying == false, self.retryAfter != .distantFuture { self.retryAfter = .distantPast }
            self.isPlaying = playing
            self.update()
        }
    }

    func acquire() { viewers += 1; update() }
    func release() { viewers = max(viewers - 1, 0); update() }

    private var wanted: Bool {
        viewers > 0 && isPlaying != false && WaveformSettings.shared.useRealAudio
    }

    /// Main thread.
    private func update() {
        stopWork?.cancel(); stopWork = nil
        if wanted {
            guard !running, Date() >= retryAfter else { return }
            start()
        } else if running {
            // Debounce: collapsed view ↔ track peek swap Equalizers within one transition.
            let work = DispatchWorkItem { [weak self] in self?.stop() }
            stopWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        }
    }

    private func start() {
        guard #available(macOS 14.4, *) else {
            status = .unavailable("Requires macOS 14.4"); retryAfter = .distantFuture; return
        }
        running = true
        status = .starting
        analyzer.reset()
        let analyzer = analyzer
        control.async { [weak self] in
            let tap = SystemAudioTap()
            tap.onSamples = { samples, count, rate in
                analyzer.feed(samples, count: count, sampleRate: rate) { event in
                    DispatchQueue.main.async { self?.handle(event) }
                }
            }
            do {
                try tap.start()
                self?.engine = tap
            } catch {
                DispatchQueue.main.async { self?.fail("\(error)") }
            }
        }
    }

    private func stop() {
        guard running else { return }
        running = false
        control.async { [weak self] in
            if #available(macOS 14.4, *) { (self?.engine as? SystemAudioTap)?.stop() }
            self?.engine = nil
        }
        status = .idle
        levels = [Float](repeating: 0, count: Self.bandCount)
    }

    private func handle(_ event: SpectrumAnalyzer.Event) {
        guard running, wanted else { return }
        switch event {
        case .levels(let l):
            if status != .live { status = .live; failures = 0 }
            levels = l
        case .silenceTimeout:
            // No samples at all for a while: permission denied, or nothing actually audible.
            status = .silent
            backOff()
            stop()
            status = .silent
            levels = [Float](repeating: 0, count: Self.bandCount)
        }
    }

    private func fail(_ message: String) {
        status = .unavailable(message)
        backOff()
        stop()
        status = .unavailable(message)
    }
}

/// FFT → log-spaced bands with fast attack / slow release. Called on the Core Audio IO thread only.
final class SpectrumAnalyzer {
    enum Event { case levels([Float]), silenceTimeout }

    private let n = 1024
    private let log2n = vDSP_Length(10)
    private let bands: Int
    private let fft: FFTSetup
    private var window: [Float]
    private var ring: [Float]
    private var ringPos = 0
    private var sinceLast = 0
    private var zeroFrames = 0
    private var smoothed: [Float]
    private var windowed: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var power: [Float]
    private let lock = NSLock()
    private var needsReset = false

    static let fps = 30.0
    static let silenceTimeout = 3.0

    init(bands: Int) {
        self.bands = bands
        fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        ring = [Float](repeating: 0, count: n)
        smoothed = [Float](repeating: 0, count: bands)
        windowed = [Float](repeating: 0, count: n)
        real = [Float](repeating: 0, count: n / 2)
        imag = [Float](repeating: 0, count: n / 2)
        power = [Float](repeating: 0, count: n / 2)
    }

    deinit { vDSP_destroy_fftsetup(fft) }

    /// Any thread.
    func reset() { lock.lock(); needsReset = true; lock.unlock() }

    func feed(_ p: UnsafePointer<Float>, count: Int, sampleRate: Double, emit: (Event) -> Void) {
        lock.lock(); let r = needsReset; needsReset = false; lock.unlock()
        if r {
            for i in 0..<bands { smoothed[i] = 0 }
            zeroFrames = 0; sinceLast = 0
        }

        var peak: Float = 0
        vDSP_maxmgv(p, 1, &peak, vDSP_Length(count))
        if peak == 0 {
            zeroFrames += count
            if Double(zeroFrames) > sampleRate * Self.silenceTimeout {
                zeroFrames = 0
                emit(.silenceTimeout)
                return
            }
        } else {
            zeroFrames = 0
        }

        for i in 0..<count {
            ring[ringPos] = p[i]
            ringPos = (ringPos + 1) & (n - 1)
        }
        sinceLast += count
        let hop = Int(sampleRate / Self.fps)
        guard sinceLast >= hop else { return }
        sinceLast = min(sinceLast - hop, hop) // carry remainder → steady ~30 fps with 512-frame IO
        emit(.levels(analyze(sampleRate: sampleRate)))
    }

    private func analyze(sampleRate: Double) -> [Float] {
        // Linearize ring (oldest first) and window.
        let tail = n - ringPos
        ring.withUnsafeBufferPointer { r in
            windowed.withUnsafeMutableBufferPointer { w in
                w.baseAddress!.update(from: r.baseAddress! + ringPos, count: tail)
                (w.baseAddress! + tail).update(from: r.baseAddress!, count: ringPos)
            }
        }
        vDSP_vmul(windowed, 1, window, 1, &windowed, 1, vDSP_Length(n))

        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                windowed.withUnsafeBufferPointer { w in
                    w.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                im[0] = 0 // packed Nyquist; ignore
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(n / 2))
            }
        }

        // Log-spaced bands 50 Hz … 14 kHz.
        let binHz = sampleRate / Double(n)
        let lo = 50.0, hi = min(14_000, sampleRate / 2 - binHz)
        var out = [Float](repeating: 0, count: bands)
        let norm = Float(n) * Float(n) // zrip output is 2× scaled; Hann-normalized amplitude ≈ |X|/n
        for b in 0..<bands {
            let f0 = lo * pow(hi / lo, Double(b) / Double(bands))
            let f1 = lo * pow(hi / lo, Double(b + 1) / Double(bands))
            let i0 = max(1, Int(f0 / binHz))
            let i1 = max(i0 + 1, min(n / 2, Int(ceil(f1 / binHz))))
            var sum: Float = 0
            power.withUnsafeBufferPointer { vDSP_sve($0.baseAddress! + i0, 1, &sum, vDSP_Length(i1 - i0)) }
            let db = 10 * log10(max(sum / norm, 1e-12))
            // Tilt: music has much more energy low; lift highs so all bars move.
            let tilt = Float(b) / Float(bands - 1) * 12
            let v = min(max((db + tilt + 64) / 58, 0), 1)
            let prev = smoothed[b]
            smoothed[b] = v > prev ? prev + (v - prev) * 0.75 : prev + (v - prev) * 0.14
            out[b] = smoothed[b]
        }
        return out
    }
}
