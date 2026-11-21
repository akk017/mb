import Foundation
import FoundationModels
import GRDB
import Testing
@testable import MiniBrainCore

// MARK: - Fakes

struct FakeTagger: Tagger {
    var isAvailable = true
    var suggestion = TagSuggestion()
    var error: Error?
    func suggest(for input: TaggerInput) async throws -> TagSuggestion {
        if let error { throw error }
        return suggestion
    }
}

func runAITags(_ processor: AITagProcessor, env: TestEnv, itemID: String) async throws {
    try env.write { try EnrichmentQueue.enqueue(itemID: itemID, kind: .aiTags, now: env.clock.now, in: $0) }
    let worker = EnrichmentWorker(database: env.db, blobs: env.blobs, clock: env.clock, processors: [processor])
    #expect(await worker.runPending() == 1)
    #expect(try jobs(env, itemID).first?.status == .done)
}

// MARK: - T6.1 Tagger

@Suite struct TaggerTests {
    @Test func pipelineWithFakeTagger() async throws {
        let env = try TestEnv()
        let item = try env.makeItem(title: "Eames lounge chair", content: "Rosewood and black leather, $4,995")
        let tagger = FakeTagger(suggestion: TagSuggestion(
            tags: ["Chair", "mid-century", "#Furniture"], category: " Furniture ", colors: ["Black", "brown"],
            price: 4995, summary: "  A classic lounge chair.  "))
        try await runAITags(AITagProcessor(primary: tagger), env: env, itemID: item.id)
        let saved = try #require(try env.repo.fetch(item.id))
        #expect(try env.repo.tags(for: item.id).map(\.name) == ["chair", "furniture", "mid-century"])
        #expect(try env.repo.tags(for: item.id).allSatisfy { $0.source == .ai })
        #expect(saved.meta["category"] == "furniture")
        #expect(saved.meta["price"] == 4995)
        #expect(saved.meta["summary"] == "A classic lounge chair.")
        #expect(saved.meta["colors"] == ["black", "brown"])
        #expect(try SearchService(database: env.db).search("meta.price<5000 tag:chair").map(\.id) == [item.id])
    }

    @Test func outputValidation() {
        let raw = TagSuggestion(
            tags: ["  Alpha ", "BETA", "beta", "", "#gamma", "a   b", "c,", "d", "e", "f", "g", "h", "i",
                   String(repeating: "x", count: 41)],
            category: "", colors: ["Red", "red", "Blue", "Green", "Pink"], price: -3, summary: String(repeating: "s", count: 400))
        let v = raw.validated()
        #expect(v.tags == ["alpha", "beta", "gamma", "a b", "c", "d", "e", "f"])
        #expect(v.tags.count == TagValidator.maxTags)
        #expect(v.category == nil)
        #expect(v.price == nil)
        #expect(v.colors == ["red", "blue", "green"])
        #expect(v.summary?.count == 280)
        #expect(TagValidator.normalize([" Foo ", "foo", "FOO"]) == ["foo"])
    }

    @Test func fallbackWhenAppleIntelligenceUnavailable() async throws {
        let env = try TestEnv()
        let item = try env.makeItem(title: "Sourdough starter", content: "Feed the starter flour and water. Sourdough bread needs a strong starter.")
        let unavailable = FakeTagger(isAvailable: false, suggestion: TagSuggestion(tags: ["should-not-appear"]))
        let processor = AITagProcessor(primary: unavailable)
        #expect(processor.activeTagger() is KeywordTagger)
        try await runAITags(processor, env: env, itemID: item.id)
        let names = try env.repo.tags(for: item.id).map(\.name)
        #expect(!names.contains("should-not-appear"))
        #expect(names.contains("starter"))
        #expect(names.contains("sourdough"))
        #expect(names.count <= 5)
    }

    @Test func fallbackWhenModelFails() async throws {
        let env = try TestEnv()
        let item = try env.makeItem(title: "Kayak trip", content: "Kayak rental near the lake")
        let failing = FakeTagger(error: MiniBrainError.modelUnavailable("guardrail"))
        try await runAITags(AITagProcessor(primary: failing), env: env, itemID: item.id)
        #expect(try env.repo.tags(for: item.id).map(\.name).contains("kayak"))
    }

    @Test func noPrimaryUsesFallback() {
        #expect(AITagProcessor(primary: nil).activeTagger() is KeywordTagger)
        #expect(AITagProcessor(primary: FakeTagger()).activeTagger() is FakeTagger)
    }

    @Test func generableConformanceRoundTrips() throws {
        let tags = GeneratedTags(tags: ["a", "b"], category: "c", colors: ["red"], price: 12, summary: "s")
        let decoded = try GeneratedTags(tags.generatedContent)
        #expect(decoded.suggestion == tags.suggestion)
        let noPrice = try GeneratedTags(GeneratedTags(tags: [], category: "", colors: [], price: nil, summary: "").generatedContent)
        #expect(noPrice.price == nil)
        let schema = GeneratedTags.generationSchema.debugDescription
        for field in ["tags", "category", "colors", "price", "summary"] { #expect(schema.contains(field)) }
    }

    @Test(.tags(.integration), .enabled(if: AppleIntelligence.isAvailable, "Apple Intelligence unavailable"))
    func realFoundationModelTagger() async throws {
        let s = try await FoundationModelsTagger().suggest(for: TaggerInput(
            type: .link, title: "IKEA POÄNG armchair", text: "Birch veneer armchair with cushion, $129", url: "https://ikea.com"))
            .validated()
        #expect(!s.tags.isEmpty)
        #expect(s.tags.count <= 8)
        #expect(s.tags.allSatisfy { $0 == $0.lowercased() })
    }
}

// MARK: - T6.2 ModelManager / image tagger

struct FakeModel: VisionLanguageModel {
    let output: String
    func generate(prompt: String, image: Data) async throws -> String { output }
}

/// Counts loads; optionally gated so a test can hold the load open.
final class FakeLoader: @unchecked Sendable {
    private let lock = NSLock()
    private var gate: CheckedContinuation<Void, Never>?
    private var gated: Bool
    private(set) var loads = 0
    init(gated: Bool = false) { self.gated = gated }

    func load() async -> any VisionLanguageModel {
        lock.withLock { loads += 1 }
        if lock.withLock({ gated }) {
            await withCheckedContinuation { cont in
                lock.lock()
                if gated { gate = cont; lock.unlock() } else { lock.unlock(); cont.resume() }
            }
        }
        return FakeModel(output: "chair, wood")
    }

    var isWaiting: Bool { lock.withLock { gate != nil } }

    func release() {
        lock.lock()
        gated = false
        let g = gate
        gate = nil
        lock.unlock()
        g?.resume()
    }
}

@Suite struct ModelManagerTests {
    func make(_ loader: FakeLoader, clock: FakeClock) -> ModelManager<any VisionLanguageModel> {
        ModelManager(clock: clock, idleTimeout: 300) { await loader.load() }
    }

    @Test func loadsOnDemand() async throws {
        let clock = FakeClock(), loader = FakeLoader()
        let manager = make(loader, clock: clock)
        #expect(await manager.isLoaded == false)
        #expect(loader.loads == 0)
        let tags = try await VLMImageTagger(manager: manager).tags(forImage: Data([1]))
        #expect(tags == ["chair", "wood"])
        #expect(await manager.isLoaded)
        #expect(loader.loads == 1)
        _ = try await VLMImageTagger(manager: manager).tags(forImage: Data([2]))
        #expect(loader.loads == 1)
    }

    @Test func unloadsAfterFiveMinutesIdle() async throws {
        let clock = FakeClock(), loader = FakeLoader()
        let manager = make(loader, clock: clock)
        _ = try await manager.withModel { _ in 1 }
        await clock.waitForSleepers()
        clock.advance(by: 299)
        await Task.yield()
        #expect(await manager.isLoaded)
        clock.advance(by: 1)
        await pollUntilAsync { await manager.isLoaded == false }
        #expect(await manager.isLoaded == false)
        #expect(await manager.unloadCount == 1)
        // Next use reloads.
        _ = try await manager.withModel { _ in 1 }
        #expect(loader.loads == 2)
    }

    @Test func useResetsIdleTimer() async throws {
        let clock = FakeClock(), loader = FakeLoader()
        let manager = make(loader, clock: clock)
        _ = try await manager.withModel { _ in 1 }
        await clock.waitForSleepers()
        clock.advance(by: 200)
        _ = try await manager.withModel { _ in 2 }
        await clock.waitForSleepers()
        clock.advance(by: 200)
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(await manager.isLoaded) // only 200s since last use
        clock.advance(by: 100)
        await pollUntilAsync { await manager.isLoaded == false }
        #expect(await manager.isLoaded == false)
    }

    @Test func concurrentRequestsShareOneLoad() async throws {
        let clock = FakeClock(), loader = FakeLoader(gated: true)
        let manager = make(loader, clock: clock)
        let tasks = (0..<5).map { i in Task { try await manager.withModel { _ in i } } }
        await pollUntilAsync { loader.isWaiting }
        try? await Task.sleep(nanoseconds: 20_000_000) // let the others queue up behind the load
        loader.release()
        var results: [Int] = []
        for t in tasks { results.append(try await t.value) }
        #expect(results.sorted() == [0, 1, 2, 3, 4])
        #expect(loader.loads == 1)
        #expect(await manager.loadCount == 1)
    }

    @Test func parsesModelOutput() {
        #expect(VLMImageTagger.parse("1. Chair\n2. Oak Wood\n- living room, Cozy.") == ["chair", "oak wood", "living room", "cozy"])
    }

    @Test func imageTagProcessorAddsAITags() async throws {
        let env = try TestEnv()
        let manager = make(FakeLoader(), clock: env.clock)
        let item = try await runProcessor(ImageTagProcessor(tagger: VLMImageTagger(manager: manager)),
                                          payload: .imageData(try Fixtures.data("red.png")), env: env)
        #expect(try env.repo.tags(for: item.id) == [ItemTag(name: "chair", source: .ai), ItemTag(name: "wood", source: .ai)])
    }

    @Test func visionClassifierFallbackDoesNotThrow() async throws {
        let tags = try await VisionClassifierImageTagger().tags(forImage: try Fixtures.data("text.png"))
        #expect(tags.count <= TagValidator.maxTags)
    }

    @Test(.tags(.integration), .enabled(if: ImageTaggerFactory.hasVisionLanguageModel, "MLX Qwen2.5-VL not built in"))
    func realVisionLanguageModel() async throws {
        let tags = try await ImageTaggerFactory.make().tags(forImage: try Fixtures.data("two-color.png"))
        #expect(!tags.isEmpty)
    }
}

func pollUntilAsync(timeout: TimeInterval = 3, _ condition: () async -> Bool) async {
    let end = Date().addingTimeInterval(timeout)
    while await !condition(), Date() < end { try? await Task.sleep(nanoseconds: 2_000_000) }
}

// MARK: - T6.3 Tag merge

@Suite struct TagMergeTests {
    @Test func aiTagsMarkedAI() async throws {
        let env = try TestEnv()
        let item = try env.makeItem()
        try await runAITags(AITagProcessor(primary: FakeTagger(suggestion: TagSuggestion(tags: ["x"]))), env: env, itemID: item.id)
        #expect(try env.repo.tags(for: item.id) == [ItemTag(name: "x", source: .ai)])
    }

    @Test func userTagsAlwaysWin() async throws {
        let env = try TestEnv()
        let item = try env.makeItem()
        try env.repo.userAddTag("Chair", to: item.id)
        try await runAITags(AITagProcessor(primary: FakeTagger(suggestion: TagSuggestion(tags: ["chair", "wood"]))), env: env, itemID: item.id)
        #expect(try env.repo.tags(for: item.id) == [ItemTag(name: "Chair", source: .user), ItemTag(name: "wood", source: .ai)])
        // A later user add of an AI tag promotes it to user.
        try env.repo.userAddTag("wood", to: item.id)
        #expect(try env.repo.tags(for: item.id).allSatisfy { $0.source == .user })
    }

    @Test func userCanRemoveAITags() async throws {
        let env = try TestEnv()
        let item = try env.makeItem()
        try await runAITags(AITagProcessor(primary: FakeTagger(suggestion: TagSuggestion(tags: ["junk", "keep"]))), env: env, itemID: item.id)
        try env.repo.userRemoveTag("junk", from: item.id)
        #expect(try env.repo.tags(for: item.id).map(\.name) == ["keep"])
    }

    @Test func removedAITagNotReAddedOnReEnrich() async throws {
        let env = try TestEnv()
        let item = try env.makeItem()
        let processor = AITagProcessor(primary: FakeTagger(suggestion: TagSuggestion(tags: ["junk", "keep", "new"])))
        try await runAITags(processor, env: env, itemID: item.id)
        try env.repo.userRemoveTag("Junk", from: item.id)
        try await runAITags(processor, env: env, itemID: item.id) // re-enrich
        #expect(try env.repo.tags(for: item.id).map(\.name) == ["keep", "new"])
        #expect(TagMerger.suppressedTags(of: try env.repo.fetch(item.id)!) == ["junk"])
        // The user can still add it back explicitly.
        try env.repo.userAddTag("junk", to: item.id)
        #expect(try env.repo.tags(for: item.id).map(\.name) == ["junk", "keep", "new"])
        #expect(TagMerger.suppressedTags(of: try env.repo.fetch(item.id)!).isEmpty)
    }

    @Test func setUserTagsSuppressesRemovedAITags() async throws {
        let env = try TestEnv()
        let item = try env.makeItem()
        let processor = AITagProcessor(primary: FakeTagger(suggestion: TagSuggestion(tags: ["a", "b"])))
        try await runAITags(processor, env: env, itemID: item.id)
        try env.repo.setUserTags(["b", "mine"], for: item.id)
        try await runAITags(processor, env: env, itemID: item.id)
        #expect(try env.repo.tags(for: item.id).map(\.name) == ["b", "mine"])
    }
}
