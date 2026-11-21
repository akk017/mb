import AppKit
import MiniBrainCore

/// Detects system-wide drag sessions from any app (Finder, browsers, …).
///
/// Every new drag writes to the shared drag pasteboard, bumping its
/// `changeCount`. While the mouse button is down, a changed count means a drag
/// started; button up means it ended. Window moves and text selection don't
/// touch the drag pasteboard, so they never trigger.
@MainActor
public final class DragWatcher {
    public var onDragStart: (() -> Void)?
    public var onDragEnd: (() -> Void)?
    public private(set) var isDragging = false
    private var lastChangeCount: Int

    public init(initialChangeCount: Int) {
        lastChangeCount = initialChangeCount
    }

    /// Feed one sample: mouse button state + current drag pasteboard state.
    public func sample(mouseDown: Bool, changeCount: Int, hasContent: Bool) {
        if mouseDown {
            guard !isDragging, changeCount != lastChangeCount else { return }
            lastChangeCount = changeCount
            guard hasContent else { return }
            isDragging = true
            onDragStart?()
        } else {
            lastChangeCount = changeCount
            guard isDragging else { return }
            isDragging = false
            onDragEnd?()
        }
    }
}

/// Polls the drag pasteboard and mouse state (cheap; ~7 Hz). Polling works
/// even when a drag session swallows mouse events for other apps.
@MainActor
public final class SystemDragMonitor {
    public let watcher: DragWatcher
    private var timer: Timer?
    private let pasteboard = NSPasteboard(name: .drag)

    public init() {
        watcher = DragWatcher(initialChangeCount: NSPasteboard(name: .drag).changeCount)
    }

    public func start(interval: TimeInterval = 0.15) {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let mouseDown = NSEvent.pressedMouseButtons & 1 != 0
        watcher.sample(mouseDown: mouseDown, changeCount: pasteboard.changeCount,
                       hasContent: !(pasteboard.types ?? []).isEmpty)
    }
}

/// Shows the drop box when a drag starts and hides it again afterwards —
/// unless the user opened it themselves (hotkey/menu).
@MainActor
public final class DropBoxAutoShow {
    nonisolated public static let defaultsKey = "autoShowDropBoxOnDrag"

    let appState: AppState
    let clock: any MiniBrainCore.Clock
    let isEnabled: () -> Bool
    let dropState: () -> DropBoxViewModel.State?
    /// Wait after release before hiding an untouched box.
    public var idleHideDelay: TimeInterval = 0.4
    /// Keep "Saved"/error visible this long before hiding.
    public var resultHideDelay: TimeInterval = 1.2
    private var hideTask: Task<Void, Never>?
    private var resultShown = false

    public init(
        appState: AppState, clock: any MiniBrainCore.Clock = SystemClock(),
        isEnabled: @escaping () -> Bool, dropState: @escaping () -> DropBoxViewModel.State?
    ) {
        self.appState = appState
        self.clock = clock
        self.isEnabled = isEnabled
        self.dropState = dropState
    }

    public func dragStarted() {
        hideTask?.cancel()
        resultShown = false
        guard isEnabled(), !appState.isDropBoxVisible else { return }
        appState.showDropBoxForDrag()
    }

    public func dragEnded() {
        guard appState.isDropBoxShownByDrag else { return }
        scheduleHide(after: idleHideDelay)
    }

    private func scheduleHide(after delay: TimeInterval) {
        hideTask?.cancel()
        hideTask = Task { [weak self, clock] in
            do { try await clock.sleep(for: delay) } catch { return }
            self?.hideIfDone()
        }
    }

    private func hideIfDone() {
        guard appState.isDropBoxShownByDrag else { return } // user pinned it
        switch dropState() {
        case .saving?, .choosingType?, .editingFields?:
            scheduleHide(after: idleHideDelay) // still busy / waiting for the user: check again
        case .saved?, .error?:
            if resultShown {
                appState.setDropBoxVisible(false)
            } else {
                resultShown = true
                scheduleHide(after: resultHideDelay)
            }
        default:
            appState.setDropBoxVisible(false)
        }
    }
}
