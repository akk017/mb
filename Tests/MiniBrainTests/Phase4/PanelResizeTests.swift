import AppKit
import SwiftUI
import Testing
@testable import MiniBrainCore
@testable import MiniBrainUI

@Suite struct PanelResizeTests {
    @Test(arguments: [496.89453125, 360.4, 512.5, 700.0001])
    func panelWidthIsAlwaysWholePoints(saved: Double) {
        // Fractional widths make SwiftUI and AppKit's pixel alignment fight
        // over the last fraction, re-laying out forever (app froze).
        for window in [1320.0, 1512.0, 1511.5, 1000.25] {
            let w = DetailPanelWidth.clamp(saved, windowWidth: window)
            #expect(w == w.rounded(), "\(saved) in \(window) → \(w)")
        }
    }

    @Test func windowWidthChangeIgnoresSubPointJitter() {
        #expect(!PanelLayout.isMeaningfulWidthChange(from: 1512, to: 1511.6))
        #expect(!PanelLayout.isMeaningfulWidthChange(from: 1512, to: 1512.4))
        #expect(PanelLayout.isMeaningfulWidthChange(from: 1512, to: 1511))
        #expect(PanelLayout.isMeaningfulWidthChange(from: 1320, to: 1512))
    }

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

@Suite @MainActor struct ResizeHandleMouseTests {
    func mouse(_ type: NSEvent.EventType, at p: NSPoint, in window: NSWindow, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    @Test func dragKeepsTrackingWhenPointerLeavesHandle() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let handle = ResizeHandleView.HandleNSView(frame: NSRect(x: 400, y: 0, width: 11, height: 400))
        window.contentView?.addSubview(handle)
        var widths: [Double] = []
        var ended = 0, resets = 0
        handle.currentWidth = { 460 }
        handle.onDrag = { widths.append($0) }
        handle.onEnd = { ended += 1 }
        handle.onReset = { resets += 1 }

        handle.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: 405, y: 200), in: window))
        #expect(handle.isDragging)
        // Pointer races far left of the 11pt handle — drag must keep tracking.
        for x in stride(from: 395, through: 105, by: -10) {
            handle.mouseDragged(with: mouse(.leftMouseDragged, at: NSPoint(x: CGFloat(x), y: 200), in: window))
        }
        handle.mouseUp(with: mouse(.leftMouseUp, at: NSPoint(x: 105, y: 200), in: window))
        #expect(!handle.isDragging)
        #expect(widths.first == 470)   // 10pt left → 10pt wider
        #expect(widths.last == 760)    // 300pt left → 300pt wider (container clamps)
        #expect(ended == 1)

        handle.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: 405, y: 200), in: window, clicks: 2))
        #expect(resets == 1)
        #expect(!handle.isDragging)    // double-click doesn't start a drag
    }

    @Test func libraryPersistsWidthFromRealMouseDrag() async throws {
        let env = try TestEnv()
        let item = try env.makeItem(title: "Resize me")
        let lib = LibraryViewModel(search: SearchService(database: env.db), repository: env.repo, clock: env.clock)
        await lib.performSearch()
        lib.select(item.id)
        let actions = ItemActions(workspace: FakeWorkspace(), pasteboard: FakePasteboardWriter(), blobs: env.blobs, repository: env.repo)
        let d = makeDefaults()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1500, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: LibraryView(model: lib, actions: actions).defaultAppStorage(d))
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        spinPerf(0.4)

        let handle = try #require(Self.find(ResizeHandleView.HandleNSView.self, in: window.contentView!))
        let start = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        handle.mouseDown(with: mouse(.leftMouseDown, at: start, in: window))
        for step in 1...12 {
            handle.mouseDragged(with: mouse(.leftMouseDragged, at: NSPoint(x: start.x - CGFloat(step * 10), y: start.y), in: window))
            spinPerf(0.01)
        }
        handle.mouseUp(with: mouse(.leftMouseUp, at: NSPoint(x: start.x - 120, y: start.y), in: window))
        spinPerf(0.1)
        #expect(d.double(forKey: DetailPanelWidth.defaultsKey) == 580) // 460 + 120, saved on release
        window.orderOut(nil)
    }

    static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let v = view as? T { return v }
        for sub in view.subviews { if let found = find(type, in: sub) { return found } }
        return nil
    }
}
