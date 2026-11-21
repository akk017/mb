import AppKit
import MiniBrainCore
import SwiftUI

/// Library palette from `colors-firefox-dev.json` (Firefox Developer
/// Edition tokens), tuned to the blue-grey logo: surfaces are `gray-30`
/// (#BAC2CA, hue 210 — the logo's hue) and `blue-110` layered with the json's
/// `white/black alpha` tokens. Accent = json `accent.primary`. Tag colors use
/// the json OKLCH hue ramps. Solid colors only — no materials.
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

    // json tokens
    static let gray0 = hex(0xFBFBFE)                          // color.gray.0
    static let gray30 = hex(0xBAC2CA)                         // color.gray.30 — blue-grey, matches logo
    static let white = hex(0xFFFFFF)                          // color.white.@base
    static let blue110 = OKLCH.color(20, 0.05, 260)           // color.blue.110
    static func white(_ a: CGFloat) -> NSColor { NSColor(white: 1, alpha: a) }   // color.white.alpha.*
    static func black(_ a: CGFloat) -> NSColor { NSColor(white: 0, alpha: a) }   // color.black.alpha.*

    /// `top` at `alpha` composited over opaque `base` (how alpha tokens layer).
    static func over(_ base: NSColor, _ top: NSColor, _ alpha: CGFloat) -> NSColor {
        let b = base.usingColorSpace(.sRGB)!, t = top.usingColorSpace(.sRGB)!
        return NSColor(srgbRed: b.redComponent * (1 - alpha) + t.redComponent * alpha,
                       green: b.greenComponent * (1 - alpha) + t.greenComponent * alpha,
                       blue: b.blueComponent * (1 - alpha) + t.blueComponent * alpha, alpha: 1)
    }

    // Blue-grey ramp built from the tokens above.
    static let slate50 = over(gray30, white, 0.90)   // #F8F9FA  white.90 over gray-30
    static let slate100 = over(gray30, white, 0.80)  // #F1F3F4  white.80 over gray-30
    static let slate150 = over(gray30, white, 0.70)  // #EAEDEF  white.70 over gray-30
    static let slate250 = over(gray30, white, 0.50)  // #DCE0E4  white.50 over gray-30
    static let slate600 = over(gray30, black(1), 0.30) // #82888D black.30 over gray-30
    static let slate700 = over(gray30, black(1), 0.50) // #5D6165 black.50 over gray-30
    static let ink800 = over(blue110, white, 0.20)   // #394456  blue-110 + white.20
    static let ink850 = over(blue110, white, 0.10)   // #212D41  blue-110 + white.10
    static let ink900 = over(ink850, black(1), 0.30) // #171F2E  (blue-110 + white.10) + black.30

    static let sidebar = dynamic(light: slate150, dark: ink850)
    static let content = dynamic(light: slate50, dark: ink900)
    static let panel = dynamic(light: slate50, dark: ink850)
    static let card = dynamic(light: white, dark: ink850)
    static let cardBorder = dynamic(light: black(0.10), dark: white(0.10))
    static let thumbBackground = dynamic(light: slate100, dark: ink900)
    static let hover = dynamic(light: black(0.05), dark: white(0.06))
    static let selectedRow = dynamic(light: black(0.10), dark: white(0.10))
    static let divider = dynamic(light: black(0.10), dark: white(0.10))
    static let field = dynamic(light: black(0.05), dark: white(0.10))
    static let primary = dynamic(light: ink850, dark: gray0)
    static let secondary = dynamic(light: slate700, dark: gray30)
    static let tertiary = dynamic(light: slate600, dark: over(ink900, white, 0.40))

    /// Current accent (Settings › General › Accent). Default = json
    /// `accent.primary` (light blue.60, dark cyan.30).
    nonisolated(unsafe) static var accentChoice: AccentChoice = .jsonDefault {
        didSet { accentCache = accentChoice.color }
    }
    nonisolated(unsafe) private static var accentCache: Color = AccentChoice.jsonDefault.color
    static var accent: Color { accentCache }
    /// color.accent.attention — used for success ("Saved").
    static let attention = dynamic(light: hex(0x2AC3A2), dark: hex(0x54FFBD))
    /// Text on an accent fill.
    static let onAccent = dynamic(light: white, dark: ink900)

    /// Tag chips: (background, text) per hue. Light uses step 10 on 80,
    /// dark uses step 90 on 10 — all from the json's OKLCH ramps.
    static let tagHues: [Double] = [15, 50, 90, 145, 205, 260, 290, 315, 360] // red … pink
    static let tagBackgrounds: [Color] = [dynamic(light: slate250, dark: ink800)] + tagHues.map { h in
        dynamic(light: OKLCH.color(90, 0.1, h), dark: OKLCH.color(34, 0.14, h))
    }
    static let tagForegrounds: [Color] = [dynamic(light: ink850, dark: gray0)] + tagHues.map { h in
        dynamic(light: OKLCH.color(41, 0.17, h), dark: OKLCH.color(90, 0.1, h))
    }
    /// Neutral chip text (badges).
    static let tagText = dynamic(light: ink850, dark: gray0)
}

/// Accent options: the json default, every json hue ramp (light step 60 /
/// dark step 30 — the rule json `accent.primary` uses), or the macOS accent.
public enum AccentChoice: String, CaseIterable, Sendable {
    case jsonDefault = "default"
    case red, orange, yellow, green, cyan, blue, violet, purple, pink
    case system

    public var title: String {
        switch self {
        case .jsonDefault: "Default"
        case .system: "macOS"
        default: rawValue.capitalized
        }
    }

    /// (light step, dark step) OKLCH values copied from colors-firefox-dev.json.
    var oklch: (light: (Double, Double, Double), dark: (Double, Double, Double))? {
        switch self {
        case .jsonDefault: ((55, 0.24, 260), (76, 0.14, 205))   // blue.60 / cyan.30
        case .red: ((55, 0.21, 15), (76, 0.17, 15))             // red.60 / red.30
        case .orange: ((58, 0.21, 50), (79, 0.17, 50))          // orange.60 / .30
        case .yellow: ((51, 0.23, 90), (79, 0.20, 90))          // yellow.70 (contrast) / .30
        case .green: ((55, 0.21, 145), (76, 0.17, 145))         // green.60 / .30
        case .cyan: ((55, 0.21, 205), (76, 0.14, 205))          // cyan.60 / .30
        case .blue: ((55, 0.24, 260), (76, 0.20, 260))          // blue.60 / .30
        case .violet: ((55, 0.24, 290), (76, 0.20, 290))        // violet.60 / .30
        case .purple: ((55, 0.21, 315), (76, 0.17, 315))        // purple.60 / .30
        case .pink: ((55, 0.21, 360), (76, 0.17, 360))          // pink.60 / .30
        case .system: nil
        }
    }

    func nsColor(dark: Bool) -> NSColor {
        guard let v = oklch else { return .controlAccentColor }
        let t = dark ? v.dark : v.light
        return OKLCH.color(t.0, t.1, t.2)
    }

    var color: Color {
        guard oklch != nil else { return Color(nsColor: .controlAccentColor) }
        return Theme.dynamic(light: nsColor(dark: false), dark: nsColor(dark: true))
    }
}

/// System / Light / Dark.
public enum AppAppearance: String, CaseIterable, Sendable {
    case system, light, dark

    public var title: String { rawValue.capitalized }

    /// nil = follow macOS.
    public var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Re-creates its content when the accent changes (colors are read when views
/// are built) and applies the accent as the control tint.
struct ThemedRoot<Content: View>: View {
    let preferences: AppPreferences
    @ViewBuilder var content: Content

    var body: some View {
        let choice = preferences.accentColor
        content
            .id(choice)
            .tint(Theme.accent)
    }
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
    /// Background the row sits on (for the edge fade).
    var fadeColor: Color = Theme.card

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(names, id: \.self) { TagChip(name: $0, size: size).fixedSize() }
            }
            .padding(.vertical, 1)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        // Soft fade at the right edge hints that there is more to scroll.
        // An overlay in the surface color (not a mask, which renders offscreen).
        .overlay(alignment: .trailing) {
            LinearGradient(colors: [fadeColor.opacity(0), fadeColor], startPoint: .leading, endPoint: .trailing)
                .frame(width: 14)
                .allowsHitTesting(false)
        }
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
