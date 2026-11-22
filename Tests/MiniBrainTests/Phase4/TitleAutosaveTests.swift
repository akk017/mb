import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MiniBrainCore
@testable import MiniBrainUI

@Suite @MainActor struct TitleAutosaveTests {
    final class Saved { var values: [String] = [] }

    @Test func typingSavesOnceAfterPause() async {
        let saved = Saved()
        let saver = DebouncedSaver(delay: .milliseconds(80)) { saved.values.append($0) }
        for partial in ["K", "Ka", "Kaa", "Kaantha"] { saver.schedule(partial) }
        #expect(saved.values.isEmpty) // nothing while typing
        await waitUntil { !saved.values.isEmpty }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(saved.values == ["Kaantha"]) // one save, the last value
    }

    @Test func enterSavesImmediatelyAndCancelsPendingSave() async {
        let saved = Saved()
        let saver = DebouncedSaver(delay: .milliseconds(80)) { saved.values.append($0) }
        saver.schedule("Kaantha (2025)")
        saver.flush() // Return
        #expect(saved.values == ["Kaantha (2025)"])
        try? await Task.sleep(for: .milliseconds(200))
        #expect(saved.values == ["Kaantha (2025)"]) // debounced copy doesn't fire again
        saver.flush() // nothing pending → no-op
        #expect(saved.values.count == 1)
    }

    @Test func flushOnLeavingSavesPendingEdit() {
        let saved = Saved()
        let saver = DebouncedSaver(delay: .seconds(10)) { saved.values.append($0) }
        saver.schedule("Half typed")
        saver.flush() // panel closed / another item selected
        #expect(saved.values == ["Half typed"])
    }

    @Test func modelSkipsBlankAndUnchangedTitles() async throws {
        let env = try TestEnv()
        let item = try env.makeItem(title: "Original")
        let lib = LibraryViewModel(search: SearchService(database: env.db), repository: env.repo, clock: env.clock)
        await lib.performSearch()
        let before = try #require(try env.repo.fetch(item.id)).updatedAt
        env.clock.advance(by: 5)
        try lib.saveTitle("   ", for: item.id)
        try lib.saveTitle("Original", for: item.id)
        #expect(try env.repo.fetch(item.id)?.updatedAt == before) // no writes
        try lib.saveTitle("  Renamed  ", for: item.id)
        #expect(try env.repo.fetch(item.id)?.title == "Renamed")
        #expect(lib.results.first?.item.title == "Renamed")
    }

    @Test func typingInPanelTitleSavesWithoutReturn() async throws {
        let env = try TestEnv()
        let item = try env.makeItem(title: "Kaantha (2025) ⭐ 7.2")
        let lib = LibraryViewModel(search: SearchService(database: env.db), repository: env.repo, clock: env.clock)
        await lib.performSearch()
        let actions = ItemActions(workspace: FakeWorkspace(), pasteboard: FakePasteboardWriter(), blobs: env.blobs, repository: env.repo)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 497, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: ItemPropertiesPanel(model: lib, actions: actions, item: item).frame(width: 497).defaultAppStorage(makeDefaults()))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        spinPerf(0.3)
        func fields(_ v: NSView) -> [NSTextField] { ((v as? NSTextField).map { [$0] } ?? []) + v.subviews.flatMap(fields) }
        let field = try #require(fields(host).first { $0.stringValue.hasPrefix("Kaantha") })
        window.makeFirstResponder(field)
        spinPerf(0.1)
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("Kaantha", replacementRange: editor.selectedRange())
        spinPerf(0.2)
        #expect(try env.repo.fetch(item.id)?.title == "Kaantha (2025) ⭐ 7.2") // not yet: still typing
        await waitUntil { (try? env.repo.fetch(item.id)?.title) == "Kaantha" }
        #expect(try env.repo.fetch(item.id)?.title == "Kaantha") // saved after the pause, no Return
    }
}
