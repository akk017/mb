import Foundation
import Observation

public enum Hotkey: String, CaseIterable, Sendable {
    /// ⌘⇧Space
    case toggleDropBox
    /// ⌘⇧B
    case toggleLibrary
}

/// Registers global hotkeys. Real implementations: KeyboardShortcuts (Xcode
/// builds) or Carbon `RegisterEventHotKey` (CLT builds). Tests use a fake.
@MainActor
public protocol HotkeyRegistering: AnyObject {
    func register(_ hotkey: Hotkey, handler: @escaping @MainActor () -> Void)
    /// Binds (or clears) the key combo. Returns false if the system refuses
    /// it, e.g. another app already owns that shortcut.
    @discardableResult func setCombo(_ combo: KeyCombo?, for hotkey: Hotkey) -> Bool
    /// False when the registrar records shortcuts itself (KeyboardShortcuts).
    var supportsCustomCombos: Bool { get }
    /// Temporarily disables all shortcuts (while recording a new one).
    func setPaused(_ paused: Bool)
    func unregisterAll()
}

/// Shows/hides the actual windows. Implemented by the app delegate.
@MainActor
public protocol WindowPresenting: AnyObject {
    func setDropBoxVisible(_ visible: Bool)
    /// Shows the drop box near the cursor for an in-progress drag.
    func showDropBoxForDrag()
    func setLibraryVisible(_ visible: Bool)
    /// False when the drop box is up but on another Space (or display) than
    /// the one the user is looking at.
    var isDropBoxOnActiveSpace: Bool { get }
}

public extension WindowPresenting {
    var isDropBoxOnActiveSpace: Bool { true }
}

/// Top-level UI state shared by the menu bar, hotkeys, and windows.
@MainActor
@Observable
public final class AppState {
    public private(set) var isDropBoxVisible = false
    public private(set) var isLibraryVisible = false
    /// True while the drop box is up only because a drag started (auto-hides).
    public private(set) var isDropBoxShownByDrag = false
    @ObservationIgnored public weak var presenter: (any WindowPresenting)?

    public init() {}

    /// Wires both hotkeys to their toggles and binds their key combos.
    public func bindHotkeys(_ registrar: any HotkeyRegistering, combos: (Hotkey) -> KeyCombo? = KeyCombo.defaultCombo) {
        for hotkey in Hotkey.allCases {
            registrar.register(hotkey) { [weak self] in self?.handle(hotkey) }
            registrar.setCombo(combos(hotkey), for: hotkey)
        }
    }

    public func handle(_ hotkey: Hotkey) {
        switch hotkey {
        case .toggleDropBox:
            // Hotkey while drag-shown pins it open instead of closing it.
            if isDropBoxShownByDrag { isDropBoxShownByDrag = false; return }
            // Open on another Space: bring it here instead of hiding it.
            if isDropBoxVisible, presenter?.isDropBoxOnActiveSpace == false {
                presenter?.setDropBoxVisible(true)
                return
            }
            setDropBoxVisible(!isDropBoxVisible)
        case .toggleLibrary: setLibraryVisible(!isLibraryVisible)
        }
    }

    /// Shows the drop box for a drag in progress (auto-hidden afterwards).
    public func showDropBoxForDrag() {
        guard !isDropBoxVisible else { return }
        isDropBoxShownByDrag = true
        isDropBoxVisible = true
        presenter?.showDropBoxForDrag()
    }

    public func setDropBoxVisible(_ visible: Bool) {
        if !visible { isDropBoxShownByDrag = false }
        guard visible != isDropBoxVisible else { return }
        isDropBoxVisible = visible
        presenter?.setDropBoxVisible(visible)
    }

    public func setLibraryVisible(_ visible: Bool) {
        guard visible != isLibraryVisible else { return }
        isLibraryVisible = visible
        presenter?.setLibraryVisible(visible)
    }
}
