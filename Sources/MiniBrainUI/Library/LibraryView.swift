import AppKit
import MiniBrainCore
import SwiftUI

/// Library window: solid sidebar · gallery · property panel.
public struct LibraryView: View {
    @Bindable var model: LibraryViewModel
    let actions: ItemActions
    let openSettings: () -> Void
    /// Live drag width + window width. Kept out of this view's own state so
    /// dragging the panel edge doesn't rebuild the sidebar and gallery.
    @State private var layout: PanelLayout

    public init(model: LibraryViewModel, actions: ItemActions, openSettings: @escaping () -> Void = {}) {
        self.init(model: model, actions: actions, openSettings: openSettings, layout: PanelLayout())
    }

    init(model: LibraryViewModel, actions: ItemActions, openSettings: @escaping () -> Void = {}, layout: PanelLayout) {
        self.model = model
        self.actions = actions
        self.openSettings = openSettings
        _layout = State(initialValue: layout)
    }

    public var body: some View {
        HStack(spacing: 0) {
            LibrarySidebar(model: model)
                .frame(width: 248)
            Theme.divider.frame(width: 1)
            GalleryView(model: model, actions: actions)
                .frame(minWidth: DetailPanelWidth.minimumGallery, maxWidth: .infinity)
            if model.isMultiSelection || model.selectedItem != nil {
                DetailPanelContainer(layout: layout) {
                    if model.isMultiSelection {
                        MultiSelectionPanel(model: model, actions: actions)
                    } else if let item = model.selectedItem {
                        ItemPropertiesPanel(model: model, actions: actions, item: item)
                            .id(item.id)
                    }
                }
                .transition(.move(edge: .trailing))
            }
        }
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { layout.updateWindowWidth(geo.size.width) }
                .onChange(of: geo.size.width) { _, w in layout.updateWindowWidth(w) }
        })
        .background(Theme.content)
        .foregroundStyle(Theme.primary)
        .tint(Theme.accent)
        .animation(.snappy(duration: 0.2), value: model.selectedIDs.count > 1)
        .animation(.snappy(duration: 0.2), value: model.selectedItemID == nil)
        .background {
            // ⌘, opens Settings (the menu-bar menu's shortcut only works while it's open).
            Button("Settings…", action: openSettings)
                .keyboardShortcut(",", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
        }
        .task { await model.refresh() }
        .frame(minWidth: 980, minHeight: 600)
        .ignoresSafeArea()
    }
}

// MARK: - Resizable detail panel

/// Size rules for the right-hand detail panel.
enum DetailPanelWidth {
    static let defaultsKey = "library.detailPanelWidth"
    static let standard: Double = 460
    static let minimum: Double = 360
    static let minimumGallery: Double = 420
    static let sidebar: Double = 248 + 1 // sidebar + divider

    /// Keeps the panel between `minimum` and whatever leaves the gallery its
    /// minimum width in the current window.
    /// Always whole points: a fractional width (e.g. a saved 496.89 pt) makes
    /// SwiftUI layout and AppKit's pixel alignment of scroll views disagree by
    /// a fraction and re-lay out forever — the app froze.
    static func clamp(_ width: Double, windowWidth: Double) -> Double {
        let maximum = max(minimum, (windowWidth - sidebar - minimumGallery - 1).rounded(.down))
        return min(max(width.rounded(), minimum), maximum)
    }
}

private struct IsResizingPanelKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while the detail panel edge is being dragged (cheaper rendering).
    /// (Written by hand: the `@Entry` macro plugin ships only with Xcode.)
    var isResizingPanel: Bool {
        get { self[IsResizingPanelKey.self] }
        set { self[IsResizingPanelKey.self] = newValue }
    }
}

/// Large preview in the detail panel; uses cheaper scaling while resizing.
struct PanelPreviewImage: View {
    let image: NSImage
    @Environment(\.isResizingPanel) private var resizing

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(resizing ? .medium : .high)
            .scaledToFit()
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Drag state for the detail panel, observed only by its container.
@MainActor
@Observable
final class PanelLayout {
    /// Width while dragging (nil when not dragging).
    var liveWidth: Double?
    var windowWidth: Double = 1320

    /// Sub-point changes are pixel-alignment jitter; feeding them back into
    /// the panel width can start a layout loop.
    nonisolated static func isMeaningfulWidthChange(from old: Double, to new: Double) -> Bool {
        abs(new.rounded() - old.rounded()) >= 1
    }

    func updateWindowWidth(_ width: Double) {
        guard Self.isMeaningfulWidthChange(from: windowWidth, to: width) else { return }
        LoopDetector.shared.tick("library.windowWidth", detail: "\(windowWidth)→\(width)")
        windowWidth = width.rounded()
    }
}

/// Handle + panel content at the saved/live width. Only this view re-renders
/// while the edge is dragged.
struct DetailPanelContainer<Content: View>: View {
    let layout: PanelLayout
    @ViewBuilder var content: Content
    /// Saved width (restored on reopen / relaunch).
    @AppStorage(DetailPanelWidth.defaultsKey) private var savedWidth = DetailPanelWidth.standard

    var body: some View {
        HStack(spacing: 0) {
            Theme.divider.frame(width: 1)
            content
                .frame(width: DetailPanelWidth.clamp(layout.liveWidth ?? savedWidth, windowWidth: layout.windowWidth))
                .transaction { if layout.liveWidth != nil { $0.disablesAnimations = true } }
                .environment(\.isResizingPanel, layout.liveWidth != nil)
        }
        // Grab area sits on top of everything, centred on the divider.
        .overlay(alignment: .leading) {
            PanelResizeHandle(width: $savedWidth, layout: layout)
                .offset(x: -5)
        }
    }
}

/// Draggable leading edge of the detail panel (AppKit-backed): AppKit keeps
/// delivering mouse-drag events to the view that got mouseDown even when the
/// pointer runs ahead of the moving edge, and the cursor comes from a cursor
/// rect plus a balanced push/pop for the drag — no flicker, never stuck.
/// Double-click restores the default width.
struct PanelResizeHandle: View {
    @Binding var width: Double
    let layout: PanelLayout
    @State private var highlighted = false

    var body: some View {
        ZStack {
            // Accent line while hovered/dragged (the 1px divider is drawn by the container).
            Rectangle()
                .fill(Theme.accent)
                .frame(width: 2)
                .opacity(highlighted ? 1 : 0)
                .allowsHitTesting(false)
            ResizeHandleView(
                currentWidth: { DetailPanelWidth.clamp(width, windowWidth: layout.windowWidth) },
                onDrag: { proposed in
                    let next = DetailPanelWidth.clamp(proposed, windowWidth: layout.windowWidth)
                    if next != layout.liveWidth { layout.liveWidth = next }
                },
                onEnd: {
                    if let live = layout.liveWidth { width = live } // persist
                    layout.liveWidth = nil
                },
                onReset: {
                    layout.liveWidth = nil
                    width = DetailPanelWidth.standard
                },
                onHighlight: { highlighted = $0 })
        }
        .frame(width: 11)
        .frame(maxHeight: .infinity)
        .help("Drag to resize · double-click to reset")
    }
}

/// The AppKit view behind `PanelResizeHandle`.
struct ResizeHandleView: NSViewRepresentable {
    let currentWidth: () -> Double
    let onDrag: (Double) -> Void
    let onEnd: () -> Void
    let onReset: () -> Void
    let onHighlight: (Bool) -> Void

    func makeNSView(context: Context) -> HandleNSView {
        let view = HandleNSView()
        update(view)
        return view
    }

    func updateNSView(_ view: HandleNSView, context: Context) { update(view) }

    private func update(_ view: HandleNSView) {
        view.currentWidth = currentWidth
        view.onDrag = onDrag
        view.onEnd = onEnd
        view.onReset = onReset
        view.onHighlight = onHighlight
    }

    final class HandleNSView: NSView {
        var currentWidth: () -> Double = { DetailPanelWidth.standard }
        var onDrag: (Double) -> Void = { _ in }
        var onEnd: () -> Void = {}
        var onReset: () -> Void = {}
        var onHighlight: (Bool) -> Void = { _ in }

        private(set) var isDragging = false
        private var startX: CGFloat = 0
        private var startWidth: Double = 0
        private var hovering = false
        private var trackingArea: NSTrackingArea?

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            hovering = true
            onHighlight(true)
        }

        override func mouseExited(with event: NSEvent) {
            hovering = false
            if !isDragging { onHighlight(false) }
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                onReset()
                return
            }
            isDragging = true
            startX = event.locationInWindow.x
            startWidth = currentWidth()
            NSCursor.resizeLeftRight.push()
            onHighlight(true)
        }

        override func mouseDragged(with event: NSEvent) {
            guard isDragging else { return }
            // Dragging left widens the panel (it grows from the right edge).
            onDrag(startWidth + Double(startX - event.locationInWindow.x))
        }

        override func mouseUp(with event: NSEvent) {
            guard isDragging else { return }
            isDragging = false
            NSCursor.pop()
            onEnd()
            if !hovering { onHighlight(false) }
            window?.invalidateCursorRects(for: self)
        }
    }
}

// MARK: - Sidebar

struct LibrarySidebar: View {
    @Bindable var model: LibraryViewModel
    @FocusState private var searchFocused: Bool
    @State private var hintIndex = 0
    @State private var tagToDelete: String?
    @State private var completionIndex = 0
    @State private var completionsDismissedFor: String?
    @AppStorage("sidebar.typesCollapsed") private var typesCollapsed = false
    @AppStorage("sidebar.tagsCollapsed") private var tagsCollapsed = false
    @AppStorage("sidebar.colorsCollapsed") private var colorsCollapsed = false
    static let colors = ["red", "orange", "yellow", "green", "blue", "purple", "pink", "brown", "black", "white", "gray"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 38) // traffic lights
            searchField
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .zIndex(1) // completion list floats over the rows below
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    row("All Items", icon: .layoutGrid, selected: model.filters == LibraryFilters()) {
                        model.filters = LibraryFilters()
                    }
                    ForEach(ItemType.allCases, id: \.self) { type in
                        row(type.displayName, icon: type.icon, selected: model.filters.type == type) {
                            model.filters.type = model.filters.type == type ? nil : type
                        }
                    }

                    if !model.customTypes.isEmpty {
                        header("Types", isCollapsed: $typesCollapsed)
                        if !typesCollapsed { ForEach(model.customTypes) { type in
                            let on = model.filters.customType?.caseInsensitiveCompare(type.name) == .orderedSame
                            row(type.name, icon: .layers, selected: on) {
                                model.filters.customType = on ? nil : type.name
                            }
                        } }
                    }

                    if !model.allTags.isEmpty {
                        header("Tags", count: model.allTags.count, isCollapsed: $tagsCollapsed)
                        if !tagsCollapsed { ForEach(model.allTags, id: \.self) { tag in
                            let on = model.filters.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
                            Button {
                                if on { model.filters.tags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame } }
                                else { model.filters.tags.append(tag) }
                            } label: {
                                HStack(spacing: 9) {
                                    RoundedRectangle(cornerRadius: 3).fill(TagPalette.background(for: tag)).frame(width: 12, height: 12)
                                        .frame(width: 18)
                                    Text(tag).lineLimit(1)
                                    Spacer()
                                }
                                .sidebarRowStyle(selected: on)
                            }
                            .buttonStyle(SidebarButtonStyle())
                            .contextMenu {
                                Button("Delete Tag…", role: .destructive) { tagToDelete = tag }
                            }
                        } }
                    }

                    header("Colors", isCollapsed: $colorsCollapsed)
                    if !colorsCollapsed { LazyVGrid(columns: Array(repeating: GridItem(.fixed(20), spacing: 8), count: 7), alignment: .leading, spacing: 8) {
                        ForEach(Self.colors, id: \.self) { name in
                            let on = model.filters.color == name
                            Circle()
                                .fill(Color(named: name))
                                .overlay(Circle().strokeBorder(on ? Theme.primary : Theme.divider, lineWidth: on ? 2 : 1))
                                .frame(width: 16, height: 16)
                                .contentShape(Circle())
                                .onTapGesture { model.filters.color = on ? nil : name }
                                .help(name.capitalized)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 2) }
                }
                .overlayScrollers()
                .padding(.horizontal, 10)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.never)
        }
        .background(Theme.sidebar)
        .confirmationDialog(
            "Delete the tag “\(tagToDelete ?? "")”?",
            isPresented: Binding(get: { tagToDelete != nil }, set: { if !$0 { tagToDelete = nil } })
        ) {
            Button("Delete Tag", role: .destructive) {
                guard let name = tagToDelete else { return }
                Task { try? await model.deleteTagEverywhere(name) }
            }
        } message: {
            let n = tagToDelete.map(model.usageCount(ofTag:)) ?? 0
            Text("It will be removed from \(n) item\(n == 1 ? "" : "s"). The items themselves are kept, and AI won’t add this tag back to them.")
        }
    }

    private var completions: [SearchCompletion.Suggestion] {
        guard searchFocused, completionsDismissedFor != model.searchText else { return [] }
        return SearchCompletion.suggestions(
            for: model.searchText,
            context: .init(tags: model.allTags, customTypes: model.customTypes.map(\.name)))
    }

    private func accept(_ suggestion: SearchCompletion.Suggestion) {
        model.searchText = SearchCompletion.apply(suggestion, to: model.searchText)
        completionIndex = 0
        searchFocused = true
    }

    private var hint: String {
        let hints = SearchHints.examples(customTypes: model.customTypes.map(\.name), tags: model.allTags)
        return hints[hintIndex % hints.count]
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Icon(.search, size: 14).foregroundStyle(Theme.secondary)
            TextField("Search", text: $model.searchText, prompt: Text(""))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                .overlay(alignment: .leading) {
                    if model.searchText.isEmpty {
                        Text(hint)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.tertiary)
                            .lineLimit(1)
                            .id(hint)
                            .transition(.opacity.combined(with: .offset(y: 4)))
                            .allowsHitTesting(false)
                    }
                }
                .animation(.easeInOut(duration: 0.35), value: hintIndex)
                .onKeyPress(.downArrow) { moveCompletion(1) }
                .onKeyPress(.upArrow) { moveCompletion(-1) }
                .onKeyPress(.tab) { acceptCurrentCompletion() }
                .onKeyPress(.return) { acceptCurrentCompletion() }
                .onKeyPress(.escape) {
                    if completions.isEmpty {
                        searchFocused = false // Esc leaves the search box
                    } else {
                        completionsDismissedFor = model.searchText
                    }
                    return .handled
                }
                .onChange(of: model.searchText) {
                    completionIndex = 0
                    if completionsDismissedFor != model.searchText { completionsDismissedFor = nil }
                }
                .task {
                    // Cycle example queries while the box is empty.
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 3_500_000_000)
                        if model.searchText.isEmpty { hintIndex += 1 }
                    }
                }
            if !model.searchText.isEmpty {
                Button { model.searchText = "" } label: { Icon(.circleX, size: 14) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.tertiary)
            } else {
                Text("⌘F")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Theme.field, in: RoundedRectangle(cornerRadius: 3))
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(alignment: .topLeading) {
            let items = completions
            if !items.isEmpty {
                CompletionList(items: items, selected: min(completionIndex, items.count - 1), onPick: accept)
                    .offset(y: 34)
            }
        }
        .background { Button("") { searchFocused = true }.keyboardShortcut("f").opacity(0) }
        .help("Search  (type:image tag:work color:red meta.price<100)")
    }

    /// Section header; click to collapse/expand (remembered).
    private func moveCompletion(_ delta: Int) -> KeyPress.Result {
        let count = completions.count
        guard count > 0 else { return .ignored }
        completionIndex = (min(completionIndex, count - 1) + delta + count) % count
        return .handled
    }

    private func acceptCurrentCompletion() -> KeyPress.Result {
        let items = completions
        guard !items.isEmpty else { return .ignored }
        accept(items[min(completionIndex, items.count - 1)])
        return .handled
    }

    private func header(_ title: String, count: Int? = nil, isCollapsed: Binding<Bool>) -> some View {
        Button { withAnimation(.snappy(duration: 0.18)) { isCollapsed.wrappedValue.toggle() } } label: {
            HStack(spacing: 5) {
                Text(title)
                if let count, isCollapsed.wrappedValue {
                    Text("\(count)").foregroundStyle(Theme.tertiary)
                }
                Spacer()
                Icon(.chevronDown, size: 12)
                    .rotationEffect(.degrees(isCollapsed.wrappedValue ? -90 : 0))
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 12)
        .padding(.bottom, 2)
        .help(isCollapsed.wrappedValue ? "Show \(title)" : "Hide \(title)")
    }

    private func row(_ title: String, icon: LucideIcon, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Icon(icon, size: 15)
                    .frame(width: 18)
                    .foregroundStyle(Theme.secondary)
                Text(title).lineLimit(1)
                Spacer()
            }
            .sidebarRowStyle(selected: selected)
        }
        .buttonStyle(SidebarButtonStyle())
    }
}

/// Dropdown under the search field.
struct CompletionList: View {
    let items: [SearchCompletion.Suggestion]
    let selected: Int
    let onPick: (SearchCompletion.Suggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Button { onPick(item) } label: {
                    HStack(spacing: 8) {
                        label(for: item)
                        Spacer(minLength: 4)
                        if index == selected {
                            Text("⇥").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(index == selected ? Theme.selectedRow : .clear,
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .frame(width: 228, alignment: .leading)
        .keepsTextFocus() // clicking a suggestion must not end editing first
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.divider))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }

    @ViewBuilder
    private func label(for item: SearchCompletion.Suggestion) -> some View {
        switch item.kind {
        case .tag:
            TagChip(name: item.title, size: .small)
        case .color:
            HStack(spacing: 7) {
                Circle().fill(Color(named: item.title)).frame(width: 11, height: 11)
                    .overlay(Circle().strokeBorder(Theme.divider))
                Text(item.title).font(.system(size: 13))
            }
        case .type:
            HStack(spacing: 7) {
                Icon(ItemType(rawValue: item.title).map(\.icon) ?? .layers, size: 14)
                    .foregroundStyle(Theme.secondary)
                Text(item.title).font(.system(size: 13))
            }
        case .keyword:
            Text(item.title).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.primary)
        }
    }
}

private extension View {
    func sidebarRowStyle(selected: Bool) -> some View {
        self
            .font(.system(size: 13.5, weight: selected ? .medium : .regular))
            .foregroundStyle(Theme.primary)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(selected ? Theme.selectedRow : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
    }
}

/// Plain row button with a solid hover highlight.
struct SidebarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverHighlight { configuration.label.opacity(configuration.isPressed ? 0.7 : 1) }
    }
}

struct HoverHighlight<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        content
            .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onHover {
                LoopDetector.shared.tick("hover.propertyRow", detail: "\($0)")
                hovering = $0
            }
    }
}

// MARK: - Gallery

struct GalleryView: View {
    @Bindable var model: LibraryViewModel
    let actions: ItemActions

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Group {
                if model.showsEmptyLibrary {
                    ContentUnavailableView {
                        Label("Your brain is empty", systemImage: "brain")
                    } description: {
                        Text("Press ⌘⇧Space, or just start dragging something, and drop it in.")
                    }
                } else if model.showsNoResults {
                    ContentUnavailableView.search(text: model.queryString)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 340), spacing: 16, alignment: .top)],
                                  alignment: .leading, spacing: 16) {
                            ForEach(model.results) { result in
                                GalleryCard(
                                    item: result.item,
                                    tags: model.tagsByItem[result.id] ?? [],
                                    fileURL: actions.fileURL(for: result.item) ?? actions.previewURL(for: result.item),
                                    snippet: result.snippet,
                                    customTypeName: model.customType(for: result.item)?.name,
                                    selected: model.isSelected(result.id),
                                    showsRecognizedText: model.showsRecognizedText)
                                .onTapGesture(count: 2) { actions.open(result.item) }
                                .simultaneousGesture(TapGesture().onEnded {
                                    let mods = NSEvent.modifierFlags
                                    model.select(result.id, toggle: mods.contains(.command), extendRange: mods.contains(.shift))
                                })
                                .contextMenu { ItemContextMenu(model: model, actions: actions, item: result.item) }
                            }
                        }
                        .overlayScrollers()
                        .padding(.horizontal, 28)
                        .padding(.vertical, 18)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.content)
        .background {
            // ⌘A / Esc / ⌫ for the selection — ignored while typing in a field.
            LibraryKeyHandler { command in
                switch command {
                case .selectAll:
                    model.selectAll()
                case .clearSelection:
                    guard !model.selectedIDs.isEmpty else { return false }
                    model.clearSelection()
                case .trashSelection:
                    guard !model.selectedIDs.isEmpty else { return false }
                    try? model.trashSelected()
                    Task { await model.refresh() }
                }
                return true
            }
            .frame(width: 0, height: 0)
        }
        .overlay(alignment: .bottom) {
            if let error = model.errorMessage {
                Text(error)
                    .font(.callout)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Theme.tagBackgrounds[2], in: Capsule())
                    .foregroundStyle(Theme.tagForegrounds[2])
                    .padding(12)
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 6) {
            Icon(.brain, size: 16).foregroundStyle(Theme.secondary)
            Text("Library").foregroundStyle(Theme.secondary)
            if let crumb {
                Text("/").foregroundStyle(Theme.tertiary)
                Icon(crumb.icon, size: 15).foregroundStyle(Theme.secondary)
                Text(crumb.title)
            }
            Spacer()
            Text("\(model.results.count) item\(model.results.count == 1 ? "" : "s")")
                .foregroundStyle(Theme.tertiary)
        }
        .font(.system(size: 13.5))
        .lineLimit(1)
        .padding(.horizontal, 20)
        .frame(height: 46)
    }

    private var crumb: (title: String, icon: LucideIcon)? {
        let f = model.filters
        if let name = f.customType { return (name, .layers) }
        if let type = f.type { return (type.displayName, type.icon) }
        if !f.tags.isEmpty { return (f.tags.joined(separator: ", "), .tag) }
        if let color = f.color { return (color.capitalized, .palette) }
        return nil
    }
}

struct GalleryCard: View {
    let item: Item
    let tags: [ItemTag]
    let fileURL: URL?
    let snippet: String?
    let customTypeName: String?
    let selected: Bool
    var showsRecognizedText = false
    @State private var hovering = false

    /// OCR text of images is hidden unless enabled in Settings.
    enum InfoLine: Equatable { case url(String), snippet(String), blank }

    /// Card bottom line. Extracted text never appears on cards: PDF/link text
    /// never, OCR text only when "Show recognized text" is on; text notes show
    /// their search snippet.
    static func infoLine(for item: Item, snippet: String?, showsRecognizedText: Bool) -> InfoLine {
        if let url = item.url ?? item.meta["source_url"]?.stringValue { return .url(url) }
        let allowed = switch item.type {
        case .text: true
        case .image: showsRecognizedText
        case .pdf, .link: false
        }
        if allowed, let snippet, !snippet.isEmpty { return .snippet(snippet) }
        return .blank
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Thumbnail(item: item, fileURL: fileURL, maxPixel: 700)
                .frame(height: 170)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay(alignment: .topLeading) {
                    if let customTypeName {
                        Text(customTypeName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.tagText)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.tagBackgrounds[0], in: RoundedRectangle(cornerRadius: 4))
                            .padding(8)
                    }
                }
            // Fixed slots so every card has the same height.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Icon(item.type.icon, size: 15)
                        .foregroundStyle(Theme.secondary)
                    Text(item.title.isEmpty ? "Untitled" : item.title)
                        .font(.system(size: 14.5, weight: .semibold))
                        .lineLimit(1)
                }
                .frame(height: GalleryCard.titleHeight, alignment: .leading)
                Group {
                    if tags.isEmpty {
                        Color.clear
                    } else {
                        ScrollingChipRow(names: tags.map(\.name), size: .small)
                    }
                }
                .frame(height: GalleryCard.tagsHeight)
                infoLine
                    .frame(height: GalleryCard.infoHeight, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(selected ? Theme.accent : (hovering ? Theme.selectedRow : Theme.cardBorder),
                          lineWidth: selected ? 2 : 1))
        // Shadow only on hover: per-card shadows are re-rendered offscreen
        // on every layout pass and make resizing stutter.
        .shadow(color: .black.opacity(hovering ? 0.18 : 0), radius: hovering ? 6 : 0, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover {
            LoopDetector.shared.tick("hover.galleryCard", detail: "\($0)")
            hovering = $0
        }
    }

    static let titleHeight: CGFloat = 20
    static let tagsHeight: CGFloat = 20
    static let infoHeight: CGFloat = 16

    /// One line: URL, else a search snippet (text notes; images only if OCR text is shown), else blank.
    @ViewBuilder
    private var infoLine: some View {
        switch Self.infoLine(for: item, snippet: snippet, showsRecognizedText: showsRecognizedText) {
        case .url(let url):
            URLLabel(urlString: url, isClickable: false)
                .help(url)
        case .snippet(let text):
            highlighted(text.replacingOccurrences(of: "\n", with: " "))
                .font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
        case .blank:
            Color.clear
        }
    }

    func highlighted(_ snippet: String) -> Text {
        var attributed = AttributedString()
        for run in SnippetHighlighter.runs(snippet) {
            var part = AttributedString(run.text)
            if run.highlighted {
                part.inlinePresentationIntent = .stronglyEmphasized
                part.foregroundColor = Theme.primary
            }
            attributed += part
        }
        return Text(attributed)
    }
}

struct ItemContextMenu: View {
    let model: LibraryViewModel
    let actions: ItemActions
    let item: Item

    var body: some View {
        if model.isMultiSelection, model.isSelected(item.id) {
            Text("\(model.selectedIDs.count) items selected")
            Button("Move \(model.selectedIDs.count) Items to Trash", role: .destructive) {
                try? model.trashSelected()
                Task { await model.refresh() }
            }
        } else {
            singleItemMenu
        }
    }

    @ViewBuilder
    private var singleItemMenu: some View {
        Button("Open") { actions.open(item) }.disabled(!actions.canOpen(item))
        Button("Reveal in Finder") { actions.revealInFinder(item) }.disabled(!actions.canReveal(item))
        Button("Copy") { _ = try? actions.copy(item) }
        Divider()
        Button("Move to Trash", role: .destructive) {
            try? actions.trash(item)
            Task { await model.refresh() }
        }
        .keyboardShortcut(.delete, modifiers: .command)
    }
}

/// Whole picture (fit, never cropped) on a neutral background.
struct Thumbnail: View {
    let item: Item
    let fileURL: URL?
    var maxPixel: Int = 700

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.thumbBackground)
            // Links show their fetched preview image (a plain image file).
            if let fileURL, let image = ThumbnailCache.image(for: fileURL, type: item.type == .link ? .image : item.type, maxPixel: maxPixel) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(item.type == .pdf ? 10 : 0)
                    .shadow(color: item.type == .pdf ? .black.opacity(0.2) : .clear, radius: 3)
            } else {
                placeholder
            }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if item.type == .text, !item.content.isEmpty {
            Text(item.content)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.secondary)
                .lineLimit(8)
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Icon(item.type.icon, size: 30)
                .foregroundStyle(Theme.tertiary)
        }
    }
}

// MARK: - Properties panel

struct ItemPropertiesPanel: View {
    let model: LibraryViewModel
    let actions: ItemActions
    let item: Item
    @State private var title = ""
    @State private var saverBox = SaverBox()
    @State private var showTagEditor = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    TextField("Untitled", text: $title, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 30, weight: .bold))
                        .lineLimit(1...4)
                        // Autosaves after a pause; Return saves immediately.
                        .onChange(of: title) { _, new in titleSaver.schedule(new) }
                        .onSubmit { titleSaver.flush() }
                        .padding(.bottom, 18)

                    VStack(alignment: .leading, spacing: 2) {
                        PropertyRow(icon: .list, label: "Tags") { tagsValue }
                        PropertyRow(icon: item.type.icon, label: "Kind") {
                            Text(item.type.singularName)
                        }
                        if !model.customTypes.isEmpty {
                            PropertyRow(icon: .layers, label: "Type") { customTypeMenu }
                        }
                        PropertyRow(icon: .clock, label: "Created time") {
                            Text(item.createdAt.formatted(date: .long, time: .shortened))
                        }
                        PropertyRow(icon: .alignLeft, label: "Note", alignTop: true) {
                            InlineText(value: item.note, placeholder: "Empty", multiline: true) { new in
                                run { try model.saveNote(new, for: item.id) }
                            }
                        }
                        if let url = item.url ?? item.meta["source_url"]?.stringValue {
                            PropertyRow(icon: .link, label: "URL") { URLLabel(urlString: url, font: .system(size: 13.5)) }
                        }
                        if let type = model.customType(for: item) {
                            ForEach(type.fields) { field in
                                PropertyRow(icon: field.kind.icon, label: field.name, alignTop: field.kind == .largeText) {
                                    fieldValue(field)
                                }
                            }
                        }
                        addPropertyButton
                    }
                    if let errorText {
                        Text(errorText).font(.caption).foregroundStyle(.orange).padding(.top, 6)
                    }

                    Theme.divider.frame(height: 1).padding(.vertical, 20)
                    preview
                }
                .overlayScrollers()
                .padding(.horizontal, 30)
                .padding(.top, 8)
                .padding(.bottom, 36)
            }
        }
        .background(Theme.panel)
        .onAppear { title = item.title }
        .onDisappear { titleSaver.flush() } // switching item / closing panel keeps the edit
    }

    // Toolbar: close · open · reveal · copy · trash
    private var toolbar: some View {
        HStack(spacing: 14) {
            Button { model.selectedItemID = nil } label: { Icon(.chevronsRight, size: 16) }
                .help("Close")
            Spacer()
            Button { actions.open(item) } label: { Icon(.externalLink, size: 16) }
                .disabled(!actions.canOpen(item)).help("Open")
            Button { actions.revealInFinder(item) } label: { Icon(.folder, size: 16) }
                .disabled(!actions.canReveal(item)).help("Reveal in Finder")
            Button { _ = try? actions.copy(item) } label: { Icon(.copy, size: 16) }
                .help("Copy")
            Button {
                try? actions.trash(item)
                Task { await model.refresh() }
            } label: { Icon(.trash, size: 16) }
                .help("Move to Trash (⌘⌫)")
        }
        .buttonStyle(.plain)
        .font(.system(size: 14))
        .foregroundStyle(Theme.secondary)
        .padding(.horizontal, 18)
        .frame(height: 46)
    }

    private var tagsValue: some View {
        let tags = model.tags(for: item.id)
        return HStack(spacing: 4) {
            if tags.isEmpty {
                Text("Empty").foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { showTagEditor = true }
            } else {
                // Single line; scroll sideways for more. Click opens the editor.
                ScrollingChipRow(names: tags.map(\.name), fadeColor: Theme.panel)
                    .onTapGesture { showTagEditor = true }
                Button { showTagEditor = true } label: { Icon(.plus, size: 14) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.tertiary)
                    .help("Edit tags")
            }
        }
        .popover(isPresented: $showTagEditor, arrowEdge: .bottom) {
            TagEditor(
                tags: model.tags(for: item.id).map(\.name),
                allTags: model.allTags,
                onAdd: { name in run { try model.addTag(name, to: item.id) } },
                onRemove: { name in run { try model.removeTag(name, from: item.id) } })
        }
    }

    private var customTypeMenu: some View {
        Menu {
            Button("None") { run { try model.assignCustomType(nil, to: item.id) } }
            Divider()
            ForEach(model.customTypes) { type in
                Button(type.name) { run { try model.assignCustomType(type.id, to: item.id) } }
            }
        } label: {
            if let type = model.customType(for: item) {
                TagChip(name: type.name)
            } else {
                Text("Empty").foregroundStyle(Theme.tertiary)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private func fieldValue(_ field: FieldDefinition) -> some View {
        let value = item.fieldValues[field.id] ?? ""
        switch field.kind {
        case .text:
            InlineText(value: value, placeholder: "Empty") { new in save(new, field) }
        case .largeText:
            InlineText(value: value, placeholder: "Empty", multiline: true) { new in save(new, field) }
        case .webLink:
            InlineLink(value: value) { new in save(new, field) }
        }
    }

    private var addPropertyButton: some View {
        Menu {
            if model.customType(for: item) != nil {
                ForEach(FieldKind.allCases, id: \.self) { kind in
                    Button {
                        run { try model.addProperty(named: kind.title, kind: kind, toTypeOf: item) }
                    } label: { Label(kind.title, systemImage: kind.symbol) }
                }
            } else if model.customTypes.isEmpty {
                Text("Create a type in Settings › Types to add properties")
            } else {
                Section("Choose a type first") {
                    ForEach(model.customTypes) { type in
                        Button(type.name) { run { try model.assignCustomType(type.id, to: item.id) } }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Icon(.plus, size: 14)
                Text("Add a property")
            }
            .font(.system(size: 13.5))
            .foregroundStyle(Theme.tertiary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 6)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var preview: some View {
        switch item.type {
        case .image, .pdf:
            if let url = actions.fileURL(for: item), let image = ThumbnailCache.image(for: url, type: item.type, maxPixel: 1200) {
                PanelPreviewImage(image: image)
                    .onTapGesture(count: 2) { actions.open(item) }
            }
            // Extracted text (PDF text, OCR) stays searchable but isn't shown
            // here — except OCR when enabled in Settings.
            if item.type == .image, model.showsRecognizedText, !item.content.isEmpty {
                Text("Recognized Text")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .padding(.top, 18)
                contentText.padding(.top, -6)
            }
        case .link:
            if let url = actions.previewURL(for: item), let image = ThumbnailCache.image(for: url, type: .image, maxPixel: 1200) {
                PanelPreviewImage(image: image)
                    .onTapGesture(count: 2) { actions.open(item) }
            }
        case .text:
            if !item.content.isEmpty { contentText }
        }
    }

    private var contentText: some View {
        Text(item.content)
            .font(.system(size: 14))
            .lineSpacing(3)
            .textSelection(.enabled)
            .foregroundStyle(Theme.primary)
            .padding(.top, 12)
    }

    private func save(_ value: String, _ field: FieldDefinition) {
        run { try model.saveFieldValue(value, field: field.id, for: item.id) }
    }

    /// Debounced title saves; flushed on Return and when the panel goes away.
    private var titleSaver: DebouncedSaver {
        if let saver = saverBox.saver { return saver }
        let saver = DebouncedSaver { [model, id = item.id] new in
            do { try model.saveTitle(new, for: id) } catch {
                Log.shared.error("title save failed item=\(id): \(error)", "library")
            }
        }
        saverBox.saver = saver
        return saver
    }

    private func run(_ op: () throws -> Void) {
        do { try op(); errorText = nil } catch { errorText = error.localizedDescription }
    }
}

/// Holds the panel's saver so it's created once per panel, not per render.
@MainActor final class SaverBox { var saver: DebouncedSaver? }

/// Shown when several items are selected: bulk tag / type / trash.
struct MultiSelectionPanel: View {
    let model: LibraryViewModel
    let actions: ItemActions
    @State private var showTagEditor = false
    @State private var errorText: String?

    var body: some View {
        let items = model.selectedItems
        VStack(spacing: 0) {
            HStack {
                Button { model.clearSelection() } label: { Icon(.chevronsRight, size: 16) }
                    .help("Close")
                Spacer()
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 18)
            .frame(height: 46)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("\(items.count) items selected")
                        .font(.system(size: 26, weight: .bold))
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                        ForEach(items.prefix(12)) { item in
                            Thumbnail(item: item, fileURL: actions.fileURL(for: item) ?? actions.previewURL(for: item), maxPixel: 240)
                                .frame(height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                                .help(item.title)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        PropertyRow(icon: .tag, label: "Add tag") {
                            Button { showTagEditor = true } label: {
                                Text("Choose…").foregroundStyle(Theme.tertiary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: $showTagEditor, arrowEdge: .bottom) {
                                TagEditor(tags: [], allTags: model.allTags,
                                          onAdd: { name in run { try model.addTagToSelected(name) } },
                                          onRemove: { _ in })
                            }
                        }
                        if !model.customTypes.isEmpty {
                            PropertyRow(icon: .layers, label: "Set type") {
                                Menu {
                                    Button("None") { run { try model.assignCustomTypeToSelected(nil) } }
                                    Divider()
                                    ForEach(model.customTypes) { type in
                                        Button(type.name) { run { try model.assignCustomTypeToSelected(type.id) } }
                                    }
                                } label: { Text("Choose…").foregroundStyle(Theme.tertiary) }
                                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                            }
                        }
                    }
                    HStack {
                        Button("Move \(items.count) Items to Trash", role: .destructive) {
                            run { try model.trashSelected() }
                            Task { await model.refresh() }
                        }
                        Spacer()
                        Button("Deselect All") { model.clearSelection() }
                    }
                    if let errorText { Text(errorText).font(.caption).foregroundStyle(.orange) }
                    Text("⌘-click to add or remove items, ⇧-click for a range, ⌘A selects all, ⌘⌫ moves to Trash, Esc clears.")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiary)
                }
                .overlayScrollers()
                .padding(.horizontal, 30)
                .padding(.bottom, 30)
            }
        }
        .background(Theme.panel)
    }

    private func run(_ op: () throws -> Void) {
        do { try op(); errorText = nil } catch { errorText = error.localizedDescription }
    }
}

/// icon + gray label | value
struct PropertyRow<Value: View>: View {
    let icon: LucideIcon
    let label: String
    var alignTop = false
    @ViewBuilder var value: Value

    var body: some View {
        HStack(alignment: alignTop ? .top : .center, spacing: 0) {
            HStack(spacing: 8) {
                Icon(icon, size: 15).frame(width: 18)
                Text(label).lineLimit(1)
            }
            .foregroundStyle(Theme.secondary)
            .frame(width: 132, alignment: .leading)
            .padding(.top, alignTop ? 6 : 0)
            HoverHighlight {
                value
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                    .padding(.horizontal, 6)
            }
        }
        .font(.system(size: 14))
    }
}

/// Click to edit; Return or clicking away saves; Esc cancels. "Empty" when blank.
struct InlineText: View {
    let value: String
    var placeholder = "Empty"
    var multiline = false
    let onCommit: (String) -> Void
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        if editing {
            TextField("", text: $draft, axis: multiline ? .vertical : .horizontal)
                .textFieldStyle(.plain)
                .lineLimit(multiline ? 1...12 : 1...1)
                .focused($focused)
                .onSubmit(commit)
                .onExitCommand { editing = false }
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                .onAppear { focused = true }
                .padding(.vertical, 5)
        } else {
            Text(value.isEmpty ? placeholder : value)
                .foregroundStyle(value.isEmpty ? Theme.tertiary : Theme.primary)
                .lineLimit(multiline ? 12 : 1)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { draft = value; editing = true }
        }
    }

    private func commit() {
        guard editing else { return }
        editing = false
        if draft != value { onCommit(draft) }
    }
}

/// Web-link property: the link opens on click; the pencil edits.
struct InlineLink: View {
    let value: String
    let onCommit: (String) -> Void
    @State private var editing = false

    var body: some View {
        if editing || value.isEmpty {
            InlineText(value: value, placeholder: "Empty") { new in
                editing = false
                onCommit(new)
            }
        } else {
            HStack(spacing: 6) {
                if let url = CustomType.webURL(from: value) {
                    URLLabel(urlString: url.absoluteString, font: .system(size: 13.5))
                } else {
                    Text(value).foregroundStyle(Theme.primary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button { editing = true } label: { Icon(.pencil, size: 13) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.tertiary)
                    .help("Edit link")
            }
        }
    }
}

/// Tag picker: current chips (×), search/create field, existing options.
struct TagEditor: View {
    let tags: [String]
    let allTags: [String]
    let onAdd: (String) -> Void
    let onRemove: (String) -> Void
    @State private var query = ""
    @State private var current: [String] = []
    @FocusState private var focused: Bool

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var options: [String] {
        let taken = Set(current.map { $0.lowercased() })
        return allTags.filter { !taken.contains($0.lowercased()) && (trimmed.isEmpty || $0.localizedCaseInsensitiveContains(trimmed)) }
    }
    private var canCreate: Bool {
        !trimmed.isEmpty && !allTags.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
            && !current.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                if !current.isEmpty {
                    FlowLayout {
                        ForEach(current, id: \.self) { name in
                            TagChip(name: name) { remove(name) }
                        }
                    }
                }
                TextField("Search for an option…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .focused($focused)
                    .onSubmit(submit)
            }
            .padding(10)
            .background(Theme.field)
            Text(canCreate || !options.isEmpty ? "Select an option or create one" : "Type to create a tag")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if canCreate {
                        optionRow {
                            Text("Create").foregroundStyle(Theme.secondary)
                            TagChip(name: trimmed)
                        } action: { add(trimmed) }
                    }
                    ForEach(options, id: \.self) { name in
                        optionRow { TagChip(name: name) } action: { add(name) }
                    }
                }
                .overlayScrollers()
                .padding(.horizontal, 4)
                .padding(.bottom, 6)
            }
            .frame(maxHeight: 260)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 300)
        .onAppear {
            current = tags
            focused = true
        }
    }

    private func optionRow<L: View>(@ViewBuilder label: () -> L, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) { label(); Spacer() }
                .padding(.horizontal, 8)
                .frame(height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(SidebarButtonStyle())
    }

    private func submit() {
        if canCreate { add(trimmed) } else if let first = options.first { add(first) }
    }

    private func add(_ name: String) {
        guard !current.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        current.append(name)
        onAdd(name)
        query = ""
    }

    private func remove(_ name: String) {
        current.removeAll { $0 == name }
        onRemove(name)
    }
}
