import AppKit
import Carbon.HIToolbox
import MiniBrainCore
import Observation

/// Interprets a key press while recording a shortcut.
public enum ShortcutRecording {
    public enum Action: Equatable {
        case cancel
        case clear
        case record(KeyCombo)
        case invalid
    }

    public static func interpret(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Action {
        let mods = modifiers.intersection(KeyCombo.relevantModifiers)
        if mods.isEmpty, Int(keyCode) == kVK_Escape { return .cancel }
        if mods.isEmpty, Int(keyCode) == kVK_Delete || Int(keyCode) == kVK_ForwardDelete { return .clear }
        let combo = KeyCombo(keyCode: UInt32(keyCode), modifiers: mods)
        return combo.isValidGlobalShortcut ? .record(combo) : .invalid
    }
}

/// Applies shortcut changes: conflict check, live re-registration, persistence.
@MainActor
@Observable
public final class ShortcutSettings {
    @ObservationIgnored let preferences: AppPreferences
    @ObservationIgnored let registrar: any HotkeyRegistering
    public private(set) var errors: [Hotkey: String] = [:]

    public init(preferences: AppPreferences, registrar: any HotkeyRegistering) {
        self.preferences = preferences
        self.registrar = registrar
    }

    public var supportsCustomCombos: Bool { registrar.supportsCustomCombos }

    public func combo(for hotkey: Hotkey) -> KeyCombo? { preferences.shortcut(for: hotkey) }

    /// Returns true when the new shortcut is active.
    @discardableResult
    public func set(_ combo: KeyCombo?, for hotkey: Hotkey) -> Bool {
        errors[hotkey] = nil
        let previous = preferences.shortcut(for: hotkey)
        guard combo != previous else { return true }
        if let combo {
            if let other = preferences.conflict(for: combo, excluding: hotkey) {
                errors[hotkey] = "\(combo.displayString) is already used for “\(other.title)”."
                return false
            }
            guard registrar.setCombo(combo, for: hotkey) else {
                registrar.setCombo(previous, for: hotkey) // restore the old binding
                errors[hotkey] = "\(combo.displayString) is taken by macOS or another app."
                return false
            }
        } else {
            registrar.setCombo(nil, for: hotkey)
        }
        preferences.setShortcut(combo, for: hotkey)
        return true
    }

    public func resetToDefaults() {
        errors = [:]
        for hotkey in Hotkey.allCases { registrar.setCombo(nil, for: hotkey) }
        preferences.resetShortcuts()
        for hotkey in Hotkey.allCases {
            if !registrar.setCombo(preferences.shortcut(for: hotkey), for: hotkey) {
                errors[hotkey] = "Default shortcut is taken by macOS or another app."
            }
        }
    }

    public func setRecording(_ recording: Bool) { registrar.setPaused(recording) }
}

/// Storage tab: shows where the library lives and moves it.
@MainActor
@Observable
public final class StorageSettings {
    public struct Hooks {
        /// Asks the user for a folder (NSOpenPanel in the app).
        public var chooseFolder: () -> URL?
        /// Asks for confirmation with a message; true = go ahead.
        public var confirm: (String) -> Bool
        /// Restarts the app so it opens the library at the new location.
        public var relaunch: () -> Void
        public var reveal: (URL) -> Void

        public init(chooseFolder: @escaping () -> URL?, confirm: @escaping (String) -> Bool,
                    relaunch: @escaping () -> Void, reveal: @escaping (URL) -> Void) {
            self.chooseFolder = chooseFolder
            self.confirm = confirm
            self.relaunch = relaunch
            self.reveal = reveal
        }
    }

    @ObservationIgnored let paths: AppPaths
    @ObservationIgnored let database: AppDatabase
    @ObservationIgnored let repository: ItemRepository
    @ObservationIgnored let preferences: AppPreferences
    @ObservationIgnored let hooks: Hooks
    @ObservationIgnored let defaultBase: URL?
    public let isOverriddenByEnvironment: Bool
    public private(set) var sizeDescription = ""
    public private(set) var itemCount = 0
    public private(set) var message: String?

    public init(paths: AppPaths, database: AppDatabase, repository: ItemRepository, preferences: AppPreferences,
                hooks: Hooks, defaultBase: URL? = try? AppPaths().baseDirectory,
                isOverriddenByEnvironment: Bool = ProcessInfo.processInfo.environment["MINIBRAIN_DATA_DIR"] != nil) {
        self.paths = paths
        self.database = database
        self.repository = repository
        self.preferences = preferences
        self.hooks = hooks
        self.defaultBase = defaultBase
        self.isOverriddenByEnvironment = isOverriddenByEnvironment
        refresh()
    }

    public var path: String { paths.baseDirectory.path }
    public var isDefaultLocation: Bool {
        defaultBase.map { $0.standardizedFileURL.path == paths.baseDirectory.standardizedFileURL.path } ?? true
    }

    public func refresh() {
        itemCount = (try? repository.count(includeTrashed: true)) ?? 0
        sizeDescription = ByteCountFormatter.string(fromByteCount: LibraryMover.librarySize(paths), countStyle: .file)
    }

    public func revealInFinder() { hooks.reveal(paths.baseDirectory) }

    public func chooseNewLocation() {
        guard let folder = hooks.chooseFolder() else { return }
        move(to: folder)
    }

    public func resetToDefault() {
        guard let defaultBase else { return }
        move(to: defaultBase, isDefault: true)
    }

    /// Copies (or adopts) the library at `folder`, saves the setting, restarts.
    public func move(to folder: URL, isDefault: Bool = false) {
        message = nil
        let hasLibrary = FileManager.default.fileExists(atPath: folder.appendingPathComponent("brain.db").path)
        let question = hasLibrary
            ? "“\(folder.path)” already contains a MiniBrain library. Switch to it? MiniBrain will restart. Your current library stays where it is."
            : "Copy your library to “\(folder.path)”? MiniBrain will restart. The current copy stays where it is."
        guard hooks.confirm(question) else { return }
        do {
            _ = try LibraryMover.relocate(to: folder, from: paths, database: database)
            preferences.libraryPath = isDefault ? nil : folder.path
            hooks.relaunch()
        } catch {
            message = error.localizedDescription
        }
    }
}

/// Settings › Types: create/rename/delete custom types and edit their fields.
@MainActor
@Observable
public final class TypesSettings {
    @ObservationIgnored let repository: CustomTypeRepository
    public private(set) var types: [CustomType] = []
    public private(set) var selectedID: String?
    /// Editable copy of the selected type; changes are saved by `commit()`.
    public var draft: CustomType?
    public private(set) var error: String?
    @ObservationIgnored public var onChange: (() -> Void)?

    public init(repository: CustomTypeRepository) {
        self.repository = repository
        reload()
    }

    public func reload() {
        types = (try? repository.all()) ?? []
        if selectedID == nil || !types.contains(where: { $0.id == selectedID }) { selectedID = types.first?.id }
        draft = types.first { $0.id == selectedID }
    }

    public func select(_ id: String?) {
        guard id != selectedID else { return }
        commit()
        selectedID = id
        draft = types.first { $0.id == id }
        error = nil
    }

    /// New type with sensible starter fields (Name + Link).
    @discardableResult
    public func addType() -> CustomType? {
        commit()
        var name = "New Type"
        var n = 2
        while types.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { name = "New Type \(n)"; n += 1 }
        do {
            let type = try repository.create(name: name, fields: [
                FieldDefinition(name: "Name", kind: .text),
                FieldDefinition(name: "Link", kind: .webLink),
            ])
            selectedID = type.id
            reload()
            onChange?()
            return type
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    public func deleteSelected() {
        guard let id = selectedID else { return }
        do {
            try repository.delete(id)
            selectedID = nil
            reload()
            onChange?()
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func itemCount(for id: String) -> Int { (try? repository.itemCount(for: id)) ?? 0 }

    /// Saves the draft if it changed. On error (empty/duplicate name) the
    /// stored version is kept and the message shown.
    public func commit() {
        guard let draft, let stored = types.first(where: { $0.id == draft.id }), draft != stored else { return }
        do {
            let saved = try repository.update(draft)
            if let i = types.firstIndex(where: { $0.id == saved.id }) { types[i] = saved }
            types.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self.draft = saved
            error = nil
            onChange?()
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func addField(_ kind: FieldKind) {
        guard draft != nil else { return }
        draft?.fields.append(FieldDefinition(name: kind.title, kind: kind))
        commit()
    }

    public func removeField(_ id: String) {
        draft?.fields.removeAll { $0.id == id }
        commit()
    }

    public func moveField(_ id: String, by offset: Int) {
        guard var fields = draft?.fields, let i = fields.firstIndex(where: { $0.id == id }) else { return }
        let j = i + offset
        guard fields.indices.contains(j) else { return }
        fields.swapAt(i, j)
        draft?.fields = fields
        commit()
    }

    public func setKind(_ kind: FieldKind, for id: String) {
        guard let i = draft?.fields.firstIndex(where: { $0.id == id }) else { return }
        draft?.fields[i].kind = kind
        commit()
    }
}

/// Which Settings tab is showing (so other UI can jump to a tab).
@MainActor
@Observable
public final class SettingsNavigation {
    public enum Tab: Hashable { case general, shortcuts, types, storage }
    public var tab: Tab = .general
    public init() {}
}
