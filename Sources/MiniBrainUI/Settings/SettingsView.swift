import AppKit
import MiniBrainCore
import SwiftUI
#if canImport(KeyboardShortcuts)
import KeyboardShortcuts
#endif

public struct SettingsView: View {
    @Bindable var preferences: AppPreferences
    @Bindable var navigation: SettingsNavigation
    let shortcuts: ShortcutSettings
    let types: TypesSettings?
    let storage: StorageSettings?
    let onDockModeChange: () -> Void
    let onRecognizedTextVisibilityChange: () -> Void
    let clearRecognizedText: () throws -> Int
    let onPositionChange: () -> Void

    public init(preferences: AppPreferences, navigation: SettingsNavigation, shortcuts: ShortcutSettings,
                types: TypesSettings?, storage: StorageSettings?,
                onDockModeChange: @escaping () -> Void = {},
                onRecognizedTextVisibilityChange: @escaping () -> Void = {},
                clearRecognizedText: @escaping () throws -> Int = { 0 },
                onPositionChange: @escaping () -> Void) {
        self.preferences = preferences
        self.navigation = navigation
        self.shortcuts = shortcuts
        self.types = types
        self.storage = storage
        self.onDockModeChange = onDockModeChange
        self.onRecognizedTextVisibilityChange = onRecognizedTextVisibilityChange
        self.clearRecognizedText = clearRecognizedText
        self.onPositionChange = onPositionChange
    }

    public var body: some View {
        TabView(selection: $navigation.tab) {
            GeneralSettingsTab(preferences: preferences, onPositionChange: onPositionChange,
                               onDockModeChange: onDockModeChange,
                               onRecognizedTextVisibilityChange: onRecognizedTextVisibilityChange,
                               clearRecognizedText: clearRecognizedText)
                .tabItem { Label { Text("General") } icon: { Icon(.settings, size: 18) } }
                .tag(SettingsNavigation.Tab.general)
            ShortcutsSettingsTab(shortcuts: shortcuts)
                .tabItem { Label { Text("Shortcuts") } icon: { Icon(.keyboard, size: 18) } }
                .tag(SettingsNavigation.Tab.shortcuts)
            Group {
                if let types { TypesSettingsTab(model: types) } else { unavailable }
            }
            .tabItem { Label { Text("Types") } icon: { Icon(.layers, size: 18) } }
            .tag(SettingsNavigation.Tab.types)
            Group {
                if let storage { StorageSettingsTab(storage: storage) } else { unavailable }
            }
            .tabItem { Label { Text("Storage") } icon: { Icon(.hardDrive, size: 18) } }
            .tag(SettingsNavigation.Tab.storage)
        }
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
        .tint(Theme.accent)
    }

    private var unavailable: some View {
        Text("Library couldn't be opened.").foregroundStyle(.secondary).padding(40)
    }
}

// MARK: - Types

struct TypesSettingsTab: View {
    @Bindable var model: TypesSettings
    @State private var confirmDelete = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                List(selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
                    ForEach(model.types) { type in
                        Label { Text(type.name) } icon: { Icon(.layers, size: 14) }.tag(type.id as String?)
                    }
                }
                .listStyle(.bordered)
                HStack(spacing: 0) {
                    Button { model.addType() } label: { Icon(.plus, size: 14).frame(width: 24, height: 20) }
                        .help("New type")
                    Button { confirmDelete = true } label: { Icon(.minus, size: 14).frame(width: 24, height: 20) }
                        .disabled(model.selectedID == nil)
                        .help("Delete type")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(4)
            }
            .frame(width: 180, height: 330)
            .padding(16)

            Group {
                if model.draft != nil {
                    editor
                } else {
                    ContentUnavailableView {
                        Label { Text("No Custom Types") } icon: { Icon(.layers, size: 28) }
                    } description: {
                        Text("Create types like “Products” with your own fields. Hold ⇧ while dropping to save into one.")
                    } actions: {
                        Button("New Type") { model.addType() }
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 360, alignment: .top)
        }
        .onDisappear { model.commit() }
        .confirmationDialog("Delete “\(model.draft?.name ?? "")”?", isPresented: $confirmDelete) {
            Button("Delete Type", role: .destructive) { model.deleteSelected() }
        } message: {
            let count = model.selectedID.map(model.itemCount(for:)) ?? 0
            Text(count == 0 ? "No items use this type." : "\(count) item\(count == 1 ? "" : "s") will keep their content but lose this type and its field values.")
        }
    }

    private var editor: some View {
        Form {
            Section {
                TextField("Type Name", text: Binding(get: { model.draft?.name ?? "" }, set: { model.draft?.name = $0 }))
                    .onSubmit { model.commit() }
                if let error = model.error {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }
            Section {
                if let fields = model.draft?.fields, !fields.isEmpty {
                    ForEach(Array(fields.enumerated()), id: \.element.id) { index, field in
                        fieldRow(field, index: index, count: fields.count)
                    }
                } else {
                    Text("No fields yet.").foregroundStyle(.secondary)
                }
            } header: {
                Text("Fields")
            } footer: {
                HStack {
                    Menu("Add Field") {
                        ForEach(FieldKind.allCases, id: \.self) { kind in
                            Button(kind.title) { model.addField(kind) }
                        }
                    }
                    .fixedSize()
                    Spacer()
                    Text("Press Return to save a name.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func fieldRow(_ field: FieldDefinition, index: Int, count: Int) -> some View {
        HStack(spacing: 8) {
            TextField("Field name", text: Binding(
                get: { model.draft?.fields.first { $0.id == field.id }?.name ?? "" },
                set: { new in
                    if let i = model.draft?.fields.firstIndex(where: { $0.id == field.id }) { model.draft?.fields[i].name = new }
                }))
                .labelsHidden()
                .onSubmit { model.commit() }
            Picker("Kind", selection: Binding(get: { field.kind }, set: { model.setKind($0, for: field.id) })) {
                ForEach(FieldKind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Button { model.moveField(field.id, by: -1) } label: { Icon(.chevronDown, size: 13).rotationEffect(.degrees(180)) }
                .disabled(index == 0)
            Button { model.moveField(field.id, by: 1) } label: { Icon(.chevronDown, size: 13) }
                .disabled(index == count - 1)
            Button(role: .destructive) { model.removeField(field.id) } label: { Icon(.trash, size: 13) }
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    @Bindable var preferences: AppPreferences
    let onPositionChange: () -> Void
    var onDockModeChange: () -> Void = {}
    var onRecognizedTextVisibilityChange: () -> Void = {}
    var clearRecognizedText: () throws -> Int = { 0 }
    @State private var confirmClear = false
    @State private var clearMessage: String?

    var body: some View {
        Form {
            Section("App") {
                Picker("Show in Dock", selection: $preferences.dockMode) {
                    ForEach(DockMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            Section("Drop Box") {
                Toggle("Show drop box when dragging anything", isOn: $preferences.autoShowOnDrag)
                Toggle("Auto-tag every drop", isOn: $preferences.autoTag)
                Toggle("Optimize images to WebP", isOn: $preferences.optimizeImages)
                    .help("Saved images and link previews are re-encoded as WebP when that makes them smaller. Animated GIFs are kept as they are.")
                    .help("Suggest tags with on-device AI for each new item. In the drop box: ← Off, → On, Return toggles.")
                LabeledContent("Position") {
                    HStack(alignment: .center, spacing: 14) {
                        PositionPicker(selection: $preferences.dropBoxPosition)
                        Text(preferences.dropBoxPosition.title)
                            .foregroundStyle(.secondary)
                            .frame(width: 110, alignment: .leading)
                    }
                }
                Text("The drop box always opens here, on the screen with the pointer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Fetch previews for links", isOn: $preferences.linkPreviews)
            } header: {
                Text("Links")
            } footer: {
                Text("Downloads each saved page’s preview image and title. This is the only feature that uses the internet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Recognize text in images", isOn: $preferences.ocrEnabled)
                Toggle("Show recognized text in library", isOn: $preferences.showRecognizedText)
                HStack {
                    if let clearMessage {
                        Text(clearMessage).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove Recognized Text…") { confirmClear = true }
                }
            } header: {
                Text("Text Recognition (OCR)")
            } footer: {
                Text("Reads text inside images on this Mac so you can search for it. Turning it off stops new images from being read; existing text stays until you remove it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: preferences.dropBoxPosition) { onPositionChange() }
        .onChange(of: preferences.showRecognizedText) { onRecognizedTextVisibilityChange() }
        .onChange(of: preferences.dockMode) { onDockModeChange() }
        .confirmationDialog("Remove recognized text from all saved images?", isPresented: $confirmClear) {
            Button("Remove Text", role: .destructive) {
                do {
                    let n = try clearRecognizedText()
                    clearMessage = n == 0 ? "No saved images had recognized text." : "Removed text from \(n) image\(n == 1 ? "" : "s")."
                } catch {
                    clearMessage = error.localizedDescription
                }
            }
        } message: {
            Text("The images stay; only the text read from them is deleted, so it no longer appears in search.")
        }
    }
}

/// 3×3 grid drawn like a screen; click a cell to choose the position.
struct PositionPicker: View {
    @Binding var selection: DropBoxPosition

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.quaternary)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.secondary.opacity(0.4)))
            .frame(width: 150, height: 96)
            .overlay {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(0..<3, id: \.self) { row in
                        GridRow {
                            ForEach(0..<3, id: \.self) { column in
                                cell(DropBoxPosition.allCases[row * 3 + column])
                            }
                        }
                    }
                }
                .padding(6)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Drop box position")
    }

    func cell(_ position: DropBoxPosition) -> some View {
        let selected = position == selection
        return Button { selection = position } label: {
            RoundedRectangle(cornerRadius: 3)
                .fill(selected ? Theme.accent : Color.secondary.opacity(0.25))
                .frame(width: selected ? 30 : 22, height: selected ? 20 : 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(position.title)
        .accessibilityLabel(position.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(.snappy(duration: 0.15), value: selected)
    }
}

// MARK: - Shortcuts

struct ShortcutsSettingsTab: View {
    let shortcuts: ShortcutSettings

    var body: some View {
        Form {
            Section {
                ForEach(Hotkey.allCases, id: \.self) { hotkey in
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent(hotkey.title) { recorder(for: hotkey) }
                        if let error = shortcuts.errors[hotkey] {
                            Text(error).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            } footer: {
                Text("Click a shortcut, then press the new keys. Use ⌘, ⌥ or ⌃. Esc cancels, Delete clears.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if shortcuts.supportsCustomCombos {
                HStack {
                    Spacer()
                    Button("Restore Defaults") { shortcuts.resetToDefaults() }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    func recorder(for hotkey: Hotkey) -> some View {
        #if canImport(KeyboardShortcuts)
        KeyboardShortcuts.Recorder(for: hotkey.shortcutName)
        #else
        ShortcutRecorderField(
            combo: shortcuts.combo(for: hotkey),
            onRecord: { shortcuts.set($0, for: hotkey) },
            onRecordingChange: { shortcuts.setRecording($0) })
        #endif
    }
}

/// Click-to-record shortcut field (used when KeyboardShortcuts isn't built in).
struct ShortcutRecorderField: View {
    let combo: KeyCombo?
    let onRecord: (KeyCombo?) -> Void
    let onRecordingChange: (Bool) -> Void
    @State private var recording = false
    @State private var monitor: Any?
    @State private var shake = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                Text(recording ? "Press shortcut…" : (combo?.displayString ?? "Record Shortcut"))
                    .monospacedDigit()
                    .frame(minWidth: 130)
                    .foregroundStyle(recording ? Theme.accent : (combo == nil ? .secondary : .primary))
            }
            .offset(x: shake ? -4 : 0)
            if combo != nil, !recording {
                Button { onRecord(nil) } label: { Icon(.circleX) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Clear shortcut")
            }
        }
        .onDisappear(perform: stop)
    }

    func toggle() { recording ? stop() : start() }

    func start() {
        recording = true
        onRecordingChange(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch ShortcutRecording.interpret(keyCode: event.keyCode, modifiers: event.modifierFlags) {
            case .cancel: stop()
            case .clear: onRecord(nil); stop()
            case .record(let combo): onRecord(combo); stop()
            case .invalid:
                NSSound.beep()
                withAnimation(.spring(response: 0.15, dampingFraction: 0.2)) { shake.toggle() }
                withAnimation(.spring.delay(0.15)) { shake = false }
            }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { onRecordingChange(false) }
        recording = false
    }
}

// MARK: - Storage

struct StorageSettingsTab: View {
    let storage: StorageSettings

    var body: some View {
        Form {
            Section("Library Location") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(storage.path)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text("\(storage.itemCount) items · \(storage.sizeDescription)\(storage.isDefaultLocation ? " · Default location" : "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Reveal in Finder") { storage.revealInFinder() }
                    Spacer()
                    if !storage.isDefaultLocation {
                        Button("Use Default") { storage.resetToDefault() }
                    }
                    Button("Change…") { storage.chooseNewLocation() }
                }
                .disabled(storage.isOverriddenByEnvironment)
                if storage.isOverriddenByEnvironment {
                    Text("Set by MINIBRAIN_DATA_DIR; unset it to change here.").font(.caption).foregroundStyle(.secondary)
                }
                if let message = storage.message {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { storage.refresh() }
    }
}
