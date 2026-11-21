import Foundation
import GRDB

/// Parameterized SQL produced from a `SearchQuery`. User input only ever
/// travels in `arguments`; FTS terms are quoted so operators are inert.
public struct SQLQuery: Equatable, Sendable {
    public var sql: String
    public var arguments: [DatabaseValue]

    public var statementArguments: StatementArguments { StatementArguments(arguments) }
}

public enum SearchSQLBuilder {
    public static let highlightStart = "<mark>"
    public static let highlightEnd = "</mark>"

    /// Column weights: item_id, title, note, content, tags, url.
    static let bm25 = "bm25(items_fts, 0.0, 10.0, 5.0, 1.0, 8.0, 2.0)"
    static let snippet = "snippet(items_fts, -1, '<mark>', '</mark>', '…', 12)"

    /// FTS5 MATCH expression: each word becomes a quoted prefix term, each
    /// phrase a quoted phrase; terms are ANDed. Returns nil without text.
    public static func matchExpression(_ terms: [SearchTerm]) -> String? {
        let parts: [String] = terms.compactMap { term in
            guard !term.isInert else { return nil }
            let quoted = "\"" + term.text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            switch term {
            case .word: return quoted + "*"
            case .phrase: return quoted
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// WHERE fragments (always including the trash filter), ANDed by callers.
    public static func filterClauses(_ filters: [SearchFilter]) -> (clauses: [String], arguments: [DatabaseValue]) {
        var clauses = ["items.trashed_at IS NULL"]
        var args: [DatabaseValue] = []
        for filter in filters {
            switch filter {
            case .type(let type):
                clauses.append("items.type = ?")
                args.append(type.rawValue.databaseValue)
            case .customType(let name):
                clauses.append("items.custom_type_id IN (SELECT id FROM custom_types WHERE name = ? COLLATE NOCASE)")
                args.append(name.databaseValue)
            case .tag(let tag):
                clauses.append("""
                    EXISTS (SELECT 1 FROM item_tags it JOIN tags t ON t.id = it.tag_id \
                    WHERE it.item_id = items.id AND t.name = ? COLLATE NOCASE)
                    """)
                args.append(tag.databaseValue)
            case .after(let date):
                clauses.append("items.created_at >= ?")
                args.append(date.databaseValue)
            case .before(let date):
                clauses.append("items.created_at < ?")
                args.append(date.databaseValue)
            case .color(let color):
                clauses.append("""
                    EXISTS (SELECT 1 FROM json_each(items.meta, '$.colors') \
                    WHERE json_each.value = ? COLLATE NOCASE)
                    """)
                args.append(color.databaseValue)
            case .meta(let key, let op, let value):
                // Key is validated by the parser; still passed as an argument.
                switch value {
                case .number(let n):
                    clauses.append("json_extract(items.meta, ?) \(op.rawValue) ?")
                    args.append(("$." + key).databaseValue)
                    args.append(n.databaseValue)
                case .string(let s):
                    let collate = (op == .eq || op == .ne) ? " COLLATE NOCASE" : ""
                    clauses.append("json_extract(items.meta, ?) \(op.rawValue) ?\(collate)")
                    args.append(("$." + key).databaseValue)
                    args.append(s.databaseValue)
                }
            }
        }
        return (clauses, args)
    }

    /// Full search statement. Columns: `items.*`, `snippet`, `score`
    /// (lower is better for text queries).
    public static func build(_ query: SearchQuery, limit: Int = 100, offset: Int = 0) -> SQLQuery {
        let (clauses, filterArgs) = filterClauses(query.filters)
        if let match = matchExpression(query.terms) {
            let sql = """
                SELECT items.*, \(snippet) AS snippet, \(bm25) AS score \
                FROM items_fts JOIN items ON items.rowid = items_fts.rowid \
                WHERE items_fts MATCH ? AND \(clauses.joined(separator: " AND ")) \
                ORDER BY score, items.created_at DESC LIMIT ? OFFSET ?
                """
            return SQLQuery(sql: sql, arguments: [match.databaseValue] + filterArgs + [limit.databaseValue, offset.databaseValue])
        }
        let sql = """
            SELECT items.*, NULL AS snippet, 0.0 AS score FROM items \
            WHERE \(clauses.joined(separator: " AND ")) \
            ORDER BY items.created_at DESC LIMIT ? OFFSET ?
            """
        return SQLQuery(sql: sql, arguments: filterArgs + [limit.databaseValue, offset.databaseValue])
    }

    /// `SELECT items.id` restricted to `ids` that pass the filters (used by
    /// hybrid / related search to filter vector hits).
    public static func filterIDs(_ ids: [String], filters: [SearchFilter]) -> SQLQuery {
        let (clauses, args) = filterClauses(filters)
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        let sql = "SELECT items.id FROM items WHERE items.id IN (\(placeholders)) AND \(clauses.joined(separator: " AND "))"
        return SQLQuery(sql: sql, arguments: ids.map(\.databaseValue) + args)
    }
}
