import AppKit
import SwiftUI

/// Media rows for the Settings window (a Form section). Owner: Media agent.
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
        Picker("Source", selection: $s.source) {
            ForEach(MediaSettings.Source.allCases) { Text($0.label).tag($0) }
        }
        Picker("Extra control (left)", selection: extra(\.extraLeft, other: \.extraRight)) {
            ForEach(MediaSettings.ExtraControl.allCases) { Text($0.label).tag($0) }
        }
        Picker("Extra control (right)", selection: extra(\.extraRight, other: \.extraLeft)) {
            ForEach(MediaSettings.ExtraControl.allCases) { Text($0.label).tag($0) }
        }
        Toggle("Clean up track titles", isOn: $s.cleanTitles)
            .help("Hides tags like “(Remastered 2011)” or “[Official Video]”.")
        Toggle("Tint player with artwork color", isOn: $s.artworkColor)
        Toggle("Hide live activity while the playing app is in front", isOn: $s.hideWhileSourceFrontmost)
        if s.source == .automatic {
            DisclosureGroup("Ignored sources") {
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
                }
            }
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
