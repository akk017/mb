import Foundation
import GRDB
import Testing
@testable import MiniBrainCore

let utc = TimeZone(identifier: "UTC")!
func day(_ s: String) -> Date {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = utc
    f.dateFormat = "yyyy-MM-dd"
    return f.date(from: s)!
}

// MARK: - T3.1 Parser

@Suite struct QueryParserTests {
    let parser = QueryParser(timeZone: utc)

    @Test func emptyQuery() throws {
        #expect(try parser.parse("") == SearchQuery())
        #expect(try parser.parse("   ").isEmpty)
    }

    @Test func plainWords() throws {
        #expect(try parser.parse("walnut  sideboard") == SearchQuery(terms: [.word("walnut"), .word("sideboard")]))
    }

    @Test func quotedPhrases() throws {
        let q = try parser.parse(#"lamp "mid century" "unterminated phrase"#)
        #expect(q.terms == [.word("lamp"), .phrase("mid century"), .phrase("unterminated phrase")])
    }

    @Test func typeFilter() throws {
        #expect(try parser.parse("type:image").filters == [.type(.image)])
        #expect(try parser.parse("type:PDFs").filters == [.type(.pdf)])
        #expect(try parser.parse("type:url").filters == [.type(.link)])
        #expect(throws: MiniBrainError.self) { try parser.parse("type:spaceship") }
    }

    @Test func tagFilter() throws {
        #expect(try parser.parse("tag:work").filters == [.tag("work")])
        #expect(try parser.parse(#"tag:"home office""#).filters == [.tag("home office")])
    }

    @Test func dateFilters() throws {
        let q = try parser.parse("after:2024-01-31 before:2024-03-01")
        #expect(q.filters == [.after(day("2024-01-31")), .before(day("2024-03-01"))])
    }

    @Test(arguments: ["after:2024-13-01", "before:2024-02-30", "after:yesterday", "before:2024-1-1", "after:20240101"])
    func invalidDateThrows(input: String) {
        #expect(throws: MiniBrainError.self) { try parser.parse(input) }
    }

    @Test func colorFilter() throws {
        #expect(try parser.parse("color:Red").filters == [.color("red")])
    }

    @Test func metaFilters() throws {
        #expect(try parser.parse("meta.price<100").filters == [.meta(key: "price", op: .lt, value: .number(100))])
        #expect(try parser.parse("meta.price>=9.5").filters == [.meta(key: "price", op: .ge, value: .number(9.5))])
        #expect(try parser.parse("meta.brand=ikea").filters == [.meta(key: "brand", op: .eq, value: .string("ikea"))])
        #expect(try parser.parse("meta.brand:ikea").filters == [.meta(key: "brand", op: .eq, value: .string("ikea"))])
        #expect(try parser.parse("meta.brand!=hay").filters == [.meta(key: "brand", op: .ne, value: .string("hay"))])
        #expect(try parser.parse(#"meta.store="west elm""#).filters == [.meta(key: "store", op: .eq, value: .string("west elm"))])
        // Invalid meta key → plain text.
        #expect(try parser.parse("meta.bad-key=1").terms == [.word("meta.bad-key=1")])
    }

    @Test func unknownFilterTreatedAsText() throws {
        let q = try parser.parse("foo:bar https://x.com")
        #expect(q.filters.isEmpty)
        #expect(q.terms == [.word("foo:bar"), .word("https://x.com")])
    }

    @Test func mixedQuery() throws {
        let q = try parser.parse(#"chair "eames lounge" type:image tag:wishlist after:2024-05-01 color:brown meta.price<5000"#)
        #expect(q.terms == [.word("chair"), .phrase("eames lounge")])
        #expect(q.filters == [
            .type(.image), .tag("wishlist"), .after(day("2024-05-01")), .color("brown"),
            .meta(key: "price", op: .lt, value: .number(5000)),
        ])
    }
}

// MARK: - T3.2 SQL builder

@Suite struct SearchSQLBuilderTests {
    @Test func emptyQuerySQL() {
        let q = SearchSQLBuilder.build(SearchQuery(), limit: 10)
        #expect(q.sql == "SELECT items.*, NULL AS snippet, 0.0 AS score FROM items WHERE items.trashed_at IS NULL ORDER BY items.created_at DESC LIMIT ? OFFSET ?")
        #expect(q.arguments == [10.databaseValue, 0.databaseValue])
    }

    @Test func textQuerySQL() {
        let q = SearchSQLBuilder.build(SearchQuery(terms: [.word("lamp"), .phrase("mid century")]), limit: 5)
        #expect(q.sql == """
            SELECT items.*, snippet(items_fts, -1, '<mark>', '</mark>', '…', 12) AS snippet, \
            bm25(items_fts, 0.0, 10.0, 5.0, 1.0, 8.0, 2.0) AS score \
            FROM items_fts JOIN items ON items.rowid = items_fts.rowid \
            WHERE items_fts MATCH ? AND items.trashed_at IS NULL \
            ORDER BY score, items.created_at DESC LIMIT ? OFFSET ?
            """)
        #expect(q.arguments == [#""lamp"* "mid century""#.databaseValue, 5.databaseValue, 0.databaseValue])
    }

    @Test func eachFilterSQLAndArgs() {
        let cases: [(SearchFilter, String, [DatabaseValue])] = [
            (.type(.pdf), "items.type = ?", ["pdf".databaseValue]),
            (.tag("work"), "EXISTS (SELECT 1 FROM item_tags it JOIN tags t ON t.id = it.tag_id WHERE it.item_id = items.id AND t.name = ? COLLATE NOCASE)", ["work".databaseValue]),
            (.after(day("2024-01-01")), "items.created_at >= ?", [day("2024-01-01").databaseValue]),
            (.before(day("2024-01-01")), "items.created_at < ?", [day("2024-01-01").databaseValue]),
            (.color("red"), "EXISTS (SELECT 1 FROM json_each(items.meta, '$.colors') WHERE json_each.value = ? COLLATE NOCASE)", ["red".databaseValue]),
            (.meta(key: "price", op: .lt, value: .number(100)), "json_extract(items.meta, ?) < ?", ["$.price".databaseValue, 100.0.databaseValue]),
            (.meta(key: "brand", op: .eq, value: .string("ikea")), "json_extract(items.meta, ?) = ? COLLATE NOCASE", ["$.brand".databaseValue, "ikea".databaseValue]),
        ]
        for (filter, clause, args) in cases {
            let (clauses, arguments) = SearchSQLBuilder.filterClauses([filter])
            #expect(clauses == ["items.trashed_at IS NULL", clause])
            #expect(arguments == args)
        }
    }

    @Test func filtersCombineWithAND() {
        let q = SearchSQLBuilder.build(SearchQuery(terms: [.word("x")], filters: [.type(.image), .tag("a")]))
        #expect(q.sql.contains("WHERE items_fts MATCH ? AND items.trashed_at IS NULL AND items.type = ? AND EXISTS ("))
        #expect(q.arguments.count == 1 + 2 + 2)
        #expect(!q.sql.contains(" OR "))
    }

    @Test func ftsSpecialCharsEscaped() {
        #expect(SearchSQLBuilder.matchExpression([.word(#"say"hi"#)]) == #""say""hi"*"#)
        #expect(SearchSQLBuilder.matchExpression([.word("NOT"), .word("a*"), .word("(b)")]) == #""NOT"* "a*"* "(b)"*"#)
        #expect(SearchSQLBuilder.matchExpression([.word("***"), .word("--")]) == nil)
    }

    @Test(arguments: [
        "'; DROP TABLE items; --",
        #"" OR 1=1 --"#,
        "title:secret NEAR(a b)",
        "x\" OR \"y",
        "{title} : ^ * AND OR NOT",
        "meta.price<1;DELETE FROM items",
        "tag:'); DROP TABLE tags; --",
    ])
    func injectionStringsStayInert(input: String) throws {
        let env = try TestEnv()
        _ = try env.makeItem(title: "survivor")
        let service = SearchService(database: env.db, parser: QueryParser(timeZone: utc))
        _ = try service.search(input)
        #expect(try env.repo.count() == 1)
        #expect(try env.repo.allTags().isEmpty)
        let sql = SearchSQLBuilder.build(try QueryParser(timeZone: utc).parse(input)).sql
        #expect(!sql.contains("DROP"))
        #expect(!sql.contains("DELETE"))
    }
}

// MARK: - T3.3 SearchService

@Suite struct SearchServiceTests {
    /// Seeded fixture DB.
    func seeded() throws -> (TestEnv, SearchService, [String: Item]) {
        let env = try TestEnv()
        var items: [String: Item] = [:]
        func add(_ key: String, _ type: ItemType, title: String, note: String = "", content: String = "",
                 tags: [String] = [], meta: Meta = [:], date: String) throws {
            let item = try env.makeItem(type, title: title, note: note, content: content, meta: meta, createdAt: day(date))
            for t in tags { try env.repo.attachTag(t, to: item.id) }
            items[key] = item
        }
        try add("titleLamp", .image, title: "Brass lamp", tags: ["decor"], meta: ["price": 120, "colors": ["yellow"]], date: "2024-03-01")
        try add("contentLamp", .text, title: "Shopping notes", content: "maybe a lamp for the desk, also a rug and plant", date: "2024-04-01")
        try add("noteLamp", .link, title: "Lighting store", note: "great lamp selection", meta: ["price": 40], date: "2024-05-01")
        try add("redChair", .image, title: "Red chair", tags: ["decor", "wishlist"], meta: ["price": 300, "colors": ["red"]], date: "2024-06-01")
        try add("invoice", .pdf, title: "Invoice March", content: "Total due 1,200 lamplighter services", date: "2024-03-15")
        let trashed = try env.makeItem(.text, title: "lamp in trash", createdAt: day("2024-07-01"))
        try env.repo.trash(trashed.id)
        return (env, SearchService(database: env.db, parser: QueryParser(timeZone: utc)), items)
    }

    @Test func returnsExpectedOrder() throws {
        let (_, service, items) = try seeded()
        let ids = try service.search("lamp").map(\.item.id)
        // Title match > note match > content-only matches (incl. prefix hit "lamplighter").
        #expect(Array(ids.prefix(2)) == [items["titleLamp"]!.id, items["noteLamp"]!.id])
        #expect(Set(ids.dropFirst(2)) == [items["contentLamp"]!.id, items["invoice"]!.id])
    }

    @Test func prefixMatch() throws {
        let (_, service, items) = try seeded()
        #expect(try service.search("lampl").map(\.item.id) == [items["invoice"]!.id])
        #expect(try service.search("wish").map(\.item.id) == [items["redChair"]!.id])
    }

    @Test func filtersAndTextCombined() throws {
        let (_, service, items) = try seeded()
        #expect(try service.search("lamp type:image").map(\.item.id) == [items["titleLamp"]!.id])
        #expect(try service.search("lamp meta.price<100").map(\.item.id) == [items["noteLamp"]!.id])
        #expect(try service.search("tag:decor color:red").map(\.item.id) == [items["redChair"]!.id])
        #expect(Set(try service.search("lamp after:2024-03-10 before:2024-04-30").map(\.item.id))
                == [items["contentLamp"]!.id, items["invoice"]!.id])
        #expect(try service.search("tag:decor").map(\.item.id) == [items["redChair"]!.id, items["titleLamp"]!.id])
    }

    @Test func emptyQueryListsNewestFirstWithoutTrash() throws {
        let (_, service, items) = try seeded()
        let ids = try service.search("").map(\.item.id)
        #expect(ids.count == 5)
        #expect(ids.first == items["redChair"]!.id)
    }

    @Test func snippetsHighlightMatch() throws {
        let (_, service, items) = try seeded()
        let result = try #require(try service.search("rug").first)
        #expect(result.item.id == items["contentLamp"]!.id)
        #expect(result.snippet?.contains("<mark>rug</mark>") == true)
        let runs = SnippetHighlighter.runs(result.snippet!)
        #expect(runs.contains(SnippetHighlighter.Run(text: "rug", highlighted: true)))
    }

    @Test(.tags(.performance))
    func tenThousandItemsUnder50ms() throws {
        let env = try TestEnv()
        let vocab = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india",
                     "juliet", "kilo", "lima", "mike", "november", "oscar", "papa", "quebec", "romeo",
                     "sierra", "tango", "uniform", "victor", "whiskey", "xray", "yankee", "zulu"]
        var rng = SystemRandomNumberGenerator()
        try env.db.writer.write { db in
            for i in 0..<10_000 {
                let words = (0..<30).map { _ in vocab.randomElement(using: &rng)! + String(Int.random(in: 0..<50, using: &rng)) }
                try Item(type: .text, title: "Item \(i) " + words.prefix(4).joined(separator: " "),
                         content: words.joined(separator: " "), createdAt: env.clock.now).insert(db)
            }
        }
        let service = SearchService(database: env.db)
        _ = try service.search("tango1") // warm up
        var best = Double.infinity
        for _ in 0..<5 {
            let start = Date()
            let results = try service.search("tango1 sierra", limit: 50)
            best = min(best, Date().timeIntervalSince(start))
            #expect(!results.isEmpty)
        }
        #expect(best < 0.050, "search took \(best * 1000) ms")
    }
}
