import Foundation
import os

/// App log: plain-text lines in `~/Library/Application Support/MiniBrain/Logs/
/// minibrain.log` (rotated at `maxBytes`, keeping `keep` older files), mirrored
/// to the unified system log (subsystem `app.minibrain`).
///
/// Writes happen on a private serial queue, so logging never blocks the
/// caller (important on the main thread). Never log item contents or
/// clipboard data — only ids, kinds, hosts, sizes, timings and errors.
public final class Log: @unchecked Sendable {
    public enum Level: String, Sendable { case debug = "DEBUG", info = "INFO", warning = "WARN", error = "ERROR" }

    /// Shared app logger. Disabled (no file) until `configure` is called, so
    /// tests never write into the real Application Support folder.
    public static let shared = Log()

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MiniBrain/Logs", isDirectory: true)
    }

    public static let fileName = "minibrain.log"

    private let queue = DispatchQueue(label: "app.minibrain.log")
    private var directory: URL?
    private var handle: FileHandle?
    private var maxBytes: UInt64 = 2_000_000
    private var keep = 3
    private let system = Logger(subsystem: "app.minibrain", category: "app")
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public init() {}

    /// Starts writing to `directory/minibrain.log`.
    public func configure(directory: URL = Log.defaultDirectory, maxBytes: UInt64 = 2_000_000, keep: Int = 3) {
        queue.sync {
            try? handle?.close()
            handle = nil
            self.directory = directory
            self.maxBytes = maxBytes
            self.keep = max(1, keep)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// Current log file (nil when not configured).
    public var fileURL: URL? { queue.sync { directory?.appendingPathComponent(Self.fileName) } }

    /// Waits until queued lines are on disk (tests, app quit).
    public func flush() { queue.sync { try? handle?.synchronize() } }

    public func debug(_ message: @autoclosure () -> String, _ category: String = "app") { write(.debug, message(), category) }
    public func info(_ message: @autoclosure () -> String, _ category: String = "app") { write(.info, message(), category) }
    public func warning(_ message: @autoclosure () -> String, _ category: String = "app") { write(.warning, message(), category) }
    public func error(_ message: @autoclosure () -> String, _ category: String = "app") { write(.error, message(), category) }

    private func write(_ level: Level, _ message: String, _ category: String) {
        let date = Date()
        switch level {
        case .debug: system.debug("[\(category, privacy: .public)] \(message, privacy: .public)")
        case .info: system.info("[\(category, privacy: .public)] \(message, privacy: .public)")
        case .warning: system.warning("[\(category, privacy: .public)] \(message, privacy: .public)")
        case .error: system.error("[\(category, privacy: .public)] \(message, privacy: .public)")
        }
        queue.async { [self] in
            guard directory != nil else { return }
            let line = "\(formatter.string(from: date)) \(level.rawValue) [\(category)] \(message)\n"
            append(Data(line.utf8))
        }
    }

    // MARK: - File (queue only)

    private func append(_ data: Data) {
        guard let file = openIfNeeded() else { return }
        do {
            try file.seekToEnd()
            try file.write(contentsOf: data)
            if (try file.offset()) >= maxBytes { rotate() }
        } catch {
            try? handle?.close()
            handle = nil
        }
    }

    private func openIfNeeded() -> FileHandle? {
        if let handle { return handle }
        guard let directory else { return nil }
        let url = directory.appendingPathComponent(Self.fileName)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        return handle
    }

    /// minibrain.log → minibrain.1.log → … → minibrain.<keep>.log (dropped).
    private func rotate() {
        guard let directory else { return }
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        func url(_ i: Int) -> URL {
            directory.appendingPathComponent(i == 0 ? Self.fileName : "minibrain.\(i).log")
        }
        try? fm.removeItem(at: url(keep))
        for i in stride(from: keep - 1, through: 0, by: -1) where fm.fileExists(atPath: url(i).path) {
            try? fm.moveItem(at: url(i), to: url(i + 1))
        }
        _ = openIfNeeded() // fresh, empty minibrain.log is always there
    }
}

/// Logs when the main thread stops answering for `threshold` seconds — the
/// "Not Responding" beachball — and when it recovers, with the stall length.
public final class MainThreadWatchdog: @unchecked Sendable {
    private let threshold: TimeInterval
    private let log: Log
    private let queue = DispatchQueue(label: "app.minibrain.watchdog")
    private var timer: DispatchSourceTimer?
    private var pendingSince: Date?
    private var reported = false

    public init(threshold: TimeInterval = 2, log: Log = .shared) {
        self.threshold = threshold
        self.log = log
    }

    public func start(interval: TimeInterval = 0.5) {
        queue.sync {
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + interval, repeating: interval)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    public func stop() { queue.sync { timer?.cancel(); timer = nil } }

    private func tick() {
        let now = Date()
        if let since = pendingSince {
            let stalled = now.timeIntervalSince(since)
            if stalled >= threshold, !reported {
                reported = true
                log.warning("Main thread unresponsive for \(String(format: "%.1f", stalled))s", "watchdog")
            }
            return
        }
        pendingSince = now
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.queue.async {
                if let since = self.pendingSince, self.reported {
                    let total = Date().timeIntervalSince(since)
                    self.log.warning("Main thread responsive again after \(String(format: "%.1f", total))s", "watchdog")
                }
                self.pendingSince = nil
                self.reported = false
            }
        }
    }
}

/// Spots runaway UI loops: when one named event fires more than `limit`
/// times within `window` seconds (e.g. a hover flipping on/off every frame),
/// logs a warning with the latest detail — at most once per `cooldown` per name.
public final class LoopDetector: @unchecked Sendable {
    public static let shared = LoopDetector()

    private let lock = NSLock()
    private let log: Log
    private let limit: Int
    private let window: TimeInterval
    private let cooldown: TimeInterval
    private let now: @Sendable () -> Date
    private var hits: [String: [Date]] = [:]
    private var lastReport: [String: Date] = [:]

    public init(log: Log = .shared, limit: Int = 30, window: TimeInterval = 1, cooldown: TimeInterval = 10,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.log = log
        self.limit = limit
        self.window = window
        self.cooldown = cooldown
        self.now = now
    }

    /// Records one occurrence. Returns true when this call reported a loop.
    @discardableResult
    public func tick(_ name: String, detail: @autoclosure () -> String = "") -> Bool {
        let t = now()
        let report: Int? = lock.withLock {
            var list = hits[name, default: []]
            list.append(t)
            list.removeAll { t.timeIntervalSince($0) > window }
            hits[name] = list
            guard list.count > limit else { return nil }
            if let last = lastReport[name], t.timeIntervalSince(last) < cooldown { return nil }
            lastReport[name] = t
            return list.count
        }
        guard let count = report else { return false }
        let d = detail()
        log.warning("Possible UI loop: \(name) fired \(count)× in \(Int(window))s\(d.isEmpty ? "" : " (last: \(d))")", "loop")
        return true
    }
}
