import Foundation

/// Media preferences (UserDefaults-backed). Owner: Media agent.
final class MediaSettings: ObservableObject {
    static let shared = MediaSettings()
    private let d = UserDefaults.standard

    enum Source: String, CaseIterable, Identifiable {
        case automatic, music, spotify
        var id: String { rawValue }
        var label: String {
            switch self {
            case .automatic: "Automatic"
            case .music: "Apple Music only"
            case .spotify: "Spotify only"
            }
        }
    }

    enum ExtraControl: String, CaseIterable, Identifiable {
        case none, shuffle, repeatMode, like, openSource
        var id: String { rawValue }
        var label: String {
            switch self {
            case .none: "None"
            case .shuffle: "Shuffle"
            case .repeatMode: "Repeat"
            case .like: "Favorite"
            case .openSource: "Open source app"
            }
        }
    }

    enum ArtworkStyle: String, CaseIterable, Identifiable {
        case full, gradient, mono
        var id: String { rawValue }
        var label: String {
            switch self {
            case .full: "Full artwork"
            case .gradient: "Artwork gradient"
            case .mono: "Monochrome"
            }
        }
    }

    @Published var source: Source { didSet { d.set(source.rawValue, forKey: "media.source") } }
    /// Bundle ids whose media is never shown (Automatic source only).
    @Published var ignoredSources: Set<String> { didSet { d.set(Array(ignoredSources), forKey: "media.ignored") } }
    /// Sources seen playing, offered in the ignore list.
    @Published private(set) var knownSources: [String] { didSet { d.set(knownSources, forKey: "media.known") } }
    @Published var cleanTitles: Bool { didSet { d.set(cleanTitles, forKey: "media.cleanTitles") } }
    /// Ignore browser media that has no artist (Instagram reels, muted autoplay, ads): real music and
    /// YouTube videos always report an artist or channel.
    @Published var hideUntitledWebMedia: Bool { didSet { d.set(hideUntitledWebMedia, forKey: "media.hideUntitledWebMedia") } }
    @Published var artworkColor: Bool { didSet { d.set(artworkColor, forKey: "media.artworkColor") } }
    @Published var hideWhileSourceFrontmost: Bool { didSet { d.set(hideWhileSourceFrontmost, forKey: "media.hideFrontmost") } }
    @Published var extraLeft: ExtraControl { didSet { d.set(extraLeft.rawValue, forKey: "media.extraLeft") } }
    @Published var extraRight: ExtraControl { didSet { d.set(extraRight.rawValue, forKey: "media.extraRight") } }
    @Published var showRemaining: Bool { didSet { d.set(showRemaining, forKey: "media.showRemaining") } }
    /// full: artwork as is; gradient: adds an artwork-colored backdrop behind the expanded player;
    /// mono: grayscale artwork and no color tint.
    @Published var artworkStyle: ArtworkStyle { didSet { d.set(artworkStyle.rawValue, forKey: "media.artworkStyle") } }
    /// 3D flip of the artwork when the track changes.
    @Published var artworkFlip: Bool { didSet { d.set(artworkFlip, forKey: "media.artworkFlip") } }
    /// "E" badge next to explicit tracks (MediaRemote flag if the source sets it, else iTunes Search lookup).
    @Published var explicitBadge: Bool { didSet { d.set(explicitBadge, forKey: "media.explicitBadge") } }

    var extraControls: [ExtraControl] { [extraLeft, extraRight].filter { $0 != .none } }

    private init() {
        d.register(defaults: [
            "media.source": Source.automatic.rawValue, "media.cleanTitles": true, "media.hideUntitledWebMedia": true, "media.artworkColor": true,
            "media.hideFrontmost": false, "media.extraLeft": ExtraControl.none.rawValue,
            "media.extraRight": ExtraControl.none.rawValue, "media.showRemaining": false,
            "media.artworkStyle": ArtworkStyle.full.rawValue, "media.artworkFlip": true, "media.explicitBadge": true,
        ])
        source = Source(rawValue: d.string(forKey: "media.source") ?? "") ?? .automatic
        ignoredSources = Set(d.stringArray(forKey: "media.ignored") ?? [])
        knownSources = d.stringArray(forKey: "media.known") ?? []
        cleanTitles = d.bool(forKey: "media.cleanTitles")
        hideUntitledWebMedia = d.bool(forKey: "media.hideUntitledWebMedia")
        artworkColor = d.bool(forKey: "media.artworkColor")
        hideWhileSourceFrontmost = d.bool(forKey: "media.hideFrontmost")
        extraLeft = ExtraControl(rawValue: d.string(forKey: "media.extraLeft") ?? "") ?? .none
        extraRight = ExtraControl(rawValue: d.string(forKey: "media.extraRight") ?? "") ?? .none
        showRemaining = d.bool(forKey: "media.showRemaining")
        artworkStyle = ArtworkStyle(rawValue: d.string(forKey: "media.artworkStyle") ?? "") ?? .full
        artworkFlip = d.bool(forKey: "media.artworkFlip")
        explicitBadge = d.bool(forKey: "media.explicitBadge")
    }

    func noteSource(_ bundleID: String) {
        guard !bundleID.isEmpty, !knownSources.contains(bundleID) else { return }
        knownSources = Array((knownSources + [bundleID]).suffix(16))
    }
}
