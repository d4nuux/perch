import SwiftUI

/// Player shown on the Home tab.
struct MediaPlayer: View {
    @EnvironmentObject var np: NowPlaying
    @ObservedObject private var settings = MediaSettings.shared
    @StateObject private var flip = FlipState()

    private var tint: Color {
        guard settings.artworkColor, let c = np.accentColor else { return .white }
        return Color(nsColor: c)
    }

    /// Changes whenever a new artwork image arrives; drives the crossfade.
    private var artworkID: ObjectIdentifier? { np.artwork.map(ObjectIdentifier.init) }

    var body: some View {
        HStack(spacing: 14) {
            artworkView

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Text(np.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    if np.isExplicit { ExplicitBadge().transition(.opacity) }
                }
                .animation(.easeInOut(duration: 0.2), value: np.isExplicit)
                Text(np.artist).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                MediaProgress(np: np, clock: np.clock, tint: tint)
                controls
            }
        }
        .background(backdrop)
        .onChange(of: np.trackChanges) { _, _ in
            guard settings.artworkFlip else { return }
            withAnimation(.spring(response: 0.6, dampingFraction: 0.78)) { flip.angle += 180 }
        }
    }

    // MARK: Gradient backdrop

    @ViewBuilder
    private var backdrop: some View {
        if settings.artworkStyle == .gradient, let colors = np.backdropColors {
            ZStack {
                LinearGradient(colors: colors.map { Color(nsColor: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing)
                // Fades out to the right so the backdrop blends into the notch; keeps white text readable.
                LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.75)], startPoint: .leading, endPoint: .trailing)
            }
            .opacity(np.isPlaying ? 0.9 : 0.6)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, -10).padding(.vertical, -8)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.6), value: colors)
            .animation(.easeInOut(duration: 0.3), value: np.isPlaying)
        }
    }

    // MARK: Artwork

    private var artworkView: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                if let c = np.accentColor {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(nsColor: c))
                        .frame(width: 84, height: 84)
                        .blur(radius: 20)
                        .opacity(np.isPlaying ? 0.35 : 0.18)
                        .transition(.opacity)
                }
                artworkImage
                    .id(artworkID)
                    .transition(.opacity)
            }
            .animation(.easeInOut(duration: 0.45), value: artworkID)
            .animation(.easeInOut(duration: 0.45), value: np.accentColor)
            .modifier(FlipEffect(angle: flip.angle))
            .scaleEffect(np.isPlaying ? 1 : 0.92)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: np.isPlaying)

            if let icon = np.appIcon {
                Image(nsImage: icon).resizable().frame(width: 22, height: 22).offset(x: 6, y: 6)
            }
        }
    }

    private var artworkImage: some View {
        Group {
            if let art = np.artwork {
                Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                    .grayscale(settings.artworkStyle == .mono ? 1 : 0)
            } else {
                ZStack {
                    Color.white.opacity(0.1)
                    Image(systemName: "music.note").font(.title).foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .frame(width: 84, height: 84)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Controls

    private var controls: some View {
        let extras = settings.extraLeft != .none || settings.extraRight != .none
        return HStack(spacing: 22) {
            if extras { extraButton(settings.extraLeft) }
            control("backward.fill") { np.send("previous track") }
            Button { np.send("playpause") } label: {
                Image(systemName: np.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: np.isPlaying)
            control("forward.fill") { np.send("next track") }
            if extras { extraButton(settings.extraRight) }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func extraButton(_ kind: MediaSettings.ExtraControl) -> some View {
        switch kind {
        case .none:
            Color.clear.frame(width: 18, height: 18)
        case .shuffle:
            toggleControl("shuffle", on: np.shuffle == .on, enabled: np.canShuffle) { np.toggleShuffle() }
        case .repeatMode:
            toggleControl(np.repeatMode == .one ? "repeat.1" : "repeat", on: np.repeatMode == .one || np.repeatMode == .all,
                          enabled: np.canRepeat) { np.cycleRepeat() }
        case .like:
            toggleControl(np.isLiked == true ? "heart.fill" : "heart", on: np.isLiked == true,
                          enabled: np.canLike) { np.toggleLike() }
        case .openSource:
            toggleControl(np.sourceIsBrowser ? "macwindow" : "arrow.up.forward.app", on: false,
                          enabled: !np.sourceBundleID.isEmpty) { np.openSource() }
                .help(np.sourceIsBrowser ? "Show in browser" : "Open app")
        }
    }

    private func toggleControl(_ icon: String, on: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 18, height: 18)
                .foregroundStyle(on ? tint : .white.opacity(0.55))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: icon)
    }

    private func control(_ icon: String, size: CGFloat = 15, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: size)) }.buttonStyle(.plain)
    }
}

/// Seek bar + times. The only part of the player that observes the 1 s position tick.
struct MediaProgress: View {
    let np: NowPlaying
    @ObservedObject var clock: PlaybackClock
    let tint: Color
    @ObservedObject private var settings = MediaSettings.shared
    @StateObject private var scrub = ScrubState()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SeekBar(fraction: np.duration > 0 ? min(clock.position / np.duration, 1) : 0,
                    tint: tint, enabled: np.canSeek, scrub: scrub) { f in
                np.seek(to: f * np.duration)
            }
            timeRow
        }
    }

    private var timeRow: some View {
        let pos = scrub.fraction.map { $0 * np.duration } ?? clock.position
        return HStack {
            Text(fmt(pos))
            Spacer()
            Text(settings.showRemaining ? "-" + fmt(max(np.duration - pos, 0)) : fmt(np.duration))
                .contentShape(Rectangle())
                .onTapGesture { settings.showRemaining.toggle() }
        }
        .font(.system(size: 10)).monospacedDigit().foregroundStyle(.white.opacity(0.5))
    }

    private func fmt(_ s: Double) -> String {
        let t = Int(s.isFinite ? max(s, 0) : 0)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
                         : String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// Local UI state for scrubbing (no @State: Command Line Tools lack the SwiftUI macro plugin).
final class ScrubState: ObservableObject {
    /// Fraction under the finger while dragging, nil otherwise.
    @Published var fraction: Double?
    @Published var hovering = false
}

/// Progress bar; click or drag to seek.
struct SeekBar: View {
    let fraction: Double
    let tint: Color
    let enabled: Bool
    @ObservedObject var scrub: ScrubState
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let f = scrub.fraction ?? fraction
            let active = enabled && (scrub.hovering || scrub.fraction != nil)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                Capsule().fill(tint).frame(width: w * f)
            }
            .frame(height: active ? 6 : 4)
            .animation(scrub.fraction == nil ? .linear(duration: 1) : nil, value: fraction)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: active)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { scrub.hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        guard enabled else { return }
                        scrub.fraction = min(max(v.location.x / w, 0), 1)
                    }
                    .onEnded { v in
                        guard enabled else { return }
                        onSeek(min(max(v.location.x / w, 0), 1))
                        scrub.fraction = nil
                    }
            )
        }
        .frame(height: 12)
    }
}

/// Rotation of the artwork's flip; grows by 180° per track change.
final class FlipState: ObservableObject {
    @Published var angle: Double = 0
}

/// Y-axis flip. Past 90° the content is mirrored back so the artwork never shows reversed.
struct FlipEffect: ViewModifier, Animatable {
    var angle: Double
    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: cos(angle * .pi / 180) < 0 ? -1 : 1, y: 1)
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
    }
}

/// Small outlined "E" shown after explicit track titles.
struct ExplicitBadge: View {
    var size: CGFloat = 9

    var body: some View {
        Text("E")
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(.white.opacity(0.55))
            .frame(width: size + 4, height: size + 4)
            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).stroke(.white.opacity(0.55), lineWidth: 1))
            .fixedSize()
            .accessibilityLabel("Explicit")
            .help("Explicit")
    }
}
