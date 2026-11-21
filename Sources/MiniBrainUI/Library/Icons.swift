import AppKit
import SwiftUI

/// Lucide icon set (https://lucide.dev, ISC license), bundled as SVGs.
enum LucideIcon: String, CaseIterable {
    case search, circleX = "circle-x", layoutGrid = "layout-grid", stickyNote = "sticky-note"
    case fileText = "file-text", image, link, layers, list, clock, alignLeft = "align-left", type
    case externalLink = "external-link", folder, copy, trash = "trash-2", chevronsRight = "chevrons-right"
    case chevronDown = "chevron-down", plus, pencil, brain, tag, palette, inbox, hourglass
    case circleCheck = "circle-check", triangleAlert = "triangle-alert", clipboardPaste = "clipboard-paste"
    case minus, x, globe, settings, keyboard, hardDrive = "hard-drive", arrowDownToLine = "arrow-down-to-line"

    @MainActor private static var cache: [LucideIcon: NSImage] = [:]

    static let bundleName = "MiniBrain_MiniBrainUI.bundle"

    /// Where the icon resources live. SwiftPM's `Bundle.module` only looks next
    /// to the .app (not in Contents/Resources) and otherwise falls back to the
    /// absolute build folder — then `fatalError`s on other machines. So check
    /// the app's Resources first and only use `Bundle.module` in dev/test runs.
    static func resourceBundle(main: Bundle = .main) -> Bundle? {
        let candidates = [main.resourceURL, main.bundleURL].compactMap { $0?.appendingPathComponent(bundleName) }
        for url in candidates { if let bundle = Bundle(url: url) { return bundle } }
        return nil
    }

    static let bundle: Bundle = resourceBundle() ?? Bundle.module

    /// Template NSImage (tinted by foregroundStyle), nil if the file is missing.
    @MainActor var image: NSImage? {
        if let hit = Self.cache[self] { return hit }
        guard let url = Self.bundle.url(forResource: rawValue, withExtension: "svg", subdirectory: "Icons"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        Self.cache[self] = image
        return image
    }
}

/// A Lucide icon sized like text.
struct Icon: View {
    let icon: LucideIcon
    var size: CGFloat = 15

    init(_ icon: LucideIcon, size: CGFloat = 15) {
        self.icon = icon
        self.size = size
    }

    var body: some View {
        if let image = icon.image {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }
}

/// Menu-bar glyph (brain-4-line.svg), template so it follows the menu bar's
/// light/dark appearance.
@MainActor
public enum MenuBarIcon {
    /// True when the custom SVG loaded (false = system fallback symbol).
    public static var isCustom: Bool { customImage != nil }

    static let customImage: NSImage? = {
        guard let url = LucideIcon.bundle.url(forResource: "brain-4-line", withExtension: "svg", subdirectory: "Icons")
        else { return nil }
        return NSImage(contentsOf: url)
    }()

    public static let image: NSImage = {
        guard let image = customImage?.copy() as? NSImage else {
            return NSImage(systemSymbolName: "brain", accessibilityDescription: "MiniBrain") ?? NSImage()
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = "MiniBrain"
        return image
    }()
}
