import Foundation
import Testing
@testable import MiniBrainCore
@testable import MiniBrainUI

@Suite @MainActor struct DragWatcherTests {

    /// Querying pasteboard types is a blocking call to the pasteboard server;
    /// idle ticks (no click, or unchanged pasteboard) must not make it.
    @Test func pollerSkipsPasteboardWhileIdle() {
        var idle = 0
        var reads = 0
        for _ in 0..<70 {
            if !SystemDragMonitor.shouldSkipPasteboard(mouseDown: false, wasMouseDown: false, isDragging: false, idleTicks: &idle) { reads += 1 }
        }
        #expect(reads == 10) // ~1 s apart at 0.15 s ticks, not every tick
        // Mouse down, the release tick, and active drags always read.
        #expect(!SystemDragMonitor.shouldSkipPasteboard(mouseDown: true, wasMouseDown: false, isDragging: false, idleTicks: &idle))
        #expect(!SystemDragMonitor.shouldSkipPasteboard(mouseDown: false, wasMouseDown: true, isDragging: false, idleTicks: &idle))
        #expect(!SystemDragMonitor.shouldSkipPasteboard(mouseDown: false, wasMouseDown: false, isDragging: true, idleTicks: &idle))
    }

    @Test func idleTicksNeverQueryPasteboardTypes() {
        let w = DragWatcher(initialChangeCount: 10)
        var queries = 0
        func probe() -> Bool { queries += 1; return true }
        for _ in 0..<50 { w.sample(mouseDown: false, changeCount: 10, hasContent: probe()) }
        w.sample(mouseDown: false, changeCount: 12, hasContent: probe()) // copy elsewhere, no click
        for _ in 0..<20 { w.sample(mouseDown: true, changeCount: 12, hasContent: probe()) } // click-hold, same pasteboard
        #expect(queries == 0)
        w.sample(mouseDown: true, changeCount: 13, hasContent: probe()) // real drag start
        #expect(queries == 1)
        #expect(w.isDragging)
    }

    @Test func newDragPasteboardWhileMouseDownStartsDrag() {
        var events: [String] = []
        let w = DragWatcher(initialChangeCount: 10)
        w.onDragStart = { events.append("start") }
        w.onDragEnd = { events.append("end") }

        w.sample(mouseDown: true, changeCount: 10, hasContent: true) // plain click/hold, old pasteboard
        #expect(events.isEmpty)
        w.sample(mouseDown: true, changeCount: 11, hasContent: true) // drag began
        w.sample(mouseDown: true, changeCount: 11, hasContent: true) // still dragging
        #expect(events == ["start"])
        #expect(w.isDragging)
        w.sample(mouseDown: false, changeCount: 11, hasContent: true)
        #expect(events == ["start", "end"])
        #expect(!w.isDragging)
    }

    @Test func windowMovesAndSelectionsNeverTrigger() {
        var started = 0
        let w = DragWatcher(initialChangeCount: 3)
        w.onDragStart = { started += 1 }
        for _ in 0..<20 { w.sample(mouseDown: true, changeCount: 3, hasContent: true) }
        w.sample(mouseDown: false, changeCount: 3, hasContent: true)
        #expect(started == 0)
    }

    @Test func emptyDragPasteboardIgnored() {
        var started = 0
        let w = DragWatcher(initialChangeCount: 0)
        w.onDragStart = { started += 1 }
        w.sample(mouseDown: true, changeCount: 1, hasContent: false)
        #expect(started == 0)
    }

    @Test func eachNewDragStartsOnce() {
        var events: [String] = []
        let w = DragWatcher(initialChangeCount: 0)
        w.onDragStart = { events.append("start") }
        w.onDragEnd = { events.append("end") }
        for count in 1...3 {
            w.sample(mouseDown: true, changeCount: count, hasContent: true)
            w.sample(mouseDown: false, changeCount: count, hasContent: true)
        }
        #expect(events == ["start", "end", "start", "end", "start", "end"])
        // Pasteboard written while mouse is up (e.g. programmatic) then a click: no drag.
        w.sample(mouseDown: false, changeCount: 4, hasContent: true)
        w.sample(mouseDown: true, changeCount: 4, hasContent: true)
        #expect(events.count == 6)
    }
}

@Suite @MainActor struct DropBoxAutoShowTests {
    final class Box { var state: DropBoxViewModel.State? = .idle; var enabled = true }

    func make() -> (AppState, FakePresenter, DropBoxAutoShow, FakeClock, Box) {
        let state = AppState(), presenter = FakePresenter(), clock = FakeClock(), box = Box()
        state.presenter = presenter
        let auto = DropBoxAutoShow(appState: state, clock: clock, isEnabled: { box.enabled }, dropState: { box.state })
        return (state, presenter, auto, clock, box)
    }

    @Test func showsOnDragAndHidesAfterReleaseWithoutDrop() async {
        let (state, presenter, auto, clock, _) = make()
        auto.dragStarted()
        #expect(state.isDropBoxVisible)
        #expect(state.isDropBoxShownByDrag)
        #expect(presenter.calls == ["dropBox:drag"])
        auto.dragEnded()
        await clock.waitForSleepers()
        clock.advance(by: 0.4)
        await waitUntil { !state.isDropBoxVisible }
        #expect(!state.isDropBoxVisible)
        #expect(presenter.calls == ["dropBox:drag", "dropBox:false"])
    }

    @Test func staysWhileSavingThenShowsResultThenHides() async {
        let (state, _, auto, clock, box) = make()
        auto.dragStarted()
        box.state = .saving
        auto.dragEnded()
        await clock.waitForSleepers()
        clock.advance(by: 0.4)
        await clock.waitForSleepers()
        #expect(state.isDropBoxVisible) // still saving
        box.state = .saved(title: "x")
        clock.advance(by: 0.4)
        await clock.waitForSleepers()
        #expect(state.isDropBoxVisible) // showing "Saved"
        clock.advance(by: 1.2)
        await waitUntil { !state.isDropBoxVisible }
        #expect(!state.isDropBoxVisible)
    }

    @Test func newDragCancelsPendingHide() async {
        let (state, _, auto, clock, _) = make()
        auto.dragStarted()
        auto.dragEnded()
        await clock.waitForSleepers()
        auto.dragStarted() // second drag before hide fires
        clock.advance(by: 1)
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(state.isDropBoxVisible)
    }

    @Test func hotkeyPinsDragShownBox() async {
        let (state, _, auto, clock, _) = make()
        auto.dragStarted()
        state.handle(.toggleDropBox) // pin instead of close
        #expect(state.isDropBoxVisible)
        #expect(!state.isDropBoxShownByDrag)
        auto.dragEnded()
        clock.advance(by: 5)
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(state.isDropBoxVisible)
        state.handle(.toggleDropBox) // now closes normally
        #expect(!state.isDropBoxVisible)
    }

    @Test func alreadyOpenOrDisabledDoesNothing() {
        let (state, presenter, auto, _, box) = make()
        box.enabled = false
        auto.dragStarted()
        #expect(!state.isDropBoxVisible)
        box.enabled = true
        state.setDropBoxVisible(true) // opened via hotkey
        auto.dragStarted()
        auto.dragEnded()
        #expect(!state.isDropBoxShownByDrag)
        #expect(presenter.calls == ["dropBox:true"])
    }
}
