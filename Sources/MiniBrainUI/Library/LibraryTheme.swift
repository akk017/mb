import AppKit
import MiniBrainCore
import SwiftUI

/// Library palette from `colors-firefox-dev.json` (Firefox Developer
/// Edition tokens): gray ramp for surfaces/text, cyan/blue accent, and the
/// OKLCH hue ramps for tag colors. Solid colors only — no materials.
enum Theme {
    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }

    // Gray ramp (json: color.gray.*)
    static let gray0 = hex(0xFBFBFE), gray20 = hex(0xF0F0F4), gray30 = hex(0xBAC2CA), gray50 = hex(0xBFBFC9)
    static let gray60 = hex(0x8F8F9D), gray70 = hex(0x5B5B66), gray80 = hex(0x23222B), gray90 = hex(0x1C1B22)
    static let gray100 = hex(0x15141A)
    static func white(_ a: CGFloat) -> NSColor { NSColor(white: 1, alpha: a) }   // color.white.alpha.*
    static func black(_ a: CGFloat) -> NSColor { NSColor(white: 0, alpha: a) }   // color.black.alpha.*

    static let sidebar = dynamic(light: gray20, dark: gray90)
    static let content = dynamic(light: gray0, dark: gray100)
    static let panel = dynamic(light: gray0, dark: gray90)
    static let card = dynamic(light: hex(0xFFFFFF), dark: gray80)
    static let cardBorder = dynamic(light: black(0.10), dark: white(0.10))
    static let thumbBackground = dynamic(light: gray20, dark: gray90)
    static let hover = dynamic(light: black(0.05), dark: white(0.06))
    static let selectedRow = dynamic(light: black(0.10), dark: white(0.10))
    static let divider = dynamic(light: black(0.10), dark: white(0.10))
    static let field = dynamic(light: black(0.05), dark: white(0.10))
    static let primary = dynamic(light: gray100, dark: gray0)
    static let secondary = dynamic(light: gray70, dark: gray50)
    static let tertiary = dynamic(light: gray60, dark: gray60)

    /// color.accent.primary — light: blue.60, dark: cyan.30
    static let accent = dynamic(light: OKLCH.color(55, 0.24, 260), dark: OKLCH.color(76, 0.14, 205))
    /// color.accent.attention — used for success ("Saved").
    static let attention = dynamic(light: hex(0x2AC3A2), dark: hex(0x54FFBD))
    /// Text on an accent fill.
    static let onAccent = dynamic(light: hex(0xFFFFFF), dark: gray100)

    /// Tag chips: (background, text) per hue. Light uses step 10 on 80,
    /// dark uses step 90 on 10 — all from the json's OKLCH ramps.
    static let tagHues: [Double] = [15, 50, 90, 145, 205, 260, 290, 315, 360] // red … pink
    static let tagBackgrounds: [Color] = [dynamic(light: gray20, dark: gray70)] + tagHues.map { h in
        dynamic(light: OKLCH.color(90, h == 90 ? 0.1 : 0.1, h), dark: OKLCH.color(34, 0.14, h))
    }
    static let tagForegrounds: [Color] = [dynamic(light: gray100, dark: gray0)] + tagHues.map { h in
        dynamic(light: OKLCH.color(41, 0.17, h), dark: OKLCH.color(90, 0.1, h))
    }
    /// Neutral chip text (badges).
    static let tagText = dynamic(light: gray100, dark: gray0)
}

/// OKLCH → sRGB (Björn Ottosson's OKLab), gamut-clamped.
enum OKLCH {
    /// - Parameters: lightness in percent (0…100), chroma, hue in degrees.
    static func rgb(_ lightness: Double, _ chroma: Double, _ hue: Double) -> (r: Double, g: Double, b: Double) {
        let L = lightness / 100, h = hue * .pi / 180
        let a = chroma * cos(h), b = chroma * sin(h)
        let l_ = L + 0.3963377774 * a + 0.2158037573 * b
        let m_ = L - 0.1055613458 * a - 0.0638541728 * b
        let s_ = L - 0.0894841775 * a - 1.2914855480 * b
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        let lr = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let lg = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let lb = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        func encode(_ x: Double) -> Double {
            let c = min(max(x, 0), 1)
            return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
        }
        return (encode(lr), encode(lg), encode(lb))
    }

    static func color(_ lightness: Double, _ chroma: Double, _ hue: Double, alpha: CGFloat = 1) -> NSColor {
        let c = rgb(lightness, chroma, hue)
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: alpha)
    }
}

enum TagPalette {
    /// Stable color index for a tag name (case-insensitive).
    static func index(for name: String) -> Int {
        var h: UInt64 = 0xcbf29ce484222325
        for b in name.lowercased().utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return Int(h % UInt64(Theme.tagBackgrounds.count))
    }

    static func background(for name: String) -> Color { Theme.tagBackgrounds[index(for: name)] }
    static func foreground(for name: String) -> Color { Theme.tagForegrounds[index(for: name)] }
}

/// Colored tag pill.
struct TagChip: View {
    let name: String
    var size: Size = .regular
    var onRemove: (() -> Void)?

    enum Size { case small, regular }

    var body: some View {
        HStack(spacing: 3) {
            Text(name)
                .lineLimit(1)
                .truncationMode(.tail)
            if let onRemove {
                Button(action: onRemove) {
                    Icon(.x, size: size == .small ? 9 : 11)
                }
                .buttonStyle(.plain)
                .foregroundStyle(TagPalette.foreground(for: name).opacity(0.7))
                .help("Remove \(name)")
            }
        }
        .font(size == .small ? .system(size: 11.5) : .system(size: 13))
        .foregroundStyle(TagPalette.foreground(for: name))
        .padding(.horizontal, size == .small ? 6 : 7)
        .padding(.vertical, size == .small ? 1.5 : 2.5)
        .background(TagPalette.background(for: name), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// Single line of full-width chips that scrolls sideways when it overflows.
struct ScrollingChipRow: View {
    let names: [String]
    var size: TagChip.Size = .regular

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(names, id: \.self) { TagChip(name: $0, size: size).fixedSize() }
            }
            .padding(.vertical, 1)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .mask(
            // Soft fade at the right edge hints that there is more to scroll.
            HStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 14)
            })
    }
}

/// One-line row: chips shrink equally (with "…") when they don't all fit.
struct ChipRowLayout: Layout {
    var spacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        let height = ideal.map(\.height).max() ?? 0
        let total = ideal.map(\.width).reduce(0, +) + spacing * CGFloat(max(subviews.count - 1, 0))
        return CGSize(width: min(total, proposal.width ?? total), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = Self.widths(ideal: subviews.map { $0.sizeThatFits(.unspecified).width },
                                 available: bounds.width, spacing: spacing)
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths) {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: width, height: nil))
            x += width + spacing
        }
    }

    /// Fair share: small chips keep their width, big ones split the rest.
    static func widths(ideal: [CGFloat], available: CGFloat, spacing: CGFloat) -> [CGFloat] {
        guard !ideal.isEmpty else { return [] }
        let room = max(available - spacing * CGFloat(ideal.count - 1), 0)
        if ideal.reduce(0, +) <= room { return ideal }
        var result = ideal
        var remaining = room
        var open = Array(ideal.indices).sorted { ideal[$0] < ideal[$1] }
        while !open.isEmpty {
            let share = remaining / CGFloat(open.count)
            let first = open[0]
            if ideal[first] <= share {
                result[first] = ideal[first]
                remaining -= ideal[first]
                open.removeFirst()
            } else {
                for i in open { result[i] = max(share, 18) }
                break
            }
        }
        return result
    }
}

/// Wrapping layout for chips in the tag editor.
struct FlowLayout: Layout {
    var spacing: CGFloat = 5
    var lineSpacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let isFirst = rows[rows.count - 1].indices.isEmpty
            rows[rows.count - 1].indices.append(i)
            rows[rows.count - 1].width += isFirst ? size.width : size.width + spacing
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

/// URL shown as bright host + dimmed path; clickable.
struct URLLabel: View {
    let urlString: String
    var font: Font = .system(size: 12.5)

    var body: some View {
        let parts = Self.split(urlString)
        Group {
            if let url = URL(string: urlString), url.scheme != nil {
                Link(destination: url) { label(parts) }
                    .buttonStyle(.plain)
                    .help(urlString)
            } else {
                label(parts)
            }
        }
    }

    func label(_ parts: (host: String, rest: String)) -> some View {
        var host = AttributedString(parts.host)
        host.foregroundColor = Theme.primary
        var rest = AttributedString(parts.rest)
        rest.foregroundColor = Theme.tertiary
        return Text(host + rest)
            .font(font)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    /// "https://www.a.com/b/c?q" → ("a.com", "/b/c?q")
    static func split(_ s: String) -> (host: String, rest: String) {
        guard let url = URL(string: s), var host = url.host else { return (s, "") }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var rest = url.path
        if let q = url.query { rest += "?" + q }
        if rest == "/" { rest = "/" }
        return (host, rest)
    }
}

/// Downsampled, cached thumbnails (decoding full images per redraw is slow).
@MainActor
enum ThumbnailCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 400
        return c
    }()

    static func image(for url: URL, type: ItemType, maxPixel: Int) -> NSImage? {
        let key = "\(url.path)#\(maxPixel)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let image: NSImage?
        switch type {
        case .image:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                  ] as CFDictionary)
            else { return nil }
            image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        case .pdf:
            image = PDFThumbnail.make(url: url, maxPixel: maxPixel)
        default:
            image = nil
        }
        if let image { cache.setObject(image, forKey: key) }
        return image
    }
}

import PDFKit

enum PDFThumbnail {
    static func make(url: URL, maxPixel: Int) -> NSImage? {
        guard let page = PDFDocument(url: url)?.page(at: 0) else { return nil }
        let side = CGFloat(maxPixel)
        return page.thumbnail(of: NSSize(width: side, height: side), for: .cropBox)
    }
}

extension ItemType {
    var displayName: String {
        switch self {
        case .text: "Text"
        case .link: "Links"
        case .image: "Images"
        case .pdf: "PDFs"
        }
    }

    var singularName: String {
        switch self {
        case .text: "Text"
        case .link: "Link"
        case .image: "Image"
        case .pdf: "PDF"
        }
    }

    var icon: LucideIcon {
        switch self {
        case .text: .stickyNote
        case .link: .link
        case .image: .image
        case .pdf: .fileText
        }
    }
}

extension FieldKind {
    /// SF Symbol for native menus.
    var symbol: String {
        switch self {
        case .text: "textformat"
        case .largeText: "text.alignleft"
        case .webLink: "link"
        }
    }

    var icon: LucideIcon {
        switch self {
        case .text: .type
        case .largeText: .alignLeft
        case .webLink: .link
        }
    }
}

extension Color {
    init(named name: String) {
        switch name {
        case "red": self = .red
        case "orange": self = .orange
        case "yellow": self = .yellow
        case "green": self = .green
        case "blue": self = .blue
        case "purple": self = .purple
        case "pink": self = .pink
        case "brown": self = .brown
        case "black": self = .black
        case "white": self = .white
        default: self = .gray
        }
    }
}
