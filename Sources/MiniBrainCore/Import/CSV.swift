import Foundation

/// RFC 4180-style CSV: quoted cells, "" escapes, line breaks inside quotes,
/// CRLF/LF, a leading BOM, and auto-detected `,` `;` or tab separators.
public enum CSV {
    public static func parse(_ text: String) -> [[String]] {
        var input = text
        if input.hasPrefix("\u{FEFF}") { input.removeFirst() }
        let separator = detectSeparator(input)
        var rows: [[String]] = []
        var row: [String] = []
        var cell = ""
        var inQuotes = false
        var chars = Array(input)
        chars.append("\n") // flush the last row
        var i = 0
        func endRow() {
            row.append(cell)
            cell = ""
            // Blank lines (a single empty cell) are skipped.
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        }
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { cell.append("\""); i += 1 } else { inQuotes = false }
                } else {
                    cell.append(c)
                }
            } else if c == "\"" && cell.isEmpty {
                inQuotes = true
            } else if c == separator {
                row.append(cell)
                cell = ""
            } else if c == "\r\n" || c == "\n" || c == "\r" {
                endRow()
            } else {
                cell.append(c)
            }
            i += 1
        }
        return rows
    }

    /// The separator that appears most often outside quotes on the first line.
    static func detectSeparator(_ text: String) -> Character {
        var counts: [Character: Int] = [",": 0, ";": 0, "\t": 0]
        var inQuotes = false
        for c in text {
            if c == "\"" { inQuotes.toggle(); continue }
            if inQuotes { continue }
            if c == "\n" || c == "\r\n" || c == "\r" { break }
            if counts[c] != nil { counts[c, default: 0] += 1 }
        }
        let best = counts.max { a, b in a.value == b.value ? a.key != "," : a.value < b.value }
        return (best?.value ?? 0) > 0 ? best!.key : ","
    }

    /// Writes rows with CRLF line endings, quoting only when needed. Cells that
    /// a spreadsheet would run as a formula (=, +, @) get a leading '.
    public static func write(_ rows: [[String]]) -> String {
        rows.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    static func escape(_ raw: String) -> String {
        var value = raw
        if let first = value.first, "=+@".contains(first) { value = "'" + value }
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" || $0 == "\r\n" || $0 == ";" || $0 == "\t" })
        else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// Imports CSV rows as items (one row = one item) via `ItemInputService`, so
/// rows get exactly the API's validation.
///
/// Columns (header names, any case): title/name, url/link/website,
/// text/content/body, note/notes, tags (split on , ; |), image (a file path),
/// type (per-row custom type when no type is given), and the custom type's
/// field names. Export-only columns (kind, created_at, id) are ignored.
public struct CSVImporter: Sendable {
    public enum Role: Hashable, Sendable, CustomStringConvertible {
        case title, url, text, note, tags, image, type
        case field(String)
        case ignored

        public var description: String {
            switch self {
            case .title: "Title"
            case .url: "URL"
            case .text: "Text"
            case .note: "Note"
            case .tags: "Tags"
            case .image: "Image"
            case .type: "Type"
            case .field(let name): name
            case .ignored: "Ignored"
            }
        }
    }

    public struct Column: Equatable, Sendable {
        public let header: String
        public let role: Role
    }

    public struct RowError: Equatable, Sendable {
        /// Record number in the file, counting the header as 1.
        public let row: Int
        public let message: String
    }

    public struct Options: Sendable {
        public var type: String?
        public var baseDirectory: URL?
        public var dryRun: Bool
        public var skipInvalid: Bool
        public init(type: String? = nil, baseDirectory: URL? = nil, dryRun: Bool = false, skipInvalid: Bool = false) {
            self.type = type
            self.baseDirectory = baseDirectory
            self.dryRun = dryRun
            self.skipInvalid = skipInvalid
        }
    }

    public struct Report: Sendable, Equatable {
        public var columns: [Column] = []
        public var totalRows = 0
        public var validRows = 0
        public var imported: [String] = []
        public var errors: [RowError] = []
        /// Up to 5 rows as header → value (preview).
        public var sample: [[String: String]] = []
        public var ignoredColumns: [String] {
            columns.filter { $0.role == .ignored && !CSVImporter.exportOnlyColumns.contains($0.header.lowercased()) }.map(\.header)
        }
    }

    public static let maxRows = 10_000
    static let exportOnlyColumns: Set<String> = ["kind", "created_at", "id"]

    public let items: ItemInputService
    public let log: Log

    public init(items: ItemInputService, log: Log = .shared) {
        self.items = items
        self.log = log
    }

    /// Validates every row; then saves them unless dry-run, or unless any row
    /// failed and `skipInvalid` is off (all-or-nothing by default).
    public func importCSV(_ text: String, options: Options) throws -> Report {
        let rows = CSV.parse(text)
        guard let header = rows.first, header.contains(where: { !$0.isBlank }) else {
            throw ItemInputError(400, "The CSV is empty")
        }
        let allTypes = try items.customTypes.all()
        var fixedType: CustomType?
        if let name = options.type?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            fixedType = ItemInputService.findType(name, in: allTypes)
            guard fixedType != nil else {
                let known = allTypes.map(\.name).joined(separator: ", ")
                throw ItemInputError(404, "Unknown type '\(name)'" + (known.isEmpty ? " (no custom types yet)" : ". Known: \(known)"))
            }
        }
        let columns = header.map { Column(header: $0.trimmingCharacters(in: .whitespacesAndNewlines),
                                          role: Self.role(for: $0, fixedType: fixedType, allTypes: allTypes)) }
        let content: Set<Role> = [.title, .url, .text, .image]
        guard columns.contains(where: { content.contains($0.role) || { if case .field = $0.role { return true }; return false }($0) }) else {
            throw ItemInputError(400, "None of the columns can be imported. Use title, url, text, note, tags, image"
                                 + (fixedType.map { " or the \($0.name) fields: \($0.fields.map(\.name).joined(separator: ", "))" } ?? ""))
        }
        let dataRows = rows.dropFirst()
        guard dataRows.count <= Self.maxRows else { throw ItemInputError(413, "Too many rows (max \(Self.maxRows))") }

        var report = Report(columns: columns)
        var prepared: [(row: Int, item: PreparedItem)] = []
        for (offset, cells) in dataRows.enumerated() {
            let rowNumber = offset + 2
            guard cells.contains(where: { !$0.isBlank }) else { continue }
            report.totalRows += 1
            if report.sample.count < 5 {
                var preview: [String: String] = [:]
                for (i, column) in columns.enumerated() where i < cells.count { preview[column.header] = cells[i] }
                report.sample.append(preview)
            }
            do {
                let input = try Self.input(cells: cells, columns: columns, fixedType: fixedType, allTypes: allTypes)
                prepared.append((rowNumber, try items.prepare(input, types: allTypes, baseDirectory: options.baseDirectory)))
            } catch let error as ItemInputError {
                report.errors.append(RowError(row: rowNumber, message: error.message))
            }
        }
        report.validRows = prepared.count
        let blocked = !report.errors.isEmpty && !options.skipInvalid
        if !options.dryRun && !blocked {
            for (row, item) in prepared {
                do { report.imported.append(try items.save(item).id) } catch {
                    report.errors.append(RowError(row: row, message: "\(error)"))
                }
            }
        }
        log.info("csv import type=\(fixedType?.name ?? "per-row") rows=\(report.totalRows) imported=\(report.imported.count) errors=\(report.errors.count)\(options.dryRun ? " (dry run)" : "")", "import")
        return report
    }

    static func role(for rawHeader: String, fixedType: CustomType?, allTypes: [CustomType]) -> Role {
        let header = rawHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        // A field of the chosen type with exactly this name wins over the built-ins.
        if let type = fixedType, let field = ItemInputService.findField(header, in: type) { return .field(field.name) }
        switch header.lowercased() {
        case "title", "name": return .title
        case "url", "link", "website": return .url
        case "text", "content", "body": return .text
        case "note", "notes": return .note
        case "tags", "tag": return .tags
        case "image", "image_path", "picture", "photo", "cover": return .image
        case "type", "custom_type": return fixedType == nil ? .type : .ignored
        default:
            if fixedType == nil, allTypes.contains(where: { ItemInputService.findField(header, in: $0) != nil }) {
                return .field(header) // resolved against each row's type
            }
            return .ignored
        }
    }

    static func input(cells: [String], columns: [Column], fixedType: CustomType?, allTypes: [CustomType]) throws -> [String: Any] {
        var input: [String: Any] = [:]
        var fields: [String: Any] = [:]
        var rowType = fixedType
        for (i, column) in columns.enumerated() where i < cells.count {
            let value = cells[i].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            switch column.role {
            case .title: input["title"] = value
            case .url: input["url"] = value
            case .text: input["text"] = cells[i]
            case .note: input["note"] = cells[i]
            case .image: input["image_path"] = value
            case .tags:
                input["tags"] = value.split(whereSeparator: { ",;|".contains($0) })
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            case .type:
                guard let type = ItemInputService.findType(value, in: allTypes) else {
                    throw ItemInputError(404, "Unknown type '\(value)'")
                }
                rowType = type
            case .field(let name): fields[name] = value
            case .ignored: break
            }
        }
        if let rowType {
            input["type"] = rowType.id
            // Per-row types: keep only fields this row's type has.
            let own = fields.filter { ItemInputService.findField($0.key, in: rowType) != nil }
            if !own.isEmpty { input["fields"] = own }
        }
        return input
    }
}

/// Items → CSV: built-in columns, then one column per custom field. The image
/// column holds the stored file's path, so an export can be re-imported.
public struct CSVExporter: Sendable {
    public static let baseColumns = ["title", "kind", "url", "text", "note", "tags", "image", "type", "created_at", "id"]

    public let repository: ItemRepository
    public let customTypes: CustomTypeRepository
    public let blobs: BlobStore

    public init(repository: ItemRepository, customTypes: CustomTypeRepository, blobs: BlobStore) {
        self.repository = repository
        self.customTypes = customTypes
        self.blobs = blobs
    }

    /// `type` fixes the field columns; otherwise every type present adds its fields.
    public func export(_ items: [Item], type: CustomType?) throws -> String {
        let types = Dictionary(try customTypes.all().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var fieldNames: [String] = []
        let sources = type.map { [$0] } ?? items.compactMap { $0.customTypeID.flatMap { types[$0] } }
        for t in sources { for f in t.fields where !fieldNames.contains(f.name) { fieldNames.append(f.name) } }

        let tags = try repository.tags(forItems: items.map(\.id))
        let iso = ISO8601DateFormatter()
        var rows = [Self.baseColumns + fieldNames]
        for item in items {
            let itemType = item.customTypeID.flatMap { types[$0] }
            let image: String = {
                if item.type == .image, let hash = item.blobHash { return blobs.url(for: hash)?.path ?? "" }
                if let hash = item.meta[LinkPreviewProcessor.previewBlobKey]?.stringValue { return blobs.url(for: hash)?.path ?? "" }
                return ""
            }()
            var row = [
                item.title, item.type.rawValue, item.url ?? "", item.type == .text ? item.content : "",
                item.note, (tags[item.id] ?? []).map(\.name).joined(separator: "; "), image,
                itemType?.name ?? "", iso.string(from: item.createdAt), item.id,
            ]
            for name in fieldNames {
                let field = itemType?.fields.first { $0.name == name }
                row.append(field.flatMap { item.fieldValues[$0.id] } ?? "")
            }
            rows.append(row)
        }
        return CSV.write(rows)
    }
}
