import Foundation

/// Looks up whether a track is explicit with the iTunes Search API. In-memory cache keyed by
/// title|artist; at most one request per track, started only after the track has been current for a
/// moment (skipping through a playlist doesn't fire a request per track). Failures are not retried
/// for that track; 403/429 pauses all lookups. Main thread only.
final class ExplicitLookup {
    private var cache: [String: Bool] = [:]
    private var currentKey = ""
    private var pending: DispatchWorkItem?
    private var inFlight: Set<String> = []
    private var failedUntil: [String: Date] = [:]
    private var pausedUntil = Date.distantPast

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.timeoutIntervalForResource = 15
        c.waitsForConnectivity = false
        c.httpMaximumConnectionsPerHost = 1
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    /// Returns the cached answer if known. Otherwise schedules one lookup for this track (if not
    /// already scheduled/failed) and returns nil; `result` is called later, only if it's still current.
    func request(title: String, artist: String, result: @escaping (Bool) -> Void) -> Bool? {
        let key = Self.norm(title) + "|" + Self.norm(artist)
        if let v = cache[key] { cancel(); currentKey = key; return v }
        guard key != currentKey else { return nil } // same track re-emitted: already handled
        cancel()
        currentKey = key
        guard !title.isEmpty, !artist.isEmpty, !inFlight.contains(key),
              (failedUntil[key] ?? .distantPast) < Date(), pausedUntil < Date() else { return nil }
        let work = DispatchWorkItem { [weak self] in self?.fetch(key: key, title: title, artist: artist, result: result) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        return nil
    }

    /// Forget the current track (no track / setting off). Keeps the cache.
    func cancel() {
        pending?.cancel()
        pending = nil
        currentKey = ""
    }

    private func fetch(key: String, title: String, artist: String, result: @escaping (Bool) -> Void) {
        pending = nil
        guard key == currentKey, let url = Self.url(term: "\(artist) \(title)") else { return }
        inFlight.insert(key)
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let task = session.dataTask(with: req) { [weak self] data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let answer: Bool? = (error == nil && status == 200 && data != nil)
                ? Self.parse(data!, title: title, artist: artist) : nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight.remove(key)
                if let answer {
                    self.cache[key] = answer
                    if self.currentKey == key { result(answer) }
                } else {
                    self.failedUntil[key] = Date().addingTimeInterval(15 * 60)
                    if status == 403 || status == 429 { self.pausedUntil = Date().addingTimeInterval(10 * 60) }
                }
            }
        }
        task.priority = URLSessionTask.lowPriority
        task.resume()
    }

    private static func url(term: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#/")
        guard let q = term.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        var s = "https://itunes.apple.com/search?term=\(q)&entity=song&limit=5"
        if let region = Locale.current.region?.identifier, region.count == 2 { s += "&country=\(region)" }
        return URL(string: s)
    }

    /// Nil if the response is malformed; false if no result matches title+artist.
    static func parse(_ data: Data, title: String, artist: String) -> Bool? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]] else { return nil }
        let t = norm(title), a = norm(artist)
        guard !t.isEmpty, !a.isEmpty else { return false }
        let matches = results.filter { r in
            let rt = norm(r["trackName"] as? String ?? ""), ra = norm(r["artistName"] as? String ?? "")
            guard !rt.isEmpty, !ra.isEmpty else { return false }
            let titleOK = rt == t || (min(rt.count, t.count) >= 4 && (rt.hasPrefix(t) || t.hasPrefix(rt)))
            let artistOK = ra.contains(a) || a.contains(ra)
            return titleOK && artistOK
        }
        // "cleaned" = the clean edit of an explicit song. Search currently returns only the cleaned edit
        // for explicit songs (lookup by id still says "explicit"), and players default to the explicit
        // version, so both count.
        return matches.contains { ["explicit", "cleaned"].contains($0["trackExplicitness"] as? String ?? "") }
    }

    /// Lowercased, diacritic-free alphanumerics, without bracketed tags, "feat." credits and " - …" suffixes.
    static func norm(_ s: String) -> String {
        var t = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        t = t.replacingOccurrences(of: #"[\(\[][^\)\]]*[\)\]]"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s(feat\.?|ft\.?|featuring)\s.*$"#, with: "", options: .regularExpression)
        let dashless = t.replacingOccurrences(of: #"\s[-–—]\s.*$"#, with: "", options: .regularExpression)
        if !dashless.trimmingCharacters(in: .whitespaces).isEmpty { t = dashless }
        return String(String.UnicodeScalarView(t.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }
}
