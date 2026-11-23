import Foundation
import Network

/// Minimal HTTP/1.1 server on 127.0.0.1 (Network.framework). One request per
/// connection (`Connection: close`); bodies need a Content-Length.
public final class LocalAPIServer: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case stopped
        case running(port: UInt16)
        case failed(String)
    }

    private let handler: @Sendable (HTTPRequest) async -> HTTPResponse
    private let maxBodyBytes: Int
    private let requestTimeout: TimeInterval
    private let queue = DispatchQueue(label: "app.minibrain.api")
    private let lock = NSLock()
    private var listener: NWListener?
    private var _state: State = .stopped

    /// Called on the server queue whenever the state changes.
    public var onStateChange: (@Sendable (State) -> Void)?

    public init(maxBodyBytes: Int = 30 * 1024 * 1024, requestTimeout: TimeInterval = 30,
                handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) {
        self.handler = handler
        self.maxBodyBytes = maxBodyBytes
        self.requestTimeout = requestTimeout
    }

    public var state: State { lock.withLock { _state } }

    public var boundPort: UInt16? {
        if case .running(let port) = state { return port }
        return nil
    }

    /// Listens on 127.0.0.1:`port` (0 = any free port).
    public func start(port: UInt16) throws {
        stop()
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw MiniBrainError.enrichmentFailed("Bad port \(port)") }
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.set(.running(port: listener?.port?.rawValue ?? port))
            case .failed(let error):
                self.set(.failed(Self.describe(error, port: port)))
                listener?.cancel()
            case .cancelled:
                if case .failed = self.state { return }
                self.set(.stopped)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        lock.withLock { self.listener = listener }
        listener.start(queue: queue)
    }

    public func stop() {
        let current = lock.withLock { () -> NWListener? in
            let l = listener
            listener = nil
            return l
        }
        current?.cancel()
        set(.stopped)
    }

    private func set(_ state: State) {
        let changed = lock.withLock { () -> Bool in
            guard _state != state else { return false }
            _state = state
            return true
        }
        if changed { onStateChange?(state) }
    }

    static func describe(_ error: NWError, port: UInt16) -> String {
        if case .posix(let code) = error, code == .EADDRINUSE { return "Port \(port) is already in use" }
        return error.localizedDescription
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        let deadline = DispatchWorkItem { [weak connection] in connection?.cancel() }
        queue.asyncAfter(deadline: .now() + requestTimeout, execute: deadline)
        receive(on: connection, buffer: Data(), deadline: deadline)
    }

    private func receive(on connection: NWConnection, buffer: Data, deadline: DispatchWorkItem) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequestParser.parse(buffer, maxBodyBytes: self.maxBodyBytes) {
            case .complete(let request, _):
                let handler = self.handler
                let timer = DeadlineBox(item: deadline)
                Task {
                    let response = await handler(request)
                    self.send(response, on: connection, deadline: timer.item)
                }
            case .invalid(let status, let message):
                self.send(.error(status, message), on: connection, deadline: deadline)
            case .incomplete:
                if isComplete || error != nil {
                    deadline.cancel()
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer, deadline: deadline)
                }
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection, deadline: DispatchWorkItem) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in
            deadline.cancel()
            connection.cancel()
        })
    }
}

/// DispatchWorkItem is thread-safe (cancel from any thread) but not marked
/// Sendable; this lets the request timeout cross into the handler Task.
private struct DeadlineBox: @unchecked Sendable {
    let item: DispatchWorkItem
}
