import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MiniBrainCore
@testable import MiniBrainUI

// MARK: - Fakes

@MainActor
final class FakeHotkeyRegistrar: HotkeyRegistering {
    var handlers: [Hotkey: @MainActor () -> Void] = [:]
    var combos: [Hotkey: KeyCombo] = [:]
    /// Combos the "system" refuses (taken by another app).
    var taken: Set<KeyCombo> = []
    var paused = false
    var supportsCustomCombos: Bool { true }
    func register(_ hotkey: Hotkey, handler: @escaping @MainActor () -> Void) { handlers[hotkey] = handler }
    func setCombo(_ combo: KeyCombo?, for hotkey: Hotkey) -> Bool {
        if let combo, taken.contains(combo) { combos[hotkey] = nil; return false }
        combos[hotkey] = combo
        return true
    }
    func setPaused(_ paused: Bool) { self.paused = paused }
    func unregisterAll() { handlers.removeAll() }
    func trigger(_ hotkey: Hotkey) { handlers[hotkey]?() }
}

@MainActor
final class FakePresenter: WindowPresenting {
    var calls: [String] = []
    func setDropBoxVisible(_ visible: Bool) { calls.append("dropBox:\(visible)") }
    func showDropBoxForDrag() { calls.append("dropBox:drag") }
    func setLibraryVisible(_ visible: Bool) { calls.append("library:\(visible)") }
}

/// Capturer whose completion the test controls.
final class GatedCapturer: Capturing, @unchecked Sendable {
    private let lock = NSLock()
    private var gate: CheckedContinuation<Void, Never>?
    private var opened = false
    var error: Error?
    private(set) var payloads: [CapturePayload] = []

    func save(_ payload: CapturePayload, customTypeID: String?) async throws -> Item {
        lock.withLock { payloads.append(payload) }
        await withCheckedContinuation { cont in
            lock.lock()
            if opened { lock.unlock(); cont.resume() } else { gate = cont; lock.unlock() }
        }
        if let error { throw error }
        return Item(type: .text, title: payload.plainText ?? "item", createdAt: Date())
    }

    func open() {
        lock.lock()
        opened = true
        let g = gate
        gate = nil
        lock.unlock()
        g?.resume()
    }
}

@MainActor
func waitUntil(_ condition: @MainActor () -> Bool, timeout: TimeInterval = 5) async {
    let end = Date().addingTimeInterval(timeout)
    // Also require a minimum number of polls: when other main-actor tests hog
    // the main thread, the deadline can pass before the awaited work (a
    // debounce, a scheduled refresh) ever got a turn to run.
    var polls = 0
    while !condition(), Date() < end || polls < 100 {
        try? await Task.sleep(nanoseconds: 1_000_000)
        polls += 1
    }
}

// MARK: - T4.1 Hotkeys

@Suite @MainActor struct AppStateTests {
    @Test func hotkeysToggleState() {
        let state = AppState()
        let registrar = FakeHotkeyRegistrar()
        let presenter = FakePresenter()
        state.presenter = presenter
        state.bindHotkeys(registrar)
        #expect(Set(registrar.handlers.keys) == Set(Hotkey.allCases))

        registrar.trigger(.toggleDropBox)
        #expect(state.isDropBoxVisible)
        registrar.trigger(.toggleDropBox)
        #expect(!state.isDropBoxVisible)

        registrar.trigger(.toggleLibrary)
        #expect(state.isLibraryVisible)
        #expect(!state.isDropBoxVisible)
        #expect(presenter.calls == ["dropBox:true", "dropBox:false", "library:true"])
    }

    @Test func settingSameVisibilityIsNoOp() {
        let state = AppState()
        let presenter = FakePresenter()
        state.presenter = presenter
        state.setLibraryVisible(false)
        state.setLibraryVisible(true)
        state.setLibraryVisible(true)
        #expect(presenter.calls == ["library:true"])
    }
}

// MARK: - T4.2 Drop box

@Suite @MainActor struct DropBoxViewModelTests {
    @Test func hoverStates() {
        let vm = DropBoxViewModel(capturer: GatedCapturer(), clock: FakeClock())
        #expect(vm.state == .idle)
        vm.dragEntered()
        #expect(vm.state == .hovering)
        vm.dragExited()
        #expect(vm.state == .idle)
    }

    @Test func idleHoveringSavingSavedIdle() async {
        let clock = FakeClock()
        let capturer = GatedCapturer()
        let vm = DropBoxViewModel(capturer: capturer, clock: clock)
        vm.dragEntered()
        let provider = NSItemProvider(object: "remember this" as NSString)
        let drop = Task { await vm.drop([provider]) }
        await waitUntil { vm.state == .saving }
        #expect(vm.state == .saving)
        capturer.open()
        #expect(await drop.value)
        #expect(vm.state == .saved(title: "remember this"))
        await clock.waitForSleepers()
        clock.advance(by: 1.5)
        await waitUntil { vm.state == .idle }
        #expect(vm.state == .idle)
    }

    @Test func errorState() async {
        let clock = FakeClock()
        let capturer = GatedCapturer()
        capturer.error = MiniBrainError.emptyPayload
        capturer.open()
        let vm = DropBoxViewModel(capturer: capturer, clock: clock)
        #expect(await vm.drop([NSItemProvider(object: "x" as NSString)]) == false)
        #expect(vm.state == .error("Nothing to save"))
        await clock.waitForSleepers()
        clock.advance(by: 2)
        await waitUntil { vm.state == .idle }
        #expect(vm.state == .idle)
    }

    @Test func unsupportedProviderGivesError() async {
        let capturer = GatedCapturer()
        capturer.open()
        let vm = DropBoxViewModel(capturer: capturer, clock: FakeClock())
        let provider = NSItemProvider(item: Data([1, 2]) as NSData, typeIdentifier: "com.example.unknown")
        #expect(await vm.drop([provider]) == false)
        #expect(vm.state == .error("Unsupported content"))
        #expect(capturer.payloads.isEmpty)
    }

    @Test func pasteUsesSamePipeline() async throws {
        let env = try TestEnv()
        let service = CaptureService(database: env.db, blobs: env.blobs, clock: env.clock)
        let vm = DropBoxViewModel(capturer: service, clock: FakeClock())
        #expect(await vm.paste(FakePasteboard(strings: [UTI.utf8Text: "pasted words"])))
        #expect(try env.repo.fetchAll().map(\.title) == ["pasted words"])
    }
}

@Suite @MainActor struct ItemProviderMappingTests {
    @Test func pngMapsToImageData() async throws {
        let png = try Fixtures.data("red.png")
        let p = NSItemProvider(item: png as NSData, typeIdentifier: UTType.png.identifier)
        let payload = try await ItemProviderMapper.payload(from: [p])
        #expect(payload.imageData == png)
        #expect(try TypeDetector.detect(payload).type == .image)
    }

    @Test func tiffMapsToImageData() async throws {
        let tiff = NSImage(data: try Fixtures.data("red.png"))!.tiffRepresentation!
        let p = NSItemProvider(item: tiff as NSData, typeIdentifier: UTType.tiff.identifier)
        #expect(try await ItemProviderMapper.payload(from: [p]).imageData == tiff)
    }

    @Test func pdfMapsToPDFData() async throws {
        let pdf = try Fixtures.data("sample.pdf")
        let p = NSItemProvider(item: pdf as NSData, typeIdentifier: UTType.pdf.identifier)
        let payload = try await ItemProviderMapper.payload(from: [p])
        #expect(payload.pdfData == pdf)
    }

    @Test func urlMapsToURL() async throws {
        let p = NSItemProvider(object: URL(string: "https://swift.org/blog")! as NSURL)
        let payload = try await ItemProviderMapper.payload(from: [p])
        #expect(payload.url == URL(string: "https://swift.org/blog"))
        #expect(try TypeDetector.detect(payload).type == .link)
    }

    @Test func plainTextMapsToText() async throws {
        let p = NSItemProvider(object: "a dragged sentence" as NSString)
        let payload = try await ItemProviderMapper.payload(from: [p])
        #expect(payload.plainText == "a dragged sentence")
    }

    @Test func htmlMapsToHTML() async throws {
        let html = try String(contentsOf: Fixtures.url("snippet-cfhtml.html"), encoding: .utf8)
        let p = NSItemProvider(item: Data(html.utf8) as NSData, typeIdentifier: UTType.html.identifier)
        let payload = try await ItemProviderMapper.payload(from: [p])
        #expect(payload.html == html)
        let detected = try TypeDetector.detect(payload)
        #expect(detected.url == "https://www.example.com/articles/walnut-sideboards")
        #expect(detected.content.contains("walnut sideboards"))
    }

    @Test func fileURLReadsFileContents() async throws {
        let p = try #require(NSItemProvider(contentsOf: Fixtures.url("sample.pdf")))
        let payload = try await ItemProviderMapper.payload(from: [p])
        #expect(payload.pdfData == (try Fixtures.data("sample.pdf")))
        #expect(payload.suggestedName == "sample.pdf")
    }

    @Test func multipleProvidersMerge() async throws {
        let url = NSItemProvider(object: URL(string: "https://a.dev")! as NSURL)
        let text = NSItemProvider(object: "A dev site" as NSString)
        let payload = try await ItemProviderMapper.payload(from: [url, text])
        let d = try TypeDetector.detect(payload)
        #expect(d.type == .link)
        #expect(d.title == "A dev site")
    }

    @Test func unknownTypeRejected() async {
        let p = NSItemProvider(item: Data([0]) as NSData, typeIdentifier: "com.example.custom")
        await #expect(throws: MiniBrainError.unsupportedPayload) { try await ItemProviderMapper.payload(from: [p]) }
    }
}

// MARK: - T4.3 Library

final class CountingSearch: SearchProviding, @unchecked Sendable {
    let base: SearchService
    private let lock = NSLock()
    private var _queries: [String] = []
    var queries: [String] { lock.withLock { _queries } }
    init(_ base: SearchService) { self.base = base }
    func results(for query: String, limit: Int) async throws -> [SearchResult] {
        lock.withLock { _queries.append(query) }
        return try base.search(query, limit: limit)
    }
}

@Suite @MainActor struct LibraryViewModelTests {
    func make() throws -> (TestEnv, LibraryViewModel, CountingSearch) {
        let env = try TestEnv()
        let search = CountingSearch(SearchService(database: env.db, parser: QueryParser(timeZone: utc)))
        let vm = LibraryViewModel(search: search, repository: env.repo, clock: env.clock)
        vm.timeZone = utc
        return (env, vm, search)
    }

    @Test func searchIsDebounced() async throws {
        let (env, vm, search) = try make()
        _ = try env.makeItem(title: "walnut table")
        vm.searchText = "w"
        vm.searchText = "wal"
        vm.searchText = "walnut"
        await env.clock.waitForSleepers()
        #expect(search.queries.isEmpty)
        env.clock.advance(by: 0.1)
        #expect(search.queries.isEmpty)
        env.clock.advance(by: 0.2)
        await waitUntil { vm.results.count == 1 }
        #expect(search.queries == ["walnut"])
        #expect(vm.results.map(\.item.title) == ["walnut table"])
    }

    @Test func filterStateBecomesQueryString() throws {
        let (_, vm, _) = try make()
        vm.searchText = "  chair "
        vm.filters = LibraryFilters(type: .image, tags: ["wishlist", "living room"], color: "red",
                                    after: day("2024-01-01"), before: day("2024-02-01"))
        #expect(vm.queryString == #"chair type:image tag:wishlist tag:"living room" color:red after:2024-01-01 before:2024-02-01"#)
        vm.searchText = ""
        vm.filters = LibraryFilters()
        #expect(vm.queryString == "")
        // Round-trips through the parser.
        let parsed = try QueryParser(timeZone: utc).parse(#"tag:"living room" type:pdf"#)
        #expect(parsed.filters == [.tag("living room"), .type(.pdf)])
    }

    @Test func filterChangeSearchesImmediately() async throws {
        let (env, vm, search) = try make()
        _ = try env.makeItem(.image, title: "photo")
        _ = try env.makeItem(.text, title: "note")
        vm.filters.type = .image
        await waitUntil { !search.queries.isEmpty && !vm.isSearching }
        #expect(search.queries == ["type:image"])
        #expect(vm.results.map(\.item.title) == ["photo"])
    }

    @Test func editingNoteAndTagsPersists() async throws {
        let (env, vm, _) = try make()
        let item = try env.makeItem(title: "lamp")
        await vm.performSearch()
        vm.selectedItemID = item.id
        try vm.saveNote("buy before winter", for: item.id)
        try vm.setTags(["home", "Lighting"], for: item.id)
        #expect(try env.repo.fetch(item.id)?.note == "buy before winter")
        #expect(Set(try env.repo.tags(for: item.id).map(\.name)) == ["home", "Lighting"])
        #expect(vm.selectedItem?.note == "buy before winter")
        try vm.setTags(["home"], for: item.id)
        #expect(try env.repo.tags(for: item.id).map(\.name) == ["home"])
        #expect(vm.allTags == ["home"])
        // Persisted edits are searchable.
        #expect(try SearchService(database: env.db).search("winter").map(\.id) == [item.id])
    }

    @Test func emptyStateShown() async throws {
        let (env, vm, _) = try make()
        await vm.performSearch()
        #expect(vm.showsEmptyLibrary)
        #expect(!vm.showsNoResults)
        _ = try env.makeItem(title: "first")
        vm.searchText = "zzz"
        await vm.performSearch()
        #expect(!vm.showsEmptyLibrary)
        #expect(vm.showsNoResults)
    }

    @Test func invalidQueryShowsError() async throws {
        let (_, vm, _) = try make()
        vm.searchText = "after:nope"
        await vm.performSearch()
        #expect(vm.errorMessage?.contains("invalid date") == true)
    }
}

// MARK: - T4.4 Item actions

@MainActor
final class FakeWorkspace: Workspace {
    var opened: [URL] = []
    var revealed: [[URL]] = []
    func open(_ url: URL) -> Bool { opened.append(url); return true }
    func activateFileViewerSelecting(_ fileURLs: [URL]) { revealed.append(fileURLs) }
}

@MainActor
final class FakePasteboardWriter: PasteboardWriting {
    var cleared = 0
    var strings: [NSPasteboard.PasteboardType: String] = [:]
    var datas: [NSPasteboard.PasteboardType: Data] = [:]
    func clearContents() -> Int { cleared += 1; strings = [:]; datas = [:]; return cleared }
    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool { strings[dataType] = string; return true }
    func setData(_ data: Data?, forType dataType: NSPasteboard.PasteboardType) -> Bool { datas[dataType] = data; return data != nil }
}

@Suite @MainActor struct ItemActionsTests {
    func make() throws -> (TestEnv, ItemActions, FakeWorkspace, FakePasteboardWriter, CaptureService) {
        let env = try TestEnv()
        let ws = FakeWorkspace(), pb = FakePasteboardWriter()
        let actions = ItemActions(workspace: ws, pasteboard: pb, blobs: env.blobs, repository: env.repo)
        return (env, actions, ws, pb, CaptureService(database: env.db, blobs: env.blobs, clock: env.clock))
    }

    @Test func openLinkOpensURL() throws {
        let (_, actions, ws, _, capture) = try make()
        let link = try capture.capture(.url(URL(string: "https://example.com/x")!))
        #expect(actions.open(link))
        #expect(ws.opened == [URL(string: "https://example.com/x")!])
    }

    @Test func openFileOpensBlob() throws {
        let (env, actions, ws, _, capture) = try make()
        let pdf = try capture.capture(.pdfData(try Fixtures.data("sample.pdf")))
        #expect(actions.open(pdf))
        #expect(ws.opened == [env.blobs.url(for: pdf.blobHash!)!])
        #expect(ws.opened.first?.pathExtension == "pdf")
    }

    @Test func revealInFinderSelectsBlob() throws {
        let (env, actions, ws, _, capture) = try make()
        let image = try capture.capture(.imageData(try Fixtures.data("red.png")))
        #expect(actions.revealInFinder(image))
        #expect(ws.revealed == [[env.blobs.url(for: image.blobHash!)!]])
        let text = try capture.capture(.plainText("no file"))
        #expect(!actions.revealInFinder(text))
        #expect(ws.revealed.count == 1)
    }

    @Test func copyWritesCorrectPasteboardContent() throws {
        let (_, actions, _, pb, capture) = try make()

        let text = try capture.capture(.plainText("copy me\nplease"))
        #expect(try actions.copy(text))
        #expect(pb.strings == [.string: "copy me\nplease"])

        let link = try capture.capture(.url(URL(string: "https://a.b/c")!))
        #expect(try actions.copy(link))
        #expect(pb.strings == [.string: "https://a.b/c", .URL: "https://a.b/c"])

        let png = try Fixtures.data("red.png")
        let image = try capture.capture(.imageData(png))
        #expect(try actions.copy(image))
        #expect(pb.datas[.png] == png)
        #expect(pb.strings.isEmpty)

        let pdfData = try Fixtures.data("sample.pdf")
        let pdf = try capture.capture(.pdfData(pdfData))
        #expect(try actions.copy(pdf))
        #expect(pb.datas == [.pdf: pdfData])
        #expect(pb.cleared == 4)
    }

    @Test func trashMovesToTrash() throws {
        let (env, actions, _, _, capture) = try make()
        let item = try capture.capture(.plainText("bye"))
        try actions.trash(item)
        #expect(try env.repo.fetch(item.id)?.isTrashed == true)
        #expect(try env.repo.fetchAll().isEmpty)
    }
}
