import AppKit
import Carbon.HIToolbox
import Testing
@testable import MiniBrainUI

@Suite struct LibraryKeyTests {
    func cmd(_ code: Int, _ chars: String?, _ mods: NSEvent.ModifierFlags, editing: Bool = false) -> LibraryKeyCommand? {
        LibraryKeyCommand.command(keyCode: UInt16(code), characters: chars, modifiers: mods, isEditingText: editing)
    }

    @Test func selectionKeysWhenNotTyping() {
        #expect(cmd(kVK_ANSI_A, "a", .command) == .selectAll)
        #expect(cmd(kVK_Escape, nil, []) == .clearSelection)
        #expect(cmd(kVK_Delete, nil, .command) == .trashSelection)       // ⌘⌫
        #expect(cmd(kVK_ForwardDelete, nil, .command) == .trashSelection)
        #expect(cmd(kVK_Delete, nil, []) == nil)                         // plain ⌫ never deletes items
        #expect(cmd(kVK_ForwardDelete, nil, []) == nil)
    }

    @Test func typingInAFieldKeepsItsKeys() {
        // ⌘A selects the search text, ⌫ deletes characters, Esc is the field's.
        #expect(cmd(kVK_ANSI_A, "a", .command, editing: true) == nil)
        #expect(cmd(kVK_Delete, nil, [], editing: true) == nil)
        #expect(cmd(kVK_Delete, nil, .command, editing: true) == nil) // ⌘⌫ deletes the text line instead
        #expect(cmd(kVK_Escape, nil, [], editing: true) == nil)
    }

    @Test func otherKeysPassThrough() {
        #expect(cmd(kVK_ANSI_A, "a", []) == nil)
        #expect(cmd(kVK_ANSI_A, "a", [.command, .shift]) == nil)
        #expect(cmd(kVK_ANSI_C, "c", .command) == nil)
    }

    @Test func hintsIncludeExamplesAndCustomTypes() {
        let plain = SearchHints.examples(customTypes: [], tags: [])
        #expect(plain.first == "Search everything…")
        #expect(plain.contains("Try  type:image"))
        #expect(plain.contains("Try  tag:design"))
        let custom = SearchHints.examples(customTypes: ["Gift Ideas"], tags: ["vps"])
        #expect(custom.contains("Try  type:\"Gift Ideas\""))
        #expect(custom.contains("Try  tag:vps"))
    }
}
