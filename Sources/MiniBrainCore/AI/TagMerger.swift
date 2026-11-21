import Foundation
import GRDB

/// Cleans model-suggested tags: trim, lowercase, strip '#', collapse spaces,
/// dedupe, drop empties/overlong, cap at `maxTags`.
public enum TagValidator {
    public static let maxTags = 8
    public static let maxLength = 40

    public static func normalize(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in tags {
            var t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            while t.hasPrefix("#") { t.removeFirst() }
            t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
            guard !t.isEmpty, t.count <= maxLength, seen.insert(t).inserted else { continue }
            out.append(t)
            if out.count == maxTags { break }
        }
        return out
    }
}

/// Merge rules between user and AI tags:
/// - AI tags are attached with `source = ai`.
/// - User tags always win: an AI suggestion never downgrades a user tag.
/// - Tags the user removed are remembered in `meta.suppressed_ai_tags` and
///   never re-added by later enrichment.
public enum TagMerger {
    public static let suppressedKey = "suppressed_ai_tags"

    public static func applyAITags(_ tags: [String], to itemID: String, in db: Database) throws {
        guard let item = try Item.fetchOne(db, key: itemID) else { return }
        let suppressed = Set(suppressedTags(of: item))
        for tag in TagValidator.normalize(tags) where !suppressed.contains(tag) {
            try ItemRepository.attachTag(tag, to: itemID, source: .ai, in: db)
        }
    }

    public static func suppressedTags(of item: Item) -> [String] {
        item.meta[suppressedKey]?.stringArray.map { $0.lowercased() } ?? []
    }

    /// User removes a tag (AI or user). It is suppressed for future AI runs.
    public static func userRemoveTag(_ name: String, from itemID: String, now: Date, in db: Database) throws {
        try ItemRepository.detachTag(name, from: itemID, in: db)
        guard var item = try Item.fetchOne(db, key: itemID) else { return }
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var list = suppressedTags(of: item)
        if !list.contains(key) {
            list.append(key)
            item.meta[suppressedKey] = .array(list.map { .string($0) })
            item.updatedAt = now
            try item.update(db)
        }
    }

    /// User adds a tag: stored as `user`, and lifted from the suppression list.
    public static func userAddTag(_ name: String, to itemID: String, now: Date, in db: Database) throws {
        try ItemRepository.attachTag(name, to: itemID, source: .user, in: db)
        guard var item = try Item.fetchOne(db, key: itemID) else { return }
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let list = suppressedTags(of: item)
        if list.contains(key) {
            item.meta[suppressedKey] = .array(list.filter { $0 != key }.map { .string($0) })
            item.updatedAt = now
            try item.update(db)
        }
    }
}

extension ItemRepository {
    /// User-facing tag add (lifts AI suppression).
    public func userAddTag(_ name: String, to itemID: String) throws {
        let now = clock.now
        try writer.write { db in try TagMerger.userAddTag(name, to: itemID, now: now, in: db) }
    }

    /// User-facing tag removal (suppresses re-adding by AI).
    public func userRemoveTag(_ name: String, from itemID: String) throws {
        let now = clock.now
        try writer.write { db in try TagMerger.userRemoveTag(name, from: itemID, now: now, in: db) }
    }

    /// Replaces the user-visible tag set of an item with `names`.
    public func setUserTags(_ names: [String], for itemID: String) throws {
        let now = clock.now
        try writer.write { db in
            let current = try Self.tags(for: itemID, in: db)
            let wanted = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let wantedKeys = Set(wanted.map { $0.lowercased() })
            for tag in current where !wantedKeys.contains(tag.name.lowercased()) {
                try TagMerger.userRemoveTag(tag.name, from: itemID, now: now, in: db)
            }
            let currentKeys = Set(current.map { $0.name.lowercased() })
            for name in wanted where !currentKeys.contains(name.lowercased()) {
                try TagMerger.userAddTag(name, to: itemID, now: now, in: db)
            }
        }
    }
}
