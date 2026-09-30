import AppKit
import SwiftUI

/// Name, icon and accent of an app, resolved from its bundle id. Cached; safe off the main thread.
struct AppInfo {
    let bundleID: String
    let name: String
    let icon: NSImage
    /// Faint tint sampled from the icon (nil for monochrome icons).
    let accent: NSColor?
    let url: URL?
    var isInstalled: Bool { url != nil }
    /// Icon for avatar badges; nil when the app isn't installed (no placeholder glyph).
    var badge: NSImage? { url != nil ? icon : nil }

    private static var cache: [String: AppInfo] = [:]
    private static let lock = NSLock()

    static func lookup(_ bundleID: String) -> AppInfo {
        let key = bundleID.lowercased()
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let icon: NSImage = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "app.badge", accessibilityDescription: nil) ?? NSImage()
        var name = AppCatalog.knownNames[key]
        if let url {
            let b = Bundle(url: url)
            name = (b?.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
                ?? (b?.infoDictionary?["CFBundleDisplayName"] as? String)
                ?? (b?.infoDictionary?["CFBundleName"] as? String)
                ?? FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        let info = AppInfo(bundleID: key, name: name ?? AppCatalog.prettyName(key), icon: icon,
                           accent: url != nil ? ArtworkColor.accent(for: icon) : nil, url: url)
        lock.lock()
        cache[key] = info
        lock.unlock()
        return info
    }
}

/// Which layout a notification gets.
enum NotificationKind: String {
    case email, chat, generic
}

/// Bundle-id knowledge: email apps, chat apps, browsers, web apps.
enum AppCatalog {
    static let emailApps: Set<String> = [
        "com.apple.mail", "com.microsoft.outlook", "com.readdle.smartemail-mac", "com.superhuman.electron",
        "com.mimestream.mimestream", "it.bloop.airmail2", "com.freron.mailmate", "org.mozilla.thunderbird",
        "io.canarymail.mac", "ch.protonmail.desktop", "com.fastmail.mac.fastmail", "com.hey.app.desktop",
        "com.postbox-inc.postbox", "com.readdle.spark-desktop",
    ]
    static let chatApps: Set<String> = [
        "com.tinyspeck.slackmacgap", "com.hnc.discord", "net.whatsapp.whatsapp", "desktop.whatsapp",
        "com.apple.mobilesms", "com.apple.ichat", "ru.keepcoder.telegram", "org.telegram.desktop",
        "com.microsoft.teams2", "com.microsoft.teams", "com.facebook.archon", "org.whispersystems.signal-desktop",
        "com.apple.ichat.messages",
    ]
    static let browsers: Set<String> = [
        "com.google.chrome", "com.google.chrome.beta", "com.google.chrome.dev", "com.google.chrome.canary",
        "com.google.chrome.framework.alertnotificationservice", "com.microsoft.edgemac", "com.brave.browser",
        "company.thebrowser.browser", "com.apple.safari", "org.mozilla.firefox", "com.vivaldi.vivaldi",
        "com.operasoftware.opera", "ai.perplexity.comet", "company.thebrowser.dia",
    ]
    /// Browser bundle prefixes whose PWAs get their own id, e.g. "com.google.chrome.app.<hash>".
    static let webAppPrefixes = ["com.google.chrome.app.", "com.microsoft.edgemac.app.", "com.brave.browser.app.",
                                 "com.apple.safari.webapp", "com.apple.webkit.pushbundle."]
    static let webmailHosts = ["mail.google.com", "outlook.live.com", "outlook.office.com", "outlook.office365.com",
                               "outlook.cloud.microsoft", "mail.yahoo.com", "app.fastmail.com", "mail.proton.me",
                               "app.hey.com", "mail.superhuman.com", "mail.zoho.com", "icloud.com"]
    static let webchatHosts = ["app.slack.com", "discord.com", "web.whatsapp.com", "teams.microsoft.com",
                               "web.telegram.org", "messenger.com", "chat.google.com", "teams.live.com"]
    static let webmailNames = ["mail", "outlook", "superhuman", "fastmail", "proton", "hey"]
    static let webchatNames = ["slack", "discord", "whatsapp", "teams", "telegram", "messenger", "chat"]

    static let knownNames: [String: String] = [
        "com.apple.mail": "Mail", "com.microsoft.outlook": "Outlook", "com.readdle.smartemail-mac": "Spark",
        "com.superhuman.electron": "Superhuman", "com.google.chrome": "Google Chrome",
        "com.apple.mobilesms": "Messages", "com.tinyspeck.slackmacgap": "Slack",
    ]

    /// Default list shown in "Choose apps" even before usernoted has anything from them.
    static let suggested = ["com.apple.mail", "com.microsoft.outlook", "com.readdle.smartemail-mac",
                            "com.superhuman.electron", "com.google.chrome", "com.apple.safari",
                            "com.microsoft.edgemac", "company.thebrowser.browser", "com.brave.browser",
                            "com.tinyspeck.slackmacgap", "com.apple.mobilesms", "com.microsoft.teams2"]

    static func isBrowser(_ id: String) -> Bool { browsers.contains(id.lowercased()) }

    static func isWebApp(_ id: String) -> Bool {
        let l = id.lowercased()
        return webAppPrefixes.contains { l.hasPrefix($0) }
    }

    /// "com.readdle.smartemail-mac" → "Smartemail Mac" when nothing better is known.
    static func prettyName(_ id: String) -> String {
        let last = id.split(separator: ".").last.map(String.init) ?? id
        return last.replacingOccurrences(of: "-", with: " ").capitalized
    }

    /// Host a browser notification came from (Chrome puts it in the subtitle, Safari in the title).
    static func host(in rec: NotificationRecord) -> String? {
        for s in [rec.subtitle, rec.title] {
            let t = s.lowercased().trimmingCharacters(in: .whitespaces)
            guard !t.contains(" "), t.contains("."), t.count < 60 else { continue }
            return t.hasPrefix("www.") ? String(t.dropFirst(4)) : t
        }
        return nil
    }

    private static func matches(_ host: String?, _ hosts: [String]) -> Bool {
        guard let host else { return false }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func kind(bundleID: String, appName: String, host: String?) -> NotificationKind {
        let id = bundleID.lowercased()
        if emailApps.contains(id) { return .email }
        if chatApps.contains(id) { return .chat }
        if isBrowser(id) {
            if matches(host, webmailHosts) { return .email }
            if matches(host, webchatHosts) { return .chat }
            return .generic
        }
        if isWebApp(id) {
            let n = appName.lowercased()
            if webmailNames.contains(where: n.contains) { return .email }
            if webchatNames.contains(where: n.contains) { return .chat }
        }
        return .generic
    }
}

/// A mirrored notification, parsed and classified (off the main thread), ready to render.
struct NotificationItem: Identifiable {
    let id: Int64
    let app: AppInfo
    let kind: NotificationKind
    let date: Date
    /// Email: sender. Chat: person. Generic: title.
    let primary: String
    /// Email: subject. Chat: group/channel. Generic: subtitle.
    let secondary: String
    /// Email: snippet. Chat: message. Generic: body.
    let text: String
    /// Web notification: the site (shown as a caption, opened on tap).
    let host: String?
    /// One-time code found in the text, if any.
    let code: String?

    var key: String { "notif.\(id)" }
    var bundleID: String { app.bundleID }

    init(id: Int64, app: AppInfo, kind: NotificationKind, date: Date, primary: String, secondary: String,
         text: String, host: String?, code: String?) {
        self.id = id
        self.app = app
        self.kind = kind
        self.date = date
        self.primary = primary
        self.secondary = secondary
        self.text = text
        self.host = host
        self.code = code
    }

    init(record r: NotificationRecord, detectCodes: Bool) {
        let app = AppInfo.lookup(r.bundleID)
        let web = AppCatalog.isBrowser(r.bundleID)
        let host = web ? AppCatalog.host(in: r) : nil
        let kind = AppCatalog.kind(bundleID: r.bundleID, appName: app.name, host: host)
        // Drop the site line from browser notifications; it becomes a caption instead.
        let title = host != nil && r.title.lowercased().contains(host!) ? "" : r.title
        let subtitle = host != nil && r.subtitle.lowercased().contains(host!) ? "" : r.subtitle
        var primary = title, secondary = subtitle, text = r.body
        switch kind {
        case .email:
            // Mail/Outlook/Spark: title = sender, subtitle = subject, body = snippet.
            // Gmail web: subtitle = site, body = "Subject\nsnippet".
            if secondary.isEmpty {
                let lines = r.body.split(separator: "\n", maxSplits: 1).map(String.init)
                secondary = lines.first ?? ""
                text = lines.count > 1 ? lines[1] : ""
            }
            if primary.isEmpty { primary = app.name }
        case .chat:
            // Slack: "Name in #channel" / "Name (#channel)".
            for sep in [" in #", " (#"] {
                if let range = primary.range(of: sep), secondary.isEmpty {
                    secondary = "#" + primary[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: ")"))
                    primary = String(primary[..<range.lowerBound])
                    break
                }
            }
            if primary.isEmpty { primary = app.name }
        case .generic:
            if primary.isEmpty { primary = subtitle.isEmpty ? app.name : subtitle; secondary = "" }
        }
        let code = detectCodes ? OneTimeCode.find(in: [r.title, r.subtitle, r.body].joined(separator: "\n")) : nil
        self.init(id: r.recID, app: app, kind: kind, date: r.delivered, primary: primary, secondary: secondary,
                  text: text.replacingOccurrences(of: "\n", with: " "), host: host, code: code)
    }

    /// One-line summary for lists: email subject, chat message, generic body.
    var preview: String {
        switch kind {
        case .chat: text.isEmpty ? secondary : text
        default: secondary.isEmpty ? text : secondary
        }
    }

    /// "now", "4m", "2h".
    func age(at now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(date))
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        return "\(Int(s / 3600))h"
    }

    /// Opens the source app (a web notification opens its site in that browser), off the main thread.
    func open() {
        let app = self.app, host = self.host
        guard let appURL = app.url else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        if let host, let site = URL(string: "https://\(host)") {
            NSWorkspace.shared.open([site], withApplicationAt: appURL, configuration: config)
        } else {
            NSWorkspace.shared.openApplication(at: appURL, configuration: config)
        }
    }
}

/// Verification-code detection: needs a keyword ("code", "verification", "OTP", …) and then a
/// 4–8 digit number (also "123-456" / "123 456"), or a 4–8 char A–Z/0–9 token with a digit.
enum OneTimeCode {
    private static let keyword = try! NSRegularExpression(
        pattern: #"(code|verif|otp|one[- ]time|passcode|2fa|two[- ]factor|security|sign[- ]?in|log[- ]?in|pin\b|código|codice|kode|код)"#,
        options: [.caseInsensitive])
    private static let digits = try! NSRegularExpression(pattern: #"(?<![\d,:/$€£]|\d\.)(\d{3}[- ]\d{3}|\d{4,8})(?![\d,:/%]|[.,]\d)"#)
    private static let alnum = try! NSRegularExpression(pattern: #"\b(?=[A-Z0-9]*\d)(?=[A-Z0-9]*[A-Z])[A-Z0-9]{4,8}\b"#)

    static func find(in text: String) -> String? {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        guard keyword.firstMatch(in: text, range: all) != nil else { return nil }
        for m in digits.matches(in: text, range: all) {
            let raw = ns.substring(with: m.range(at: 1))
            let code = raw.filter(\.isNumber)
            // Skip years ("2026") unless the text says nothing else looks like a code.
            if code.count == 4, let y = Int(code), (1990...2099).contains(y) { continue }
            return code
        }
        if let m = alnum.firstMatch(in: text, range: all) { return ns.substring(with: m.range) }
        return nil
    }
}
