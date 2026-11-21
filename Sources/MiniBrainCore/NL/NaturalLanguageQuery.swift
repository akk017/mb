import Foundation

/// Model output for a natural-language query (plain values; the
/// Foundation Models `GeneratedQuery` converts into this).
public struct TranslatedQuery: Sendable, Equatable {
    public var keywords: [String]
    public var type: String
    public var tags: [String]
    public var color: String
    public var after: String
    public var before: String
    public var maxPrice: Double?
    public var minPrice: Double?

    public init(keywords: [String] = [], type: String = "any", tags: [String] = [], color: String = "",
                after: String = "", before: String = "", maxPrice: Double? = nil, minPrice: Double? = nil) {
        self.keywords = keywords
        self.type = type
        self.tags = tags
        self.color = color
        self.after = after
        self.before = before
        self.maxPrice = maxPrice
        self.minPrice = minPrice
    }
}

public protocol QueryTranslator: Sendable {
    var isAvailable: Bool { get }
    func translate(_ sentence: String, today: Date) async throws -> TranslatedQuery
}

/// Validates model output and maps it onto the same AST the query parser
/// produces. Anything malformed throws `invalidModelOutput`.
public struct NLQueryMapper: Sendable {
    public let parser: QueryParser
    public static let knownColors: Set<String> = [
        "red", "orange", "yellow", "green", "blue", "purple", "pink", "brown", "black", "white", "gray", "grey",
    ]

    public init(parser: QueryParser = QueryParser()) { self.parser = parser }

    public func map(_ t: TranslatedQuery) throws -> SearchQuery {
        var query = SearchQuery()
        for raw in t.keywords {
            let k = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty else { continue }
            guard k.count <= 60 else { throw MiniBrainError.invalidModelOutput("keyword too long") }
            query.terms.append(k.contains(" ") ? .phrase(k) : .word(k))
        }
        let type = t.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !["", "any", "all", "none"].contains(type) {
            if parser.customTypeExists(type) {
                query.filters.append(.customType(type))
            } else {
                guard let itemType = QueryParser.itemType(type) else {
                    throw MiniBrainError.invalidModelOutput("unknown type '\(t.type)'")
                }
                query.filters.append(.type(itemType))
            }
        }
        for tag in TagValidator.normalize(t.tags) { query.filters.append(.tag(tag)) }
        let color = t.color.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !color.isEmpty {
            guard Self.knownColors.contains(color) else { throw MiniBrainError.invalidModelOutput("unknown color '\(color)'") }
            query.filters.append(.color(color == "grey" ? "gray" : color))
        }
        do {
            if !t.after.isBlank { query.filters.append(.after(try parser.date(t.after.trimmingCharacters(in: .whitespaces)))) }
            if !t.before.isBlank { query.filters.append(.before(try parser.date(t.before.trimmingCharacters(in: .whitespaces)))) }
        } catch {
            throw MiniBrainError.invalidModelOutput("bad date")
        }
        if let min = t.minPrice {
            guard min.isFinite, min >= 0 else { throw MiniBrainError.invalidModelOutput("bad price") }
            query.filters.append(.meta(key: "price", op: .ge, value: .number(min)))
        }
        if let max = t.maxPrice {
            guard max.isFinite, max >= 0 else { throw MiniBrainError.invalidModelOutput("bad price") }
            query.filters.append(.meta(key: "price", op: .le, value: .number(max)))
        }
        guard !query.isEmpty else { throw MiniBrainError.invalidModelOutput("empty query") }
        return query
    }
}

/// Sentence → SearchQuery via the translator, falling back to plain FTS
/// over the sentence's meaningful words whenever translation fails.
public struct NLQueryService: Sendable {
    public let translator: (any QueryTranslator)?
    public let mapper: NLQueryMapper
    public let clock: any Clock

    public init(translator: (any QueryTranslator)?, mapper: NLQueryMapper = NLQueryMapper(), clock: any Clock = SystemClock()) {
        self.translator = translator
        self.mapper = mapper
        self.clock = clock
    }

    public enum Source: Equatable, Sendable { case model, fallback }

    public func query(for sentence: String) async -> (query: SearchQuery, source: Source) {
        if let translator, translator.isAvailable,
           let translated = try? await translator.translate(sentence, today: clock.now),
           let query = try? mapper.map(translated) {
            return (query, .model)
        }
        return (Self.fallback(sentence), .fallback)
    }

    static let fillerWords: Set<String> = [
        "a", "an", "the", "show", "me", "find", "my", "i", "that", "which", "with", "from", "of", "for", "in",
        "on", "to", "and", "or", "all", "some", "saved", "save", "stuff", "things", "items", "please", "about",
        "what", "where", "did", "do", "was", "were", "is", "are", "those", "these", "it", "any",
    ]

    /// Plain full-text query from the sentence's non-filler words.
    public static func fallback(_ sentence: String) -> SearchQuery {
        let words = sentence.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !fillerWords.contains($0) }
        return SearchQuery(terms: words.map { .word($0) })
    }

    /// Heuristic: a question-like sentence without explicit filter syntax.
    public static func looksNatural(_ text: String, parsed: SearchQuery) -> Bool {
        guard parsed.filters.isEmpty, !parsed.terms.contains(where: { if case .phrase = $0 { true } else { false } }) else {
            return false
        }
        let words = parsed.terms.map { $0.text.lowercased() }
        guard words.count >= 4 else { return false }
        return words.contains(where: fillerWords.contains) || words.contains { ["last", "under", "before", "after", "since", "week", "month", "year"].contains($0) }
    }
}
