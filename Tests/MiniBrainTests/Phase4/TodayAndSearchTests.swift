import Foundation
import Testing
@testable import MiniBrainCore
@testable import MiniBrainUI

/// Sidebar "Today" and search-box debouncing.
@Suite @MainActor struct TodayFilterTests {
    func make() throws -> (TestEnv, LibraryViewModel, CountingSearch) {
        let env = try TestEnv()
        let search = CountingSearch(SearchService(database: env.db, parser: QueryParser(timeZone: utc)))
        let vm = LibraryViewModel(search: search, repository: env.repo, clock: env.clock)
        vm.timeZone = utc
        return (env, vm, search)
    }

    @Test func todayShowsOnlyItemsAddedToday() async throws {
        let (env, vm, _) = try make()
        // Clock: 2023-11-14 22:13 UTC.
        _ = try env.makeItem(title: "today one")
        _ = try env.makeItem(title: "today early", createdAt: env.clock.now.addingTimeInterval(-22 * 3600))
        _ = try env.makeItem(title: "yesterday", createdAt: env.clock.now.addingTimeInterval(-23 * 3600))
        vm.filters = LibraryFilters(addedToday: true)
        #expect(vm.queryString == "after:2023-11-14")
        await vm.performSearch()
        #expect(Set(vm.results.map(\.item.title)) == ["today one", "today early"])
    }

    @Test func todayRollsOverAtMidnight() async throws {
        let (env, vm, _) = try make()
        vm.filters = LibraryFilters(addedToday: true)
        #expect(vm.queryString == "after:2023-11-14")
        env.clock.advance(by: 2 * 3600) // past midnight UTC
        #expect(vm.queryString == "after:2023-11-15")
    }

    @Test func todayCombinesWithSearchTextAndIsNotEmpty() {
        let filters = LibraryFilters(addedToday: true)
        #expect(!filters.isEmpty)
        #expect(filters != LibraryFilters())
    }
}

@Suite @MainActor struct SearchDebounceTests {
    func make() throws -> (TestEnv, LibraryViewModel, CountingSearch) {
        let env = try TestEnv()
        let search = CountingSearch(SearchService(database: env.db, parser: QueryParser(timeZone: utc)))
        let vm = LibraryViewModel(search: search, repository: env.repo, clock: env.clock)
        vm.timeZone = utc
        return (env, vm, search)
    }

    @Test func whitespaceOnlyChangeDoesNotSearchAgain() async throws {
        let (env, vm, search) = try make()
        vm.searchText = "lamp"
        await env.clock.waitForSleepers()
        env.clock.advance(by: 1)
        await waitUntil { search.queries.count == 1 }
        vm.searchText = "lamp "   // trailing space: same query
        vm.searchText = " lamp "
        #expect(env.clock.sleeperCount == 0)
        await vm.searchTaskForTesting?.value
        #expect(search.queries == ["lamp"])
    }

    @Test func returnSearchesImmediately() async throws {
        let (env, vm, search) = try make()
        _ = try env.makeItem(title: "walnut table")
        vm.searchText = "walnut"
        vm.searchNow()
        await vm.searchTaskForTesting?.value
        #expect(search.queries == ["walnut"])
        #expect(vm.results.count == 1)
    }

    @Test func typingKeepsRestartingTheTimer() async throws {
        let (env, vm, search) = try make()
        vm.searchText = "w"
        await env.clock.waitForSleepers()
        env.clock.advance(by: 0.2)
        vm.searchText = "wa"
        await env.clock.waitForSleepers()
        env.clock.advance(by: 0.2)
        vm.searchText = "wal"
        await env.clock.waitForSleepers()
        env.clock.advance(by: 0.2)
        #expect(search.queries.isEmpty)
        env.clock.advance(by: 0.2)
        await waitUntil { search.queries.count == 1 }
        #expect(search.queries == ["wal"])
    }
}
