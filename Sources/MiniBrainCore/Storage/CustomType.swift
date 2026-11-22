import Foundation
import GRDB

public enum FieldKind: String, Codable, CaseIterable, Sendable {
    case text
    case largeText = "large_text"
    case webLink = "web_link"

    public var title: String {
        switch self {
        case .text: "Text"
        case .largeText: "Large Text"
        case .webLink: "Web Link"
        }
    }
}

public struct FieldDefinition: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var kind: FieldKind

    public init(id: String = UUID().uuidString, name: String, kind: FieldKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

/// A user-defined type such as "Products" with its own fields.
public struct CustomType: Codable, Equatable, Hashable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "custom_types"
    public static let fieldsMetaKey = "fields"

    public var id: String
    public var name: String
    public var fields: [FieldDefinition]
    public var createdAt: Date

    public init(id: String = UUID().uuidString, name: String, fields: [FieldDefinition] = [], createdAt: Date) {
        self.id = id
        self.name = name
        self.fields = fields
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, fields
        case createdAt = "created_at"
    }

    /// A Text field called "Name" or "Title" mirrors the item's name, so the
    /// drop form asks once instead of showing two name boxes.
    public var nameField: FieldDefinition? {
        fields.first { $0.kind == .text && ["name", "title"].contains($0.name.trimmingCharacters(in: .whitespaces).lowercased()) }
    }

    /// Normalizes a web-link value: adds https:// when no scheme is given.
    /// Returns nil when it can't be an http(s) URL.
    public static func webURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .whitespaces) == nil else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, host.contains(".") || host == "localhost"
        else { return nil }
        return url
    }

    /// Initial field values for a newly captured item: a field named
    /// name/title gets the title; the first web-link field gets the URL.
    public func prefilledValues(for item: Item) -> [String: String] {
        var values: [String: String] = [:]
        if let titleField = fields.first(where: { $0.kind != .webLink && ["name", "title"].contains($0.name.lowercased()) }),
           !item.title.isEmpty {
            values[titleField.id] = item.title
        }
        if let url = item.url ?? item.meta["source_url"]?.stringValue,
           let linkField = fields.first(where: { $0.kind == .webLink }) {
            values[linkField.id] = url
        }
        return values
    }
}

public enum CustomTypeError: Error, Equatable, LocalizedError {
    case emptyName
    case duplicateName(String)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .emptyName: "Name can't be empty."
        case .duplicateName(let n): "A type named “\(n)” already exists."
        case .notFound(let n): "Type “\(n)” not found."
        }
    }
}

/// CRUD for custom types and their per-item field values.
public struct CustomTypeRepository: Sendable {
    public let database: AppDatabase
    public let clock: any Clock

    public init(database: AppDatabase, clock: any Clock = SystemClock()) {
        self.database = database
        self.clock = clock
    }

    public func all() throws -> [CustomType] {
        try database.writer.read { db in
            try CustomType.order(sql: "name COLLATE NOCASE").fetchAll(db)
        }
    }

    public func find(_ id: String) throws -> CustomType? {
        try database.writer.read { db in try CustomType.fetchOne(db, key: id) }
    }

    public func find(named name: String) throws -> CustomType? {
        try database.writer.read { db in
            try CustomType.filter(sql: "name = ? COLLATE NOCASE", arguments: [name]).fetchOne(db)
        }
    }

    static func cleanName(_ name: String) throws -> String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { throw CustomTypeError.emptyName }
        return n
    }

    static func cleanFields(_ fields: [FieldDefinition]) -> [FieldDefinition] {
        fields.compactMap { f in
            let name = f.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : FieldDefinition(id: f.id, name: name, kind: f.kind)
        }
    }

    @discardableResult
    public func create(name: String, fields: [FieldDefinition] = []) throws -> CustomType {
        let type = CustomType(name: try Self.cleanName(name), fields: Self.cleanFields(fields), createdAt: clock.now)
        try database.writer.write { db in
            if try CustomType.filter(sql: "name = ? COLLATE NOCASE", arguments: [type.name]).fetchCount(db) > 0 {
                throw CustomTypeError.duplicateName(type.name)
            }
            try type.insert(db)
        }
        return type
    }

    /// Saves name/fields. Values of removed fields are dropped from items.
    @discardableResult
    public func update(_ type: CustomType) throws -> CustomType {
        var type = type
        type.name = try Self.cleanName(type.name)
        type.fields = Self.cleanFields(type.fields)
        let saved = type
        try database.writer.write { db in
            guard let old = try CustomType.fetchOne(db, key: saved.id) else { throw CustomTypeError.notFound(saved.name) }
            if try CustomType.filter(sql: "name = ? COLLATE NOCASE AND id != ?", arguments: [saved.name, saved.id]).fetchCount(db) > 0 {
                throw CustomTypeError.duplicateName(saved.name)
            }
            try saved.update(db)
            let removed = Set(old.fields.map(\.id)).subtracting(saved.fields.map(\.id))
            if !removed.isEmpty {
                for var item in try Item.filter(Item.Columns.customTypeID == saved.id).fetchAll(db) {
                    item.fieldValues = item.fieldValues.filter { !removed.contains($0.key) }
                    try item.update(db)
                }
            }
        }
        return saved
    }

    /// Deletes the type; its items stay (type link cleared, values removed).
    public func delete(_ id: String) throws {
        try database.writer.write { db in
            for var item in try Item.filter(Item.Columns.customTypeID == id).fetchAll(db) {
                item.fieldValues = [:]
                try item.update(db)
            }
            _ = try CustomType.deleteOne(db, key: id) // FK sets items.custom_type_id = NULL
        }
    }

    /// Puts an item into a type (or removes it with nil). Keeps values of
    /// fields that still exist; prefills empty ones on first assignment.
    @discardableResult
    public func assign(_ itemID: String, to typeID: String?) throws -> Item {
        let now = clock.now
        return try database.writer.write { db in
            guard var item = try Item.fetchOne(db, key: itemID) else { throw MiniBrainError.notFound(itemID) }
            if let typeID {
                guard let type = try CustomType.fetchOne(db, key: typeID) else { throw CustomTypeError.notFound(typeID) }
                let ids = Set(type.fields.map(\.id))
                var values = item.customTypeID == typeID ? item.fieldValues.filter { ids.contains($0.key) } : [:]
                for (k, v) in type.prefilledValues(for: item) where values[k] == nil { values[k] = v }
                item.fieldValues = values
            } else {
                item.fieldValues = [:]
            }
            item.customTypeID = typeID
            item.updatedAt = now
            try item.update(db)
            // `update` omits a nil custom_type_id; clear it explicitly.
            if typeID == nil {
                try db.execute(sql: "UPDATE items SET custom_type_id = NULL WHERE id = ?", arguments: [itemID])
            }
            return item
        }
    }

    /// Replaces an item's field values (empty strings are dropped).
    @discardableResult
    /// Saves field values and, when `title` is non-blank, renames the item.
    /// A type's "Name"/"Title" field follows the new title.
    public func setFieldValues(_ values: [String: String], title: String? = nil, for itemID: String) throws -> Item {
        let now = clock.now
        return try database.writer.write { db in
            guard var item = try Item.fetchOne(db, key: itemID) else { throw MiniBrainError.notFound(itemID) }
            let type = try item.customTypeID.flatMap { try CustomType.fetchOne(db, key: $0) }
            let allowed: Set<String>? = type.map { Set($0.fields.map(\.id)) }
            var cleaned: [String: String] = [:]
            for (k, v) in values where allowed?.contains(k) ?? true {
                let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { cleaned[k] = t }
            }
            if let name = title?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                item.title = name
                if let field = type?.nameField { cleaned[field.id] = name }
            }
            item.fieldValues = cleaned
            item.updatedAt = now
            try item.update(db)
            return item
        }
    }

    public func itemCount(for typeID: String) throws -> Int {
        try database.writer.read { db in
            try Item.filter(Item.Columns.customTypeID == typeID && Item.Columns.trashedAt == nil).fetchCount(db)
        }
    }

    /// For the query parser: does a type with this name exist?
    public func exists(named name: String) -> Bool {
        (try? database.writer.read { db in
            try CustomType.filter(sql: "name = ? COLLATE NOCASE", arguments: [name]).fetchCount(db) > 0
        }) ?? false
    }
}
