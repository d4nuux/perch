import Foundation
import OSLog
import SQLite3

/// One delivered notification as stored by usernoted. Text fields are never logged.
struct NotificationRecord {
    let recID: Int64
    /// As stored (usernoted lowercases most identifiers, e.g. "com.apple.mail").
    let bundleID: String
    let title: String
    let subtitle: String
    let body: String
    let delivered: Date
}

/// Where usernoted keeps its database, and whether we may read it.
///
/// macOS 15+ (and this machine, Darwin 27): ~/Library/Group Containers/group.com.apple.usernoted/db2/db.
/// macOS 11–14: $(getconf DARWIN_USER_DIR)/com.apple.notificationcenter/db2/db.
/// Both need Full Disk Access; without it every open/stat inside fails with EPERM.
enum NotificationDBLocation {
    static var groupContainer: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted", isDirectory: true)
    }

    static var candidates: [URL] {
        var list = [groupContainer.appendingPathComponent("db2/db")]
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        if confstr(_CS_DARWIN_USER_DIR, &buf, buf.count) > 0 {
            let dir = String(cString: buf)
            list.append(URL(fileURLWithPath: dir).appendingPathComponent("com.apple.notificationcenter/db2/db"))
        }
        return list
    }

    /// First candidate that exists and can be opened for reading.
    static func resolve() -> URL? {
        candidates.first { access($0.path, R_OK) == 0 }
    }

    /// Full Disk Access check without side effects: can we open the (TCC-protected) usernoted
    /// container, or the TCC folder itself? Either one only opens with FDA.
    static var hasFullDiskAccess: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let probes = [groupContainer.path,
                      home.appendingPathComponent("Library/Application Support/com.apple.TCC").path]
        for path in probes {
            let fd = open(path, O_RDONLY | O_DIRECTORY)
            if fd >= 0 { close(fd); return true }
        }
        return false
    }
}

/// Read-only SQLite access to the usernoted DB. Not thread-safe: use from one serial queue.
///
/// Schema (db2, macOS 11 → 15; re-checked at open via PRAGMA table_info so a renamed column
/// degrades instead of crashing):
///   app(app_id INTEGER PRIMARY KEY, identifier TEXT, badge INTEGER, …)
///   record(rec_id INTEGER PRIMARY KEY, app_id INTEGER, uuid BLOB, data BLOB, request_date REAL,
///          request_last_date REAL, delivered_date REAL, presented BOOL, style INTEGER, …)
/// Dates are seconds since 2001-01-01 (reference date). `data` is a binary plist:
///   { app: String, date: Double, req: { titl, subt, body, iden, thre, cate, … }, … }
final class NotificationDB {
    private static let log = Logger(subsystem: "Perch", category: "Notifications")

    let url: URL
    private var db: OpaquePointer?
    private var idCol = "rec_id"
    private var dateCol: String?
    private var appIdentCol = "identifier"
    private var hasAppTable = true

    init?(url: URL) {
        self.url = url
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            Self.log.error("open failed: \(String(cString: sqlite3_errmsg(handle)), privacy: .public)")
            sqlite3_close(handle)
            return nil
        }
        db = handle
        sqlite3_busy_timeout(handle, 250)
        guard readSchema() else {
            Self.log.error("unexpected schema; mirroring disabled")
            close()
            return nil
        }
    }

    deinit { close() }

    func close() {
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    private func columns(_ table: String) -> Set<String> {
        var out: Set<String> = []
        query("PRAGMA table_info(\(table))") { stmt in
            if let c = sqlite3_column_text(stmt, 1) { out.insert(String(cString: c)) }
        }
        return out
    }

    private func readSchema() -> Bool {
        let rec = columns("record")
        guard rec.contains("data") else { return false }
        idCol = rec.contains("rec_id") ? "rec_id" : "rowid"
        dateCol = rec.contains("delivered_date") ? "delivered_date"
            : rec.contains("request_date") ? "request_date" : nil
        let app = columns("app")
        hasAppTable = app.contains("app_id") && rec.contains("app_id")
        appIdentCol = app.contains("identifier") ? "identifier" : app.contains("bundleid") ? "bundleid" : "identifier"
        if !app.contains(appIdentCol) { hasAppTable = false }
        return true
    }

    /// Highest record id (0 when empty).
    func maxID() -> Int64 {
        var v: Int64 = 0
        query("SELECT MAX(\(idCol)) FROM record") { v = sqlite3_column_int64($0, 0) }
        return v
    }

    /// Records with id > `after`, oldest first. `skip` sees (id, delivered) before the plist is
    /// decoded, so already-seen rows cost no parsing.
    func records(after: Int64, limit: Int = 32, skip: (Int64, Date) -> Bool) -> [NotificationRecord] {
        let date = dateCol.map { "r.\($0)" } ?? "0"
        let ident = hasAppTable ? "a.\(appIdentCol)" : "NULL"
        let join = hasAppTable ? "LEFT JOIN app a ON a.app_id = r.app_id" : ""
        let sql = "SELECT r.\(idCol), \(ident), r.data, \(date) FROM record r \(join) "
            + "WHERE r.\(idCol) > ?1 ORDER BY r.\(idCol) ASC LIMIT ?2"
        var out: [NotificationRecord] = []
        query(sql, bind: { stmt in
            sqlite3_bind_int64(stmt, 1, after)
            sqlite3_bind_int(stmt, 2, Int32(limit))
        }) { stmt in
            let id = sqlite3_column_int64(stmt, 0)
            let delivered = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 3))
            if skip(id, delivered) { return }
            let ident = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            var data = Data()
            if let bytes = sqlite3_column_blob(stmt, 2) {
                data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 2)))
            }
            guard let rec = Self.decode(id: id, bundleID: ident, data: data, delivered: delivered) else { return }
            out.append(rec)
        }
        return out
    }

    /// Every app usernoted knows, with how many notifications it currently stores.
    func apps() -> [(bundleID: String, count: Int, last: Date?)] {
        guard hasAppTable else { return [] }
        let date = dateCol.map { "MAX(r.\($0))" } ?? "NULL"
        let sql = "SELECT a.\(appIdentCol), COUNT(r.\(idCol)), \(date) FROM app a "
            + "LEFT JOIN record r ON r.app_id = a.app_id GROUP BY a.app_id"
        var out: [(String, Int, Date?)] = []
        query(sql) { stmt in
            guard let c = sqlite3_column_text(stmt, 0) else { return }
            let last: Date? = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil
                : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 2))
            out.append((String(cString: c), Int(sqlite3_column_int64(stmt, 1)), last))
        }
        return out
    }

    private func query(_ sql: String, bind: ((OpaquePointer) -> Void)? = nil, row: (OpaquePointer) -> Void) {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            Self.log.error("prepare failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            return
        }
        defer { sqlite3_finalize(stmt) }
        bind?(stmt)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { row(stmt); continue }
            if rc != SQLITE_DONE {
                Self.log.error("step failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            }
            break
        }
    }

    // MARK: Plist

    static func decode(id: Int64, bundleID: String?, data: Data, delivered: Date) -> NotificationRecord? {
        guard !data.isEmpty,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let root = plist as? [String: Any] else { return nil }
        let req = (root["req"] as? [String: Any]) ?? [:]
        func str(_ k: String) -> String {
            ((req[k] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let app = bundleID ?? (root["app"] as? String), !app.isEmpty else { return nil }
        let rec = NotificationRecord(recID: id, bundleID: app, title: str("titl"), subtitle: str("subt"),
                                     body: str("body"), delivered: delivered)
        // Silent/empty records (badge-only updates) aren't worth a banner.
        guard !(rec.title.isEmpty && rec.body.isEmpty && rec.subtitle.isEmpty) else { return nil }
        return rec
    }
}
