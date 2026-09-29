import Foundation

/// Finds a video-meeting join link (Google Meet, Zoom, Teams, Webex, FaceTime) in free text.
enum MeetingLink {
    private static let tail = #"[^\s<>"'()\[\]{}]+"#
    private static let regexes: [NSRegularExpression] = [
        #"(?:https?://)?meet\.google\.com/[a-z]{3,4}-[a-z]{4}-[a-z]{3,4}"#,
        #"(?:https?://)?(?:[\w-]+\.)*zoom(?:gov)?\.(?:us|com)/(?:j|my|s|w|wc/join)/"# + tail,
        #"zoommtg://"# + tail,
        #"(?:https?://)?teams\.microsoft\.com/(?:l/meetup-join|meet)/"# + tail,
        #"(?:https?://)?teams\.live\.com/meet/"# + tail,
        #"(?:https?://)?(?:[\w-]+\.)*webex\.com/"# + tail,
        #"(?:https?://)?facetime\.apple\.com/join"# + tail,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    /// First meeting link found, searching `texts` in order.
    static func find(in texts: [String?]) -> URL? {
        for case let text? in texts where !text.isEmpty {
            let s = text.replacingOccurrences(of: "&amp;", with: "&")
            let range = NSRange(s.startIndex..., in: s)
            var best: (loc: Int, url: URL)?
            for re in regexes {
                guard let m = re.firstMatch(in: s, range: range), let r = Range(m.range, in: s) else { continue }
                if let best, best.loc <= m.range.location { continue }
                if let url = normalize(String(s[r])) { best = (m.range.location, url) }
            }
            if let best { return best.url }
        }
        return nil
    }

    private static func normalize(_ raw: String) -> URL? {
        var s = raw
        while let last = s.last, ".,;:!?>*".contains(last) { s.removeLast() }
        if !s.lowercased().hasPrefix("http"), !s.lowercased().hasPrefix("zoommtg") { s = "https://" + s }
        return URL(string: s)
    }
}
