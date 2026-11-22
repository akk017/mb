import Foundation
import GRDB

/// Background jobs a captured item gets. Stored as `enrichment_queue.kind`.
public enum EnrichmentKind: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case pdfText = "pdf_text"
    case ocr
    case colors
    case aiTags = "ai_tags"
    case imageTags = "image_tags"
    case embedding
    case linkPreview = "link_preview"
    case optimizeImage = "optimize_image"

    /// Jobs per item type, in processing order (text extraction before tagging).
    public static func kinds(for type: ItemType) -> [EnrichmentKind] {
        switch type {
        case .pdf: [.pdfText, .aiTags, .embedding]
        // WebP conversion last, so OCR/colors/tagging read the original pixels.
        case .image: [.ocr, .colors, .imageTags, .aiTags, .embedding, .optimizeImage]
        case .link: [.linkPreview, .aiTags, .embedding]
        case .text: [.aiTags, .embedding]
        }
    }
}

/// Something that wants to hear about new queue rows (the enrichment worker).
/// Must return immediately — capture never waits for enrichment.
public protocol EnrichmentNotifying: Sendable {
    func enrichmentJobsAvailable()
}

/// Payload → blob + item + FTS row + queue rows, atomically.
public struct CaptureService: Sendable {
    public let database: AppDatabase
    public let blobs: BlobStore
    public let clock: any Clock
    public let idGenerator: @Sendable () -> String
    public let enabledKinds: Set<EnrichmentKind>
    public let notifier: (any EnrichmentNotifying)?
    /// Runtime switch per job kind (e.g. OCR turned off in Settings).
    public let isKindEnabled: @Sendable (EnrichmentKind) -> Bool

    public init(
        database: AppDatabase, blobs: BlobStore, clock: any Clock = SystemClock(),
        idGenerator: @escaping @Sendable () -> String = { UUID().uuidString },
        enabledKinds: Set<EnrichmentKind> = Set(EnrichmentKind.allCases),
        notifier: (any EnrichmentNotifying)? = nil,
        isKindEnabled: @escaping @Sendable (EnrichmentKind) -> Bool = { _ in true }
    ) {
        self.database = database
        self.blobs = blobs
        self.clock = clock
        self.idGenerator = idGenerator
        self.enabledKinds = enabledKinds
        self.notifier = notifier
        self.isKindEnabled = isKindEnabled
    }

    /// Drop path. With `customTypeID`, the item joins that custom type and
    /// its name/link fields are prefilled.
    @discardableResult
    public func capture(_ payload: CapturePayload, customTypeID: String? = nil) throws -> Item {
        let detected = try TypeDetector.detect(payload)
        let now = clock.now

        var blobHash: String?
        var createdBlob = false
        if let data = detected.data {
            let result = try blobs.store(data, fileExtension: detected.fileExtension)
            blobHash = result.hash
            createdBlob = result.created
        }

        var meta = detected.meta
        if let data = detected.data { meta["byte_size"] = .number(Double(data.count)) }
        var item = Item(
            id: idGenerator(), type: detected.type, title: detected.title, content: detected.content,
            url: detected.url, blobHash: blobHash, meta: meta, createdAt: now)
        let kinds = EnrichmentKind.kinds(for: item.type).filter { enabledKinds.contains($0) && isKindEnabled($0) }

        do {
            item = try database.writer.write { db in
                var item = item
                if let customTypeID {
                    guard let type = try CustomType.fetchOne(db, key: customTypeID) else {
                        throw CustomTypeError.notFound(customTypeID)
                    }
                    item.customTypeID = type.id
                    item.fieldValues = type.prefilledValues(for: item)
                }
                try item.insert(db)
                for kind in kinds {
                    try EnrichmentQueue.enqueue(itemID: item.id, kind: kind, now: now, in: db)
                }
                return item
            }
        } catch {
            // DB rolled back; don't leave an orphan file behind.
            if createdBlob, let blobHash { _ = try? blobs.deleteIfUnreferenced(blobHash, database: database) }
            Log.shared.error("capture failed type=\(item.type.rawValue): \(error)", "capture")
            throw error
        }
        Log.shared.info("captured item=\(item.id) type=\(item.type.rawValue)\(item.url.flatMap { URL(string: $0)?.host }.map { " host=\($0)" } ?? "") bytes=\(detected.data?.count ?? 0) jobs=\(kinds.map(\.rawValue).joined(separator: ","))\(customTypeID != nil ? " customType" : "")", "capture")
        if !kinds.isEmpty { notifier?.enrichmentJobsAvailable() }
        return item
    }

    /// Paste path: same pipeline, payload read from a pasteboard.
    @discardableResult
    public func capture(pasteboard: any PasteboardReading) throws -> Item {
        try capture(PasteboardPayloadMapper.payload(from: pasteboard))
    }
}

/// Read-only pasteboard abstraction (NSPasteboard conforms in the UI module).
public protocol PasteboardReading {
    var availableTypes: [String] { get }
    func data(forType type: String) -> Data?
    func string(forType type: String) -> String?
}

/// UTI strings used by pasteboards and item providers.
public enum UTI {
    public static let pdf = "com.adobe.pdf"
    public static let png = "public.png"
    public static let jpeg = "public.jpeg"
    public static let tiff = "public.tiff"
    public static let heic = "public.heic"
    public static let gif = "com.compuserve.gif"
    public static let image = "public.image"
    public static let fileURL = "public.file-url"
    public static let url = "public.url"
    public static let html = "public.html"
    public static let utf8Text = "public.utf8-plain-text"
    public static let plainText = "public.plain-text"

    public static let imageTypes = [png, jpeg, tiff, heic, gif]
}

public enum PasteboardPayloadMapper {
    public static func payload(from pb: any PasteboardReading) throws -> CapturePayload {
        var payload = CapturePayload()
        if let fileURLString = pb.string(forType: UTI.fileURL), let fileURL = URL(string: fileURLString), fileURL.isFileURL {
            payload = try FilePayloadReader.payload(forFile: fileURL)
        }
        if payload.pdfData == nil, let pdf = pb.data(forType: UTI.pdf) { payload.pdfData = pdf }
        if payload.imageData == nil {
            for type in UTI.imageTypes { if let d = pb.data(forType: type) { payload.imageData = d; break } }
        }
        if payload.url == nil, let s = pb.string(forType: UTI.url), let url = URL(string: s) { payload.url = url }
        if payload.html == nil, let html = pb.string(forType: UTI.html) { payload.html = html }
        if payload.plainText == nil {
            payload.plainText = pb.string(forType: UTI.utf8Text) ?? pb.string(forType: UTI.plainText)
        }
        return payload
    }
}

/// Turns a dropped/pasted file into payload data by its extension.
public enum FilePayloadReader {
    public static func payload(forFile url: URL) throws -> CapturePayload {
        let data = try Data(contentsOf: url)
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent
        if ext == "pdf" || DataSniffer.isPDF(data) { return CapturePayload(pdfData: data, suggestedName: name) }
        if DataSniffer.imageExtension(data) != nil { return CapturePayload(imageData: data, suggestedName: name) }
        if ["html", "htm"].contains(ext), let s = String(data: data, encoding: .utf8) {
            return CapturePayload(html: s, suggestedName: name)
        }
        if let s = String(data: data, encoding: .utf8) { return CapturePayload(plainText: s, suggestedName: name) }
        throw MiniBrainError.unsupportedPayload
    }
}
