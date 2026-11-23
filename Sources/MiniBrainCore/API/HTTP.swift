import Foundation

/// A parsed HTTP/1.1 request (just what the local API needs).
public struct HTTPRequest: Sendable, Equatable {
    public var method: String
    /// Path plus query string, as sent ("/items?q=x").
    public var target: String
    /// Header names lowercased.
    public var headers: [String: String]
    public var body: Data

    public init(method: String, target: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method.uppercased()
        self.target = target
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, b in b })
        self.body = body
    }

    public var path: String {
        URLComponents(string: target)?.path ?? String(target.prefix { $0 != "?" })
    }

    public var query: [String: String] {
        var out: [String: String] = [:]
        for item in URLComponents(string: target)?.queryItems ?? [] { out[item.name] = item.value ?? "" }
        return out
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// JSON body (sorted keys, so output is stable).
    public static func json(_ status: Int, _ object: Any) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json; charset=utf-8"], body: data)
    }

    public static func error(_ status: Int, _ message: String) -> HTTPResponse {
        json(status, ["error": message])
    }

    public static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 411: "Length Required"
        case 413: "Payload Too Large"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        default: "Status"
        }
    }

    public func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        var all = headers
        all["Content-Length"] = "\(body.count)"
        all["Connection"] = "close"
        for key in all.keys.sorted() { head += "\(key): \(all[key]!)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }
}

/// Incremental parser: feed everything received so far.
public enum HTTPRequestParser {
    public enum Result: Sendable, Equatable {
        case incomplete
        case complete(HTTPRequest, consumed: Int)
        case invalid(Int, String)
    }

    public static let maxHeaderBytes = 32 * 1024

    public static func parse(_ data: Data, maxBodyBytes: Int = 30 * 1024 * 1024) -> Result {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = data.range(of: separator) else {
            return data.count > maxHeaderBytes ? .invalid(400, "Headers too large") : .incomplete
        }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else {
            return .invalid(400, "Malformed request")
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1."), requestLine[1].hasPrefix("/") else {
            return .invalid(400, "Malformed request line")
        }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .invalid(400, "Malformed header") }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil { return .invalid(411, "Send a Content-Length (chunked bodies aren't supported)") }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .invalid(400, "Bad Content-Length") }
        guard length <= maxBodyBytes else { return .invalid(413, "Body larger than \(maxBodyBytes / 1_048_576) MB") }
        let bodyStart = end.upperBound
        guard data.distance(from: bodyStart, to: data.endIndex) >= length else { return .incomplete }
        let bodyEnd = data.index(bodyStart, offsetBy: length)
        let request = HTTPRequest(method: String(requestLine[0]), target: String(requestLine[1]),
                                  headers: headers, body: Data(data[bodyStart..<bodyEnd]))
        return .complete(request, consumed: data.distance(from: data.startIndex, to: bodyEnd))
    }
}
