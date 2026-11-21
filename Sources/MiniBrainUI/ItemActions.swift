import AppKit
import MiniBrainCore

/// The slice of NSWorkspace the app uses.
@MainActor
public protocol Workspace: AnyObject {
    @discardableResult func open(_ url: URL) -> Bool
    func activateFileViewerSelecting(_ fileURLs: [URL])
}

extension NSWorkspace: Workspace {}

/// The slice of NSPasteboard the app writes to.
@MainActor
public protocol PasteboardWriting: AnyObject {
    @discardableResult func clearContents() -> Int
    @discardableResult func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool
    @discardableResult func setData(_ data: Data?, forType dataType: NSPasteboard.PasteboardType) -> Bool
}

extension NSPasteboard: PasteboardWriting {}

extension NSPasteboard: PasteboardReading {
    public var availableTypes: [String] { types?.map(\.rawValue) ?? [] }
    public func data(forType type: String) -> Data? { data(forType: NSPasteboard.PasteboardType(type)) }
    public func string(forType type: String) -> String? { string(forType: NSPasteboard.PasteboardType(type)) }
}

/// Open, reveal in Finder, copy, trash.
@MainActor
public struct ItemActions {
    let workspace: any Workspace
    let pasteboard: any PasteboardWriting
    let blobs: BlobStore
    let repository: ItemRepository

    public init(workspace: any Workspace, pasteboard: any PasteboardWriting, blobs: BlobStore, repository: ItemRepository) {
        self.workspace = workspace
        self.pasteboard = pasteboard
        self.blobs = blobs
        self.repository = repository
    }

    public func fileURL(for item: Item) -> URL? {
        item.blobHash.flatMap(blobs.url(for:))
    }

    /// Fetched link-preview image (links have no blob of their own).
    public func previewURL(for item: Item) -> URL? {
        item.meta[LinkPreviewProcessor.previewBlobKey]?.stringValue.flatMap(blobs.url(for:))
    }

    public func canOpen(_ item: Item) -> Bool { item.type == .link ? item.url != nil : fileURL(for: item) != nil }
    public func canReveal(_ item: Item) -> Bool { fileURL(for: item) != nil }

    /// Links open in the browser; files in their default app.
    @discardableResult
    public func open(_ item: Item) -> Bool {
        if item.type == .link || item.blobHash == nil, let s = item.url, let url = URL(string: s) {
            return workspace.open(url)
        }
        guard let file = fileURL(for: item) else { return false }
        return workspace.open(file)
    }

    @discardableResult
    public func revealInFinder(_ item: Item) -> Bool {
        guard let file = fileURL(for: item) else { return false }
        workspace.activateFileViewerSelecting([file])
        return true
    }

    @discardableResult
    public func copy(_ item: Item) throws -> Bool {
        pasteboard.clearContents()
        switch item.type {
        case .text:
            var text = item.content.isEmpty ? item.title : item.content
            if let url = item.url, text.isEmpty { text = url }
            return pasteboard.setString(text, forType: .string)
        case .link:
            guard let url = item.url else { return false }
            pasteboard.setString(url, forType: .URL)
            return pasteboard.setString(url, forType: .string)
        case .image:
            guard let hash = item.blobHash else { return false }
            let data = try blobs.read(hash)
            switch DataSniffer.imageExtension(data) {
            case "png": return pasteboard.setData(data, forType: .png)
            case "tiff": return pasteboard.setData(data, forType: .tiff)
            default:
                // WebP/JPEG/HEIC: give other apps PNG + TIFF, which everything accepts.
                guard let image = NSImage(data: data), let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
                else { return false }
                pasteboard.setData(tiff, forType: .tiff)
                return pasteboard.setData(png, forType: .png)
            }
        case .pdf:
            guard let hash = item.blobHash else { return false }
            return pasteboard.setData(try blobs.read(hash), forType: .pdf)
        }
    }

    public func trash(_ item: Item) throws {
        try repository.trash(item.id)
    }
}
