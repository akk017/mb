import AppKit
import SwiftUI
import Testing
@testable import MiniBrainCore
@testable import MiniBrainUI

@Suite struct PanelResizeTests {
    @Test func clampKeepsPanelAndGalleryUsable() {
        let window: Double = 1400 // room for panel: 1400 - 249 - 420 - 1 = 730
        #expect(DetailPanelWidth.clamp(460, windowWidth: window) == 460)
        #expect(DetailPanelWidth.clamp(200, windowWidth: window) == DetailPanelWidth.minimum)
        #expect(DetailPanelWidth.clamp(2000, windowWidth: window) == 730)
        // Tiny window: never below the panel minimum.
        #expect(DetailPanelWidth.clamp(500, windowWidth: 900) == DetailPanelWidth.minimum)
    }

    @Test @MainActor func savedWidthIsRestoredOnOpen() async throws {
        let env = try TestEnv()
        let item = try env.makeItem(title: "Wide panel")
        let lib = LibraryViewModel(search: SearchService(database: env.db), repository: env.repo, clock: env.clock)
        await lib.performSearch()
        lib.select(item.id)
        let actions = ItemActions(workspace: FakeWorkspace(), pasteboard: FakePasteboardWriter(), blobs: env.blobs, repository: env.repo)

        func panelWidth(stored: Double?) -> CGFloat {
            let d = makeDefaults()
            if let stored { d.set(stored, forKey: DetailPanelWidth.defaultsKey) }
            let host = NSHostingView(rootView: LibraryView(model: lib, actions: actions).defaultAppStorage(d))
            host.frame = NSRect(x: 0, y: 0, width: 1500, height: 800)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            host.layoutSubtreeIfNeeded()
            // Find the panel's trailing content: measure via the hosting view's
            // subview whose frame touches the right edge and is the widest such.
            return host.fittingSize.width > 0 ? Self.rightPanelWidth(in: host) : 0
        }
        let standard = panelWidth(stored: nil)
        let wide = panelWidth(stored: 640)
        #expect(abs(wide - standard - 180) < 2, "standard \(standard), restored \(wide)")
    }

    /// Width of the region right of the panel's leading divider, found by
    /// scanning a rendered row of pixels for the divider/panel color change.
    @MainActor static func rightPanelWidth(in host: NSHostingView<some View>) -> CGFloat {
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        let y = Int(rep.pixelsHigh / 2)
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        // Panel background differs from gallery background; find last change point.
        func color(_ x: Int) -> NSColor { rep.colorAt(x: x, y: y) ?? .clear }
        let panel = color(rep.pixelsWide - 5)
        var x = rep.pixelsWide - 5
        while x > 0, color(x).isClose(to: panel) { x -= 1 }
        return CGFloat(rep.pixelsWide - x) / scale
    }
}

private extension NSColor {
    func isClose(to other: NSColor) -> Bool {
        guard let a = usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.02 && abs(a.greenComponent - b.greenComponent) < 0.02
            && abs(a.blueComponent - b.blueComponent) < 0.02
    }
}
