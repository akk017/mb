import Foundation

/// Injectable source of time. Everything that reads "now" or waits goes through
/// this so tests can drive time with a fake.
///
/// Named `Clock` per the roadmap; inside this module it shadows the standard
/// library's `Clock` protocol, which MiniBrain does not use.
public protocol Clock: Sendable {
    var now: Date { get }
    /// Suspends for `seconds` of this clock's time. Throws `CancellationError`
    /// when the task is cancelled.
    func sleep(for seconds: TimeInterval) async throws
}

/// Wall-clock implementation.
public struct SystemClock: Clock {
    public init() {}
    public var now: Date { Date() }
    public func sleep(for seconds: TimeInterval) async throws {
        guard seconds > 0 else { try Task.checkCancellation(); return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
