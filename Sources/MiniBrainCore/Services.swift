import Foundation

/// Which local AI capabilities are available on this Mac.
public struct LocalAIServices: Sendable {
    public var tagger: (any Tagger)?
    public var fallbackTagger: any Tagger
    public var imageTagger: (any ImageTagger)?
    public var embedder: (any Embedder)?
    public var translator: (any QueryTranslator)?

    public init(tagger: (any Tagger)?, fallbackTagger: any Tagger = KeywordTagger(), imageTagger: (any ImageTagger)?,
                embedder: (any Embedder)?, translator: (any QueryTranslator)?) {
        self.tagger = tagger
        self.fallbackTagger = fallbackTagger
        self.imageTagger = imageTagger
        self.embedder = embedder
        self.translator = translator
    }

    /// Real services. Availability is re-checked at use time, so turning on
    /// Apple Intelligence later starts working without a relaunch.
    public static func make() -> LocalAIServices {
        LocalAIServices(
            tagger: FoundationModelsTagger(),
            imageTagger: ImageTaggerFactory.make(),
            embedder: ContextualEmbedder(),
            translator: FoundationModelsTranslator())
    }
}

public enum EnrichmentPipeline {
    public static func processors(services: LocalAIServices,
                                  ocrEnabled: @escaping @Sendable () -> Bool = { true },
                                  linkPreviewsEnabled: @escaping @Sendable () -> Bool = { true },
                                  autoTagEnabled: @escaping @Sendable () -> Bool = { true },
                                  optimizeImages: @escaping @Sendable () -> Bool = { true },
                                  linkFetcher: any LinkPreviewFetching = LinkPresentationFetcher()) -> [any EnrichmentProcessor] {
        var list: [any EnrichmentProcessor] = [
            PDFTextProcessor(), OCRProcessor(isEnabled: ocrEnabled), ColorProcessor(),
            LinkPreviewProcessor(fetcher: linkFetcher, isEnabled: linkPreviewsEnabled, optimizeImages: optimizeImages),
            ImageOptimizeProcessor(isEnabled: optimizeImages),
            AITagProcessor(primary: services.tagger, fallback: services.fallbackTagger, isEnabled: autoTagEnabled),
        ]
        if let imageTagger = services.imageTagger {
            list.append(ImageTagProcessor(tagger: imageTagger, isEnabled: autoTagEnabled))
        }
        if let embedder = services.embedder { list.append(EmbeddingProcessor(embedder: embedder)) }
        return list
    }
}

/// What the library search bar uses: natural-language translation for
/// sentence-like queries (when Apple Intelligence is on), then hybrid
/// FTS + vector search.
public struct SmartSearch: Sendable {
    public let hybrid: HybridSearchService
    public let nl: NLQueryService
    public let parser: QueryParser

    public init(database: AppDatabase, embedder: (any Embedder)?, translator: (any QueryTranslator)?,
                parser: QueryParser = QueryParser(), clock: any Clock = SystemClock()) {
        self.parser = parser
        self.hybrid = HybridSearchService(database: database, embedder: embedder, parser: parser)
        self.nl = NLQueryService(translator: translator, mapper: NLQueryMapper(parser: parser), clock: clock)
    }

    public func search(_ text: String, limit: Int = 100) async throws -> [SearchResult] {
        let parsed = try parser.parse(text)
        if NLQueryService.looksNatural(text, parsed: parsed), nl.translator?.isAvailable == true {
            let (query, _) = await nl.query(for: text)
            return try await hybrid.search(query, limit: limit)
        }
        return try await hybrid.search(parsed, limit: limit)
    }
}
