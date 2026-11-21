import Foundation

/// Parses the search bar syntax:
///
///     words "quoted phrases" type:image tag:work tag:"two words"
///     after:2024-01-01 before:2024-12-31 color:red meta.price<100
///
/// - Unknown `key:value` filters are treated as plain words.
/// - Invalid dates or types throw `MiniBrainError.invalidQuery`.
/// - `after:` is inclusive (from start of that day), `before:` exclusive.
public struct QueryParser: Sendable {
    public var calendar: Calendar
    /// Resolves `type:<name>` against user-defined custom types.
    public var customTypeExists: @Sendable (String) -> Bool

    public init(timeZone: TimeZone = .current, customTypeExists: @escaping @Sendable (String) -> Bool = { _ in false }) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        self.calendar = cal
        self.customTypeExists = customTypeExists
    }

    static let filterKeys: Set<String> = ["type", "tag", "after", "before", "color"]

    public func parse(_ input: String) throws -> SearchQuery {
        var query = SearchQuery()
        for token in Self.tokenize(input) {
            switch token {
            case .phrase(let p):
                if !p.isEmpty { query.terms.append(.phrase(p)) }
            case .keyValue(let key, let value, _):
                if let filter = try filter(key: key, value: value) {
                    query.filters.append(filter)
                } else {
                    // Unknown filter: keep the literal text as words.
                    query.terms.append(.word(key + ":" + value))
                }
            case .word(let w):
                if let meta = Self.metaFilter(w) {
                    query.filters.append(meta)
                } else {
                    query.terms.append(.word(w))
                }
            }
        }
        return query
    }

    func filter(key rawKey: String, value: String) throws -> SearchFilter? {
        let key = rawKey.lowercased()
        guard Self.filterKeys.contains(key), !value.isEmpty else { return nil }
        switch key {
        case "type":
            // A custom type with this exact name wins over built-in aliases.
            if customTypeExists(value) { return .customType(value) }
            guard let type = Self.itemType(value) else {
                throw MiniBrainError.invalidQuery("unknown type '\(value)'")
            }
            return .type(type)
        case "tag":
            return .tag(value)
        case "color":
            return .color(value.lowercased())
        case "after":
            return .after(try date(value))
        case "before":
            return .before(try date(value))
        default:
            return nil
        }
    }

    static func itemType(_ raw: String) -> ItemType? {
        var v = raw.lowercased()
        if let t = ItemType(rawValue: v) { return t }
        if v.hasSuffix("s") { v.removeLast() }
        switch v {
        case "text", "note": return .text
        case "link", "url", "bookmark": return .link
        case "image", "img", "photo", "picture", "screenshot": return .image
        case "pdf", "document", "doc": return .pdf
        default: return nil
        }
    }

    func date(_ value: String) throws -> Date {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2])
        else { throw MiniBrainError.invalidQuery("invalid date '\(value)' (use YYYY-MM-DD)") }
        let comps = DateComponents(year: y, month: m, day: d)
        guard comps.isValidDate(in: calendar), let date = calendar.date(from: comps) else {
            throw MiniBrainError.invalidQuery("invalid date '\(value)' (use YYYY-MM-DD)")
        }
        return date
    }

    static let metaRegex = try! NSRegularExpression(pattern: #"^meta\.([A-Za-z0-9_]+)(<=|>=|!=|=|<|>|:)(.+)$"#)

    static func metaFilter(_ token: String) -> SearchFilter? {
        let range = NSRange(token.startIndex..., in: token)
        guard let m = metaRegex.firstMatch(in: token, range: range),
              let k = Range(m.range(at: 1), in: token),
              let o = Range(m.range(at: 2), in: token),
              let v = Range(m.range(at: 3), in: token)
        else { return nil }
        let opString = String(token[o])
        let op = opString == ":" ? MetaOperator.eq : MetaOperator(rawValue: opString)!
        var raw = String(token[v])
        if raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") { raw = String(raw.dropFirst().dropLast()) }
        let value: MetaValue = Double(raw).map { .number($0) } ?? .string(raw)
        return .meta(key: String(token[k]), op: op, value: value)
    }

    // MARK: - Tokenizer

    enum Token: Equatable {
        case word(String)
        case phrase(String)
        case keyValue(key: String, value: String, quoted: Bool)
    }

    static func tokenize(_ input: String) -> [Token] {
        var tokens: [Token] = []
        var i = input.startIndex
        func readQuoted(from start: String.Index) -> (String, String.Index) {
            var j = input.index(after: start)
            var out = ""
            while j < input.endIndex, input[j] != "\"" { out.append(input[j]); j = input.index(after: j) }
            if j < input.endIndex { j = input.index(after: j) } // closing quote
            return (out, j)
        }
        while i < input.endIndex {
            let c = input[i]
            if c.isWhitespace { i = input.index(after: i); continue }
            if c == "\"" {
                let (text, next) = readQuoted(from: i)
                tokens.append(.phrase(text.trimmingCharacters(in: .whitespaces)))
                i = next
                continue
            }
            // Bare token; may contain key:"quoted value" or meta.key<op>"value".
            var word = ""
            var quotedValue = false
            while i < input.endIndex, !input[i].isWhitespace {
                if input[i] == "\"" {
                    let (text, next) = readQuoted(from: i)
                    if word.hasPrefix("meta.") { word += "\"\(text)\"" } else { word += text }
                    quotedValue = true
                    i = next
                    continue
                }
                word.append(input[i])
                i = input.index(after: i)
            }
            if !word.hasPrefix("meta."), let colon = word.firstIndex(of: ":"), colon != word.startIndex {
                let key = String(word[..<colon])
                let value = String(word[word.index(after: colon)...])
                if filterKeys.contains(key.lowercased()) {
                    tokens.append(.keyValue(key: key, value: value, quoted: quotedValue))
                    continue
                }
            }
            tokens.append(.word(word))
        }
        return tokens
    }
}
