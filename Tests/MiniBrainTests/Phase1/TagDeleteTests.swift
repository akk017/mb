import Foundation
import Testing
@testable import MiniBrainCore
@testable import MiniBrainUI

@Suite struct TagDeleteTests {
    @Test func deletesTagFromEveryItemAndKeepsItems() throws {
        let env = try TestEnv()
        let a = try env.makeItem(title: "a"), b = try env.makeItem(title: "b"), c = try env.makeItem(title: "c")
        try env.repo.attachTag("Cloudy", to: a.id)
        try env.repo.attachTag("cloudy", to: b.id, source: .ai)
        try env.repo.attachTag("sky", to: c.id)
        #expect(try env.repo.usageCount(ofTag: "CLOUDY") == 2)

        #expect(try env.repo.deleteTagEverywhere("cloudy") == 2)
        #expect(try env.repo.allTags().map(\.name) == ["sky"])
        #expect(try env.repo.tags(for: a.id).isEmpty)
        #expect(try env.repo.count() == 3) // items kept
        #expect(try SearchService(database: env.db).search("tag:cloudy").isEmpty)
        #expect(try env.repo.usageCount(ofTag: "cloudy") == 0)
    }

    @Test func aiDoesNotReAddDeletedTag() async throws {
        let env = try TestEnv()
        let item = try env.makeItem(title: "x")
        let processor = AITagProcessor(primary: FakeTagger(suggestion: TagSuggestion(tags: ["cloudy", "sky"])))
        try await runAITags(processor, env: env, itemID: item.id)
        try env.repo.deleteTagEverywhere("cloudy")
        try await runAITags(processor, env: env, itemID: item.id) // re-enrich
        #expect(try env.repo.tags(for: item.id).map(\.name) == ["sky"])
    }

    @Test func unknownTagIsNoOp() throws {
        let env = try TestEnv()
        #expect(try env.repo.deleteTagEverywhere("nope") == 0)
    }
}

@Suite @MainActor struct SidebarTagDeleteTests {
    @Test func deletingClearsSidebarFilterAndRefreshes() async throws {
        let env = try TestEnv()
        let a = try env.makeItem(title: "a")
        try env.repo.attachTag("cloudy", to: a.id)
        try env.repo.attachTag("sky", to: a.id)
        let vm = LibraryViewModel(search: SearchService(database: env.db), repository: env.repo, clock: env.clock)
        vm.filters.tags = ["cloudy"]
        await vm.performSearch()
        #expect(vm.usageCount(ofTag: "cloudy") == 1)
        try await vm.deleteTagEverywhere("cloudy")
        #expect(vm.filters.tags.isEmpty)
        #expect(vm.allTags == ["sky"])
        #expect(vm.results.map(\.id) == [a.id])
        #expect(vm.tagsByItem[a.id]?.map(\.name) == ["sky"])
    }
}
