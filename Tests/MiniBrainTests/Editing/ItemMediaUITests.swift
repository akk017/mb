import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MiniBrainCore
@testable import MiniBrainUI

@Suite @MainActor struct ImageDropLoaderTests {
    @Test func readsImageFileDroppedFromFinder() async throws {
        let png = try Fixtures.data("two-color.png")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cover-\(UUID().uuidString).png")
        try png.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let provider = NSItemProvider(contentsOf: file)!
        #expect(await ImageDropLoader.data(from: [provider]) == png)
    }

    @Test func readsImageDataDraggedFromABrowser() async throws {
        let png = try Fixtures.data("red.png")
        let provider = NSItemProvider(item: png as NSData, typeIdentifier: UTType.png.identifier)
        #expect(await ImageDropLoader.data(from: [provider]) == png)
    }

    @Test func ignoresNonImageFiles() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(await ImageDropLoader.data(from: [NSItemProvider(contentsOf: file)!]) == nil)
    }
}

@Suite @MainActor struct ThumbnailChoiceTests {
    @Test func customCoverWinsThenOwnFileThenLinkPreview() throws {
        let env = try TestEnv()
        let actions = ItemActions(workspace: FakeWorkspace(), pasteboard: FakePasteboardWriter(), blobs: env.blobs, repository: env.repo)
        let pdfBlob = try env.blobs.store(fakePDF("p"), fileExtension: "pdf").hash
        let preview = try env.blobs.store(try Fixtures.data("red.png"), fileExtension: "png").hash

        let pdf = try env.makeItem(.pdf, blobHash: pdfBlob)
        #expect(actions.thumbnail(for: pdf)?.isPreview == false) // PDF page

        let link = try env.makeItem(.link, url: "https://a.com", meta: ["preview_blob": .string(preview)])
        #expect(actions.thumbnail(for: link)?.isPreview == true) // fetched preview

        let coveredPDF = try env.makeItem(.pdf, blobHash: pdfBlob,
                                          meta: ["preview_blob": .string(preview), ItemEditor.customPreviewKey: true])
        let thumb = try #require(actions.thumbnail(for: coveredPDF))
        #expect(thumb.isPreview)
        #expect(thumb.url == env.blobs.url(for: preview)) // cover beats the PDF page

        #expect(actions.thumbnail(for: try env.makeItem(.text)) == nil)
    }

    @Test func modelEditsURLAndImageThroughEditor() async throws {
        let env = try TestEnv()
        let item = try env.makeItem(.text, title: "Note")
        let lib = LibraryViewModel(search: SearchService(database: env.db), repository: env.repo, clock: env.clock)
        lib.itemEditor = ItemEditor(database: env.db, blobs: env.blobs, clock: env.clock)
        await lib.performSearch()
        #expect(throws: ItemEditError.invalidURL("hello world")) { try lib.setURL("hello world", for: item.id) }
        try lib.setURL("blog.arrtcle.com", for: item.id)
        #expect(lib.results.first?.item.url == "https://blog.arrtcle.com")
        try lib.setImage(try Fixtures.data("two-color.png"), for: item.id)
        #expect(lib.results.first?.item.meta[ItemEditor.customPreviewKey] == true)
        try lib.removeImage(for: item.id)
        #expect(lib.results.first?.item.meta["preview_blob"] == nil)
    }
}

@Suite @MainActor struct OpenPictureTests {
    func setup() throws -> (TestEnv, FakeWorkspace, ItemActions) {
        let env = try TestEnv()
        let ws = FakeWorkspace()
        return (env, ws, ItemActions(workspace: ws, pasteboard: FakePasteboardWriter(), blobs: env.blobs, repository: env.repo))
    }

    @Test func linkPictureOpensTheImageNotTheWebPage() throws {
        let (env, ws, actions) = try setup()
        let cover = try env.blobs.store(try Fixtures.data("two-color.png"), fileExtension: "png").hash
        let link = try env.makeItem(.link, url: "https://antonz.org/x",
                                    meta: ["preview_blob": .string(cover), ItemEditor.customPreviewKey: true])
        #expect(actions.openPicture(link))
        #expect(ws.opened == [env.blobs.url(for: cover)!])
        #expect(!ws.opened.contains(URL(string: "https://antonz.org/x")!))
    }

    @Test func fetchedLinkPreviewAndNoteCoverOpenTheImage() throws {
        let (env, ws, actions) = try setup()
        let preview = try env.blobs.store(try Fixtures.data("red.png"), fileExtension: "png").hash
        let link = try env.makeItem(.link, url: "https://a.com", meta: ["preview_blob": .string(preview)])
        let note = try env.makeItem(.text, meta: ["preview_blob": .string(preview), ItemEditor.customPreviewKey: true])
        actions.openPicture(link)
        actions.openPicture(note)
        #expect(ws.opened == [env.blobs.url(for: preview)!, env.blobs.url(for: preview)!])
    }

    @Test func imageAndPDFOpenTheirFile() throws {
        let (env, ws, actions) = try setup()
        let png = try env.blobs.store(try Fixtures.data("red.png"), fileExtension: "png").hash
        let pdf = try env.blobs.store(fakePDF("d"), fileExtension: "pdf").hash
        actions.openPicture(try env.makeItem(.image, blobHash: png))
        actions.openPicture(try env.makeItem(.pdf, blobHash: pdf))
        #expect(ws.opened == [env.blobs.url(for: png)!, env.blobs.url(for: pdf)!])
    }

    @Test func noPictureOpensNothing() throws {
        let (env, ws, actions) = try setup()
        #expect(!actions.openPicture(try env.makeItem(.text)))
        #expect(ws.opened.isEmpty)
    }
}
