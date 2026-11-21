import AppKit
import Testing
@testable import MiniBrainUI

@Suite @MainActor struct IconTests {
    @Test func everyLucideIconLoadsAsTemplate() {
        for icon in LucideIcon.allCases {
            let image = icon.image
            #expect(image != nil, "missing icon \(icon.rawValue)")
            #expect(image?.isTemplate == true)
            #expect(image?.size == NSSize(width: 24, height: 24))
        }
    }
}

@Suite struct IconBundleLookupTests {
    @Test func findsBundleInsideAppResources() throws {
        let tmp = try TempDir()
        let app = tmp.url.appendingPathComponent("MiniBrain.app")
        let resources = app.appendingPathComponent("Contents/Resources")
        let iconBundle = resources.appendingPathComponent(LucideIcon.bundleName)
        try FileManager.default.createDirectory(at: iconBundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try Data("""
            <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
            <key>CFBundleExecutable</key><string>MiniBrain</string>
            <key>CFBundleIdentifier</key><string>test.app</string>
            <key>CFBundlePackageType</key><string>APPL</string></dict></plist>
            """.utf8).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let main = try #require(Bundle(url: app))
        let found = try #require(LucideIcon.resourceBundle(main: main))
        #expect(found.bundleURL.standardizedFileURL == iconBundle.standardizedFileURL)
    }

    @Test func missingBundleReturnsNilInsteadOfCrashing() throws {
        let tmp = try TempDir()
        let main = try #require(Bundle(url: tmp.url))
        #expect(LucideIcon.resourceBundle(main: main) == nil)
    }
}
