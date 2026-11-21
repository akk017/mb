import CoreImage
import Foundation
import PDFKit
import Vision

// MARK: - T5.2 PDF text

public enum PDFTextExtractor {
    public struct Output: Equatable, Sendable {
        public var text: String
        public var pageCount: Int
        public var encrypted: Bool
    }

    /// Extracts text with PDFKit. Locked (password-protected) documents return
    /// empty text with `encrypted = true` instead of failing.
    public static func extract(_ data: Data) throws -> Output {
        guard let doc = PDFDocument(data: data) else {
            throw MiniBrainError.enrichmentFailed("unreadable PDF")
        }
        if doc.isLocked {
            return Output(text: "", pageCount: doc.pageCount, encrypted: true)
        }
        var pages: [String] = []
        for i in 0..<doc.pageCount {
            if let s = doc.page(at: i)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                pages.append(s)
            }
        }
        return Output(text: pages.joined(separator: "\n\n"), pageCount: doc.pageCount, encrypted: doc.isEncrypted)
    }
}

public struct PDFTextProcessor: EnrichmentProcessor {
    public let kind = EnrichmentKind.pdfText
    public init() {}

    public func process(_ item: Item, context: EnrichmentContext) async throws -> EnrichmentResult {
        let out = try PDFTextExtractor.extract(try context.blobData(for: item))
        var meta: Meta = ["page_count": .number(Double(out.pageCount))]
        if out.encrypted { meta["encrypted"] = true }
        return EnrichmentResult(content: out.text, meta: meta)
    }
}

// MARK: - T5.3 OCR

public enum OCRRecognizer {
    /// Recognized text lines (top to bottom), empty for images without text.
    public static func recognize(_ data: Data) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(data: data, options: [:])
        try handler.perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }
}

public struct OCRProcessor: EnrichmentProcessor {
    public let kind = EnrichmentKind.ocr
    /// Checked at run time so turning OCR off also skips queued jobs.
    public let isEnabled: @Sendable () -> Bool

    public init(isEnabled: @escaping @Sendable () -> Bool = { true }) { self.isEnabled = isEnabled }

    public func process(_ item: Item, context: EnrichmentContext) async throws -> EnrichmentResult {
        guard isEnabled() else { return .empty }
        let lines = try OCRRecognizer.recognize(try context.blobData(for: item))
        return EnrichmentResult(content: lines.joined(separator: "\n"), meta: ["has_text": .bool(!lines.isEmpty)])
    }
}

// MARK: - T5.4 Dominant colors

public enum ColorAnalyzer {
    public struct Swatch: Equatable, Sendable {
        public var name: String
        public var hex: String
        public var share: Double
    }

    static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Top `limit` named color buckets covering at least `minShare` of pixels.
    public static func dominantColors(_ data: Data, limit: Int = 3, minShare: Double = 0.08) throws -> [Swatch] {
        guard var image = CIImage(data: data) else { throw MiniBrainError.enrichmentFailed("unreadable image") }
        // Downsample with Core Image so analysis cost is independent of size.
        let maxSide = max(image.extent.width, image.extent.height)
        if maxSide > 64 {
            let scale = 64 / maxSide
            let filter = CIFilter(name: "CILanczosScaleTransform")!
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(scale, forKey: kCIInputScaleKey)
            filter.setValue(1.0, forKey: kCIInputAspectRatioKey)
            image = filter.outputImage!
        }
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0 else { return [] }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        ciContext.render(image, toBitmap: &pixels, rowBytes: width * 4, bounds: extent,
                         format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))

        var buckets: [String: (count: Int, r: Double, g: Double, b: Double)] = [:]
        var total = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Double(pixels[i + 3]) / 255
            guard a > 0.5 else { continue }
            // Un-premultiply.
            let r = Double(pixels[i]) / 255 / a, g = Double(pixels[i + 1]) / 255 / a, b = Double(pixels[i + 2]) / 255 / a
            let name = colorName(r: min(r, 1), g: min(g, 1), b: min(b, 1))
            var e = buckets[name] ?? (0, 0, 0, 0)
            e.count += 1; e.r += r; e.g += g; e.b += b
            buckets[name] = e
            total += 1
        }
        guard total > 0 else { return [] }
        var swatches: [Swatch] = []
        for (name, e) in buckets {
            let n = Double(e.count)
            let share = n / Double(total)
            guard share >= minShare else { continue }
            swatches.append(Swatch(name: name, hex: hex(e.r / n, e.g / n, e.b / n), share: share))
        }
        swatches.sort { a, b in a.share != b.share ? a.share > b.share : a.name < b.name }
        return Array(swatches.prefix(limit))
    }

    /// Maps an sRGB color (0…1) to a named bucket.
    public static func colorName(r: Double, g: Double, b: Double) -> String {
        let maxC = max(r, g, b), minC = min(r, g, b)
        let v = maxC
        let s = maxC == 0 ? 0 : (maxC - minC) / maxC
        if v < 0.18 { return "black" }
        if s < 0.15 { return v > 0.85 ? "white" : "gray" }
        var h: Double
        let d = maxC - minC
        if maxC == r { h = (g - b) / d } else if maxC == g { h = 2 + (b - r) / d } else { h = 4 + (r - g) / d }
        h *= 60
        if h < 0 { h += 360 }
        switch h {
        case 345..., ..<15: return v < 0.45 ? "brown" : "red"
        case 15..<45: return v < 0.6 ? "brown" : "orange"
        case 45..<70: return v < 0.5 ? "brown" : "yellow"
        case 70..<165: return "green"
        case 165..<260: return "blue"
        case 260..<290: return "purple"
        default: return "pink"
        }
    }

    static func hex(_ r: Double, _ g: Double, _ b: Double) -> String {
        String(format: "#%02X%02X%02X", Int((min(r, 1) * 255).rounded()), Int((min(g, 1) * 255).rounded()), Int((min(b, 1) * 255).rounded()))
    }
}

public struct ColorProcessor: EnrichmentProcessor {
    public let kind = EnrichmentKind.colors
    public init() {}

    public func process(_ item: Item, context: EnrichmentContext) async throws -> EnrichmentResult {
        let swatches = try ColorAnalyzer.dominantColors(try context.blobData(for: item))
        return EnrichmentResult(meta: [
            "colors": .array(swatches.map { .string($0.name) }),
            "dominant_colors": .array(swatches.map { .string($0.hex) }),
        ])
    }
}
