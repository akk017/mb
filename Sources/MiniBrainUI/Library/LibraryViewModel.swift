import Foundation
import MiniBrainCore
import Observation

/// What the library uses to run queries (plain FTS, hybrid, or NL).
public protocol SearchProviding: Sendable {
    func results(for query: String, limit: Int) async throws -> [SearchResult]
}

extension SearchService: SearchProviding {
    public func results(for query: String, limit: Int) async throws -> [SearchResult] {
        let service = self
        return try await Task.detached { try service.search(query, limit: limit) }.value
    }
}

/// Sidebar filter selections, rendered into the query syntax.
public struct LibraryFilters: Equatable, Sendable {
    public var type: ItemType?
    /// Name of a user-defined custom type.
    public var customType: String?
    public var tags: [String] = []
    public var color: String?
    public var after: Date?
    public var before: Date?

    public init(type: ItemType? = nil, customType: String? = nil, tags: [String] = [], color: String? = nil,
                after: Date? = nil, before: Date? = nil) {
        self.type = type
        self.customType = customType
        self.tags = tags
        self.color = color
        self.after = after
        self.before = before
    }

    public var isEmpty: Bool { self == LibraryFilters() }

    public func queryFragments(timeZone: TimeZone = .current) -> [String] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        var parts: [String] = []
        if let type { parts.append("type:\(type.rawValue)") }
        if let customType { parts.append("type:\"\(customType)\"") }
        for tag in tags { parts.append(tag.contains(" ") ? "tag:\"\(tag)\"" : "tag:\(tag)") }
        if let color { parts.append("color:\(color)") }
        if let after { parts.append("after:\(f.string(from: after))") }
        if let before { parts.append("before:\(f.string(from: before))") }
        return parts
    }
}

@MainActor
@Observable
public final class LibraryViewModel {
    public var searchText = "" { didSet { if searchText != oldValue { scheduleSearch() } } }
    public var filters = LibraryFilters() { didSet { if filters != oldValue { scheduleSearch(immediate: true) } } }
    public private(set) var results: [SearchResult] = []
    public private(set) var totalItemCount = 0
    public private(set) var allTags: [String] = []
    public private(set) var customTypes: [CustomType] = []
    /// Tags of the items in `results`, for cards and the detail panel.
    public private(set) var tagsByItem: [String: [ItemTag]] = [:]
    public private(set) var errorMessage: String?
    public private(set) var isSearching = false
    /// Primary (last clicked) selection. Setting it directly selects only that item.
    public var selectedItemID: String? {
        didSet {
            guard !updatingSelection else { return }
            selectedIDs = selectedItemID.map { [$0] } ?? []
        }
    }
    /// Everything selected (⌘-click / ⇧-click / ⌘A).
    public private(set) var selectedIDs: Set<String> = []
    @ObservationIgnored private var updatingSelection = false
    /// Show OCR text for images (Settings › General).
    public var showsRecognizedText = false

    @ObservationIgnored let search: any SearchProviding
    @ObservationIgnored let repository: ItemRepository
    @ObservationIgnored let customTypeRepository: CustomTypeRepository?
    @ObservationIgnored let clock: any MiniBrainCore.Clock
    @ObservationIgnored public var debounce: TimeInterval = 0.25
    @ObservationIgnored public var timeZone: TimeZone = .current
    @ObservationIgnored public var limit = 500
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private(set) var searchCount = 0

    public init(search: any SearchProviding, repository: ItemRepository, customTypes: CustomTypeRepository? = nil,
                clock: any MiniBrainCore.Clock = SystemClock()) {
        self.search = search
        self.repository = repository
        self.customTypeRepository = customTypes
        self.clock = clock
    }

    /// The full query sent to search: free text + sidebar filters.
    public var queryString: String {
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return ([text].filter { !$0.isEmpty } + filters.queryFragments(timeZone: timeZone)).joined(separator: " ")
    }

    /// No items at all (onboarding empty state) vs. a query with no hits.
    public var showsEmptyLibrary: Bool { totalItemCount == 0 }
    public var showsNoResults: Bool { totalItemCount > 0 && results.isEmpty && !isSearching }

    /// The single selected item (nil when nothing or several are selected).
    public var selectedItem: Item? {
        guard selectedIDs.count <= 1, let id = selectedItemID else { return nil }
        return results.first { $0.id == id }?.item
    }

    public var isMultiSelection: Bool { selectedIDs.count > 1 }

    /// Selected items in grid order.
    public var selectedItems: [Item] {
        results.filter { selectedIDs.contains($0.id) }.map(\.item)
    }

    public func isSelected(_ id: String) -> Bool { selectedIDs.contains(id) }

    /// Click handling: plain = only this; ⌘ = toggle; ⇧ = range from the last click.
    public func select(_ id: String, toggle: Bool = false, extendRange: Bool = false) {
        var ids = selectedIDs
        var primary: String? = id
        if extendRange, let anchor = selectedItemID,
           let a = results.firstIndex(where: { $0.id == anchor }), let b = results.firstIndex(where: { $0.id == id }) {
            for r in results[min(a, b)...max(a, b)] { ids.insert(r.id) }
        } else if toggle {
            if ids.contains(id) {
                ids.remove(id)
                primary = selectedItemID == id ? results.first { ids.contains($0.id) }?.id : selectedItemID
            } else {
                ids.insert(id)
            }
        } else {
            ids = [id]
        }
        setSelection(ids, primary: primary)
    }

    public func selectAll() {
        setSelection(Set(results.map(\.id)), primary: selectedItemID ?? results.first?.id)
    }

    public func clearSelection() { setSelection([], primary: nil) }

    private func setSelection(_ ids: Set<String>, primary: String?) {
        updatingSelection = true
        selectedIDs = ids
        selectedItemID = ids.isEmpty ? nil : primary
        updatingSelection = false
    }

    // MARK: - Bulk actions

    public func trashSelected() throws {
        for id in selectedIDs { try repository.trash(id) }
        clearSelection()
    }

    public func addTagToSelected(_ name: String) throws {
        for id in selectedIDs { try addTag(name, to: id) }
    }

    public func assignCustomTypeToSelected(_ typeID: String?) throws {
        for id in selectedIDs { try assignCustomType(typeID, to: id) }
    }

    /// Debounced search. Typing restarts the timer.
    public func scheduleSearch(immediate: Bool = false) {
        searchTask?.cancel()
        let delay = immediate ? 0 : debounce
        searchTask = Task { [weak self, clock] in
            if delay > 0 {
                do { try await clock.sleep(for: delay) } catch { return }
            }
            guard !Task.isCancelled else { return }
            await self?.performSearch()
        }
    }

    /// Runs the current query now.
    public func performSearch() async {
        if let name = filters.customType, let repo = customTypeRepository, !repo.exists(named: name) {
            filters.customType = nil // type was deleted or renamed
        }
        let query = queryString
        isSearching = true
        searchCount += 1
        defer { isSearching = false }
        do {
            let found = try await search.results(for: query, limit: limit)
            guard query == queryString else { return } // stale
            results = found
            errorMessage = nil
            totalItemCount = try repository.count()
            allTags = try repository.allTags().map(\.name)
            tagsByItem = try repository.tags(forItems: found.map(\.id))
            customTypes = (try customTypeRepository?.all()) ?? []
            let visible = Set(found.map(\.id))
            if !selectedIDs.isSubset(of: visible) {
                let kept = selectedIDs.intersection(visible)
                setSelection(kept, primary: selectedItemID.flatMap { kept.contains($0) ? $0 : nil } ?? kept.first)
            }
        } catch let MiniBrainError.invalidQuery(message) {
            errorMessage = message
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func refresh() async { await performSearch() }

    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?

    /// Coalesces bursts (several enrichment jobs finishing together) into one
    /// refresh after `delay`.
    public func scheduleRefresh(after delay: Duration = .milliseconds(350)) {
        guard pendingRefresh == nil else { return }
        pendingRefresh = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            self.pendingRefresh = nil
            await self.refresh()
        }
    }

    // MARK: - Detail editing

    public func tags(for itemID: String) -> [ItemTag] {
        tagsByItem[itemID] ?? (try? repository.tags(for: itemID)) ?? []
    }

    /// Adds one user tag (lifts any AI suppression).
    public func addTag(_ name: String, to itemID: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try repository.userAddTag(trimmed, to: itemID)
        try reloadTags(itemID)
    }

    /// Removes one tag (AI won't re-add it).
    public func removeTag(_ name: String, from itemID: String) throws {
        try repository.userRemoveTag(name, from: itemID)
        try reloadTags(itemID)
    }

    // MARK: - Tag management (sidebar)

    public func usageCount(ofTag name: String) -> Int { (try? repository.usageCount(ofTag: name)) ?? 0 }

    /// Removes a tag from every item (and drops a sidebar filter on it).
    public func deleteTagEverywhere(_ name: String) async throws {
        try repository.deleteTagEverywhere(name)
        filters.tags.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
        await performSearch()
    }

    private func reloadTags(_ itemID: String) throws {
        tagsByItem[itemID] = try repository.tags(for: itemID)
        allTags = try repository.allTags().map(\.name)
    }

    public func saveNote(_ note: String, for itemID: String) throws {
        let updated = try repository.modify(itemID) { $0.note = note }
        replace(updated)
    }

    /// Saves a renamed title (trimmed). Blank or unchanged titles are skipped,
    /// so autosave while typing doesn't write on every pause.
    public func saveTitle(_ title: String, for itemID: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let cached = results.first(where: { $0.id == itemID })?.item
        let current = try cached ?? repository.fetch(itemID)
        guard current?.title != trimmed else { return }
        let updated = try repository.modify(itemID) { $0.title = trimmed }
        replace(updated)
    }

    public func setTags(_ tags: [String], for itemID: String) throws {
        try repository.setUserTags(tags, for: itemID)
        try reloadTags(itemID)
    }

    // MARK: - Custom types

    public func customType(for item: Item) -> CustomType? {
        guard let id = item.customTypeID else { return nil }
        return customTypes.first { $0.id == id }
    }

    /// Moves an item into a custom type (nil removes it).
    public func assignCustomType(_ typeID: String?, to itemID: String) throws {
        guard let repo = customTypeRepository else { return }
        replace(try repo.assign(itemID, to: typeID))
    }

    public func saveFieldValues(_ values: [String: String], for itemID: String) throws {
        guard let repo = customTypeRepository else { return }
        replace(try repo.setFieldValues(values, for: itemID))
    }

    /// Saves one custom-field value, keeping the others.
    public func saveFieldValue(_ value: String, field fieldID: String, for itemID: String) throws {
        guard let item = try results.first(where: { $0.id == itemID })?.item ?? repository.fetch(itemID) else { return }
        var values = item.fieldValues
        values[fieldID] = value
        try saveFieldValues(values, for: itemID)
    }

    /// "+ Add a property": appends a field to the item's custom type.
    @discardableResult
    public func addProperty(named name: String, kind: FieldKind, toTypeOf item: Item) throws -> FieldDefinition? {
        guard let repo = customTypeRepository, var type = customType(for: item) else { return nil }
        var fieldName = name
        var n = 2
        while type.fields.contains(where: { $0.name.caseInsensitiveCompare(fieldName) == .orderedSame }) {
            fieldName = "\(name) \(n)"; n += 1
        }
        let field = FieldDefinition(name: fieldName, kind: kind)
        type.fields.append(field)
        let saved = try repo.update(type)
        if let i = customTypes.firstIndex(where: { $0.id == saved.id }) { customTypes[i] = saved }
        return field
    }

    private func replace(_ item: Item) {
        if let i = results.firstIndex(where: { $0.id == item.id }) { results[i].item = item }
    }
}

extension SmartSearch: SearchProviding {
    public func results(for query: String, limit: Int) async throws -> [SearchResult] {
        try await search(query, limit: limit)
    }
}

/// Runs `save` once typing pauses for `delay`; `flush()` saves right away
/// (Return, leaving the field/panel) and cancels the pending save.
@MainActor
public final class DebouncedSaver {
    private let delay: Duration
    private let save: (String) -> Void
    private var pending: String?
    private var task: Task<Void, Never>?

    public init(delay: Duration = .milliseconds(600), save: @escaping (String) -> Void) {
        self.delay = delay
        self.save = save
    }

    public func schedule(_ value: String) {
        pending = value
        task?.cancel()
        task = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    public func flush() {
        task?.cancel()
        task = nil
        guard let value = pending else { return }
        pending = nil
        save(value)
    }
}
