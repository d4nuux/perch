import SwiftUI

enum HUDKind {
    case volume, brightness, keyboard

    var key: String {
        switch self {
        case .volume: "hud.volume"
        case .brightness: "hud.brightness"
        case .keyboard: "hud.keyboard"
        }
    }

    var title: String {
        switch self {
        case .volume: "Volume"
        case .brightness: "Brightness"
        case .keyboard: "Keyboard"
        }
    }

    func symbol(level: Double, muted: Bool) -> String {
        switch self {
        case .volume:
            if muted || level <= 0.001 { return "speaker.slash.fill" }
            if level < 0.34 { return "speaker.wave.1.fill" }
            if level < 0.67 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        case .brightness:
            return level < 0.5 ? "sun.min.fill" : "sun.max.fill"
        case .keyboard:
            return level < 0.5 ? "light.min" : "light.max"
        }
    }
}

/// Current level of one HUD. The presented views observe it, so repeated key presses animate the
/// bar instead of rebuilding it. Main thread only.
final class HUDLevel: ObservableObject {
    let kind: HUDKind
    @Published var level: Double = 0
    @Published var muted = false
    /// Volume only: the default output device.
    @Published var device: OutputDeviceInfo?
    /// Volume only: showing an output-device change — device icon and name win.
    @Published var announcing = false
    /// Brightness only: name of the external display being adjusted (nil = built-in).
    @Published var displayName: String?

    init(kind: HUDKind) { self.kind = kind }

    private var showsDevice: Bool {
        guard kind == .volume, let device else { return false }
        return announcing || !device.isBuiltInSpeaker
    }

    var symbol: String {
        if showsDevice, let device, announcing || !(muted || level <= 0.001) { return device.symbol }
        return kind.symbol(level: level, muted: muted)
    }

    var label: String {
        if showsDevice, let device, !device.name.isEmpty { return device.name }
        if kind == .brightness, let displayName, !displayName.isEmpty { return displayName }
        return kind.title
    }
}

/// Fixed widths so the notch width is known before presenting (LiveActivity.extraWidth).
enum HUDLayout {
    static let icon: CGFloat = 24
    static let label: CGFloat = 92
    static let bar: CGFloat = 90
    static let percent: CGFloat = 30
    static let spacing: CGFloat = 6

    /// extraWidth for LiveActivity: both sides get half, minus ActivityView's 12pt padding.
    static func extraWidth(settings: HUDSettings, forceLabel: Bool = false) -> CGFloat {
        let leading = icon + (settings.showLabel || forceLabel ? spacing + label : 0)
        let trailing = bar + (settings.showPercentage ? spacing + percent : 0)
        return 2 * (max(leading, trailing) + 12 + 8)
    }
}

struct HUDLeading: View {
    @ObservedObject var state: HUDLevel
    @ObservedObject var settings = HUDSettings.shared

    var body: some View {
        HStack(spacing: HUDLayout.spacing) {
            HUDIcon(state: state)
            if settings.showLabel || state.announcing {
                Text(state.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: HUDLayout.label, alignment: .leading)
            }
        }
    }
}

struct HUDIcon: View {
    @ObservedObject var state: HUDLevel

    var body: some View {
        let name = state.symbol
        Image(systemName: name)
            .font(.system(size: 13, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: HUDLayout.icon, height: 20, alignment: .leading)
            .opacity(state.muted ? 0.6 : 1)
            .animation(.snappy(duration: 0.2), value: name)
            .animation(.easeInOut(duration: 0.2), value: state.muted)
    }
}

struct HUDTrailing: View {
    @ObservedObject var state: HUDLevel
    @ObservedObject var settings = HUDSettings.shared

    var body: some View {
        HStack(spacing: HUDLayout.spacing) {
            HUDBar(state: state, style: settings.barStyle(for: state.kind), animation: settings.animation.animation)
            if settings.showPercentage {
                Text("\(Int((min(max(state.level, 0), 1) * 100).rounded()))")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(state.muted ? 0.35 : 0.55))
                    .frame(width: HUDLayout.percent, alignment: .trailing)
                    .contentTransition(.numericText())
                    .animation(settings.animation.animation, value: state.level)
            }
        }
    }
}

struct HUDBar: View {
    @ObservedObject var state: HUDLevel
    var style: HUDBarStyle = .solid
    var animation: Animation? = .spring(response: 0.26, dampingFraction: 0.9)
    static let width: CGFloat = HUDLayout.bar
    static let segments = 16

    var body: some View {
        let level = min(max(state.level, 0), 1)
        Group {
            switch style {
            case .segmented: segmented(level)
            case .decibel: decibel(level)
            case .glow: glow(level)
            case .solid, .accent, .gradient: continuous(level)
            }
        }
        .frame(width: Self.width, height: style == .decibel ? 8 : 6)
        .animation(animation, value: state.level)
        .animation(.easeInOut(duration: 0.2), value: state.muted)
    }

    private static var tint: Color { Color(nsColor: .controlAccentColor) }

    private var fillStyle: AnyShapeStyle {
        let o = state.muted ? 0.35 : 1
        switch style {
        case .solid, .segmented, .decibel: return AnyShapeStyle(.white.opacity(o))
        case .accent, .glow: return AnyShapeStyle(Self.tint.opacity(o))
        case .gradient:
            return AnyShapeStyle(LinearGradient(
                colors: [.white.opacity(0.45 * o), Self.tint.opacity(o)],
                startPoint: .leading, endPoint: .trailing))
        }
    }

    private func continuous(_ level: Double) -> some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(.white.opacity(0.2))
            // Gradient spans the whole track and is masked, so colors stay put as the level moves.
            Rectangle()
                .fill(fillStyle)
                .mask(alignment: .leading) {
                    Rectangle().frame(width: CGFloat(level) * Self.width)
                }
        }
        .clipShape(Capsule())
    }

    /// Tinted fill with a blurred halo; halo radius and strength grow with the level. Not clipped,
    /// so the glow spills past the 6pt track.
    private func glow(_ level: Double) -> some View {
        let width = max(CGFloat(level) * Self.width, level > 0 ? 6 : 0)
        let strength = state.muted ? 0.15 : 0.25 + 0.6 * level
        return ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.16))
            Capsule()
                .fill(Self.tint)
                .frame(width: width)
                .blur(radius: 2 + 4 * level)
                .opacity(strength)
            Capsule()
                .fill(LinearGradient(colors: [Self.tint.opacity(state.muted ? 0.35 : 0.85),
                                              Self.tint.opacity(state.muted ? 0.35 : 1)],
                                     startPoint: .leading, endPoint: .trailing))
                .overlay(Capsule().fill(.white.opacity(state.muted ? 0 : 0.25 * level)).padding(.vertical, 1.5))
                .frame(width: width)
                .shadow(color: Self.tint.opacity(strength * 0.8), radius: 1 + 3 * level)
        }
    }

    private func segmented(_ level: Double) -> some View {
        let lit = Int((level * Double(Self.segments)).rounded())
        return HStack(spacing: 2) {
            ForEach(0..<Self.segments, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < lit ? fillStyle : AnyShapeStyle(.white.opacity(0.2)))
            }
        }
    }

    static let meterSegments = 22

    /// Level-meter look: thin cells. Volume steps green → yellow → red toward the top of the range
    /// (unlit cells keep a faint zone color); other HUDs are plain white.
    private func decibel(_ level: Double) -> some View {
        let n = Self.meterSegments
        let lit = Int((level * Double(n)).rounded())
        let dim = state.muted ? 0.35 : 1
        return HStack(spacing: 1.5) {
            ForEach(0..<n, id: \.self) { i in
                let zone = zoneColor(i, of: n)
                RoundedRectangle(cornerRadius: 0.75)
                    .fill(i < lit ? zone.opacity(dim) : zone.opacity(state.kind == .volume ? 0.14 : 0.16))
            }
        }
    }

    private func zoneColor(_ i: Int, of n: Int) -> Color {
        guard state.kind == .volume else { return .white }
        let p = (Double(i) + 0.5) / Double(n)
        if p < 0.6 { return Color(red: 0.30, green: 0.85, blue: 0.40) }
        if p < 0.85 { return Color(red: 1.0, green: 0.82, blue: 0.20) }
        return Color(red: 1.0, green: 0.30, blue: 0.25)
    }
}
