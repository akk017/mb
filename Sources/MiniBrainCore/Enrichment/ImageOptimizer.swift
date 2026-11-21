import CoreGraphics
import CWebP
import Foundation
import ImageIO

/// WebP encoding via the vendored libwebp (macOS decodes WebP but can't encode it).
public enum WebPEncoder {
    /// Encodes a CGImage (orientation already applied) as lossy WebP.
    public static func encode(_ image: CGImage, quality: Float) -> Data? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= 16383, height <= 16383 else { return nil } // WebP limit
        let stride = width * 4
        var pixels = [UInt8](repeating: 0, count: stride * height)
        guard let ctx = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: stride,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // libwebp wants straight (non-premultiplied) alpha.
        var i = 0
        while i < pixels.count {
            let a = pixels[i + 3]
            if a != 0 && a != 255 {
                let f = 255 / Double(a)
                pixels[i] = UInt8(min(255, Double(pixels[i]) * f))
                pixels[i + 1] = UInt8(min(255, Double(pixels[i + 1]) * f))
                pixels[i + 2] = UInt8(min(255, Double(pixels[i + 2]) * f))
            }
            i += 4
        }
        var output: UnsafeMutablePointer<UInt8>?
        let size = mb_webp_encode_rgba(pixels, Int32(width), Int32(height), Int32(stride), quality, 0, &output)
        guard size > 0, let output else { return nil }
        defer { mb_webp_free(output) }
        return Data(bytes: output, count: size)
    }
}

/// Re-encodes stored images as WebP when that makes them smaller.
public enum ImageOptimizer {
    public static let defaultQuality: Float = 82
    /// Keep the original unless WebP saves at least this fraction.
    public static let minimumSaving = 0.05

    /// WebP bytes for `data`, or nil when it should stay as is (already WebP,
    /// animated GIF, undecodable, or WebP wouldn't be smaller).
    public static func webp(from data: Data, quality: Float = defaultQuality) -> Data? {
        guard let format = DataSniffer.imageExtension(data), format != "webp" else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        if format == "gif", CGImageSourceGetCount(source) > 1 { return nil } // keep animation
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        // Full size with EXIF orientation baked in (WebP has no orientation tag).
        guard max(w, h) > 0,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: max(w, h),
              ] as CFDictionary),
              let webp = WebPEncoder.encode(image, quality: quality)
        else { return nil }
        return Double(webp.count) <= Double(data.count) * (1 - minimumSaving) ? webp : nil
    }
}

/// `optimize_image` job: converts an image item's file (or a link's preview
/// image) to WebP, then the old file is removed if nothing else uses it.
public struct ImageOptimizeProcessor: EnrichmentProcessor {
    public static let optimizedKey = "webp_optimized"
    public let kind = EnrichmentKind.optimizeImage
    public let isEnabled: @Sendable () -> Bool
    public let quality: Float

    public init(quality: Float = ImageOptimizer.defaultQuality, isEnabled: @escaping @Sendable () -> Bool = { true }) {
        self.quality = quality
        self.isEnabled = isEnabled
    }

    public func process(_ item: Item, context: EnrichmentContext) async throws -> EnrichmentResult {
        guard isEnabled(), item.meta[Self.optimizedKey]?.boolValue != true else { return .empty }
        switch item.type {
        case .image:
            guard let hash = item.blobHash else { return .empty }
            let original = try context.blobs.read(hash)
            guard let webp = ImageOptimizer.webp(from: original, quality: quality) else {
                return EnrichmentResult(meta: [Self.optimizedKey: true])
            }
            let newHash = try context.blobs.store(webp, fileExtension: "webp").hash
            return EnrichmentResult(
                meta: [Self.optimizedKey: true, "format": "webp",
                       "byte_size": .number(Double(webp.count)), "original_byte_size": .number(Double(original.count))],
                blobHash: newHash, obsoleteBlobs: [hash])
        case .link:
            guard let hash = item.meta[LinkPreviewProcessor.previewBlobKey]?.stringValue else { return .empty }
            let original = try context.blobs.read(hash)
            guard let webp = ImageOptimizer.webp(from: original, quality: quality) else {
                return EnrichmentResult(meta: [Self.optimizedKey: true])
            }
            let newHash = try context.blobs.store(webp, fileExtension: "webp").hash
            return EnrichmentResult(
                meta: [Self.optimizedKey: true, LinkPreviewProcessor.previewBlobKey: .string(newHash)],
                obsoleteBlobs: [hash])
        case .text, .pdf:
            return .empty
        }
    }
}
