import AppKit
import MiniBrainCore
import SwiftUI
import UniformTypeIdentifiers

/// Reads image bytes from a drop: an image file from Finder, or image data
/// dragged out of a browser / Photos / Preview.
@MainActor
enum ImageDropLoader {
    static let acceptedTypes: [UTType] = [.fileURL, .image]

    static func data(from providers: [NSItemProvider]) async -> Data? {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let url = try? await ItemProviderMapper.loadURL(provider, type: .fileURL), url.isFileURL,
               let data = imageFileData(url) {
                return data
            }
            if let type = ItemProviderMapper.preferredImageType(provider),
               let data = try? await ItemProviderMapper.loadData(provider, type: type), !data.isEmpty {
                return data
            }
        }
        return nil
    }

    /// Bytes of an image file; nil for other files.
    static func imageFileData(_ url: URL) -> Data? {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func chooseImageFile() -> Data? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an image"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return imageFileData(url)
    }
}

/// The detail panel's picture: shows the image (or an empty drop area), takes
/// image drops / a chosen file, and offers Remove for custom covers.
struct ItemImageSlot: View {
    let image: NSImage?
    /// Image items replace their picture; others get a cover.
    let isImageItem: Bool
    let canRemove: Bool
    let onImage: (Data) -> Void
    let onRemove: () -> Void
    let onOpen: () -> Void
    @State private var targeted = false

    var body: some View {
        Group {
            if let image {
                PanelPreviewImage(image: image)
                    .onTapGesture(count: 2, perform: onOpen)
                    .help(isImageItem ? "Double-click to open · drop an image to replace"
                                      : "Double-click to open the image · drop an image to use as cover")
            } else {
                emptyArea
            }
        }
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.accent.opacity(0.10))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.accent, lineWidth: 2))
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: ImageDropLoader.acceptedTypes, isTargeted: $targeted) { providers in
            Task { @MainActor in
                if let data = await ImageDropLoader.data(from: providers) { onImage(data) }
            }
            return true
        }
        .contextMenu {
            Button(image == nil ? "Choose Image…" : (isImageItem ? "Replace Image…" : "Change Cover…"), action: choose)
            if canRemove { Button("Remove Cover", role: .destructive, action: onRemove) }
        }
        .animation(.easeOut(duration: 0.12), value: targeted)
    }

    private var emptyArea: some View {
        VStack(spacing: 6) {
            Icon(.image, size: 20)
            Text("Drop an image, or click to choose").font(.system(size: 12.5))
        }
        .foregroundStyle(Theme.tertiary)
        .frame(maxWidth: .infinity, minHeight: 110)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Theme.divider, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        .contentShape(Rectangle())
        .onTapGesture(perform: choose)
    }

    private func choose() {
        if let data = ImageDropLoader.chooseImageFile() { onImage(data) }
    }
}

/// URL property: the link opens on click and the pencil edits. Invalid input
/// ("hello world") shows why and is not saved; Esc cancels.
struct InlineURLField: View {
    let value: String
    let onCommit: (String) throws -> Void
    @State private var editing = false
    @State private var draft = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if editing {
                TextField("URL", text: $draft, prompt: Text(verbatim: "https://… or example.com").foregroundStyle(Theme.tertiary))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { commit(refocus: true) }
                    .onExitCommand { releaseFocus(); cancel() }
                    .onChange(of: focused) { _, isFocused in if !isFocused, editing { commit(refocus: false) } }
                    .onChange(of: draft) { error = nil }
                    .deferredFocus($focused)
                    .padding(.vertical, 5)
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if value.isEmpty {
                Text("Empty")
                    .foregroundStyle(Theme.tertiary)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: start)
            } else {
                HStack(spacing: 6) {
                    URLLabel(urlString: value, font: .system(size: 13.5))
                    Spacer(minLength: 4)
                    Button(action: start) { Icon(.pencil, size: 13) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.tertiary)
                        .help("Edit URL")
                }
                .padding(.vertical, 5)
            }
        }
    }

    private func start() {
        draft = value
        error = nil
        editing = true
    }

    private func cancel() {
        error = nil
        editing = false
    }

    /// Saves when valid; on error stays in edit mode with the reason shown
    /// (nothing is saved). Return keeps the cursor in the field.
    private func commit(refocus: Bool) {
        guard editing else { return }
        if draft.trimmingCharacters(in: .whitespacesAndNewlines) == value {
            if refocus { releaseFocus() }
            cancel()
            return
        }
        do {
            try onCommit(draft)
            if refocus { releaseFocus() }
            cancel()
        } catch {
            self.error = error.localizedDescription
            if refocus { focused = true }
        }
    }
}
