import AppKit
import SwiftUI

/// Waveform rows for the Settings window (Form rows; Settings wraps them in a Section).
struct WaveformSettingsSection: View {
    @ObservedObject private var settings = WaveformSettings.shared
    @ObservedObject private var visualizer = AudioVisualizer.shared

    var body: some View {
        Picker("Visualizer style", selection: $settings.style) {
            Text("Bars").tag(WaveformSettings.Style.bars)
            Text("Wave line").tag(WaveformSettings.Style.line)
        }
        Stepper(value: $settings.barCount, in: WaveformSettings.barRange) {
            LabeledContent("Bars", value: "\(settings.barCount)")
        }
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Use real audio", isOn: $settings.useRealAudio)
                .help("Draws the spectrum of what's actually playing. Off: animated bars, no audio capture.")
            if settings.useRealAudio {
                HStack {
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if needsPermissionHint {
                        Button("Open Privacy Settings…") { Self.openPrivacy() }.controlSize(.small)
                    }
                }
            }
        }
    }

    private var statusText: String {
        switch visualizer.status {
        case .idle: "Captures only while music is playing and the visualizer is visible."
        case .starting: "Starting…"
        case .live: "Live audio active."
        case .silent: "No audio received — allow NotchApp under System Audio Recording, or nothing is audible."
        case .unavailable(let why): "Audio capture unavailable (\(why)). Using animation."
        }
    }

    private var needsPermissionHint: Bool {
        switch visualizer.status { case .silent, .unavailable: true; default: false }
    }

    static func openPrivacy() {
        let urls = ["x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture",
                    "x-apple.systempreferences:com.apple.preference.security?Privacy"]
        for s in urls { if let u = URL(string: s), NSWorkspace.shared.open(u) { return } }
    }
}
