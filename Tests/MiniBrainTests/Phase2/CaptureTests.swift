import Foundation
import GRDB
import Testing
@testable import MiniBrainCore

let pngHeader = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
func fakePNG(_ tag: String = "a") -> Data { pngHeader + Data(tag.utf8) }
func fakePDF(_ tag: String = "a") -> Data { Data("%PDF-1.4\n\(tag)".utf8) }

// MARK: - T2.1 BlobStore

@Suite struct BlobStoreTests {
    @Test func computesCorrectSHA256() {
        #expect(BlobStore.hash(of: Data("abc".utf8))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(BlobStore.hash(of: Data())
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func sameBytesStoredOnce() throws {
        let env = try TestEnv()
        let a = try env.blobs.store(Data("hello".utf8), fileExtension: "txt")
        let b = try env.blobs.store(Data("hello".utf8), fileExtension: "txt")
        #expect(a.hash == b.hash)
        #expect(a.created && !b.created)
        let shard = env.blobs.directory.appendingPathComponent(String(a.hash.prefix(2)))
        #expect(try FileManager.default.contentsOfDirectory(atPath: shard.path).count == 1)
        #expect(env.blobs.url(for: a.hash)?.pathExtension == "txt")
    }

    @Test func readBackEqualsInput() throws {
        let env = try TestEnv()
        let bytes = Data((0..<4096).map { UInt8($0 % 251) })
        let r = try env.blobs.store(bytes)
        #expect(try env.blobs.read(r.hash) == bytes)
        #expect(throws: MiniBrainError.blobMissing("nope")) { try env.blobs.read("nope") }
    }

    @Test func deletesOnlyUnreferencedBlobs() throws {
        let env = try TestEnv()
        let used = try env.blobs.store(fakePNG("used")).hash
        let unused = try env.blobs.store(fakePNG("unused")).hash
        let item = try env.makeItem(.image, blobHash: used)
        try env.repo.trash(item.id) // trashed items still reference their blob
        #expect(try env.blobs.deleteIfUnreferenced(used, database: env.db) == false)
        #expect(env.blobs.exists(used))
        #expect(try env.blobs.deleteIfUnreferenced(unused, database: env.db) == true)
        #expect(!env.blobs.exists(unused))
    }
}

// MARK: - T2.2 Type detector

@Suite struct TypeDetectorTests {
    @Test func detectsPlainText() throws {
        let d = try TypeDetector.detect(.plainText("Buy oat milk\nand eggs"))
        #expect(d.type == .text)
        #expect(d.title == "Buy oat milk")
        #expect(d.content == "Buy oat milk\nand eggs")
    }

    @Test func detectsURL() throws {
        let d = try TypeDetector.detect(.url(URL(string: "https://example.com/a/b")!))
        #expect(d.type == .link)
        #expect(d.url == "https://example.com/a/b")
        #expect(d.title == "example.com/a/b")
        #expect(d.meta["host"] == "example.com")
    }

    @Test func detectsImage() throws {
        let d = try TypeDetector.detect(.imageData(fakePNG()))
        #expect(d.type == .image)
        #expect(d.fileExtension == "png")
        #expect(d.data == fakePNG())
    }

    @Test func detectsPDF() throws {
        let d = try TypeDetector.detect(CapturePayload(pdfData: fakePDF(), suggestedName: "Invoice 42.pdf"))
        #expect(d.type == .pdf)
        #expect(d.title == "Invoice 42")
        #expect(d.fileExtension == "pdf")
    }

    @Test func detectsHTMLAsText() throws {
        let d = try TypeDetector.detect(.html("<p>Hello <b>world</b> &amp; friends</p>"))
        #expect(d.type == .text)
        #expect(d.content == "Hello world & friends")
    }

    @Test func urlWinsOverText() throws {
        let p = CapturePayload(url: URL(string: "https://swift.org")!, plainText: "The Swift site")
        let d = try TypeDetector.detect(p)
        #expect(d.type == .link)
        #expect(d.url == "https://swift.org")
        #expect(d.title == "The Swift site")
    }

    @Test(arguments: [
        ("Version:0.9\nSourceURL:https://news.site/story\n<html><body>Big news</body></html>", "https://news.site/story"),
        (#"<html><head><base href="https://a.com/x"></head><body>hi</body></html>"#, "https://a.com/x"),
        (#"<link rel="canonical" href="https://c.org/p"><p>text</p>"#, "https://c.org/p"),
        (#"<meta property="og:url" content="https://og.io/1"><p>text</p>"#, "https://og.io/1"),
    ])
    func htmlExtractsSourceURL(html: String, expected: String) throws {
        let d = try TypeDetector.detect(.html(html))
        #expect(d.type == .text)
        #expect(d.url == expected)
        #expect(!d.content.contains("<"))
    }

    @Test func plainTextThatIsOnlyAURLBecomesLink() throws {
        let d = try TypeDetector.detect(.plainText("  https://github.com/groue/GRDB.swift \n"))
        #expect(d.type == .link)
        #expect(d.url == "https://github.com/groue/GRDB.swift")
        #expect(try TypeDetector.detect(.plainText("see https://x.com later")).type == .text)
        #expect(try TypeDetector.detect(.plainText("ftp://x.com/file")).type == .text)
    }

    @Test func unknownPayloadRejected() {
        #expect(throws: MiniBrainError.emptyPayload) { try TypeDetector.detect(CapturePayload()) }
        #expect(throws: MiniBrainError.emptyPayload) { try TypeDetector.detect(.plainText("   \n")) }
        #expect(throws: MiniBrainError.unsupportedPayload) {
            try TypeDetector.detect(.url(URL(fileURLWithPath: "/tmp/x.bin")))
        }
    }

    @Test func longTitlesTruncated() throws {
        let d = try TypeDetector.detect(.plainText(String(repeating: "word ", count: 50)))
        #expect(d.title.count <= TypeDetector.maxTitleLength)
        #expect(d.title.hasSuffix("…"))
    }
}

// MARK: - T2.3 CaptureService

struct FakePasteboard: PasteboardReading {
    var strings: [String: String] = [:]
    var datas: [String: Data] = [:]
    var availableTypes: [String] { Array(strings.keys) + Array(datas.keys) }
    func data(forType type: String) -> Data? { datas[type] ?? strings[type].map { Data($0.utf8) } }
    func string(forType type: String) -> String? { strings[type] }
}

final class CountingNotifier: EnrichmentNotifying, @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }
    func enrichmentJobsAvailable() { lock.withLock { _count += 1 } }
}

@Suite struct CaptureServiceTests {
    func service(_ env: TestEnv, ids: (@Sendable () -> String)? = nil, notifier: CountingNotifier? = nil) -> CaptureService {
        CaptureService(database: env.db, blobs: env.blobs, clock: env.clock,
                       idGenerator: ids ?? { UUID().uuidString }, notifier: notifier)
    }

    func searchable(_ env: TestEnv, _ word: String) throws -> [String] {
        try env.db.writer.read {
            try String.fetchAll($0, sql: "SELECT item_id FROM items_fts WHERE items_fts MATCH ?", arguments: [word])
        }
    }

    @Test func textEndToEnd() throws {
        let env = try TestEnv()
        let item = try service(env).capture(.plainText("Quarterly roadmap draft"))
        #expect(try env.repo.fetch(item.id) == item)
        #expect(item.type == .text)
        #expect(item.createdAt == env.clock.now)
        #expect(try searchable(env, "roadmap") == [item.id])
    }

    @Test func linkEndToEnd() throws {
        let env = try TestEnv()
        let item = try service(env).capture(.url(URL(string: "https://www.apple.com/macos")!))
        #expect(item.type == .link)
        #expect(item.blobHash == nil)
        #expect(try searchable(env, "apple") == [item.id])
    }

    @Test func imageEndToEnd() throws {
        let env = try TestEnv()
        let item = try service(env).capture(CapturePayload(imageData: fakePNG(), suggestedName: "sunset.png"))
        let hash = try #require(item.blobHash)
        #expect(try env.blobs.read(hash) == fakePNG())
        #expect(item.title == "sunset")
        #expect(try searchable(env, "sunset") == [item.id])
        let kinds = try env.db.writer.read { try EnrichmentQueue.jobs(for: item.id, in: $0) }.map(\.kind)
        #expect(kinds == EnrichmentKind.kinds(for: .image))
    }

    @Test func pdfEndToEnd() throws {
        let env = try TestEnv()
        let item = try service(env).capture(.pdfData(fakePDF()))
        #expect(item.type == .pdf)
        #expect(env.blobs.url(for: item.blobHash!)?.pathExtension == "pdf")
        #expect(item.meta["byte_size"] == .number(Double(fakePDF().count)))
    }

    @Test func htmlEndToEnd() throws {
        let env = try TestEnv()
        let item = try service(env).capture(.html("SourceURL:https://blog.dev/post\n<p>Actors are great</p>"))
        #expect(item.type == .text)
        #expect(item.url == "https://blog.dev/post")
        #expect(try searchable(env, "actors") == [item.id])
    }

    @Test func failureRollsBackWithoutOrphans() throws {
        let env = try TestEnv()
        let svc = service(env, ids: { "fixed-id" })
        _ = try svc.capture(.imageData(fakePNG("first")))
        let secondHash = BlobStore.hash(of: fakePNG("second"))
        #expect(throws: DatabaseError.self) { try svc.capture(.imageData(fakePNG("second"))) }
        #expect(!env.blobs.exists(secondHash), "orphan blob left behind")
        #expect(try env.repo.count() == 1)
        let queue = try env.db.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM enrichment_queue") }
        #expect(queue == EnrichmentKind.kinds(for: .image).count)
    }

    @Test func failureKeepsPreexistingSharedBlob() throws {
        let env = try TestEnv()
        let svc = service(env, ids: { "same" })
        let first = try svc.capture(.imageData(fakePNG("dup")))
        #expect(throws: DatabaseError.self) { try svc.capture(.imageData(fakePNG("dup"))) }
        #expect(env.blobs.exists(first.blobHash!))
    }

    @Test func emptyPayloadRejectedWithoutSideEffects() throws {
        let env = try TestEnv()
        #expect(throws: MiniBrainError.emptyPayload) { try service(env).capture(CapturePayload()) }
        #expect(try env.repo.count() == 0)
    }

    @Test func pastePathSameAsDropPath() throws {
        let cases: [(CapturePayload, FakePasteboard)] = [
            (.plainText("hello paste"), FakePasteboard(strings: [UTI.utf8Text: "hello paste"])),
            (CapturePayload(url: URL(string: "https://a.io")!, plainText: "A site"),
             FakePasteboard(strings: [UTI.url: "https://a.io", UTI.utf8Text: "A site"])),
            (.imageData(fakePNG()), FakePasteboard(datas: [UTI.png: fakePNG()])),
            (.pdfData(fakePDF()), FakePasteboard(datas: [UTI.pdf: fakePDF()])),
            (.html("<p>hi</p>"), FakePasteboard(strings: [UTI.html: "<p>hi</p>"])),
        ]
        for (payload, pasteboard) in cases {
            let dropEnv = try TestEnv(), pasteEnv = try TestEnv()
            var dropped = try service(dropEnv, ids: { "x" }).capture(payload)
            var pasted = try service(pasteEnv, ids: { "x" }).capture(pasteboard: pasteboard)
            dropped.createdAt = pasted.createdAt
            dropped.updatedAt = pasted.updatedAt
            #expect(dropped == pasted)
        }
    }

    @Test func pastedFileURLReadsFile() throws {
        let env = try TestEnv()
        let file = env.tmp.url.appendingPathComponent("scan.pdf")
        try fakePDF("file").write(to: file)
        let item = try service(env).capture(pasteboard: FakePasteboard(strings: [UTI.fileURL: file.absoluteString]))
        #expect(item.type == .pdf)
        #expect(item.title == "scan")
    }

    @Test func notifiesEnrichmentAfterCommit() throws {
        let env = try TestEnv()
        let notifier = CountingNotifier()
        _ = try service(env, notifier: notifier).capture(.plainText("ping"))
        #expect(notifier.count == 1)
    }
}
