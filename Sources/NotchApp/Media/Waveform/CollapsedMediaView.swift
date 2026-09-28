import SwiftUI

/// Collapsed "live activity": artwork on the left of the notch, live visualizer on the right.
struct CollapsedActivity: View {
    @EnvironmentObject var nowPlaying: NowPlaying
    let notchWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if let art = nowPlaying.artwork ?? nowPlaying.appIcon {
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Color.white.opacity(0.12)
                        Image(systemName: "music.note").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                    }
                }
            }
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            Spacer(minLength: notchWidth)
            Equalizer(color: nowPlaying.accentColor.map { Color(nsColor: $0) } ?? .white).frame(width: 24, height: 14)
        }
        .padding(.horizontal, 12)
        .onAppear { AudioVisualizer.shared.attach(nowPlaying) }
    }
}

/// Audio visualizer. Shows the live spectrum when `AudioVisualizer` has data, else a synthetic
/// animation. Being on screen is what requests capture (see `AudioVisualizer.acquire`).
struct Equalizer: View {
    @ObservedObject private var visualizer = AudioVisualizer.shared
    @ObservedObject private var settings = WaveformSettings.shared
    private let bars: Int?
    private let color: Color
    private let style: WaveformSettings.Style?

    /// Default look: settings' bar count and style, green.
    init() { self.init(bars: nil, color: .green) }

    /// `bars`/`style` nil → use the user's setting.
    init(bars: Int? = nil, color: Color, style: WaveformSettings.Style? = nil) {
        self.bars = bars
        self.color = color
        self.style = style
    }

    var body: some View {
        GeometryReader { geo in
            let n = barCount(width: geo.size.width)
            Group {
                if settings.useRealAudio && visualizer.isLive {
                    shape(Self.resample(visualizer.levels, to: n), size: geo.size)
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in // not display-rate
                        shape(Self.synthetic(n, t: ctx.date.timeIntervalSinceReferenceDate), size: geo.size)
                    }
                }
            }
        }
        .onAppear { visualizer.acquire() }
        .onDisappear { visualizer.release() }
    }

    private func barCount(width: CGFloat) -> Int {
        let wanted = bars ?? settings.barCount
        // Keep bars ≥ 1.5pt with 1.5pt gaps.
        return max(2, min(wanted, Int((width + 1.5) / 3)))
    }

    @ViewBuilder
    private func shape(_ levels: [Float], size: CGSize) -> some View {
        switch style ?? settings.style {
        case .bars:
            let n = CGFloat(levels.count)
            let gap = min(2, size.width / (n * 3))
            let w = (size.width - gap * (n - 1)) / n
            HStack(alignment: .center, spacing: gap) {
                ForEach(levels.indices, id: \.self) { i in
                    Capsule().fill(color)
                        .frame(width: w, height: max(w, size.height * CGFloat(0.12 + 0.88 * levels[i])))
                }
            }
            .frame(width: size.width, height: size.height)
        case .line:
            WaveLine(levels: levels).stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                .frame(width: size.width, height: size.height)
        }
    }

    static func synthetic(_ n: Int, t: Double) -> [Float] {
        (0..<n).map { i in Float(0.3 + 0.7 * abs(sin(t * (3.1 + Double(i) * 1.3) + Double(i)))) }
    }

    /// Linear interpolation of `levels` onto `n` points.
    static func resample(_ levels: [Float], to n: Int) -> [Float] {
        guard levels.count > 1, n > 1 else { return Array(repeating: levels.first ?? 0, count: max(n, 1)) }
        if levels.count == n { return levels }
        return (0..<n).map { i in
            let x = Float(i) / Float(n - 1) * Float(levels.count - 1)
            let j = min(Int(x), levels.count - 2)
            let f = x - Float(j)
            return levels[j] * (1 - f) + levels[j + 1] * f
        }
    }
}

/// Smooth line that swings above/below the midline, amplitude = band level.
private struct WaveLine: Shape {
    let levels: [Float]

    func path(in r: CGRect) -> Path {
        let n = levels.count
        let mid = r.midY
        // Endpoints pinned to the midline; each band is one alternating peak.
        var pts = [CGPoint(x: r.minX, y: mid)]
        for i in 0..<n {
            let x = r.minX + r.width * (CGFloat(i) + 0.5) / CGFloat(n)
            let a = r.height / 2 * CGFloat(0.08 + 0.92 * levels[i])
            pts.append(CGPoint(x: x, y: mid + (i.isMultiple(of: 2) ? -a : a)))
        }
        pts.append(CGPoint(x: r.maxX, y: mid))
        var p = Path()
        p.move(to: pts[0])
        for i in 1..<pts.count {
            let a = pts[i - 1], b = pts[i]
            let c = CGPoint(x: (a.x + b.x) / 2, y: a.y)
            let d = CGPoint(x: (a.x + b.x) / 2, y: b.y)
            p.addCurve(to: b, control1: c, control2: d)
        }
        return p
    }
}
