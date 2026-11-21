import AppKit
import SwiftUI
import Testing
@testable import MiniBrainCore
@testable import MiniBrainUI

@MainActor func spinPerf(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

/// Dragging the detail-panel edge must stay within a 60 Hz frame budget with
/// a full library (layout + draw per drag step).
@Suite @MainActor struct PanelResizePerformanceTests {
    @Test(.tags(.performance)) func dragFramesStayWithinBudget() async throws {
        let env = try TestEnv()
        let capture = CaptureService(database: env.db, blobs: env.blobs, clock: env.clock, enabledKinds: [])
        let png = try Fixtures.data("two-color.png")
        var first: Item?
        for i in 0..<200 {
            let item = try capture.capture(CapturePayload(url: URL(string: "https://site\(i).example.com/page")!,
                                                         imageData: png + Data("\(i)".utf8), suggestedName: "Item \(i)"))
            for t in ["design", "frontend", "inspiration", "dev", "ui", "backend"] { try env.repo.attachTag(t, to: item.id) }
            first = first ?? item
        }
        let lib = LibraryViewModel(search: SearchService(database: env.db), repository: env.repo, clock: env.clock)
        await lib.performSearch()
        lib.select(first!.id)
        let actions = ItemActions(workspace: FakeWorkspace(), pasteboard: FakePasteboardWriter(), blobs: env.blobs, repository: env.repo)
        let layout = PanelLayout()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1500, height: 900), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        let host = NSHostingView(rootView: LibraryView(model: lib, actions: actions, layout: layout).defaultAppStorage(makeDefaults()))
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded(); host.display()
        spinPerf(0.5)

        var frames: [Double] = []
        for step in 0..<60 {
            let t0 = CFAbsoluteTimeGetCurrent()
            layout.liveWidth = 460 + Double(step % 30) * 8
            host.layoutSubtreeIfNeeded()
            host.display()
            frames.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
        window.orderOut(nil)
        frames.sort()
        let median = frames[frames.count / 2], p90 = frames[Int(Double(frames.count) * 0.9)]
        #expect(median < 8, "median frame \(median) ms")
        #expect(p90 < 25, "p90 frame \(p90) ms")
    }
}
