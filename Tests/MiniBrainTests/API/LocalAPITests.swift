import Foundation
import GRDB
import Testing
@testable import MiniBrainCore

// MARK: - Helpers

private let token = "test-token-123"
private let port: UInt16 = 7777

private func request(_ method: String, _ path: String, json: Any? = nil, body: Data? = nil,
                     headers: [String: String] = [:], auth: Bool = true) -> HTTPRequest {
    var h = ["host": "127.0.0.1:\(port)"]
    if auth { h["authorization"] = "Bearer \(token)" }
    for (k, v) in headers { h[k.lowercased()] = v }
    let data = body ?? json.map { try! JSONSerialization.data(withJSONObject: $0) } ?? Data()
    return HTTPRequest(method: method, target: path, headers: h, body: data)
}

private func object(_ r: HTTPResponse) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: r.body) as? [String: Any])
}

final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _n = 0
    var n: Int { lock.withLock { _n } }
    func hit() { lock.withLock { _n += 1 } }
}

struct APIFixture {
    let env: TestEnv
    let types: CustomTypeRepository
    let api: LocalAPI
    let changes: ChangeCounter
    let products: CustomType

    init() throws {
        env = try TestEnv()
        types = CustomTypeRepository(database: env.db, clock: env.clock)
        products = try types.create(name: "Products", fields: [
            FieldDefinition(id: "price", name: "Price", kind: .text),
            FieldDefinition(id: "link", name: "Buy Link", kind: .webLink),
            FieldDefinition(id: "desc", name: "Description", kind: .largeText),
        ])
        let changes = ChangeCounter()
        self.changes = changes
        let types = types
        api = LocalAPI(
            capture: CaptureService(database: env.db, blobs: env.blobs, clock: env.clock),
            repository: env.repo, customTypes: types,
            search: SearchService(database: env.db, parser: QueryParser(customTypeExists: { types.exists(named: $0) })),
            token: { token }, onChange: { changes.hit() })
    }
}

// MARK: - HTTP parsing

@Suite struct HTTPRequestParserTests {
    @Test func parsesGetWithQuery() throws {
        let raw = Data("GET /items?q=tag%3Ago&limit=5 HTTP/1.1\r\nHost: 127.0.0.1:7777\r\nAuthorization: Bearer x\r\n\r\n".utf8)
        guard case .complete(let req, let used) = HTTPRequestParser.parse(raw) else { Issue.record("not complete"); return }
        #expect(used == raw.count)
        #expect(req.method == "GET")
        #expect(req.path == "/items")
        #expect(req.query == ["q": "tag:go", "limit": "5"])
        #expect(req.headers["authorization"] == "Bearer x")
    }

    @Test func waitsForWholeBodyAcrossChunks() {
        let body = #"{"title":"x"}"#
        let head = "POST /items HTTP/1.1\r\nHost: h\r\nContent-Length: \(body.utf8.count)\r\n\r\n"
        let partial = Data((head + String(body.prefix(4))).utf8)
        guard case .incomplete = HTTPRequestParser.parse(partial) else { Issue.record("should wait"); return }
        guard case .complete(let req, _) = HTTPRequestParser.parse(Data((head + body).utf8)) else { Issue.record("not complete"); return }
        #expect(String(decoding: req.body, as: UTF8.self) == body)
    }

    @Test func rejectsOversizedChunkedAndGarbage() {
        let big = Data("POST /items HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n".utf8)
        guard case .invalid(413, _) = HTTPRequestParser.parse(big, maxBodyBytes: 1000) else { Issue.record("413"); return }
        let chunked = Data("POST /items HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        guard case .invalid(411, _) = HTTPRequestParser.parse(chunked) else { Issue.record("411"); return }
        guard case .invalid(400, _) = HTTPRequestParser.parse(Data("nonsense\r\n\r\n".utf8)) else { Issue.record("400"); return }
    }

    @Test func serializesResponse() {
        let text = String(decoding: HTTPResponse.json(201, ["ok": true]).serialized(), as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 201 Created\r\n"))
        #expect(text.contains("Content-Type: application/json; charset=utf-8\r\n"))
        #expect(text.contains("Connection: close\r\n"))
        #expect(text.hasSuffix("\r\n\r\n{\"ok\":true}"))
    }
}

// MARK: - Security

@Suite struct LocalAPISecurityTests {
    @Test func healthNeedsNoTokenEverythingElseDoes() throws {
        let f = try APIFixture()
        #expect(f.api.handle(request("GET", "/health", auth: false)).status == 200)
        #expect(f.api.handle(request("GET", "/types", auth: false)).status == 401)
        #expect(f.api.handle(request("GET", "/types", headers: ["Authorization": "Bearer wrong"], auth: false)).status == 401)
        #expect(f.api.handle(request("GET", "/types")).status == 200)
    }

    @Test func browsersAndForeignHostsAreRefused() throws {
        let f = try APIFixture()
        // A web page can't call the API (DNS rebinding / CSRF).
        #expect(f.api.handle(request("GET", "/types", headers: ["Origin": "https://evil.example"])).status == 403)
        #expect(f.api.handle(request("GET", "/types", headers: ["Host": "evil.example:7777"])).status == 403)
        #expect(f.api.handle(request("GET", "/types", headers: ["Host": "localhost:7777"])).status == 200)
    }

    @Test func unknownRoutesAndMethods() throws {
        let f = try APIFixture()
        #expect(f.api.handle(request("GET", "/nope")).status == 404)
        #expect(f.api.handle(request("DELETE", "/items")).status == 405)
    }
}

// MARK: - Endpoints

@Suite struct LocalAPIEndpointTests {
    @Test func listsTypesWithFields() throws {
        let f = try APIFixture()
        let r = f.api.handle(request("GET", "/types"))
        let types = try #require(try object(r)["types"] as? [[String: Any]])
        #expect(types.count == 1)
        #expect(types[0]["name"] as? String == "Products")
        let fields = try #require(types[0]["fields"] as? [[String: Any]])
        #expect(fields.map { $0["name"] as? String } == ["Price", "Buy Link", "Description"])
        #expect(fields.map { $0["kind"] as? String } == ["text", "web_link", "large_text"])
    }

    @Test func addsItemToCustomTypeWithFieldsTitleAndTags() throws {
        let f = try APIFixture()
        let r = f.api.handle(request("POST", "/items", json: [
            "type": "products", // case-insensitive
            "title": "Sony WH-1000XM5",
            "text": "Noise cancelling headphones",
            "fields": ["Price": 349, "buy link": "amazon.com/dp/B09XS7JWHH", "Description": "Black"],
            "tags": ["audio", " Wishlist "],
        ]))
        #expect(r.status == 201, "\(String(decoding: r.body, as: UTF8.self))")
        let body = try object(r)
        let id = try #require(body["id"] as? String)
        let saved = try #require(try f.env.repo.fetch(id))
        #expect(saved.title == "Sony WH-1000XM5")
        #expect(saved.customTypeID == f.products.id)
        #expect(saved.fieldValues["price"] == "349")
        #expect(saved.fieldValues["link"] == "amazon.com/dp/B09XS7JWHH")
        #expect(saved.fieldValues["desc"] == "Black")
        #expect(Set(try f.env.repo.tags(for: id).map(\.name)) == ["audio", "Wishlist"])
        #expect(body["custom_type"] as? String == "Products")
        #expect((body["fields"] as? [String: String])?["Price"] == "349")
        #expect(f.changes.n == 1) // library refreshes
    }

    @Test func urlBecomesLinkAndQueuesPreview() throws {
        let f = try APIFixture()
        let r = f.api.handle(request("POST", "/items", json: ["url": "blog.arrtcle.com/post", "text": "read later"]))
        #expect(r.status == 201)
        let id = try #require(try object(r)["id"] as? String)
        let saved = try #require(try f.env.repo.fetch(id))
        #expect(saved.type == .link)
        #expect(saved.url == "https://blog.arrtcle.com/post")
        #expect(saved.note == "read later") // text alongside a URL becomes the note
        #expect(try jobs(f.env, id).contains { $0.kind == .linkPreview })
    }

    @Test func imageBase64BecomesImageItem() throws {
        let f = try APIFixture()
        let png = try Fixtures.data("red.png")
        let r = f.api.handle(request("POST", "/items", json: ["image_base64": png.base64EncodedString(), "title": "Red"]))
        #expect(r.status == 201)
        let imageID = try #require(try object(r)["id"] as? String)
        let saved = try #require(try f.env.repo.fetch(imageID))
        #expect(saved.type == .image)
        #expect(saved.title == "Red")
        #expect(try f.env.blobs.read(try #require(saved.blobHash)) == png)
    }

    struct BadCase: Sendable, CustomStringConvertible {
        let json: String
        let status: Int
        let message: String
        var description: String { json }
    }

    static let badCases: [BadCase] = [
        BadCase(json: #"{"url": "hello world"}"#, status: 400, message: "valid web address"),
        BadCase(json: #"{"type": "Gadgets", "title": "x"}"#, status: 404, message: "Unknown type 'Gadgets'"),
        BadCase(json: #"{"type": "Products", "title": "x", "fields": {"Colour": "red"}}"#, status: 400, message: "Unknown field 'Colour'"),
        BadCase(json: #"{"title": "x", "fields": {"Price": "1"}}"#, status: 400, message: "fields need a type"),
        BadCase(json: #"{"type": "Products", "title": "x", "fields": {"Buy Link": "not a link"}}"#, status: 400, message: "Buy Link"),
        BadCase(json: "{}", status: 400, message: "Nothing to save"),
        BadCase(json: #"{"image_base64": "%%%"}"#, status: 400, message: "base64"),
        BadCase(json: #"{"image_base64": "aGVsbG8="}"#, status: 400, message: "isn't an image"),
        BadCase(json: #"{"title": "x", "tags": "not-a-list"}"#, status: 400, message: "tags"),
        BadCase(json: #"{"title": 5}"#, status: 400, message: "title must be a string"),
    ]

    @Test(arguments: badCases)
    func invalidRequestsSaveNothing(_ bad: BadCase) throws {
        let f = try APIFixture()
        let r = f.api.handle(request("POST", "/items", body: Data(bad.json.utf8)))
        #expect(r.status == bad.status)
        let error = try #require(try object(r)["error"] as? String)
        #expect(error.contains(bad.message), "\(error)")
        #expect(try f.env.repo.count() == 0)
        #expect(f.changes.n == 0)
    }

    @Test func productWithImageAndBuyLinkKeepsBoth() throws {
        let f = try APIFixture()
        let png = try Fixtures.data("two-color.png")
        let r = f.api.handle(request("POST", "/items", json: [
            "type": "Products", "title": "Sony WH-1000XM5",
            "url": "amazon.com/dp/B09XS7JWHH", "image_base64": png.base64EncodedString(),
            "fields": ["Price": 349],
        ]))
        #expect(r.status == 201, "\(String(decoding: r.body, as: UTF8.self))")
        let id = try #require(try object(r)["id"] as? String)
        let saved = try #require(try f.env.repo.fetch(id))
        #expect(saved.type == .link) // the URL is kept
        #expect(saved.url == "https://amazon.com/dp/B09XS7JWHH")
        #expect(saved.title == "Sony WH-1000XM5")
        #expect(saved.fieldValues["price"] == "349")
        #expect(saved.meta[ItemEditor.customPreviewKey] == true) // the image is its cover
        let cover = try #require(saved.meta["preview_blob"]?.stringValue)
        #expect(f.env.blobs.exists(cover))
        #expect(try object(r)["has_image"] as? Bool == true)
    }

    @Test func textWithImageGetsCover() throws {
        let f = try APIFixture()
        let r = f.api.handle(request("POST", "/items", json: [
            "text": "Recipe: pancakes", "image_base64": try Fixtures.data("red.png").base64EncodedString(),
        ]))
        let textID = try #require(try object(r)["id"] as? String)
        let saved = try #require(try f.env.repo.fetch(textID))
        #expect(saved.type == .text)
        #expect(saved.content == "Recipe: pancakes")
        #expect(saved.meta[ItemEditor.customPreviewKey] == true)
    }

    @Test func imageOnlyProductIsAnImageItemInTheType() throws {
        let f = try APIFixture()
        let r = f.api.handle(request("POST", "/items", json: [
            "type": "Products", "title": "Kindle", "image_base64": try Fixtures.data("red.png").base64EncodedString(),
            "fields": ["Price": "99"],
        ]))
        let kindleID = try #require(try object(r)["id"] as? String)
        let saved = try #require(try f.env.repo.fetch(kindleID))
        #expect(saved.type == .image)
        #expect(saved.customTypeID == f.products.id)
        #expect(saved.title == "Kindle")
        #expect(saved.fieldValues["price"] == "99")
    }

    @Test func malformedJSONIs400() throws {
        let f = try APIFixture()
        #expect(f.api.handle(request("POST", "/items", body: Data("{oops".utf8))).status == 400)
    }

    @Test func searchesAndFetchesItems() throws {
        let f = try APIFixture()
        _ = f.api.handle(request("POST", "/items", json: ["type": "Products", "title": "Kindle", "tags": ["reading"]]))
        _ = f.api.handle(request("POST", "/items", json: ["text": "Grocery list: milk"]))
        let all = try #require(try object(f.api.handle(request("GET", "/items")))["items"] as? [[String: Any]])
        #expect(all.count == 2)
        let found = try #require(try object(f.api.handle(request("GET", "/items?q=type%3AProducts")))["items"] as? [[String: Any]])
        #expect(found.map { $0["title"] as? String } == ["Kindle"])
        let id = try #require(found.first?["id"] as? String)
        #expect(f.api.handle(request("GET", "/items/\(id)")).status == 200)
        #expect(f.api.handle(request("GET", "/items/missing")).status == 404)
    }
}

// MARK: - Token

@Suite struct LocalAPITokenTests {
    @Test func tokenFileIsPrivateStableAndRegeneratable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mb-token-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LocalAPIToken(directory: dir)
        let first = try store.load()
        #expect(first.count >= 40)
        #expect(try store.load() == first)
        let perms = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
        let second = try store.regenerate()
        #expect(second != first)
        #expect(try store.load() == second)
    }
}

// MARK: - Real socket + Python client

@Suite(.serialized) struct LocalAPIServerTests {
    func start(_ f: APIFixture) async throws -> (LocalAPIServer, UInt16) {
        let api = f.api
        let server = LocalAPIServer { req in api.handle(req) }
        try server.start(port: 0)
        let end = Date().addingTimeInterval(5)
        while server.boundPort == nil, Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        return (server, try #require(server.boundPort))
    }

    @Test func servesRealHTTPOnLoopback() async throws {
        let f = try APIFixture()
        let (server, bound) = try await start(f)
        defer { server.stop() }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(bound)/items")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["type": "Products", "title": "Over the wire", "fields": ["Price": "9"]])
        let (data, response) = try await URLSession.shared.data(for: req)
        #expect((response as? HTTPURLResponse)?.statusCode == 201, "\(String(decoding: data, as: UTF8.self))")
        #expect(try f.env.repo.fetchAll().first?.title == "Over the wire")
    }

    @Test func pythonClientImportsAndExportsCSV() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") || FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/python3")
        else { return }
        let f = try APIFixture()
        let (server, bound) = try await start(f)
        defer { server.stop() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pycsv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Fixtures.data("two-color.png").write(to: dir.appendingPathComponent("sony.png"))
        try "Name,Price,URL,Image,Tags\nSony,349,amazon.com/dp/1,sony.png,audio\nKindle,99,,,reading\n"
            .write(to: dir.appendingPathComponent("products.csv"), atomically: true, encoding: .utf8)
        let clientDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("clients/python")
        let script = """
            import json, minibrain
            mb = minibrain.MiniBrain()
            report = mb.import_csv("\(dir.appendingPathComponent("products.csv").path)", type="Products")
            try:
                mb.import_csv("Name,URL\\nBad,hello world\\n", type="Products")
                blocked = None
            except minibrain.MiniBrainError as e:
                blocked = [e.status, e.details["errors"][0]["row"]]
            text = mb.export_csv("\(dir.appendingPathComponent("out.csv").path)", type="Products")
            print(json.dumps({"count": report["imported_count"], "blocked": blocked, "header": text.splitlines()[0]}))
            """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-c", script]
        p.environment = ["MINIBRAIN_API_URL": "http://127.0.0.1:\(bound)", "MINIBRAIN_API_TOKEN": token,
                         "PATH": "/opt/homebrew/bin:/usr/bin:/bin", "PYTHONPATH": clientDir.path]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = await Task.detached { out.fileHandleForReading.readDataToEndOfFile() }.value
        p.waitUntilExit()
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(p.terminationStatus == 0, "\(stderr)")
        let result = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(result["count"] as? Int == 2)
        #expect(result["blocked"] as? [Int] == [400, 2])
        #expect((result["header"] as? String)?.hasPrefix("title,kind,url") == true)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("out.csv").path))
        let sony = try f.env.repo.fetchAll().first { $0.title == "Sony" }
        #expect(sony?.meta[ItemEditor.customPreviewKey] == true) // relative image path → cover
    }

    @Test func pythonClientAddsToCustomType() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") || FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/python3")
        else { return } // no Python on this machine
        let f = try APIFixture()
        let (server, bound) = try await start(f)
        defer { server.stop() }
        let clientDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("clients/python")
        let imagePath = Fixtures.url("two-color.png").path
        let script = """
            import json, minibrain
            IMAGE_PATH = "\(imagePath)"
            mb = minibrain.MiniBrain()
            names = [t["name"] for t in mb.types()]
            item = mb.add(type="Products", title="From Python", fields={"Price": 12.5}, tags=["py"],
                          url="amazon.com/dp/X1", image=IMAGE_PATH)
            found = mb.search("type:Products")
            try:
                mb.add(url="hello world")
                bad = "no error"
            except minibrain.MiniBrainError as e:
                bad = e.status
            print(json.dumps({"types": names, "id": item["id"], "found": [i["title"] for i in found], "bad": bad}))
            """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-c", script]
        p.currentDirectoryURL = clientDir
        p.environment = ["MINIBRAIN_API_URL": "http://127.0.0.1:\(bound)", "MINIBRAIN_API_TOKEN": token,
                         "PATH": "/opt/homebrew/bin:/usr/bin:/bin", "PYTHONPATH": clientDir.path]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        // Read off-main while the server answers on its own queue.
        let data = await Task.detached { out.fileHandleForReading.readDataToEndOfFile() }.value
        p.waitUntilExit()
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(p.terminationStatus == 0, "\(stderr)")
        let result = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(result["types"] as? [String] == ["Products"])
        #expect(result["found"] as? [String] == ["From Python"])
        #expect(result["bad"] as? Int == 400)
        let pyID = try #require(result["id"] as? String)
        let saved = try #require(try f.env.repo.fetch(pyID))
        #expect(saved.fieldValues["price"] == "12.5")
        #expect(saved.type == .link)
        #expect(saved.meta[ItemEditor.customPreviewKey] == true) // image became the cover
    }
}

// MARK: - CSV over the API

@Suite struct LocalAPICSVTests {
    let csv = "Name,Price,URL,Tags\nSony,349,amazon.com/dp/1,audio\nKindle,99,,reading\n"

    @Test func importsRawCSVBodyWithQueryOptions() throws {
        let f = try APIFixture()
        let r = f.api.handle(request("POST", "/import/csv?type=Products", body: Data(csv.utf8),
                                     headers: ["Content-Type": "text/csv"]))
        #expect(r.status == 201, "\(String(decoding: r.body, as: UTF8.self))")
        let body = try object(r)
        #expect(body["imported_count"] as? Int == 2)
        #expect((body["imported"] as? [String])?.count == 2)
        let columns = try #require(body["columns"] as? [[String: Any]])
        #expect(columns.map { $0["maps_to"] as? String } == ["Title", "Price", "URL", "Tags"])
        #expect(try f.env.repo.count() == 2)
        #expect(f.changes.n == 1)
    }

    @Test func importsJSONWrappedCSVAndDryRun() throws {
        let f = try APIFixture()
        let r = f.api.handle(request("POST", "/import/csv", json: ["csv": csv, "type": "Products", "dry_run": true]))
        #expect(r.status == 200)
        let body = try object(r)
        #expect(body["valid_rows"] as? Int == 2)
        #expect(body["dry_run"] as? Bool == true)
        #expect(try f.env.repo.count() == 0)
        #expect(f.changes.n == 0)
    }

    @Test func badRowsBlockTheImportWithDetails() throws {
        let f = try APIFixture()
        let r = f.api.handle(request("POST", "/import/csv", json: ["csv": "Name,URL\nOk,a.com\nBad,hello world\n", "type": "Products"]))
        #expect(r.status == 400)
        let body = try object(r)
        #expect((body["error"] as? String)?.contains("nothing was saved") == true)
        let errors = try #require(body["errors"] as? [[String: Any]])
        #expect(errors.first?["row"] as? Int == 3)
        #expect(try f.env.repo.count() == 0)

        let skipped = f.api.handle(request("POST", "/import/csv", json: ["csv": "Name,URL\nOk,a.com\nBad,hello world\n",
                                                                          "type": "Products", "skip_invalid": true]))
        #expect(skipped.status == 201)
        #expect(try f.env.repo.count() == 1)
    }

    @Test func exportsCSVForAType() throws {
        let f = try APIFixture()
        _ = f.api.handle(request("POST", "/import/csv?type=Products", body: Data(csv.utf8)))
        _ = f.api.handle(request("POST", "/items", json: ["text": "unrelated note"]))
        let r = f.api.handle(request("GET", "/export/csv?type=Products"))
        #expect(r.status == 200)
        #expect(r.headers["Content-Type"] == "text/csv; charset=utf-8")
        #expect(r.headers["Content-Disposition"]?.contains("Products.csv") == true)
        let rows = CSV.parse(String(decoding: r.body, as: UTF8.self))
        #expect(rows.count == 3) // header + 2 products, not the note
        #expect(rows[0].suffix(3) == ["Price", "Buy Link", "Description"])
        #expect(f.api.handle(request("GET", "/export/csv?type=Nope")).status == 404)
        let all = CSV.parse(String(decoding: f.api.handle(request("GET", "/export/csv")).body, as: UTF8.self))
        #expect(all.count == 4)
    }
}
