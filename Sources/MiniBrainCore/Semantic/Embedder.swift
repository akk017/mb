import Foundation
import NaturalLanguage

public protocol Embedder: Sendable {
    var dimension: Int { get }
    func embed(_ text: String) async throws -> [Float]
}

public enum VectorMath {
    public static func normalized(_ v: [Float]) -> [Float] {
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? v.map { $0 / norm } : v
    }

    public static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count)
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        guard na > 0, nb > 0 else { return 1 }
        return 1 - dot / (na.squareRoot() * nb.squareRoot())
    }
}

/// `NLContextualEmbedding` (on-device transformer) with mean pooling over
/// token vectors and L2 normalization. Deterministic for a given input.
public final class ContextualEmbedder: Embedder, @unchecked Sendable {
    private let embedding: NLContextualEmbedding
    private let lock = NSLock()
    private var loaded = false

    public init?(language: NLLanguage = .english) {
        guard let e = NLContextualEmbedding(language: language) else { return nil }
        embedding = e
    }

    public var dimension: Int { embedding.dimension }

    /// Longest text sent to the model; the rest is ignored for embeddings.
    public static let maxCharacters = 2000

    /// Assets are a system-managed model download.
    public var hasAssets: Bool { embedding.hasAvailableAssets }

    public func requestAssets() async -> Bool {
        if embedding.hasAvailableAssets { return true }
        let result = try? await embedding.requestAssets()
        return result == .available
    }

    private func loadIfNeeded() throws {
        try lock.withLock {
            guard !loaded else { return }
            try embedding.load()
            loaded = true
        }
    }

    public func embed(_ text: String) async throws -> [Float] {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return [Float](repeating: 0, count: dimension) }
        guard hasAssets else { throw MiniBrainError.modelUnavailable("NLContextualEmbedding assets not downloaded") }
        try loadIfNeeded()
        // Ranges passed to enumerateTokenVectors must come from the exact
        // string that was embedded (indices of `input` are invalid in a prefix).
        let modelText = String(input.prefix(Self.maxCharacters))
        let result = try lock.withLock { try embedding.embeddingResult(for: modelText, language: nil) }
        var sum = [Double](repeating: 0, count: dimension)
        var count = 0
        result.enumerateTokenVectors(in: modelText.startIndex..<modelText.endIndex) { vector, _ in
            for i in 0..<min(vector.count, sum.count) { sum[i] += vector[i] }
            count += 1
            return true
        }
        guard count > 0 else { return [Float](repeating: 0, count: dimension) }
        return VectorMath.normalized(sum.map { Float($0 / Double(count)) })
    }
}

/// `embedding` job: title + note + content (+ tags) → vec_items.
public struct EmbeddingProcessor: EnrichmentProcessor {
    public let kind = EnrichmentKind.embedding
    public let embedder: any Embedder

    public init(embedder: any Embedder) { self.embedder = embedder }

    public static func text(for item: Item, tags: [ItemTag]) -> String {
        [item.title, item.note, item.content, item.fieldValues.values.sorted().joined(separator: " "),
         tags.map(\.name).joined(separator: " ")]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    public func process(_ item: Item, context: EnrichmentContext) async throws -> EnrichmentResult {
        let vector = try await embedder.embed(Self.text(for: item, tags: context.tags))
        guard vector.count == EmbeddingConfig.dimension else {
            throw MiniBrainError.invalidModelOutput("embedding dimension \(vector.count)")
        }
        return EnrichmentResult(embedding: vector)
    }
}
