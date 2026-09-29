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

/// Colors derived from artwork (downsampled to 8x8).
enum ArtworkColor {
    /// Premultiplied-RGBA 8x8 pixels, row 0 = top of the image.
    private static func pixels(_ image: NSImage, n: Int = 8) -> [UInt8]? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var px = [UInt8](repeating: 0, count: n * n * 4)
        let drawn: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8,
                                      bytesPerRow: n * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        return drawn ? px : nil
    }

    private static func color(_ px: [UInt8], _ i: Int) -> NSColor? {
        let a = CGFloat(px[i * 4 + 3]) / 255
        guard a > 0.5 else { return nil }
        return NSColor(srgbRed: CGFloat(px[i * 4]) / 255 / a, green: CGFloat(px[i * 4 + 1]) / 255 / a,
                       blue: CGFloat(px[i * 4 + 2]) / 255 / a, alpha: 1)
    }

    /// Most saturated usable pixel, made readable on black. Nil for monochrome artwork.
    static func accent(for image: NSImage) -> NSColor? {
        guard let px = pixels(image) else { return nil }
        var best: (score: CGFloat, h: CGFloat, s: CGFloat, b: CGFloat)?
        for i in 0..<64 {
            guard let c = color(px, i) else { continue }
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

    /// Two dark colors (top half, bottom half of the artwork) for a backdrop gradient under white text.
    static func backdrop(for image: NSImage) -> [NSColor]? {
        guard let px = pixels(image) else { return nil }
        func average(rows: Range<Int>) -> NSColor? {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, n: CGFloat = 0
            for y in rows { for x in 0..<8 {
                guard let c = color(px, y * 8 + x) else { continue }
                r += c.redComponent; g += c.greenComponent; b += c.blueComponent; n += 1
            } }
            guard n > 0 else { return nil }
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0
            NSColor(srgbRed: r / n, green: g / n, blue: b / n, alpha: 1).getHue(&h, saturation: &s, brightness: &v, alpha: nil)
            // Averages go muddy: nudge saturation up, clamp brightness into a dark band.
            return NSColor(hue: h, saturation: min(s * 1.25, 0.75), brightness: min(max(v, 0.22), 0.42), alpha: 1)
        }
        guard let top = average(rows: 0..<4), let bottom = average(rows: 4..<8) else { return nil }
        return [top, bottom]
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
    /// Any web browser we know of (tab focusing aside).
    static func isBrowser(_ bundleID: String) -> Bool {
        supports(bundleID) || bundleID.hasPrefix("org.mozilla.") || bundleID == "app.zen-browser.zen"
    }

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
