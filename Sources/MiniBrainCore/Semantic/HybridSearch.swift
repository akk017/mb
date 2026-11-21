import Foundation
import GRDB

/// Reciprocal Rank Fusion: score(d) = Σ 1 / (k + rank_i(d)), rank from 1.
public enum RRF {
    public static let defaultK: Double = 60

    public static func fuse(_ lists: [[String]], k: Double = defaultK) -> [(id: String, score: Double)] {
        var scores: [String: Double] = [:]
        var firstSeen: [String: Int] = [:]
        var order = 0
        for list in lists {
            for (index, id) in list.enumerated() {
                scores[id, default: 0] += 1 / (k + Double(index + 1))
                if firstSeen[id] == nil { firstSeen[id] = order; order += 1 }
            }
        }
        return scores
            .map { (id: $0.key, score: $0.value) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : firstSeen[$0.id]! < firstSeen[$1.id]! }
    }
}

/// FTS (bm25) + vector (sqlite-vec) results fused with RRF (k = 60).
/// Filters from the query apply to both lists.
public struct HybridSearchService: Sendable {
    public let database: AppDatabase
    public let embedder: (any Embedder)?
    public let fts: SearchService
    public var candidateCount = 100
    /// Vector hits farther than this (cosine distance) are ignored.
    public var maxVectorDistance: Double = 0.6
    public var k: Double = RRF.defaultK

    public init(database: AppDatabase, embedder: (any Embedder)?, parser: QueryParser = QueryParser()) {
        self.database = database
        self.embedder = embedder
        self.fts = SearchService(database: database, parser: parser)
    }

    public func search(_ text: String, limit: Int = 100) async throws -> [SearchResult] {
        try await search(fts.parser.parse(text), limit: limit)
    }

    public func search(_ query: SearchQuery, limit: Int = 100) async throws -> [SearchResult] {
        let textResults = try fts.search(query, limit: max(limit, candidateCount))
        guard query.hasText, let embedder else { return Array(textResults.prefix(limit)) }

        let queryText = query.terms.map(\.text).joined(separator: " ")
        let vector: [Float]
        do {
            vector = try await embedder.embed(queryText)
        } catch {
            return Array(textResults.prefix(limit)) // degrade to FTS
        }
        let vectorIDs = try vectorCandidates(vector, filters: query.filters)
        let fused = RRF.fuse([textResults.map(\.id), vectorIDs], k: k).prefix(limit)

        let byID = Dictionary(uniqueKeysWithValues: textResults.map { ($0.id, $0) })
        let missing = fused.map(\.id).filter { byID[$0] == nil }
        let fetched = try await database.writer.read { db in
            try Item.filter(keys: missing).fetchAll(db)
        }
        let fetchedByID = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
        return fused.compactMap { entry in
            if let r = byID[entry.id] { return SearchResult(item: r.item, snippet: r.snippet, score: entry.score) }
            if let item = fetchedByID[entry.id] { return SearchResult(item: item, snippet: nil, score: entry.score) }
            return nil
        }
    }

    /// Nearest items passing the query filters, best first.
    func vectorCandidates(_ vector: [Float], filters: [SearchFilter]) throws -> [String] {
        let maxDistance = maxVectorDistance
        let count = candidateCount
        return try database.writer.read { db in
            let neighbors = try VectorStore.nearest(to: vector, k: count, in: db).filter { $0.distance <= maxDistance }
            guard !neighbors.isEmpty else { return [] }
            let q = SearchSQLBuilder.filterIDs(neighbors.map(\.itemID), filters: filters)
            let allowed = Set(try String.fetchAll(db, sql: q.sql, arguments: q.statementArguments))
            return neighbors.map(\.itemID).filter(allowed.contains)
        }
    }
}

/// Items semantically close to a given item (excluding itself and trash).
public struct RelatedItemsService: Sendable {
    public let database: AppDatabase

    public init(database: AppDatabase) { self.database = database }

    public func related(to itemID: String, limit: Int = 6) throws -> [Item] {
        try database.writer.read { db in
            guard let vector = try VectorStore.embedding(forItem: itemID, in: db) else { return [] }
            let total = try VectorStore.count(in: db)
            let neighbors = try VectorStore.nearest(to: vector, k: min(total, limit + 50), in: db)
                .filter { $0.itemID != itemID }
            guard !neighbors.isEmpty else { return [] }
            let q = SearchSQLBuilder.filterIDs(neighbors.map(\.itemID), filters: [])
            let allowed = Set(try String.fetchAll(db, sql: q.sql, arguments: q.statementArguments))
            let ids = Array(neighbors.map(\.itemID).filter(allowed.contains).prefix(limit))
            let items = Dictionary(uniqueKeysWithValues: try Item.filter(keys: ids).fetchAll(db).map { ($0.id, $0) })
            return ids.compactMap { items[$0] }
        }
    }
}
