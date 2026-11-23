import Foundation
import Testing
@testable import MiniBrainCore
@testable import MiniBrainUI

@Suite(.serialized) @MainActor struct LocalAPIControllerTests {
    func make() throws -> (LocalAPIController, AppPreferences, TestEnv, URL) {
        let env = try TestEnv()
        let prefs = AppPreferences(defaults: makeDefaults())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mb-api-\(UUID().uuidString)")
        let types = CustomTypeRepository(database: env.db, clock: env.clock)
        let controller = LocalAPIController(preferences: prefs, tokenStore: LocalAPIToken(directory: dir), portOverride: 0) { token in
            LocalAPI(capture: CaptureService(database: env.db, blobs: env.blobs, clock: env.clock),
                     repository: env.repo, customTypes: types, search: SearchService(database: env.db), token: token)
        }
        return (controller, prefs, env, dir)
    }

    func waitForState(_ c: LocalAPIController, _ ok: (LocalAPIServer.State) -> Bool) async {
        let end = Date().addingTimeInterval(5)
        while !ok(c.state), Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func status(_ c: LocalAPIController, token: String) async throws -> Int {
        var req = URLRequest(url: URL(string: "\(c.baseURL)/types")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: req)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    @Test func offByDefault() throws {
        let (c, prefs, _, dir) = try make()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!prefs.localAPIEnabled)
        c.apply()
        #expect(c.state == .stopped)
        #expect(c.token.isEmpty) // no token file until it's turned on
    }

    @Test func enableServeRegenerateDisable() async throws {
        let (c, prefs, _, dir) = try make()
        defer { c.stop(); try? FileManager.default.removeItem(at: dir) }
        c.setEnabled(true)
        #expect(prefs.localAPIEnabled)
        await waitForState(c) { $0.runningPort != nil }
        #expect(c.state.runningPort != nil)
        let first = c.token
        #expect(try await status(c, token: first) == 200)

        c.regenerateToken()
        #expect(c.token != first)
        #expect(try await status(c, token: first) == 401) // old scripts stop working
        #expect(try await status(c, token: c.token) == 200)

        c.setEnabled(false)
        #expect(c.state == .stopped)
        #expect(!prefs.localAPIEnabled)
    }

    @Test func portValidation() throws {
        let (c, prefs, _, dir) = try make()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(prefs.localAPIPort == AppPreferences.defaultLocalAPIPort)
        #expect(!c.setPort(80))
        #expect(!c.setPort(70000))
        #expect(c.setPort(8123))
        #expect(prefs.localAPIPort == 8123)
    }

    @Test func busyPortReportsFailure() async throws {
        let blocker = LocalAPIServer { _ in .json(200, [:]) }
        try blocker.start(port: 0)
        defer { blocker.stop() }
        let end = Date().addingTimeInterval(5)
        while blocker.boundPort == nil, Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        let busy = try #require(blocker.boundPort)

        let env = try TestEnv()
        let prefs = AppPreferences(defaults: makeDefaults())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mb-api-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let types = CustomTypeRepository(database: env.db, clock: env.clock)
        let c = LocalAPIController(preferences: prefs, tokenStore: LocalAPIToken(directory: dir), portOverride: busy) { token in
            LocalAPI(capture: CaptureService(database: env.db, blobs: env.blobs, clock: env.clock),
                     repository: env.repo, customTypes: types, search: SearchService(database: env.db), token: token)
        }
        c.setEnabled(true)
        defer { c.stop() }
        await waitForState(c) { if case .failed = $0 { return true } else { return false } }
        guard case .failed(let message) = c.state else { Issue.record("expected failure, got \(c.state)"); return }
        #expect(message.contains("in use"), "\(message)")
    }
}
