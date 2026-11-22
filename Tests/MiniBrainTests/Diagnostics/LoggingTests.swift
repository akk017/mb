import Foundation
import GRDB
import Testing
@testable import MiniBrainCore
@testable import MiniBrainUI

private func tempLogDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("mb-logs-\(UUID().uuidString)", isDirectory: true)
}

private func contents(_ log: Log) throws -> String {
    log.flush()
    return try String(contentsOf: try #require(log.fileURL), encoding: .utf8)
}

@Suite struct LogTests {
    @Test func writesTimestampedLinesWithLevelAndCategory() throws {
        let dir = tempLogDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = Log()
        log.configure(directory: dir)
        log.info("hello", "capture")
        log.error("bad thing", "enrichment")
        let text = try contents(log)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].contains("INFO [capture] hello"))
        #expect(lines[1].contains("ERROR [enrichment] bad thing"))
        #expect(lines[0].first?.isNumber == true) // ISO-8601 timestamp first
        #expect(log.fileURL?.lastPathComponent == "minibrain.log")
    }

    @Test func unconfiguredLogWritesNoFile() {
        let log = Log()
        log.info("nowhere")
        log.flush()
        #expect(log.fileURL == nil)
    }

    @Test func rotatesAndKeepsLimitedHistory() throws {
        let dir = tempLogDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = Log()
        log.configure(directory: dir, maxBytes: 200, keep: 2)
        for i in 0..<60 { log.info("line \(i) " + String(repeating: "x", count: 40)) }
        log.flush()
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(files == ["minibrain.1.log", "minibrain.2.log", "minibrain.log"])
        // Newest lines are in the current file.
        let current = try String(contentsOf: dir.appendingPathComponent("minibrain.log"), encoding: .utf8)
        let older = try String(contentsOf: dir.appendingPathComponent("minibrain.2.log"), encoding: .utf8)
        #expect(!current.contains("line 0 ") || current.contains("line 59"))
        #expect(!older.contains("line 59"))
    }

    @Test func defaultDirectoryIsApplicationSupport() {
        #expect(Log.defaultDirectory.path.hasSuffix("Library/Application Support/MiniBrain/Logs"))
    }
}

@Suite(.serialized) struct WatchdogTests {
    @MainActor func block(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

    @Test @MainActor func logsMainThreadStallAndRecovery() async throws {
        let dir = tempLogDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = Log()
        log.configure(directory: dir)
        let watchdog = MainThreadWatchdog(threshold: 0.3, log: log)
        watchdog.start(interval: 0.05)
        defer { watchdog.stop() }
        try await Task.sleep(for: .milliseconds(150))
        block(0.9) // simulated freeze
        // Let the main queue run the watchdog's ping.
        let end = Date().addingTimeInterval(3)
        var text = ""
        while Date() < end {
            try await Task.sleep(for: .milliseconds(50))
            text = (try? contents(log)) ?? ""
            if text.contains("responsive again") { break }
        }
        #expect(text.contains("WARN [watchdog] Main thread unresponsive"))
        #expect(text.contains("Main thread responsive again after"))
    }

    @Test @MainActor func quietWhenMainThreadIsResponsive() async throws {
        let dir = tempLogDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = Log()
        log.configure(directory: dir)
        let watchdog = MainThreadWatchdog(threshold: 3, log: log)
        watchdog.start(interval: 0.05)
        try await Task.sleep(for: .milliseconds(400))
        watchdog.stop()
        let text = (try? contents(log)) ?? ""
        #expect(text.isEmpty)
    }
}

@Suite struct EnrichmentLoggingTests {
    final class Finished: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [String] = []
        var events: [String] { lock.withLock { _events } }
        func add(_ e: String) { lock.withLock { _events.append(e) } }
    }

    @Test func reportsAndLogsEachFinishedJob() async throws {
        let env = try TestEnv()
        let dir = tempLogDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = Log()
        log.configure(directory: dir)
        let ok = try env.makeItem(.link, url: "https://www.imdb.com/title/tt1")
        let bad = try env.makeItem(.text)
        try env.write { db in
            try EnrichmentQueue.enqueue(itemID: ok.id, kind: .linkPreview, now: env.clock.now, in: db)
            try EnrichmentQueue.enqueue(itemID: bad.id, kind: .ocr, now: env.clock.now, in: db)
        }
        let worker = EnrichmentWorker(database: env.db, blobs: env.blobs, clock: env.clock, processors: [
            FakeProcessor(kind: .linkPreview, result: EnrichmentResult(meta: ["page_title": "Movie"])),
            FailingProcessor(kind: .ocr),
        ], log: log)
        let finished = Finished()
        await worker.setOnJobFinished { id, kind, success in finished.add("\(id == ok.id ? "ok" : "bad") \(kind.rawValue) \(success)") }
        #expect(await worker.runPending() == 2)
        #expect(Set(finished.events) == ["ok link_preview true", "bad ocr false"])
        let text = try contents(log)
        #expect(text.contains("INFO [enrichment] link_preview done item=\(ok.id)"))
        #expect(text.contains("ERROR [enrichment] ocr failed item=\(bad.id)"))
        #expect(text.contains("boom"))
    }
}

@Suite @MainActor struct LibraryLiveRefreshTests {
    /// Link previews/titles land a few seconds after the save; the library
    /// must pick them up without being reopened.
    @Test func scheduledRefreshPicksUpEnrichedItemAndCoalesces() async throws {
        let env = try TestEnv()
        let item = try env.makeItem(.link, title: "www.imdb.com/title/tt1", url: "https://www.imdb.com/title/tt1")
        let lib = LibraryViewModel(search: SearchService(database: env.db), repository: env.repo, clock: env.clock)
        await lib.performSearch()
        #expect(lib.results.first?.item.meta["preview_blob"] == nil)

        _ = try env.repo.modify(item.id) {
            $0.title = "Kaantha (2025)"
            $0.meta["preview_blob"] = .string("abc")
        }
        lib.scheduleRefresh(after: .milliseconds(50))
        let scheduled = try #require(lib.pendingRefreshTask)
        for _ in 0..<4 { lib.scheduleRefresh(after: .milliseconds(50)) } // burst → same refresh
        #expect(lib.pendingRefreshTask == scheduled)
        await scheduled.value
        #expect(lib.results.first?.item.title == "Kaantha (2025)")
        #expect(lib.results.first?.item.meta["preview_blob"] == .string("abc"))
        #expect(lib.pendingRefreshTask == nil)
    }
}

@Suite struct LoopDetectorTests {
    final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 0) }

    @Test func reportsBurstOnceThenCoolsDown() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mb-loop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = Log()
        log.configure(directory: dir)
        let clock = Clock()
        let detector = LoopDetector(log: log, limit: 30, window: 1, cooldown: 10, now: { clock.t })
        var reports = 0
        for i in 0..<100 { // 100 flips within 0.5 s
            clock.t = Date(timeIntervalSince1970: Double(i) * 0.005)
            if detector.tick("hover.galleryCard", detail: "\(i % 2 == 0)") { reports += 1 }
        }
        #expect(reports == 1)
        clock.t = Date(timeIntervalSince1970: 20) // after cooldown, a new burst reports again
        for _ in 0..<40 { if detector.tick("hover.galleryCard") { reports += 1 } }
        #expect(reports == 2)
        log.flush()
        let text = try String(contentsOf: try #require(log.fileURL), encoding: .utf8)
        #expect(text.contains("WARN [loop] Possible UI loop: hover.galleryCard fired 31× in 1s (last: true)"))
    }

    @Test func normalRatesStayQuiet() {
        let clock = Clock()
        let detector = LoopDetector(log: Log(), limit: 30, window: 1, now: { clock.t })
        for i in 0..<200 { // 10 per second — e.g. moving the pointer across cards
            clock.t = Date(timeIntervalSince1970: Double(i) * 0.1)
            #expect(!detector.tick("hover.galleryCard"))
        }
    }
}
