import AppKit

/// Everything a feature service may use. Services are created once at launch on the main thread.
struct NotchContext {
    let model: NotchModel
    let nowPlaying: NowPlaying
    let battery: Battery
    let shelf: Shelf
    let settings: AppSettings
    /// The notch panel itself (for gesture monitors etc.). Don't change its frame or level.
    let panel: NSPanel
}
