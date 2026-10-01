import AppKit
import SwiftUI

/// Media rows for the Settings window (a Form section).
struct MediaSettingsSection: View {
    @ObservedObject private var s = MediaSettings.shared

    /// Browsers offered in the ignore list even before they've played anything.
    private static let commonSources = ["com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser",
                                        "company.thebrowser.dia", "com.brave.Browser", "com.microsoft.edgemac"]

    private var ignoreCandidates: [String] {
        var seen = Set<String>()
        let installed = Self.commonSources.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
        return (s.knownSources + installed + Array(s.ignoredSources)).filter { seen.insert($0).inserted }
    }

    var body: some View {
        Section {
            SettingPicker("Source", detail: sourceDetail, selection: $s.source) {
                ForEach(MediaSettings.Source.allCases) { Text($0.label).tag($0) }
            }
            if s.source == .automatic {
                DisclosureGroup {
                    ForEach(ignoreCandidates, id: \.self) { id in
                        Toggle(isOn: ignored(id)) {
                            HStack(spacing: 6) {
                                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                        .resizable().frame(width: 16, height: 16)
                                    Text(FileManager.default.displayName(atPath: url.path)
                                        .replacingOccurrences(of: ".app", with: ""))
                                } else {
                                    Text(id)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                } label: {
                    SettingLabel(title: "Ignored sources",
                                 detail: s.ignoredSources.isEmpty ? "Apps whose playback never shows in the notch."
                                                                  : "\(s.ignoredSources.count) ignored")
                }
            }
            SettingToggle("Hide while the playing app is in front",
                          detail: "The Now Playing activity steps aside when you're already looking at the player.",
                          isOn: $s.hideWhileSourceFrontmost)
        } header: {
            SectionHeader("Source")
        }

        Section {
            SettingPicker("Left of the controls", selection: extra(\.extraLeft, other: \.extraRight)) {
                ForEach(MediaSettings.ExtraControl.allCases) { Text($0.label).tag($0) }
            }
            SettingPicker("Right of the controls", selection: extra(\.extraRight, other: \.extraLeft)) {
                ForEach(MediaSettings.ExtraControl.allCases) { Text($0.label).tag($0) }
            }
        } header: {
            SectionHeader("Extra controls")
        } footer: {
            SectionFooter("Shown on either side of play / pause in the open player. Each control can be used once.")
        }

        Section("Artwork") {
            SettingPicker("Style", selection: $s.artworkStyle) {
                ForEach(MediaSettings.ArtworkStyle.allCases) { Text($0.label).tag($0) }
            }
            SettingToggle("Tint player with artwork color",
                          detail: s.artworkStyle == .mono ? "Not available with Monochrome artwork." : nil,
                          isOn: $s.artworkColor)
                .disabled(s.artworkStyle == .mono)
            SettingToggle("Flip artwork on track change", isOn: $s.artworkFlip)
        }

        Section("Track info") {
            SettingToggle("Ignore browser videos without track info",
                          detail: "Skips things like Instagram reels and autoplaying clips that report no artist. "
                              + "Music and YouTube videos still show.",
                          isOn: $s.hideUntitledWebMedia)
            SettingToggle("Clean up track titles", detail: "Hides tags like “(Remastered 2011)” or “[Official Video]”.",
                          isOn: $s.cleanTitles)
            SettingToggle("Show explicit badge",
                          detail: "Uses the player's explicit flag when it reports one, otherwise looks the track up "
                              + "in the iTunes Search API (one request per track, cached).",
                          isOn: $s.explicitBadge)
        }
    }

    private var sourceDetail: String {
        switch s.source {
        case .automatic: "Whatever is playing, from any app or browser."
        case .music: "Only Apple Music."
        case .spotify: "Only Spotify."
        }
    }

    /// Picking the control already in the other slot clears that slot (max 2 distinct extras).
    private func extra(_ kp: ReferenceWritableKeyPath<MediaSettings, MediaSettings.ExtraControl>,
                       other: ReferenceWritableKeyPath<MediaSettings, MediaSettings.ExtraControl>)
        -> Binding<MediaSettings.ExtraControl> {
        Binding(get: { s[keyPath: kp] }, set: { v in
            if v != .none, s[keyPath: other] == v { s[keyPath: other] = .none }
            s[keyPath: kp] = v
        })
    }

    private func ignored(_ id: String) -> Binding<Bool> {
        Binding(get: { s.ignoredSources.contains(id) }, set: { on in
            if on { s.ignoredSources.insert(id) } else { s.ignoredSources.remove(id) }
        })
    }
}
