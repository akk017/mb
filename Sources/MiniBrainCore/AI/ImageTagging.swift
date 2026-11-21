import CoreImage
import Foundation
import Vision

public protocol ImageTagger: Sendable {
    func tags(forImage data: Data) async throws -> [String]
}

/// A loaded vision-language model (e.g. Qwen2.5-VL 3B via MLX Swift).
public protocol VisionLanguageModel: Sendable {
    func generate(prompt: String, image: Data) async throws -> String
}

/// Loads a heavy model on demand, shares one load between concurrent
/// callers, and unloads it after `idleTimeout` without use.
public actor ModelManager<Model: Sendable> {
    public let idleTimeout: TimeInterval
    private let clock: any Clock
    private let loader: @Sendable () async throws -> Model
    private var model: Model?
    private var loading: Task<Model, Error>?
    private var activeUses = 0
    private var lastUsed: Date?
    private var idleTask: Task<Void, Never>?
    public private(set) var loadCount = 0
    public private(set) var unloadCount = 0

    public init(clock: any Clock = SystemClock(), idleTimeout: TimeInterval = 300,
                loader: @escaping @Sendable () async throws -> Model) {
        self.clock = clock
        self.idleTimeout = idleTimeout
        self.loader = loader
    }

    public var isLoaded: Bool { model != nil }

    /// Runs `body` with the model, loading it first if needed.
    public func withModel<T: Sendable>(_ body: @Sendable (Model) async throws -> T) async throws -> T {
        activeUses += 1
        idleTask?.cancel()
        defer {
            activeUses -= 1
            lastUsed = clock.now
            scheduleIdleUnload()
        }
        let model = try await obtain()
        return try await body(model)
    }

    /// Unloads immediately (e.g. memory pressure).
    public func unload() {
        guard model != nil else { return }
        model = nil
        unloadCount += 1
    }

    private func obtain() async throws -> Model {
        if let model { return model }
        if let loading { return try await loading.value }
        let task = Task { [loader] in try await loader() }
        loading = task
        do {
            let loaded = try await task.value
            model = loaded
            loading = nil
            loadCount += 1
            return loaded
        } catch {
            loading = nil
            throw error
        }
    }

    private func scheduleIdleUnload() {
        idleTask?.cancel()
        guard activeUses == 0, model != nil else { return }
        let timeout = idleTimeout
        idleTask = Task { [clock] in
            do { try await clock.sleep(for: timeout) } catch { return }
            self.unloadIfIdle()
        }
    }

    private func unloadIfIdle() {
        guard activeUses == 0, let lastUsed, clock.now.timeIntervalSince(lastUsed) >= idleTimeout else { return }
        unload()
    }
}

/// Image tagger backed by a vision-language model behind a ModelManager.
public struct VLMImageTagger: ImageTagger {
    public let manager: ModelManager<any VisionLanguageModel>

    public static let prompt = """
        List up to 8 short lowercase tags describing this image (objects, style, setting, colors). \
        Reply with a comma-separated list only.
        """

    public init(manager: ModelManager<any VisionLanguageModel>) { self.manager = manager }

    public func tags(forImage data: Data) async throws -> [String] {
        let raw = try await manager.withModel { model in try await model.generate(prompt: Self.prompt, image: data) }
        return Self.parse(raw)
    }

    static func parse(_ output: String) -> [String] {
        let pieces = output
            .replacingOccurrences(of: #"(?m)^\s*[-*\d.]+\s*"#, with: "", options: .regularExpression)
            .components(separatedBy: CharacterSet(charactersIn: ",\n;"))
        return TagValidator.normalize(pieces)
    }
}

/// Built-in fallback: Vision's on-device image classifier (no download).
public struct VisionClassifierImageTagger: ImageTagger {
    public var minimumConfidence: Float
    public init(minimumConfidence: Float = 0.3) { self.minimumConfidence = minimumConfidence }

    public func tags(forImage data: Data) async throws -> [String] {
        let request = VNClassifyImageRequest()
        try VNImageRequestHandler(data: data, options: [:]).perform([request])
        let labels = (request.results ?? [])
            .filter { $0.confidence >= minimumConfidence }
            .sorted { $0.confidence > $1.confidence }
            .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
        return TagValidator.normalize(labels)
    }
}

/// `image_tags` job.
public struct ImageTagProcessor: EnrichmentProcessor {
    public let kind = EnrichmentKind.imageTags
    public let tagger: any ImageTagger
    public let isEnabled: @Sendable () -> Bool

    public init(tagger: any ImageTagger, isEnabled: @escaping @Sendable () -> Bool = { true }) {
        self.tagger = tagger
        self.isEnabled = isEnabled
    }

    public func process(_ item: Item, context: EnrichmentContext) async throws -> EnrichmentResult {
        guard isEnabled() else { return .empty }
        return EnrichmentResult(aiTags: try await tagger.tags(forImage: try context.blobData(for: item)))
    }
}

#if canImport(MLXVLM) && canImport(MLXLMCommon)
import MLXLMCommon
import MLXVLM

/// Qwen2.5-VL 3B via MLX Swift. Only compiled when the package is built with
/// `MB_WITH_MLX=1` under Xcode (MLX needs the Metal toolchain).
public struct MLXQwenVisionModel: VisionLanguageModel {
    let container: ModelContainer

    public static func load() async throws -> MLXQwenVisionModel {
        let container = try await VLMModelFactory.shared.loadContainer(configuration: VLMRegistry.qwen2_5VL3BInstruct)
        return MLXQwenVisionModel(container: container)
    }

    public func generate(prompt: String, image: Data) async throws -> String {
        guard let ciImage = CIImage(data: image) else { throw MiniBrainError.enrichmentFailed("unreadable image") }
        let result = try await container.perform { context in
            let input = try await context.processor.prepare(input: UserInput(prompt: prompt, images: [.ciImage(ciImage)]))
            return try MLXLMCommon.generate(input: input, parameters: GenerateParameters(temperature: 0.2), context: context) { tokens in
                tokens.count >= 64 ? .stop : .more
            }
        }
        return result.output
    }
}
#endif

public enum ImageTaggerFactory {
    public static var hasVisionLanguageModel: Bool {
        #if canImport(MLXVLM) && canImport(MLXLMCommon)
        true
        #else
        false
        #endif
    }

    /// MLX Qwen2.5-VL when compiled in, otherwise Vision's classifier.
    public static func make(clock: any Clock = SystemClock()) -> any ImageTagger {
        #if canImport(MLXVLM) && canImport(MLXLMCommon)
        let manager = ModelManager<any VisionLanguageModel>(clock: clock) { try await MLXQwenVisionModel.load() }
        return VLMImageTagger(manager: manager)
        #else
        return VisionClassifierImageTagger()
        #endif
    }
}
