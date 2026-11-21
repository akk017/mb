import Foundation
import GRDB

public enum JobStatus: String, Codable, Sendable, DatabaseValueConvertible {
    case pending, running, done, failed
}

public struct EnrichmentJob: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "enrichment_queue"

    public var id: Int64?
    public var itemID: String
    public var kind: EnrichmentKind
    public var status: JobStatus
    public var attempts: Int
    public var lastError: String?
    public var nextAttemptAt: Date
    public var createdAt: Date
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case itemID = "item_id"
        case kind, status, attempts
        case lastError = "last_error"
        case nextAttemptAt = "next_attempt_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// SQL helpers over `enrichment_queue`. All state lives in the DB so pending
/// work survives restarts.
public enum EnrichmentQueue {
    /// Adds (or re-arms) a job.
    public static func enqueue(itemID: String, kind: EnrichmentKind, now: Date, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO enrichment_queue(item_id, kind, status, attempts, next_attempt_at, created_at, updated_at)
                VALUES (?, ?, 'pending', 0, ?, ?, ?)
                ON CONFLICT(item_id, kind) DO UPDATE SET
                    status = 'pending', attempts = 0, last_error = NULL,
                    next_attempt_at = excluded.next_attempt_at, updated_at = excluded.updated_at
                """,
            arguments: [itemID, kind, now, now, now])
    }

    /// Claims the oldest due pending job (marks it running).
    public static func claimNext(now: Date, in db: Database) throws -> EnrichmentJob? {
        guard var job = try EnrichmentJob.fetchOne(
            db,
            sql: """
                SELECT * FROM enrichment_queue
                 WHERE status = 'pending' AND next_attempt_at <= ?
                 ORDER BY next_attempt_at, id LIMIT 1
                """,
            arguments: [now])
        else { return nil }
        job.status = .running
        job.updatedAt = now
        try job.update(db)
        return job
    }

    public static func markDone(_ id: Int64, now: Date, in db: Database) throws {
        try db.execute(
            sql: "UPDATE enrichment_queue SET status = 'done', last_error = NULL, updated_at = ? WHERE id = ?",
            arguments: [now, id])
    }

    /// Records a failure: retries with exponential backoff, or marks failed
    /// once `maxAttempts` is reached.
    public static func markFailed(
        _ id: Int64, error: String, now: Date, maxAttempts: Int, baseBackoff: TimeInterval, in db: Database
    ) throws {
        guard var job = try EnrichmentJob.fetchOne(db, key: id) else { return }
        job.attempts += 1
        job.lastError = error
        job.updatedAt = now
        if job.attempts >= maxAttempts {
            job.status = .failed
        } else {
            job.status = .pending
            job.nextAttemptAt = now.addingTimeInterval(backoff(attempt: job.attempts, base: baseBackoff))
        }
        try job.update(db)
    }

    /// base * 2^(attempt-1): 30s, 60s, 120s…
    public static func backoff(attempt: Int, base: TimeInterval) -> TimeInterval {
        base * pow(2, Double(max(attempt - 1, 0)))
    }

    /// Jobs left `running` by a crash/quit go back to pending. The interrupted
    /// run counts as an attempt, so a job that keeps crashing the app is marked
    /// failed after `maxAttempts` instead of crash-looping on every launch.
    public static func resetRunning(now: Date, maxAttempts: Int = 3, in db: Database) throws {
        try db.execute(
            sql: """
                UPDATE enrichment_queue
                   SET attempts = attempts + 1,
                       status = CASE WHEN attempts + 1 >= ? THEN 'failed' ELSE 'pending' END,
                       last_error = CASE WHEN attempts + 1 >= ? THEN 'interrupted (app quit or crashed)' ELSE last_error END,
                       updated_at = ?
                 WHERE status = 'running'
                """,
            arguments: [maxAttempts, maxAttempts, now])
    }

    /// Queues `kind` for every item of `type` that has never had that job
    /// (used when a new job kind is introduced). Returns how many were added.
    @discardableResult
    public static func backfill(_ kind: EnrichmentKind, forType type: ItemType, now: Date, in db: Database) throws -> Int {
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO enrichment_queue(item_id, kind, status, attempts, next_attempt_at, created_at, updated_at)
                SELECT id, ?, 'pending', 0, ?, ?, ? FROM items WHERE type = ? AND trashed_at IS NULL
                """,
            arguments: [kind, now, now, now, type])
        return db.changesCount
    }

    public static func nextDueDate(in db: Database) throws -> Date? {
        try Date.fetchOne(db, sql: "SELECT min(next_attempt_at) FROM enrichment_queue WHERE status = 'pending'")
    }

    public static func jobs(for itemID: String, in db: Database) throws -> [EnrichmentJob] {
        try EnrichmentJob.filter(Column("item_id") == itemID).order(Column("id")).fetchAll(db)
    }
}
