import AppKit
import SwiftUI

/// Visualizer sections for the Settings window.
struct WaveformSettingsSection: View {
    @ObservedObject private var settings = WaveformSettings.shared
    @ObservedObject private var visualizer = AudioVisualizer.shared

    var body: some View {
        Section("Style") {
            VisualizerPreview(style: settings.style, count: settings.barCount)
            SettingPicker("Style", selection: $settings.style, segmented: true) {
                Text("Bars").tag(WaveformSettings.Style.bars)
                Text("Wave line").tag(WaveformSettings.Style.line)
            }
            SettingStepper(settings.style == .bars ? "Bars" : "Peaks",
                           detail: "Fewer reads calmer; more shows more detail.",
                           value: $settings.barCount, in: WaveformSettings.barRange)
        }

        Section {
            SettingToggle("Use real audio",
                          detail: "Draws the spectrum of what's actually playing. Off: animated bars, no audio capture.",
                          isOn: $settings.useRealAudio)
            if settings.useRealAudio {
                SettingRow("Status", detail: statusText) {
                    if needsPermissionHint {
                        Button("Open Privacy Settings…") { Self.openPrivacy() }
                    } else {
                        StatusBadge(text: statusBadge.0, color: statusBadge.1)
                    }
                }
            }
        } header: {
            SectionHeader("Audio")
        }
    }

    private var statusBadge: (String, Color) {
        switch visualizer.status {
        case .live: ("Live", .green)
        case .starting: ("Starting", .orange)
        default: ("Idle", .secondary)
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

/// Static look of the collapsed notch with the visualizer on its right (no animation, no capture).
private struct VisualizerPreview: View {
    let style: WaveformSettings.Style
    let count: Int

    private var levels: [CGFloat] {
        (0..<count).map { i in 0.3 + 0.7 * abs(sin(Double(i) * 1.9 + 0.6)) }.map { CGFloat($0) }
    }

    var body: some View {
        PreviewBackdrop(height: 64, menuBarHeight: 32) {
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 20, height: 20)
                Spacer(minLength: 150)
                graph.frame(width: 26, height: 14)
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(NotchShape(topRadius: 6, bottomRadius: 12).fill(.black))
            .fixedSize()
        }
        .padding(.vertical, 2)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var graph: some View {
        GeometryReader { geo in
            let n = CGFloat(levels.count)
            switch style {
            case .bars:
                let gap = min(2, geo.size.width / (n * 3))
                let w = (geo.size.width - gap * (n - 1)) / n
                HStack(spacing: gap) {
                    ForEach(levels.indices, id: \.self) { i in
                        Capsule().fill(.green)
                            .frame(width: w, height: max(w, geo.size.height * (0.12 + 0.88 * levels[i])))
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            case .line:
                Path { p in
                    let mid = geo.size.height / 2
                    p.move(to: CGPoint(x: 0, y: mid))
                    var prev = CGPoint(x: 0, y: mid)
                    for i in levels.indices {
                        let x = geo.size.width * (CGFloat(i) + 0.5) / n
                        let a = geo.size.height / 2 * (0.08 + 0.92 * levels[i])
                        let pt = CGPoint(x: x, y: mid + (i.isMultiple(of: 2) ? -a : a))
                        p.addCurve(to: pt, control1: CGPoint(x: (prev.x + x) / 2, y: prev.y),
                                   control2: CGPoint(x: (prev.x + x) / 2, y: pt.y))
                        prev = pt
                    }
                    let end = CGPoint(x: geo.size.width, y: mid)
                    p.addCurve(to: end, control1: CGPoint(x: (prev.x + end.x) / 2, y: prev.y),
                               control2: CGPoint(x: (prev.x + end.x) / 2, y: mid))
                }
                .stroke(.green, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
        }
    }
}
