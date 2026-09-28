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

    init(kind: HUDKind) { self.kind = kind }
}

struct HUDIcon: View {
    @ObservedObject var state: HUDLevel

    var body: some View {
        let name = state.kind.symbol(level: state.level, muted: state.muted)
        Image(systemName: name)
            .font(.system(size: 13, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 24, height: 20, alignment: .leading)
            .opacity(state.muted ? 0.6 : 1)
            .animation(.snappy(duration: 0.2), value: name)
            .animation(.easeInOut(duration: 0.2), value: state.muted)
    }
}

struct HUDBar: View {
    @ObservedObject var state: HUDLevel
    static let width: CGFloat = 90

    var body: some View {
        let fill = CGFloat(min(max(state.level, 0), 1)) * Self.width
        ZStack(alignment: .leading) {
            Rectangle().fill(.white.opacity(0.2))
            Rectangle()
                .fill(.white.opacity(state.muted ? 0.35 : 1))
                .frame(width: fill)
        }
        .frame(width: Self.width, height: 6)
        .clipShape(Capsule())
        .animation(.spring(response: 0.26, dampingFraction: 0.9), value: state.level)
        .animation(.easeInOut(duration: 0.2), value: state.muted)
    }
}
