import AppKit
import SwiftUI
import Testing
@testable import MiniBrainCore
@testable import MiniBrainUI

@Suite @MainActor struct AppearanceAccentTests {
    func hex(_ c: NSColor) -> String {
        let s = c.usingColorSpace(.sRGB)!
        return String(format: "#%02X%02X%02X", Int((s.redComponent * 255).rounded()),
                      Int((s.greenComponent * 255).rounded()), Int((s.blueComponent * 255).rounded()))
    }

    @Test func defaultIsJsonAccentPrimary() {
        #expect(hex(AccentChoice.jsonDefault.nsColor(dark: false)) == "#0062FA") // blue.60
        #expect(hex(AccentChoice.jsonDefault.nsColor(dark: true)) == "#00CADB")  // cyan.30
    }

    @Test func everyJsonHueHasLightAndDarkSteps() {
        let hues: [AccentChoice: Double] = [.red: 15, .orange: 50, .yellow: 90, .green: 145, .cyan: 205,
                                            .blue: 260, .violet: 290, .purple: 315, .pink: 360]
        for (choice, hue) in hues {
            let v = try! #require(choice.oklch)
            #expect(v.light.2 == hue && v.dark.2 == hue)
            #expect(v.dark.0 > v.light.0) // dark mode uses the lighter step (30 vs 60/70)
        }
        #expect(AccentChoice.yellow.oklch?.light.0 == 51) // yellow.70 for contrast with white text
        #expect(AccentChoice.allCases.count == 11)        // default + 9 hues + macOS
    }

    @Test func systemFollowsMacOSAccent() {
        #expect(AccentChoice.system.oklch == nil)
        #expect(AccentChoice.system.nsColor(dark: false) == NSColor.controlAccentColor)
    }

    @Test func choicePersistsAndDrivesTheme() {
        let saved = Theme.accentChoice
        defer { Theme.accentChoice = saved }
        let d = makeDefaults()
        let p = AppPreferences(defaults: d)
        #expect(p.accentColor == .jsonDefault)
        #expect(p.appearance == .system)
        p.accentColor = .pink
        p.appearance = .dark
        #expect(Theme.accentChoice == .pink)
        let reloaded = AppPreferences(defaults: d)
        #expect(reloaded.accentColor == .pink)
        #expect(reloaded.appearance == .dark)
    }

    @Test func appearanceMapsToNSAppearance() {
        #expect(AppAppearance.system.nsAppearance == nil)
        #expect(AppAppearance.light.nsAppearance?.name == .aqua)
        #expect(AppAppearance.dark.nsAppearance?.name == .darkAqua)
    }
}
