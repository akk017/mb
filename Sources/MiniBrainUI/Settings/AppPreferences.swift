import AppKit
import Carbon.HIToolbox
import Foundation
import Observation
import SwiftUI

/// Where the drop box appears on screen.
public enum DropBoxPosition: String, CaseIterable, Codable, Sendable {
    case topLeft, topCenter, topRight
    case middleLeft, center, middleRight
    case bottomLeft, bottomCenter, bottomRight

    public var title: String {
        switch self {
        case .topLeft: "Top Left"
        case .topCenter: "Top Center"
        case .topRight: "Top Right"
        case .middleLeft: "Middle Left"
        case .center: "Center"
        case .middleRight: "Middle Right"
        case .bottomLeft: "Bottom Left"
        case .bottomCenter: "Bottom Center"
        case .bottomRight: "Bottom Right"
        }
    }

    /// Panel origin inside `visibleFrame` (AppKit coordinates, y up).
    public func origin(panelSize: CGSize, in visibleFrame: CGRect, margin: CGFloat = 24) -> CGPoint {
        let index = DropBoxPosition.allCases.firstIndex(of: self)!
        let column = index % 3, row = index / 3 // row 0 = top
        let x: CGFloat = switch column {
        case 0: visibleFrame.minX + margin
        case 1: visibleFrame.midX - panelSize.width / 2
        default: visibleFrame.maxX - panelSize.width - margin
        }
        let y: CGFloat = switch row {
        case 0: visibleFrame.maxY - panelSize.height - margin
        case 1: visibleFrame.midY - panelSize.height / 2
        default: visibleFrame.minY + margin
        }
        return CGPoint(x: x.rounded(), y: y.rounded())
    }
}

public enum DockMode: String, CaseIterable, Sendable {
    case always, whileWindowsOpen, never

    public var title: String {
        switch self {
        case .always: "Always"
        case .whileWindowsOpen: "While a window is open"
        case .never: "Never (menu bar only)"
        }
    }

    /// Whether the Dock icon should show given open windows.
    public func showsInDock(windowOpen: Bool) -> Bool {
        switch self {
        case .always: true
        case .whileWindowsOpen: windowOpen
        case .never: false
        }
    }
}

/// A global shortcut: virtual key code + modifiers.
public struct KeyCombo: Codable, Equatable, Hashable, Sendable {
    public var keyCode: UInt32
    /// Raw `NSEvent.ModifierFlags`, limited to ⌃⌥⇧⌘.
    public var modifiers: UInt

    public static let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    public init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.relevantModifiers).rawValue
    }

    public var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    public var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if modifierFlags.contains(.command) { m |= UInt32(cmdKey) }
        if modifierFlags.contains(.shift) { m |= UInt32(shiftKey) }
        if modifierFlags.contains(.option) { m |= UInt32(optionKey) }
        if modifierFlags.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    public static func defaultCombo(for hotkey: Hotkey) -> KeyCombo {
        switch hotkey {
        case .toggleDropBox: KeyCombo(keyCode: UInt32(kVK_Space), modifiers: [.command, .shift])
        case .toggleLibrary: KeyCombo(keyCode: UInt32(kVK_ANSI_B), modifiers: [.command, .shift])
        }
    }

    static let functionKeys: [UInt32: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
    ]

    static let keyNames: [UInt32: String] = [
        49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 53: "⎋", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q",
        13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I",
        35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M",
        47: ".", 50: "`",
    ]

    public var isFunctionKey: Bool { Self.functionKeys[keyCode] != nil }

    /// Function-key code → NSMenu private-use character (NSF1FunctionKey …).
    static let functionKeyCharacters: [UInt32: UInt32] = [
        122: 0xF704, 120: 0xF705, 99: 0xF706, 118: 0xF707, 96: 0xF708, 97: 0xF709, 98: 0xF70A, 100: 0xF70B,
        101: 0xF70C, 109: 0xF70D, 103: 0xF70E, 111: 0xF70F, 105: 0xF710, 107: 0xF711, 113: 0xF712,
    ]

    /// The character a menu item shows for this key (nil if unknown).
    public var keyEquivalentCharacter: Character? {
        if let fn = Self.functionKeyCharacters[keyCode], let scalar = Unicode.Scalar(fn) { return Character(scalar) }
        switch Int(keyCode) {
        case kVK_Space: return " "
        case kVK_Return: return "\r"
        case kVK_Tab: return "\t"
        case kVK_Escape: return "\u{1B}"
        case kVK_Delete: return "\u{8}"
        case kVK_ForwardDelete: return "\u{7F}"
        case kVK_LeftArrow: return "\u{F702}"
        case kVK_RightArrow: return "\u{F703}"
        case kVK_DownArrow: return "\u{F701}"
        case kVK_UpArrow: return "\u{F700}"
        default:
            guard let name = Self.keyNames[keyCode], name.count == 1 else { return nil }
            return Character(name.lowercased())
        }
    }

    /// SwiftUI equivalent for showing the shortcut on a menu item.
    public var swiftUIShortcut: KeyboardShortcut? {
        guard let char = keyEquivalentCharacter else { return nil }
        var mods: SwiftUI.EventModifiers = []
        if modifierFlags.contains(.command) { mods.insert(.command) }
        if modifierFlags.contains(.shift) { mods.insert(.shift) }
        if modifierFlags.contains(.option) { mods.insert(.option) }
        if modifierFlags.contains(.control) { mods.insert(.control) }
        return KeyboardShortcut(KeyEquivalent(char), modifiers: mods)
    }

    public var keyName: String { Self.functionKeys[keyCode] ?? Self.keyNames[keyCode] ?? "Key \(keyCode)" }

    public var displayString: String {
        var s = ""
        if modifierFlags.contains(.control) { s += "⌃" }
        if modifierFlags.contains(.option) { s += "⌥" }
        if modifierFlags.contains(.shift) { s += "⇧" }
        if modifierFlags.contains(.command) { s += "⌘" }
        return s + keyName
    }

    /// Global shortcuts need ⌘, ⌥ or ⌃ (or a function key) so typing isn't hijacked.
    public var isValidGlobalShortcut: Bool {
        isFunctionKey || !modifierFlags.intersection([.command, .option, .control]).isEmpty
    }
}

/// User settings, persisted in UserDefaults (suite injectable for tests).
@MainActor
@Observable
public final class AppPreferences {
    public enum Keys {
        public static let dropBoxPosition = "dropBoxPosition"
        public static let autoShowOnDrag = "autoShowDropBoxOnDrag"
        public static let libraryPath = "libraryPath"
        public static let ocrEnabled = "ocrEnabled"
        public static let showRecognizedText = "showRecognizedText"
        public static let linkPreviews = "linkPreviews"
        public static let autoTag = "autoTag"
        public static let optimizeImages = "optimizeImages"
        public static let appearance = "appearance"
        public static let accentColor = "accentColor"
        public static let dockMode = "dockMode"
        public static let localAPIEnabled = "localAPI.enabled"
        public static let localAPIPort = "localAPI.port"
        public static let excludedApps = "dropBox.excludedApps"
        public static let exclusionRule = "dropBox.exclusionRule"
        public static func shortcut(_ hotkey: Hotkey) -> String { "shortcut.\(hotkey.rawValue)" }
    }

    @ObservationIgnored let defaults: UserDefaults

    public var dropBoxPosition: DropBoxPosition {
        didSet { defaults.set(dropBoxPosition.rawValue, forKey: Keys.dropBoxPosition) }
    }
    public var autoShowOnDrag: Bool {
        didSet { defaults.set(autoShowOnDrag, forKey: Keys.autoShowOnDrag) }
    }
    /// Recognize text in images (OCR) for search.
    public var ocrEnabled: Bool {
        didSet { defaults.set(ocrEnabled, forKey: Keys.ocrEnabled) }
    }
    /// Show OCR text on image cards / in the item panel.
    public var showRecognizedText: Bool {
        didSet { defaults.set(showRecognizedText, forKey: Keys.showRecognizedText) }
    }
    /// Fetch preview images/titles for saved links (uses the internet).
    public var linkPreviews: Bool {
        didSet { defaults.set(linkPreviews, forKey: Keys.linkPreviews) }
    }
    /// Run AI tagging (text + image) on every new drop.
    public var autoTag: Bool {
        didSet { defaults.set(autoTag, forKey: Keys.autoTag) }
    }
    /// Store images as WebP when smaller.
    public var optimizeImages: Bool {
        didSet { defaults.set(optimizeImages, forKey: Keys.optimizeImages) }
    }
    /// System / Light / Dark.
    public var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }
    /// Accent color choice.
    public var accentColor: AccentChoice {
        didSet {
            defaults.set(accentColor.rawValue, forKey: Keys.accentColor)
            Theme.accentChoice = accentColor
        }
    }
    /// When MiniBrain shows an icon in the Dock.
    public var dockMode: DockMode {
        didSet { defaults.set(dockMode.rawValue, forKey: Keys.dockMode) }
    }
    /// Local HTTP API for scripts (127.0.0.1 only). Off by default.
    public var localAPIEnabled: Bool {
        didSet { defaults.set(localAPIEnabled, forKey: Keys.localAPIEnabled) }
    }
    public var localAPIPort: Int {
        didSet { defaults.set(localAPIPort, forKey: Keys.localAPIPort) }
    }
    public static let defaultLocalAPIPort = 7777
    /// Apps during which dragging doesn't pop up the drop box.
    public private(set) var excludedApps: [ExcludedApp] = [] {
        didSet { defaults.set((try? JSONEncoder().encode(excludedApps)) ?? Data(), forKey: Keys.excludedApps) }
    }
    public var exclusionRule: ExclusionRule {
        didSet { defaults.set(exclusionRule.rawValue, forKey: Keys.exclusionRule) }
    }
    public var dropExclusions: DropExclusions { DropExclusions(apps: excludedApps, rule: exclusionRule) }

    public func addExcludedApp(_ app: ExcludedApp) {
        guard !excludedApps.contains(where: { $0.id == app.id }) else { return }
        excludedApps.append(app)
    }

    public func removeExcludedApp(_ bundleID: String) {
        excludedApps.removeAll { $0.id == bundleID.lowercased() }
    }
    /// nil = default Application Support location.
    public var libraryPath: String? {
        didSet { defaults.set(libraryPath, forKey: Keys.libraryPath) }
    }
    /// Missing entry = shortcut cleared by the user.
    public private(set) var shortcuts: [Hotkey: KeyCombo] = [:]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        dropBoxPosition = defaults.string(forKey: Keys.dropBoxPosition).flatMap(DropBoxPosition.init(rawValue:)) ?? .topRight
        autoShowOnDrag = defaults.object(forKey: Keys.autoShowOnDrag) as? Bool ?? true
        libraryPath = defaults.string(forKey: Keys.libraryPath)
        ocrEnabled = defaults.object(forKey: Keys.ocrEnabled) as? Bool ?? true
        showRecognizedText = defaults.object(forKey: Keys.showRecognizedText) as? Bool ?? false
        linkPreviews = defaults.object(forKey: Keys.linkPreviews) as? Bool ?? true
        autoTag = defaults.object(forKey: Keys.autoTag) as? Bool ?? true
        optimizeImages = defaults.object(forKey: Keys.optimizeImages) as? Bool ?? true
        appearance = defaults.string(forKey: Keys.appearance).flatMap(AppAppearance.init(rawValue:)) ?? .system
        accentColor = defaults.string(forKey: Keys.accentColor).flatMap(AccentChoice.init(rawValue:)) ?? .jsonDefault
        dockMode = defaults.string(forKey: Keys.dockMode).flatMap(DockMode.init(rawValue:)) ?? .always
        localAPIEnabled = defaults.object(forKey: Keys.localAPIEnabled) as? Bool ?? false
        let savedPort = defaults.integer(forKey: Keys.localAPIPort)
        localAPIPort = (1024...65535).contains(savedPort) ? savedPort : Self.defaultLocalAPIPort
        exclusionRule = defaults.string(forKey: Keys.exclusionRule).flatMap(ExclusionRule.init(rawValue:)) ?? .frontmost
        excludedApps = defaults.data(forKey: Keys.excludedApps).flatMap { try? JSONDecoder().decode([ExcludedApp].self, from: $0) } ?? []
        for hotkey in Hotkey.allCases {
            let key = Keys.shortcut(hotkey)
            if defaults.object(forKey: key) == nil {
                shortcuts[hotkey] = KeyCombo.defaultCombo(for: hotkey)
            } else if let data = defaults.data(forKey: key), let combo = try? JSONDecoder().decode(KeyCombo.self, from: data) {
                shortcuts[hotkey] = combo
            } // else: cleared (stored as empty data)
        }
    }

    public func shortcut(for hotkey: Hotkey) -> KeyCombo? { shortcuts[hotkey] }

    public func setShortcut(_ combo: KeyCombo?, for hotkey: Hotkey) {
        shortcuts[hotkey] = combo
        let data = combo.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        defaults.set(data, forKey: Keys.shortcut(hotkey))
    }

    public func resetShortcuts() {
        for hotkey in Hotkey.allCases { setShortcut(KeyCombo.defaultCombo(for: hotkey), for: hotkey) }
    }

    /// The other hotkey already using `combo`, if any.
    public func conflict(for combo: KeyCombo, excluding hotkey: Hotkey) -> Hotkey? {
        Hotkey.allCases.first { $0 != hotkey && shortcut(for: $0) == combo }
    }

    /// Thread-safe read of the OCR switch (used by background capture/enrichment).
    public nonisolated static func isOCREnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: "ocrEnabled") as? Bool ?? true
    }

    public nonisolated static func isImageOptimizationEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: "optimizeImages") as? Bool ?? true
    }

    public nonisolated static func isAutoTagEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: "autoTag") as? Bool ?? true
    }

    public nonisolated static func areLinkPreviewsEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: "linkPreviews") as? Bool ?? true
    }

    /// Library folder: MINIBRAIN_DATA_DIR env > saved setting > default.
    public static func libraryBaseDirectory(defaults: UserDefaults = .standard,
                                            environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let env = environment["MINIBRAIN_DATA_DIR"], !env.isEmpty { return URL(fileURLWithPath: env, isDirectory: true) }
        if let path = defaults.string(forKey: Keys.libraryPath), !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        return nil
    }
}

extension Hotkey {
    public var title: String {
        switch self {
        case .toggleDropBox: "Show/Hide Drop Box"
        case .toggleLibrary: "Show/Hide Library"
        }
    }
}
