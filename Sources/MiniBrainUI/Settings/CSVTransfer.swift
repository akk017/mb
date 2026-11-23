import AppKit
import MiniBrainCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// CSV import/export for the app (Settings › Types and the drop box): preview
/// with a dry run, then import; export a type to a file.
@MainActor
@Observable
public final class CSVTransfer {
    public struct Pending: Equatable {
        public let fileName: String
        public let text: String
        public let baseDirectory: URL?
        public let typeName: String?
        public let report: CSVImporter.Report
    }

    /// Dry-run result waiting for the user (drives the preview sheet).
    public private(set) var pending: Pending?
    /// Last outcome, e.g. "Imported 12 items into Products · 2 rows skipped".
    public private(set) var message: String?
    public private(set) var isError = false

    @ObservationIgnored let importer: CSVImporter
    @ObservationIgnored let exporter: CSVExporter
    @ObservationIgnored let search: SearchService
    @ObservationIgnored public var onImported: (() -> Void)?

    public init(importer: CSVImporter, exporter: CSVExporter, search: SearchService) {
        self.importer = importer
        self.exporter = exporter
        self.search = search
    }

    /// Reads a CSV file (UTF-8, else Latin-1).
    public static func readText(_ url: URL) throws -> String {
        if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        return try String(contentsOf: url, encoding: .isoLatin1)
    }

    // MARK: - Import

    /// Validates `url` into `typeName` (nil = per-row "type" column) and shows the preview.
    public func preview(fileURL url: URL, typeName: String?) {
        do {
            let text = try Self.readText(url)
            preview(text: text, fileName: url.lastPathComponent, baseDirectory: url.deletingLastPathComponent(), typeName: typeName)
        } catch {
            fail("Couldn't read \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    public func preview(text: String, fileName: String, baseDirectory: URL?, typeName: String?) {
        do {
            let report = try importer.importCSV(text, options: .init(type: typeName, baseDirectory: baseDirectory, dryRun: true))
            pending = Pending(fileName: fileName, text: text, baseDirectory: baseDirectory, typeName: typeName, report: report)
            message = nil
            isError = false
        } catch {
            fail(Self.describe(error))
        }
    }

    /// Imports the previewed file; rows with problems are skipped.
    @discardableResult
    public func confirm() -> CSVImporter.Report? {
        guard let pending else { return nil }
        self.pending = nil
        return run(text: pending.text, baseDirectory: pending.baseDirectory, typeName: pending.typeName)
    }

    public func cancel() { pending = nil }

    /// Imports straight away (drop box), skipping rows with problems.
    @discardableResult
    public func importNow(fileURL url: URL, typeName: String?) -> CSVImporter.Report? {
        do {
            return run(text: try Self.readText(url), baseDirectory: url.deletingLastPathComponent(), typeName: typeName)
        } catch {
            fail("Couldn't read \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    private func run(text: String, baseDirectory: URL?, typeName: String?) -> CSVImporter.Report? {
        do {
            let report = try importer.importCSV(text, options: .init(type: typeName, baseDirectory: baseDirectory, skipInvalid: true))
            message = Self.summary(report, typeName: typeName)
            isError = report.imported.isEmpty
            if !report.imported.isEmpty { onImported?() }
            return report
        } catch {
            fail(Self.describe(error))
            return nil
        }
    }

    public static func summary(_ report: CSVImporter.Report, typeName: String?) -> String {
        let n = report.imported.count
        var text = "Imported \(n) item\(n == 1 ? "" : "s")" + (typeName.map { " into \($0)" } ?? "")
        if !report.errors.isEmpty {
            text += " · \(report.errors.count) row\(report.errors.count == 1 ? "" : "s") skipped"
        }
        return text
    }

    // MARK: - Export

    /// CSV for a type (nil = everything).
    public func exportText(typeName: String?) throws -> String {
        let query = typeName.map { "type:\"\($0)\"" } ?? ""
        let items = try search.search(query, limit: CSVImporter.maxRows).map(\.item)
        let type = try typeName.flatMap { name in try importer.items.customTypes.find(named: name) }
        return try exporter.export(items, type: type)
    }

    public func export(typeName: String?, to url: URL) {
        do {
            let text = try exportText(typeName: typeName)
            try text.write(to: url, atomically: true, encoding: .utf8)
            let rows = max(CSV.parse(text).count - 1, 0)
            message = "Exported \(rows) item\(rows == 1 ? "" : "s") to \(url.lastPathComponent)"
            isError = false
        } catch {
            fail("Export failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Panels (Settings)

    public func chooseAndPreview(typeName: String?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        panel.message = "Choose a CSV to import" + (typeName.map { " into \($0)" } ?? "")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        preview(fileURL: url, typeName: typeName)
    }

    public func chooseAndExport(typeName: String?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(typeName ?? "MiniBrain").csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        export(typeName: typeName, to: url)
    }

    private func fail(_ text: String) {
        message = text
        isError = true
        Log.shared.error("csv: \(text)", "import")
    }

    static func describe(_ error: Error) -> String {
        (error as? ItemInputError)?.message ?? error.localizedDescription
    }
}

/// Preview sheet: how columns map, a few rows, problems; then Import.
struct CSVImportPreview: View {
    let pending: CSVTransfer.Pending
    let onImport: () -> Void
    let onCancel: () -> Void

    private var report: CSVImporter.Report { pending.report }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Import \(pending.fileName)").font(.headline)
                Text("\(report.totalRows) row\(report.totalRows == 1 ? "" : "s")" + (pending.typeName.map { " into \($0)" } ?? "")
                     + " · \(report.validRows) ready" + (report.errors.isEmpty ? "" : " · \(report.errors.count) with problems"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            GroupBox("Columns") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(report.columns.enumerated()), id: \.offset) { _, column in
                        HStack {
                            Text(column.header.isEmpty ? "(blank)" : column.header).lineLimit(1)
                            Spacer()
                            Text(column.role == .ignored ? "ignored" : "→ \(column.role.description)")
                                .foregroundStyle(column.role == .ignored ? .tertiary : .secondary)
                        }
                        .font(.callout)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
            if let first = report.sample.first {
                GroupBox("First row") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(report.columns.filter { $0.role != .ignored && !(first[$0.header] ?? "").isEmpty }, id: \.header) { column in
                            HStack(alignment: .top) {
                                Text(column.role.description).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                                Text(first[column.header] ?? "").lineLimit(2)
                            }
                            .font(.callout)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
            }
            if !report.errors.isEmpty {
                GroupBox("Rows that will be skipped") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(report.errors.prefix(50).enumerated()), id: \.offset) { _, error in
                                Text("Row \(error.row): \(error.message)").font(.caption).foregroundStyle(.orange)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 110)
                }
            }
            HStack {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Import \(report.validRows) Item\(report.validRows == 1 ? "" : "s")", action: onImport)
                    .keyboardShortcut(.defaultAction)
                    .disabled(report.validRows == 0)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
