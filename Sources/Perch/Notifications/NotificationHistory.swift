import SwiftUI

/// The last mirrored notifications, in memory only (never written to disk).
final class NotificationHistory: ObservableObject {
    static let shared = NotificationHistory()
    static let limit = 20

    /// Newest first.
    @Published private(set) var items: [NotificationItem] = []

    /// `new` oldest first (DB order).
    func add(_ new: [NotificationItem]) {
        let ids = Set(new.map(\.id))
        items = Array((new.reversed() + items.filter { !ids.contains($0.id) }).prefix(Self.limit))
    }

    func remove(_ id: Int64) { items.removeAll { $0.id == id } }
    func clear() { items = [] }

    /// Grouped by app, groups ordered by their newest item.
    var groups: [(app: AppInfo, items: [NotificationItem])] {
        var order: [String] = []
        var map: [String: [NotificationItem]] = [:]
        for i in items {
            if map[i.bundleID] == nil { order.append(i.bundleID) }
            map[i.bundleID, default: []].append(i)
        }
        return order.map { (map[$0]![0].app, map[$0]!) }
    }
}

/// Recent notifications for the expanded notch (dark, fits the 556×~110 tab area). Not wired into
/// NotchView yet; see the Notifications report for the proposed hookup (a fourth tab or a Home section).
struct NotificationHistoryView: View {
    @ObservedObject var history = NotificationHistory.shared
    @ObservedObject var settings = NotificationSettings.shared
    var isLocked = false

    private var redact: Bool { isLocked && !settings.previewsWhenLocked }

    var body: some View {
        if history.items.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "bell.slash").font(.title3).foregroundStyle(.white.opacity(0.4))
                Text("No recent notifications").foregroundStyle(.white.opacity(0.5))
                Spacer()
            }
            .frame(maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Notifications").font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Button("Clear") { history.clear() }
                            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    }
                    ForEach(history.groups, id: \.app.bundleID) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                AppIcon(image: group.app.icon, size: 14)
                                Text(group.app.name).font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.55))
                                Text("\(group.items.count)").font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
                            }
                            if redact {
                                Text(group.items.count == 1 ? "1 new notification" : "\(group.items.count) new notifications")
                                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).padding(.leading, 20)
                            } else {
                                ForEach(group.items) { item in
                                    HistoryRow(item: item) {
                                        item.open()
                                        history.remove(item.id)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }
}

private struct HistoryRow: View {
    let item: NotificationItem
    let action: () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        HStack(spacing: 8) {
            if item.kind == .generic {
                AppIcon(image: item.app.icon, size: 16)
            } else {
                Avatar(name: item.primary, size: 16)
            }
            Text(item.primary).font(.system(size: 11.5, weight: .semibold)).lineLimit(1).layoutPriority(1)
            Text(item.preview).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            Spacer(minLength: 4)
            TimelineView(.everyMinute) { ctx in
                Text(item.age(at: ctx.date)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)).fixedSize()
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(hover.value ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onHover { hover.value = $0 }
        .onTapGesture(perform: action)
        .padding(.leading, 14)
    }
}
