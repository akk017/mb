import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MiniBrainCore
@testable import MiniBrainUI

// MARK: - Paste (⌘V handled by the panel itself)

@Suite @MainActor struct PanelPasteTests {
    func key(_ chars: String, _ mods: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 9)!
    }

    @Test func commandVTriggersPaste() {
        let panel = DropBoxPanel(content: Text("x"))
        var pasted = 0
        panel.onPaste = { pasted += 1 }
        #expect(panel.performKeyEquivalent(with: key("v", .command)))
        #expect(panel.performKeyEquivalent(with: key("V", [.command, .shift]))) // ⇧⌘V = paste into a type
        #expect(pasted == 2)
        #expect(!panel.performKeyEquivalent(with: key("c", .command)))
        #expect(!panel.performKeyEquivalent(with: key("v", [.command, .option])))
        #expect(pasted == 2)
    }

    @Test func commandCommaOpensSettings() {
        let panel = DropBoxPanel(content: Text("x"))
        var opened = 0
        panel.onOpenSettings = { opened += 1 }
        #expect(panel.performKeyEquivalent(with: key(",", .command)))
        #expect(opened == 1)
    }

    @Test func escapeClosesOrCancels() {
        let panel = DropBoxPanel(content: Text("x"))
        var escaped = false
        panel.onEscape = { escaped = true }
        panel.cancelOperation(nil)
        #expect(escaped)
    }

    @Test func pastedClipboardIsSaved() async throws {
        let env = try TestEnv()
        let vm = DropBoxViewModel(capturer: CaptureService(database: env.db, blobs: env.blobs, clock: env.clock), clock: FakeClock())
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        pb.setString("pasted from clipboard", forType: .string)
        #expect(await vm.paste(pb))
        #expect(try env.repo.fetchAll().map(\.title) == ["pasted from clipboard"])
        pb.releaseGlobally()
    }
}

// MARK: - Multi-select

@Suite @MainActor struct MultiSelectTests {
    func make(_ n: Int = 5) async throws -> (TestEnv, LibraryViewModel, [String]) {
        let env = try TestEnv()
        var ids: [String] = []
        for i in 0..<n {
            env.clock.advance(by: 1)
            ids.append(try env.makeItem(title: "item \(i)").id)
        }
        let vm = LibraryViewModel(search: SearchService(database: env.db), repository: env.repo, clock: env.clock)
        await vm.performSearch()
        return (env, vm, vm.results.map(\.id)) // newest first
    }

    @Test func plainClickSelectsOne() async throws {
        let (_, vm, ids) = try await make()
        vm.select(ids[1])
        #expect(vm.selectedIDs == [ids[1]])
        #expect(vm.selectedItem?.id == ids[1])
        #expect(!vm.isMultiSelection)
        vm.select(ids[3])
        #expect(vm.selectedIDs == [ids[3]])
    }

    @Test func commandClickToggles() async throws {
        let (_, vm, ids) = try await make()
        vm.select(ids[0])
        vm.select(ids[2], toggle: true)
        vm.select(ids[4], toggle: true)
        #expect(vm.selectedIDs == [ids[0], ids[2], ids[4]])
        #expect(vm.isMultiSelection)
        #expect(vm.selectedItem == nil)
        #expect(vm.selectedItems.map(\.id) == [ids[0], ids[2], ids[4]])
        vm.select(ids[2], toggle: true)
        #expect(vm.selectedIDs == [ids[0], ids[4]])
        vm.select(ids[0], toggle: true)
        vm.select(ids[4], toggle: true)
        #expect(vm.selectedIDs.isEmpty)
        #expect(vm.selectedItemID == nil)
    }

    @Test func shiftClickSelectsRange() async throws {
        let (_, vm, ids) = try await make()
        vm.select(ids[1])
        vm.select(ids[3], extendRange: true)
        #expect(vm.selectedIDs == Set(ids[1...3]))
    }

    @Test func selectAllAndClear() async throws {
        let (_, vm, ids) = try await make()
        vm.selectAll()
        #expect(vm.selectedIDs == Set(ids))
        vm.clearSelection()
        #expect(vm.selectedIDs.isEmpty)
        vm.selectedItemID = ids[0] // direct assignment still means single selection
        #expect(vm.selectedIDs == [ids[0]])
    }

    @Test func bulkTagTypeAndTrash() async throws {
        let (env, vm, ids) = try await make()
        let types = CustomTypeRepository(database: env.db, clock: env.clock)
        let products = try types.create(name: "Products")
        let vmWithTypes = LibraryViewModel(search: SearchService(database: env.db), repository: env.repo,
                                           customTypes: types, clock: env.clock)
        await vmWithTypes.performSearch()
        vmWithTypes.select(ids[0])
        vmWithTypes.select(ids[1], toggle: true)
        try vmWithTypes.addTagToSelected("bulk")
        try vmWithTypes.assignCustomTypeToSelected(products.id)
        for id in ids[0...1] {
            #expect(try env.repo.tags(for: id).map(\.name) == ["bulk"])
            #expect(try env.repo.fetch(id)?.customTypeID == products.id)
        }
        #expect(try env.repo.tags(for: ids[2]).isEmpty)
        try vmWithTypes.trashSelected()
        #expect(vmWithTypes.selectedIDs.isEmpty)
        #expect(try env.repo.count() == 3)
        _ = vm
    }

    @Test func selectionDropsItemsThatLeaveResults() async throws {
        let (env, vm, ids) = try await make()
        vm.select(ids[0])
        vm.select(ids[1], toggle: true)
        try env.repo.trash(ids[1])
        await vm.performSearch()
        #expect(vm.selectedIDs == [ids[0]])
    }
}

// MARK: - Link previews

struct FakeLinkFetcher: LinkPreviewFetching {
    var preview: LinkPreview
    var error: Error?
    func preview(for url: URL) async throws -> LinkPreview {
        if let error { throw error }
        return preview
    }
}

@Suite struct LinkPreviewTests {
    func run(_ fetcher: FakeLinkFetcher, payload: CapturePayload, env: TestEnv, enabled: Bool = true) async throws -> Item {
        try await runProcessor(LinkPreviewProcessor(fetcher: fetcher, isEnabled: { enabled }), payload: payload, env: env)
    }

    @Test func storesPreviewImageAndReplacesAutoTitle() async throws {
        let env = try TestEnv()
        let png = try Fixtures.data("two-color.png")
        let item = try await run(FakeLinkFetcher(preview: LinkPreview(title: "Green Cloud — VPS Hosting", imageData: png)),
                                 payload: .url(URL(string: "https://greencloud.example.com/vps")!), env: env)
        let hash = try #require(item.meta[LinkPreviewProcessor.previewBlobKey]?.stringValue)
        // Stored as WebP (smaller), same pixels size as the fetched PNG.
        let stored = try env.blobs.read(hash)
        #expect(DataSniffer.imageExtension(stored) == "webp")
        #expect(NSImage(data: stored)?.size == NSImage(data: png)?.size)
        #expect(item.title == "Green Cloud — VPS Hosting")
        #expect(item.meta["page_title"] == "Green Cloud — VPS Hosting")
        #expect(try SearchService(database: env.db).search("hosting").map(\.id) == [item.id])
    }

    @Test func keepsTitleTheUserProvided() async throws {
        let env = try TestEnv()
        let item = try await run(FakeLinkFetcher(preview: LinkPreview(title: "Page Title", imageData: nil)),
                                 payload: CapturePayload(url: URL(string: "https://a.com/x")!, plainText: "My own name"), env: env)
        #expect(item.title == "My own name")
        #expect(item.meta[LinkPreviewProcessor.previewBlobKey] == nil)
    }

    @Test func disabledDoesNothing() async throws {
        let env = try TestEnv()
        let item = try await run(FakeLinkFetcher(preview: LinkPreview(title: "T", imageData: Data([1]))),
                                 payload: .url(URL(string: "https://a.com/")!), env: env, enabled: false)
        #expect(item.meta[LinkPreviewProcessor.previewBlobKey] == nil)
        #expect(item.title == "a.com")
    }

    @Test func offlineFailureRetriesLater() async throws {
        let env = try TestEnv()
        let capture = CaptureService(database: env.db, blobs: env.blobs, clock: env.clock, enabledKinds: [.linkPreview])
        let item = try capture.capture(.url(URL(string: "https://a.com/")!))
        let worker = EnrichmentWorker(database: env.db, blobs: env.blobs, clock: env.clock, processors: [
            LinkPreviewProcessor(fetcher: FakeLinkFetcher(preview: LinkPreview(), error: URLError(.notConnectedToInternet))),
        ])
        #expect(await worker.runPending() == 1)
        let job = try #require(try jobs(env, item.id).first)
        #expect(job.status == .pending)
        #expect(job.attempts == 1)
    }

    @Test func linksGetPreviewJobAndBackfillCoversOldLinks() throws {
        let env = try TestEnv()
        #expect(EnrichmentKind.kinds(for: .link).first == .linkPreview)
        let old = try env.makeItem(.link, title: "old", url: "https://old.example.com")
        _ = try env.makeItem(.text, title: "note")
        let added = try env.write { try EnrichmentQueue.backfill(.linkPreview, forType: .link, now: env.clock.now, in: $0) }
        #expect(added == 1)
        #expect(try jobs(env, old.id).map(\.kind) == [.linkPreview])
        #expect(try env.write { try EnrichmentQueue.backfill(.linkPreview, forType: .link, now: env.clock.now, in: $0) } == 0)
    }

    @Test func previewBlobCountsAsReferenceAndIsPurged() throws {
        let env = try TestEnv()
        let hash = try env.blobs.store(try Fixtures.data("red.png"), fileExtension: "png").hash
        let link = try env.makeItem(.link, title: "l", url: "https://a.com", meta: [LinkPreviewProcessor.previewBlobKey: .string(hash)])
        #expect(try env.blobs.deleteIfUnreferenced(hash, database: env.db) == false)
        try env.repo.trash(link.id)
        env.clock.advance(by: 31 * 86_400)
        try env.repo.purgeTrash(blobs: env.blobs)
        #expect(!env.blobs.exists(hash))
    }
}

// MARK: - Palette (colors-firefox-dev.json)

@Suite struct PaletteTests {
    func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.01 }

    @Test func oklchConvertsKnownValues() {
        let white = OKLCH.rgb(100, 0, 0)
        #expect(close(white.r, 1) && close(white.g, 1) && close(white.b, 1))
        let black = OKLCH.rgb(0, 0, 0)
        #expect(close(black.r, 0) && close(black.g, 0) && close(black.b, 0))
        // oklch(62.8% 0.2577 29.23) is pure sRGB red.
        let red = OKLCH.rgb(62.8, 0.2577, 29.23)
        #expect(close(red.r, 1) && red.g < 0.03 && red.b < 0.03)
        // Hue ramps from the json: red is reddest, blue is bluest.
        let r = OKLCH.rgb(62, 0.21, 15), b = OKLCH.rgb(62, 0.24, 260)
        #expect(r.r > r.b && b.b > b.r)
    }

    @Test func tagPaletteHasTenEntries() {
        #expect(Theme.tagBackgrounds.count == 10)
        #expect(Theme.tagForegrounds.count == 10)
        #expect((0..<10).contains(TagPalette.index(for: "anything")))
    }
}

@Suite struct SlateThemeTests {
    func hex(_ c: NSColor) -> String {
        let s = c.usingColorSpace(.sRGB)!
        return String(format: "#%02X%02X%02X", Int((s.redComponent * 255).rounded()),
                      Int((s.greenComponent * 255).rounded()), Int((s.blueComponent * 255).rounded()))
    }

    @Test func slateScaleResolvesToExpectedHex() {
        let expected: [(NSColor, String)] = [
            (Theme.slate50, "#F8FAFC"), (Theme.slate100, "#F1F5F9"), (Theme.slate200, "#E2E8F0"),
            (Theme.slate300, "#CAD5E2"), (Theme.slate400, "#90A1B9"), (Theme.slate500, "#62748E"),
            (Theme.slate600, "#45556C"), (Theme.slate700, "#314158"), (Theme.slate800, "#1D293D"),
            (Theme.slate900, "#0F172B"), (Theme.slate950, "#020618"),
        ]
        for (color, value) in expected { #expect(hex(color) == value) }
    }

    @Test func surfacesAreCoolSlateNotPurple() {
        for c in [Theme.slate100, Theme.slate500, Theme.slate800, Theme.slate900, Theme.slate950] {
            let s = c.usingColorSpace(.sRGB)!
            var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0
            s.getHue(&h, saturation: &sat, brightness: &b, alpha: nil)
            #expect(s.blueComponent > s.redComponent)
            #expect((205...235).contains(h * 360), "hue \(h * 360) for \(hex(c))")
        }
    }

    @Test func darkModeIsDarkerThanBefore() {
        // Dark content background is near-black slate (luminance well under the old #171F2E).
        let s = Theme.slate950.usingColorSpace(.sRGB)!
        #expect(s.redComponent + s.greenComponent + s.blueComponent < 0.2)
    }
}
