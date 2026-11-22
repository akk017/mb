import Foundation
import GRDB

/// What a processor learned about an item.
public struct EnrichmentResult: Sendable, Equatable {
    /// Replaces `items.content` (extracted PDF/OCR text) when non-nil.
    public var content: String?
    /// Replaces `items.title` when non-nil (e.g. a fetched page title).
    public var title: String?
    /// Shallow-merged into `items.meta`.
    public var meta: Meta
    /// Suggested tags, merged with `source = ai` (user tags win).
    public var aiTags: [String]
    /// Stored in `vec_items`.
    public var embedding: [Float]?
    /// Replaces `items.blob_hash` (e.g. after WebP conversion).
    public var blobHash: String?
    /// Blobs to delete after saving, if nothing references them anymore.
    public var obsoleteBlobs: [String]

    public init(content: String? = nil, title: String? = nil, meta: Meta = [:], aiTags: [String] = [],
                embedding: [Float]? = nil, blobHash: String? = nil, obsoleteBlobs: [String] = []) {
        self.blobHash = blobHash
        self.obsoleteBlobs = obsoleteBlobs
        self.content = content
        self.title = title
        self.meta = meta
        self.aiTags = aiTags
        self.embedding = embedding
    }

    public static let empty = EnrichmentResult()
}

public struct EnrichmentContext: Sendable {
    public let blobs: BlobStore
    public let tags: [ItemTag]

    public func blobData(for item: Item) throws -> Data {
        guard let hash = item.blobHash else { throw MiniBrainError.blobMissing(item.id) }
        return try blobs.read(hash)
    }
}

public protocol EnrichmentProcessor: Sendable {
    var kind: EnrichmentKind { get }
    func process(_ item: Item, context: EnrichmentContext) async throws -> EnrichmentResult
}

/// Actor-based worker draining `enrichment_queue`.
///
/// - Retries failures with exponential backoff up to `maxAttempts`.
/// - All state is in the DB; `start()` re-arms jobs left `running`.
/// - Capture only inserts rows and pings `enrichmentJobsAvailable()`, which
///   returns immediately.
public actor EnrichmentWorker: EnrichmentNotifying {
    public let database: AppDatabase
    public let blobs: BlobStore
    public let clock: any Clock
    public let maxAttempts: Int
    public let baseBackoff: TimeInterval
    /// Upper bound on how long the loop idles before re-checking the queue.
    public let idlePoll: TimeInterval
    private var processors: [EnrichmentKind: any EnrichmentProcessor]
    private var loop: Task<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private var pendingWake = false
    private var onJobFinished: (@Sendable (_ itemID: String, _ kind: EnrichmentKind, _ succeeded: Bool) -> Void)?
    private let log: Log

    public init(
        database: AppDatabase, blobs: BlobStore, clock: any Clock = SystemClock(),
        processors: [any EnrichmentProcessor], maxAttempts: Int = 3,
        baseBackoff: TimeInterval = 30, idlePoll: TimeInterval = 60, log: Log = .shared
    ) {
        self.log = log
        self.database = database
        self.blobs = blobs
        self.clock = clock
        self.maxAttempts = maxAttempts
        self.baseBackoff = baseBackoff
        self.idlePoll = idlePoll
        self.processors = Dictionary(processors.map { ($0.kind, $0) }, uniquingKeysWith: { _, b in b })
    }

    // MARK: - Public API

    /// Called after every job finishes (success or failure), off the main
    /// thread. The library uses it to show previews/titles as they arrive.
    public func setOnJobFinished(_ handler: (@Sendable (_ itemID: String, _ kind: EnrichmentKind, _ succeeded: Bool) -> Void)?) {
        onJobFinished = handler
    }

    /// Re-arms interrupted jobs and starts the background loop.
    public func start() throws {
        guard loop == nil else { return }
        let now = clock.now
        let maxAttempts = maxAttempts
        try database.writer.write { db in try EnrichmentQueue.resetRunning(now: now, maxAttempts: maxAttempts, in: db) }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                _ = await self.runPending()
                let wait = await self.secondsUntilNextDue()
                // Sleep until the next retry is due or until woken by a new job.
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { [clock = self.clock] in try? await clock.sleep(for: wait) }
                    group.addTask {
                        await withTaskCancellationHandler {
                            await self.waitForWake()
                        } onCancel: {
                            Task { await self.cancelWait() }
                        }
                    }
                    _ = await group.next()
                    group.cancelAll()
                }
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        cancelWait()
    }

    public var isRunning: Bool { loop != nil }

    public nonisolated func enrichmentJobsAvailable() {
        Task { await self.wake() }
    }

    private func waitForWake() async {
        if pendingWake { pendingWake = false; return }
        if Task.isCancelled { return }
        await withCheckedContinuation { waiter = $0 }
    }

    private func wake() {
        if let w = waiter { waiter = nil; w.resume() } else { pendingWake = true }
    }

    private func cancelWait() {
        if let w = waiter { waiter = nil; w.resume() }
    }

    /// Processes every job that is due now. Returns how many jobs ran.
    @discardableResult
    public func runPending() async -> Int {
        var count = 0
        while !Task.isCancelled {
            let now = clock.now
            guard let job = try? await database.writer.write({ db in try EnrichmentQueue.claimNext(now: now, in: db) })
            else { break }
            await run(job)
            count += 1
        }
        return count
    }

    // MARK: - Internals

    private func secondsUntilNextDue() -> TimeInterval {
        guard let next = try? database.writer.read({ db in try EnrichmentQueue.nextDueDate(in: db) }) else {
            return idlePoll
        }
        return min(max(next.timeIntervalSince(clock.now), 0), idlePoll)
    }

    private func run(_ job: EnrichmentJob) async {
        guard let jobID = job.id else { return }
        let started = Date()
        func elapsed() -> String { String(format: "%.2fs", Date().timeIntervalSince(started)) }
        do {
            guard let item = try await database.writer.read({ db in try Item.fetchOne(db, key: job.itemID) }) else {
                // Item vanished between claim and run; cascade will remove the row.
                return
            }
            guard let processor = processors[job.kind] else {
                // Nothing registered for this kind (e.g. feature unavailable): done.
                let now = clock.now
                try await database.writer.write { db in try EnrichmentQueue.markDone(jobID, now: now, in: db) }
                return
            }
            let tags = try ItemRepository(database: database, clock: clock).tags(for: item.id)
            let result = try await processor.process(item, context: EnrichmentContext(blobs: blobs, tags: tags))
            let now = clock.now
            try await database.writer.write { db in
                try Self.apply(result, to: item.id, now: now, in: db)
                try EnrichmentQueue.markDone(jobID, now: now, in: db)
            }
            for hash in result.obsoleteBlobs {
                _ = try? blobs.deleteIfUnreferenced(hash, database: database)
            }
            log.info("\(job.kind.rawValue) done item=\(job.itemID) in \(elapsed())", "enrichment")
            onJobFinished?(job.itemID, job.kind, true)
        } catch {
            let now = clock.now
            let message = String(describing: error)
            let maxAttempts = maxAttempts, baseBackoff = baseBackoff
            try? await database.writer.write { db in
                try EnrichmentQueue.markFailed(
                    jobID, error: message, now: now, maxAttempts: maxAttempts, baseBackoff: baseBackoff, in: db)
            }
            log.error("\(job.kind.rawValue) failed item=\(job.itemID) attempts=\(job.attempts) in \(elapsed()): \(message)", "enrichment")
            onJobFinished?(job.itemID, job.kind, false)
        }
    }

    static func apply(_ result: EnrichmentResult, to itemID: String, now: Date, in db: Database) throws {
        guard var item = try Item.fetchOne(db, key: itemID) else { return }
        var changed = false
        if let content = result.content, content != item.content {
            item.content = content
            changed = true
        }
        if let title = result.title, !title.isEmpty, title != item.title {
            item.title = title
            changed = true
        }
        if let blobHash = result.blobHash, blobHash != item.blobHash {
            item.blobHash = blobHash
            changed = true
        }
        if !result.meta.isEmpty {
            for (k, v) in result.meta { item.meta[k] = v }
            changed = true
        }
        if changed {
            item.updatedAt = now
            try item.update(db)
        }
        if !result.aiTags.isEmpty {
            try TagMerger.applyAITags(result.aiTags, to: itemID, in: db)
        }
        if let embedding = result.embedding {
            try VectorStore.upsert(embedding, forItem: itemID, in: db)
        }
    }
}
