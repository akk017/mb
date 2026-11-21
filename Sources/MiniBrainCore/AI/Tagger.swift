import Foundation
import NaturalLanguage

public struct TaggerInput: Sendable, Equatable {
    public var type: ItemType
    public var title: String
    public var text: String
    public var url: String?

    public init(type: ItemType, title: String, text: String, url: String? = nil) {
        self.type = type
        self.title = title
        self.text = text
        self.url = url
    }

    public init(item: Item) {
        self.init(type: item.type, title: item.title,
                  text: [item.note, item.content].filter { !$0.isEmpty }.joined(separator: "\n"), url: item.url)
    }

    /// Prompt text, capped so it fits the on-device context window.
    public var promptText: String {
        var s = "Type: \(type.rawValue)\nTitle: \(title)\n"
        if let url { s += "URL: \(url)\n" }
        if !text.isEmpty { s += "Content:\n\(text.prefix(3000))" }
        return s
    }
}

/// Structured tagging output (mirrors the @Generable schema).
public struct TagSuggestion: Sendable, Equatable {
    public var tags: [String]
    public var category: String?
    public var colors: [String]
    public var price: Double?
    public var summary: String?

    public init(tags: [String] = [], category: String? = nil, colors: [String] = [], price: Double? = nil, summary: String? = nil) {
        self.tags = tags
        self.category = category
        self.colors = colors
        self.price = price
        self.summary = summary
    }

    /// Output validation: trimmed/lowercased tags (max 8), sane category,
    /// non-negative price, bounded summary.
    public func validated() -> TagSuggestion {
        func clean(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }
        let category = clean(category)?.lowercased()
        let summary = clean(summary).map { $0.count > 280 ? String($0.prefix(279)) + "…" : $0 }
        let price = price.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let colors = TagValidator.normalize(colors).filter { !$0.contains(" ") || $0.count < 20 }
        return TagSuggestion(tags: TagValidator.normalize(tags), category: category.flatMap { $0.count <= 40 ? $0 : nil },
                             colors: Array(colors.prefix(3)), price: price, summary: summary)
    }
}

public protocol Tagger: Sendable {
    var isAvailable: Bool { get }
    func suggest(for input: TaggerInput) async throws -> TagSuggestion
}

/// Offline fallback when Apple Intelligence is unavailable: most frequent
/// meaningful nouns/words (NaturalLanguage lemmas), no model needed.
public struct KeywordTagger: Tagger {
    public var maxTags: Int

    public init(maxTags: Int = 5) { self.maxTags = maxTags }

    public var isAvailable: Bool { true }

    static let stopwords: Set<String> = [
        "the", "and", "for", "with", "this", "that", "from", "have", "your", "you", "are", "was", "were",
        "will", "would", "about", "into", "over", "also", "just", "than", "then", "them", "they", "their",
        "there", "what", "when", "where", "which", "while", "who", "why", "how", "can", "could", "should",
        "not", "but", "all", "any", "more", "most", "some", "such", "only", "own", "same", "very", "http",
        "https", "www", "com", "html", "image", "text", "link", "pdf", "type", "title", "content", "url",
    ]

    public func suggest(for input: TaggerInput) async throws -> TagSuggestion {
        let text = "\(input.title)\n\(input.title)\n\(input.text)" // title counts double
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
        tagger.string = text
        var counts: [String: Int] = [:]
        var firstSeen: [String: Int] = [:]
        var index = 0
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation, .omitOther]) { tag, range in
            guard tag == .noun || tag == .adjective || tag == .otherWord || tag == nil else { return true }
            let lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue
            let word = (lemma ?? String(text[range])).lowercased()
            guard word.count >= 3, word.count <= 30, !Self.stopwords.contains(word),
                  word.contains(where: \.isLetter), !word.allSatisfy(\.isNumber) else { return true }
            counts[word, default: 0] += 1
            if firstSeen[word] == nil { firstSeen[word] = index }
            index += 1
            return true
        }
        let ranked = counts.keys.sorted {
            counts[$0]! != counts[$1]! ? counts[$0]! > counts[$1]! : firstSeen[$0]! < firstSeen[$1]!
        }
        return TagSuggestion(tags: Array(ranked.prefix(maxTags)))
    }
}

/// `ai_tags` job: primary tagger (Foundation Models) or fallback when it's
/// unavailable. Output is validated before it touches the DB.
public struct AITagProcessor: EnrichmentProcessor {
    public let kind = EnrichmentKind.aiTags
    public let primary: (any Tagger)?
    public let fallback: any Tagger

    /// Checked at run time ("Auto-tag every drop").
    public let isEnabled: @Sendable () -> Bool

    public init(primary: (any Tagger)?, fallback: any Tagger = KeywordTagger(),
                isEnabled: @escaping @Sendable () -> Bool = { true }) {
        self.primary = primary
        self.fallback = fallback
        self.isEnabled = isEnabled
    }

    public func activeTagger() -> any Tagger {
        if let primary, primary.isAvailable { return primary }
        return fallback
    }

    public func process(_ item: Item, context: EnrichmentContext) async throws -> EnrichmentResult {
        guard isEnabled() else { return .empty }
        let input = TaggerInput(item: item)
        let usesPrimary = primary?.isAvailable == true
        let raw: TagSuggestion
        do {
            raw = try await activeTagger().suggest(for: input)
        } catch {
            guard usesPrimary else { throw error }
            raw = try await fallback.suggest(for: input) // model failed mid-flight
        }
        let s = raw.validated()
        var meta: Meta = [:]
        if let category = s.category { meta["category"] = .string(category) }
        if let summary = s.summary { meta["summary"] = .string(summary) }
        if let price = s.price { meta["price"] = .number(price) }
        if !s.colors.isEmpty, item.type != .image { meta["colors"] = .array(s.colors.map { .string($0) }) }
        return EnrichmentResult(meta: meta, aiTags: s.tags)
    }
}
