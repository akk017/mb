import Foundation
import GRDB
import Testing
@testable import MiniBrainCore
@testable import MiniBrainUI

struct FakeTranslator: QueryTranslator {
    var isAvailable = true
    var output: TranslatedQuery?
    var error: Error?
    func translate(_ sentence: String, today: Date) async throws -> TranslatedQuery {
        if let error { throw error }
        return output ?? TranslatedQuery()
    }
}

// MARK: - T8.1 NL → SearchQuery

@Suite struct NLQueryTests {
    let parser = QueryParser(timeZone: utc)
    var mapper: NLQueryMapper { NLQueryMapper(parser: parser) }

    @Test func translatorOutputMapsToCorrectSQL() throws {
        let translated = TranslatedQuery(keywords: ["chair", "mid century"], type: "image", tags: ["Wishlist"],
                                         color: "Red", after: "2024-01-01", before: "2024-07-01", maxPrice: 500, minPrice: 50)
        let query = try mapper.map(translated)
        let equivalent = try parser.parse(
            #"chair "mid century" type:image tag:wishlist color:red after:2024-01-01 before:2024-07-01 meta.price>=50 meta.price<=500"#)
        #expect(query == equivalent)
        let sql = SearchSQLBuilder.build(query)
        #expect(sql == SearchSQLBuilder.build(equivalent))
        #expect(sql.arguments.first == #""chair"* "mid century""#.databaseValue)
        #expect(sql.sql.contains("items.type = ?"))
        #expect(sql.sql.contains("json_extract(items.meta, ?) <= ?"))
    }

    @Test func anyTypeAndEmptyFieldsAddNoFilters() throws {
        let q = try mapper.map(TranslatedQuery(keywords: ["receipts"], type: "any"))
        #expect(q == SearchQuery(terms: [.word("receipts")]))
        #expect(try mapper.map(TranslatedQuery(keywords: [], type: "pdf")) == SearchQuery(filters: [.type(.pdf)]))
    }

    @Test(arguments: [
        TranslatedQuery(keywords: ["x"], type: "spaceship"),
        TranslatedQuery(keywords: ["x"], color: "ultraviolet"),
        TranslatedQuery(keywords: ["x"], after: "last tuesday"),
        TranslatedQuery(keywords: ["x"], maxPrice: -5),
        TranslatedQuery(keywords: [String(repeating: "k", count: 61)]),
        TranslatedQuery(),
    ])
    func invalidOutputRejected(output: TranslatedQuery) {
        #expect(throws: MiniBrainError.self) { try mapper.map(output) }
    }

    @Test func invalidOutputFallsBackToPlainFTS() async {
        let sentence = "show me the receipts from my dentist"
        let expected = SearchQuery(terms: [.word("receipts"), .word("dentist")])
        for translator in [
            FakeTranslator(output: TranslatedQuery(keywords: ["receipts"], type: "spaceship")),
            FakeTranslator(error: MiniBrainError.modelUnavailable("x")),
            FakeTranslator(isAvailable: false, output: TranslatedQuery(keywords: ["nope"])),
        ] {
            let service = NLQueryService(translator: translator, mapper: mapper, clock: FakeClock())
            let (query, source) = await service.query(for: sentence)
            #expect(source == .fallback)
            #expect(query == expected)
        }
        let (q, source) = await NLQueryService(translator: nil, mapper: mapper).query(for: sentence)
        #expect(source == .fallback)
        #expect(q == expected)
    }

    @Test func validOutputUsesModel() async {
        let service = NLQueryService(
            translator: FakeTranslator(output: TranslatedQuery(keywords: ["chair"], color: "red")), mapper: mapper)
        let (query, source) = await service.query(for: "red chairs I saved")
        #expect(source == .model)
        #expect(query == SearchQuery(terms: [.word("chair")], filters: [.color("red")]))
    }

    @Test func smartSearchRoutesSentencesThroughTranslator() async throws {
        let env = try TestEnv()
        let chair = try env.makeItem(.image, title: "Red chair", meta: ["colors": ["red"], "price": 300])
        _ = try env.makeItem(.image, title: "Red chair deluxe", meta: ["colors": ["red"], "price": 900])
        _ = try env.makeItem(.text, title: "chair notes")
        let translator = FakeTranslator(output: TranslatedQuery(keywords: ["chair"], type: "image", color: "red", maxPrice: 500))
        let search = SmartSearch(database: env.db, embedder: nil, translator: translator, parser: parser, clock: env.clock)
        #expect(try await search.search("show me red chairs I saved under 500").map(\.id) == [chair.id])
        // Explicit syntax bypasses the translator.
        #expect(try await search.search("chair").count == 3)
        #expect(try await search.search("chair type:text").count == 1)
    }

    @Test func naturalLanguageHeuristic() throws {
        func natural(_ s: String) throws -> Bool { NLQueryService.looksNatural(s, parsed: try parser.parse(s)) }
        #expect(try natural("show me red chairs I saved"))
        #expect(try natural("pdfs about taxes from last year"))
        #expect(try !natural("walnut sideboard"))
        #expect(try !natural("show me chairs type:image"))
        #expect(try !natural(#""exact phrase" with more words here"#))
    }

    @Test func generatedQueryRoundTrips() throws {
        let content = GeneratedQuery.generationSchema.debugDescription
        for field in ["keywords", "type", "tags", "color", "after", "before", "maxPrice", "minPrice"] {
            #expect(content.contains(field))
        }
    }

    @Test(.tags(.integration), .enabled(if: AppleIntelligence.isAvailable, "Apple Intelligence unavailable"))
    func realTranslatorSampleSentences() async throws {
        let translator = FoundationModelsTranslator()
        let today = day("2025-06-15")
        let pdfs = try mapper.map(try await translator.translate("PDFs about taxes", today: today))
        #expect(pdfs.filters.contains(.type(.pdf)))
        let red = try mapper.map(try await translator.translate("red images I saved", today: today))
        #expect(red.filters.contains(.color("red")))
    }
}

// MARK: - T8.2 Release: open existing v1 library

@Suite struct ReleaseTests {
    @Test func appOpensExistingV1DatabaseWithoutDataLoss() async throws {
        let tmp = try TempDir()
        try FileManager.default.copyItem(at: Fixtures.url("v1.sqlite"), to: tmp.url.appendingPathComponent("brain.db"))

        let env = try AppEnvironment.live(baseDirectory: tmp.url)
        let applied = try await env.database.writer.read { try AppDatabase.migrator.appliedMigrations($0) }
        #expect(applied == ["v1", "v2", "v3"])
        #expect(try env.repository.count(includeTrashed: true) == 4)
        #expect(Set(try env.repository.fetchAll().map(\.id)) == ["fixture-text", "fixture-link", "fixture-image"])
        #expect(try env.repository.fetchTrashed().map(\.id) == ["fixture-trashed"])
        #expect(try env.repository.fetch("fixture-link")?.url == "https://github.com/groue/GRDB.swift")
        #expect(Set(try env.repository.allTags().map(\.name)) == ["groceries", "dev", "wishlist"])
        #expect(try await env.search.results(for: "grocery", limit: 10).map(\.id) == ["fixture-text"])
        #expect(FileManager.default.fileExists(atPath: env.paths.blobsDirectory.path))

        // Reopening again is a no-op migration and keeps everything.
        let again = try AppEnvironment.live(baseDirectory: tmp.url)
        #expect(try again.repository.count(includeTrashed: true) == 4)
    }

    @Test func freshInstallCreatesLibrary() throws {
        let tmp = try TempDir()
        let base = tmp.url.appendingPathComponent("MiniBrain")
        let env = try AppEnvironment.live(baseDirectory: base)
        #expect(FileManager.default.fileExists(atPath: env.paths.databaseURL.path))
        #expect(try env.repository.count() == 0)
    }
}
