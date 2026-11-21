import AppKit
import Carbon.HIToolbox
import Foundation
import SwiftUI
import Testing
@testable import MiniBrainCore
@testable import MiniBrainUI

/// Fresh, isolated UserDefaults per test. The suite name is an absolute path
/// in the temp directory (CFPreferences stores path domains there), so tests
/// never write to ~/Library/Preferences.
func makeDefaults() -> UserDefaults {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("MiniBrainTests-defaults-\(UUID().uuidString)").path
    let d = UserDefaults(suiteName: path)!
    d.removePersistentDomain(forName: path)
    return d
}

@Suite struct DropBoxPositionTests {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let size = CGSize(width: 200, height: 100)

    @Test func allNinePositions() {
        let expected: [DropBoxPosition: CGPoint] = [
            .topLeft: CGPoint(x: 24, y: 676), .topCenter: CGPoint(x: 400, y: 676), .topRight: CGPoint(x: 776, y: 676),
            .middleLeft: CGPoint(x: 24, y: 350), .center: CGPoint(x: 400, y: 350), .middleRight: CGPoint(x: 776, y: 350),
            .bottomLeft: CGPoint(x: 24, y: 24), .bottomCenter: CGPoint(x: 400, y: 24), .bottomRight: CGPoint(x: 776, y: 24),
        ]
        for position in DropBoxPosition.allCases {
            #expect(position.origin(panelSize: size, in: screen) == expected[position], "\(position)")
        }
    }

    @Test func respectsScreenOffsetAndStaysInside() {
        let second = CGRect(x: 1440, y: -200, width: 1920, height: 1055) // e.g. external display, menu bar removed
        for position in DropBoxPosition.allCases {
            let o = position.origin(panelSize: size, in: second)
            #expect(second.contains(CGRect(origin: o, size: size)))
        }
    }

    @Test func samePlaceEveryTime() {
        let a = DropBoxPosition.bottomCenter.origin(panelSize: size, in: screen)
        let b = DropBoxPosition.bottomCenter.origin(panelSize: size, in: screen)
        #expect(a == b)
    }
}

@Suite struct KeyComboTests {
    @Test func displayStrings() {
        #expect(KeyCombo.defaultCombo(for: .toggleDropBox).displayString == "⇧⌘Space")
        #expect(KeyCombo.defaultCombo(for: .toggleLibrary).displayString == "⇧⌘B")
        #expect(KeyCombo(keyCode: UInt32(kVK_ANSI_K), modifiers: [.control, .option, .shift, .command]).displayString == "⌃⌥⇧⌘K")
        #expect(KeyCombo(keyCode: UInt32(kVK_F5), modifiers: []).displayString == "F5")
    }

    @Test func carbonModifiers() {
        let c = KeyCombo(keyCode: 1, modifiers: [.command, .shift, .option, .control, .capsLock])
        #expect(c.carbonModifiers == UInt32(cmdKey | shiftKey | optionKey | controlKey))
        #expect(c.modifierFlags == [.command, .shift, .option, .control]) // caps lock dropped
    }

    @Test func validity() {
        #expect(KeyCombo(keyCode: 0, modifiers: [.command]).isValidGlobalShortcut)
        #expect(!KeyCombo(keyCode: 0, modifiers: []).isValidGlobalShortcut)
        #expect(!KeyCombo(keyCode: 0, modifiers: [.shift]).isValidGlobalShortcut)
        #expect(KeyCombo(keyCode: UInt32(kVK_F6), modifiers: []).isValidGlobalShortcut)
    }

    @Test func recordingInterpretsKeys() {
        #expect(ShortcutRecording.interpret(keyCode: UInt16(kVK_Escape), modifiers: []) == .cancel)
        #expect(ShortcutRecording.interpret(keyCode: UInt16(kVK_Delete), modifiers: []) == .clear)
        #expect(ShortcutRecording.interpret(keyCode: UInt16(kVK_ANSI_D), modifiers: [.option, .command])
                == .record(KeyCombo(keyCode: UInt32(kVK_ANSI_D), modifiers: [.option, .command])))
        #expect(ShortcutRecording.interpret(keyCode: UInt16(kVK_ANSI_D), modifiers: []) == .invalid)
        #expect(ShortcutRecording.interpret(keyCode: UInt16(kVK_ANSI_D), modifiers: [.shift]) == .invalid)
        #expect(ShortcutRecording.interpret(keyCode: UInt16(kVK_Escape), modifiers: [.command]) != .cancel)
    }
}

@Suite @MainActor struct AppPreferencesTests {
    @Test func defaults() {
        let p = AppPreferences(defaults: makeDefaults())
        #expect(p.dropBoxPosition == .topRight)
        #expect(p.autoShowOnDrag)
        #expect(p.libraryPath == nil)
        #expect(p.shortcut(for: .toggleDropBox) == KeyCombo.defaultCombo(for: .toggleDropBox))
        #expect(p.shortcut(for: .toggleLibrary) == KeyCombo.defaultCombo(for: .toggleLibrary))
    }

    @Test func persistsAcrossInstances() {
        let d = makeDefaults()
        let p = AppPreferences(defaults: d)
        p.dropBoxPosition = .bottomCenter
        p.autoShowOnDrag = false
        p.libraryPath = "/Volumes/Data/Brain"
        let combo = KeyCombo(keyCode: UInt32(kVK_ANSI_J), modifiers: [.control, .option])
        p.setShortcut(combo, for: .toggleDropBox)
        p.setShortcut(nil, for: .toggleLibrary)

        let reloaded = AppPreferences(defaults: d)
        #expect(reloaded.dropBoxPosition == .bottomCenter)
        #expect(!reloaded.autoShowOnDrag)
        #expect(reloaded.libraryPath == "/Volumes/Data/Brain")
        #expect(reloaded.shortcut(for: .toggleDropBox) == combo)
        #expect(reloaded.shortcut(for: .toggleLibrary) == nil) // cleared stays cleared
    }

    @Test func libraryLocationPrecedence() {
        let d = makeDefaults()
        #expect(AppPreferences.libraryBaseDirectory(defaults: d, environment: [:]) == nil)
        d.set("/Users/x/Brain", forKey: AppPreferences.Keys.libraryPath)
        #expect(AppPreferences.libraryBaseDirectory(defaults: d, environment: [:])?.path == "/Users/x/Brain")
        #expect(AppPreferences.libraryBaseDirectory(defaults: d, environment: ["MINIBRAIN_DATA_DIR": "/tmp/dev"])?.path == "/tmp/dev")
    }
}

@Suite @MainActor struct ShortcutSettingsTests {
    func make() -> (AppPreferences, FakeHotkeyRegistrar, ShortcutSettings, AppState) {
        let prefs = AppPreferences(defaults: makeDefaults())
        let registrar = FakeHotkeyRegistrar()
        let state = AppState()
        state.bindHotkeys(registrar) { prefs.shortcut(for: $0) }
        return (prefs, registrar, ShortcutSettings(preferences: prefs, registrar: registrar), state)
    }

    let ctrlOptJ = KeyCombo(keyCode: UInt32(kVK_ANSI_J), modifiers: [.control, .option])

    @Test func bindingUsesSavedCombos() {
        let (_, registrar, _, _) = make()
        #expect(registrar.combos[.toggleDropBox] == KeyCombo.defaultCombo(for: .toggleDropBox))
        #expect(registrar.combos[.toggleLibrary] == KeyCombo.defaultCombo(for: .toggleLibrary))
    }

    @Test func changeAppliesLiveAndPersists() {
        let (prefs, registrar, settings, state) = make()
        #expect(settings.set(ctrlOptJ, for: .toggleDropBox))
        #expect(registrar.combos[.toggleDropBox] == ctrlOptJ)
        #expect(prefs.shortcut(for: .toggleDropBox) == ctrlOptJ)
        #expect(settings.errors.isEmpty)
        registrar.trigger(.toggleDropBox) // handler still wired after rebinding
        #expect(state.isDropBoxVisible)
    }

    @Test func conflictWithOtherHotkeyRejected() {
        let (prefs, registrar, settings, _) = make()
        let libraryCombo = KeyCombo.defaultCombo(for: .toggleLibrary)
        #expect(!settings.set(libraryCombo, for: .toggleDropBox))
        #expect(settings.errors[.toggleDropBox]?.contains("Show/Hide Library") == true)
        #expect(prefs.shortcut(for: .toggleDropBox) == KeyCombo.defaultCombo(for: .toggleDropBox))
        #expect(registrar.combos[.toggleDropBox] == KeyCombo.defaultCombo(for: .toggleDropBox))
    }

    @Test func systemRefusalRestoresPreviousShortcut() {
        let (prefs, registrar, settings, _) = make()
        registrar.taken = [ctrlOptJ]
        #expect(!settings.set(ctrlOptJ, for: .toggleLibrary))
        #expect(settings.errors[.toggleLibrary]?.contains("taken") == true)
        #expect(registrar.combos[.toggleLibrary] == KeyCombo.defaultCombo(for: .toggleLibrary))
        #expect(prefs.shortcut(for: .toggleLibrary) == KeyCombo.defaultCombo(for: .toggleLibrary))
    }

    @Test func clearAndRestoreDefaults() {
        let (prefs, registrar, settings, _) = make()
        settings.set(nil, for: .toggleDropBox)
        #expect(registrar.combos[.toggleDropBox] == nil)
        #expect(prefs.shortcut(for: .toggleDropBox) == nil)
        settings.set(ctrlOptJ, for: .toggleLibrary)
        settings.resetToDefaults()
        #expect(registrar.combos[.toggleDropBox] == KeyCombo.defaultCombo(for: .toggleDropBox))
        #expect(registrar.combos[.toggleLibrary] == KeyCombo.defaultCombo(for: .toggleLibrary))
        #expect(prefs.shortcut(for: .toggleLibrary) == KeyCombo.defaultCombo(for: .toggleLibrary))
    }

    @Test func recordingPausesHotkeys() {
        let (_, registrar, settings, _) = make()
        settings.setRecording(true)
        #expect(registrar.paused)
        settings.setRecording(false)
        #expect(!registrar.paused)
    }
}

@Suite struct LibraryMoverTests {
    @Test func copiesDatabaseAndBlobsAndKeepsOriginal() throws {
        let tmp = try TempDir()
        let oldPaths = try AppPaths(baseDirectory: tmp.url.appendingPathComponent("old")).ensureDirectories()
        let db = try AppDatabase.open(at: oldPaths.databaseURL)
        let blobs = BlobStore(directory: oldPaths.blobsDirectory)
        let capture = CaptureService(database: db, blobs: blobs)
        let image = try capture.capture(.imageData(try Fixtures.data("red.png")))
        let note = try capture.capture(.plainText("move me safely"))
        try ItemRepository(database: db).attachTag("keep", to: note.id)

        let newBase = tmp.url.appendingPathComponent("new place/Brain")
        #expect(try LibraryMover.relocate(to: newBase, from: oldPaths, database: db) == .copied)

        let newPaths = try AppPaths(baseDirectory: newBase)
        let moved = try AppDatabase.open(at: newPaths.databaseURL)
        let repo = ItemRepository(database: moved)
        #expect(Set(try repo.fetchAll().map(\.id)) == [image.id, note.id])
        #expect(try repo.tags(for: note.id).map(\.name) == ["keep"])
        #expect(try SearchService(database: moved).search("safely").map(\.id) == [note.id])
        #expect(try BlobStore(directory: newPaths.blobsDirectory).read(image.blobHash!) == (try Fixtures.data("red.png")))
        // Original untouched.
        #expect(try ItemRepository(database: db).count() == 2)
        #expect(blobs.exists(image.blobHash!))
    }

    @Test func existingLibraryIsAdoptedNotOverwritten() throws {
        let tmp = try TempDir()
        let oldPaths = try AppPaths(baseDirectory: tmp.url.appendingPathComponent("a")).ensureDirectories()
        let db = try AppDatabase.open(at: oldPaths.databaseURL)
        _ = try ItemRepository(database: db).insert(Item(type: .text, title: "in A", createdAt: Date()))
        let otherPaths = try AppPaths(baseDirectory: tmp.url.appendingPathComponent("b")).ensureDirectories()
        let other = try AppDatabase.open(at: otherPaths.databaseURL)
        _ = try ItemRepository(database: other).insert(Item(type: .text, title: "in B", createdAt: Date()))

        #expect(try LibraryMover.relocate(to: otherPaths.baseDirectory, from: oldPaths, database: db) == .usingExisting)
        #expect(try ItemRepository(database: other).fetchAll().map(\.title) == ["in B"])
    }

    @Test func sameLocationRejected() throws {
        let tmp = try TempDir()
        let paths = try AppPaths(baseDirectory: tmp.url).ensureDirectories()
        let db = try AppDatabase.open(at: paths.databaseURL)
        #expect(throws: LibraryMover.MoveError.sameLocation) {
            try LibraryMover.relocate(to: tmp.url, from: paths, database: db)
        }
    }
}

@Suite @MainActor struct StorageSettingsTests {
    final class Recorder { var relaunched = 0; var confirmed: [String] = []; var answer = true; var revealed: [URL] = [] }

    func make(_ tmp: TempDir, choose: URL?) throws -> (StorageSettings, AppPreferences, Recorder) {
        let paths = try AppPaths(baseDirectory: tmp.url.appendingPathComponent("current")).ensureDirectories()
        let db = try AppDatabase.open(at: paths.databaseURL)
        let repo = ItemRepository(database: db)
        _ = try repo.insert(Item(type: .text, title: "x", createdAt: Date()))
        let prefs = AppPreferences(defaults: makeDefaults())
        let rec = Recorder()
        let storage = StorageSettings(
            paths: paths, database: db, repository: repo, preferences: prefs,
            hooks: .init(chooseFolder: { choose },
                         confirm: { rec.confirmed.append($0); return rec.answer },
                         relaunch: { rec.relaunched += 1 },
                         reveal: { rec.revealed.append($0) }),
            defaultBase: tmp.url.appendingPathComponent("default"), isOverriddenByEnvironment: false)
        return (storage, prefs, rec)
    }

    @Test func showsLocationAndStats() throws {
        let tmp = try TempDir()
        let (storage, _, rec) = try make(tmp, choose: nil)
        #expect(storage.path.hasSuffix("/current"))
        #expect(storage.itemCount == 1)
        #expect(!storage.sizeDescription.isEmpty)
        #expect(!storage.isDefaultLocation)
        storage.revealInFinder()
        #expect(rec.revealed.map(\.lastPathComponent) == ["current"])
    }

    @Test func changeCopiesSavesAndRelaunches() throws {
        let tmp = try TempDir()
        let target = tmp.url.appendingPathComponent("chosen")
        let (storage, prefs, rec) = try make(tmp, choose: target)
        storage.chooseNewLocation()
        #expect(rec.confirmed.count == 1)
        #expect(rec.relaunched == 1)
        #expect(prefs.libraryPath == target.path)
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("brain.db").path))
        #expect(storage.message == nil)
    }

    @Test func cancelDoesNothing() throws {
        let tmp = try TempDir()
        let target = tmp.url.appendingPathComponent("chosen")
        let (storage, prefs, rec) = try make(tmp, choose: target)
        rec.answer = false
        storage.chooseNewLocation()
        #expect(rec.relaunched == 0)
        #expect(prefs.libraryPath == nil)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func resetToDefaultClearsSetting() throws {
        let tmp = try TempDir()
        let (storage, prefs, rec) = try make(tmp, choose: nil)
        prefs.libraryPath = storage.path
        storage.resetToDefault()
        #expect(prefs.libraryPath == nil)
        #expect(rec.relaunched == 1)
    }

    @Test func choosingCurrentFolderShowsError() throws {
        let tmp = try TempDir()
        let (storage, _, rec) = try make(tmp, choose: tmp.url.appendingPathComponent("current"))
        storage.chooseNewLocation()
        #expect(rec.relaunched == 0)
        #expect(storage.message?.contains("already") == true)
    }
}

@Suite struct MenuShortcutTests {
    @Test func comboConvertsToMenuShortcut() {
        let space = KeyCombo.defaultCombo(for: .toggleDropBox).swiftUIShortcut
        #expect(space?.key == KeyEquivalent(" "))
        #expect(space?.modifiers == [.command, .shift])
        let custom = KeyCombo(keyCode: UInt32(kVK_ANSI_J), modifiers: [.control, .option]).swiftUIShortcut
        #expect(custom?.key == KeyEquivalent("j"))
        #expect(custom?.modifiers == [.control, .option])
        let f5 = KeyCombo(keyCode: UInt32(kVK_F5), modifiers: []).swiftUIShortcut
        #expect(f5?.key == KeyEquivalent(Character(Unicode.Scalar(0xF708)!)))
        #expect(KeyCombo(keyCode: 999, modifiers: [.command]).swiftUIShortcut == nil)
    }

    @Test @MainActor func menuFollowsSavedShortcut() {
        let prefs = AppPreferences(defaults: makeDefaults())
        let settings = ShortcutSettings(preferences: prefs, registrar: FakeHotkeyRegistrar())
        settings.set(KeyCombo(keyCode: UInt32(kVK_ANSI_K), modifiers: [.command, .option]), for: .toggleLibrary)
        #expect(prefs.shortcut(for: .toggleLibrary)?.swiftUIShortcut?.key == KeyEquivalent("k"))
        settings.set(nil, for: .toggleDropBox)
        #expect(prefs.shortcut(for: .toggleDropBox)?.swiftUIShortcut == nil)
    }
}
