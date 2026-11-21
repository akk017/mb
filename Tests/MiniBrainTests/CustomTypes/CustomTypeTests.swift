import AppKit
import Foundation
import GRDB
import Testing
@testable import MiniBrainCore
@testable import MiniBrainUI

func productsType(_ repo: CustomTypeRepository) throws -> CustomType {
    try repo.create(name: "Products", fields: [
        FieldDefinition(name: "Name", kind: .text),
        FieldDefinition(name: "Description", kind: .largeText),
        FieldDefinition(name: "Shop Link", kind: .webLink),
    ])
}

// MARK: - Schema v3

@Suite struct CustomTypeSchemaTests {
    @Test func migrationV3CreatesTablesAndColumn() throws {
        let env = try TestEnv()
        let (hasTable, columns) = try env.read { db in
            (try db.tableExists("custom_types"), try db.columns(in: "items").map(\.name))
        }
        #expect(hasTable)
        #expect(columns.contains("custom_type_id"))
        #expect(try env.read { try AppDatabase.migrator.appliedMigrations($0) } == ["v1", "v2", "v3"])
    }

    @Test func v2DatabaseUpgradesAndKeepsFTS() throws {
        let tmp = try TempDir()
        let url = tmp.url.appendingPathComponent("brain.db")
        let v2 = try AppDatabase.openSingleFile(at: url, upTo: AppDatabase.schemaV2)
        let repo = ItemRepository(database: v2)
        let item = try repo.insert(Item(type: .text, title: "Walnut desk", createdAt: Date()))
        try repo.attachTag("furniture", to: item.id)
        try v2.writer.close()

        let v3 = try AppDatabase.openSingleFile(at: url)
        #expect(try SearchService(database: v3).search("walnut").map(\.id) == [item.id])
        #expect(try SearchService(database: v3).search("furniture").map(\.id) == [item.id])
        #expect(try ItemRepository(database: v3).fetch(item.id)?.customTypeID == nil)
    }

    @Test func itemsStillWritableToV1Schema() throws {
        let db = try AppDatabase.inMemory(upTo: AppDatabase.schemaV1)
        let item = try ItemRepository(database: db).insert(Item(type: .text, title: "old schema", createdAt: Date()))
        #expect(try ItemRepository(database: db).fetch(item.id)?.title == "old schema")
    }
}

// MARK: - Repository

@Suite struct CustomTypeRepositoryTests {
    @Test func createListFind() throws {
        let env = try TestEnv()
        let repo = CustomTypeRepository(database: env.db, clock: env.clock)
        let products = try productsType(repo)
        _ = try repo.create(name: "  Books ", fields: [FieldDefinition(name: " ", kind: .text)])
        #expect(try repo.all().map(\.name) == ["Books", "Products"])
        #expect(try repo.find(named: "products")?.id == products.id)
        #expect(try repo.find(named: "Books")?.fields.isEmpty == true) // blank field names dropped
        #expect(repo.exists(named: "PRODUCTS"))
        #expect(!repo.exists(named: "Recipes"))
    }

    @Test func rejectsEmptyAndDuplicateNames() throws {
        let env = try TestEnv()
        let repo = CustomTypeRepository(database: env.db, clock: env.clock)
        _ = try productsType(repo)
        #expect(throws: CustomTypeError.emptyName) { try repo.create(name: "  ") }
        #expect(throws: CustomTypeError.duplicateName("products")) { try repo.create(name: "products") }
        var books = try repo.create(name: "Books")
        books.name = "PRODUCTS"
        #expect(throws: CustomTypeError.duplicateName("PRODUCTS")) { try repo.update(books) }
    }

    @Test func assignPrefillsAndFieldValuesPersist() throws {
        let env = try TestEnv()
        let repo = CustomTypeRepository(database: env.db, clock: env.clock)
        let type = try productsType(repo)
        let link = try env.makeItem(.link, title: "Aeron Chair", url: "https://store.example.com/aeron")
        env.clock.advance(by: 10)
        let assigned = try repo.assign(link.id, to: type.id)
        #expect(assigned.customTypeID == type.id)
        #expect(assigned.fieldValues == [type.fields[0].id: "Aeron Chair", type.fields[2].id: "https://store.example.com/aeron"])
        #expect(assigned.updatedAt == link.updatedAt.addingTimeInterval(10))

        let saved = try repo.setFieldValues([
            type.fields[1].id: "  Ergonomic mesh chair  ", type.fields[0].id: "", "unknown-field": "x",
        ], for: link.id)
        #expect(saved.fieldValues == [type.fields[1].id: "Ergonomic mesh chair"])
        #expect(try env.repo.fetch(link.id)?.fieldValues == saved.fieldValues)
    }

    @Test func unassignClearsTypeAndValues() throws {
        let env = try TestEnv()
        let repo = CustomTypeRepository(database: env.db, clock: env.clock)
        let type = try productsType(repo)
        let item = try env.makeItem(title: "Lamp")
        try repo.assign(item.id, to: type.id)
        try repo.assign(item.id, to: nil)
        let fetched = try #require(try env.repo.fetch(item.id))
        #expect(fetched.customTypeID == nil)
        #expect(fetched.fieldValues.isEmpty)
    }

    @Test func removingFieldDropsItsValues() throws {
        let env = try TestEnv()
        let repo = CustomTypeRepository(database: env.db, clock: env.clock)
        var type = try productsType(repo)
        let item = try env.makeItem(title: "Desk")
        try repo.assign(item.id, to: type.id)
        try repo.setFieldValues([type.fields[1].id: "oak", type.fields[0].id: "Desk"], for: item.id)
        type.fields.remove(at: 1)
        try repo.update(type)
        #expect(try env.repo.fetch(item.id)?.fieldValues == [type.fields[0].id: "Desk"])
    }

    @Test func deletingTypeKeepsItems() throws {
        let env = try TestEnv()
        let repo = CustomTypeRepository(database: env.db, clock: env.clock)
        let type = try productsType(repo)
        let item = try env.makeItem(title: "Kettle")
        try repo.assign(item.id, to: type.id)
        #expect(try repo.itemCount(for: type.id) == 1)
        try repo.delete(type.id)
        let fetched = try #require(try env.repo.fetch(item.id))
        #expect(fetched.customTypeID == nil)
        #expect(fetched.fieldValues.isEmpty)
        #expect(try repo.all().isEmpty)
    }

    @Test func fieldValuesAreFullTextSearchable() throws {
        let env = try TestEnv()
        let repo = CustomTypeRepository(database: env.db, clock: env.clock)
        let type = try productsType(repo)
        let item = try env.makeItem(title: "Chair")
        try repo.assign(item.id, to: type.id)
        try repo.setFieldValues([type.fields[1].id: "Herringbone upholstery"], for: item.id)
        let search = SearchService(database: env.db)
        #expect(try search.search("herringbone").map(\.id) == [item.id])
        try repo.setFieldValues([:], for: item.id)
        #expect(try search.search("herringbone").isEmpty)
    }

    @Test func webURLNormalization() {
        #expect(CustomType.webURL(from: "example.com/x")?.absoluteString == "https://example.com/x")
        #expect(CustomType.webURL(from: " https://a.io ")?.absoluteString == "https://a.io")
        #expect(CustomType.webURL(from: "http://shop.dev/p?id=1")?.absoluteString == "http://shop.dev/p?id=1")
        #expect(CustomType.webURL(from: "not a link") == nil)
        #expect(CustomType.webURL(from: "ftp://files.example.com") == nil)
        #expect(CustomType.webURL(from: "") == nil)
        #expect(CustomType.webURL(from: "word") == nil)
    }
}

// MARK: - Capture + search

@Suite struct CustomTypeCaptureSearchTests {
    @Test func captureIntoTypePrefillsFields() throws {
        let env = try TestEnv()
        let repo = CustomTypeRepository(database: env.db, clock: env.clock)
        let type = try productsType(repo)
        let capture = CaptureService(database: env.db, blobs: env.blobs, clock: env.clock)
        let item = try capture.capture(CapturePayload(url: URL(string: "https://shop.example.com/lamp")!, plainText: "Arc Lamp"),
                                       customTypeID: type.id)
        #expect(item.customTypeID == type.id)
        #expect(item.fieldValues == [type.fields[0].id: "Arc Lamp", type.fields[2].id: "https://shop.example.com/lamp"])
        #expect(try env.repo.fetch(item.id) == item)
    }

    @Test func imageFromWebPrefillsLinkWithSourceURL() throws {
        let env = try TestEnv()
        let repo = CustomTypeRepository(database: env.db, clock: env.clock)
        let type = try productsType(repo)
        let capture = CaptureService(database: env.db, blobs: env.blobs, clock: env.clock)
        let item = try capture.capture(CapturePayload(url: URL(string: "https://img.example.com/sofa.png")!,
                                                      imageData: try Fixtures.data("red.png")), customTypeID: type.id)
        #expect(item.type == .image)
        #expect(item.fieldValues[type.fields[2].id] == "https://img.example.com/sofa.png")
    }

    @Test func unknownTypeFailsWithoutOrphans() throws {
        let env = try TestEnv()
        let capture = CaptureService(database: env.db, blobs: env.blobs, clock: env.clock)
        let png = try Fixtures.data("red.png")
        #expect(throws: CustomTypeError.self) { try capture.capture(.imageData(png), customTypeID: "missing") }
        #expect(try env.repo.count() == 0)
        #expect(!env.blobs.exists(BlobStore.hash(of: png)))
    }

    @Test func typeFilterSearchesCustomType() throws {
        let env = try TestEnv()
        let repo = CustomTypeRepository(database: env.db, clock: env.clock)
        let type = try productsType(repo)
        _ = try repo.create(name: "Gift Ideas")
        let chair = try env.makeItem(.link, title: "Chair", url: "https://a.com")
        _ = try env.makeItem(.link, title: "Chair article", url: "https://b.com")
        try repo.assign(chair.id, to: type.id)

        let parser = QueryParser(timeZone: utc, customTypeExists: { repo.exists(named: $0) })
        let search = SearchService(database: env.db, parser: parser)
        #expect(try parser.parse("type:products").filters == [.customType("products")])
        #expect(try parser.parse(#"type:"Gift Ideas""#).filters == [.customType("Gift Ideas")])
        #expect(try parser.parse("type:link").filters == [.type(.link)]) // built-ins unchanged
        #expect(throws: MiniBrainError.self) { try parser.parse("type:spaceship") }
        #expect(try search.search("chair type:Products").map(\.id) == [chair.id])
        #expect(try search.search("chair").count == 2)
        #expect(try search.search(#"type:"Gift Ideas""#).isEmpty)
    }

    @Test func customTypeSQL() {
        let (clauses, args) = SearchSQLBuilder.filterClauses([.customType("Products")])
        #expect(clauses.last == "items.custom_type_id IN (SELECT id FROM custom_types WHERE name = ? COLLATE NOCASE)")
        #expect(args == ["Products".databaseValue])
    }

    @Test func nlMapperUsesCustomTypes() throws {
        let mapper = NLQueryMapper(parser: QueryParser(timeZone: utc, customTypeExists: { $0.lowercased() == "products" }))
        #expect(try mapper.map(TranslatedQuery(keywords: ["chair"], type: "Products")).filters == [.customType("products")])
        #expect(throws: MiniBrainError.self) { try mapper.map(TranslatedQuery(keywords: ["x"], type: "recipes")) }
    }
}

// MARK: - Drop box ⇧ flow

@Suite @MainActor struct ShiftDropTests {
    func make() throws -> (TestEnv, CustomTypeRepository, DropBoxViewModel, FakeClock) {
        let env = try TestEnv()
        let repo = CustomTypeRepository(database: env.db, clock: env.clock)
        let capture = CaptureService(database: env.db, blobs: env.blobs, clock: env.clock)
        let clock = FakeClock()
        return (env, repo, DropBoxViewModel(capturer: capture, customTypes: repo, clock: clock), clock)
    }

    @Test func shiftDropChoosesTypeThenFillsFields() async throws {
        let (env, repo, vm, _) = try make()
        let type = try productsType(repo)
        let provider = NSItemProvider(object: URL(string: "https://shop.example.com/mug")! as NSURL)
        #expect(await vm.drop([provider], chooseType: true))
        #expect(vm.state == .choosingType([type]))
        #expect(vm.isAwaitingInput)
        #expect(try env.repo.count() == 0) // nothing saved until a type is chosen

        await vm.choose(type)
        guard case .editingFields(let item, let shownType) = vm.state else {
            Issue.record("expected field form, got \(vm.state)"); return
        }
        #expect(shownType == type)
        #expect(item.fieldValues[type.fields[2].id] == "https://shop.example.com/mug")

        var values = item.fieldValues
        values[type.fields[1].id] = "Stoneware, 350 ml"
        vm.saveFields(values)
        #expect(vm.state == .saved(title: "to Products"))
        let saved = try #require(try env.repo.fetch(item.id))
        #expect(saved.customTypeID == type.id)
        #expect(saved.fieldValues[type.fields[1].id] == "Stoneware, 350 ml")
    }

    @Test func saveWithoutTypeAndCancel() async throws {
        let (env, repo, vm, _) = try make()
        _ = try productsType(repo)
        await vm.drop([NSItemProvider(object: "plain note" as NSString)], chooseType: true)
        await vm.choose(nil)
        #expect(vm.state == .saved(title: "plain note"))
        #expect(try env.repo.fetchAll().first?.customTypeID == nil)

        await vm.drop([NSItemProvider(object: "never saved" as NSString)], chooseType: true)
        vm.cancelChoice()
        #expect(vm.state == .idle)
        #expect(try env.repo.count() == 1)
    }

    @Test func typeWithoutFieldsSavesImmediately() async throws {
        let (env, repo, vm, _) = try make()
        let bare = try repo.create(name: "Inbox")
        await vm.drop([NSItemProvider(object: "x" as NSString)], chooseType: true)
        await vm.choose(bare)
        #expect(vm.state == .saved(title: "to Inbox"))
        #expect(try env.repo.fetchAll().first?.customTypeID == bare.id)
    }

    @Test func noTypesYetShowsEmptyChooser() async throws {
        let (_, _, vm, _) = try make()
        var opened = false
        vm.onOpenSettings = { opened = true }
        await vm.drop([NSItemProvider(object: "x" as NSString)], chooseType: true)
        #expect(vm.state == .choosingType([]))
        vm.openSettings()
        #expect(opened)
        #expect(vm.state == .idle)
    }

    @Test func plainDropUnchanged() async throws {
        let (env, repo, vm, _) = try make()
        _ = try productsType(repo)
        #expect(await vm.drop([NSItemProvider(object: "quick" as NSString)]))
        #expect(vm.state == .saved(title: "quick"))
        #expect(try env.repo.fetchAll().first?.customTypeID == nil)
    }

    @Test func autoShowStaysOpenWhileChoosing() async throws {
        let state = AppState(), presenter = FakePresenter(), clock = FakeClock()
        state.presenter = presenter
        var dropState: DropBoxViewModel.State = .choosingType([])
        let auto = DropBoxAutoShow(appState: state, clock: clock, isEnabled: { true }, dropState: { dropState })
        auto.dragStarted()
        auto.dragEnded()
        for _ in 0..<5 {
            await clock.waitForSleepers()
            clock.advance(by: 0.4)
        }
        #expect(state.isDropBoxVisible)
        dropState = .saved(title: "to Products")
        await clock.waitForSleepers()
        clock.advance(by: 0.4)
        await clock.waitForSleepers()
        clock.advance(by: 1.2)
        await waitUntil { !state.isDropBoxVisible }
        #expect(!state.isDropBoxVisible)
    }
}

// MARK: - Settings › Types + library

@Suite @MainActor struct TypesSettingsTests {
    @Test func addRenameFieldsAndDelete() throws {
        let env = try TestEnv()
        let repo = CustomTypeRepository(database: env.db, clock: env.clock)
        let model = TypesSettings(repository: repo)
        #expect(model.types.isEmpty)
        #expect(model.draft == nil)

        let first = try #require(model.addType())
        #expect(first.name == "New Type")
        #expect(first.fields.map(\.kind) == [.text, .webLink])
        #expect(model.addType()?.name == "New Type 2")

        model.select(first.id)
        model.draft?.name = "Products"
        model.commit()
        #expect(try repo.find(first.id)?.name == "Products")

        model.addField(.largeText)
        let fieldIDs = try #require(model.draft?.fields.map(\.id))
        #expect(model.draft?.fields.map(\.kind) == [.text, .webLink, .largeText])
        model.moveField(fieldIDs[2], by: -1)
        #expect(try repo.find(first.id)?.fields.map(\.kind) == [.text, .largeText, .webLink])
        model.setKind(.largeText, for: fieldIDs[0])
        model.removeField(fieldIDs[1])
        #expect(try repo.find(first.id)?.fields.map(\.kind) == [.largeText, .largeText])

        model.deleteSelected()
        #expect(try repo.all().map(\.name) == ["New Type 2"])
        #expect(model.selectedID == model.types.first?.id)
    }

    @Test func duplicateRenameShowsErrorAndKeepsStored() throws {
        let env = try TestEnv()
        let repo = CustomTypeRepository(database: env.db, clock: env.clock)
        _ = try repo.create(name: "Books")
        let model = TypesSettings(repository: repo)
        let other = try #require(model.addType())
        model.draft?.name = "books"
        model.commit()
        #expect(model.error?.contains("already exists") == true)
        #expect(try repo.find(other.id)?.name == "New Type")
    }
}

@Suite @MainActor struct LibraryCustomTypeTests {
    @Test func filterQueryAndDetailEditing() async throws {
        let env = try TestEnv()
        let repo = CustomTypeRepository(database: env.db, clock: env.clock)
        let type = try productsType(repo)
        let item = try env.makeItem(.link, title: "Mug", url: "https://shop.example.com/mug")
        _ = try env.makeItem(.text, title: "Unrelated")
        let parser = QueryParser(timeZone: utc, customTypeExists: { repo.exists(named: $0) })
        let vm = LibraryViewModel(search: SearchService(database: env.db, parser: parser), repository: env.repo,
                                  customTypes: repo, clock: env.clock)
        await vm.performSearch()
        #expect(vm.customTypes == [type])

        try vm.assignCustomType(type.id, to: item.id)
        vm.filters = LibraryFilters(customType: "Products")
        #expect(vm.queryString == #"type:"Products""#)
        await vm.performSearch()
        #expect(vm.results.map(\.id) == [item.id])
        #expect(vm.customType(for: vm.results[0].item) == type)

        try vm.saveFieldValues([type.fields[1].id: "Glazed"], for: item.id)
        #expect(try env.repo.fetch(item.id)?.fieldValues[type.fields[1].id] == "Glazed")
        #expect(vm.results.first?.item.fieldValues[type.fields[1].id] == "Glazed")

        // Deleting the type clears a stale sidebar filter.
        try repo.delete(type.id)
        await vm.performSearch()
        await vm.performSearch()
        #expect(vm.filters.customType == nil)
    }
}
