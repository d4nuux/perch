import SwiftUI

// Animated "3D" visuals for live activities (ActivitySettings.animatedVisuals).
// Every animation here is one-shot, started from onAppear; nothing repeats, so once a peek has
// settled SwiftUI renders no further frames. Callers give each visual an `.id` per presentation
// so a new peek re-runs its entrance while an in-place update (same id) doesn't.

// MARK: Device

/// SF Symbol for a Bluetooth device, with a Y-axis swing-in entrance and one specular sweep.
struct DeviceVisual: View {
    let kind: BluetoothMonitor.Kind
    var tint: Color = .white
    var entrance = true
    /// A soft pulse in `tint` after the entrance (low battery).
    var pulse = false

    var body: some View {
        let symbol = Image(systemName: kind.symbol)
            .font(.system(size: ActivityViews.symbolSize + 0.5, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .fixedSize()
        Group {
            if entrance {
                symbol.modifier(Entrance(pulse: pulse ? tint : nil))
            } else {
                symbol
            }
        }
        .frame(width: 22, height: 18)
    }
}

private final class EntranceState: ObservableObject {
    @Published var settled = false
    @Published var sweep: CGFloat = 0
    @Published var sweepDone = false
    @Published var pulseTrigger = 0
}

/// Swing from -70° about Y with a spring and a slight scale-up; a highlight band masked to the
/// content crosses once, then the overlay is removed.
private struct Entrance: ViewModifier {
    let pulse: Color?
    @StateObject private var s = EntranceState()

    func body(content: Content) -> some View {
        content
            .opacity(s.sweepDone ? 1 : 0.8)
            .overlay {
                if !s.sweepDone {
                    SpecularBand(progress: s.sweep)
                        .blendMode(.plusLighter)
                        .mask(content)
                        .allowsHitTesting(false)
                }
            }
            .keyframeAnimator(initialValue: CGFloat(0), trigger: s.pulseTrigger) { view, glow in
                view
                    .scaleEffect(1 + 0.08 * glow)
                    .shadow(color: (pulse ?? .clear).opacity(0.85 * glow), radius: 5 * glow)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(1, duration: 0.3)
                    CubicKeyframe(0, duration: 0.45)
                    CubicKeyframe(0.6, duration: 0.3)
                    CubicKeyframe(0, duration: 0.5)
                }
            }
            .scaleEffect(s.settled ? 1 : 0.8)
            .rotation3DEffect(.degrees(s.settled ? 0 : -70), axis: (x: 0, y: 1, z: 0),
                              anchor: .center, perspective: 0.55)
            .opacity(s.settled ? 1 : 0)
            .onAppear(perform: start)
    }

    private func start() {
        guard !s.settled else { return }
        withAnimation(.spring(response: 0.55, dampingFraction: 0.62)) { s.settled = true }
        withAnimation(.easeInOut(duration: 0.75).delay(0.1)) {
            s.sweep = 1
        } completion: {
            withAnimation(.easeOut(duration: 0.2)) { s.sweepDone = true }
            if pulse != nil { s.pulseTrigger += 1 }
        }
    }
}

/// A diagonal white highlight band; `progress` 0 = off the leading edge, 1 = off the trailing edge.
private struct SpecularBand: View {
    let progress: CGFloat

    var body: some View {
        GeometryReader { g in
            let band = max(g.size.width, g.size.height) * 0.7
            LinearGradient(stops: [.init(color: .white.opacity(0), location: 0),
                                   .init(color: .white.opacity(0.95), location: 0.5),
                                   .init(color: .white.opacity(0), location: 1)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: band, height: g.size.height * 2)
                .rotationEffect(.degrees(18))
                .offset(x: -band + progress * (g.size.width + band), y: -g.size.height / 2)
        }
    }
}

// MARK: Battery

private final class BatteryState: ObservableObject {
    @Published var filled = false
    @Published var boltTrigger = 0
    @Published var pulseTrigger = 0
}

/// Drawn battery: fills from empty to `level` on appear; optional bolt that pulses once, and an
/// optional soft pulse in `tint` (low battery).
struct BatteryVisual: View {
    let level: Int
    let tint: Color
    var bolt = false
    var pulse = false
    @StateObject private var s = BatteryState()

    private static let size = CGSize(width: 23, height: 11.5)

    var body: some View {
        let w = Self.size.width, h = Self.size.height
        let frac = CGFloat(min(max(level, 0), 100)) / 100
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.4, style: .continuous)
                    .strokeBorder(.white.opacity(0.45), lineWidth: 1)
                RoundedRectangle(cornerRadius: 1.8, style: .continuous)
                    .fill(tint)
                    .frame(width: max(1.5, (w - 4) * (s.filled ? frac : 0)), height: h - 4)
                    .padding(.leading, 2)
            }
            .frame(width: w, height: h)
            RoundedRectangle(cornerRadius: 0.8).fill(.white.opacity(0.45)).frame(width: 1.6, height: 4)
        }
        .overlay {
            if bolt {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 8.5, weight: .black))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: 0.6)
                    .keyframeAnimator(initialValue: CGFloat(1), trigger: s.boltTrigger) { v, scale in
                        v.scaleEffect(scale)
                    } keyframes: { _ in
                        KeyframeTrack {
                            SpringKeyframe(1.5, duration: 0.22, spring: .snappy)
                            SpringKeyframe(1, duration: 0.45, spring: .bouncy)
                        }
                    }
                    .offset(x: -1.3)
            }
        }
        .keyframeAnimator(initialValue: CGFloat(0), trigger: s.pulseTrigger) { v, glow in
            v.shadow(color: tint.opacity(0.9 * glow), radius: 5 * glow)
                .scaleEffect(1 + 0.06 * glow)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(1, duration: 0.3)
                CubicKeyframe(0, duration: 0.45)
                CubicKeyframe(0.6, duration: 0.3)
                CubicKeyframe(0, duration: 0.5)
            }
        }
        .fixedSize()
        .onAppear(perform: start)
    }

    private func start() {
        guard !s.filled else { return }
        withAnimation(.spring(response: 0.7, dampingFraction: 0.86).delay(0.12)) {
            s.filled = true
        } completion: {
            if bolt { s.boltTrigger += 1 }
            if pulse { s.pulseTrigger += 1 }
        }
    }
}

// MARK: AirPods left / right / case

private final class AppearState: ObservableObject {
    @Published var shown = false
}

/// "L 80%   R 78%   Case 45%" row under the notch, fading in left to right once.
struct BudsBatteryRow: View {
    let kind: BluetoothMonitor.Kind
    let buds: BluetoothMonitor.Buds
    @StateObject private var s = AppearState()

    private var items: [(symbol: String, level: Int)] {
        let pro = kind == .airpodsPro
        var out: [(String, Int)] = []
        if let l = buds.left { out.append((pro ? "airpodpro.left" : "airpod.left", l)) }
        if let r = buds.right { out.append((pro ? "airpodpro.right" : "airpod.right", r)) }
        if let c = buds.chargingCase {
            out.append((pro ? "airpodspro.chargingcase.wireless" : "airpods.chargingcase", c))
        }
        return out
    }

    var body: some View {
        HStack(spacing: 16) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                HStack(spacing: 4) {
                    Image(systemName: item.symbol)
                        .font(.system(size: 11, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                    Text("\(item.level)%")
                        .font(.system(size: 11, weight: .medium)).monospacedDigit()
                }
                .foregroundStyle(item.level <= ActivitySettings.deviceLowThreshold
                                 ? ActivityViews.low : .white.opacity(0.8))
                .fixedSize()
                .opacity(s.shown ? 1 : 0)
                .offset(y: s.shown ? 0 : -4)
                .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(0.15 + Double(i) * 0.07),
                           value: s.shown)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 6)
        .onAppear { s.shown = true }
    }
}
