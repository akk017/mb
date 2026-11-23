import AppKit
import SwiftUI
import Testing
@testable import MiniBrainUI

/// Drop box follows you to the current Space and stays on top.
@Suite @MainActor struct DropBoxSpacesTests {
    @Test func panelJoinsEverySpaceAndFloatsAboveApps() {
        let panel = DropBoxPanel(content: Text("x"))
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(!panel.collectionBehavior.contains(.moveToActiveSpace))
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.level.rawValue >= NSWindow.Level.statusBar.rawValue)
        #expect(!panel.hidesOnDeactivate)
    }

    @Test func showReassertsSpaceBehavior() {
        let panel = DropBoxPanel(content: Text("x"))
        panel.collectionBehavior = []
        panel.level = .normal
        panel.show(at: .center, takeFocus: false)
        defer { panel.orderOut(nil) }
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.level.rawValue >= NSWindow.Level.statusBar.rawValue)
        #expect(panel.isVisible)
    }

    @Test func hotkeyBringsBoxHereWhenItIsOpenOnAnotherSpace() {
        let presenter = SpacePresenter()
        let state = AppState()
        state.presenter = presenter
        state.handle(.toggleDropBox)
        #expect(presenter.calls == ["dropBox:true"])

        presenter.onActiveSpace = false            // user switched Space
        state.handle(.toggleDropBox)
        #expect(state.isDropBoxVisible)            // not hidden …
        #expect(presenter.calls == ["dropBox:true", "dropBox:true"]) // … shown here

        presenter.onActiveSpace = true
        state.handle(.toggleDropBox)
        #expect(!state.isDropBoxVisible)
        #expect(presenter.calls.last == "dropBox:false")
    }
}

@MainActor
final class SpacePresenter: WindowPresenting {
    var calls: [String] = []
    var onActiveSpace = true
    var isDropBoxOnActiveSpace: Bool { onActiveSpace }
    func setDropBoxVisible(_ visible: Bool) { calls.append("dropBox:\(visible)") }
    func showDropBoxForDrag() { calls.append("dropBox:drag") }
    func setLibraryVisible(_ visible: Bool) { calls.append("library:\(visible)") }
}
