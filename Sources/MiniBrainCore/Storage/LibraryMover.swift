import Foundation
import GRDB

/// Moves (copies) the library to a new folder, or adopts a library that is
/// already there. The old library is never deleted.
public enum LibraryMover {
    public enum Outcome: Equatable, Sendable {
        /// Database + blobs were copied into the new folder.
        case copied
        /// The folder already had a `brain.db`; it will be used as-is.
        case usingExisting
    }

    public enum MoveError: Error, Equatable, LocalizedError {
        case sameLocation
        case notWritable(String)

        public var errorDescription: String? {
            switch self {
            case .sameLocation: "That folder is already the library location."
            case .notWritable(let path): "Can't write to \(path)."
            }
        }
    }

    public static func relocate(to newBase: URL, from current: AppPaths, database: AppDatabase) throws -> Outcome {
        let newPaths = try AppPaths(baseDirectory: newBase)
        guard newBase.standardizedFileURL.path != current.baseDirectory.standardizedFileURL.path else {
            throw MoveError.sameLocation
        }
        do { try newPaths.ensureDirectories() } catch { throw MoveError.notWritable(newBase.path) }
        guard FileManager.default.isWritableFile(atPath: newBase.path) else { throw MoveError.notWritable(newBase.path) }

        if FileManager.default.fileExists(atPath: newPaths.databaseURL.path) { return .usingExisting }

        // Consistent snapshot of the live DB (WAL included) via SQLite backup.
        let target = try DatabaseQueue(path: newPaths.databaseURL.path, configuration: AppDatabase.makeConfiguration())
        try database.writer.backup(to: target)
        try target.close()

        // Copy blob shards that aren't there yet.
        let fm = FileManager.default
        if let shards = try? fm.contentsOfDirectory(at: current.blobsDirectory, includingPropertiesForKeys: nil) {
            for shard in shards {
                let destShard = newPaths.blobsDirectory.appendingPathComponent(shard.lastPathComponent, isDirectory: true)
                try fm.createDirectory(at: destShard, withIntermediateDirectories: true)
                for file in try fm.contentsOfDirectory(at: shard, includingPropertiesForKeys: nil) {
                    let dest = destShard.appendingPathComponent(file.lastPathComponent)
                    if !fm.fileExists(atPath: dest.path) { try fm.copyItem(at: file, to: dest) }
                }
            }
        }
        return .copied
    }

    /// Total bytes of the database files and blobs.
    public static func librarySize(_ paths: AppPaths) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        guard let e = fm.enumerator(at: paths.baseDirectory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        for case let url as URL in e {
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
        }
        return total
    }
}
