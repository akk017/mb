import CryptoKit
import Foundation
import GRDB

/// Content-addressed file storage: `blobs/<first 2 hex>/<sha256>[.ext]`.
/// Identical bytes are stored once.
public struct BlobStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func hash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func shardDirectory(for hash: String) -> URL {
        directory.appendingPathComponent(String(hash.prefix(2)), isDirectory: true)
    }

    /// Result of a `store` call.
    public struct StoreResult: Equatable, Sendable {
        public let hash: String
        /// False when identical bytes were already present.
        public let created: Bool
    }

    /// Writes `data` unless it is already stored. The extension only helps
    /// Finder / Quick Look; lookups are by hash.
    @discardableResult
    public func store(_ data: Data, fileExtension: String? = nil) throws -> StoreResult {
        let hash = Self.hash(of: data)
        if url(for: hash) != nil { return StoreResult(hash: hash, created: false) }
        let shard = shardDirectory(for: hash)
        try FileManager.default.createDirectory(at: shard, withIntermediateDirectories: true)
        var name = hash
        if let ext = fileExtension?.trimmingCharacters(in: CharacterSet(charactersIn: ".")), !ext.isEmpty {
            name += ".\(ext)"
        }
        try data.write(to: shard.appendingPathComponent(name), options: .atomic)
        return StoreResult(hash: hash, created: true)
    }

    /// File URL for a stored blob, or nil when absent.
    public func url(for hash: String) -> URL? {
        let shard = shardDirectory(for: hash)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: shard.path) else { return nil }
        guard let name = names.first(where: { $0 == hash || $0.hasPrefix(hash + ".") }) else { return nil }
        return shard.appendingPathComponent(name)
    }

    public func exists(_ hash: String) -> Bool { url(for: hash) != nil }

    public func read(_ hash: String) throws -> Data {
        guard let url = url(for: hash) else { throw MiniBrainError.blobMissing(hash) }
        return try Data(contentsOf: url)
    }

    /// Removes the file unconditionally.
    public func delete(_ hash: String) throws {
        guard let url = url(for: hash) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Removes the file only if no item (trashed or not) references it.
    /// Returns true when the file was deleted.
    @discardableResult
    public func deleteIfUnreferenced(_ hash: String, database: AppDatabase) throws -> Bool {
        let referenced = try database.writer.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM items
                               WHERE blob_hash = ? OR json_extract(meta, '$.preview_blob') = ?)
                """, arguments: [hash, hash]) ?? false
        }
        guard !referenced, exists(hash) else { return false }
        try delete(hash)
        return true
    }
}
