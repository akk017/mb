import Foundation
import GRDB
import Testing
@testable import MiniBrainCore

@Suite struct CSVParserTests {
    @Test func parsesQuotesEscapesNewlinesAndBOM() {
        let text = "\u{FEFF}name,notes\r\n\"Sony, WH\",\"He said \"\"wow\"\"\nline 2\"\r\nKindle,\r\n"
        #expect(CSV.parse(text) == [["name", "notes"], ["Sony, WH", "He said \"wow\"\nline 2"], ["Kindle", ""]])
    }

    @Test func detectsSemicolonAndTabSeparators() {
        #expect(CSV.parse("a;b\n1;2") == [["a", "b"], ["1", "2"]])
        #expect(CSV.parse("a\tb\n1\t2") == [["a", "b"], ["1", "2"]])
        #expect(CSV.parse("a,b\n\"x;y\",2") == [["a", "b"], ["x;y", "2"]])
    }

    @Test func skipsBlankLinesAndKeepsShortRows() {
        #expect(CSV.parse("a,b\n\n1\n,\n") == [["a", "b"], ["1"], ["", ""]])
    }

    @Test func writerQuotesOnlyWhenNeededAndRoundTrips() {
        let rows = [["title", "notes"], ["Plain", "has, comma"], ["Quote \"x\"", "multi\nline"], ["=SUM(A1)", ""]]
        let text = CSV.write(rows)
        #expect(text.hasPrefix("title,notes\r\nPlain,\"has, comma\"\r\n\"Quote \"\"x\"\"\",\"multi\nline\"\r\n"))
        #expect(text.contains("'=SUM(A1)")) // no spreadsheet formula injection
        #expect(CSV.parse(text).dropFirst(3).first == ["'=SUM(A1)", ""])
        #expect(Array(CSV.parse(text).prefix(3)) == Array(rows.prefix(3)))
    }
}

private struct CSVFixture {
    let env: TestEnv
    let types: CustomTypeRepository
    let products: CustomType
    let importer: CSVImporter
    let exporter: CSVExporter

    init() throws {
        env = try TestEnv()
        types = CustomTypeRepository(database: env.db, clock: env.clock)
        products = try types.create(name: "Products", fields: [
            FieldDefinition(id: "price", name: "Price", kind: .text),
            FieldDefinition(id: "link", name: "Buy Link", kind: .webLink),
            FieldDefinition(id: "desc", name: "Description", kind: .largeText),
        ])
        let service = ItemInputService(capture: CaptureService(database: env.db, blobs: env.blobs, clock: env.clock),
                                       repository: env.repo, customTypes: types)
        importer = CSVImporter(items: service)
        exporter = CSVExporter(repository: env.repo, customTypes: types, blobs: env.blobs)
    }
}

@Suite struct CSVImportTests {
    let csv = """
        Name,Price,Buy Link,URL,Tags,Description,Colour
        Sony WH-1000XM5,349,amazon.com/dp/B09XS7JWHH,amazon.com/dp/B09XS7JWHH,audio; wishlist,Noise cancelling,black
        Kindle,99,,,reading,,
        """

    @Test func mapsColumnsToTitleUrlTagsAndFields() throws {
        let f = try CSVFixture()
        let report = try f.importer.importCSV(csv, options: .init(type: "products"))
        #expect(report.errors.isEmpty, "\(report.errors)")
        #expect(report.imported.count == 2)
        #expect(report.ignoredColumns == ["Colour"])
        #expect(report.columns.map(\.role) == [.title, .field("Price"), .field("Buy Link"), .url, .tags, .field("Description"), .ignored])
        let sony = try #require(try f.env.repo.fetch(report.imported[0]))
        #expect(sony.title == "Sony WH-1000XM5")
        #expect(sony.type == .link)
        #expect(sony.url == "https://amazon.com/dp/B09XS7JWHH")
        #expect(sony.customTypeID == f.products.id)
        #expect(sony.fieldValues["price"] == "349")
        #expect(sony.fieldValues["desc"] == "Noise cancelling")
        #expect(Set(try f.env.repo.tags(for: sony.id).map(\.name)) == ["audio", "wishlist"])
        let kindle = try #require(try f.env.repo.fetch(report.imported[1]))
        #expect(kindle.type == .text) // title-only row
        #expect(kindle.title == "Kindle")
    }

    @Test func anyInvalidRowSavesNothingByDefault() throws {
        let f = try CSVFixture()
        let bad = "Name,URL,Buy Link\nGood,example.com,\nBad,hello world,\nAlso bad,,not a link\n"
        let report = try f.importer.importCSV(bad, options: .init(type: "Products"))
        #expect(report.imported.isEmpty)
        #expect(report.errors.map(\.row) == [3, 4]) // line numbers in the file (header = 1)
        #expect(report.errors[0].message.contains("hello world"))
        #expect(report.errors[1].message.contains("Buy Link"))
        #expect(try f.env.repo.count() == 0)
    }

    @Test func skipInvalidImportsTheGoodRows() throws {
        let f = try CSVFixture()
        let report = try f.importer.importCSV("Name,URL\nGood,example.com\nBad,hello world\n",
                                              options: .init(type: "Products", skipInvalid: true))
        #expect(report.imported.count == 1)
        #expect(report.errors.map(\.row) == [3])
        #expect(try f.env.repo.count() == 1)
    }

    @Test func dryRunValidatesAndPreviewsWithoutSaving() throws {
        let f = try CSVFixture()
        let report = try f.importer.importCSV(csv, options: .init(type: "Products", dryRun: true))
        #expect(report.imported.isEmpty)
        #expect(report.validRows == 2)
        #expect(report.totalRows == 2)
        #expect(report.sample.first?["Name"] == "Sony WH-1000XM5")
        #expect(try f.env.repo.count() == 0)
    }

    @Test func perRowTypeColumnWhenNoTypeGiven() throws {
        let f = try CSVFixture()
        let report = try f.importer.importCSV("type,title,price\nProducts,Kindle,99\n,Loose note,\n", options: .init())
        #expect(report.errors.isEmpty, "\(report.errors)")
        let items = try report.imported.map { try #require(try f.env.repo.fetch($0)) }
        #expect(items[0].customTypeID == f.products.id)
        #expect(items[0].fieldValues["price"] == "99")
        #expect(items[1].customTypeID == nil)
    }

    @Test func imageColumnReadsFilesRelativeToTheCSV() throws {
        let f = try CSVFixture()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("csv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Fixtures.data("two-color.png").write(to: dir.appendingPathComponent("headphones.png"))
        let text = "Name,URL,Image\nSony,amazon.com/dp/X,headphones.png\nPoster,,headphones.png\nMissing,,nope.png\n"
        let report = try f.importer.importCSV(text, options: .init(type: "Products", baseDirectory: dir, skipInvalid: true))
        #expect(report.imported.count == 2)
        #expect(report.errors.map(\.row) == [4])
        #expect(report.errors.first?.message.contains("not found") == true)
        let sony = try #require(try f.env.repo.fetch(report.imported[0]))
        #expect(sony.type == .link && sony.meta[ItemEditor.customPreviewKey] == true) // image = cover
        #expect(try f.env.repo.fetch(report.imported[1])?.type == .image) // image alone = Image item
    }

    @Test func globalProblemsThrow() throws {
        let f = try CSVFixture()
        #expect(throws: ItemInputError(400, "The CSV is empty")) { try f.importer.importCSV("  \n", options: .init()) }
        #expect(throws: ItemInputError.self) { try f.importer.importCSV("Name\nx", options: .init(type: "Gadgets")) }
        #expect(throws: ItemInputError.self) { try f.importer.importCSV("Colour,Size\nred,L", options: .init(type: "Products")) }
    }
}

@Suite struct CSVExportTests {
    @Test func exportsOneColumnPerFieldAndRoundTrips() throws {
        let f = try CSVFixture()
        _ = try f.importer.importCSV("""
            Name,Price,Buy Link,URL,Tags,Notes
            Sony,349,amazon.com/dp/1,amazon.com/dp/1,audio;wishlist,"Gift, maybe"
            Kindle,99,,,reading,
            """, options: .init(type: "Products"))
        let items = try f.env.repo.fetchAll()
        let text = try f.exporter.export(items, type: f.products)
        let rows = CSV.parse(text)
        #expect(rows[0] == ["title", "kind", "url", "text", "note", "tags", "image", "type", "created_at", "id",
                            "Price", "Buy Link", "Description"])
        let sony = try #require(rows.first { $0.first == "Sony" })
        #expect(sony[2] == "https://amazon.com/dp/1")
        #expect(sony[4] == "Gift, maybe")
        #expect(sony[5] == "audio; wishlist")
        #expect(sony[7] == "Products")
        #expect(sony[10] == "349")

        // Re-import the export into a fresh library: same items.
        let g = try CSVFixture()
        let report = try g.importer.importCSV(text, options: .init())
        #expect(report.errors.isEmpty, "\(report.errors)")
        #expect(report.imported.count == 2)
        let back = try g.env.repo.fetchAll().first { $0.title == "Sony" }
        #expect(back?.fieldValues["price"] == "349")
        #expect(back?.note == "Gift, maybe")
        #expect(back?.url == "https://amazon.com/dp/1")
    }

    @Test func imageColumnPointsAtTheStoredFile() throws {
        let f = try CSVFixture()
        let hash = try f.env.blobs.store(try Fixtures.data("red.png"), fileExtension: "png").hash
        let image = try f.env.makeItem(.image, title: "Red", blobHash: hash)
        let rows = CSV.parse(try f.exporter.export([image], type: nil))
        let col = try #require(rows[0].firstIndex(of: "image"))
        #expect(rows[1][col] == f.env.blobs.url(for: hash)?.path)
    }
}
