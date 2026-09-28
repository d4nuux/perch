import AppKit
import SwiftUI

/// Snapshot of what the lock-screen widgets show. Fed via Combine by `LockScreenService` only while
/// the screen is locked, so the hidden window does no rendering work otherwise.
final class LockScreenWidgetModel: ObservableObject {
    @Published var hasTrack = false
    @Published var title = ""
    @Published var artist = ""
    @Published var isPlaying = false
    @Published var artwork: NSImage?
    @Published var hasBattery = false
    @Published var batteryLevel = 100
    @Published var isCharging = false

    var onCommand: ((String) -> Void)?
}

/// Non-activating, never-key panel. It must never take focus from the login password field.
final class LockScreenPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets media buttons receive the first click even though the window is never key.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// NSVisualEffectView forced active (the window is never key, so `.followsWindowActiveState`
/// would render flat).
struct LockBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct LockCard: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View {
        content
            .background(
                ZStack { LockBlur(); Color.black.opacity(0.35) }
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
    }
}

struct LockScreenWidgetsView: View {
    @ObservedObject var model: LockScreenWidgetModel
    static let width: CGFloat = 360

    var body: some View {
        VStack(spacing: 10) {
            if model.hasBattery { batteryPill }
            if model.hasTrack { nowPlayingCard.transition(.opacity) }
            Spacer(minLength: 0)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(.easeInOut(duration: 0.25), value: model.hasTrack)
        .environment(\.colorScheme, .dark)
    }

    private var batteryPill: some View {
        HStack(spacing: 6) {
            Image(systemName: batterySymbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(model.batteryLevel <= 20 && !model.isCharging ? .red : .white)
            if model.isCharging {
                Image(systemName: "bolt.fill").font(.system(size: 10, weight: .bold)).foregroundColor(.yellow)
            }
            Text("\(model.batteryLevel)%")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundColor(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .modifier(LockCard(radius: 14))
    }

    private var batterySymbol: String {
        switch model.batteryLevel {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }

    private var nowPlayingCard: some View {
        HStack(spacing: 12) {
            Group {
                if let art = model.artwork {
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Color.white.opacity(0.1)
                        Image(systemName: "music.note").font(.system(size: 22)).foregroundColor(.white.opacity(0.6))
                    }
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(model.title).font(.system(size: 14, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                Text(model.artist).font(.system(size: 12)).foregroundColor(.white.opacity(0.65)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 14) {
                control("backward.fill", 14) { model.onCommand?("previous track") }
                control(model.isPlaying ? "pause.fill" : "play.fill", 20) { model.onCommand?("playpause") }
                control("forward.fill", 14) { model.onCommand?("next track") }
            }
        }
        .padding(12)
        .modifier(LockCard(radius: 18))
    }

    private func control(_ symbol: String, _ size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }
}
