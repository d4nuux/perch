import SwiftUI

/// Collapsed "live activity": app icon on the left of the notch, equalizer on the right.
struct CollapsedActivity: View {
    @EnvironmentObject var nowPlaying: NowPlaying
    let notchWidth: CGFloat

    var body: some View {
        HStack {
            if let art = nowPlaying.artwork ?? nowPlaying.appIcon {
                Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            Spacer(minLength: notchWidth)
            Equalizer().frame(width: 18, height: 12)
        }
        .padding(.horizontal, 12)
    }
}

struct Equalizer: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let h = 0.35 + 0.65 * abs(sin(t * (3.1 + Double(i) * 1.3) + Double(i)))
                    Capsule().fill(Color.green).frame(width: 2.5).scaleEffect(y: h, anchor: .bottom)
                }
            }
        }
    }
}

