import Foundation
import GRDB
import ImageIO

public enum ItemEditError: Error, Equatable, LocalizedError {
    case invalidURL(String)
    case urlRequired
    case invalidImage
    case cannotRemoveImage

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Not a valid web address (e.g. https://example.com or blog.example.com)."
        case .urlRequired: "A link needs a URL."
        case .invalidImage: "That file isn't an image."
        case .cannotRemoveImage: "An image item's picture can be replaced, not removed."
        }
    }
}

/// Edits an item's URL and image from the detail panel, keeping meta, blobs
/// and enrichment jobs consistent.
public struct ItemEditor: Sendable {
    /// Meta flag: `preview_blob` was chosen by the user (link previews keep it).
    public static let customPreviewKey = "preview_custom"

    public let database: AppDatabase
    public let blobs: BlobStore
    public let clock: any Clock
    public let notifier: (any EnrichmentNotifying)?
    public let optimizeImages: @Sendable () -> Bool

    public init(database: AppDatabase, blobs: BlobStore, clock: any Clock = SystemClock(),
                notifier: (any EnrichmentNotifying)? = nil, optimizeImages: @escaping @Sendable () -> Bool = { false }) {
        self.database = database
        self.blobs = blobs
        self.clock = clock
        self.notifier = notifier
        self.optimizeImages = optimizeImages
    }

    // MARK: - URL

    /// Validates and saves a URL. Links need one and re-fetch their preview
    /// when it changes; other items may clear it.
    @discardableResult
    public func setURL(_ raw: String, for itemID: String) throws -> Item {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let url: URL?
        if trimmed.isEmpty {
            url = nil
        } else {
            guard let valid = WebURL.normalize(trimmed) else { throw ItemEditError.invalidURL(trimmed) }
            url = valid
        }
        let now = clock.now
        var queued = false
        let item: Item = try database.writer.write { db in
            guard var item = try Item.fetchOne(db, key: itemID) else { throw MiniBrainError.notFound(itemID) }
            if item.type == .link, url == nil { throw ItemEditError.urlRequired }
            guard item.url != url?.absoluteString else { return item }
            if item.type == .link, let url {
                // Keep a title the user (or the page) set; follow an automatic one.
                let oldAuto = item.url.flatMap(URL.init(string:)).map { TypeDetector.link($0, title: nil).title }
                if item.title == oldAuto { item.title = TypeDetector.link(url, title: nil).title }
                item.meta["host"] = url.host.map { .string($0) }
                item.meta["page_title"] = nil
                try EnrichmentQueue.enqueue(itemID: item.id, kind: .linkPreview, now: now, in: db)
                queued = true
            }
            item.url = url?.absoluteString
            item.updatedAt = now
            try item.update(db)
            return item
        }
        if queued { notifier?.enrichmentJobsAvailable() }
        Log.shared.info("url edited item=\(itemID) host=\(url?.host ?? "none")", "library")
        return item
    }

    // MARK: - Image

    /// Image items get their picture replaced (and re-processed); every other
    /// item gets a custom cover image.
    @discardableResult
    public func setImage(_ data: Data, for itemID: String) throws -> Item {
        guard Self.isDecodableImage(data) else { throw ItemEditError.invalidImage }
        let now = clock.now
        let current = try database.writer.read { db in try Item.fetchOne(db, key: itemID) }
        guard let current else { throw MiniBrainError.notFound(itemID) }

        let stored: String
        if current.type == .image {
            // Original pixels: OCR/colors read them; WebP conversion runs last.
            stored = try blobs.store(data, fileExtension: DataSniffer.imageExtension(data) ?? "png").hash
        } else {
            let webp = optimizeImages() ? ImageOptimizer.webp(from: data) : nil
            stored = try blobs.store(webp ?? data, fileExtension: webp != nil ? "webp" : (DataSniffer.imageExtension(data) ?? "png")).hash
        }

        var obsolete: String?
        var queued = false
        let item: Item = try database.writer.write { db in
            guard var item = try Item.fetchOne(db, key: itemID) else { throw MiniBrainError.notFound(itemID) }
            if item.type == .image {
                obsolete = item.blobHash
                item.blobHash = stored
                item.content = "" // stale OCR text
                item.meta["byte_size"] = .number(Double(data.count))
                for key in ["webp_optimized", "format", "original_byte_size", "colors", "dominant_colors"] { item.meta[key] = nil }
                for kind in EnrichmentKind.kinds(for: .image) {
                    try EnrichmentQueue.enqueue(itemID: item.id, kind: kind, now: now, in: db)
                }
                queued = true
            } else {
                obsolete = item.meta[LinkPreviewProcessor.previewBlobKey]?.stringValue
                item.meta[LinkPreviewProcessor.previewBlobKey] = .string(stored)
                item.meta[Self.customPreviewKey] = true
                item.meta[ImageOptimizeProcessor.optimizedKey] = optimizeImages() ? true : nil
            }
            item.updatedAt = now
            try item.update(db)
            return item
        }
        if let obsolete, obsolete != stored { _ = try? blobs.deleteIfUnreferenced(obsolete, database: database) }
        if queued { notifier?.enrichmentJobsAvailable() }
        Log.shared.info("image set item=\(itemID) type=\(item.type.rawValue) bytes=\(data.count)", "library")
        return item
    }

    /// Removes a custom cover. Links fetch their page preview again.
    @discardableResult
    public func removeImage(for itemID: String) throws -> Item {
        let now = clock.now
        var obsolete: String?
        var queued = false
        let item: Item = try database.writer.write { db in
            guard var item = try Item.fetchOne(db, key: itemID) else { throw MiniBrainError.notFound(itemID) }
            guard item.type != .image else { throw ItemEditError.cannotRemoveImage }
            obsolete = item.meta[LinkPreviewProcessor.previewBlobKey]?.stringValue
            guard obsolete != nil else { return item }
            item.meta[LinkPreviewProcessor.previewBlobKey] = nil
            item.meta[Self.customPreviewKey] = nil
            item.meta[ImageOptimizeProcessor.optimizedKey] = nil
            if item.type == .link {
                try EnrichmentQueue.enqueue(itemID: item.id, kind: .linkPreview, now: now, in: db)
                queued = true
            }
            item.updatedAt = now
            try item.update(db)
            return item
        }
        if let obsolete { _ = try? blobs.deleteIfUnreferenced(obsolete, database: database) }
        if queued { notifier?.enrichmentJobsAvailable() }
        return item
    }

    static func isDecodableImage(_ data: Data) -> Bool {
        guard !data.isEmpty, let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }
}
