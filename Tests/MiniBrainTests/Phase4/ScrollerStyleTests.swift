import AppKit
import SwiftUI
import Testing
@testable import MiniBrainCore
@testable import MiniBrainUI

/// With "Show scroll bars: Always", legacy scrollers take width and auto-hide
/// when content fits. Content whose height depends on width can then flip the
/// scroller on/off every layout pass — the app froze ("Not Responding").
/// Library scroll views must use overlay scrollers, which take no width.
@Suite(.serialized) @MainActor struct ScrollerStyleTests {
    func scrollViews(in view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        if let s = view as? NSScrollView, !(s.documentView is NSTextView) { found.append(s) }
        for sub in view.subviews { found += scrollViews(in: sub) }
        return found
    }

    @Test func libraryScrollViewsUseOverlayScrollersEvenWhenSystemSaysAlways() async throws {
        let previous = UserDefaults.standard.object(forKey: "AppleShowScrollBars")
        UserDefaults.standard.set("Always", forKey: "AppleShowScrollBars")
        defer { UserDefaults.standard.set(previous, forKey: "AppleShowScrollBars") }

        let env = try TestEnv()
        let capture = CaptureService(database: env.db, blobs: env.blobs, clock: env.clock, enabledKinds: [])
        let png = try Fixtures.data("two-color.png")
        var first: Item?
        for i in 0..<30 {
            let item = try capture.capture(CapturePayload(imageData: png + Data("\(i)".utf8), suggestedName: "Item \(i)"))
            first = first ?? item
        }
        let lib = LibraryViewModel(search: SearchService(database: env.db), repository: env.repo, clock: env.clock)
        await lib.performSearch()
        lib.select(first!.id)
        let actions = ItemActions(workspace: FakeWorkspace(), pasteboard: FakePasteboardWriter(), blobs: env.blobs, repository: env.repo)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 700), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        let host = NSHostingView(rootView: LibraryView(model: lib, actions: actions, layout: PanelLayout()).defaultAppStorage(makeDefaults()))
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        spinPerf(0.4)

        let views = scrollViews(in: host)
        #expect(views.count >= 3) // sidebar, gallery, detail panel
        #expect(views.allSatisfy { $0.scrollerStyle == .overlay }, "\(views.map(\.scrollerStyle.rawValue))")

        // AppKit resets styles when the system setting changes; we re-apply.
        let vertical = views.filter(\.hasVerticalScroller) // gallery + panel (sidebar hides its bar, tag rows are horizontal)
        #expect(vertical.count >= 2)
        for v in vertical { v.scrollerStyle = .legacy } // what AppKit does on that notification
        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        spinPerf(0.2)
        #expect(vertical.allSatisfy { $0.scrollerStyle == .overlay }, "\(vertical.map(\.scrollerStyle.rawValue))")
    }
}
