import Foundation
import GRDB
import CSQLiteVec

/// Owns the GRDB connection and the schema migrations.
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    /// Wraps an existing writer and migrates it to the latest schema.
    public init(_ writer: any DatabaseWriter, upTo lastMigration: String? = nil) throws {
        self.writer = writer
        if let lastMigration {
            try Self.migrator.migrate(writer, upTo: lastMigration)
        } else {
            try Self.migrator.migrate(writer)
        }
    }

    /// In-memory database (tests).
    public static func inMemory(upTo lastMigration: String? = nil) throws -> AppDatabase {
        try AppDatabase(DatabaseQueue(configuration: makeConfiguration()), upTo: lastMigration)
    }

    /// On-disk database in WAL mode (a `DatabasePool` always uses WAL).
    public static func open(at url: URL, upTo lastMigration: String? = nil) throws -> AppDatabase {
        try AppDatabase(DatabasePool(path: url.path, configuration: makeConfiguration()), upTo: lastMigration)
    }

    /// On-disk database with a rollback journal (single file; fixtures/tools).
    public static func openSingleFile(at url: URL, upTo lastMigration: String? = nil) throws -> AppDatabase {
        try AppDatabase(DatabaseQueue(path: url.path, configuration: makeConfiguration()), upTo: lastMigration)
    }

    public static func makeConfiguration() -> Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            let rc = mb_sqlite_vec_register(db.sqliteConnection)
            if rc != SQLITE_OK {
                throw DatabaseError(resultCode: ResultCode(rawValue: rc), message: "sqlite-vec registration failed")
            }
        }
        return config
    }

    // MARK: - Migrations

    public static let schemaV1 = "v1"
    public static let schemaV2 = "v2"
    public static let schemaV3 = "v3"

    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration(schemaV1, migrate: migrateV1)
        migrator.registerMigration(schemaV2, migrate: migrateV2)
        migrator.registerMigration(schemaV3, migrate: migrateV3)
        return migrator
    }

    /// Schema v1: items, tags, item_tags, items_fts (+ sync triggers), enrichment_queue.
    static func migrateV1(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE items (
                id          TEXT PRIMARY KEY NOT NULL,
                type        TEXT NOT NULL,
                title       TEXT NOT NULL DEFAULT '',
                note        TEXT NOT NULL DEFAULT '',
                content     TEXT NOT NULL DEFAULT '',
                url         TEXT,
                blob_hash   TEXT,
                meta        TEXT NOT NULL DEFAULT '{}',
                created_at  DATETIME NOT NULL,
                updated_at  DATETIME NOT NULL,
                trashed_at  DATETIME
            );
            CREATE INDEX items_type_idx ON items(type);
            CREATE INDEX items_created_at_idx ON items(created_at);
            CREATE INDEX items_trashed_at_idx ON items(trashed_at);
            CREATE INDEX items_blob_hash_idx ON items(blob_hash);

            CREATE TABLE tags (
                id    INTEGER PRIMARY KEY AUTOINCREMENT,
                name  TEXT NOT NULL UNIQUE COLLATE NOCASE
            );

            CREATE TABLE item_tags (
                item_id  TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
                tag_id   INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
                source   TEXT NOT NULL DEFAULT 'user',
                PRIMARY KEY (item_id, tag_id)
            );
            CREATE INDEX item_tags_tag_idx ON item_tags(tag_id);

            CREATE VIRTUAL TABLE items_fts USING fts5(
                item_id UNINDEXED, title, note, content, tags, url,
                tokenize = 'unicode61 remove_diacritics 2',
                prefix = '2 3'
            );

            CREATE TABLE enrichment_queue (
                id               INTEGER PRIMARY KEY AUTOINCREMENT,
                item_id          TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
                kind             TEXT NOT NULL,
                status           TEXT NOT NULL DEFAULT 'pending',
                attempts         INTEGER NOT NULL DEFAULT 0,
                last_error       TEXT,
                next_attempt_at  DATETIME NOT NULL,
                created_at       DATETIME NOT NULL,
                updated_at       DATETIME NOT NULL,
                UNIQUE (item_id, kind)
            );
            CREATE INDEX enrichment_queue_status_idx ON enrichment_queue(status, next_attempt_at);
            """)

        // FTS rows share the items rowid, so updates/deletes are O(log n).
        let tagsOf = { (itemRef: String) in
            """
            (SELECT coalesce(group_concat(t.name, ' '), '')
               FROM item_tags it JOIN tags t ON t.id = it.tag_id
              WHERE it.item_id = \(itemRef))
            """
        }
        try db.execute(sql: """
            CREATE TRIGGER items_fts_ai AFTER INSERT ON items BEGIN
                INSERT INTO items_fts(rowid, item_id, title, note, content, tags, url)
                VALUES (new.rowid, new.id, new.title, new.note, new.content, \(tagsOf("new.id")), coalesce(new.url, ''));
            END;

            CREATE TRIGGER items_fts_au AFTER UPDATE OF title, note, content, url ON items BEGIN
                DELETE FROM items_fts WHERE rowid = old.rowid;
                INSERT INTO items_fts(rowid, item_id, title, note, content, tags, url)
                VALUES (new.rowid, new.id, new.title, new.note, new.content, \(tagsOf("new.id")), coalesce(new.url, ''));
            END;

            CREATE TRIGGER items_fts_ad AFTER DELETE ON items BEGIN
                DELETE FROM items_fts WHERE rowid = old.rowid;
            END;

            CREATE TRIGGER item_tags_fts_ai AFTER INSERT ON item_tags BEGIN
                UPDATE items_fts SET tags = \(tagsOf("new.item_id"))
                 WHERE rowid = (SELECT rowid FROM items WHERE id = new.item_id);
            END;

            CREATE TRIGGER item_tags_fts_ad AFTER DELETE ON item_tags BEGIN
                UPDATE items_fts SET tags = \(tagsOf("old.item_id"))
                 WHERE rowid = (SELECT rowid FROM items WHERE id = old.item_id);
                DELETE FROM tags
                 WHERE id = old.tag_id
                   AND NOT EXISTS (SELECT 1 FROM item_tags WHERE tag_id = old.tag_id);
            END;

            CREATE TRIGGER tags_fts_au AFTER UPDATE OF name ON tags BEGIN
                UPDATE items_fts SET tags = \(tagsOf("items_fts.item_id"))
                 WHERE rowid IN (SELECT i.rowid FROM items i
                                   JOIN item_tags it ON it.item_id = i.id
                                  WHERE it.tag_id = new.id);
            END;
            """)
    }

    /// Schema v2: sqlite-vec table for item embeddings (see T7.1).
    static func migrateV2(_ db: Database) throws {
        try db.execute(sql: """
            CREATE VIRTUAL TABLE vec_items USING vec0(
                item_rowid INTEGER PRIMARY KEY,
                embedding float[\(EmbeddingConfig.dimension)] distance_metric=cosine
            );
            CREATE TRIGGER items_vec_ad AFTER DELETE ON items BEGIN
                DELETE FROM vec_items WHERE item_rowid = old.rowid;
            END;
            """)
    }
}

extension AppDatabase {
    /// Schema v3: user-defined custom types ("Products", …) with fields.
    /// Items link to a type; field values live in `meta.fields` and are
    /// indexed in a new `fields` FTS column (FTS table rebuilt).
    static func migrateV3(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE custom_types (
                id          TEXT PRIMARY KEY NOT NULL,
                name        TEXT NOT NULL UNIQUE COLLATE NOCASE,
                fields      TEXT NOT NULL DEFAULT '[]',
                created_at  DATETIME NOT NULL
            );
            ALTER TABLE items ADD COLUMN custom_type_id TEXT REFERENCES custom_types(id) ON DELETE SET NULL;
            CREATE INDEX items_custom_type_idx ON items(custom_type_id);

            DROP TRIGGER items_fts_ai;
            DROP TRIGGER items_fts_au;
            DROP TRIGGER items_fts_ad;
            DROP TRIGGER item_tags_fts_ai;
            DROP TRIGGER item_tags_fts_ad;
            DROP TRIGGER tags_fts_au;
            DROP TABLE items_fts;

            CREATE VIRTUAL TABLE items_fts USING fts5(
                item_id UNINDEXED, title, note, content, tags, url, fields,
                tokenize = 'unicode61 remove_diacritics 2',
                prefix = '2 3'
            );
            """)
        let tagsOf = { (itemRef: String) in
            """
            (SELECT coalesce(group_concat(t.name, ' '), '')
               FROM item_tags it JOIN tags t ON t.id = it.tag_id
              WHERE it.item_id = \(itemRef))
            """
        }
        let fieldsOf = { (row: String) in
            "(SELECT coalesce(group_concat(value, ' '), '') FROM json_each(\(row).meta, '$.fields'))"
        }
        try db.execute(sql: """
            CREATE TRIGGER items_fts_ai AFTER INSERT ON items BEGIN
                INSERT INTO items_fts(rowid, item_id, title, note, content, tags, url, fields)
                VALUES (new.rowid, new.id, new.title, new.note, new.content, \(tagsOf("new.id")),
                        coalesce(new.url, ''), \(fieldsOf("new")));
            END;

            CREATE TRIGGER items_fts_au AFTER UPDATE OF title, note, content, url, meta ON items BEGIN
                DELETE FROM items_fts WHERE rowid = old.rowid;
                INSERT INTO items_fts(rowid, item_id, title, note, content, tags, url, fields)
                VALUES (new.rowid, new.id, new.title, new.note, new.content, \(tagsOf("new.id")),
                        coalesce(new.url, ''), \(fieldsOf("new")));
            END;

            CREATE TRIGGER items_fts_ad AFTER DELETE ON items BEGIN
                DELETE FROM items_fts WHERE rowid = old.rowid;
            END;

            CREATE TRIGGER item_tags_fts_ai AFTER INSERT ON item_tags BEGIN
                UPDATE items_fts SET tags = \(tagsOf("new.item_id"))
                 WHERE rowid = (SELECT rowid FROM items WHERE id = new.item_id);
            END;

            CREATE TRIGGER item_tags_fts_ad AFTER DELETE ON item_tags BEGIN
                UPDATE items_fts SET tags = \(tagsOf("old.item_id"))
                 WHERE rowid = (SELECT rowid FROM items WHERE id = old.item_id);
                DELETE FROM tags
                 WHERE id = old.tag_id
                   AND NOT EXISTS (SELECT 1 FROM item_tags WHERE tag_id = old.tag_id);
            END;

            CREATE TRIGGER tags_fts_au AFTER UPDATE OF name ON tags BEGIN
                UPDATE items_fts SET tags = \(tagsOf("items_fts.item_id"))
                 WHERE rowid IN (SELECT i.rowid FROM items i
                                   JOIN item_tags it ON it.item_id = i.id
                                  WHERE it.tag_id = new.id);
            END;

            INSERT INTO items_fts(rowid, item_id, title, note, content, tags, url, fields)
            SELECT items.rowid, items.id, items.title, items.note, items.content, \(tagsOf("items.id")),
                   coalesce(items.url, ''), \(fieldsOf("items"))
              FROM items;
            """)
    }
}

public enum EmbeddingConfig {
    /// Matches `NLContextualEmbedding(language: .english).dimension`.
    public static let dimension = 512
}
