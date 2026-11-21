import Foundation
import GRDB

/// CRUD, tagging, trash and purge for items.
public struct ItemRepository: Sendable {
    public let database: AppDatabase
    public let clock: any Clock

    /// Items in the trash longer than this are purged.
    public static let trashRetention: TimeInterval = 30 * 24 * 60 * 60

    public init(database: AppDatabase, clock: any Clock = SystemClock()) {
        self.database = database
        self.clock = clock
    }

    var writer: any DatabaseWriter { database.writer }

    // MARK: - CRUD

    @discardableResult
    public func insert(_ item: Item) throws -> Item {
        try writer.write { db in try Self.insert(item, in: db) }
    }

    static func insert(_ item: Item, in db: Database) throws -> Item {
        try item.insert(db)
        return item
    }

    public func fetch(_ id: String) throws -> Item? {
        try writer.read { db in try Item.fetchOne(db, key: id) }
    }

    /// Non-trashed items, newest first.
    public func fetchAll(includeTrashed: Bool = false) throws -> [Item] {
        try writer.read { db in
            var request = Item.order(Item.Columns.createdAt.desc)
            if !includeTrashed { request = request.filter(Item.Columns.trashedAt == nil) }
            return try request.fetchAll(db)
        }
    }

    public func fetchTrashed() throws -> [Item] {
        try writer.read { db in
            try Item.filter(Item.Columns.trashedAt != nil).order(Item.Columns.trashedAt.desc).fetchAll(db)
        }
    }

    /// Saves all fields and bumps `updatedAt`.
    @discardableResult
    public func update(_ item: Item) throws -> Item {
        var item = item
        item.updatedAt = clock.now
        let saved = item
        try writer.write { db in
            guard try Item.exists(db, key: saved.id) else { throw MiniBrainError.notFound(saved.id) }
            try saved.update(db)
        }
        return saved
    }

    /// Loads, mutates, and saves an item in one transaction.
    @discardableResult
    public func modify(_ id: String, _ change: (inout Item) throws -> Void) throws -> Item {
        let now = clock.now
        return try writer.write { db in
            guard var item = try Item.fetchOne(db, key: id) else { throw MiniBrainError.notFound(id) }
            try change(&item)
            item.updatedAt = now
            try item.update(db)
            return item
        }
    }

    /// Permanently deletes the row (tags and queue rows cascade).
    public func delete(_ id: String) throws {
        _ = try writer.write { db in try Item.deleteOne(db, key: id) }
    }

    public func count(includeTrashed: Bool = false) throws -> Int {
        try writer.read { db in
            includeTrashed ? try Item.fetchCount(db) : try Item.filter(Item.Columns.trashedAt == nil).fetchCount(db)
        }
    }

    // MARK: - Tags

    public static func normalizeTag(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MiniBrainError.invalidTag(name) }
        return trimmed
    }

    /// Attaches a tag (created on demand, case-insensitively unique).
    /// Re-attaching an AI tag the user already has keeps `source = user`.
    public func attachTag(_ name: String, to itemID: String, source: TagSource = .user) throws {
        try writer.write { db in try Self.attachTag(name, to: itemID, source: source, in: db) }
    }

    static func attachTag(_ name: String, to itemID: String, source: TagSource, in db: Database) throws {
        let name = try normalizeTag(name)
        guard try Item.exists(db, key: itemID) else { throw MiniBrainError.notFound(itemID) }
        try db.execute(sql: "INSERT INTO tags(name) VALUES (?) ON CONFLICT(name) DO NOTHING", arguments: [name])
        let tagID = try Int64.fetchOne(db, sql: "SELECT id FROM tags WHERE name = ? COLLATE NOCASE", arguments: [name])!
        try db.execute(
            sql: """
                INSERT INTO item_tags(item_id, tag_id, source) VALUES (?, ?, ?)
                ON CONFLICT(item_id, tag_id) DO UPDATE SET source =
                    CASE WHEN item_tags.source = 'user' OR excluded.source = 'user' THEN 'user' ELSE 'ai' END
                """,
            arguments: [itemID, tagID, source])
    }

    /// Detaches a tag. The tag row is deleted by trigger once unused.
    public func detachTag(_ name: String, from itemID: String) throws {
        try writer.write { db in try Self.detachTag(name, from: itemID, in: db) }
    }

    static func detachTag(_ name: String, from itemID: String, in db: Database) throws {
        try db.execute(
            sql: """
                DELETE FROM item_tags
                 WHERE item_id = ? AND tag_id = (SELECT id FROM tags WHERE name = ? COLLATE NOCASE)
                """,
            arguments: [itemID, name.trimmingCharacters(in: .whitespacesAndNewlines)])
    }

    public func tags(for itemID: String) throws -> [ItemTag] {
        try writer.read { db in try Self.tags(for: itemID, in: db) }
    }

    static func tags(for itemID: String, in db: Database) throws -> [ItemTag] {
        try ItemTag.fetchAll(
            db,
            sql: """
                SELECT t.name AS name, it.source AS source
                  FROM item_tags it JOIN tags t ON t.id = it.tag_id
                 WHERE it.item_id = ? ORDER BY t.name COLLATE NOCASE
                """,
            arguments: [itemID])
    }

    /// Tags for many items in one query (for gallery cards).
    public func tags(forItems ids: [String]) throws -> [String: [ItemTag]] {
        guard !ids.isEmpty else { return [:] }
        return try writer.read { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT it.item_id AS item_id, t.name AS name, it.source AS source
                      FROM item_tags it JOIN tags t ON t.id = it.tag_id
                     WHERE it.item_id IN (\(placeholders)) ORDER BY t.name COLLATE NOCASE
                    """,
                arguments: StatementArguments(ids))
            var out: [String: [ItemTag]] = [:]
            for row in rows {
                out[row["item_id"], default: []].append(ItemTag(name: row["name"], source: row["source"]))
            }
            return out
        }
    }

    public func allTags() throws -> [Tag] {
        try writer.read { db in
            try Tag.fetchAll(db, sql: "SELECT id, name FROM tags ORDER BY name COLLATE NOCASE")
        }
    }

    /// Renames a tag everywhere. If the new name already exists, the two merge.
    public func renameTag(_ oldName: String, to newName: String) throws {
        let newName = try Self.normalizeTag(newName)
        try writer.write { db in
            guard let oldID = try Int64.fetchOne(
                db, sql: "SELECT id FROM tags WHERE name = ? COLLATE NOCASE", arguments: [oldName])
            else { throw MiniBrainError.notFound(oldName) }
            if let existing = try Int64.fetchOne(
                db, sql: "SELECT id FROM tags WHERE name = ? COLLATE NOCASE AND id != ?",
                arguments: [newName, oldID])
            {
                let itemIDs = try String.fetchAll(
                    db, sql: "SELECT item_id FROM item_tags WHERE tag_id = ?", arguments: [oldID])
                for itemID in itemIDs {
                    let source = try String.fetchOne(
                        db, sql: "SELECT source FROM item_tags WHERE item_id = ? AND tag_id = ?",
                        arguments: [itemID, oldID]) ?? "user"
                    try db.execute(sql: "DELETE FROM item_tags WHERE item_id = ? AND tag_id = ?", arguments: [itemID, oldID])
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO item_tags(item_id, tag_id, source) VALUES (?, ?, ?)",
                        arguments: [itemID, existing, source])
                }
            } else {
                try db.execute(sql: "UPDATE tags SET name = ? WHERE id = ?", arguments: [newName, oldID])
            }
        }
    }

    /// Clears OCR text from all image items (search index updates by trigger).
    /// Returns how many items changed.
    @discardableResult
    public func clearRecognizedText() throws -> Int {
        let now = clock.now
        return try writer.write { db in
            try db.execute(
                sql: """
                    UPDATE items SET content = '', meta = json_remove(meta, '$.has_text'), updated_at = ?
                     WHERE type = 'image' AND content != ''
                    """,
                arguments: [now])
            return db.changesCount
        }
    }

    /// How many items (including trashed) use a tag.
    public func usageCount(ofTag name: String) throws -> Int {
        try writer.read { db in
            try Int.fetchOne(db, sql: """
                SELECT count(*) FROM item_tags it JOIN tags t ON t.id = it.tag_id WHERE t.name = ? COLLATE NOCASE
                """, arguments: [name]) ?? 0
        }
    }

    /// Deletes a tag from every item. Each item remembers the removal so AI
    /// tagging won't add it back. Returns how many items lost the tag.
    @discardableResult
    public func deleteTagEverywhere(_ name: String) throws -> Int {
        let now = clock.now
        return try writer.write { db in
            let itemIDs = try String.fetchAll(db, sql: """
                SELECT it.item_id FROM item_tags it JOIN tags t ON t.id = it.tag_id WHERE t.name = ? COLLATE NOCASE
                """, arguments: [name])
            for id in itemIDs { try TagMerger.userRemoveTag(name, from: id, now: now, in: db) }
            try db.execute(sql: "DELETE FROM tags WHERE name = ? COLLATE NOCASE", arguments: [name]) // if still present
            return itemIDs.count
        }
    }

    // MARK: - Trash

    public func trash(_ id: String) throws {
        let now = clock.now
        try writer.write { db in
            try db.execute(sql: "UPDATE items SET trashed_at = ? WHERE id = ?", arguments: [now, id])
            guard db.changesCount > 0 else { throw MiniBrainError.notFound(id) }
        }
    }

    public func restore(_ id: String) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE items SET trashed_at = NULL WHERE id = ?", arguments: [id])
            guard db.changesCount > 0 else { throw MiniBrainError.notFound(id) }
        }
    }

    /// Deletes items trashed more than `retention` ago, then removes their blobs
    /// if no remaining item references them. Returns the number of purged items.
    @discardableResult
    public func purgeTrash(olderThan retention: TimeInterval = trashRetention, blobs: BlobStore? = nil) throws -> Int {
        let cutoff = clock.now.addingTimeInterval(-retention)
        let (count, hashes) = try writer.write { db -> (Int, [String]) in
            let expired = try Item
                .filter(Item.Columns.trashedAt != nil && Item.Columns.trashedAt <= cutoff)
                .fetchAll(db)
            for item in expired { try item.delete(db) }
            let previews = expired.compactMap { $0.meta["preview_blob"]?.stringValue }
            return (expired.count, Array(Set(expired.compactMap(\.blobHash) + previews)))
        }
        if let blobs {
            for hash in hashes { try blobs.deleteIfUnreferenced(hash, database: database) }
        }
        return count
    }
}
