import SwiftUI
import UniformTypeIdentifiers

struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let t = topRadius, b = bottomRadius
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY), control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b), control: CGPoint(x: r.maxX - t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - t, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// The notch outline without its top edge (which sits on the screen edge), for the contrast stroke.
struct NotchOutline: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let t = topRadius, b = bottomRadius
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY), control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b), control: CGPoint(x: r.maxX - t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - t, y: r.minY))
        return p
    }
}

/// Behind-window blur for the open notch's soft bottom edge. Only instantiated while open with
/// the setting on; the WindowServer does the blurring.
struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.blendingMode = .behindWindow
        v.material = .hudWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Page dots for the swipe-to-cycle activity list.
struct PageDots: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(Color.white.opacity(i == index ? 0.9 : 0.3))
                    .frame(width: 4, height: 4)
            }
        }
        .animation(NotchModel.cycleAnimation, value: index)
    }
}

struct NotchView: View {
    @EnvironmentObject var model: NotchModel
    @EnvironmentObject var nowPlaying: NowPlaying
    @EnvironmentObject var shelf: Shelf
    @EnvironmentObject var calendar: CalendarService
    @EnvironmentObject var display: DisplaySettings
    @EnvironmentObject var screen: NotchScreen

    /// Content appears once the shape has started growing (~80ms), and leaves quickly on close.
    static let expandedTransition = AnyTransition.asymmetric(
        insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .top))
            .animation(.spring(response: 0.34, dampingFraction: 0.86).delay(0.08)),
        removal: .opacity.animation(.easeIn(duration: 0.09))
    )
    static let collapsedTransition = AnyTransition.asymmetric(
        insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.1)),
        removal: .opacity.animation(.easeIn(duration: 0.1))
    )
    /// Swipe-to-cycle: `direction` +1 = next (enters from the trailing side), -1 = previous.
    static func cycleTransition(_ direction: Int) -> AnyTransition {
        let next = direction > 0
        return .asymmetric(
            insertion: .move(edge: next ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: next ? .leading : .trailing).combined(with: .opacity)
        )
    }
    /// Height of the open notch's soft bottom edge (drawn below the content, outside `size`).
    static let softEdgeHeight: CGFloat = 26
    static let outlineColor = Color.white.opacity(0.18)

    var body: some View {
        let open = model.isOpen(on: screen.displayID)
        let notch = screen.notchSize
        let idle = IdleState.resolve(display.idleContent, nowPlaying: nowPlaying, calendar: calendar)
        let size = model.size(notch: notch, expanded: open, idleExtra: idle.extraWidth)
        // Simulated notch (no hardware cutout): flat top flush with the screen edge, pill-round bottom.
        let top: CGFloat = open ? 14 : (screen.isSimulated ? 0 : 6)
        let bottom: CGFloat = open ? 28 : (screen.isSimulated ? min(notch.height / 2, 16) : 12)
        let grow: CGFloat = display.hoverGrow && screen.isHovering && !open ? 1.04 : 1
        let soft = open && display.progressiveBlur
        // With the soft edge the shape extends below the content and fades out over that strip.
        let shapeHeight = size.height + (soft ? Self.softEdgeHeight : 0)
        let shapeWidth = size.width + top * 2

        ZStack(alignment: .top) {
            if soft {
                BehindWindowBlur()
                    .clipShape(NotchShape(topRadius: top, bottomRadius: bottom))
                    .mask(softEdgeMask(height: shapeHeight))
                    .frame(width: shapeWidth, height: shapeHeight)
                    .transition(.opacity)
            }
            NotchShape(topRadius: top, bottomRadius: bottom)
                .fill(Color.black)
                .frame(width: shapeWidth, height: shapeHeight)
                .mask(softEdgeMask(height: shapeHeight, enabled: soft))
                .shadow(color: .black.opacity(open && !soft ? 0.45 : 0), radius: open ? 18 : 0, y: open ? 8 : 0)
            if display.contrastOutline {
                NotchOutline(topRadius: top, bottomRadius: bottom)
                    .stroke(Self.outlineColor, lineWidth: 1)
                    .frame(width: shapeWidth, height: shapeHeight)
                    .mask(softEdgeMask(height: shapeHeight, enabled: soft))
                    .allowsHitTesting(false)
            }

            Group {
                if open {
                    // Laid out at its final size so nothing reflows while the shape springs open.
                    ExpandedView()
                        .frame(width: NotchModel.expandedSize.width, height: NotchModel.expandedSize.height)
                        .transition(Self.expandedTransition)
                } else if let activity = model.activity {
                    ActivityView(activity: activity, notchSize: notch)
                        .id(activity.key)
                        .transition(model.cycleDirection == 0
                                    ? Self.collapsedTransition : Self.cycleTransition(model.cycleDirection))
                } else {
                    switch idle {
                    case .nowPlaying:
                        CollapsedActivity(notchWidth: notch.width).transition(Self.collapsedTransition)
                    case .event(let e):
                        CollapsedEventView(event: e, notchWidth: notch.width).transition(Self.collapsedTransition)
                    case .none:
                        EmptyView()
                    }
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipped()
            .overlay(alignment: .bottom) {
                if !open, model.showsPageDots, let i = model.cycleIndex {
                    PageDots(count: model.recentActivities.count, index: i)
                        .frame(height: NotchModel.pageDotsHeight, alignment: .top)
                        .transition(.opacity)
                }
            }
        }
        .scaleEffect(grow, anchor: .top)
        .contentShape(Rectangle())
        .onTapGesture { if !open { model.open(on: screen.displayID) } }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onDrop(of: [.fileURL], isTargeted: $model.dropTargeted) { providers in
            model.tab = .shelf
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { shelf.add(url) } }
                }
            }
            return true
        }
        .onChange(of: model.dropTargeted) { _, targeted in
            if targeted { model.tab = .shelf }
        }
    }
}

extension NotchView {
    /// Opaque down to just above the content's bottom edge, then fades to clear over the soft
    /// edge strip. Fully opaque when `enabled` is false (so toggling doesn't swap view types).
    func softEdgeMask(height: CGFloat, enabled: Bool = true) -> LinearGradient {
        let fadeStart = enabled ? max(0, (height - Self.softEdgeHeight - 8) / max(height, 1)) : 1
        return LinearGradient(stops: [
            .init(color: .black, location: 0),
            .init(color: .black, location: fadeStart),
            .init(color: .black.opacity(enabled ? 0.55 : 1), location: enabled ? (fadeStart + 1) / 2 : 1),
            .init(color: .black.opacity(enabled ? 0 : 1), location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }
}

/// Renders a `LiveActivity` around the closed notch.
struct ActivityView: View {
    let activity: LiveActivity
    let notchSize: CGSize

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                activity.leading.frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: notchSize.width)
                activity.trailing.frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .frame(height: notchSize.height)
            if let below = activity.below {
                below.frame(height: activity.belowHeight)
            }
        }
        .foregroundStyle(.white)
    }
}

struct ExpandedView: View {
    @EnvironmentObject var model: NotchModel
    @EnvironmentObject var screen: NotchScreen

    var body: some View {
        VStack(spacing: 12) {
            Header()
            // Fixed-size slot + crossfade: switching tabs never changes the layout around it.
            ZStack(alignment: .top) {
                switch model.tab {
                case .home: HomeTab().transition(.opacity)
                case .calendar: CalendarTab().transition(.opacity)
                case .shelf: ShelfTab().transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.top, max(screen.notchSize.height - 24, 6))
        .padding(.horizontal, 22)
        .padding(.bottom, 16)
        .frame(maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.white)
        .overlay(alignment: .bottom) {
            // Volume / brightness while open: a floating pill instead of the system OSD.
            if let a = model.activity, a.key.hasPrefix("hud.") {
                HStack(spacing: 12) { a.leading; a.trailing }
                    .padding(.horizontal, 16)
                    .frame(height: 34)
                    .background(Capsule().fill(Color(white: 0.14)))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
                    .shadow(color: .black.opacity(0.5), radius: 8, y: 2)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}

struct Header: View {
    @EnvironmentObject var model: NotchModel
    @EnvironmentObject var battery: Battery
    @EnvironmentObject var screen: NotchScreen

    var body: some View {
        HStack(spacing: 6) {
            TabButton(icon: "house.fill", selected: model.tab == .home) { select(.home) }
            TabButton(icon: "calendar", selected: model.tab == .calendar) { select(.calendar) }
            TabButton(icon: "tray.fill", selected: model.tab == .shelf) { select(.shelf) }
            Spacer(minLength: screen.notchSize.width)
            if battery.hasBattery {
                HStack(spacing: 4) {
                    Text("\(battery.level)%").font(.system(size: 11, weight: .medium)).monospacedDigit()
                    Image(systemName: battery.isCharging ? "battery.100.bolt" : batterySymbol)
                        .foregroundStyle(battery.level <= 20 && !battery.isCharging ? .red : .white)
                }
            }
            Button { SettingsWindow.show() } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.5))
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.5))
        }
        .frame(height: 24)
    }

    private func select(_ tab: NotchModel.Tab) {
        withAnimation(NotchModel.tabAnimation) { model.tab = tab }
    }

    private var batterySymbol: String {
        switch battery.level {
        case 88...: "battery.100"
        case 63..<88: "battery.75"
        case 38..<63: "battery.50"
        case 13..<38: "battery.25"
        default: "battery.0"
        }
    }
}

struct TabButton: View {
    let icon: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 22)
                .background(Capsule().fill(.white.opacity(selected ? 0.18 : 0)))
                .foregroundStyle(.white.opacity(selected ? 1 : 0.5))
        }
        .buttonStyle(.plain)
    }
}

struct HomeTab: View {
    @EnvironmentObject var nowPlaying: NowPlaying

    var body: some View {
        HStack(spacing: 18) {
            if nowPlaying.hasTrack { MediaPlayer() } else { idle }
            Divider().overlay(.white.opacity(0.15))
            ClockCard().frame(width: 150)
        }
        .frame(maxHeight: .infinity)
    }

    private var idle: some View {
        HStack(spacing: 10) {
            Image(systemName: "music.note").font(.title2).foregroundStyle(.white.opacity(0.4))
            Text("Nothing playing").foregroundStyle(.white.opacity(0.5))
            Spacer()
        }
    }
}

struct ClockCard: View {
    var body: some View {
        TimelineView(.everyMinute) { ctx in
            VStack(alignment: .leading, spacing: 2) {
                Text(ctx.date, format: .dateTime.weekday(.wide))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                // AM/PM as a small suffix so the time fits the card instead of truncating.
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(ctx.date, format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                        .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                    AMPMLabel(date: ctx.date)
                }
                .lineLimit(1).minimumScaleFactor(0.6)
                Text(ctx.date, format: .dateTime.month(.wide).day())
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// "AM"/"PM" alone (empty on 24-hour locales).
private struct AMPMLabel: View {
    let date: Date
    var body: some View {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("j")
        let is12h = f.dateFormat.contains("a")
        f.dateFormat = "a"
        return Text(is12h ? f.string(from: date) : "")
            .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6))
    }
}

struct ShelfTab: View {
    @EnvironmentObject var shelf: Shelf

    var body: some View {
        Group {
            if shelf.items.isEmpty {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                    .foregroundStyle(.white.opacity(0.25))
                    .overlay(
                        VStack(spacing: 6) {
                            Image(systemName: "tray.and.arrow.down").font(.title2)
                            Text("Drop files here").font(.system(size: 12))
                        }
                        .foregroundStyle(.white.opacity(0.5))
                    )
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(shelf.items, id: \.self) { ShelfItem(url: $0) }
                    }
                }
                .overlay(alignment: .topTrailing) {
                    Button("Clear") { shelf.clear() }
                        .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

struct ShelfItem: View {
    @EnvironmentObject var shelf: Shelf
    let url: URL
    @StateObject private var hover = HoverState()
    private var hovering: Bool { hover.value }

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().frame(width: 52, height: 52)
            Text(url.lastPathComponent).font(.system(size: 10)).lineLimit(1).truncationMode(.middle)
        }
        .frame(width: 78)
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(hovering ? 0.1 : 0)))
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button { shelf.remove(url) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .onHover { hover.value = $0 }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
    }
}

final class HoverState: ObservableObject {
    @Published var value = false
}
