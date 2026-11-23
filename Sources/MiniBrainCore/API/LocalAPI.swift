import Foundation
import Security

/// The local HTTP API's routes. Pure request → response (no sockets), so it
/// is tested directly; `LocalAPIServer` is only the transport.
///
/// Security: the server listens on 127.0.0.1 only; every route but /health
/// needs `Authorization: Bearer <token>`; requests from browsers (an Origin
/// header) or for a non-local Host (DNS rebinding) are refused.
public struct LocalAPI: Sendable {
    public let capture: CaptureService
    public let repository: ItemRepository
    public let customTypes: CustomTypeRepository
    public let search: SearchService
    public let token: @Sendable () -> String
    public let onChange: @Sendable () -> Void
    public let log: Log
    /// Shared validate-then-save logic (also used by CSV import).
    public let items: ItemInputService

    public init(capture: CaptureService, repository: ItemRepository, customTypes: CustomTypeRepository,
                search: SearchService, token: @escaping @Sendable () -> String,
                onChange: @escaping @Sendable () -> Void = {}, log: Log = .shared,
                optimizeImages: @escaping @Sendable () -> Bool = { false }) {
        items = ItemInputService(capture: capture, repository: repository, customTypes: customTypes,
                                 optimizeImages: optimizeImages)
        self.capture = capture
        self.repository = repository
        self.customTypes = customTypes
        self.search = search
        self.token = token
        self.onChange = onChange
        self.log = log
    }

    public func handle(_ request: HTTPRequest) -> HTTPResponse {
        let started = Date()
        let response = route(request)
        log.info("\(request.method) \(request.path) → \(response.status) in \(Int(Date().timeIntervalSince(started) * 1000))ms", "api")
        return response
    }

    private func route(_ request: HTTPRequest) -> HTTPResponse {
        if request.headers["origin"] != nil { return .error(403, "Browser requests are not allowed") }
        guard Self.isLocalHost(request.headers["host"]) else { return .error(403, "Host must be 127.0.0.1 or localhost") }

        let segments = request.path.split(separator: "/").map(String.init)
        if segments == ["health"] {
            return request.method == "GET" ? .json(200, ["ok": true, "version": MiniBrain.version]) : .error(405, "Use GET")
        }
        guard isAuthorized(request) else { return .error(401, "Missing or wrong token (Authorization: Bearer <token>)") }

        do {
            switch (request.method, segments) {
            case ("GET", ["types"]): return try listTypes()
            case ("GET", ["items"]): return try listItems(request.query)
            case ("POST", ["items"]): return try addItem(request.body)
            case ("POST", ["import", "csv"]): return try importCSV(request)
            case ("GET", ["export", "csv"]): return try exportCSV(request.query)
            case (_, ["import", "csv"]), (_, ["export", "csv"]): return .error(405, "Method not allowed")
            case ("GET", let s) where s.count == 2 && s[0] == "items": return try getItem(s[1])
            case (_, ["types"]), (_, ["items"]): return .error(405, "Method not allowed")
            case (_, let s) where s.count == 2 && s[0] == "items": return .error(405, "Method not allowed")
            default: return .error(404, "No route for \(request.path)")
            }
        } catch let error as APIError {
            return .error(error.status, error.message)
        } catch let error as ItemInputError {
            return .error(error.status, error.message)
        } catch let MiniBrainError.invalidQuery(message) {
            return .error(400, message)
        } catch {
            log.error("\(request.method) \(request.path) failed: \(error)", "api")
            return .error(500, "Internal error: \(error.localizedDescription)")
        }
    }

    struct APIError: Error {
        let status: Int
        let message: String
        init(_ status: Int, _ message: String) { self.status = status; self.message = message }
    }

    // MARK: - Auth

    static func isLocalHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        let name: Substring
        if host.hasPrefix("[") { name = host.prefix { $0 != "]" }.dropFirst() } // [::1]:7777
        else { name = host.split(separator: ":", maxSplits: 1).first ?? "" }
        return ["127.0.0.1", "localhost", "::1"].contains(String(name))
    }

    private func isAuthorized(_ request: HTTPRequest) -> Bool {
        guard let header = request.headers["authorization"], header.hasPrefix("Bearer ") else { return false }
        let given = Array(header.dropFirst("Bearer ".count).utf8)
        let expected = Array(token().utf8)
        guard !expected.isEmpty, given.count == expected.count else { return false }
        return zip(given, expected).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0 // constant time
    }

    // MARK: - Routes

    private func listTypes() throws -> HTTPResponse {
        let types = try customTypes.all().map { type in
            ["id": type.id, "name": type.name,
             "fields": type.fields.map { ["id": $0.id, "name": $0.name, "kind": $0.kind.rawValue] }] as [String: Any]
        }
        return .json(200, ["types": types])
    }

    private func listItems(_ query: [String: String]) throws -> HTTPResponse {
        let limit = min(max(Int(query["limit"] ?? "") ?? 50, 1), 500)
        let results = try search.search(query["q"] ?? "", limit: limit)
        let types = try typesByID()
        return .json(200, ["items": try results.map { try json(for: $0.item, types: types) }])
    }

    private func getItem(_ id: String) throws -> HTTPResponse {
        guard let item = try repository.fetch(id), item.trashedAt == nil else { throw APIError(404, "No item \(id)") }
        return .json(200, try json(for: item, types: try typesByID()))
    }

    /// POST /items — validates everything first, so a bad request saves nothing.
    private func addItem(_ body: Data) throws -> HTTPResponse {
        guard !body.isEmpty else { throw APIError(400, "Nothing to save: send JSON with text, url, image_base64 or title") }
        guard let input = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw APIError(400, "Body must be a JSON object")
        }
        var safe = input
        safe["image_path"] = nil // files on disk only via CSV import
        let prepared = try items.prepare(safe)
        let item = try items.save(prepared)
        onChange()
        return .json(201, try json(for: item, types: try typesByID()))
    }

    // MARK: - CSV

    /// POST /import/csv — body is the CSV (`Content-Type: text/csv`, options in
    /// the query) or JSON `{"csv", "type", "dry_run", "skip_invalid", "base_dir"}`.
    private func importCSV(_ request: HTTPRequest) throws -> HTTPResponse {
        var text: String
        var options = CSVImporter.Options()
        let isJSON = request.headers["content-type"]?.contains("json") == true
            || request.body.first.map { $0 == UInt8(ascii: "{") } == true
        if isJSON {
            guard let input = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let csv = input["csv"] as? String else { throw APIError(400, "Send {\"csv\": \"…\"} or a text/csv body") }
            text = csv
            options.type = input["type"] as? String
            options.dryRun = input["dry_run"] as? Bool ?? false
            options.skipInvalid = input["skip_invalid"] as? Bool ?? false
            options.baseDirectory = (input["base_dir"] as? String).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        } else {
            guard let csv = String(data: request.body, encoding: .utf8) else { throw APIError(400, "CSV must be UTF-8") }
            text = csv
            let q = request.query
            options.type = q["type"]
            options.dryRun = Self.flag(q["dry_run"])
            options.skipInvalid = Self.flag(q["skip_invalid"])
            options.baseDirectory = q["base_dir"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        }
        if text.isEmpty { text = " " }
        let report = try CSVImporter(items: items, log: log).importCSV(text, options: options)
        if !report.imported.isEmpty { onChange() }
        var body = Self.json(report)
        body["dry_run"] = options.dryRun
        let blocked = !report.errors.isEmpty && !options.skipInvalid && !options.dryRun
        if blocked {
            body["error"] = "\(report.errors.count) row(s) have problems; nothing was saved. Fix them, or send skip_invalid to import the valid rows."
            return .json(400, body)
        }
        return .json(report.imported.isEmpty ? 200 : 201, body)
    }

    /// GET /export/csv?type=Products&q=… — items as CSV (one column per field).
    private func exportCSV(_ query: [String: String]) throws -> HTTPResponse {
        var type: CustomType?
        if let name = query["type"], !name.isEmpty {
            type = ItemInputService.findType(name, in: try customTypes.all())
            guard type != nil else { throw APIError(404, "Unknown type '\(name)'") }
        }
        var q = query["q"] ?? ""
        if let type { q = "type:\"\(type.name)\" " + q }
        let limit = min(max(Int(query["limit"] ?? "") ?? CSVImporter.maxRows, 1), CSVImporter.maxRows)
        let found = try search.search(q.trimmingCharacters(in: .whitespaces), limit: limit).map(\.item)
        let csv = try CSVExporter(repository: repository, customTypes: customTypes, blobs: items.capture.blobs).export(found, type: type)
        let name = (type?.name ?? "MiniBrain").replacingOccurrences(of: "\"", with: "")
        return HTTPResponse(status: 200, headers: ["Content-Type": "text/csv; charset=utf-8",
                                                   "Content-Disposition": "attachment; filename=\"\(name).csv\""],
                            body: Data(csv.utf8))
    }

    static func flag(_ value: String?) -> Bool {
        ["1", "true", "yes"].contains(value?.lowercased() ?? "")
    }

    static func json(_ report: CSVImporter.Report) -> [String: Any] {
        [
            "total_rows": report.totalRows,
            "valid_rows": report.validRows,
            "imported": report.imported,
            "imported_count": report.imported.count,
            "errors": report.errors.map { ["row": $0.row, "message": $0.message] as [String: Any] },
            "columns": report.columns.map { ["header": $0.header, "maps_to": $0.role.description] },
            "ignored_columns": report.ignoredColumns,
        ]
    }

    // MARK: - JSON

    private func typesByID() throws -> [String: CustomType] {
        Dictionary(try customTypes.all().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func json(for item: Item, types: [String: CustomType]) throws -> [String: Any] {
        let type = item.customTypeID.flatMap { types[$0] }
        var fields: [String: String] = [:]
        if let type {
            for field in type.fields { if let v = item.fieldValues[field.id], !v.isEmpty { fields[field.name] = v } }
        }
        var out: [String: Any] = [
            "id": item.id,
            "kind": item.type.rawValue,
            "title": item.title,
            "note": item.note,
            "tags": try repository.tags(for: item.id).map(\.name),
            "fields": fields,
            "created_at": ISO8601DateFormatter().string(from: item.createdAt),
            "custom_type": type?.name ?? NSNull(),
            "url": item.url ?? NSNull(),
        ]
        if item.type == .text { out["text"] = item.content }
        out["has_image"] = item.type == .image || item.meta[LinkPreviewProcessor.previewBlobKey] != nil
        return out
    }
}

/// The API token: random, stored in a file only the user can read
/// (`…/Application Support/MiniBrain/api-token`), so scripts can read it too.
public struct LocalAPIToken: Sendable {
    public let fileURL: URL

    public init(directory: URL = Log.defaultDirectory.deletingLastPathComponent()) {
        fileURL = directory.appendingPathComponent("api-token")
    }

    /// Existing token, or a new one.
    public func load() throws -> String {
        if let existing = try? String(contentsOf: fileURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), existing.count >= 32 {
            return existing
        }
        return try regenerate()
    }

    @discardableResult
    public func regenerate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw MiniBrainError.enrichmentFailed("Couldn't generate a token")
        }
        let token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let fm = FileManager.default
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: fileURL)
        guard fm.createFile(atPath: fileURL.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return token
    }
}
