import Foundation
import SwiftUI
import Testing
@testable import MiniBrainCore
@testable import MiniBrainUI

/// Settings › General › Excluded Apps: no drag pop-up while one of them is
/// in front (default) or open.
@Suite @MainActor struct ExcludedAppsTests {
    let figma = ExcludedApp(bundleID: "com.figma.Desktop", name: "Figma")
    let finder = ExcludedApp(bundleID: "com.apple.finder", name: "Finder")

    @Test func frontmostRuleBlocksOnlyWhenExcludedAppIsInFront() {
        let ex = DropExclusions(apps: [figma, finder], rule: .frontmost)
        #expect(ex.blockingApp(frontmost: "com.figma.Desktop", running: [])?.name == "Figma")
        #expect(ex.blockingApp(frontmost: "COM.APPLE.FINDER", running: [])?.name == "Finder") // bundle IDs are case-insensitive
        #expect(ex.blockingApp(frontmost: "com.apple.Safari", running: ["com.figma.Desktop"]) == nil)
        #expect(ex.blockingApp(frontmost: nil, running: []) == nil)
    }

    @Test func runningRuleBlocksWhileExcludedAppIsOpenAnywhere() {
        let ex = DropExclusions(apps: [figma], rule: .running)
        #expect(ex.blockingApp(frontmost: "com.apple.Safari", running: ["com.figma.Desktop", "com.apple.Safari"])?.name == "Figma")
        #expect(ex.blockingApp(frontmost: "com.apple.Safari", running: ["com.apple.Safari"]) == nil)
    }

    @Test func emptyListNeverBlocks() {
        let ex = DropExclusions(apps: [], rule: .running)
        #expect(ex.blockingApp(frontmost: "com.figma.Desktop", running: ["com.figma.Desktop"]) == nil)
    }

    @Test func preferencesPersistListAndRule() {
        let defaults = makeDefaults()
        let prefs = AppPreferences(defaults: defaults)
        #expect(prefs.excludedApps.isEmpty)
        #expect(prefs.exclusionRule == .frontmost)
        prefs.addExcludedApp(figma)
        prefs.addExcludedApp(ExcludedApp(bundleID: "COM.FIGMA.DESKTOP", name: "Figma again")) // duplicate ignored
        prefs.addExcludedApp(finder)
        prefs.exclusionRule = .running
        let reloaded = AppPreferences(defaults: defaults)
        #expect(reloaded.excludedApps.map(\.bundleID) == ["com.figma.Desktop", "com.apple.finder"])
        #expect(reloaded.exclusionRule == .running)
        reloaded.removeExcludedApp("com.figma.Desktop")
        #expect(AppPreferences(defaults: defaults).excludedApps.map(\.name) == ["Finder"])
    }

    @Test func corruptSavedListFallsBackToEmpty() {
        let defaults = makeDefaults()
        defaults.set(Data("nope".utf8), forKey: AppPreferences.Keys.excludedApps)
        #expect(AppPreferences(defaults: defaults).excludedApps.isEmpty)
    }

    @Test func dragDoesNotPopUpWhileBlocked() {
        let state = AppState()
        let presenter = FakePresenter()
        state.presenter = presenter
        var blocked = true
        let autoShow = DropBoxAutoShow(appState: state, clock: FakeClock(), isEnabled: { !blocked }, dropState: { nil })
        autoShow.dragStarted()
        #expect(!state.isDropBoxVisible)
        blocked = false
        autoShow.dragStarted()
        #expect(state.isDropBoxVisible)
    }

    @Test func appFromBundleReadsIDAndName() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ex-\(UUID().uuidString)/Sketchy.app/Contents")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.example.sketchy", "CFBundleName": "Sketchy"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: dir.appendingPathComponent("Info.plist"))
        let app = try #require(ExcludedApp(appURL: dir.deletingLastPathComponent()))
        #expect(app.bundleID == "com.example.sketchy")
        #expect(app.name == "Sketchy")
        #expect(ExcludedApp(appURL: FileManager.default.temporaryDirectory) == nil)
    }

    @Test func settingsSectionRenders() {
        let prefs = AppPreferences(defaults: makeDefaults())
        prefs.addExcludedApp(figma)
        let view = ExcludedAppsSection(preferences: prefs, runningApps: { [finder] })
        let host = NSHostingView(rootView: Form { view }.formStyle(.grouped).frame(width: 500, height: 300))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height > 0)
    }
}
