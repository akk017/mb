import Foundation
import GRDB

public enum ItemType: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case text, link, image, pdf
}

/// One captured thing. Binary content lives in the BlobStore (`blobHash`);
/// searchable text lives in `title`, `note`, `content`.
public struct Item: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "items"

    public var id: String
    public var type: ItemType
    public var title: String
    public var note: String
    public var content: String
    public var url: String?
    public var blobHash: String?
    public var meta: Meta
    public var createdAt: Date
    public var updatedAt: Date
    public var trashedAt: Date?
    /// User-defined custom type (schema v3); values in `meta.fields`.
    public var customTypeID: String?

    public init(
        id: String = UUID().uuidString, type: ItemType, title: String = "", note: String = "",
        content: String = "", url: String? = nil, blobHash: String? = nil, meta: Meta = [:],
        createdAt: Date, updatedAt: Date? = nil, trashedAt: Date? = nil, customTypeID: String? = nil
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.note = note
        self.content = content
        self.url = url
        self.blobHash = blobHash
        self.meta = meta
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.trashedAt = trashedAt
        self.customTypeID = customTypeID
    }

    // Custom Codable: `custom_type_id` is omitted when nil so items can still
    // be written to schema-v1 databases (fixtures, tools).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(ItemType.self, forKey: .type)
        title = try c.decode(String.self, forKey: .title)
        note = try c.decode(String.self, forKey: .note)
        content = try c.decode(String.self, forKey: .content)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        blobHash = try c.decodeIfPresent(String.self, forKey: .blobHash)
        meta = try c.decode(Meta.self, forKey: .meta)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        trashedAt = try c.decodeIfPresent(Date.self, forKey: .trashedAt)
        customTypeID = try c.decodeIfPresent(String.self, forKey: .customTypeID)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        try c.encode(title, forKey: .title)
        try c.encode(note, forKey: .note)
        try c.encode(content, forKey: .content)
        try c.encode(url, forKey: .url)
        try c.encode(blobHash, forKey: .blobHash)
        try c.encode(meta, forKey: .meta)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(trashedAt, forKey: .trashedAt)
        try c.encodeIfPresent(customTypeID, forKey: .customTypeID)
    }

    /// DB columns. `custom_type_id` is only written when set, so items can
    /// still be inserted into schema-v1 databases (fixtures, tools).
    public func encode(to container: inout PersistenceContainer) throws {
        container[CodingKeys.id] = id
        container[CodingKeys.type] = type
        container[CodingKeys.title] = title
        container[CodingKeys.note] = note
        container[CodingKeys.content] = content
        container[CodingKeys.url] = url
        container[CodingKeys.blobHash] = blobHash
        let json = try Self.databaseJSONEncoder(for: "meta").encode(meta)
        container[CodingKeys.meta] = String(decoding: json, as: UTF8.self)
        container[CodingKeys.createdAt] = createdAt
        container[CodingKeys.updatedAt] = updatedAt
        container[CodingKeys.trashedAt] = trashedAt
        if let customTypeID { container[CodingKeys.customTypeID] = customTypeID }
    }

    /// Field values of the item's custom type, keyed by field id.
    public var fieldValues: [String: String] {
        get {
            guard case .object(let o)? = meta[CustomType.fieldsMetaKey] else { return [:] }
            return o.compactMapValues(\.stringValue)
        }
        set {
            let cleaned = newValue.filter { !$0.value.isEmpty }
            meta[CustomType.fieldsMetaKey] = cleaned.isEmpty ? nil : .object(cleaned.mapValues { .string($0) })
        }
    }

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id, type, title, note, content, url
        case blobHash = "blob_hash"
        case meta
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case trashedAt = "trashed_at"
        case customTypeID = "custom_type_id"
    }

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let type = Column(CodingKeys.type)
        public static let createdAt = Column(CodingKeys.createdAt)
        public static let trashedAt = Column(CodingKeys.trashedAt)
        public static let blobHash = Column(CodingKeys.blobHash)
        public static let customTypeID = Column(CodingKeys.customTypeID)
    }

    public var isTrashed: Bool { trashedAt != nil }

    // Meta is stored as a JSON object string with stable key order.
    public static func databaseJSONEncoder(for column: String) -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }
}

public enum TagSource: String, Codable, Sendable, DatabaseValueConvertible {
    case user, ai
}

public struct Tag: Codable, Equatable, Hashable, Sendable, FetchableRecord {
    public var id: Int64
    public var name: String
}

/// A tag as attached to one item.
public struct ItemTag: Codable, Equatable, Hashable, Sendable, FetchableRecord {
    public var name: String
    public var source: TagSource
}
