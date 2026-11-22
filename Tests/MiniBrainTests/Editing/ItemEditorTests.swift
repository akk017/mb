import Foundation
import GRDB
import Testing
@testable import MiniBrainCore

final class EditNotifier: EnrichmentNotifying, @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }
    func enrichmentJobsAvailable() { lock.withLock { _count += 1 } }
}

@Suite struct WebURLTests {
    @Test(arguments: [
        ("https://antonz.org/probabilistic-data-structures", "https://antonz.org/probabilistic-data-structures"),
        ("http://example.com", "http://example.com"),
        ("www.imdb.com/title/tt1", "https://www.imdb.com/title/tt1"),
        ("blog.arrtcle.com", "https://blog.arrtcle.com"),
        ("  blog.arrtcle.com/post?id=2  ", "https://blog.arrtcle.com/post?id=2"),
        ("my-site.photography", "https://my-site.photography"),
        ("HTTPS://Example.COM/A", "HTTPS://Example.COM/A"),
    ])
    func acceptsWebAddresses(raw: String, expected: String) {
        #expect(WebURL.normalize(raw)?.absoluteString == expected)
    }

    @Test(arguments: ["hello world", "", "   ", "hello", "ftp://example.com", "mailto:a@b.com",
                      "me@example.com", "example", "example.c", "exa mple.com", "https://", "javascript:alert(1)",
                      "-bad.com", "bad-.com", "1.2.3"])
    func rejectsNonWebAddresses(raw: String) {
        #expect(WebURL.normalize(raw) == nil)
    }
}

@Suite struct ItemEditorURLTests {
    func editor(_ env: TestEnv, _ notifier: EditNotifier = EditNotifier()) -> ItemEditor {
        ItemEditor(database: env.db, blobs: env.blobs, clock: env.clock, notifier: notifier)
    }

    @Test func invalidURLIsRejectedAndNothingSaved() throws {
        let env = try TestEnv()
        let item = try env.makeItem(.link, title: "antonz.org", url: "https://antonz.org/")
        #expect(throws: ItemEditError.invalidURL("hello world")) {
            try editor(env).setURL("hello world", for: item.id)
        }
        #expect(try env.repo.fetch(item.id)?.url == "https://antonz.org/")
    }

    @Test func linkURLChangeNormalizesUpdatesHostAndRefetchesPreview() throws {
        let env = try TestEnv()
        let notifier = EditNotifier()
        let item = try env.makeItem(.link, title: "My title", url: "https://old.example.com/", meta: ["host": "old.example.com"])
        try env.write { try EnrichmentQueue.enqueue(itemID: item.id, kind: .linkPreview, now: env.clock.now, in: $0) }
        try env.write { db in try db.execute(sql: "UPDATE enrichment_queue SET status = 'done'") }
        let updated = try editor(env, notifier).setURL("blog.arrtcle.com/post", for: item.id)
        #expect(updated.url == "https://blog.arrtcle.com/post")
        #expect(updated.meta["host"] == "blog.arrtcle.com")
        #expect(updated.title == "My title") // a user title stays
        let job = try #require(try jobs(env, item.id).first { $0.kind == .linkPreview })
        #expect(job.status == .pending)
        #expect(notifier.count == 1)
    }

    @Test func autoTitleFollowsNewURL() throws {
        let env = try TestEnv()
        let item = try env.makeItem(.link, title: "old.example.com/a", url: "https://old.example.com/a")
        let updated = try editor(env).setURL("https://new.example.com/b", for: item.id)
        #expect(updated.title == "new.example.com/b")
    }

    @Test func linkCannotLoseItsURLButOtherItemsCan() throws {
        let env = try TestEnv()
        let link = try env.makeItem(.link, url: "https://a.com")
        #expect(throws: ItemEditError.urlRequired) { try editor(env).setURL("  ", for: link.id) }
        let note = try env.makeItem(.text, url: "https://source.com")
        #expect(try editor(env).setURL("", for: note.id).url == nil)
    }

    @Test func anyItemCanGetAURL() throws {
        let env = try TestEnv()
        let pdf = try env.makeItem(.pdf, title: "Paper")
        let notifier = EditNotifier()
        let updated = try editor(env, notifier).setURL("www.arxiv.org/abs/1", for: pdf.id)
        #expect(updated.url == "https://www.arxiv.org/abs/1")
        #expect(updated.type == .pdf)
        #expect(try jobs(env, pdf.id).isEmpty) // no link preview for non-links
        #expect(notifier.count == 0)
    }

    @Test func unchangedURLWritesNothing() throws {
        let env = try TestEnv()
        let item = try env.makeItem(.link, url: "https://a.com/x")
        let before = try #require(try env.repo.fetch(item.id)).updatedAt
        env.clock.advance(by: 10)
        _ = try editor(env).setURL("a.com/x", for: item.id)
        #expect(try env.repo.fetch(item.id)?.updatedAt == before)
    }
}

@Suite struct ItemEditorImageTests {
    func editor(_ env: TestEnv, optimize: Bool = false, _ notifier: EditNotifier = EditNotifier()) -> ItemEditor {
        ItemEditor(database: env.db, blobs: env.blobs, clock: env.clock, notifier: notifier, optimizeImages: { optimize })
    }

    @Test func notAnImageIsRejected() throws {
        let env = try TestEnv()
        let item = try env.makeItem(.link, url: "https://a.com")
        #expect(throws: ItemEditError.invalidImage) { try editor(env).setImage(Data("hello".utf8), for: item.id) }
        #expect(try env.repo.fetch(item.id)?.meta["preview_blob"] == nil)
    }

    @Test func linkGetsCustomCoverThatReplacesOldPreview() throws {
        let env = try TestEnv()
        let old = try env.blobs.store(try Fixtures.data("red.png"), fileExtension: "png").hash
        let item = try env.makeItem(.link, url: "https://a.com", meta: ["preview_blob": .string(old)])
        let png = try Fixtures.data("two-color.png")
        let updated = try editor(env).setImage(png, for: item.id)
        let hash = try #require(updated.meta["preview_blob"]?.stringValue)
        #expect(hash == BlobStore.hash(of: png))
        #expect(updated.meta[ItemEditor.customPreviewKey] == true)
        #expect(!env.blobs.exists(old)) // old fetched preview removed
    }

    @Test func coverIsOptimizedToWebPWhenEnabled() throws {
        let env = try TestEnv()
        let item = try env.makeItem(.text, content: "note")
        let updated = try editor(env, optimize: true).setImage(try Fixtures.data("text.png"), for: item.id)
        let hash = try #require(updated.meta["preview_blob"]?.stringValue)
        #expect(env.blobs.url(for: hash)?.pathExtension == "webp")
    }

    @Test func imageItemReplacesItsImageAndReprocesses() throws {
        let env = try TestEnv()
        let notifier = EditNotifier()
        let oldData = try Fixtures.data("red.png")
        let old = try env.blobs.store(oldData, fileExtension: "png").hash
        let item = try env.makeItem(.image, title: "Shot", content: "old OCR", blobHash: old,
                                    meta: ["webp_optimized": true, "byte_size": .number(Double(oldData.count))])
        let png = try Fixtures.data("text.png")
        let updated = try editor(env, notifier).setImage(png, for: item.id)
        #expect(updated.blobHash == BlobStore.hash(of: png))
        #expect(updated.content == "") // stale OCR cleared
        #expect(updated.meta["webp_optimized"] == nil)
        #expect(updated.meta["byte_size"] == .number(Double(png.count)))
        #expect(updated.meta["preview_blob"] == nil)
        #expect(Set(try jobs(env, item.id).map(\.kind)) == Set(EnrichmentKind.kinds(for: .image)))
        #expect(notifier.count == 1)
        #expect(!env.blobs.exists(old))
    }

    @Test func removingCoverRestoresFetchedPreviewForLinks() throws {
        let env = try TestEnv()
        let item = try env.makeItem(.link, url: "https://a.com")
        let ed = editor(env)
        let withCover = try ed.setImage(try Fixtures.data("two-color.png"), for: item.id)
        let cover = try #require(withCover.meta["preview_blob"]?.stringValue)
        let cleared = try ed.removeImage(for: item.id)
        #expect(cleared.meta["preview_blob"] == nil)
        #expect(cleared.meta[ItemEditor.customPreviewKey] == nil)
        #expect(!env.blobs.exists(cover))
        #expect(try jobs(env, item.id).contains { $0.kind == .linkPreview && $0.status == .pending })
    }

    @Test func linkPreviewRefreshKeepsCustomCover() async throws {
        let env = try TestEnv()
        let item = try env.makeItem(.link, title: "a.com", url: "https://a.com")
        let withCover = try editor(env).setImage(try Fixtures.data("two-color.png"), for: item.id)
        struct Fetcher: LinkPreviewFetching {
            func preview(for url: URL) async throws -> LinkPreview { LinkPreview(title: "Fetched", imageData: try Fixtures.data("red.png")) }
        }
        let processor = LinkPreviewProcessor(fetcher: Fetcher(), isEnabled: { true }, optimizeImages: { false })
        let result = try await processor.process(withCover, context: EnrichmentContext(blobs: env.blobs, tags: []))
        #expect(result.meta["preview_blob"] == nil) // cover not overwritten
        #expect(result.title == "Fetched")
    }
}
