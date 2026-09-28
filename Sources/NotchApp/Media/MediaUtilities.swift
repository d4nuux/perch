import AppKit

/// Strips release noise ("(Remastered 2011)", "[Official Video]", " - Remastered"…) from titles.
enum TitleCleaner {
    private static let patterns: [NSRegularExpression] = [
        // Bracketed tags: (Remastered 2011) [Official Music Video] (Lyrics) (Audio) [HD] (Visualizer)
        #"\s*[\(\[][^\(\)\[\]]*\b(?:remaster(?:ed)?|official|lyrics?|visuali[sz]er|audio|video|hd|hq|4k|explicit)\b[^\(\)\[\]]*[\)\]]"#,
        // " - Remastered", " - 2011 Remaster", " - Remastered 2009 Version"
        #"\s+[-–—]\s+(?:\d{4}\s+)?(?:digital(?:ly)?\s+)?remaster(?:ed)?(?:\s+\d{4})?(?:\s+(?:version|edition|mix))?\s*$"#,
        // " - Official Video", " | Official Audio"
        #"\s+[-–—|]\s+official\s+(?:music\s+|lyric\s+)?(?:video|audio)\s*$"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    static func clean(_ title: String) -> String {
        var s = title
        for re in patterns {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        s = s.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? title : s
    }
}

/// Accent color from artwork: downsample to 8x8 and take the most saturated usable pixel.
enum ArtworkColor {
    static func accent(for image: NSImage) -> NSColor? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let n = 8
        var px = [UInt8](repeating: 0, count: n * n * 4)
        let drawn: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8,
                                      bytesPerRow: n * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard drawn else { return nil }
        var best: (score: CGFloat, h: CGFloat, s: CGFloat, b: CGFloat)?
        for i in 0..<(n * n) {
            let a = CGFloat(px[i * 4 + 3]) / 255
            guard a > 0.5 else { continue }
            let c = NSColor(srgbRed: CGFloat(px[i * 4]) / 255 / a, green: CGFloat(px[i * 4 + 1]) / 255 / a,
                            blue: CGFloat(px[i * 4 + 2]) / 255 / a, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
            c.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
            guard b > 0.18 else { continue } // near-black pixels have meaningless hue
            let score = s * (0.5 + b / 2)
            if score > (best?.score ?? 0) { best = (score, h, s, b) }
        }
        guard let best, best.s > 0.18 else { return nil } // monochrome artwork: callers fall back to white
        // Readable on black: bright, not neon.
        return NSColor(hue: best.h, saturation: min(best.s, 0.8), brightness: max(best.b, 0.75), alpha: 1)
    }
}

/// Brings a browser tab that is playing `title` to the front (AppleScript; run off the main thread).
enum BrowserTabs {
    static let chromium: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "com.brave.Browser",
        "com.microsoft.edgemac", "company.thebrowser.Browser", "company.thebrowser.dia",
    ]
    static let safari: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]

    static func supports(_ bundleID: String) -> Bool { chromium.contains(bundleID) || safari.contains(bundleID) }

    /// Returns true if a matching tab was found and focused.
    static func focus(bundleID: String, containing title: String) -> Bool {
        let q = title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let src: String
        if safari.contains(bundleID) {
            src = """
            tell application id "\(bundleID)"
                repeat with w in windows
                    repeat with t in tabs of w
                        if name of t contains "\(q)" then
                            set current tab of w to t
                            set index of w to 1
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end tell
            return "none"
            """
        } else {
            // Chrome-style dictionary; Arc/Dia select tabs with `select` instead of `active tab index`.
            src = """
            tell application id "\(bundleID)"
                repeat with w in windows
                    set i to 0
                    repeat with t in tabs of w
                        set i to i + 1
                        if title of t contains "\(q)" then
                            try
                                set active tab index of w to i
                            on error
                                tell t to select
                            end try
                            try
                                set index of w to 1
                            end try
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end tell
            return "none"
            """
        }
        var err: NSDictionary?
        return NSAppleScript(source: src)?.executeAndReturnError(&err).stringValue == "ok"
    }
}
