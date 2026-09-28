import SwiftUI

/// Player shown on the Home tab. (Owned by the Media agent.)
struct MediaPlayer: View {
    @EnvironmentObject var np: NowPlaying

    var body: some View {
        HStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let art = np.artwork {
                        Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            Color.white.opacity(0.1)
                            Image(systemName: "music.note").font(.title).foregroundStyle(.white.opacity(0.4))
                        }
                    }
                }
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .scaleEffect(np.isPlaying ? 1 : 0.92)
                .animation(.spring(response: 0.35, dampingFraction: 0.7), value: np.isPlaying)

                if let icon = np.appIcon {
                    Image(nsImage: icon).resizable().frame(width: 22, height: 22).offset(x: 6, y: 6)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(np.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(np.artist).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                GeometryReader { geo in
                    let f = np.duration > 0 ? min(np.position / np.duration, 1) : 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.2))
                        Capsule().fill(.white).frame(width: geo.size.width * f)
                    }
                }
                .frame(height: 4)
                .animation(.linear(duration: 1), value: np.position)
                HStack {
                    Text(fmt(np.position)); Spacer(); Text(fmt(np.duration))
                }
                .font(.system(size: 10)).monospacedDigit().foregroundStyle(.white.opacity(0.5))
                HStack(spacing: 26) {
                    control("backward.fill") { np.send("previous track") }
                    control(np.isPlaying ? "pause.fill" : "play.fill", size: 20) { np.send("playpause") }
                    control("forward.fill") { np.send("next track") }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func control(_ icon: String, size: CGFloat = 15, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: size)) }.buttonStyle(.plain)
    }

    private func fmt(_ s: Double) -> String {
        let t = Int(s.isFinite ? s : 0)
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

