import Foundation
import GRDB
import Testing
@testable import MiniBrainCore

// MARK: - Fakes

struct FakeProcessor: EnrichmentProcessor {
    let kind: EnrichmentKind
    var result: EnrichmentResult = .empty
    func process(_ item: Item, context: EnrichmentContext) async throws -> EnrichmentResult { result }
}

struct FailingProcessor: EnrichmentProcessor {
    let kind: EnrichmentKind
    func process(_ item: Item, context: EnrichmentContext) async throws -> EnrichmentResult {
        throw MiniBrainError.enrichmentFailed("boom")
    }
}

/// Blocks until released; counts invocations.
final class BlockingProcessor: EnrichmentProcessor, @unchecked Sendable {
    let kind: EnrichmentKind
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private(set) var started = 0
    init(kind: EnrichmentKind) { self.kind = kind }

    func process(_ item: Item, context: EnrichmentContext) async throws -> EnrichmentResult {
        await withCheckedContinuation { cont in
            lock.lock()
            started += 1
            if released { lock.unlock(); cont.resume() } else { waiters.append(cont); lock.unlock() }
        }
        return EnrichmentResult(meta: ["blocked": true])
    }

    func release() {
        lock.lock()
        released = true
        let w = waiters
        waiters = []
        lock.unlock()
        w.forEach { $0.resume() }
    }
}

func jobs(_ env: TestEnv, _ itemID: String) throws -> [EnrichmentJob] {
    try env.read { try EnrichmentQueue.jobs(for: itemID, in: $0) }
}

func pollUntil(timeout: TimeInterval = 3, _ condition: () throws -> Bool) async rethrows {
    let end = Date().addingTimeInterval(timeout)
    while try !condition(), Date() < end { try? await Task.sleep(nanoseconds: 2_000_000) }
}

// MARK: - T5.1 Queue

@Suite struct EnrichmentQueueTests {
    @Test func enqueueThenProcessed() async throws {
        let env = try TestEnv()
        let capture = CaptureService(database: env.db, blobs: env.blobs, clock: env.clock, enabledKinds: [.aiTags])
        let item = try capture.capture(.plainText("A note about sourdough"))
        #expect(try jobs(env, item.id).map(\.status) == [.pending])

        let worker = EnrichmentWorker(database: env.db, blobs: env.blobs, clock: env.clock, processors: [
            FakeProcessor(kind: .aiTags, result: EnrichmentResult(meta: ["category": "food"], aiTags: ["Bread", " baking "])),
        ])
        #expect(await worker.runPending() == 1)
        #expect(try jobs(env, item.id).map(\.status) == [.done])
        #expect(try env.repo.tags(for: item.id) == [ItemTag(name: "baking", source: .ai), ItemTag(name: "bread", source: .ai)])
        #expect(try env.repo.fetch(item.id)?.meta["category"] == "food")
    }

    @Test func failureRetriedWithBackoffThenMarkedFailed() async throws {
        let env = try TestEnv()
        let item = try env.makeItem()
        try env.write { try EnrichmentQueue.enqueue(itemID: item.id, kind: .ocr, now: env.clock.now, in: $0) }
        let worker = EnrichmentWorker(database: env.db, blobs: env.blobs, clock: env.clock,
                                      processors: [FailingProcessor(kind: .ocr)], maxAttempts: 3, baseBackoff: 30)

        #expect(await worker.runPending() == 1)
        var job = try #require(try jobs(env, item.id).first)
        #expect(job.status == .pending)
        #expect(job.attempts == 1)
        #expect(job.nextAttemptAt == env.clock.now.addingTimeInterval(30))
        #expect(job.lastError?.contains("boom") == true)

        #expect(await worker.runPending() == 0) // not due yet
        env.clock.advance(by: 30)
        #expect(await worker.runPending() == 1)
        job = try #require(try jobs(env, item.id).first)
        #expect(job.attempts == 2)
        #expect(job.nextAttemptAt == env.clock.now.addingTimeInterval(60))

        env.clock.advance(by: 60)
        #expect(await worker.runPending() == 1)
        job = try #require(try jobs(env, item.id).first)
        #expect(job.status == .failed)
        #expect(job.attempts == 3)
        env.clock.advance(by: 3600)
        #expect(await worker.runPending() == 0)
    }

    @Test func backoffMath() {
        #expect(EnrichmentQueue.backoff(attempt: 1, base: 30) == 30)
        #expect(EnrichmentQueue.backoff(attempt: 2, base: 30) == 60)
        #expect(EnrichmentQueue.backoff(attempt: 4, base: 30) == 240)
    }

    @Test func pendingJobsResumeAfterRestart() async throws {
        let env = try TestEnv()
        let a = try env.makeItem(title: "a")
        let b = try env.makeItem(title: "b")
        try env.write { db in
            try EnrichmentQueue.enqueue(itemID: a.id, kind: .aiTags, now: env.clock.now, in: db)
            try EnrichmentQueue.enqueue(itemID: b.id, kind: .aiTags, now: env.clock.now, in: db)
            // Simulate a crash mid-job: one job left `running`.
            _ = try EnrichmentQueue.claimNext(now: env.clock.now, in: db)
        }
        #expect(try jobs(env, a.id).first?.status == .running)

        // "Restart": a fresh worker on the same database.
        let worker = EnrichmentWorker(database: env.db, blobs: env.blobs, clock: env.clock,
                                      processors: [FakeProcessor(kind: .aiTags)])
        try await worker.start()
        try await pollUntil {
            try jobs(env, a.id).first?.status == .done && jobs(env, b.id).first?.status == .done
        }
        await worker.stop()
        #expect(try jobs(env, a.id).first?.status == .done)
        #expect(try jobs(env, b.id).first?.status == .done)
    }

    @Test func captureNeverBlocksOnEnrichment() async throws {
        let env = try TestEnv()
        let blocking = BlockingProcessor(kind: .aiTags)
        let worker = EnrichmentWorker(database: env.db, blobs: env.blobs, clock: env.clock, processors: [blocking])
        try await worker.start()
        let capture = CaptureService(database: env.db, blobs: env.blobs, clock: env.clock,
                                     enabledKinds: [.aiTags], notifier: worker)
        let first = try capture.capture(.plainText("first"))
        await pollUntil { blocking.started == 1 } // worker is now stuck inside a job

        let start = Date()
        let second = try capture.capture(.plainText("second"))
        #expect(Date().timeIntervalSince(start) < 0.5)
        #expect(try env.repo.fetch(second.id) != nil)
        #expect(try jobs(env, second.id).first?.status == .pending)

        blocking.release()
        try await pollUntil { try jobs(env, second.id).first?.status == .done }
        #expect(try jobs(env, first.id).first?.status == .done)
        #expect(try env.repo.fetch(second.id)?.meta["blocked"] == true)
        await worker.stop()
    }

    @Test func missingProcessorMarksDone() async throws {
        let env = try TestEnv()
        let item = try env.makeItem()
        try env.write { try EnrichmentQueue.enqueue(itemID: item.id, kind: .imageTags, now: env.clock.now, in: $0) }
        let worker = EnrichmentWorker(database: env.db, blobs: env.blobs, clock: env.clock, processors: [])
        #expect(await worker.runPending() == 1)
        #expect(try jobs(env, item.id).first?.status == .done)
    }
}

// MARK: - Helpers for real processors

func runProcessor(_ processor: any EnrichmentProcessor, payload: CapturePayload, env: TestEnv) async throws -> Item {
    let capture = CaptureService(database: env.db, blobs: env.blobs, clock: env.clock, enabledKinds: [processor.kind])
    let item = try capture.capture(payload)
    let worker = EnrichmentWorker(database: env.db, blobs: env.blobs, clock: env.clock, processors: [processor])
    #expect(await worker.runPending() == 1)
    #expect(try jobs(env, item.id).first?.status == .done)
    return try #require(try env.repo.fetch(item.id))
}

// MARK: - T5.2 PDF

@Suite struct PDFTextTests {
    @Test func fixturePDFTextExtractedAndSearchable() async throws {
        let env = try TestEnv()
        let item = try await runProcessor(PDFTextProcessor(), payload: .pdfData(try Fixtures.data("sample.pdf")), env: env)
        #expect(item.content.contains("MiniBrain fixture invoice"))
        #expect(item.content.contains("walnut sideboard"))
        #expect(item.meta["page_count"] == 2)
        let hits = try SearchService(database: env.db).search("sideboard").map(\.id)
        #expect(hits == [item.id])
    }

    @Test func emptyPDFHandled() throws {
        let out = try PDFTextExtractor.extract(try Fixtures.data("empty.pdf"))
        #expect(out.text == "")
        #expect(out.pageCount == 1)
        #expect(!out.encrypted)
    }

    @Test func encryptedPDFHandled() async throws {
        let env = try TestEnv()
        let item = try await runProcessor(PDFTextProcessor(), payload: .pdfData(try Fixtures.data("encrypted.pdf")), env: env)
        #expect(item.content == "")
        #expect(item.meta["encrypted"] == true)
        #expect(item.meta["page_count"] == 1)
        #expect(try SearchService(database: env.db).search("pancake").isEmpty)
    }

    @Test func garbageDataThrows() {
        #expect(throws: MiniBrainError.self) { try PDFTextExtractor.extract(Data("%PDF-nonsense".utf8)) }
    }
}

// MARK: - T5.3 OCR

@Suite struct OCRTests {
    @Test func fixtureImageTextRecognized() async throws {
        let env = try TestEnv()
        let item = try await runProcessor(OCRProcessor(), payload: .imageData(try Fixtures.data("text.png")), env: env)
        let words = item.content.uppercased()
        #expect(words.contains("HELLO"))
        #expect(words.contains("MINIBRAIN"))
        #expect(words.contains("2024"))
        #expect(item.meta["has_text"] == true)
        #expect(try SearchService(database: env.db).search("minibrain").map(\.id) == [item.id])
    }

    @Test func blankImageGivesEmptyResultWithoutError() throws {
        #expect(try OCRRecognizer.recognize(try Fixtures.data("blank.png")) == [])
    }
}

// MARK: - T5.4 Colors

@Suite struct ColorTests {
    @Test func solidRedIsRed() throws {
        let swatches = try ColorAnalyzer.dominantColors(try Fixtures.data("red.png"))
        #expect(swatches.map(\.name) == ["red"])
        #expect(swatches.first?.hex == "#FF0000")
        #expect(swatches.first?.share == 1)
    }

    @Test func twoColorImageGivesBoth() throws {
        let names = try ColorAnalyzer.dominantColors(try Fixtures.data("two-color.png")).map(\.name)
        #expect(Set(names) == ["blue", "yellow"])
    }

    @Test func namedBuckets() {
        #expect(ColorAnalyzer.colorName(r: 1, g: 1, b: 1) == "white")
        #expect(ColorAnalyzer.colorName(r: 0.05, g: 0.05, b: 0.05) == "black")
        #expect(ColorAnalyzer.colorName(r: 0.5, g: 0.5, b: 0.5) == "gray")
        #expect(ColorAnalyzer.colorName(r: 0.1, g: 0.8, b: 0.2) == "green")
        #expect(ColorAnalyzer.colorName(r: 1, g: 0.5, b: 0) == "orange")
        #expect(ColorAnalyzer.colorName(r: 0.5, g: 0.25, b: 0.05) == "brown")
        #expect(ColorAnalyzer.colorName(r: 0.6, g: 0.2, b: 0.9) == "purple")
        #expect(ColorAnalyzer.colorName(r: 1, g: 0.4, b: 0.7) == "pink")
    }

    @Test func colorSearchFindsIt() async throws {
        let env = try TestEnv()
        let red = try await runProcessor(ColorProcessor(), payload: .imageData(try Fixtures.data("red.png")), env: env)
        #expect(red.meta["colors"] == ["red"])
        #expect(red.meta["dominant_colors"] == ["#FF0000"])
        _ = try await runProcessor(ColorProcessor(), payload: .imageData(try Fixtures.data("two-color.png")), env: env)
        #expect(try SearchService(database: env.db).search("color:red").map(\.id) == [red.id])
        #expect(try SearchService(database: env.db).search("color:yellow").count == 1)
    }
}

@Suite struct CrashLoopGuardTests {
    @Test func jobThatKeepsCrashingIsMarkedFailed() throws {
        let env = try TestEnv()
        let item = try env.makeItem()
        try env.write { try EnrichmentQueue.enqueue(itemID: item.id, kind: .embedding, now: env.clock.now, in: $0) }
        for launch in 1...3 {
            // Worker claims the job, then the app "crashes" before finishing.
            try env.write { db in
                _ = try EnrichmentQueue.claimNext(now: env.clock.now, in: db)
                try EnrichmentQueue.resetRunning(now: env.clock.now, maxAttempts: 3, in: db) // next launch
            }
            let job = try #require(try jobs(env, item.id).first)
            #expect(job.attempts == launch)
            #expect(job.status == (launch < 3 ? .pending : .failed))
        }
        #expect(try jobs(env, item.id).first?.lastError?.contains("interrupted") == true)
    }
}
