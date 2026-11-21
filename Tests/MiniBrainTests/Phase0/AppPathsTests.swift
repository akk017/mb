import Foundation
import Testing
@testable import MiniBrainCore

@Suite struct AppPathsTests {
    @Test func resolvesPathsUnderInjectedBase() throws {
        let tmp = try TempDir()
        let paths = try AppPaths(baseDirectory: tmp.url)
        #expect(paths.baseDirectory == tmp.url)
        #expect(paths.databaseURL == tmp.url.appendingPathComponent("brain.db"))
        #expect(paths.blobsDirectory == tmp.url.appendingPathComponent("blobs", isDirectory: true))
    }

    @Test func createsDirectories() throws {
        let tmp = try TempDir()
        let base = tmp.url.appendingPathComponent("nested/MiniBrain")
        let paths = try AppPaths(baseDirectory: base).ensureDirectories()
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: paths.baseDirectory.path, isDirectory: &isDir) && isDir.boolValue)
        #expect(FileManager.default.fileExists(atPath: paths.blobsDirectory.path, isDirectory: &isDir) && isDir.boolValue)
    }

    @Test func ensureDirectoriesIsIdempotent() throws {
        let tmp = try TempDir()
        let paths = try AppPaths(baseDirectory: tmp.url)
        try paths.ensureDirectories()
        let marker = paths.blobsDirectory.appendingPathComponent("keep.txt")
        try Data("x".utf8).write(to: marker)
        try paths.ensureDirectories()
        try paths.ensureDirectories()
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func defaultBaseIsApplicationSupportMiniBrain() throws {
        // Only resolves the path; does not create anything under the real home.
        let paths = try AppPaths()
        #expect(paths.baseDirectory.lastPathComponent == "MiniBrain")
        #expect(paths.baseDirectory.deletingLastPathComponent().lastPathComponent == "Application Support")
    }
}
