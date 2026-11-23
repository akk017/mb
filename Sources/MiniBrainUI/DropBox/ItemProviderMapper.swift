import AppKit
import MiniBrainCore
import UniformTypeIdentifiers

/// NSItemProvider (drag & drop) → CapturePayload, per UTType.
///
/// Order matters only for which representations get loaded; the
/// TypeDetector decides the final type.
@MainActor
public enum ItemProviderMapper {
    public static let acceptedTypes: [UTType] = [.fileURL, .pdf, .image, .url, .html, .plainText]

    public static func payload(from providers: [NSItemProvider]) async throws -> CapturePayload {
        var payload = CapturePayload()
        for provider in providers {
            try await merge(provider, into: &payload)
        }
        guard !payload.isEmpty else { throw MiniBrainError.unsupportedPayload }
        return payload
    }

    static func merge(_ provider: NSItemProvider, into payload: inout CapturePayload) async throws {
        let has = { (type: UTType) in provider.hasItemConformingToTypeIdentifier(type.identifier) }

        if has(.fileURL), let fileURL = try await loadURL(provider, type: .fileURL), fileURL.isFileURL {
            let filePayload = try FilePayloadReader.payload(forFile: fileURL)
            payload.pdfData = payload.pdfData ?? filePayload.pdfData
            payload.imageData = payload.imageData ?? filePayload.imageData
            payload.html = payload.html ?? filePayload.html
            payload.plainText = payload.plainText ?? filePayload.plainText
            payload.suggestedName = payload.suggestedName ?? filePayload.suggestedName
            return
        }
        if payload.pdfData == nil, has(.pdf) {
            payload.pdfData = try await loadData(provider, type: .pdf)
        }
        if payload.imageData == nil, let imageType = preferredImageType(provider) {
            payload.imageData = try await loadData(provider, type: imageType)
        }
        if payload.url == nil, has(.url), let url = try await loadURL(provider, type: .url), !url.isFileURL {
            payload.url = url
        }
        if payload.html == nil, has(.html), let data = try await loadData(provider, type: .html) {
            payload.html = String(data: data, encoding: .utf8)
        }
        if payload.plainText == nil, has(.plainText) {
            payload.plainText = try await loadString(provider)
        }
        if payload.suggestedName == nil, let name = provider.suggestedName, payload.imageData != nil || payload.pdfData != nil {
            payload.suggestedName = name
        }
    }

    /// The dropped file when it's a single .csv / .tsv (imported as rows, not saved as a note).
    static func csvFileURL(_ providers: [NSItemProvider]) async -> URL? {
        guard providers.count == 1, let provider = providers.first,
              provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
              let url = try? await loadURL(provider, type: .fileURL), url.isFileURL,
              ["csv", "tsv"].contains(url.pathExtension.lowercased())
        else { return nil }
        return url
    }

    static func preferredImageType(_ provider: NSItemProvider) -> UTType? {
        for type in [UTType.png, .jpeg, .heic, .gif, .tiff, .image]
        where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            return type
        }
        return nil
    }

    static func loadData(_ provider: NSItemProvider, type: UTType) async throws -> Data? {
        try await withCheckedThrowingContinuation { cont in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: data) }
            }
        }
    }

    static func loadURL(_ provider: NSItemProvider, type: UTType) async throws -> URL? {
        let item = try await loadItem(provider, type: type)
        switch item {
        case let url as URL: return url
        case let url as NSURL: return url as URL
        case let data as Data:
            if let url = URL(dataRepresentation: data, relativeTo: nil) { return url }
            if let s = String(data: data, encoding: .utf8) { return URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return nil
        case let s as String: return URL(string: s)
        case let s as NSString: return URL(string: s as String)
        default: return nil
        }
    }

    static func loadString(_ provider: NSItemProvider) async throws -> String? {
        for type in [UTType.utf8PlainText, .plainText] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            switch try await loadItem(provider, type: type) {
            case let s as String: return s
            case let s as NSString: return s as String
            case let s as NSAttributedString: return s.string
            case let d as Data: if let s = String(data: d, encoding: .utf8) { return s }
            default: continue
            }
        }
        return nil
    }

    static func loadItem(_ provider: NSItemProvider, type: UTType) async throws -> Any? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UncheckedBox, Error>) in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: UncheckedBox(item)) }
            }
        }.value
    }
}

/// Moves a non-Sendable value across the loadItem callback boundary.
struct UncheckedBox: @unchecked Sendable {
    let value: Any?
    init(_ value: Any?) { self.value = value }
}
