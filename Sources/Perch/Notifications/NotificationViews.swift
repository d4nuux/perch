import AppKit
import SwiftUI

/// What one notification live activity shows: a single notification or a burst summary.
enum NotificationPresentation {
    case single(NotificationItem)
    case burst(key: String, items: [NotificationItem]) // newest first

    var key: String {
        switch self {
        case .single(let i): i.key
        case .burst(let key, _): key
        }
    }

    var items: [NotificationItem] {
        switch self {
        case .single(let i): [i]
        case .burst(_, let items): items
        }
    }
}

/// Callbacks from the views back to the service (main thread).
struct NotificationActions {
    var open: (NotificationItem) -> Void = { _ in }
    var copy: (NotificationItem) -> Void = { _ in }
    var dismiss: (String) -> Void = { _ in }
    var hover: (String, Bool) -> Void = { _, _ in }
}

/// Per-item transient UI state shared by all views ("Copied" feedback).
final class NotificationUIState: ObservableObject {
    static let shared = NotificationUIState()
    @Published var copied: Set<Int64> = []
}

/// LiveActivity builders. Keys: "notif.<rec_id>" for one, "notif.burst.<first rec_id>" for a burst.
enum NotificationViews {
    static let compactWidth: CGFloat = 190
    static let expandedWidth: CGFloat = 300
    static let secondary = Color.white.opacity(0.55)

    static func activity(_ p: NotificationPresentation, expanded: Bool, locked: Bool, redact: Bool,
                         actions: NotificationActions) -> LiveActivity {
        let items = p.items
        guard !items.isEmpty else {
            return LiveActivity(key: p.key) { EmptyView() } trailing: { EmptyView() }
        }
        let style = Style(items: items, expanded: expanded && !redact, redact: redact, key: p.key, locked: locked)
        let width = style.expanded ? expandedWidth : compactWidth
        return LiveActivity(key: p.key, extraWidth: width) {
            NotificationLeading(style: style, actions: actions)
        } trailing: {
            NotificationTrailing(style: style, actions: actions)
        }
        .withBelow(height: style.belowHeight) {
            NotificationBelow(style: style, actions: actions)
        }
        .interactive()
    }

    /// Stable tint for a name (avatar background).
    static func tint(for name: String) -> Color {
        var h: UInt32 = 5381
        for b in name.lowercased().utf8 { h = (h &* 33) ^ UInt32(b) }
        let hue = Double(h % 360) / 360
        return Color(hue: hue, saturation: 0.42, brightness: 0.72)
    }

    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(2)
        let s = words.compactMap(\.first).map { String($0).uppercased() }.joined()
        return s.isEmpty ? "?" : s
    }
}

/// Everything the three slots need to agree on.
struct Style {
    let items: [NotificationItem]
    let expanded: Bool
    /// Locked without "previews on lock screen": app name + "New message" only.
    let redact: Bool
    let key: String
    let locked: Bool

    var item: NotificationItem { items[0] }
    var isBurst: Bool { items.count > 1 }
    var accent: Color { item.app.accent.map(Color.init(nsColor:)) ?? .white }

    var belowHeight: CGFloat {
        if redact { return 38 }
        if isBurst {
            return expanded ? 30 + CGFloat(min(items.count, 4)) * 30 + (items.count > 4 ? 16 : 0) + 8 : 44
        }
        let text = expanded ? lines(item.text, perLine: 66, max: 3) : (item.text.isEmpty ? 0 : 1)
        let pill: CGFloat = item.code != nil && !expanded ? 5 : 0
        return pill + kindHeight(text: text)
    }

    private func kindHeight(text: Int) -> CGFloat {
        switch item.kind {
        case .email:
            let subject = item.secondary.isEmpty ? 0 : expanded ? lines(item.secondary, perLine: 60, max: 2) : 1
            return 22 + CGFloat(subject) * 15 + CGFloat(text) * 14 + (expanded ? 40 : 4)
        case .chat:
            return 26 + (text > 0 ? 10 + CGFloat(text) * 14 : 0) + (expanded ? 40 : 4)
        case .generic:
            return 22 + CGFloat(text) * 14 + (expanded ? 40 : 4)
        }
    }

    /// Rough wrapped line count at the expanded width (~66 chars of 11pt per line).
    private func lines(_ s: String, perLine: Int, max m: Int) -> Int {
        s.isEmpty ? 0 : min(m, (s.count + perLine - 1) / perLine)
    }

    /// "email", "message", "notification" (for burst and lock text).
    var noun: String {
        let kinds = Set(items.map(\.kind))
        guard kinds.count == 1 else { return "notification" }
        switch kinds.first! {
        case .email: return "email"
        case .chat: return "message"
        case .generic: return "notification"
        }
    }
}

// MARK: - Slots

struct NotificationLeading: View {
    let style: Style
    let actions: NotificationActions

    var body: some View {
        Group {
            if style.redact {
                AppIcon(image: style.item.app.icon, size: 18)
            } else if style.isBurst {
                StackedAvatars(items: Array(style.items.prefix(3)), size: 18)
            } else if style.item.kind == .generic {
                AppIcon(image: style.item.app.icon, size: 18)
            } else {
                Avatar(name: style.item.primary, size: 20, badge: style.item.app.badge)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { tap(style, actions) }
        .onHover { actions.hover(style.key, $0) }
    }
}

struct NotificationTrailing: View {
    let style: Style
    let actions: NotificationActions

    var body: some View {
        Group {
            if style.redact {
                Image(systemName: "lock.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(NotificationViews.secondary)
            } else if style.isBurst {
                Text("\(style.items.count)")
                    .font(.system(size: 11, weight: .bold)).monospacedDigit()
                    .padding(.horizontal, 6).frame(minWidth: 18, minHeight: 16)
                    .background(Capsule().fill(style.accent.opacity(0.32)))
            } else {
                Image(systemName: glyph)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(style.accent)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { tap(style, actions) }
        .onHover { actions.hover(style.key, $0) }
    }

    private var glyph: String {
        if style.item.code != nil { return "key.fill" }
        switch style.item.kind {
        case .email: return "envelope.fill"
        case .chat: return "bubble.left.fill"
        case .generic: return "bell.fill"
        }
    }
}

struct NotificationBelow: View {
    let style: Style
    let actions: NotificationActions
    @ObservedObject var ui = NotificationUIState.shared

    var body: some View {
        content
            .padding(.horizontal, 16)
            .padding(.top, 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
            .onTapGesture { tap(style, actions) }
            .onHover { actions.hover(style.key, $0) }
            .modifier(Entrance())
    }

    @ViewBuilder private var content: some View {
        if style.redact {
            VStack(alignment: .leading, spacing: 1) {
                Text(style.item.app.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(style.item.kind == .email ? "New message" : "New \(style.noun)")
                    .font(.system(size: 11)).foregroundStyle(NotificationViews.secondary)
            }
        } else if style.isBurst {
            BurstBody(style: style, actions: actions)
        } else {
            switch style.item.kind {
            case .email: EmailBody(style: style, actions: actions, copied: ui.copied.contains(style.item.id))
            case .chat: ChatBody(style: style, actions: actions, copied: ui.copied.contains(style.item.id))
            case .generic: GenericBody(style: style, actions: actions, copied: ui.copied.contains(style.item.id))
            }
        }
    }
}

/// Tap on the activity body: open the source app (not while locked) and dismiss.
private func tap(_ style: Style, _ actions: NotificationActions) {
    if !style.locked, !style.isBurst { actions.open(style.item) }
    if !style.locked, style.isBurst, !style.expanded { actions.open(style.item) }
    actions.dismiss(style.key)
}

// MARK: - Bodies

private struct EmailBody: View {
    let style: Style
    let actions: NotificationActions
    let copied: Bool

    var body: some View {
        let i = style.item
        VStack(alignment: .leading, spacing: 1.5) {
            HStack(spacing: 5) {
                Text(i.primary).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text("· \(i.age())").font(.system(size: 11)).foregroundStyle(NotificationViews.secondary)
                    .fixedSize()
                Spacer(minLength: 4)
                if let code = i.code, !style.expanded {
                    CodePill(code: code, copied: copied, accent: style.accent) { actions.copy(i) }
                } else if let host = i.host {
                    Text(host).font(.system(size: 10)).foregroundStyle(.white.opacity(0.35)).lineLimit(1)
                }
            }
            if !i.secondary.isEmpty {
                Text(i.secondary).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                    .lineLimit(style.expanded ? 2 : 1)
            }
            if !i.text.isEmpty {
                Text(i.text).font(.system(size: 11)).foregroundStyle(NotificationViews.secondary)
                    .lineLimit(style.expanded ? 3 : 1)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if style.expanded {
                Spacer(minLength: 6)
                ActionRow(style: style, actions: actions, copied: copied)
            }
        }
    }
}

private struct ChatBody: View {
    let style: Style
    let actions: NotificationActions
    let copied: Bool

    var body: some View {
        let i = style.item
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(i.primary).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if !i.secondary.isEmpty {
                    Text(i.secondary).font(.system(size: 11)).foregroundStyle(NotificationViews.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let code = i.code, !style.expanded {
                    CodePill(code: code, copied: copied, accent: style.accent) { actions.copy(i) }
                } else {
                    Text(i.age()).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4)).fixedSize()
                }
            }
            if !i.text.isEmpty {
                Text(i.text).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.92))
                    .lineLimit(style.expanded ? 3 : 1)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(
                        UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 11,
                                               bottomTrailingRadius: 11, topTrailingRadius: 11, style: .continuous)
                            .fill(style.accent.opacity(0.16))
                    )
                    .overlay(
                        UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 11,
                                               bottomTrailingRadius: 11, topTrailingRadius: 11, style: .continuous)
                            .strokeBorder(.white.opacity(0.06))
                    )
            }
            if style.expanded {
                Spacer(minLength: 6)
                ActionRow(style: style, actions: actions, copied: copied)
            }
        }
    }
}

private struct GenericBody: View {
    let style: Style
    let actions: NotificationActions
    let copied: Bool

    var body: some View {
        let i = style.item
        VStack(alignment: .leading, spacing: 1.5) {
            HStack(spacing: 5) {
                Text(i.primary).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if !i.secondary.isEmpty {
                    Text(i.secondary).font(.system(size: 11)).foregroundStyle(NotificationViews.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let code = i.code, !style.expanded {
                    CodePill(code: code, copied: copied, accent: style.accent) { actions.copy(i) }
                } else {
                    Text(i.host ?? i.age()).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4)).lineLimit(1)
                }
            }
            if !i.text.isEmpty {
                Text(i.text).font(.system(size: 11)).foregroundStyle(NotificationViews.secondary)
                    .lineLimit(style.expanded ? 3 : 1)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if style.expanded {
                Spacer(minLength: 6)
                ActionRow(style: style, actions: actions, copied: copied)
            }
        }
    }
}

private struct BurstBody: View {
    let style: Style
    let actions: NotificationActions

    var body: some View {
        let items = style.items
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text("\(items.count) new \(style.noun)s").font(.system(size: 12, weight: .semibold))
                if style.expanded {
                    Spacer()
                    IconButton(symbol: "xmark") { actions.dismiss(style.key) }
                }
            }
            if style.expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(items.prefix(4)) { i in
                        BurstRow(item: i) {
                            actions.open(i)
                            actions.dismiss(style.key)
                        }
                    }
                    if items.count > 4 {
                        Text("+\(items.count - 4) more").font(.system(size: 10.5)).foregroundStyle(NotificationViews.secondary)
                            .padding(.leading, 26)
                    }
                }
                .padding(.top, 2)
            } else {
                Text(summary).font(.system(size: 11)).foregroundStyle(NotificationViews.secondary).lineLimit(1)
            }
        }
    }

    private var summary: String {
        var names: [String] = []
        for i in style.items where !names.contains(i.primary) { names.append(i.primary) }
        switch names.count {
        case 0: return ""
        case 1: return "From \(names[0])"
        case 2: return "\(names[0]) and \(names[1])"
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) more"
        }
    }
}

private struct BurstRow: View {
    let item: NotificationItem
    let action: () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        HStack(spacing: 8) {
            if item.kind == .generic {
                AppIcon(image: item.app.icon, size: 18)
            } else {
                Avatar(name: item.primary, size: 18, badge: item.app.badge)
            }
            Text(item.primary).font(.system(size: 11.5, weight: .semibold)).lineLimit(1).layoutPriority(1)
            Text(item.preview).font(.system(size: 11)).foregroundStyle(NotificationViews.secondary).lineLimit(1)
            Spacer(minLength: 4)
            Text(item.age()).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)).fixedSize()
        }
        .frame(height: 30)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(hover.value ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onHover { hover.value = $0 }
        .onTapGesture(perform: action)
        .padding(.horizontal, -6)
    }
}

// MARK: - Pieces

/// Open · Copy code · ✕ under an expanded notification.
private struct ActionRow: View {
    let style: Style
    let actions: NotificationActions
    let copied: Bool

    var body: some View {
        HStack(spacing: 6) {
            PillButton(title: "Open", symbol: "arrow.up.forward.app") {
                actions.open(style.item)
                actions.dismiss(style.key)
            }
            if let code = style.item.code {
                CodePill(code: code, copied: copied, accent: style.accent) { actions.copy(style.item) }
            }
            Spacer()
            IconButton(symbol: "xmark") { actions.dismiss(style.key) }
        }
        .frame(height: 24)
        .padding(.bottom, 8)
    }
}

struct PillButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 10).frame(height: 22)
            .background(Capsule().fill(.white.opacity(hover.value ? 0.2 : 0.12)))
        }
        .buttonStyle(.plain)
        .onHover { hover.value = $0 }
    }
}

struct IconButton: View {
    let symbol: String
    let action: () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9.5, weight: .bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(.white.opacity(hover.value ? 0.2 : 0.1)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.8))
        .onHover { hover.value = $0 }
    }
}

/// "Copy 123456" → "✓ Copied".
struct CodePill: View {
    let code: String
    let copied: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 9.5, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                if copied {
                    Text("Copied").font(.system(size: 11, weight: .semibold))
                } else {
                    Text("Copy ").font(.system(size: 11, weight: .medium))
                        + Text(code).font(.system(size: 11.5, weight: .bold, design: .rounded)).monospacedDigit()
                }
            }
            .foregroundStyle(copied ? Color.green : .white)
            .fixedSize()
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(Capsule().fill((copied ? Color.green : accent).opacity(0.24)))
            .overlay(Capsule().strokeBorder((copied ? Color.green : accent).opacity(0.45), lineWidth: 0.75))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: copied)
    }
}

struct AppIcon: View {
    let image: NSImage
    let size: CGFloat

    var body: some View {
        Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }
}

/// Initials on a name-tinted circle, with the app icon as a small badge at the bottom right.
struct Avatar: View {
    let name: String
    let size: CGFloat
    var badge: NSImage?

    var body: some View {
        Circle()
            .fill(NotificationViews.tint(for: name).gradient)
            .frame(width: size, height: size)
            .overlay(
                Text(NotificationViews.initials(name))
                    .font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
            )
            .overlay(alignment: .bottomTrailing) {
                if let badge {
                    Image(nsImage: badge).resizable().interpolation(.high)
                        .frame(width: size * 0.55, height: size * 0.55)
                        .background(Circle().fill(.black).padding(-1))
                        .offset(x: size * 0.16, y: size * 0.12)
                }
            }
    }
}

struct StackedAvatars: View {
    let items: [NotificationItem]
    let size: CGFloat

    var body: some View {
        let step = size * 0.58
        ZStack(alignment: .leading) {
            ForEach(Array(items.enumerated()).reversed(), id: \.element.id) { n, i in
                Group {
                    if i.kind == .generic {
                        AppIcon(image: i.app.icon, size: size)
                    } else {
                        Circle().fill(NotificationViews.tint(for: i.primary).gradient)
                            .overlay(Text(NotificationViews.initials(i.primary))
                                .font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white))
                    }
                }
                .frame(width: size, height: size)
                .background(Circle().fill(.black).padding(-1.5))
                .offset(x: CGFloat(n) * step)
            }
        }
        .frame(width: size + CGFloat(max(items.count - 1, 0)) * step, height: size, alignment: .leading)
    }
}

/// Slide down + fade on first appearance.
private struct Entrance: ViewModifier {
    @StateObject private var shown = HoverState()

    func body(content: Content) -> some View {
        content
            .opacity(shown.value ? 1 : 0)
            .offset(y: shown.value ? 0 : -6)
            .onAppear {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.82).delay(0.06)) { shown.value = true }
            }
    }
}
