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

    var body: some View {
        let open = model.isOpen(on: screen.displayID)
        let notch = screen.notchSize
        let idle = IdleState.resolve(display.idleContent, nowPlaying: nowPlaying, calendar: calendar)
        let size = model.size(notch: notch, expanded: open, idleExtra: idle.extraWidth)
        // Simulated notch (no hardware cutout): flat top flush with the screen edge, pill-round bottom.
        let top: CGFloat = open ? 14 : (screen.isSimulated ? 0 : 6)
        let bottom: CGFloat = open ? 28 : (screen.isSimulated ? min(notch.height / 2, 16) : 12)
        let grow: CGFloat = display.hoverGrow && screen.isHovering && !open ? 1.04 : 1

        ZStack(alignment: .top) {
            NotchShape(topRadius: top, bottomRadius: bottom)
                .fill(Color.black)
                .frame(width: size.width + top * 2, height: size.height)
                .shadow(color: .black.opacity(open ? 0.45 : 0), radius: open ? 18 : 0, y: open ? 8 : 0)

            Group {
                if open {
                    // Laid out at its final size so nothing reflows while the shape springs open.
                    ExpandedView()
                        .frame(width: NotchModel.expandedSize.width, height: NotchModel.expandedSize.height)
                        .transition(Self.expandedTransition)
                } else if let activity = model.activity {
                    ActivityView(activity: activity, notchSize: notch)
                        .transition(Self.collapsedTransition)
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
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(alignment: .leading, spacing: 2) {
                Text(ctx.date, format: .dateTime.weekday(.wide))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                Text(ctx.date, format: .dateTime.hour().minute())
                    .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(ctx.date, format: .dateTime.month(.wide).day())
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
