import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Library-wide selection keys: ⌘A, Esc, ⌘⌫. They never fire while a text
/// field is being edited (search, tags, inline properties) — those keys
/// belong to the text there.
enum LibraryKeyCommand: Equatable {
    case selectAll, clearSelection, trashSelection

    static func command(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags,
                        isEditingText: Bool) -> LibraryKeyCommand? {
        guard !isEditingText else { return nil }
        let mods = modifiers.intersection([.command, .option, .control, .shift])
        if mods == .command, characters?.lowercased() == "a" { return .selectAll }
        if mods.isEmpty, Int(keyCode) == kVK_Escape { return .clearSelection }
        // ⌘⌫ moves to Trash (as in Finder). Plain ⌫ never deletes items.
        if mods == .command, Int(keyCode) == kVK_Delete || Int(keyCode) == kVK_ForwardDelete { return .trashSelection }
        return nil
    }
}

/// Installs a key monitor for the hosting window only.
struct LibraryKeyHandler: NSViewRepresentable {
    let perform: (LibraryKeyCommand) -> Bool

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.perform = perform
        return view
    }

    func updateNSView(_ view: KeyView, context: Context) { view.perform = perform }

    final class KeyView: NSView {
        var perform: ((LibraryKeyCommand) -> Bool)?
        private var monitor: Any?
        private var clickMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor); self.clickMonitor = nil }
            guard window != nil else { return }
            // Clicking anywhere that isn't a text input ends text editing
            // (so the search box doesn't keep focus forever).
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let window = self?.window, event.window === window,
                      let editor = window.firstResponder as? NSTextView, editor.isEditable,
                      let content = window.contentView else { return event }
                let point = event.locationInWindow
                if !FocusRules.keepsFocus(at: point, in: content) {
                    window.makeFirstResponder(nil)
                }
                return event
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let editing = (window.firstResponder as? NSTextView)?.isEditable == true
                guard let command = LibraryKeyCommand.command(
                    keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
                    modifiers: event.modifierFlags, isEditingText: editing),
                    self.perform?(command) == true
                else { return event }
                return nil
            }
        }

        isolated deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        }
    }
}

/// Rotating example queries for the empty search box.
enum SearchHints {
    static func examples(customTypes: [String], tags: [String]) -> [String] {
        var hints = ["Search everything…", "Try  type:image", "Try  tag:\(tags.first ?? "design")",
                     "Try  color:red", "Try  “exact phrase”", "Try  after:2025-01-01", "Try  meta.price<100"]
        if let type = customTypes.first {
            hints.insert("Try  type:\(type.contains(" ") ? "\"\(type)\"" : type)", at: 2)
        }
        return hints
    }
}

/// Decides whether a click should leave the current text field focused.
@MainActor
enum FocusRules {
    /// True when the click lands on a text input or a region marked with
    /// `.keepsTextFocus()` (e.g. the search autocomplete list).
    static func keepsFocus(at windowPoint: NSPoint, in content: NSView) -> Bool {
        if let hit = content.hitTest(content.convert(windowPoint, from: nil)), isTextInput(hit) { return true }
        return keepRegions(in: content).contains { view in
            view.convert(view.bounds, to: nil).contains(windowPoint)
        }
    }

    static func isTextInput(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let v = current {
            if v is NSTextView || v is NSTextField { return true }
            current = v.superview
        }
        return false
    }

    static func keepRegions(in view: NSView) -> [KeepFocusMarker.MarkerView] {
        var found: [KeepFocusMarker.MarkerView] = []
        for sub in view.subviews {
            if let m = sub as? KeepFocusMarker.MarkerView { found.append(m) }
            found += keepRegions(in: sub)
        }
        return found
    }
}

/// Invisible marker: clicks inside keep the text field focused.
struct KeepFocusMarker: NSViewRepresentable {
    final class MarkerView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil } // never steals clicks
    }
    func makeNSView(context: Context) -> MarkerView { MarkerView() }
    func updateNSView(_ nsView: MarkerView, context: Context) {}
}

extension View {
    func keepsTextFocus() -> some View { background(KeepFocusMarker()) }
}
