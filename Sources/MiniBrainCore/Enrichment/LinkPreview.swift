import AppKit
import Foundation
import LinkPresentation

/// What a web page offers as its preview.
public struct LinkPreview: Sendable, Equatable {
    public var title: String?
    /// Encoded image (PNG/JPEG) — the page's preview image, or its icon.
    public var imageData: Data?

    public init(title: String? = nil, imageData: Data? = nil) {
        self.title = title
        self.imageData = imageData
    }
}

public protocol LinkPreviewFetching: Sendable {
    func preview(for url: URL) async throws -> LinkPreview
}

/// `link_preview` job: fetches the page's preview image + title (needs the
/// internet; failures retry with backoff like any job).
public struct LinkPreviewProcessor: EnrichmentProcessor {
    public static let previewBlobKey = "preview_blob"
    public let kind = EnrichmentKind.linkPreview
    public let fetcher: any LinkPreviewFetching
    /// Checked at run time (Settings › General › Fetch link previews).
    public let isEnabled: @Sendable () -> Bool

    /// Store previews as WebP (Settings › Optimize images).
    public let optimizeImages: @Sendable () -> Bool

    public init(fetcher: any LinkPreviewFetching, isEnabled: @escaping @Sendable () -> Bool = { true },
                optimizeImages: @escaping @Sendable () -> Bool = { true }) {
        self.fetcher = fetcher
        self.isEnabled = isEnabled
        self.optimizeImages = optimizeImages
    }

    public func process(_ item: Item, context: EnrichmentContext) async throws -> EnrichmentResult {
        guard isEnabled(), item.type == .link, let urlString = item.url, let url = URL(string: urlString) else {
            return .empty
        }
        let preview = try await fetcher.preview(for: url)
        var meta: Meta = [:]
        if let fetched = preview.imageData, !fetched.isEmpty {
            let webp = optimizeImages() ? ImageOptimizer.webp(from: fetched) : nil
            let data = webp ?? fetched
            let ext = webp != nil ? "webp" : (DataSniffer.imageExtension(fetched) ?? "png")
            meta[Self.previewBlobKey] = .string(try context.blobs.store(data, fileExtension: ext).hash)
            if webp != nil { meta[ImageOptimizeProcessor.optimizedKey] = true }
        }
        let title = preview.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let title, !title.isEmpty { meta["page_title"] = .string(title) }
        // Replace the automatic host/path title, never one the user typed.
        let autoTitle = TypeDetector.link(url, title: nil).title
        let newTitle = (item.title == autoTitle && title?.isEmpty == false) ? title : nil
        return EnrichmentResult(title: newTitle, meta: meta)
    }
}

/// LinkPresentation-backed fetcher (same previews as Messages/Safari).
public struct LinkPresentationFetcher: LinkPreviewFetching {
    public var timeout: TimeInterval
    public var maxPixel: CGFloat

    public init(timeout: TimeInterval = 15, maxPixel: CGFloat = 1200) {
        self.timeout = timeout
        self.maxPixel = maxPixel
    }

    public func preview(for url: URL) async throws -> LinkPreview {
        let provider = LPMetadataProvider()
        provider.timeout = timeout
        let metadata = try await provider.startFetchingMetadata(for: url)
        let title = metadata.title
        let imageProvider = metadata.imageProvider ?? metadata.iconProvider
        var data: Data?
        if let imageProvider {
            data = try? await Self.loadImageData(imageProvider, maxPixel: maxPixel)
        }
        return LinkPreview(title: title, imageData: data)
    }

    static func loadImageData(_ provider: NSItemProvider, maxPixel: CGFloat) async throws -> Data? {
        let box: ImageBox = try await withCheckedThrowingContinuation { cont in
            _ = provider.loadObject(ofClass: NSImage.self) { object, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: ImageBox(image: object as? NSImage)) }
            }
        }
        guard let image = box.image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, maxPixel / CGFloat(max(cg.width, cg.height)))
        let w = Int(CGFloat(cg.width) * scale), h = Int(CGFloat(cg.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:])
    }
}

private struct ImageBox: @unchecked Sendable { let image: NSImage? }
