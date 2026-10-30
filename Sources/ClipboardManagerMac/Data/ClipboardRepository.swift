import Foundation

/// 剪贴板条目仓储：与 UI 无关的同步 SQLite 访问层。
final class ClipboardRepository {
    private let db: SQLiteDatabase

    init(db: SQLiteDatabase) {
        self.db = db
    }

    private static let columns = """
    id, type, text, html, rtf, image_path, thumbnail_path, file_paths, source_application, \
    source_title, source_bundle_id, created_at, updated_at, hash, size, is_favorite, group_name, \
    is_deleted, title, ocr_text
    """

    // MARK: - 条目

    @discardableResult
    func insert(_ item: ClipboardItem) throws -> Int64 {
        let sql = """
        INSERT INTO clipboard_items
            (type, text, html, rtf, image_path, thumbnail_path, file_paths,
             source_application, source_title, source_bundle_id,
             created_at, updated_at, hash, size,
             is_favorite, group_name, is_deleted, title, ocr_text)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        return try db.executeReturningID(sql, params(for: item))
    }

    func get(id: Int64) throws -> ClipboardItem? {
        let rows = try db.query("SELECT \(Self.columns) FROM clipboard_items WHERE id = ? AND is_deleted = 0", [.int(id)])
        return rows.first.flatMap(Self.item(from:))
    }

    func findByHash(_ hash: String) throws -> ClipboardItem? {
        let rows = try db.query("SELECT \(Self.columns) FROM clipboard_items WHERE hash = ? AND is_deleted = 0 LIMIT 1", [.text(hash)])
        return rows.first.flatMap(Self.item(from:))
    }

    func query(_ query: ClipboardQuery, offset: Int, limit: Int) throws -> [ClipboardItem] {
        var conditions = ["is_deleted = 0"]
        var params: [SQLValue] = []

        if let type = query.type {
            conditions.append("type = ?")
            params.append(SQLValue(type.rawValue))
        }
        if query.favoritesOnly {
            conditions.append("is_favorite = 1")
        }
        if let group = query.group {
            conditions.append("group_name = ? COLLATE NOCASE")
            params.append(.text(group))
        }
        if let since = query.since {
            conditions.append("created_at >= ?")
            params.append(.double(since.timeIntervalSince1970))
        }
        if let source = query.source, !source.trimmingCharacters(in: .whitespaces).isEmpty {
            conditions.append("source_application LIKE ? ESCAPE '\\'")
            params.append(.text("%\(Self.escapeLike(source.trimmingCharacters(in: .whitespaces)))%"))
        }

        let keyword = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyword.isEmpty {
            let like = "%\(Self.escapeLike(keyword))%"
            conditions.append("""
            (text LIKE ? ESCAPE '\\' OR html LIKE ? ESCAPE '\\' OR file_paths LIKE ? ESCAPE '\\' \
            OR ocr_text LIKE ? ESCAPE '\\' OR title LIKE ? ESCAPE '\\' \
            OR source_application LIKE ? ESCAPE '\\' OR source_title LIKE ? ESCAPE '\\')
            """)
            params.append(contentsOf: Array(repeating: .text(like), count: 7))
        }

        let sql = """
        SELECT \(Self.columns) FROM clipboard_items
        WHERE \(conditions.joined(separator: " AND "))
        ORDER BY created_at DESC, id DESC
        LIMIT ? OFFSET ?
        """
        params.append(SQLValue(max(1, limit)))
        params.append(SQLValue(max(0, offset)))
        return try db.query(sql, params).compactMap(Self.item(from:))
    }

    func count() throws -> Int {
        Int(try db.query("SELECT COUNT(*) AS c FROM clipboard_items WHERE is_deleted = 0").first?.int("c") ?? 0)
    }

    func favoriteCount() throws -> Int {
        Int(try db.query("SELECT COUNT(*) AS c FROM clipboard_items WHERE is_deleted = 0 AND is_favorite = 1").first?.int("c") ?? 0)
    }

    func setFavorite(id: Int64, favorite: Bool) throws {
        try db.execute("UPDATE clipboard_items SET is_favorite = ?, updated_at = ? WHERE id = ?",
                       [SQLValue(favorite), .double(Date().timeIntervalSince1970), .int(id)])
    }

    func setGroup(id: Int64, group: String?) throws {
        if let group, !group.isEmpty {
            try db.execute("INSERT OR IGNORE INTO pinboards (name) VALUES (?)", [.text(group)])
        }
        try db.execute("UPDATE clipboard_items SET group_name = ?, updated_at = ? WHERE id = ?",
                       [group.map { SQLValue.text($0) } ?? .null, .double(Date().timeIntervalSince1970), .int(id)])
    }

    func touch(id: Int64, date: Date = Date()) throws {
        try db.execute("UPDATE clipboard_items SET created_at = ?, updated_at = ? WHERE id = ?",
                       [.double(date.timeIntervalSince1970), .double(date.timeIntervalSince1970), .int(id)])
    }

    func delete(id: Int64) throws {
        try db.execute("DELETE FROM clipboard_items WHERE id = ?", [.int(id)])
    }

    func clear() throws {
        try db.execute("DELETE FROM clipboard_items;")
    }

    @discardableResult
    func deleteOlderThan(_ cutoff: Date) throws -> Int {
        try db.query("SELECT COUNT(*) AS c FROM clipboard_items WHERE created_at < ? AND is_favorite = 0 AND group_name IS NULL",
                     [.double(cutoff.timeIntervalSince1970)]).first.map { Int($0.int("c")) } ?? 0
    }

    func removeOlderThan(_ cutoff: Date) throws {
        try db.execute("DELETE FROM clipboard_items WHERE created_at < ? AND is_favorite = 0 AND group_name IS NULL",
                       [.double(cutoff.timeIntervalSince1970)])
    }

    func trim(to maxItems: Int) throws {
        guard maxItems > 0 else { return }
        try db.execute("""
        DELETE FROM clipboard_items
        WHERE is_favorite = 0 AND group_name IS NULL AND id IN (
            SELECT id FROM clipboard_items ORDER BY created_at DESC, id DESC LIMIT -1 OFFSET ?
        )
        """, [SQLValue(maxItems)])
    }

    func updateOCR(id: Int64, text: String) throws {
        try db.execute("UPDATE clipboard_items SET ocr_text = ?, updated_at = ? WHERE id = ?",
                       [.text(text), .double(Date().timeIntervalSince1970), .int(id)])
    }

    func updateContent(_ item: ClipboardItem) throws {
        let params: [SQLValue] = [
            item.title.map { SQLValue.text($0) } ?? .null,
            item.text.map { SQLValue.text($0) } ?? .null,
            item.html.map { SQLValue.text($0) } ?? .null,
            item.rtf.map { SQLValue.text($0) } ?? .null,
            SQLValue(item.type.rawValue),
            .text(item.hash),
            SQLValue(item.size),
            item.ocrText.map { SQLValue.text($0) } ?? .null,
            .double(Date().timeIntervalSince1970),
            .int(item.id)
        ]
        try db.execute("""
        UPDATE clipboard_items SET title = ?, text = ?, html = ?, rtf = ?, type = ?, hash = ?, size = ?,
            ocr_text = ?, updated_at = ? WHERE id = ?
        """, params)
    }

    func applyBatch(ids: [Int64], action: String, group: String?) throws {
        guard !ids.isEmpty else { return }
        try db.transaction {
            if action == "group", let group, !group.isEmpty {
                try db.execute("INSERT OR IGNORE INTO pinboards (name) VALUES (?)", [.text(group)])
            }
            for id in Set(ids) {
                switch action {
                case "delete":
                    try db.execute("DELETE FROM clipboard_items WHERE id = ?", [.int(id)])
                case "favorite":
                    try db.execute("UPDATE clipboard_items SET is_favorite = 1 WHERE id = ?", [.int(id)])
                case "unfavorite":
                    try db.execute("UPDATE clipboard_items SET is_favorite = 0 WHERE id = ?", [.int(id)])
                case "group":
                    try db.execute("UPDATE clipboard_items SET group_name = ? WHERE id = ?",
                                   [group.map { SQLValue.text($0) } ?? .null, .int(id)])
                default:
                    break
                }
            }
        }
    }

    func distinctSources() throws -> [String] {
        try db.query("SELECT source_application AS s FROM clipboard_items WHERE source_application IS NOT NULL AND source_application <> '' GROUP BY s ORDER BY s")
            .compactMap { $0.string("s") }
    }

    // MARK: - 收藏板

    func pinboards() throws -> [Pinboard] {
        try db.query("SELECT name, color, position FROM pinboards ORDER BY position, name").map { row in
            Pinboard(name: row.string("name") ?? "",
                     color: row.string("color") ?? "#9170D4",
                     position: Int(row.int("position")))
        }
    }

    func savePinboard(_ board: Pinboard, previousName: String?) throws {
        try db.transaction {
            if let previousName {
                try db.execute("UPDATE pinboards SET name = ?, color = ? WHERE name = ? COLLATE NOCASE",
                               [.text(board.name), .text(board.color), .text(previousName)])
                try db.execute("UPDATE clipboard_items SET group_name = ? WHERE group_name = ? COLLATE NOCASE",
                               [.text(board.name), .text(previousName)])
            } else {
                try db.execute("""
                INSERT INTO pinboards (name, color, position)
                VALUES (?, ?, COALESCE((SELECT MAX(position) + 1 FROM pinboards), 0))
                """, [.text(board.name), .text(board.color)])
            }
        }
    }

    func deletePinboard(name: String) throws {
        try db.transaction {
            try db.execute("UPDATE clipboard_items SET group_name = NULL WHERE group_name = ? COLLATE NOCASE", [.text(name)])
            try db.execute("DELETE FROM pinboards WHERE name = ? COLLATE NOCASE", [.text(name)])
        }
    }

    func reorderPinboards(_ names: [String]) throws {
        try db.transaction {
            for (index, name) in names.enumerated() {
                try db.execute("UPDATE pinboards SET position = ? WHERE name = ? COLLATE NOCASE", [SQLValue(index), .text(name)])
            }
        }
    }

    // MARK: - 映射

    private func params(for item: ClipboardItem) -> [SQLValue] {
        [
            SQLValue(item.type.rawValue),
            item.text.map { SQLValue.text($0) } ?? .null,
            item.html.map { SQLValue.text($0) } ?? .null,
            item.rtf.map { SQLValue.text($0) } ?? .null,
            item.imagePath.map { SQLValue.text($0) } ?? .null,
            item.thumbnailPath.map { SQLValue.text($0) } ?? .null,
            item.filePaths.map { SQLValue.text($0) } ?? .null,
            item.sourceApplication.map { SQLValue.text($0) } ?? .null,
            item.sourceTitle.map { SQLValue.text($0) } ?? .null,
            item.sourceBundleID.map { SQLValue.text($0) } ?? .null,
            .double(item.createdAt.timeIntervalSince1970),
            .double(item.updatedAt.timeIntervalSince1970),
            .text(item.hash),
            SQLValue(item.size),
            SQLValue(item.isFavorite),
            item.groupName.map { SQLValue.text($0) } ?? .null,
            SQLValue(item.isDeleted),
            item.title.map { SQLValue.text($0) } ?? .null,
            item.ocrText.map { SQLValue.text($0) } ?? .null
        ]
    }

    static func item(from row: Row) -> ClipboardItem? {
        guard let id = row.values["id"] else { return nil }
        var item = ClipboardItem()
        if case .int(let value) = id { item.id = value }
        item.type = ClipboardType(rawValue: Int(row.int("type"))) ?? .unknown
        item.text = row.string("text")
        item.html = row.string("html")
        item.rtf = row.string("rtf")
        item.imagePath = row.string("image_path")
        item.thumbnailPath = row.string("thumbnail_path")
        item.filePaths = row.string("file_paths")
        item.sourceApplication = row.string("source_application")
        item.sourceTitle = row.string("source_title")
        item.sourceBundleID = row.string("source_bundle_id")
        item.createdAt = row.date("created_at") ?? Date()
        item.updatedAt = row.date("updated_at") ?? item.createdAt
        item.hash = row.string("hash") ?? ""
        item.size = row.int("size")
        item.isFavorite = row.bool("is_favorite")
        item.groupName = row.string("group_name")
        item.isDeleted = row.bool("is_deleted")
        item.title = row.string("title")
        item.ocrText = row.string("ocr_text")
        return item
    }

    static func escapeLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}

/// 设置持久化：JSON 存入 settings 表。
final class SettingsRepository {
    private let db: SQLiteDatabase
    private static let key = "app_settings"

    init(db: SQLiteDatabase) {
        self.db = db
    }

    func load() -> AppSettings {
        guard let row = try? db.query("SELECT value FROM settings WHERE key = ?", [.text(Self.key)]).first,
              let json = row.string("value"),
              let data = json.data(using: .utf8),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings),
              let json = String(data: data, encoding: .utf8) else { return }
        try? db.execute("""
        INSERT INTO settings (key, value) VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """, [.text(Self.key), .text(json)])
    }
}
