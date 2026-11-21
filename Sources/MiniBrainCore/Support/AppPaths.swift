import Foundation

/// Resolves on-disk locations. The base directory is injectable so tests use
/// a temp dir and never touch real user data.
public struct AppPaths: Sendable, Equatable {
    /// `…/Application Support/MiniBrain/` (or the injected base).
    public let baseDirectory: URL

    public var databaseURL: URL { baseDirectory.appendingPathComponent("brain.db", isDirectory: false) }
    public var blobsDirectory: URL { baseDirectory.appendingPathComponent("blobs", isDirectory: true) }

    /// - Parameter baseDirectory: overrides the default Application Support location.
    public init(baseDirectory: URL? = nil, fileManager: FileManager = .default) throws {
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            let support = try fileManager.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
            self.baseDirectory = support.appendingPathComponent(MiniBrain.appName, isDirectory: true)
        }
    }

    /// Creates the base and blobs directories. Safe to call repeatedly.
    @discardableResult
    public func ensureDirectories(fileManager: FileManager = .default) throws -> AppPaths {
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: blobsDirectory, withIntermediateDirectories: true)
        return self
    }
}
