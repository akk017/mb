import Foundation
import GRDB

/// Read/write access to the sqlite-vec `vec_items` table (schema v2).
/// Rows are keyed by the items rowid.
public enum VectorStore {
    public struct Neighbor: Equatable, Sendable {
        public let itemID: String
        public let distance: Double
    }

    static func blob(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func vector(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    public static func upsert(_ embedding: [Float], forItem itemID: String, in db: Database) throws {
        guard embedding.count == EmbeddingConfig.dimension else {
            throw MiniBrainError.invalidModelOutput("embedding has \(embedding.count) dims, expected \(EmbeddingConfig.dimension)")
        }
        guard let rowid = try Int64.fetchOne(db, sql: "SELECT rowid FROM items WHERE id = ?", arguments: [itemID]) else {
            throw MiniBrainError.notFound(itemID)
        }
        try db.execute(sql: "DELETE FROM vec_items WHERE item_rowid = ?", arguments: [rowid])
        try db.execute(sql: "INSERT INTO vec_items(item_rowid, embedding) VALUES (?, ?)", arguments: [rowid, blob(embedding)])
    }

    public static func embedding(forItem itemID: String, in db: Database) throws -> [Float]? {
        try Data.fetchOne(
            db,
            sql: "SELECT v.embedding FROM vec_items v JOIN items i ON i.rowid = v.item_rowid WHERE i.id = ?",
            arguments: [itemID]
        ).map(vector)
    }

    public static func count(in db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT count(*) FROM vec_items") ?? 0
    }

    /// k nearest items by cosine distance (all items, including trashed;
    /// callers filter).
    public static func nearest(to embedding: [Float], k: Int, in db: Database) throws -> [Neighbor] {
        guard k > 0 else { return [] }
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT i.id AS id, knn.distance AS distance
                  FROM (SELECT item_rowid, distance FROM vec_items
                         WHERE embedding MATCH ? AND k = ?) knn
                  JOIN items i ON i.rowid = knn.item_rowid
                 ORDER BY knn.distance
                """,
            arguments: [blob(embedding), k])
        return rows.map { Neighbor(itemID: $0["id"], distance: $0["distance"]) }
    }
}
