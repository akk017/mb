import AppKit
import Testing
@testable import MiniBrainUI

@Suite @MainActor struct FocusRulesTests {
    @Test func clicksOnTextInputsOrKeepRegionsKeepFocus() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = content
        let field = NSTextField(frame: NSRect(x: 10, y: 250, width: 200, height: 24))
        content.addSubview(field)
        let list = KeepFocusMarker.MarkerView(frame: NSRect(x: 10, y: 120, width: 200, height: 100))
        content.addSubview(list)
        let card = NSView(frame: NSRect(x: 250, y: 20, width: 120, height: 120))
        content.addSubview(card)

        #expect(FocusRules.keepsFocus(at: NSPoint(x: 50, y: 260), in: content))   // the search field
        #expect(FocusRules.keepsFocus(at: NSPoint(x: 50, y: 150), in: content))   // autocomplete list
        #expect(!FocusRules.keepsFocus(at: NSPoint(x: 300, y: 60), in: content))  // a card
        #expect(!FocusRules.keepsFocus(at: NSPoint(x: 380, y: 290), in: content)) // empty space
    }

    @Test func markerNeverStealsClicks() {
        let marker = KeepFocusMarker.MarkerView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
        #expect(marker.hitTest(NSPoint(x: 10, y: 10)) == nil)
    }
}

@Suite @MainActor struct AppIconTests {
    @Test func menuBarIconIsTemplateSVG() {
        #expect(MenuBarIcon.isCustom, "brain-4-line.svg failed to load; menu bar would show the system brain")
        let image = MenuBarIcon.image
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 18))
        #expect(image.representations.isEmpty == false)
    }

    @Test func infoPlistAndBundleScriptUseAppIcon() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let plist = try String(contentsOf: root.appendingPathComponent("Resources/Info.plist"), encoding: .utf8)
        #expect(plist.contains("<key>CFBundleIconFile</key><string>AppIcon</string>"))
        #expect(NSImage(contentsOf: root.appendingPathComponent("Resources/AppIcon.icns")) != nil)
        let script = try String(contentsOf: root.appendingPathComponent("scripts/make-app.sh"), encoding: .utf8)
        #expect(script.contains("AppIcon.icns"))
    }
}
