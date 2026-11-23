import AppKit
import MiniBrainCore
import Observation
import SwiftUI

/// Thread-safe holder for the current token (read by the API on its queue).
final class TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    var token: String {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// Owns the local API server: starts/stops it from the preferences, holds the
/// token, and publishes state for Settings › API.
@MainActor
@Observable
public final class LocalAPIController {
    public private(set) var state: LocalAPIServer.State = .stopped
    public private(set) var token = ""

    @ObservationIgnored let preferences: AppPreferences
    @ObservationIgnored let tokenStore: LocalAPIToken
    @ObservationIgnored private let makeAPI: @MainActor (_ token: @escaping @Sendable () -> String) -> LocalAPI?
    @ObservationIgnored private var server: LocalAPIServer?
    @ObservationIgnored private let tokenBox = TokenBox()
    /// Port used when `preferences.localAPIPort` is 0 (tests: any free port).
    @ObservationIgnored private let portOverride: UInt16?

    public init(preferences: AppPreferences, tokenStore: LocalAPIToken = LocalAPIToken(), portOverride: UInt16? = nil,
                makeAPI: @escaping @MainActor (_ token: @escaping @Sendable () -> String) -> LocalAPI?) {
        self.preferences = preferences
        self.tokenStore = tokenStore
        self.portOverride = portOverride
        self.makeAPI = makeAPI
    }

    public var isEnabled: Bool { preferences.localAPIEnabled }

    public func setEnabled(_ on: Bool) {
        preferences.localAPIEnabled = on
        apply()
    }

    /// Validates and saves a new port; restarts when running.
    @discardableResult
    public func setPort(_ port: Int) -> Bool {
        guard (1024...65535).contains(port) else { return false }
        guard port != preferences.localAPIPort else { return true }
        preferences.localAPIPort = port
        apply()
        return true
    }

    public var port: UInt16 { portOverride ?? UInt16(preferences.localAPIPort) }
    public var baseURL: String { "http://127.0.0.1:\(state.runningPort ?? port)" }

    /// Starts or stops to match the preference.
    public func apply() {
        server?.stop()
        server = nil
        guard preferences.localAPIEnabled else {
            state = .stopped
            Log.shared.info("local API off", "api")
            return
        }
        do {
            token = try tokenStore.load()
            tokenBox.token = token
        } catch {
            state = .failed("Couldn't create the API token: \(error.localizedDescription)")
            return
        }
        let box = tokenBox
        guard let api = makeAPI({ box.token }) else {
            state = .failed("Library isn't open")
            return
        }
        let server = LocalAPIServer { request in api.handle(request) }
        server.onStateChange = { [weak self] newState in
            Task { @MainActor in
                self?.state = newState
                switch newState {
                case .running(let port): Log.shared.info("local API listening on 127.0.0.1:\(port)", "api")
                case .failed(let message): Log.shared.error("local API failed: \(message)", "api")
                case .stopped: break
                }
            }
        }
        self.server = server
        do {
            try server.start(port: port)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    public func stop() {
        server?.stop()
        server = nil
        state = .stopped
    }

    public func regenerateToken() {
        do {
            token = try tokenStore.regenerate()
            tokenBox.token = token
            Log.shared.info("local API token regenerated", "api")
        } catch {
            state = .failed("Couldn't create the API token: \(error.localizedDescription)")
        }
    }

    /// Ready-to-paste Python (uses the bundled client).
    public var pythonSnippet: String {
        """
        import minibrain  # clients/python/minibrain.py (no dependencies)
        mb = minibrain.MiniBrain()  # reads the token file automatically
        mb.add(type="Products", title="Sony WH-1000XM5",
               url="amazon.com/dp/B09XS7JWHH", image="headphones.jpg",
               fields={"Price": 349}, tags=["audio"])
        print(mb.search("type:Products"))
        """
    }

    public var curlSnippet: String {
        """
        curl -s \(baseURL)/items \\
          -H "Authorization: Bearer $(cat "\(tokenStore.fileURL.path)")" \\
          -H "Content-Type: application/json" \\
          -d '{"type": "Products", "title": "Kindle", "fields": {"Price": "99"}}'
        """
    }
}

extension LocalAPIServer.State {
    var runningPort: UInt16? {
        if case .running(let port) = self { return port }
        return nil
    }
}

struct LocalAPISettingsTab: View {
    @Bindable var controller: LocalAPIController
    let reveal: (URL) -> Void
    @State private var portText = ""
    @State private var portError: String?
    @State private var showToken = false
    @State private var copied: String?

    var body: some View {
        Form {
            Section {
                Toggle("Enable local API", isOn: Binding(get: { controller.isEnabled }, set: { controller.setEnabled($0) }))
                Text("Lets scripts on this Mac (Python, shell, Shortcuts) add and search items, including custom types. Only reachable from this Mac (127.0.0.1); every request needs the token below.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                status
            }
            Section("Connection") {
                HStack {
                    Text("Port")
                    Spacer()
                    TextField("Port", text: $portText)
                        .labelsHidden()
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                        .onSubmit(savePort)
                }
                if let portError { Text(portError).font(.caption).foregroundStyle(.red) }
                HStack {
                    Text("Token")
                    Spacer()
                    Text(showToken ? controller.token : Self.masked(controller.token))
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button(showToken ? "Hide" : "Show") { showToken.toggle() }
                    Button(copied == "token" ? "Copied" : "Copy") { copy(controller.token, "token") }
                    Button("Regenerate") { controller.regenerateToken() }
                        .help("Old scripts stop working until they use the new token")
                }
                .disabled(controller.token.isEmpty)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Token file")
                        Text(controller.tokenStore.fileURL.path)
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button("Reveal in Finder") { reveal(controller.tokenStore.fileURL) }
                        .disabled(controller.token.isEmpty)
                }
            }
            Section("Use it from Python") {
                snippet(controller.pythonSnippet, id: "python")
                HStack {
                    Text("Endpoints: GET /types · POST /items · GET /items?q= · GET /items/{id} · GET /health")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let client = Bundle.main.url(forResource: "minibrain", withExtension: "py") {
                        Button("Show Python Client") { reveal(client) }
                    }
                }
                snippet(controller.curlSnippet, id: "curl")
            }
        }
        .formStyle(.grouped)
        .onAppear { portText = String(controller.preferences.localAPIPort) }
    }

    @ViewBuilder private var status: some View {
        HStack(spacing: 6) {
            switch controller.state {
            case .running:
                Circle().fill(.green).frame(width: 8, height: 8)
                Text("Running at \(controller.baseURL)").font(.callout.monospaced())
            case .failed(let message):
                Circle().fill(.red).frame(width: 8, height: 8)
                Text(message).font(.callout).foregroundStyle(.red)
            case .stopped:
                Circle().fill(.secondary).frame(width: 8, height: 8)
                Text("Off").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func snippet(_ code: String, id: String) -> some View {
        ZStack(alignment: .topTrailing) {
            Text(code)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            Button(copied == id ? "Copied" : "Copy") { copy(code, id) }
                .controlSize(.small)
                .padding(6)
        }
    }

    private func savePort() {
        guard let port = Int(portText.trimmingCharacters(in: .whitespaces)), controller.setPort(port) else {
            portError = "Use a port between 1024 and 65535"
            return
        }
        portError = nil
    }

    private func copy(_ text: String, _ id: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = id
    }

    static func masked(_ token: String) -> String {
        token.isEmpty ? "—" : String(repeating: "•", count: 12) + token.suffix(4)
    }
}
