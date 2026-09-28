import AppKit
import SwiftUI

/// Snapshot of what the lock-screen widgets show. Fed via Combine by `LockScreenService` only while
/// the widgets are showing, so the hidden window does no rendering work otherwise.
final class LockScreenWidgetModel: ObservableObject {
    // Layout / style
    @Published var order: [LockWidget] = LockWidget.allCases
    @Published var enabled: Set<LockWidget> = []
    @Published var style: LockCardStyle = .frosted
    /// Measured height of the widget stack; the service sizes the window to it.
    @Published var contentHeight: CGFloat = 0

    // Now playing
    @Published var hasTrack = false
    @Published var title = ""
    @Published var artist = ""
    @Published var isPlaying = false
    @Published var artwork: NSImage?
    @Published var position: Double = 0
    @Published var duration: Double = 0
    /// Scrub fraction (0...1) while the user drags the scrubber.
    @Published var scrub: Double?
    /// Output volume 0...1; nil hides the slider (no settable volume).
    @Published var volume: Float?

    // Battery
    @Published var hasBattery = false
    @Published var batteryLevel = 100
    @Published var isCharging = false

    // Others
    @Published var weather: WeatherSnapshot?
    @Published var nextEvent: LockEvent?
    @Published var devices: [LockBTDevice] = []

    var onCommand: ((String) -> Void)?
    var onSeek: ((Double) -> Void)?
    var onVolume: ((Float) -> Void)?
}

/// Non-activating, never-key panel. It must never take focus from the login password field.
final class LockScreenPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets controls receive the first click even though the window is never key.
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
    let style: LockCardStyle

    func body(content: Content) -> some View {
        content
            .background(background.clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous)))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.white.opacity(style == .solid ? 0.06 : 0.08), lineWidth: 1)
            )
    }

    @ViewBuilder private var background: some View {
        switch style {
        case .frosted: ZStack { LockBlur(); Color.black.opacity(0.35) }
        case .clear: Color.black.opacity(0.25)
        case .solid: Color(white: 0.08)
        }
    }
}

private struct LockHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Thin draggable track (a native NSSlider may not track in a never-key window). Drag state
/// lives in the caller's model: the toolchain rule forbids SwiftUI @State.
struct LockSlider: View {
    let value: Double
    var height: CGFloat = 4
    let onDrag: (Double) -> Void
    let onEnd: (Double) -> Void

    var body: some View {
        GeometryReader { g in
            let w = max(g.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.2))
                Capsule().fill(Color.white.opacity(0.9)).frame(width: w * min(max(value, 0), 1))
            }
            .frame(height: height)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { onDrag(min(max($0.location.x / w, 0), 1)) }
                    .onEnded { onEnd(min(max($0.location.x / w, 0), 1)) }
            )
        }
        .frame(height: 14)
    }
}

struct LockScreenWidgetsView: View {
    @ObservedObject var model: LockScreenWidgetModel
    static let width: CGFloat = 360

    private let secondary = Color.white.opacity(0.55)

    var body: some View {
        VStack(spacing: 10) {
            ForEach(model.order.filter { model.enabled.contains($0) }) { w in
                widget(w)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: Self.width)
        .background(GeometryReader { g in Color.clear.preference(key: LockHeightKey.self, value: g.size.height) })
        .onPreferenceChange(LockHeightKey.self) { h in
            if abs(h - model.contentHeight) > 0.5 { model.contentHeight = h }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.hasTrack)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private func widget(_ w: LockWidget) -> some View {
        switch w {
        case .nowPlaying: if model.hasTrack { nowPlayingCard.transition(.opacity) }
        case .battery: if model.hasBattery { batteryPill }
        case .weather: if let wx = model.weather { weatherCard(wx) }
        case .nextEvent: if let e = model.nextEvent { eventCard(e) }
        case .bluetooth: if !model.devices.isEmpty { bluetoothCard }
        }
    }

    // MARK: Battery

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
        .modifier(LockCard(radius: 14, style: model.style))
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

    // MARK: Now playing

    private var nowPlayingCard: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Group {
                    if let art = model.artwork {
                        Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            Color.white.opacity(0.1)
                            Image(systemName: "music.note").font(.system(size: 22)).foregroundColor(secondary)
                        }
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title).font(.system(size: 14, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                    Text(model.artist).font(.system(size: 12)).foregroundColor(secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 14) {
                    control("backward.fill", 14) { model.onCommand?("previous track") }
                    control(model.isPlaying ? "pause.fill" : "play.fill", 20) { model.onCommand?("playpause") }
                    control("forward.fill", 14) { model.onCommand?("next track") }
                }
            }
            if model.duration > 0 { scrubber }
            if let v = model.volume { volumeRow(v) }
        }
        .padding(12)
        .modifier(LockCard(radius: 18, style: model.style))
    }

    private var scrubber: some View {
        let fraction = model.scrub ?? (model.duration > 0 ? model.position / model.duration : 0)
        let shown = fraction * model.duration
        return HStack(spacing: 8) {
            Text(Self.time(shown)).frame(width: 38, alignment: .leading)
            LockSlider(value: fraction,
                       onDrag: { model.scrub = $0 },
                       onEnd: { f in
                           model.onSeek?(f * model.duration)
                           model.position = f * model.duration
                           model.scrub = nil
                       })
            Text("-" + Self.time(max(model.duration - shown, 0))).frame(width: 42, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .medium).monospacedDigit())
        .foregroundColor(secondary)
    }

    private func volumeRow(_ v: Float) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill").frame(width: 14)
            LockSlider(value: Double(v),
                       onDrag: { f in model.volume = Float(f); model.onVolume?(Float(f)) },
                       onEnd: { f in model.volume = Float(f); model.onVolume?(Float(f)) })
            Image(systemName: "speaker.wave.3.fill").frame(width: 20)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(secondary)
    }

    private static func time(_ s: Double) -> String {
        let t = Int(max(s, 0).rounded(.down))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
                         : String(format: "%d:%02d", t / 60, t % 60)
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

    // MARK: Weather

    private func weatherCard(_ w: WeatherSnapshot) -> some View {
        HStack(spacing: 10) {
            Image(systemName: w.symbol)
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 22))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.temp(w.temperature)).font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                Text(w.summary).font(.system(size: 11)).foregroundColor(secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text("H \(Self.temp(w.high))  L \(Self.temp(w.low))")
                    .font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundColor(.white)
                if w.precipitationChance >= 0.1 {
                    Label("\(Int((w.precipitationChance * 100).rounded()))%", systemImage: "drop.fill")
                        .font(.system(size: 11)).foregroundColor(secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .modifier(LockCard(radius: 16, style: model.style))
    }

    private static let tempFormatter: MeasurementFormatter = {
        let f = MeasurementFormatter()
        f.unitStyle = .short
        f.numberFormatter.maximumFractionDigits = 0
        return f
    }()

    private static func temp(_ celsius: Double) -> String {
        tempFormatter.string(from: Measurement(value: celsius, unit: UnitTemperature.celsius))
    }

    // MARK: Next event

    private func eventCard(_ e: LockEvent) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(Color(cgColor: e.color)).frame(width: 4, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.title).font(.system(size: 13, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                Text(Self.eventTime(e)).font(.system(size: 11).monospacedDigit()).foregroundColor(secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "calendar").font(.system(size: 13)).foregroundColor(secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .modifier(LockCard(radius: 16, style: model.style))
    }

    private static func eventTime(_ e: LockEvent) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        if e.start <= Date() { return "Now · until \(f.string(from: e.end))" }
        return "\(f.string(from: e.start)) – \(f.string(from: e.end))"
    }

    // MARK: Bluetooth

    private var bluetoothCard: some View {
        HStack(spacing: 6) {
            ForEach(model.devices.prefix(4)) { d in
                VStack(spacing: 3) {
                    Image(systemName: d.symbol).font(.system(size: 16)).foregroundColor(.white).frame(height: 20)
                    Text("\(d.battery)%")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundColor(d.battery <= 20 ? .red : .white)
                    Text(d.name).font(.system(size: 10)).foregroundColor(secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .modifier(LockCard(radius: 16, style: model.style))
    }
}
