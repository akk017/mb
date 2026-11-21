import AppKit
import MiniBrainCore
import SwiftUI
import UniformTypeIdentifiers

/// Floating capture target: a main "Drop to save" zone plus one drop zone
/// per custom type. ⇧ while dropping on the main zone opens a type chooser.
public struct DropBoxView: View {
    @Bindable var model: DropBoxViewModel

    public init(model: DropBoxViewModel) { self.model = model }

    public var body: some View {
        Group {
            switch model.state {
            case .choosingType(let types):
                TypeChooserView(model: model, types: types)
            case .editingFields(let item, let type):
                FieldsFormView(model: model, item: item, type: type)
            default:
                VStack(spacing: 0) {
                    mainZone
                    if !model.types.isEmpty { typeZones }
                    AutoTagSwitch(isOn: model.autoTag) { model.setAutoTag($0) }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                }
                .frame(width: model.types.isEmpty ? 220 : 260)
            }
        }
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.divider))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .foregroundStyle(Theme.primary)
        .tint(Theme.accent)
        .animation(.snappy(duration: 0.18), value: model.state)
        .animation(.snappy(duration: 0.18), value: model.hoveredTypeID)
    }

    private var mainHovered: Bool { model.state == .hovering && model.hoveredTypeID == nil }

    private var mainZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(mainHovered ? Theme.accent.opacity(0.12) : .clear)
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(borderColor, style: StrokeStyle(lineWidth: 1.5, dash: mainHovered ? [] : [5, 4]))
            VStack(spacing: 6) {
                Icon(symbol, size: 28)
                    .foregroundStyle(borderColor)
                Text(caption)
                    .font(.system(size: 13, weight: .medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .foregroundStyle(Theme.secondary)
            }
            .padding(12)
        }
        .frame(height: model.types.isEmpty ? 148 : 118)
        .padding(6)
        .contentShape(Rectangle())
        .onDrop(of: ItemProviderMapper.acceptedTypes, delegate: MainZoneDropDelegate(model: model))
        .overlay(alignment: .topTrailing) {
            if model.state == .idle {
                Button { Task { await model.paste(NSPasteboard.general, chooseType: ShiftKey.isDown) } } label: {
                    Icon(.clipboardPaste, size: 14)
                        .frame(width: 26, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondary)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 6))
                .help("Paste from clipboard (⌘V)")
                .padding(12)
            }
        }
    }

    private var typeZones: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Save to type")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondary)
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(model.types) { type in
                    TypeDropZone(model: model, type: type)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var symbol: LucideIcon {
        switch model.state {
        case .hovering: mainHovered ? .arrowDownToLine : .inbox
        case .saving: .hourglass
        case .saved: .circleCheck
        case .error: .triangleAlert
        default: .inbox
        }
    }

    private var caption: String {
        switch model.state {
        case .hovering: mainHovered ? "Release to save" : "Drop to save"
        case .saving: "Saving…"
        case .saved(let title): "Saved \(title.isEmpty ? "" : "“\(title)”")"
        case .error(let message): message
        default: "Drop or ⌘V to save"
        }
    }

    private var borderColor: Color {
        switch model.state {
        case .hovering: mainHovered ? .accentColor : Theme.tertiary
        case .saving: .accentColor
        case .saved: Theme.attention
        case .error: .orange
        default: Theme.tertiary
        }
    }
}

/// "Auto-tag  Off | On" — click, or ←/→ to pick and Return to toggle while
/// the drop box is focused.
struct AutoTagSwitch: View {
    let isOn: Bool
    let set: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Icon(.tag, size: 13).foregroundStyle(Theme.secondary)
            Text("Auto-tag").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                segment("Off", selected: !isOn) { set(false) }
                segment("On", selected: isOn) { set(true) }
            }
            .padding(2)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .help("Auto-tag every drop — ← Off · → On · Return toggles")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Auto-tag every drop")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAdjustableAction { direction in
            set(direction == .increment)
        }
    }

    private func segment(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .frame(width: 34, height: 20)
                .foregroundStyle(selected ? Theme.onAccent : Theme.secondary)
                .background(selected ? Theme.accent : .clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Reads ⇧ from the system-wide keyboard state (works while another app
/// owns the drag) — sampled during hover and again at drop.
enum ShiftKey {
    static var isDown: Bool { CGEventSource.flagsState(.combinedSessionState).contains(.maskShift) }
}

struct MainZoneDropDelegate: DropDelegate {
    let model: DropBoxViewModel

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated { model.dragEntered() }
    }

    func dropExited(info: DropInfo) {
        MainActor.assumeIsolated { model.dragExited() }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        MainActor.assumeIsolated { model.shiftSeenDuringHover = model.shiftSeenDuringHover || ShiftKey.isDown }
        return DropProposal(operation: .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: ItemProviderMapper.acceptedTypes)
        MainActor.assumeIsolated {
            let chooseType = ShiftKey.isDown || model.shiftSeenDuringHover
            model.shiftSeenDuringHover = false
            Task { await model.drop(providers, chooseType: chooseType) }
        }
        return true
    }
}

/// One custom type as its own drop target.
struct TypeDropZone: View {
    let model: DropBoxViewModel
    let type: CustomType
    @State private var targeted = false

    var body: some View {
        let on = model.hoveredTypeID == type.id
        HStack(spacing: 5) {
            Icon(.layers, size: 13)
            Text(type.name)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(on ? Theme.onAccent : TagPalette.foreground(for: type.name))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(on ? Theme.accent : TagPalette.background(for: type.name),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .scaleEffect(on ? 1.06 : 1)
        .contentShape(Rectangle())
        .onDrop(of: ItemProviderMapper.acceptedTypes, isTargeted: Binding(
            get: { on },
            set: { $0 ? model.dragEntered(zone: type.id) : model.dragExited(zone: type.id) }
        )) { providers in
            Task { await model.drop(providers, into: type) }
            return true
        }
        .help("Drop here to save as \(type.name)")
    }
}

/// ⇧-drop step 1: pick the custom type.
struct TypeChooserView: View {
    let model: DropBoxViewModel
    let types: [CustomType]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Save as…").font(.headline)
            if types.isEmpty {
                Text("No custom types yet. Create one (e.g. “Products”) in Settings › Types.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Settings…") { model.openSettings() }
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(types) { type in
                            Button { Task { await model.choose(type) } } label: {
                                HStack {
                                    Icon(.layers, size: 15)
                                        .foregroundStyle(Theme.accent)
                                    Text(type.name).fontWeight(.medium)
                                    Spacer()
                                    Text("\(type.fields.count) field\(type.fields.count == 1 ? "" : "s")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .contentShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(ChooserRowStyle())
                        }
                    }
                }
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Button("Cancel", role: .cancel) { model.cancelChoice() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save Without Type") { Task { await model.choose(nil) } }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 280)
        .onAppear(perform: focusPanel)
    }
}

struct ChooserRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? Theme.accent.opacity(0.25) : Theme.field))
    }
}

/// ⇧-drop step 2: fill the type's fields (prefilled where possible).
struct FieldsFormView: View {
    let model: DropBoxViewModel
    let item: Item
    let type: CustomType
    @State private var values: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(type.name).font(.headline)
                Text(item.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(type.fields) { field in
                        FieldEditor(field: field, value: binding(field.id))
                    }
                }
            }
            .frame(maxHeight: 340)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Button("Skip") { model.skipFields() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { model.saveFields(values) }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            values = item.fieldValues
            focusPanel()
        }
    }

    func binding(_ id: String) -> Binding<String> {
        Binding(get: { values[id] ?? "" }, set: { values[id] = $0 })
    }
}

/// One field input: Text, Large Text, or Web Link (with an open button).
struct FieldEditor: View {
    let field: FieldDefinition
    @Binding var value: String
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(field.name).font(.caption.weight(.medium)).foregroundStyle(Theme.secondary)
            fieldInput
        }
    }

    @ViewBuilder
    private var fieldInput: some View {
        switch field.kind {
        case .text:
            TextField(field.name, text: $value, prompt: Text(field.name).foregroundStyle(Theme.tertiary))
                .labelsHidden()
                .textFieldStyle(.plain)
                .focused($focused)
                .formFieldChrome(focused: focused)
        case .largeText:
            TextEditor(text: $value)
                .font(.body)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .focused($focused)
                .frame(minHeight: 64, maxHeight: 120)
                .formFieldChrome(focused: focused, vertical: 5)
        case .webLink:
            HStack(spacing: 6) {
                TextField(field.name, text: $value, prompt: Text(verbatim: "https://…").foregroundStyle(Theme.tertiary))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .formFieldChrome(focused: focused)
                WebLinkButton(value: value)
            }
        }
    }
}

extension View {
    /// Shared look for form inputs: solid fill, 1px border that turns
    /// accent-colored on focus (drawn inside, so it is never clipped), and
    /// no system focus ring.
    func formFieldChrome(focused: Bool, vertical: CGFloat = 7) -> some View {
        self
            .focusEffectDisabled()
            .padding(.horizontal, 9)
            .padding(.vertical, vertical)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(focused ? Theme.accent : Theme.divider, lineWidth: focused ? 1.5 : 1))
            .animation(.easeOut(duration: 0.12), value: focused)
    }
}

/// Clickable link for a web-link field value (disabled when not a URL).
struct WebLinkButton: View {
    let value: String

    var body: some View {
        if let url = CustomType.webURL(from: value) {
            Link(destination: url) { Icon(.externalLink, size: 15) }
                .help("Open \(url.absoluteString)")
        } else {
            Icon(.externalLink, size: 15).foregroundStyle(.tertiary)
        }
    }
}

@MainActor
private func focusPanel() {
    DispatchQueue.main.async { NSApp.windows.first { $0 is DropBoxPanel }?.makeKey() }
}

/// Non-activating floating panel that shows on every Space and over
/// full-screen apps. Resizes to its content and stays pinned to `anchor`.
public final class DropBoxPanel: NSPanel {
    public var anchor: DropBoxPosition = .topRight
    /// ⌘V while the panel is key. Menu-bar apps have no Edit menu, so the
    /// panel handles the key equivalent itself.
    public var onPaste: (() -> Void)?
    /// Esc closes the panel.
    public var onEscape: (() -> Void)?
    /// ⌘, opens Settings.
    public var onOpenSettings: (() -> Void)?
    /// ←/→/Return while focused (auto-tag switch). Return true if handled.
    public var onArrowKey: ((DropBoxKey) -> Bool)?

    public enum DropBoxKey: Equatable { case left, right, enter }

    public override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        if plain, !(firstResponder is NSText), let onArrowKey {
            let key: DropBoxKey? = switch Int(event.keyCode) {
            case 123: .left       // kVK_LeftArrow
            case 124: .right      // kVK_RightArrow
            case 36, 76: .enter   // Return, keypad Enter
            default: nil
            }
            if let key, onArrowKey(key) { return }
        }
        super.keyDown(with: event)
    }
    private var resizeObserver: NSObjectProtocol?

    public init(content: some View) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 160),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = [.preferredContentSize]
        contentViewController = controller
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: self, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reposition(self.anchor)
            }
        }
    }

    public override var canBecomeKey: Bool { true }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.shift, .capsLock])
        if mods == .command, event.charactersIgnoringModifiers == ",", let onOpenSettings {
            onOpenSettings()
            return true
        }
        if mods == .command, event.charactersIgnoringModifiers?.lowercased() == "v",
           !(firstResponder is NSText), let onPaste {
            onPaste()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    public override func cancelOperation(_ sender: Any?) {
        if let onEscape { onEscape() } else { super.cancelOperation(sender) }
    }

    /// Shows the panel at the chosen spot on the screen with the pointer.
    /// `takeFocus` makes it key (for ⌘V); drags leave focus with the source app.
    public func show(at position: DropBoxPosition, takeFocus: Bool) {
        reposition(position)
        orderFrontRegardless()
        if takeFocus { makeKey() }
    }

    public func reposition(_ position: DropBoxPosition) {
        anchor = position
        let mouse = NSEvent.mouseLocation
        let screen = (isVisible ? self.screen : nil)
            ?? NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let origin = position.origin(panelSize: frame.size, in: visible)
        if frame.origin != origin { setFrameOrigin(origin) }
    }
}
