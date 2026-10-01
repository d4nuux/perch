import Foundation

/// Visualizer preferences (UserDefaults-backed).
final class WaveformSettings: ObservableObject {
    static let shared = WaveformSettings()
    enum Style: String, CaseIterable { case bars, line }
    static let barRange = 4...12

    private let d = UserDefaults.standard

    @Published var style: Style { didSet { d.set(style.rawValue, forKey: "waveform.style") } }
    @Published var barCount: Int { didSet { d.set(barCount, forKey: "waveform.barCount") } }
    /// Capture system audio for a real spectrum; off = synthetic animation only (no capture at all).
    @Published var useRealAudio: Bool { didSet { d.set(useRealAudio, forKey: "waveform.useRealAudio") } }

    private init() {
        d.register(defaults: ["waveform.style": Style.bars.rawValue, "waveform.barCount": 5,
                              "waveform.useRealAudio": true])
        style = Style(rawValue: d.string(forKey: "waveform.style") ?? "") ?? .bars
        barCount = min(max(d.integer(forKey: "waveform.barCount"), Self.barRange.lowerBound), Self.barRange.upperBound)
        useRealAudio = d.bool(forKey: "waveform.useRealAudio")
    }
}
