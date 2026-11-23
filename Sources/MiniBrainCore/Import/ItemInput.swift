import Foundation

/// A rejected input (status mirrors HTTP: 400 bad input, 404 unknown type).
public struct ItemInputError: Error, Equatable, Sendable, CustomStringConvertible {
    public let status: Int
    public let message: String
    public init(_ status: Int, _ message: String) {
        self.status = status
        self.message = message
    }
    public var description: String { message }
}

/// A validated item, ready to save (nothing written yet).
public struct PreparedItem: Sendable {
    public var payload: CapturePayload
    public var type: CustomType?
    public var fieldValues: [String: String]
    public var title: String?
    public var note: String?
    public var tags: [String]
    /// Image sent together with a url/text/pdf → that item's cover.
    public var cover: Data?
}

/// One way to turn loose input (API JSON, a CSV row) into items, with the
/// same validation everywhere: validate first (`prepare`), then `save`.
///
/// Keys: `type`, `title`, `text`, `url`, `note`, `fields` (name/id → value),
/// `tags` ([String]), `image_base64`, `pdf_base64`, `image_path`.
/// Content: an image alone makes an Image item; with url/text/pdf it becomes
/// the cover. Otherwise pdf > url > text > title.
public struct ItemInputService: Sendable {
    public let capture: CaptureService
    public let repository: ItemRepository
    public let customTypes: CustomTypeRepository
    public let editor: ItemEditor

    public init(capture: CaptureService, repository: ItemRepository, customTypes: CustomTypeRepository,
                optimizeImages: @escaping @Sendable () -> Bool = { false }) {
        self.capture = capture
        self.repository = repository
        self.customTypes = customTypes
        editor = ItemEditor(database: capture.database, blobs: capture.blobs, clock: capture.clock,
                            notifier: capture.notifier, optimizeImages: optimizeImages)
    }

    /// Validates `input`. `types` (all custom types) can be passed in to avoid
    /// re-reading them per row; `baseDirectory` resolves relative image paths.
    public func prepare(_ input: [String: Any], types: [CustomType]? = nil, baseDirectory: URL? = nil) throws -> PreparedItem {
        let title = try string(input, "title")
        let text = try string(input, "text")
        let note = try string(input, "note")
        let urlString = try string(input, "url")

        // Custom type + fields.
        var type: CustomType?
        if let name = try string(input, "type") {
            let all = try types ?? customTypes.all()
            type = Self.findType(name, in: all)
            guard type != nil else {
                let known = all.map(\.name).joined(separator: ", ")
                throw ItemInputError(404, "Unknown type '\(name)'" + (known.isEmpty ? " (no custom types yet)" : ". Known: \(known)"))
            }
        }
        var fieldValues: [String: String] = [:]
        if let rawFields = input["fields"] {
            guard let fields = rawFields as? [String: Any] else { throw ItemInputError(400, "fields must be an object of name → value") }
            if !fields.isEmpty {
                guard let type else { throw ItemInputError(400, "fields need a type (e.g. \"type\": \"Products\")") }
                for (key, raw) in fields {
                    guard let field = Self.findField(key, in: type) else {
                        throw ItemInputError(400, "Unknown field '\(key)' for type \(type.name). Fields: \(type.fields.map(\.name).joined(separator: ", "))")
                    }
                    let value = try Self.fieldString(raw, field: field.name)
                    if field.kind == .webLink, !value.isEmpty, CustomType.webURL(from: value) == nil {
                        throw ItemInputError(400, "\(field.name) must be a web address, got '\(value)'")
                    }
                    fieldValues[field.id] = value
                }
            }
        }

        // Tags.
        var tags: [String] = []
        if let rawTags = input["tags"] {
            guard let list = rawTags as? [Any], list.allSatisfy({ $0 is String }) else {
                throw ItemInputError(400, "tags must be a list of strings")
            }
            tags = (list as! [String]).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }

        // Image: base64 or a file on this Mac.
        var imageData: Data?
        if let base64 = try string(input, "image_base64") {
            guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters), !data.isEmpty else {
                throw ItemInputError(400, "image_base64 is not valid base64")
            }
            imageData = data
        } else if let path = try string(input, "image_path") {
            imageData = try Self.readImageFile(path, baseDirectory: baseDirectory)
        }
        if let imageData, !ItemEditor.isDecodableImage(imageData) {
            throw ItemInputError(400, input["image_path"] != nil ? "image file isn't an image" : "image_base64 isn't an image")
        }
        let hasOtherContent = urlString != nil || text != nil || input["pdf_base64"] is String
        let cover: Data? = hasOtherContent ? imageData : nil

        // Content.
        var payload: CapturePayload
        var noteToSave = note
        if let imageData, !hasOtherContent {
            payload = CapturePayload(imageData: imageData, suggestedName: title)
        } else if let base64 = try string(input, "pdf_base64") {
            guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters), data.starts(with: Data("%PDF".utf8)) else {
                throw ItemInputError(400, "pdf_base64 is not a base64 PDF")
            }
            payload = CapturePayload(pdfData: data, suggestedName: title)
        } else if let urlString {
            guard let url = WebURL.normalize(urlString) else {
                throw ItemInputError(400, "url '\(urlString)' is not a valid web address (e.g. https://example.com or blog.example.com)")
            }
            payload = .url(url)
            if noteToSave == nil { noteToSave = text } // text next to a URL is kept as the note
        } else if let text {
            payload = .plainText(text)
        } else if let title {
            payload = .plainText(title)
        } else {
            throw ItemInputError(400, "Nothing to save: send text, url, image, pdf or title")
        }
        return PreparedItem(payload: payload, type: type, fieldValues: fieldValues, title: title,
                            note: noteToSave, tags: tags, cover: cover)
    }

    /// Saves a prepared item (capture → fields/title → note → cover → tags).
    @discardableResult
    public func save(_ prepared: PreparedItem) throws -> Item {
        var item: Item
        do {
            item = try capture.capture(prepared.payload, customTypeID: prepared.type?.id)
        } catch let error as MiniBrainError {
            throw ItemInputError(400, "Can't save: \(error)")
        }
        if prepared.type != nil {
            var values = item.fieldValues
            values.merge(prepared.fieldValues) { _, new in new }
            item = try customTypes.setFieldValues(values, title: prepared.title, for: item.id)
        } else if let title = prepared.title, !title.isBlank {
            item = try repository.modify(item.id) { $0.title = title.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        if let note = prepared.note, !note.isBlank {
            item = try repository.modify(item.id) { $0.note = note }
        }
        if let cover = prepared.cover {
            item = try editor.setImage(cover, for: item.id)
        }
        for tag in prepared.tags { try repository.attachTag(tag, to: item.id, source: .user) }
        return item
    }

    // MARK: - Helpers

    static func findType(_ nameOrID: String, in types: [CustomType]) -> CustomType? {
        let key = nameOrID.trimmingCharacters(in: .whitespacesAndNewlines)
        return types.first { $0.id == key || $0.name.compare(key, options: .caseInsensitive) == .orderedSame }
    }

    static func findField(_ nameOrID: String, in type: CustomType) -> FieldDefinition? {
        let key = nameOrID.trimmingCharacters(in: .whitespacesAndNewlines)
        return type.fields.first { $0.id == key || $0.name.compare(key, options: .caseInsensitive) == .orderedSame }
    }

    private func string(_ input: [String: Any], _ key: String) throws -> String? {
        guard let raw = input[key], !(raw is NSNull) else { return nil }
        guard let value = raw as? String else { throw ItemInputError(400, "\(key) must be a string") }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }

    static func fieldString(_ raw: Any, field: String) throws -> String {
        switch raw {
        case let s as String: return s.trimmingCharacters(in: .whitespacesAndNewlines)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        case is NSNull: return ""
        default: throw ItemInputError(400, "\(field) must be a string or number")
        }
    }

    /// Reads an image file on this Mac (absolute, ~, or relative to `baseDirectory`).
    static func readImageFile(_ raw: String, baseDirectory: URL?) throws -> Data {
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.lowercased().hasPrefix("http://") || path.lowercased().hasPrefix("https://") {
            throw ItemInputError(400, "image '\(path)' is a web address — use a file on this Mac (the Python client downloads URLs for you)")
        }
        let expanded = (path as NSString).expandingTildeInPath
        let url: URL
        if expanded.hasPrefix("/") { url = URL(fileURLWithPath: expanded) }
        else if let baseDirectory { url = baseDirectory.appendingPathComponent(expanded) }
        else { throw ItemInputError(400, "image '\(path)' is a relative path; use an absolute path") }
        guard let data = try? Data(contentsOf: url) else { throw ItemInputError(400, "image file not found: \(url.path)") }
        return data
    }
}
