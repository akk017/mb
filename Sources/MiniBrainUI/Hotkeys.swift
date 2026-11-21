import AppKit
import Carbon.HIToolbox

#if canImport(KeyboardShortcuts)
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleDropBox = Self("toggleDropBox", default: .init(.space, modifiers: [.command, .shift]))
    static let toggleLibrary = Self("toggleLibrary", default: .init(.b, modifiers: [.command, .shift]))
}

extension Hotkey {
    var shortcutName: KeyboardShortcuts.Name {
        switch self {
        case .toggleDropBox: .toggleDropBox
        case .toggleLibrary: .toggleLibrary
        }
    }
}

/// KeyboardShortcuts-backed registrar; its Recorder stores shortcuts itself.
@MainActor
public final class KeyboardShortcutsRegistrar: HotkeyRegistering {
    public init() {}

    public var supportsCustomCombos: Bool { false }

    public func register(_ hotkey: Hotkey, handler: @escaping @MainActor () -> Void) {
        KeyboardShortcuts.onKeyUp(for: hotkey.shortcutName) { handler() }
    }

    public func setCombo(_ combo: KeyCombo?, for hotkey: Hotkey) -> Bool { true }

    public func setPaused(_ paused: Bool) {
        let names = Hotkey.allCases.map(\.shortcutName)
        if paused { KeyboardShortcuts.disable(names) } else { KeyboardShortcuts.enable(names) }
    }

    public func unregisterAll() {
        KeyboardShortcuts.disable(Hotkey.allCases.map(\.shortcutName))
    }
}
#endif

/// Carbon `RegisterEventHotKey` registrar with user-configurable combos.
@MainActor
public final class CarbonHotkeyRegistrar: HotkeyRegistering {
    private var refs: [Hotkey: EventHotKeyRef] = [:]
    private var combos: [Hotkey: KeyCombo] = [:]
    private var handlerRef: EventHandlerRef?
    private var paused = false
    fileprivate var handlers: [UInt32: @MainActor () -> Void] = [:]
    fileprivate static weak var shared: CarbonHotkeyRegistrar?

    public init() {}

    public var supportsCustomCombos: Bool { true }

    static func id(for hotkey: Hotkey) -> UInt32 { UInt32(Hotkey.allCases.firstIndex(of: hotkey)! + 1) }

    public func register(_ hotkey: Hotkey, handler: @escaping @MainActor () -> Void) {
        installHandlerIfNeeded()
        handlers[Self.id(for: hotkey)] = handler
    }

    public func setCombo(_ combo: KeyCombo?, for hotkey: Hotkey) -> Bool {
        unregisterRef(hotkey)
        combos[hotkey] = combo
        guard let combo, !paused else { return true }
        return registerRef(hotkey, combo)
    }

    public func setPaused(_ paused: Bool) {
        guard paused != self.paused else { return }
        self.paused = paused
        for hotkey in Hotkey.allCases {
            unregisterRef(hotkey)
            if !paused, let combo = combos[hotkey] { _ = registerRef(hotkey, combo) }
        }
    }

    public func unregisterAll() {
        for hotkey in Hotkey.allCases { unregisterRef(hotkey) }
        combos.removeAll()
        handlers.removeAll()
    }

    private func registerRef(_ hotkey: Hotkey, _ combo: KeyCombo) -> Bool {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D424B59) /* 'MBKY' */, id: Self.id(for: hotkey))
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[hotkey] = ref
        return true
    }

    private func unregisterRef(_ hotkey: Hotkey) {
        if let ref = refs.removeValue(forKey: hotkey) { UnregisterEventHotKey(ref) }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        Self.shared = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), carbonHotkeyCallback, 1, &spec, nil, &handlerRef)
    }
}

private func carbonHotkeyCallback(
    _ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr else { return status }
    let id = hotKeyID.id
    MainActor.assumeIsolated {
        CarbonHotkeyRegistrar.shared?.handlers[id]?()
    }
    return noErr
}

@MainActor
public enum HotkeyRegistrarFactory {
    public static func make() -> any HotkeyRegistering {
        #if canImport(KeyboardShortcuts)
        KeyboardShortcutsRegistrar()
        #else
        CarbonHotkeyRegistrar()
        #endif
    }
}
