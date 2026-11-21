import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MiniBrainCore
@testable import MiniBrainUI

@Suite struct DockModeTests {
    @Test func dockVisibilityPerMode() {
        #expect(DockMode.always.showsInDock(windowOpen: false))
        #expect(DockMode.always.showsInDock(windowOpen: true))
        #expect(!DockMode.whileWindowsOpen.showsInDock(windowOpen: false))
        #expect(DockMode.whileWindowsOpen.showsInDock(windowOpen: true))
        #expect(!DockMode.never.showsInDock(windowOpen: true))
    }

    @Test @MainActor func defaultsToAlwaysAndPersists() {
        let d = makeDefaults()
        let p = AppPreferences(defaults: d)
        #expect(p.dockMode == .always)
        #expect(p.autoTag)
        p.dockMode = .never
        p.autoTag = false
        let reloaded = AppPreferences(defaults: d)
        #expect(reloaded.dockMode == .never)
        #expect(!reloaded.autoTag)
        #expect(!AppPreferences.isAutoTagEnabled(defaults: d))
    }
}

@Suite @MainActor struct AutoTagSwitchTests {
    func key(_ code: UInt16, _ mods: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0,
                         context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }

    @Test func leftRightEnterReachHandler() {
        let panel = DropBoxPanel(content: Text("x"))
        var keys: [DropBoxPanel.DropBoxKey] = []
        panel.onArrowKey = { keys.append($0); return true }
        panel.keyDown(with: key(123))   // ←
        panel.keyDown(with: key(124))   // →
        panel.keyDown(with: key(36))    // Return
        panel.keyDown(with: key(124, .command)) // ⌘→ is not ours
        #expect(keys == [.left, .right, .enter])
    }

    @Test func modelTogglesAndReports() throws {
        let env = try TestEnv()
        let vm = DropBoxViewModel(capturer: CaptureService(database: env.db, blobs: env.blobs, clock: env.clock), clock: FakeClock())
        var reported: [Bool] = []
        vm.onAutoTagChange = { reported.append($0) }
        vm.setAutoTag(false)
        vm.setAutoTag(false) // no change, no report
        vm.setAutoTag(true)
        #expect(reported == [false, true])
        #expect(vm.autoTag)
    }
}

@Suite struct AutoTagPipelineTests {
    @Test func disabledSkipsTagJobsOnCapture() throws {
        let env = try TestEnv()
        let flag = Flag(false)
        let capture = CaptureService(database: env.db, blobs: env.blobs, clock: env.clock, isKindEnabled: { kind in
            (kind != .aiTags && kind != .imageTags) || flag.on
        })
        let off = try capture.capture(.imageData(try Fixtures.data("red.png")))
        let kinds = try jobs(env, off.id).map(\.kind)
        #expect(!kinds.contains(.aiTags) && !kinds.contains(.imageTags))
        #expect(kinds.contains(.colors))
        flag.on = true
        let on = try capture.capture(.plainText("hello"))
        #expect(try jobs(env, on.id).map(\.kind).contains(.aiTags))
    }

    @Test func queuedTagJobsSkippedWhenTurnedOff() async throws {
        let env = try TestEnv()
        let item = try env.makeItem(title: "Sourdough starter", content: "starter flour water")
        let tagger = AITagProcessor(primary: FakeTagger(suggestion: TagSuggestion(tags: ["bread"])), isEnabled: { false })
        try await runAITags(tagger, env: env, itemID: item.id)
        #expect(try env.repo.tags(for: item.id).isEmpty)
        let manager = ModelManager<any VisionLanguageModel>(clock: env.clock) { FakeModel(output: "chair") }
        let image = try await runProcessor(ImageTagProcessor(tagger: VLMImageTagger(manager: manager), isEnabled: { false }),
                                           payload: .imageData(try Fixtures.data("red.png")), env: env)
        #expect(try env.repo.tags(for: image.id).isEmpty)
    }
}
