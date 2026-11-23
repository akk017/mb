import AppKit
import Foundation
import Testing
@testable import MiniBrainCore
@testable import MiniBrainUI

@MainActor
private struct AppCSV {
    let env: TestEnv
    let types: CustomTypeRepository
    let products: CustomType
    let transfer: CSVTransfer
    let dir: URL

    init() throws {
        env = try TestEnv()
        types = CustomTypeRepository(database: env.db, clock: env.clock)
        products = try types.create(name: "Products", fields: [FieldDefinition(id: "price", name: "Price", kind: .text)])
        let types = types
        let items = ItemInputService(capture: CaptureService(database: env.db, blobs: env.blobs, clock: env.clock),
                                     repository: env.repo, customTypes: types)
        transfer = CSVTransfer(
            importer: CSVImporter(items: items),
            exporter: CSVExporter(repository: env.repo, customTypes: types, blobs: env.blobs),
            search: SearchService(database: env.db, parser: QueryParser(customTypeExists: { types.exists(named: $0) })))
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("appcsv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func file(_ name: String, _ text: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func dropBox() -> DropBoxViewModel {
        let vm = DropBoxViewModel(capturer: CaptureService(database: env.db, blobs: env.blobs, clock: env.clock),
                                  customTypes: types, clock: FakeClock())
        let importer = transfer.importer
        vm.csvImport = { file, typeName in
            try importer.importCSV(CSVTransfer.readText(file),
                                   options: .init(type: typeName, baseDirectory: file.deletingLastPathComponent(), skipInvalid: true))
        }
        return vm
    }
}

@Suite @MainActor struct CSVTransferTests {
    @Test func previewThenConfirmImportsAndReports() throws {
        let t = try AppCSV()
        defer { try? FileManager.default.removeItem(at: t.dir) }
        var refreshed = 0
        t.transfer.onImported = { refreshed += 1 }
        let url = try t.file("products.csv", "Name,Price,URL\nSony,349,a.com\nBad,1,hello world\n")
        t.transfer.preview(fileURL: url, typeName: "Products")
        let pending = try #require(t.transfer.pending)
        #expect(pending.fileName == "products.csv")
        #expect(pending.report.validRows == 1)
        #expect(pending.report.errors.map(\.row) == [3])
        #expect(try t.env.repo.count() == 0) // preview saves nothing

        let report = try #require(t.transfer.confirm())
        #expect(report.imported.count == 1)
        #expect(t.transfer.pending == nil)
        #expect(t.transfer.message == "Imported 1 item into Products · 1 row skipped")
        #expect(refreshed == 1)
    }

    @Test func cancelSavesNothing() throws {
        let t = try AppCSV()
        defer { try? FileManager.default.removeItem(at: t.dir) }
        t.transfer.preview(fileURL: try t.file("a.csv", "Name\nX\n"), typeName: "Products")
        t.transfer.cancel()
        #expect(t.transfer.pending == nil)
        #expect(try t.env.repo.count() == 0)
    }

    @Test func unreadableOrUnmappableFilesShowAnError() throws {
        let t = try AppCSV()
        defer { try? FileManager.default.removeItem(at: t.dir) }
        t.transfer.preview(fileURL: try t.file("weird.csv", "Colour,Size\nred,L\n"), typeName: "Products")
        #expect(t.transfer.pending == nil)
        #expect(t.transfer.isError)
        #expect(t.transfer.message?.contains("None of the columns") == true)
    }

    @Test func exportsTypeToFile() throws {
        let t = try AppCSV()
        defer { try? FileManager.default.removeItem(at: t.dir) }
        _ = t.transfer.importNow(fileURL: try t.file("p.csv", "Name,Price\nKindle,99\n"), typeName: "Products")
        let out = t.dir.appendingPathComponent("export.csv")
        t.transfer.export(typeName: "Products", to: out)
        #expect(t.transfer.message == "Exported 1 item to export.csv")
        let rows = CSV.parse(try String(contentsOf: out, encoding: .utf8))
        #expect(rows.count == 2)
        #expect(rows[0].last == "Price")
        #expect(rows[1].last == "99")
    }
}

@Suite @MainActor struct DropBoxCSVTests {
    @Test func droppedCSVAsksForTypeThenImportsRows() async throws {
        let t = try AppCSV()
        defer { try? FileManager.default.removeItem(at: t.dir) }
        let vm = t.dropBox()
        let url = try t.file("products.csv", "Name,Price\nSony,349\nKindle,99\n")
        #expect(await vm.drop([NSItemProvider(contentsOf: url)!]))
        guard case .choosingImportType(let name, let types) = vm.state else { Issue.record("got \(vm.state)"); return }
        #expect(name == "products.csv")
        #expect(types.map(\.name) == ["Products"])
        #expect(vm.isAwaitingInput)
        vm.chooseImport(t.products)
        #expect(vm.state == .saved(title: "2 items to Products"))
        #expect(try t.env.repo.fetchAll().allSatisfy { $0.customTypeID == t.products.id })
        #expect(try t.env.repo.count() == 2) // rows, not one note holding the CSV
    }

    @Test func droppedOnTypeZoneImportsStraightIn() async throws {
        let t = try AppCSV()
        defer { try? FileManager.default.removeItem(at: t.dir) }
        let vm = t.dropBox()
        let url = try t.file("p.csv", "Name,Price,URL\nSony,349,a.com\nBad,1,hello world\n")
        #expect(await vm.drop([NSItemProvider(contentsOf: url)!], into: t.products))
        #expect(vm.state == .saved(title: "1 item to Products · 1 skipped"))
    }

    @Test func allRowsBadShowsTheFirstProblem() async throws {
        let t = try AppCSV()
        defer { try? FileManager.default.removeItem(at: t.dir) }
        let vm = t.dropBox()
        let url = try t.file("p.csv", "Name,URL\nBad,hello world\n")
        #expect(await vm.drop([NSItemProvider(contentsOf: url)!], into: t.products) == false)
        guard case .error(let message) = vm.state else { Issue.record("got \(vm.state)"); return }
        #expect(message.hasPrefix("Row 2:"))
    }

    @Test func cancelLeavesNothing() async throws {
        let t = try AppCSV()
        defer { try? FileManager.default.removeItem(at: t.dir) }
        let vm = t.dropBox()
        _ = await vm.drop([NSItemProvider(contentsOf: try t.file("p.csv", "Name\nX\n"))!])
        vm.cancelChoice()
        #expect(vm.state == .idle)
        vm.chooseImport(nil) // stale choice after cancel does nothing
        #expect(try t.env.repo.count() == 0)
    }

    @Test func withoutImporterACSVIsStillSavedAsANote() async throws {
        let t = try AppCSV()
        defer { try? FileManager.default.removeItem(at: t.dir) }
        let vm = DropBoxViewModel(capturer: CaptureService(database: t.env.db, blobs: t.env.blobs, clock: t.env.clock),
                                  customTypes: t.types, clock: FakeClock())
        _ = await vm.drop([NSItemProvider(contentsOf: try t.file("p.csv", "Name\nX\n"))!])
        #expect(try t.env.repo.count() == 1)
    }
}
