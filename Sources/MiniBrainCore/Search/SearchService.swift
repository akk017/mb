import Foundation
import GRDB

public struct SearchResult: Equatable, Sendable, Identifiable {
    public var item: Item
    /// FTS snippet with `<mark>`…`</mark>` around matches (text queries only).
    public var snippet: String?
    /// bm25 for text queries (lower = better), 0 otherwise; RRF score for hybrid.
    public var score: Double

    public var id: String { item.id }

    public init(item: Item, snippet: String? = nil, score: Double = 0) {
        self.item = item
        self.snippet = snippet
        self.score = score
    }
}

/// bm25-ranked full-text search with prefix matching, filters and snippets.
public struct SearchService: Sendable {
    public let database: AppDatabase
    public let parser: QueryParser

    public init(database: AppDatabase, parser: QueryParser = QueryParser()) {
        self.database = database
        self.parser = parser
    }

    public func search(_ text: String, limit: Int = 100) throws -> [SearchResult] {
        try search(parser.parse(text), limit: limit)
    }

    public func search(_ query: SearchQuery, limit: Int = 100, offset: Int = 0) throws -> [SearchResult] {
        let sql = SearchSQLBuilder.build(query, limit: limit, offset: offset)
        return try database.writer.read { db in
            try Row.fetchAll(db, sql: sql.sql, arguments: sql.statementArguments).map { row in
                SearchResult(item: try Item(row: row), snippet: row["snippet"], score: row["score"] ?? 0)
            }
        }
    }
}

/// Splits a snippet into plain/highlighted runs for display.
public enum SnippetHighlighter {
    public struct Run: Equatable, Sendable {
        public let text: String
        public let highlighted: Bool
    }

    public static func runs(_ snippet: String) -> [Run] {
        var runs: [Run] = []
        var rest = Substring(snippet)
        while let start = rest.range(of: SearchSQLBuilder.highlightStart) {
            if start.lowerBound > rest.startIndex { runs.append(Run(text: String(rest[..<start.lowerBound]), highlighted: false)) }
            rest = rest[start.upperBound...]
            if let end = rest.range(of: SearchSQLBuilder.highlightEnd) {
                runs.append(Run(text: String(rest[..<end.lowerBound]), highlighted: true))
                rest = rest[end.upperBound...]
            } else {
                runs.append(Run(text: String(rest), highlighted: true))
                rest = ""
            }
        }
        if !rest.isEmpty { runs.append(Run(text: String(rest), highlighted: false)) }
        return runs
    }
}
