import Foundation
import SQLite3

struct DictionaryEntry: Identifiable, Equatable {
    var id: String { phrase }
    let phrase: String
    let replacement: String
    let updatedAtMillis: Int64
}

enum LocalStoreError: LocalizedError {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case invalidPath

    var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return "无法打开数据库：\(msg)"
        case .prepareFailed(let msg): return "SQL 准备失败：\(msg)"
        case .stepFailed(let msg): return "SQL 执行失败：\(msg)"
        case .invalidPath: return "存储路径无效"
        }
    }
}

/// Local SQLite store aligned with `core-store` dictionary + app_profiles schema.
final class LocalStore {
    private var db: OpaquePointer?

    init(path: String) throws {
        let expanded = NSString(string: path).expandingTildeInPath
        guard !expanded.isEmpty else { throw LocalStoreError.invalidPath }

        let url = URL(fileURLWithPath: expanded)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(expanded, &handle, flags, nil) != SQLITE_OK {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let handle { sqlite3_close(handle) }
            throw LocalStoreError.openFailed(msg)
        }
        db = handle
        try migrate()
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    // MARK: - Dictionary

    func listDictionary() throws -> [DictionaryEntry] {
        let sql = "SELECT phrase, replacement, updated_at_millis FROM dictionary ORDER BY phrase ASC"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        var entries: [DictionaryEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let phrase = String(cString: sqlite3_column_text(stmt, 0))
            let replacement = String(cString: sqlite3_column_text(stmt, 1))
            let updated = sqlite3_column_int64(stmt, 2)
            entries.append(DictionaryEntry(phrase: phrase, replacement: replacement, updatedAtMillis: updated))
        }
        return entries
    }

    func upsert(phrase: String, replacement: String) throws {
        let trimmedPhrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPhrase.isEmpty else { return }

        let sql = """
        INSERT INTO dictionary (phrase, replacement, updated_at_millis)
        VALUES (?, ?, ?)
        ON CONFLICT(phrase) DO UPDATE SET
          replacement=excluded.replacement,
          updated_at_millis=excluded.updated_at_millis
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        sqlite3_bind_text(stmt, 1, trimmedPhrase, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, replacement, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 3, now)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw LocalStoreError.stepFailed(errmsg())
        }
    }

    func delete(phrase: String) throws {
        let sql = "DELETE FROM dictionary WHERE phrase = ?"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, phrase, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw LocalStoreError.stepFailed(errmsg())
        }
    }

    // MARK: - App profiles

    func listAppProfiles() throws -> [AppProfile] {
        let sql = """
        SELECT app_id, tone, settings_json, updated_at_millis
        FROM app_profiles
        ORDER BY app_id ASC
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        var profiles: [AppProfile] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            profiles.append(try readAppProfile(stmt))
        }
        return profiles
    }

    func getAppProfile(appId: String) throws -> AppProfile? {
        let sql = """
        SELECT app_id, tone, settings_json, updated_at_millis
        FROM app_profiles WHERE app_id = ?
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, appId, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return try readAppProfile(stmt)
    }

    func upsertAppProfile(_ profile: AppProfile) throws {
        let trimmedId = profile.appId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else { return }

        let settingsData = try JSONEncoder().encode(profile.format)
        let settingsJSON = String(data: settingsData, encoding: .utf8) ?? "{}"

        let sql = """
        INSERT INTO app_profiles (app_id, tone, settings_json, updated_at_millis)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(app_id) DO UPDATE SET
          tone=excluded.tone,
          settings_json=excluded.settings_json,
          updated_at_millis=excluded.updated_at_millis
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        sqlite3_bind_text(stmt, 1, trimmedId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, profile.tone, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, settingsJSON, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 4, now)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw LocalStoreError.stepFailed(errmsg())
        }
    }

    func deleteAppProfile(appId: String) throws {
        let sql = "DELETE FROM app_profiles WHERE app_id = ?"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, appId, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw LocalStoreError.stepFailed(errmsg())
        }
    }

    private func readAppProfile(_ stmt: OpaquePointer) throws -> AppProfile {
        let appId = String(cString: sqlite3_column_text(stmt, 0))
        let tone = String(cString: sqlite3_column_text(stmt, 1))
        let settingsJSON = String(cString: sqlite3_column_text(stmt, 2))
        let updated = sqlite3_column_int64(stmt, 3)

        var format = AppProfileFormatSettings.empty
        if let data = settingsJSON.data(using: .utf8) {
            format = (try? JSONDecoder().decode(AppProfileFormatSettings.self, from: data)) ?? .empty
        }

        return AppProfile(appId: appId, tone: tone, format: format, updatedAtMillis: updated)
    }

    private func migrate() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS dictionary (
          phrase TEXT PRIMARY KEY,
          replacement TEXT NOT NULL,
          updated_at_millis INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS app_profiles (
          app_id TEXT PRIMARY KEY,
          tone TEXT NOT NULL,
          settings_json TEXT NOT NULL,
          updated_at_millis INTEGER NOT NULL
        );
        """
        var errMsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errMsg) == SQLITE_OK else {
            let msg = errMsg.map { String(cString: $0) } ?? "migrate failed"
            sqlite3_free(errMsg)
            throw LocalStoreError.stepFailed(msg)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw LocalStoreError.prepareFailed(errmsg())
        }
        return stmt
    }

    private func errmsg() -> String {
        guard let db else { return "no db" }
        return String(cString: sqlite3_errmsg(db))
    }
}

/// SQLite requires a destructor for bound text that outlives the call.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
