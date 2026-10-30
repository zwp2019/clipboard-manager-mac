import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLValue {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    init(_ value: String?) { self = value.map { .text($0) } ?? .null }
    init(_ value: Int) { self = .int(Int64(value)) }
    init(_ value: Int64) { self = .int(value) }
    init(_ value: Bool) { self = .int(value ? 1 : 0) }
    init(_ value: Double) { self = .double(value) }
    init(_ value: Date) { self = .double(value.timeIntervalSince1970) }
}

struct Row {
    let values: [String: SQLValue]

    func string(_ key: String) -> String? {
        if case .text(let value) = values[key] { return value }
        return nil
    }

    func int(_ key: String) -> Int64 {
        switch values[key] {
        case .int(let value): return value
        case .double(let value): return Int64(value)
        default: return 0
        }
    }

    func bool(_ key: String) -> Bool { int(key) != 0 }

    func date(_ key: String) -> Date? {
        switch values[key] {
        case .double(let value): return Date(timeIntervalSince1970: value)
        case .int(let value): return Date(timeIntervalSince1970: Double(value))
        default: return nil
        }
    }
}

enum DatabaseError: LocalizedError {
    case open(String)
    case sql(String)

    var errorDescription: String? {
        switch self {
        case .open(let message): return "数据库打开失败：\(message)"
        case .sql(let message): return "数据库操作失败：\(message)"
        }
    }
}

/// 轻量 SQLite 封装：WAL、busy_timeout、外键与统一迁移。
final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    let path: String

    init(path: String) throws {
        self.path = path
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            throw DatabaseError.open(String(cString: sqlite3_errmsg(db)))
        }
        handle = db
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA busy_timeout=5000;")
        try execute("PRAGMA foreign_keys=ON;")
        try execute("PRAGMA synchronous=NORMAL;")
        try DatabaseMigrator.migrate(self)
    }

    deinit {
        if let handle {
            sqlite3_close(handle)
        }
    }

    func execute(_ sql: String, _ params: [SQLValue] = []) throws {
        lock.lock()
        defer { lock.unlock() }
        if params.isEmpty {
            var error: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(handle, sql, nil, nil, &error) != SQLITE_OK {
                let message = error.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(error)
                throw DatabaseError.sql(message)
            }
            return
        }
        _ = try run(sql, params)
    }

    func query(_ sql: String, _ params: [SQLValue] = []) throws -> [Row] {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(sql, params)
        defer { sqlite3_finalize(statement) }

        var rows: [Row] = []
        let count = Int(sqlite3_column_count(statement))
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            if result != SQLITE_ROW { throw DatabaseError.sql(errorMessage()) }

            var values: [String: SQLValue] = [:]
            for index in 0..<count {
                let name = String(cString: sqlite3_column_name(statement, Int32(index)))
                switch sqlite3_column_type(statement, Int32(index)) {
                case SQLITE_INTEGER:
                    values[name] = .int(sqlite3_column_int64(statement, Int32(index)))
                case SQLITE_FLOAT:
                    values[name] = .double(sqlite3_column_double(statement, Int32(index)))
                case SQLITE_TEXT:
                    if let text = sqlite3_column_text(statement, Int32(index)) {
                        values[name] = .text(String(cString: text))
                    } else {
                        values[name] = .null
                    }
                case SQLITE_BLOB:
                    if let bytes = sqlite3_column_blob(statement, Int32(index)) {
                        values[name] = .blob(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, Int32(index)))))
                    } else {
                        values[name] = .null
                    }
                default:
                    values[name] = .null
                }
            }
            rows.append(Row(values: values))
        }
        return rows
    }

    func executeReturningID(_ sql: String, _ params: [SQLValue] = []) throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(sql, params)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.sql(errorMessage())
        }
        return sqlite3_last_insert_rowid(handle)
    }

    func transaction(_ body: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE;")
        do {
            try body()
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func backup(to destination: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if FileManager.default.fileExists(atPath: destination) {
            try FileManager.default.removeItem(atPath: destination)
        }
        try execute("VACUUM INTO '\(destination.replacingOccurrences(of: "'", with: "''"))';")
    }

    // MARK: - Private

    private func prepare(_ sql: String, _ params: [SQLValue]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError.sql(errorMessage())
        }
        for (index, value) in params.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .null:
                sqlite3_bind_null(statement, position)
            case .int(let number):
                sqlite3_bind_int64(statement, position, number)
            case .double(let number):
                sqlite3_bind_double(statement, position, number)
            case .text(let text):
                sqlite3_bind_text(statement, position, text, -1, SQLITE_TRANSIENT)
            case .blob(let data):
                sqlite3_bind_blob(statement, position, (data as NSData).bytes, Int32(data.count), SQLITE_TRANSIENT)
            }
        }
        return statement
    }

    @discardableResult
    private func run(_ sql: String, _ params: [SQLValue]) throws -> Int {
        let statement = try prepare(sql, params)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw DatabaseError.sql(errorMessage())
        }
        return Int(sqlite3_changes(handle))
    }

    private func errorMessage() -> String {
        guard let handle else { return "database closed" }
        return String(cString: sqlite3_errmsg(handle))
    }
}

/// 数据库迁移（对应原项目 SqliteSchema V1-V3 的合并版）。
enum DatabaseMigrator {
    static let version: Int32 = 3

    static func migrate(_ db: SQLiteDatabase) throws {
        let current = (try? db.query("PRAGMA user_version;").first?.int("user_version")) ?? 0
        guard current < Int64(version) else { return }

        try db.execute("""
        CREATE TABLE IF NOT EXISTS clipboard_items (
            id                 INTEGER PRIMARY KEY AUTOINCREMENT,
            type               INTEGER NOT NULL,
            text               TEXT,
            html               TEXT,
            rtf                TEXT,
            image_path         TEXT,
            thumbnail_path     TEXT,
            file_paths         TEXT,
            source_application TEXT,
            source_title       TEXT,
            source_bundle_id   TEXT,
            created_at         REAL NOT NULL,
            updated_at         REAL NOT NULL,
            hash               TEXT NOT NULL,
            size               INTEGER NOT NULL DEFAULT 0,
            is_favorite        INTEGER NOT NULL DEFAULT 0,
            group_name         TEXT,
            is_deleted         INTEGER NOT NULL DEFAULT 0,
            title              TEXT,
            ocr_text           TEXT
        );

        CREATE INDEX IF NOT EXISTS idx_items_created ON clipboard_items (created_at DESC, id DESC);
        CREATE INDEX IF NOT EXISTS idx_items_hash ON clipboard_items (hash);
        CREATE INDEX IF NOT EXISTS idx_items_favorite ON clipboard_items (is_favorite, created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_items_group ON clipboard_items (group_name);
        CREATE INDEX IF NOT EXISTS idx_items_source_date ON clipboard_items (source_application, created_at DESC);

        CREATE TABLE IF NOT EXISTS pinboards (
            name     TEXT PRIMARY KEY COLLATE NOCASE,
            color    TEXT NOT NULL DEFAULT '#9170D4',
            position INTEGER NOT NULL DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS settings (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS tags (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            name       TEXT NOT NULL UNIQUE,
            created_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS clipboard_tags (
            clipboard_item_id INTEGER NOT NULL,
            tag_id            INTEGER NOT NULL,
            PRIMARY KEY (clipboard_item_id, tag_id),
            FOREIGN KEY (clipboard_item_id) REFERENCES clipboard_items (id) ON DELETE CASCADE,
            FOREIGN KEY (tag_id) REFERENCES tags (id) ON DELETE CASCADE
        );
        """)

        try db.execute("PRAGMA user_version = \(version);")
    }
}

/// 应用数据目录（对应原项目 %LocalAppData%\ClipboardManager）。
enum AppPaths {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ClipboardManager", isDirectory: true)
    }()

    static let database = root.appendingPathComponent("Database", isDirectory: true)
    static let images = root.appendingPathComponent("Images", isDirectory: true)
    static let thumbnails = root.appendingPathComponent("Thumbnails", isDirectory: true)
    static let logs = root.appendingPathComponent("Logs", isDirectory: true)
    static let backups = root.appendingPathComponent("Backups", isDirectory: true)
    static let databaseFile = database.appendingPathComponent("clipboard.db")

    static func prepare() throws {
        for url in [root, database, images, thumbnails, logs, backups] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
