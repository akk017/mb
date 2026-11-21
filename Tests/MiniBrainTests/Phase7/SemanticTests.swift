import Foundation
import GRDB
import NaturalLanguage
import Testing
@testable import MiniBrainCore

/// Deterministic bag-of-words embedder with a tiny synonym table, so tests
/// can exercise semantic matching without a model.
struct FakeEmbedder: Embedder {
    var dimension: Int { EmbeddingConfig.dimension }
    var synonyms: [String: String] = ["sofa": "couch", "settee": "couch", "bill": "invoice"]

    static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return h
    }

    func embed(_ text: String) async throws -> [Float] {
        var v = [Float](repeating: 0, count: dimension)
        let words = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        for w in words { v[Int(Self.fnv1a(synonyms[w] ?? w) % UInt64(dimension))] += 1 }
        return VectorMath.normalized(v)
    }
}

func embedAll(_ env: TestEnv, _ embedder: any Embedder) async throws {
    let items = try env.repo.fetchAll(includeTrashed: true)
    let worker = EnrichmentWorker(database: env.db, blobs: env.blobs, clock: env.clock,
                                  processors: [EmbeddingProcessor(embedder: embedder)])
    try env.write { db in
        for item in items { try EnrichmentQueue.enqueue(itemID: item.id, kind: .embedding, now: env.clock.now, in: db) }
    }
    #expect(await worker.runPending() == items.count)
}

func unit(_ index: Int, _ dim: Int = EmbeddingConfig.dimension) -> [Float] {
    var v = [Float](repeating: 0, count: dim)
    v[index] = 1
    return v
}

// MARK: - T7.1 sqlite-vec

@Suite struct SQLiteVecTests {
    @Test func vecVersionReturns() throws {
        let env = try TestEnv()
        let version = try env.read { try String.fetchOne($0, sql: "SELECT vec_version()") }
        #expect(version == "v0.1.6")
        #expect(try env.read { try $0.tableExists("vec_items") })
    }

    @Test func insertAndQueryNearest() throws {
        let env = try TestEnv()
        let a = try env.makeItem(title: "a"), b = try env.makeItem(title: "b"), c = try env.makeItem(title: "c")
        var near = unit(0); near[1] = 0.2
        try env.write { db in
            try VectorStore.upsert(unit(0), forItem: a.id, in: db)
            try VectorStore.upsert(near, forItem: b.id, in: db)
            try VectorStore.upsert(unit(5), forItem: c.id, in: db)
            try VectorStore.upsert(unit(0), forItem: a.id, in: db) // upsert replaces
        }
        let hits = try env.read { try VectorStore.nearest(to: unit(0), k: 3, in: $0) }
        #expect(hits.map(\.itemID) == [a.id, b.id, c.id])
        #expect(abs(hits[0].distance) < 1e-6)
        #expect(abs(hits[2].distance - 1) < 1e-6)
        #expect(try env.read { try VectorStore.count(in: $0) } == 3)
        #expect(try env.read { try VectorStore.embedding(forItem: b.id, in: $0) } == near)
    }

    @Test func wrongDimensionRejected() throws {
        let env = try TestEnv()
        let a = try env.makeItem()
        #expect(throws: MiniBrainError.self) { try env.write { try VectorStore.upsert([1, 2, 3], forItem: a.id, in: $0) } }
    }

    @Test func deletingItemRemovesVector() throws {
        let env = try TestEnv()
        let a = try env.makeItem()
        try env.write { try VectorStore.upsert(unit(1), forItem: a.id, in: $0) }
        try env.repo.delete(a.id)
        #expect(try env.read { try VectorStore.count(in: $0) } == 0)
    }

    @Test func migrationV1ToV2OnFixtureKeepsData() throws {
        let tmp = try TempDir()
        let url = tmp.url.appendingPathComponent("brain.db")
        try FileManager.default.copyItem(at: Fixtures.url("v1.sqlite"), to: url)

        let before = try AppDatabase.openSingleFile(at: url, upTo: AppDatabase.schemaV1)
        #expect(try before.writer.read { try AppDatabase.migrator.appliedMigrations($0) } == ["v1"])
        #expect(try before.writer.read { try $0.tableExists("vec_items") } == false)

        let db = try AppDatabase.open(at: url) // migrates to v2
        let (applied, hasVec, items, tags, queue) = try db.writer.read { db in
            (try AppDatabase.migrator.appliedMigrations(db), try db.tableExists("vec_items"), try Item.fetchCount(db),
             try Int.fetchOne(db, sql: "SELECT count(*) FROM tags"),
             try Int.fetchOne(db, sql: "SELECT count(*) FROM enrichment_queue"))
        }
        #expect(applied == ["v1", "v2", "v3"])
        #expect(hasVec)
        #expect(items == 4)
        #expect(tags == 3)
        #expect(queue == 1)
        let repo = ItemRepository(database: db)
        #expect(try repo.fetch("fixture-image")?.meta["price"] == 299)
        #expect(try repo.tags(for: "fixture-image") == [ItemTag(name: "wishlist", source: .ai)])
        #expect(try SearchService(database: db).search("grocery").map(\.id) == ["fixture-text"])
        #expect(try SearchService(database: db).search("color:red").map(\.id) == ["fixture-image"])
        // New schema usable on migrated data.
        try db.writer.write { try VectorStore.upsert(unit(3), forItem: "fixture-link", in: $0) }
    }
}

// MARK: - T7.2 Embedder

@Suite struct EmbedderTests {
    @Test func fakeEmbedderDimensionAndDeterminism() async throws {
        let e = FakeEmbedder()
        let a = try await e.embed("Velvet sofa in green")
        let b = try await e.embed("Velvet sofa in green")
        #expect(a.count == EmbeddingConfig.dimension)
        #expect(a == b)
        let sofa = try await e.embed("sofa"), couch = try await e.embed("couch"), invoice = try await e.embed("invoice")
        #expect(VectorMath.cosineDistance(sofa, couch) < VectorMath.cosineDistance(sofa, invoice))
    }

    @Test func contextualEmbedderMatchesSchemaDimension() throws {
        let e = try #require(ContextualEmbedder())
        #expect(e.dimension == EmbeddingConfig.dimension)
    }

    @Test func embeddingsAreQueuedAndStored() async throws {
        let env = try TestEnv()
        let capture = CaptureService(database: env.db, blobs: env.blobs, clock: env.clock, enabledKinds: [.embedding])
        let item = try capture.capture(.plainText("A green velvet couch"))
        #expect(try jobs(env, item.id).map(\.kind) == [.embedding])
        let worker = EnrichmentWorker(database: env.db, blobs: env.blobs, clock: env.clock,
                                      processors: [EmbeddingProcessor(embedder: FakeEmbedder())])
        #expect(await worker.runPending() == 1)
        let stored = try env.read { try VectorStore.embedding(forItem: item.id, in: $0) }
        #expect(stored == (try await FakeEmbedder().embed("A green velvet couch\nA green velvet couch")))
    }

    @Test(.tags(.integration), .enabled(if: ContextualEmbedder()?.hasAssets == true, "NLContextualEmbedding assets not downloaded"))
    func realEmbedderSemantics() async throws {
        let e = try #require(ContextualEmbedder())
        let sofa = try await e.embed("sofa")
        #expect(sofa.count == 512)
        #expect(try await e.embed("sofa") == sofa) // deterministic
        let couch = try await e.embed("couch"), invoice = try await e.embed("invoice")
        #expect(VectorMath.cosineDistance(sofa, couch) < VectorMath.cosineDistance(sofa, invoice))
    }
}

// MARK: - T7.3 Hybrid search

@Suite struct HybridSearchTests {
    @Test func rrfMathOnKnownLists() {
        let fused = RRF.fuse([["a", "b", "c"], ["b", "c", "d"]], k: 60)
        let scores = Dictionary(uniqueKeysWithValues: fused.map { ($0.id, $0.score) })
        #expect(abs(scores["a"]! - 1.0 / 61) < 1e-12)
        #expect(abs(scores["b"]! - (1.0 / 62 + 1.0 / 61)) < 1e-12)
        #expect(abs(scores["c"]! - (1.0 / 63 + 1.0 / 62)) < 1e-12)
        #expect(abs(scores["d"]! - 1.0 / 63) < 1e-12)
        #expect(fused.map(\.id) == ["b", "c", "a", "d"])
        #expect(RRF.fuse([]).isEmpty)
        #expect(RRF.fuse([["x"]]).first?.score == 1.0 / 61)
    }

    @Test func synonymQueryFindsItemFTSMisses() async throws {
        let env = try TestEnv()
        let couch = try env.makeItem(title: "Green velvet couch", content: "three seater")
        _ = try env.makeItem(title: "Electricity invoice", content: "due March")
        try await embedAll(env, FakeEmbedder())

        #expect(try SearchService(database: env.db).search("sofa").isEmpty)
        let hybrid = HybridSearchService(database: env.db, embedder: FakeEmbedder())
        let results = try await hybrid.search("sofa")
        #expect(results.map(\.id) == [couch.id])
        #expect(results.first?.snippet == nil)
    }

    @Test func bothListsFusedAndFiltersStillApplied() async throws {
        let env = try TestEnv()
        let couchImage = try env.makeItem(.image, title: "Couch photo")
        let couchNote = try env.makeItem(.text, title: "Couch measurements")
        let sofaLink = try env.makeItem(.link, title: "Sofa shop")
        let trashed = try env.makeItem(.image, title: "Old couch")
        try env.repo.trash(trashed.id)
        try await embedAll(env, FakeEmbedder())
        let hybrid = HybridSearchService(database: env.db, embedder: FakeEmbedder())

        let all = try await hybrid.search("sofa")
        #expect(Set(all.map(\.id)) == [couchImage.id, couchNote.id, sofaLink.id])
        #expect(all.first?.id == sofaLink.id) // in both FTS and vector lists
        #expect(try await hybrid.search("sofa type:image").map(\.id) == [couchImage.id])
        #expect(try await hybrid.search("sofa type:link").map(\.id) == [sofaLink.id])
    }

    @Test func withoutEmbedderFallsBackToFTS() async throws {
        let env = try TestEnv()
        let a = try env.makeItem(title: "couch")
        let hybrid = HybridSearchService(database: env.db, embedder: nil)
        #expect(try await hybrid.search("couch").map(\.id) == [a.id])
        #expect(try await hybrid.search("sofa").isEmpty)
    }
}

// MARK: - T7.4 Related items

@Suite struct RelatedItemsTests {
    @Test func topNeighborsExcludeSelfAndTrashed() async throws {
        let env = try TestEnv()
        let base = try env.makeItem(title: "couch velvet green")
        let close = try env.makeItem(title: "sofa velvet")
        let trashed = try env.makeItem(title: "couch velvet green blue")
        let mid = try env.makeItem(title: "green lamp")
        let far = try env.makeItem(title: "tax invoice")
        try env.repo.trash(trashed.id)
        try await embedAll(env, FakeEmbedder())

        let service = RelatedItemsService(database: env.db)
        let related = try service.related(to: base.id, limit: 2)
        #expect(related.map(\.id) == [close.id, mid.id])
        let ids = try service.related(to: base.id, limit: 10).map(\.id)
        #expect(!ids.contains(base.id))
        #expect(!ids.contains(trashed.id))
        #expect(ids.contains(far.id))
        #expect(try service.related(to: "missing").isEmpty)
    }
}

// Regression: text longer than the 2000-char model limit crashed the app
// (token ranges came from the untruncated string).
@Suite struct EmbedderLongTextTests {
    @Test(.tags(.integration), .enabled(if: ContextualEmbedder()?.hasAssets == true, "NLContextualEmbedding assets not downloaded"))
    func longTextDoesNotCrash() async throws {
        let e = try #require(ContextualEmbedder())
        let long = String(repeating: "public func start(interval: TimeInterval) { guard timer == nil else { return } } ", count: 60)
        #expect(long.count > 2000)
        let v = try await e.embed(long)
        #expect(v.count == EmbeddingConfig.dimension)
        let emoji = String(repeating: "👩‍👩‍👧‍👦 café naïve ", count: 200) // multi-scalar graphemes near the cut
        #expect(try await e.embed(emoji).count == EmbeddingConfig.dimension)
    }
}
