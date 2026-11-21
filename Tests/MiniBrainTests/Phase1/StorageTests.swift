import Foundation
import GRDB
import Testing
@testable import MiniBrainCore

// MARK: - T1.1 Migrations

@Suite struct MigrationTests {
    @Test func freshMigrateSucceeds() throws {
        let db = try AppDatabase.inMemory(upTo: AppDatabase.schemaV1)
        let applied = try db.writer.read { try AppDatabase.migrator.appliedMigrations($0) }
        #expect(applied == ["v1"])
    }

    @Test func allTablesAndIndexesExist() throws {
        let db = try AppDatabase.inMemory(upTo: AppDatabase.schemaV1)
        try db.writer.read { db in
            for table in ["items", "tags", "item_tags", "items_fts", "enrichment_queue"] {
                #expect(try db.tableExists(table), "missing table \(table)")
            }
            let indexes = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'")
            for index in ["items_type_idx", "items_created_at_idx", "items_trashed_at_idx",
                          "items_blob_hash_idx", "item_tags_tag_idx", "enrichment_queue_status_idx"] {
                #expect(indexes.contains(index), "missing index \(index)")
            }
            let triggers = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger'")
            #expect(triggers.count == 6)
        }
    }

    @Test func rerunIsNoOp() throws {
        let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration())
        _ = try AppDatabase(queue, upTo: AppDatabase.schemaV1)
        let schema1 = try queue.read { try String.fetchAll($0, sql: "SELECT coalesce(sql, name) FROM sqlite_master ORDER BY name") }
        _ = try AppDatabase(queue, upTo: AppDatabase.schemaV1)
        let schema2 = try queue.read { try String.fetchAll($0, sql: "SELECT coalesce(sql, name) FROM sqlite_master ORDER BY name") }
        #expect(schema1 == schema2)
        #expect(try queue.read { try AppDatabase.migrator.hasCompletedMigrations($0) } == false) // v2 still pending
    }

    @Test func foreignKeysOnAndCascadeWorks() throws {
        let env = try TestEnv()
        #expect(try env.db.writer.read { try Bool.fetchOne($0, sql: "PRAGMA foreign_keys") } == true)
        let item = try env.makeItem()
        try env.repo.attachTag("work", to: item.id)
        try env.db.writer.write { db in
            try db.execute(sql: """
                INSERT INTO enrichment_queue(item_id, kind, next_attempt_at, created_at, updated_at)
                VALUES (?, 'ocr', ?, ?, ?)
                """, arguments: [item.id, Date(), Date(), Date()])
        }
        try env.repo.delete(item.id)
        let counts = try env.db.writer.read { db in
            (try Int.fetchOne(db, sql: "SELECT count(*) FROM item_tags"),
             try Int.fetchOne(db, sql: "SELECT count(*) FROM enrichment_queue"))
        }
        #expect(counts.0 == 0)
        #expect(counts.1 == 0)
    }

    @Test func fileDatabaseUsesWAL() throws {
        let tmp = try TempDir()
        let db = try AppDatabase.open(at: tmp.url.appendingPathComponent("brain.db"))
        let mode = try db.writer.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }
        #expect(mode == "wal")
    }

    @Test func rejectsOrphanItemTag() throws {
        let env = try TestEnv()
        #expect(throws: DatabaseError.self) {
            try env.db.writer.write { db in
                try db.execute(sql: "INSERT INTO tags(name) VALUES ('x')")
                try db.execute(sql: "INSERT INTO item_tags(item_id, tag_id) VALUES ('nope', 1)")
            }
        }
    }
}

// MARK: - T1.2 CRUD

@Suite struct ItemRepositoryTests {
    @Test(arguments: ItemType.allCases)
    func insertFetchUpdateDeleteEachType(type: ItemType) throws {
        let env = try TestEnv()
        let item = try env.makeItem(type, title: "A \(type)", content: "body", url: type == .link ? "https://a.b" : nil,
                                    blobHash: type == .image || type == .pdf ? "abc" : nil)
        var fetched = try #require(try env.repo.fetch(item.id))
        #expect(fetched == item)

        fetched.title = "Edited"
        fetched.note = "a note"
        try env.repo.update(fetched)
        let edited = try #require(try env.repo.fetch(item.id))
        #expect(edited.title == "Edited")
        #expect(edited.note == "a note")
        #expect(edited.type == type)

        try env.repo.delete(item.id)
        #expect(try env.repo.fetch(item.id) == nil)
    }

    @Test func updatedAtChangesOnEdit() throws {
        let env = try TestEnv()
        let item = try env.makeItem()
        env.clock.advance(by: 60)
        var copy = item
        copy.note = "changed"
        let saved = try env.repo.update(copy)
        #expect(saved.updatedAt == item.updatedAt.addingTimeInterval(60))
        #expect(try env.repo.fetch(item.id)?.updatedAt == saved.updatedAt)
        #expect(saved.createdAt == item.createdAt)

        env.clock.advance(by: 5)
        let modified = try env.repo.modify(item.id) { $0.title = "x" }
        #expect(modified.updatedAt == item.updatedAt.addingTimeInterval(65))
    }

    @Test func metaJSONRoundTrips() throws {
        let env = try TestEnv()
        let meta: Meta = [
            "price": 12.5, "count": 3, "flag": true, "name": "lamp", "none": nil,
            "colors": ["red", "blue"], "nested": ["a": ["b": 1]],
        ]
        let item = try env.makeItem(meta: meta)
        #expect(try env.repo.fetch(item.id)?.meta == meta)
        let raw = try env.db.writer.read { try String.fetchOne($0, sql: "SELECT meta FROM items") }
        #expect(raw?.hasPrefix("{") == true)
        let extracted = try env.db.writer.read {
            try Double.fetchOne($0, sql: "SELECT json_extract(meta, '$.price') FROM items")
        }
        #expect(extracted == 12.5)
    }

    @Test func updateMissingItemThrows() throws {
        let env = try TestEnv()
        let ghost = Item(type: .text, createdAt: env.clock.now)
        #expect(throws: MiniBrainError.notFound(ghost.id)) { try env.repo.update(ghost) }
    }
}

// MARK: - T1.3 Tags

@Suite struct TagTests {
    @Test func tagsAreCaseInsensitiveUnique() throws {
        let env = try TestEnv()
        let a = try env.makeItem(title: "a")
        let b = try env.makeItem(title: "b")
        try env.repo.attachTag("Work", to: a.id)
        try env.repo.attachTag("work", to: b.id)
        try env.repo.attachTag("WORK", to: a.id)
        let all = try env.repo.allTags()
        #expect(all.count == 1)
        #expect(all.first?.name == "Work")
        #expect(try env.repo.tags(for: a.id).map(\.name) == ["Work"])
        #expect(try env.repo.tags(for: b.id).map(\.name) == ["Work"])
    }

    @Test func attachAndDetach() throws {
        let env = try TestEnv()
        let item = try env.makeItem()
        try env.repo.attachTag("  design ", to: item.id)
        try env.repo.attachTag("ideas", to: item.id)
        #expect(try env.repo.tags(for: item.id).map(\.name) == ["design", "ideas"])
        try env.repo.detachTag("DESIGN", from: item.id)
        #expect(try env.repo.tags(for: item.id).map(\.name) == ["ideas"])
    }

    @Test func emptyTagRejected() throws {
        let env = try TestEnv()
        let item = try env.makeItem()
        #expect(throws: MiniBrainError.self) { try env.repo.attachTag("   ", to: item.id) }
    }

    @Test func tagDeletedWhenNoItemsUseIt() throws {
        let env = try TestEnv()
        let a = try env.makeItem()
        let b = try env.makeItem()
        try env.repo.attachTag("shared", to: a.id)
        try env.repo.attachTag("shared", to: b.id)
        try env.repo.attachTag("solo", to: a.id)
        try env.repo.detachTag("shared", from: a.id)
        #expect(Set(try env.repo.allTags().map(\.name)) == ["shared", "solo"])
        try env.repo.detachTag("shared", from: b.id)
        #expect(try env.repo.allTags().map(\.name) == ["solo"])
        try env.repo.delete(a.id) // cascade removes item_tags -> trigger removes tag
        #expect(try env.repo.allTags().isEmpty)
    }

    @Test func renameMergesIntoExistingTag() throws {
        let env = try TestEnv()
        let a = try env.makeItem()
        let b = try env.makeItem()
        try env.repo.attachTag("todo", to: a.id)
        try env.repo.attachTag("later", to: b.id)
        try env.repo.renameTag("later", to: "TODO")
        #expect(try env.repo.allTags().map(\.name) == ["todo"])
        #expect(try env.repo.tags(for: b.id).map(\.name) == ["todo"])
    }
}

// MARK: - T1.4 FTS sync

@Suite struct FTSSyncTests {
    func matches(_ env: TestEnv, _ query: String) throws -> [String] {
        try env.db.writer.read { db in
            try String.fetchAll(db, sql: "SELECT item_id FROM items_fts WHERE items_fts MATCH ? ORDER BY item_id",
                                arguments: [query])
        }
    }

    @Test func newItemSearchable() throws {
        let env = try TestEnv()
        let item = try env.makeItem(title: "Mid-century walnut sideboard", content: "teak legs")
        #expect(try matches(env, "walnut") == [item.id])
        #expect(try matches(env, "teak") == [item.id])
    }

    @Test func editedTitleAndNoteReflected() throws {
        let env = try TestEnv()
        var item = try env.makeItem(title: "old title")
        item.title = "brand new heading"
        item.note = "remember the zebra"
        try env.repo.update(item)
        #expect(try matches(env, "old").isEmpty)
        #expect(try matches(env, "heading") == [item.id])
        #expect(try matches(env, "zebra") == [item.id])
    }

    @Test func deletedItemGone() throws {
        let env = try TestEnv()
        let item = try env.makeItem(title: "ephemeral")
        try env.repo.delete(item.id)
        #expect(try matches(env, "ephemeral").isEmpty)
        #expect(try env.db.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM items_fts") } == 0)
    }

    @Test func tagAttachAndRenameReflected() throws {
        let env = try TestEnv()
        let item = try env.makeItem(title: "plain")
        try env.repo.attachTag("furniture", to: item.id)
        #expect(try matches(env, "tags:furniture") == [item.id])
        try env.repo.renameTag("furniture", to: "decor")
        #expect(try matches(env, "tags:furniture").isEmpty)
        #expect(try matches(env, "tags:decor") == [item.id])
        try env.repo.detachTag("decor", from: item.id)
        #expect(try matches(env, "decor").isEmpty)
    }
}

// MARK: - T1.5 Trash + purge

@Suite struct TrashTests {
    @Test func trashedItemsHiddenFromQueries() throws {
        let env = try TestEnv()
        let keep = try env.makeItem(title: "keep")
        let gone = try env.makeItem(title: "gone")
        try env.repo.trash(gone.id)
        #expect(try env.repo.fetchAll().map(\.id) == [keep.id])
        #expect(try env.repo.count() == 1)
        #expect(try env.repo.fetchTrashed().map(\.id) == [gone.id])
        #expect(try env.repo.fetch(gone.id)?.isTrashed == true)
    }

    @Test func restoreWorks() throws {
        let env = try TestEnv()
        let item = try env.makeItem()
        try env.repo.trash(item.id)
        try env.repo.restore(item.id)
        #expect(try env.repo.fetchAll().map(\.id) == [item.id])
        #expect(try env.repo.fetch(item.id)?.trashedAt == nil)
    }

    @Test func purgeRemovesItemsOlderThan30Days() throws {
        let env = try TestEnv()
        let old = try env.makeItem(title: "old")
        let recent = try env.makeItem(title: "recent")
        let live = try env.makeItem(title: "live")
        try env.repo.trash(old.id)
        env.clock.advance(by: 20 * 86_400)
        try env.repo.trash(recent.id)
        env.clock.advance(by: 11 * 86_400) // old: 31 days, recent: 11 days

        #expect(try env.repo.purgeTrash() == 1)
        #expect(try env.repo.fetch(old.id) == nil)
        #expect(try env.repo.fetch(recent.id) != nil)
        #expect(try env.repo.fetch(live.id) != nil)
    }

    @Test func purgeRemovesBlobOnlyIfUnreferenced() throws {
        let env = try TestEnv()
        let shared = try env.blobs.store(Data("shared".utf8), fileExtension: "png").hash
        let lonely = try env.blobs.store(Data("lonely".utf8), fileExtension: "png").hash
        let a = try env.makeItem(.image, blobHash: shared)
        _ = try env.makeItem(.image, blobHash: shared)
        let c = try env.makeItem(.image, blobHash: lonely)
        try env.repo.trash(a.id)
        try env.repo.trash(c.id)
        env.clock.advance(by: 31 * 86_400)
        #expect(try env.repo.purgeTrash(blobs: env.blobs) == 2)
        #expect(env.blobs.exists(shared))
        #expect(!env.blobs.exists(lonely))
    }
}
