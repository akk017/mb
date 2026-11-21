import Foundation
import GRDB
import Testing
@testable import MiniBrainCore

/// Manually driven clock. `advance(by:)` wakes any sleepers whose deadline passed.
final class FakeClock: MiniBrainCore.Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var sleepers: [(id: UUID, deadline: Date, continuation: CheckedContinuation<Void, Error>)] = []

    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) { current = start }

    var now: Date { lock.withLock { current } }

    var sleeperCount: Int { lock.withLock { sleepers.count } }

    func sleep(for seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                lock.lock()
                let deadline = current.addingTimeInterval(seconds)
                if seconds <= 0 {
                    lock.unlock()
                    cont.resume()
                    return
                }
                sleepers.append((id, deadline, cont))
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let idx = sleepers.firstIndex { $0.id == id }
            let entry = idx.map { sleepers.remove(at: $0) }
            lock.unlock()
            entry?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        let due = sleepers.filter { $0.deadline <= current }
        sleepers.removeAll { $0.deadline <= current }
        lock.unlock()
        for s in due { s.continuation.resume() }
    }

    /// Waits (in real time, briefly) until `count` tasks are sleeping on this clock.
    func waitForSleepers(_ count: Int = 1, timeout: TimeInterval = 2) async {
        let end = Date().addingTimeInterval(timeout)
        while sleeperCount < count && Date() < end {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

/// A unique temp directory removed on deinit.
final class TempDir: @unchecked Sendable {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiniBrainTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

/// In-memory DB + temp blob dir + fake clock, wired together.
struct TestEnv: Sendable {
    let tmp: TempDir
    let clock: FakeClock
    let db: AppDatabase
    let repo: ItemRepository
    let blobs: BlobStore

    init(upTo migration: String? = nil) throws {
        tmp = try TempDir()
        clock = FakeClock()
        db = try AppDatabase.inMemory(upTo: migration)
        repo = ItemRepository(database: db, clock: clock)
        blobs = BlobStore(directory: tmp.url.appendingPathComponent("blobs"))
    }

    /// Synchronous DB access (avoids GRDB's async overloads in async tests).
    func write<T>(_ updates: (Database) throws -> T) throws -> T { try db.writer.write(updates) }
    func read<T>(_ value: (Database) throws -> T) throws -> T { try db.writer.read(value) }

    func makeItem(
        _ type: ItemType = .text, title: String = "Title", note: String = "", content: String = "",
        url: String? = nil, blobHash: String? = nil, meta: Meta = [:], createdAt: Date? = nil
    ) throws -> Item {
        try repo.insert(Item(
            type: type, title: title, note: note, content: content, url: url,
            blobHash: blobHash, meta: meta, createdAt: createdAt ?? clock.now))
    }
}

enum Fixtures {
    static var directory: URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures", isDirectory: true)
    }
    static func url(_ name: String) -> URL { directory.appendingPathComponent(name) }
    static func data(_ name: String) throws -> Data { try Data(contentsOf: url(name)) }
}

extension Testing.Tag {
    /// Integration tests need Apple Intelligence or a downloaded model.
    @Tag static var integration: Self
    @Tag static var performance: Self
}
