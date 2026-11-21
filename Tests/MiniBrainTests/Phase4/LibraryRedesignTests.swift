import Foundation
import Testing
@testable import MiniBrainCore
@testable import MiniBrainUI

@Suite @MainActor struct LibraryRedesignTests {
    func make() throws -> (TestEnv, LibraryViewModel, CustomTypeRepository) {
        let env = try TestEnv()
        let types = CustomTypeRepository(database: env.db, clock: env.clock)
        let vm = LibraryViewModel(search: SearchService(database: env.db), repository: env.repo, customTypes: types, clock: env.clock)
        return (env, vm, types)
    }

    @Test func tagsLoadedForAllResultsInOneGo() async throws {
        let (env, vm, _) = try make()
        let a = try env.makeItem(title: "a"), b = try env.makeItem(title: "b"), c = try env.makeItem(title: "c")
        try env.repo.attachTag("Zeta", to: a.id)
        try env.repo.attachTag("alpha", to: a.id)
        try env.repo.attachTag("beta", to: b.id, source: .ai)
        await vm.performSearch()
        #expect(vm.tagsByItem[a.id]?.map(\.name) == ["alpha", "Zeta"])
        #expect(vm.tagsByItem[b.id] == [ItemTag(name: "beta", source: .ai)])
        #expect(vm.tagsByItem[c.id] == nil)
        #expect(try env.repo.tags(forItems: []).isEmpty)
    }

    @Test func addAndRemoveSingleTags() async throws {
        let (env, vm, _) = try make()
        let item = try env.makeItem(title: "Green Cloud")
        try env.repo.attachTag("vps", to: item.id, source: .ai)
        await vm.performSearch()

        try vm.addTag("  DevOps ", to: item.id)
        try vm.addTag("   ", to: item.id) // ignored
        #expect(vm.tags(for: item.id).map(\.name) == ["DevOps", "vps"])
        #expect(vm.allTags == ["DevOps", "vps"])

        try vm.removeTag("vps", from: item.id)
        #expect(vm.tags(for: item.id).map(\.name) == ["DevOps"])
        #expect(vm.allTags == ["DevOps"])
        // Removed AI tag is suppressed for future enrichment.
        #expect(TagMerger.suppressedTags(of: try env.repo.fetch(item.id)!) == ["vps"])
    }

    @Test func singleFieldSaveKeepsOtherValues() async throws {
        let (env, vm, types) = try make()
        let type = try productsType(types)
        let item = try env.makeItem(title: "Mug")
        try types.assign(item.id, to: type.id)
        try types.setFieldValues([type.fields[0].id: "Mug"], for: item.id)
        await vm.performSearch()
        try vm.saveFieldValue("Stoneware", field: type.fields[1].id, for: item.id)
        #expect(try env.repo.fetch(item.id)?.fieldValues == [type.fields[0].id: "Mug", type.fields[1].id: "Stoneware"])
    }

    @Test func addPropertyAppendsUniqueFieldToType() async throws {
        let (env, vm, types) = try make()
        let type = try productsType(types)
        let item = try env.makeItem(title: "Mug")
        try types.assign(item.id, to: type.id)
        await vm.performSearch()
        let assigned = vm.results.first { $0.id == item.id }!.item
        let f1 = try #require(try vm.addProperty(named: "Text", kind: .text, toTypeOf: assigned))
        let f2 = try #require(try vm.addProperty(named: "Text", kind: .text, toTypeOf: assigned))
        #expect(f1.name == "Text")
        #expect(f2.name == "Text 2")
        #expect(try types.find(type.id)?.fields.map(\.name) == ["Name", "Description", "Shop Link", "Text", "Text 2"])
        #expect(vm.customType(for: assigned)?.fields.count == 5)
        // No type → nothing to add to.
        let loose = try env.makeItem(title: "loose")
        #expect(try vm.addProperty(named: "X", kind: .text, toTypeOf: loose) == nil)
    }
}

@Suite struct LibraryLayoutTests {
    @Test func chipRowKeepsWidthsWhenTheyFit() {
        #expect(ChipRowLayout.widths(ideal: [40, 30, 50], available: 200, spacing: 5) == [40, 30, 50])
    }

    @Test func chipRowShrinksBigChipsFairly() {
        let w = ChipRowLayout.widths(ideal: [20, 100, 100, 100], available: 200, spacing: 5)
        // room = 200 - 15 = 185; small chip keeps 20, the rest split 165 / 3 = 55.
        #expect(w == [20, 55, 55, 55])
        #expect(w.reduce(0, +) + 15 <= 200)
        #expect(ChipRowLayout.widths(ideal: [], available: 100, spacing: 5).isEmpty)
    }

    @Test func tagColorIsStableAndCaseInsensitive() {
        #expect(TagPalette.index(for: "Backend") == TagPalette.index(for: "backend"))
        #expect(TagPalette.index(for: "DevOps") == TagPalette.index(for: "DevOps"))
        let indices = Set(["VPS", "Dev", "Backend", "DevOps", "Frontend", "Design", "Jobs", "UI", "Diagram"].map(TagPalette.index(for:)))
        #expect(indices.count > 3) // spreads across the palette
        #expect(indices.allSatisfy { (0..<Theme.tagBackgrounds.count).contains($0) })
    }

    @Test func urlSplitsIntoHostAndPath() {
        #expect(URLLabel.split("https://www.green.cloud/cloud-vps.php") == ("green.cloud", "/cloud-vps.php"))
        #expect(URLLabel.split("https://karpenter.sh/") == ("karpenter.sh", "/"))
        #expect(URLLabel.split("https://a.io/s?q=1") == ("a.io", "/s?q=1"))
        #expect(URLLabel.split("not a url") == ("not a url", ""))
    }
}
