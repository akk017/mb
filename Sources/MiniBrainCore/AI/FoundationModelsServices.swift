import Foundation
import FoundationModels

// The roadmap specifies `@Generable` structs. The Generable macro plugin ships
// only with Xcode, so these types conform to `Generable` by hand — the same
// schema the macro would synthesize — and build with Command Line Tools too.

/// Structured output for tagging.
struct GeneratedTags: Generable {
    var tags: [String]
    var category: String
    var colors: [String]
    var price: Double?
    var summary: String

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: GeneratedTags.self, description: "Tags and metadata for a saved item", properties: [
            .init(name: "tags", description: "Up to 8 short lowercase topical tags", type: [String].self,
                  guides: [.maximumCount(8)]),
            .init(name: "category", description: "One broad category, e.g. furniture, recipe, article, receipt",
                  type: String.self),
            .init(name: "colors", description: "Main colors mentioned or shown, lowercase names", type: [String].self,
                  guides: [.maximumCount(3)]),
            .init(name: "price", description: "Price in the item's currency if one is clearly stated",
                  type: Double?.self),
            .init(name: "summary", description: "One-sentence summary", type: String.self),
        ])
    }

    init(tags: [String], category: String, colors: [String], price: Double?, summary: String) {
        self.tags = tags
        self.category = category
        self.colors = colors
        self.price = price
        self.summary = summary
    }

    init(_ content: GeneratedContent) throws {
        tags = try content.value([String].self, forProperty: "tags")
        category = try content.value(String.self, forProperty: "category")
        colors = try content.value([String].self, forProperty: "colors")
        price = try content.value(Double?.self, forProperty: "price")
        summary = try content.value(String.self, forProperty: "summary")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: [
            "tags": tags, "category": category, "colors": colors, "price": price, "summary": summary,
        ])
    }

    var suggestion: TagSuggestion {
        TagSuggestion(tags: tags, category: category, colors: colors, price: price, summary: summary)
    }
}

/// Structured output for natural-language search.
struct GeneratedQuery: Generable {
    var keywords: [String]
    var type: String
    var tags: [String]
    var color: String
    var after: String
    var before: String
    var maxPrice: Double?
    var minPrice: Double?

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: GeneratedQuery.self, description: "A structured search over saved items", properties: [
            .init(name: "keywords", description: "Important search words, without filler words", type: [String].self,
                  guides: [.maximumCount(6)]),
            .init(name: "type", description: "One of: any, text, link, image, pdf", type: String.self),
            .init(name: "tags", description: "Tags explicitly requested", type: [String].self, guides: [.maximumCount(3)]),
            .init(name: "color", description: "A color name if requested, else empty", type: String.self),
            .init(name: "after", description: "Start date YYYY-MM-DD if a time range is requested, else empty",
                  type: String.self),
            .init(name: "before", description: "End date YYYY-MM-DD (exclusive) if requested, else empty",
                  type: String.self),
            .init(name: "maxPrice", description: "Upper price bound if requested", type: Double?.self),
            .init(name: "minPrice", description: "Lower price bound if requested", type: Double?.self),
        ])
    }

    init(_ content: GeneratedContent) throws {
        keywords = try content.value([String].self, forProperty: "keywords")
        type = try content.value(String.self, forProperty: "type")
        tags = try content.value([String].self, forProperty: "tags")
        color = try content.value(String.self, forProperty: "color")
        after = try content.value(String.self, forProperty: "after")
        before = try content.value(String.self, forProperty: "before")
        maxPrice = try content.value(Double?.self, forProperty: "maxPrice")
        minPrice = try content.value(Double?.self, forProperty: "minPrice")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: [
            "keywords": keywords, "type": type, "tags": tags, "color": color,
            "after": after, "before": before, "maxPrice": maxPrice, "minPrice": minPrice,
        ])
    }

    var translated: TranslatedQuery {
        TranslatedQuery(keywords: keywords, type: type, tags: tags, color: color,
                        after: after, before: before, maxPrice: maxPrice, minPrice: minPrice)
    }
}

public enum AppleIntelligence {
    public static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    public static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(let reason): String(describing: reason)
        }
    }
}

/// Foundation Models tagger (on-device Apple Intelligence).
public struct FoundationModelsTagger: Tagger {
    public init() {}

    public var isAvailable: Bool { AppleIntelligence.isAvailable }

    public func suggest(for input: TaggerInput) async throws -> TagSuggestion {
        guard isAvailable else { throw MiniBrainError.modelUnavailable(AppleIntelligence.unavailableReason ?? "unavailable") }
        let session = LanguageModelSession(instructions: """
            You organize a personal library of saved links, notes, images and documents. \
            Suggest concise lowercase tags a person would search for. Only state a price if it appears in the content.
            """)
        let response = try await session.respond(to: input.promptText, generating: GeneratedTags.self)
        return response.content.suggestion
    }
}

/// Foundation Models natural-language → structured query translator.
public struct FoundationModelsTranslator: QueryTranslator {
    public init() {}

    public var isAvailable: Bool { AppleIntelligence.isAvailable }

    public func translate(_ sentence: String, today: Date) async throws -> TranslatedQuery {
        guard isAvailable else { throw MiniBrainError.modelUnavailable(AppleIntelligence.unavailableReason ?? "unavailable") }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let session = LanguageModelSession(instructions: """
            Convert a request for saved items into a structured search. Today is \(f.string(from: today)). \
            Use type "any" unless the user names a kind of item. Leave fields empty when not requested.
            """)
        let response = try await session.respond(to: sentence, generating: GeneratedQuery.self)
        return response.content.translated
    }
}
