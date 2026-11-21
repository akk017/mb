import Foundation

/// Abstract capture input, independent of AppKit. A single drop or paste can
/// carry several representations at once (e.g. a URL *and* its text); the
/// TypeDetector decides which one wins.
public struct CapturePayload: Equatable, Sendable {
    public var url: URL?
    public var plainText: String?
    public var html: String?
    public var imageData: Data?
    public var pdfData: Data?
    /// File name hint (e.g. from a dragged file) used for the title.
    public var suggestedName: String?

    public init(
        url: URL? = nil, plainText: String? = nil, html: String? = nil,
        imageData: Data? = nil, pdfData: Data? = nil, suggestedName: String? = nil
    ) {
        self.url = url
        self.plainText = plainText
        self.html = html
        self.imageData = imageData
        self.pdfData = pdfData
        self.suggestedName = suggestedName
    }

    public static func url(_ url: URL) -> CapturePayload { CapturePayload(url: url) }
    public static func plainText(_ s: String) -> CapturePayload { CapturePayload(plainText: s) }
    public static func html(_ s: String) -> CapturePayload { CapturePayload(html: s) }
    public static func imageData(_ d: Data) -> CapturePayload { CapturePayload(imageData: d) }
    public static func pdfData(_ d: Data) -> CapturePayload { CapturePayload(pdfData: d) }

    public var isEmpty: Bool {
        url == nil && (plainText ?? "").isEmpty && (html ?? "").isEmpty
            && (imageData ?? Data()).isEmpty && (pdfData ?? Data()).isEmpty
    }
}

/// What the detector decided to store.
public struct DetectedCapture: Equatable, Sendable {
    public var type: ItemType
    public var title: String
    public var content: String
    public var url: String?
    public var data: Data?
    public var fileExtension: String?
    public var meta: Meta
}
