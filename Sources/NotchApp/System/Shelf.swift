import AppKit

/// Temporary holding area for files dragged onto the notch.
final class Shelf: ObservableObject {
    @Published var items: [URL] = []

    func add(_ url: URL) {
        guard !items.contains(url) else { return }
        items.append(url)
    }

    func remove(_ url: URL) { items.removeAll { $0 == url } }
    func clear() { items.removeAll() }
}
