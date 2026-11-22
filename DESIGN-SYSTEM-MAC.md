# MiniBrain Design System — macOS

How a MiniBrain-style Mac app looks and behaves. Everything here is taken from
the shipping MiniBrain code. Reuse it to build a new app that feels the same.

- Reference code: `Sources/MiniBrainUI/Library/LibraryTheme.swift`, `Icons.swift`,
  `LibraryView.swift`, `DropBox/DropBoxView.swift`, `LibraryKeys.swift`.
- Targets: macOS 26, SwiftUI with small AppKit pieces, Swift 6.

---

## 1. Principles

1. **Solid surfaces, no glass.** Don't use `.regularMaterial`, vibrancy or translucent
   sidebars. Every surface is a flat color token.
2. **Content first, chrome quiet.** Gray text for labels and metadata. Color only
   for tags, the accent and status.
3. **Same layout everywhere.**
   - A gray icon-and-label column on the left, values on the right.
   - Inline editing: click a value to edit it.
   - Empty values read **"Empty"** in the tertiary color.
4. **Keyboard-complete.** Every action has a key. Keys never fire while you type
   in a text field.
5. **Predictable placement.** Floating panels open at a fixed, user-chosen spot,
   not wherever the pointer is.
6. **Light + dark from the same tokens.** Never hard-code a color in a view.

---

## 2. Color

Source: Firefox Developer Edition tokens (`colors-firefox-dev.json`). Grays are
hex. Hues are OKLCH, converted to sRGB at runtime (see §2.6).

### 2.1 Gray ramp

| Token | Hex |
|---|---|
| gray-0 | `#FBFBFE` |
| gray-20 | `#F0F0F4` |
| gray-30 | `#BAC2CA` |
| gray-50 | `#BFBFC9` |
| gray-60 | `#8F8F9D` |
| gray-70 | `#5B5B66` |
| gray-80 | `#23222B` |
| gray-90 | `#1C1B22` |
| gray-100 | `#15141A` |

### 2.2 Slate scale (neutrals)

Neutrals use the **Slate** scale (OKLCH, a cool blue-grey that matches the logo). The
violet-tinted Firefox grays in §2.1 are no longer used for surfaces.

| Step | OKLCH | Hex |
|---|---|---|
| 50 | `oklch(98.4% 0.003 247.858)` | `#F8FAFC` |
| 100 | `oklch(96.8% 0.007 247.896)` | `#F1F5F9` |
| 200 | `oklch(92.9% 0.013 255.508)` | `#E2E8F0` |
| 300 | `oklch(86.9% 0.022 252.894)` | `#CAD5E2` |
| 400 | `oklch(70.4% 0.04 256.788)` | `#90A1B9` |
| 500 | `oklch(55.4% 0.046 257.417)` | `#62748E` |
| 600 | `oklch(44.6% 0.043 257.281)` | `#45556C` |
| 700 | `oklch(37.2% 0.044 257.287)` | `#314158` |
| 800 | `oklch(27.9% 0.041 260.031)` | `#1D293D` |
| 900 | `oklch(20.8% 0.042 265.755)` | `#0F172B` |
| 950 | `oklch(12.9% 0.042 264.695)` | `#020618` |

### 2.3 Semantic tokens

| Token | Light | Dark | Used for |
|---|---|---|---|
| `sidebar` | slate-100 | slate-900 | Sidebar background |
| `content` | slate-50 | **slate-950** | Main content / gallery background |
| `panel` | slate-50 | slate-900 | Detail panel, popovers, floating panel |
| `card` | white | slate-900 | Cards, dropdown menus |
| `cardBorder` | black 10% | white 10% | 1px card outline |
| `thumbBackground` | slate-100 | slate-950 | Letterbox behind images |
| `hover` | black 5% | white 6% | Row/value hover fill |
| `selectedRow` | black 10% | white 10% | Selected sidebar row, list highlight |
| `divider` | black 10% | white 10% | 1px separators, field borders |
| `field` | black 5% | white 10% | Text-field / search fill |
| `primary` | slate-900 | slate-50 | Main text |
| `secondary` | slate-600 | slate-400 | Labels, property names, secondary icons |
| `tertiary` | slate-500 | slate-500 | Placeholders, "Empty", hints |
| `accent` | json accent / chosen hue (§2.3a) | | Selection, focus, tint |
| `onAccent` | white | slate-950 | Text on accent fill |
| `attention` | `#2AC3A2` | `#54FFBD` | Success ("Saved") |
| tag gray (palette #0) | slate-200 / slate-800 text | slate-800 / slate-50 text | Neutral chips, badges |

Rules:
- Selection is shown with an **accent border** (2px on cards, 1.5px on fields), never an accent fill on large surfaces.
- Destructive actions use the system destructive role (red), not a custom color.
- Errors and warnings use system orange text.

### 2.3a Theme & accent (user settings)

- **Theme:** System (default) · Light · Dark, applied app-wide via `NSApp.appearance`. All tokens are dynamic, so they follow it.
- **Accent:** Default · the 9 json hues · macOS. Each hue uses the json's own
  `accent.primary` rule: **step 60 in light, step 30 in dark** (yellow uses step 70 in light for
  contrast with white text). Default = blue-60 / cyan-30. macOS = `NSColor.controlAccentColor`.
- **Changing it:** the change applies live. Window roots are wrapped in `ThemedRoot`, which re-creates content keyed by
  the accent and sets `.tint(Theme.accent)`.
- **What stays fixed:** tag colors don't follow the accent; they stay tied to tag names.

| Accent | Light (json step) | Dark (json step) |
|---|---|---|
| Default | blue.60 | cyan.30 |
| Red / Orange / Green / Cyan / Purple / Pink | `<hue>`.60 | `<hue>`.30 |
| Yellow | yellow.70 | yellow.30 |
| Blue / Violet | `<hue>`.60 | `<hue>`.30 |
| macOS | system accent | system accent |

### 2.4 Tag palette (10 entries)

Index 0 is neutral gray. Indexes 1–9 are hues from the json OKLCH ramps.
- **Light mode:** background = step 10 `oklch(90% .10 h)`, text = step 80 `oklch(41% .17 h)`.
- **Dark mode:** background = step 90 `oklch(34% .14 h)`, text = step 10.

| # | Hue | h | Light bg | Light text | Dark bg | Dark text |
|---|---|---|---|---|---|---|
| 0 | gray | — | slate-200 | slate-800 | slate-800 | slate-50 |
| 1 | red | 15 | `#FFC3C9` | `#90002B` | `#6E001F` | `#FFC3C9` |
| 2 | orange | 50 | `#FFCBA2` | `#8C1800` | `#6B1100` | `#FFCBA2` |
| 3 | yellow | 90 | `#F8DC90` | `#6E4000` | `#542F00` | `#F8DC90` |
| 4 | green | 145 | `#B5F0B5` | `#005F00` | `#004800` | `#B5F0B5` |
| 5 | cyan | 205 | `#87F2FE` | `#005F75` | `#00485A` | `#87F2FE` |
| 6 | blue | 260 | `#B7E0FF` | `#0041A4` | `#00317E` | `#B7E0FF` |
| 7 | violet | 290 | `#DCD3FF` | `#4E2E9D` | `#3B2279` | `#DCD3FF` |
| 8 | purple | 315 | `#F7CAFF` | `#6B1E87` | `#521568` | `#F7CAFF` |
| 9 | pink | 360 | `#FFC2DB` | `#8B0047` | `#6B0035` | `#FFC2DB` |

**Color assignment is stable and automatic.** Index = FNV-1a 64-bit hash of the
lowercased tag name, modulo 10. The same tag gets the same color everywhere, with no
picker. Custom-type pills (drop-zone chips) use the same function on the type name.

### 2.5 Swift tokens (drop-in)

```swift
enum Theme {
    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
    static func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
    static func white(_ a: CGFloat) -> NSColor { NSColor(white: 1, alpha: a) }   // white.alpha.*
    static func black(_ a: CGFloat) -> NSColor { NSColor(white: 0, alpha: a) }   // black.alpha.*
    /// `top` at `alpha` over opaque `base` — how the json alpha tokens layer.
    static func over(_ base: NSColor, _ top: NSColor, _ a: CGFloat) -> NSColor {
        let b = base.usingColorSpace(.sRGB)!, t = top.usingColorSpace(.sRGB)!
        return NSColor(srgbRed: b.redComponent * (1 - a) + t.redComponent * a,
                       green: b.greenComponent * (1 - a) + t.greenComponent * a,
                       blue: b.blueComponent * (1 - a) + t.blueComponent * a, alpha: 1)
    }

    static let white = hex(0xFFFFFF)
    // Slate scale
    static let slate50 = OKLCH.color(98.4, 0.003, 247.858), slate100 = OKLCH.color(96.8, 0.007, 247.896)
    static let slate200 = OKLCH.color(92.9, 0.013, 255.508), slate400 = OKLCH.color(70.4, 0.040, 256.788)
    static let slate500 = OKLCH.color(55.4, 0.046, 257.417), slate600 = OKLCH.color(44.6, 0.043, 257.281)
    static let slate800 = OKLCH.color(27.9, 0.041, 260.031), slate900 = OKLCH.color(20.8, 0.042, 265.755)
    static let slate950 = OKLCH.color(12.9, 0.042, 264.695)

    static let sidebar = dynamic(light: slate100, dark: slate900)
    static let content = dynamic(light: slate50, dark: slate950)
    static let panel = dynamic(light: slate50, dark: slate900)
    static let card = dynamic(light: white, dark: slate900)
    static let cardBorder = dynamic(light: black(0.10), dark: white(0.10))
    static let thumbBackground = dynamic(light: slate100, dark: slate950)
    static let hover = dynamic(light: black(0.05), dark: white(0.06))
    static let selectedRow = dynamic(light: black(0.10), dark: white(0.10))
    static let divider = dynamic(light: black(0.10), dark: white(0.10))
    static let field = dynamic(light: black(0.05), dark: white(0.10))
    static let primary = dynamic(light: slate900, dark: slate50)
    static let secondary = dynamic(light: slate600, dark: slate400)
    static let tertiary = dynamic(light: slate500, dark: slate500)
    static let accent = dynamic(light: OKLCH.color(55, 0.24, 260), dark: OKLCH.color(76, 0.14, 205))
    static let attention = dynamic(light: hex(0x2AC3A2), dark: hex(0x54FFBD))
    static let onAccent = dynamic(light: white, dark: slate950)

    static let tagHues: [Double] = [15, 50, 90, 145, 205, 260, 290, 315, 360]
    static let tagBackgrounds: [Color] = [dynamic(light: slate200, dark: slate800)]
        + tagHues.map { dynamic(light: OKLCH.color(90, 0.10, $0), dark: OKLCH.color(34, 0.14, $0)) }
    static let tagForegrounds: [Color] = [dynamic(light: slate800, dark: slate50)]
        + tagHues.map { dynamic(light: OKLCH.color(41, 0.17, $0), dark: OKLCH.color(90, 0.10, $0)) }
}

enum TagPalette {
    static func index(for name: String) -> Int {
        var h: UInt64 = 0xcbf29ce484222325
        for b in name.lowercased().utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return Int(h % UInt64(Theme.tagBackgrounds.count))
    }
}
```

Set `.tint(Theme.accent)` on every window root, so system controls (toggles,
pickers, default buttons) pick up the accent.

### 2.6 OKLCH → sRGB

Use Björn Ottosson's OKLab math (MiniBrain's `OKLCH` enum in `LibraryTheme.swift`), then
clamp to 0…1 and apply sRGB gamma. Reference values: `oklch(62.8% 0.2577 29.23)` ≈ pure
red. Always store colors as OKLCH numbers from the json, not pre-converted hex, so
they stay in sync with the source tokens.

---

## 3. Typography

System font (SF Pro) only. Sizes are explicit points (`.system(size:)`) so the
density matches across windows.

| Role | Size / weight | Where |
|---|---|---|
| Page title | 30 bold | Detail panel item title (inline-editable, up to 4 lines) |
| Large count | 26 bold | "N items selected" |
| Card title | 14.5 semibold | Gallery card title (1 line) |
| Body / property value | 14 regular | Property values, content text (line spacing 3) |
| Sidebar row | 13.5 regular (medium when selected) | Navigation rows |
| Top bar / breadcrumb | 13.5 regular | "Library / Products" |
| Control text | 13 regular | Search field, dropdown items, menus |
| Chip (regular) | 13 regular | Tags in the detail panel |
| Caption / hint | 12 regular | Card info line, field captions, footers |
| Section header | 11.5 medium, `secondary` | "Types", "Tags", "Colors" |
| Chip (small) | 11.5 regular | Tags on cards |
| Segment label | 11.5 semibold | Off/On segmented switch |
| Monospace | 13 `.monospaced` | Search keywords (`tag:`), storage paths |

Rules: titles are one line with tail truncation (`lineLimit(1)`). URLs use
**middle** truncation. Never let text wrap and change a card's height (see §5.3).

---

## 4. Spacing, sizes & shape

### 4.1 Spacing scale (pt)

`2 · 4 · 5 · 6 · 8 · 9 · 10 · 12 · 14 · 16 · 18 · 20 · 24 · 28 · 30 · 36`

| Use | Value |
|---|---|
| Chip gap, segment gap | 5 / 2 |
| Icon ↔ label in rows | 9 (sidebar), 8 (property rows), 7 (card title) |
| Sidebar inner padding (row content) | 8 horizontal |
| Sidebar column inset (search, rows, headers align) | 10 horizontal |
| Section header top gap | 12 (+2 below) |
| Card inner padding | 12 horizontal, 10 top, 12 bottom; 8 between lines |
| Gallery grid gap / outer padding | 16 gap; 28 horizontal, 18 vertical |
| Detail panel content inset | 30 horizontal, 8 top, 36 bottom |
| Floating panel content padding | 12–14 |
| Panel edge margin on screen | 24 |

### 4.2 Fixed dimensions

| Element | Size |
|---|---|
| Sidebar width | 248 |
| Traffic-light clearance (top of sidebar) | 38 |
| Search field | height 30, radius 7 |
| Sidebar row | height 28, radius 6 |
| Section header | height 24 |
| Top bar (gallery & panel toolbars) | height 46 |
| Gallery card | adaptive column 250–340 wide; thumbnail 170 tall; title row 20, tag row 20, info row 16 |
| Detail panel | default width 460, resizable 360…(window − sidebar − 420), persisted (`library.detailPanelWidth`) |
| Property row | label column 132, value min height 30 |
| Autocomplete dropdown | width 228, row 28, radius 8 |
| Drop box | 220 × 160 (no types) · 260 wide with type zones · chooser 280 · field form 320 |
| Drop zone pill | height 30, radius 7 |
| Segmented switch segment | 34 × 20, radius 4 (track radius 6) |
| Window minimum (library) | 980 × 600 |

### 4.3 Corner radii

| Radius | Use |
|---|---|
| 3–4 | Tag chips (4), color squares (3), segment |
| 5–6 | Dropdown rows (5), sidebar rows, previews in panel (6) |
| 7 | Text fields, search, drop zones |
| 8 | Cards, dropdown container |
| 10 | Inner drop target |
| 14 | Floating panel (drop box) |

Always use `.continuous` (squircle) corners.

### 4.4 Elevation

Flat by default. Only these get shadows:
- **Cards:** no shadow at rest; on hover black 18%, radius 6, y 1. (Resting per-card shadows and gradient masks render offscreen on every layout pass and make resizing stutter. Use overlays, not `.mask`, for fades.)
- **Dropdowns:** black 25%, radius 10, y 4.
- **Floating panel:** the system window shadow (`hasShadow = true`).

---

## 5. Components

### 5.1 Window shell (3 panes)
`Sidebar (248, sidebar) | 1px divider | Content (flex, content) | 1px divider | Detail panel (460, panel)`.
- **Title bar:** hidden (`titleVisibility = .hidden`, `titlebarAppearsTransparent`, full-size content). The sidebar starts 38pt down to clear the traffic lights.
- **Detail panel:** only shown when something is selected. It slides in from the trailing edge (`.snappy(0.2)`).

### 5.2 Sidebar
- **Top:** a search field. Magnifier icon 14, a `⌘F` key hint in a `field` capsule, and rotating example placeholders (§7.4).
- **Navigation rows:**
  - Layout: icon (15, `secondary`, 18pt column) + label.
  - States: hover = `hover` fill; selected = `selectedRow` fill and medium weight.
  - Clicking a selected filter row again clears it.
- **Collapsible sections:** a header with a trailing chevron that rotates −90° when collapsed.
  - Collapsed sections show their item count.
  - The state persists in `UserDefaults` (`@AppStorage("sidebar.<section>Collapsed")`).
- **Tag rows:** a 12×12 square (radius 3) in the tag's background color + the name.
  - Right-click → **Delete Tag…**, with a confirmation that names how many items are affected.
- **Color filters:** a grid of 16pt circles. Selected = 2px `primary` ring; otherwise 1px `divider` ring.

### 5.3 Gallery card
- **Layout, top to bottom:**
  - Thumbnail (170 tall, `thumbBackground`, image **scaled to fit, never cropped**).
  - Type icon + title (1 line).
  - Tag chips: one line, full width, scrolls sideways, with a 14pt fade mask at the trailing edge.
  - One info line: URL (bright host + dim path) › search snippet › content preview › blank.
- **Equal heights:** every slot has a fixed height, so all cards are identical. Grid rows are top-aligned.
- **States:** hover = border `selectedRow` + bigger shadow; selected = 2px `accent` border.
- **Badge:** a custom-type badge sits top-left on the thumbnail (11 medium, gray chip).

### 5.4 Tag chip
- **Shape:** padding 7×2.5 (regular) or 6×1.5 (small), radius 4.
- **Colors:** background/foreground from the tag palette (§2.4).
- **Text:** always the full name, never truncated inside a chip. Overflow scrolls instead.
- **Removable variant:** a trailing × (11pt; 9pt small) in the foreground color at 70% opacity.

### 5.5 Property row (detail panel)
`[icon 15 + label, secondary, 132 wide] [value, hover fill on the whole value area]`
- **Text:** shown as text; click to edit inline. Return or clicking away saves, Esc cancels. Blank shows "Empty".
- **Large text:** same, multi-line (1–12 lines).
- **Web link:** host bright + path dim. Click opens it in the browser; a pencil icon (13) edits it.
- **Tags:** a chip row; click opens the tag picker (§5.8).
- **Type / enum:** a chip-styled menu, no indicator.
- **"+ Add a property":** a tertiary-colored button at the end of the list.

### 5.6 Text field (forms)
- **Style:** plain field, 9×7 padding, `field` fill, radius 7, 1px `divider` border.
- **Focus:** the border becomes 1.5px `accent`, drawn **inside** the field so it never gets clipped. The system focus ring is turned off (`.focusEffectDisabled()`).
- **Text editors:** scroll indicators hidden.

```swift
extension View {
    func formFieldChrome(focused: Bool, vertical: CGFloat = 7) -> some View {
        self.focusEffectDisabled()
            .padding(.horizontal, 9).padding(.vertical, vertical)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(focused ? Theme.accent : Theme.divider, lineWidth: focused ? 1.5 : 1))
            .animation(.easeOut(duration: 0.12), value: focused)
    }
}
```

### 5.7 Floating panel (drop box)
- **Panel type:** non-activating `NSPanel`. Floating level, on all Spaces, over full-screen apps. Borderless, clear background.
- **Body:** a solid `panel` background, radius 14, 1px `divider` border.
- **Placement:** at a fixed, user-chosen anchor, one of nine. Default top-right, 24pt margin, on the screen with the pointer.
  - The panel sizes itself to its content (`NSHostingController.sizingOptions = .preferredContentSize`).
  - It re-anchors whenever it resizes.
- **Main drop target:** dashed border (5/4 dash, 1.5px), solid accent when hovered.
  - Icon + caption: "Drop or ⌘V to save" / "Release to save" / "Saving…" / "Saved".
  - Corner button: paste.
- **Drop zones:** one 30pt pill per category, in its tag-palette color. Accent fill and 1.06 scale while targeted.
- **Footer:** a segmented Off | On switch for per-drop behavior (§7.6).
- **States:** idle → hovering → saving → saved (`attention`) / error (orange).
  - After a result it returns to idle after 1.5s.
  - If it was opened by a drag, it auto-hides after 0.4s, or 1.2s after showing "Saved".

### 5.8 Tag picker (popover, 300 wide)
- **Top:** current chips with ×, plus a "Search for an option…" field, on a `field` background.
- **Below:** "Select an option or create one" (11.5, `secondary`), then a filtered list of existing tags as chips.
  - A **Create ‹chip›** row appears when the typed name is new.
  - Return picks the first match, or creates the tag.

### 5.9 Autocomplete dropdown
- **Container:** 228 wide, `card` background, radius 8, `divider` border, dropdown shadow.
- **Rows:** 28pt high. Highlighted row gets `selectedRow` fill and a trailing ⇥ hint.
- **Row content by kind:**
  - Tags show as chips.
  - Colors show a dot + name.
  - Types show an icon + name.
  - Keywords show in monospace.
- **Limit:** 8 suggestions.

### 5.10 Multi-selection panel
- **Header:** "N items selected" (26 bold).
- **Previews:** a 4-column grid of up to 12 thumbnails (64 tall, radius 5).
- **Bulk actions** (as property rows): Add tag, Set type.
- **Bottom row:** destructive "Move N Items to Trash" + "Deselect All".
- **Footer:** a key-hint line in tertiary.

### 5.11 Settings window
- **Window:** fixed width 600, a tab bar of icon + label tabs: General / Shortcuts / Types / Storage.
- **Forms:** grouped (`.formStyle(.grouped)`), with captions in footers.
- **Position picker:** a 3×3 grid drawn like a screen (150×96, radius 8). Selected cell = accent, 30×20; others 22×14 at 25% gray.
- **Shortcut recorder:**
  - A button showing the shortcut (e.g. `⇧⌘Space`); "Press shortcut…" in accent while recording.
  - Clear button next to it.
  - Invalid keys: beep + shake.

### 5.12 Empty states
Use `ContentUnavailableView` with a Lucide/brand icon, a one-line title, and a
description that teaches the next action (e.g. "Press ⌘⇧Space, or just start dragging…").

---

## 6. Icons

### 6.1 Icon set: Lucide
- **Source:** [Lucide](https://lucide.dev) v0.460.0, ISC license (ship the license file).
- **Files:** bundled SVGs (24×24 viewBox, 2px stroke, `stroke="currentColor"`), loaded as template `NSImage`s, so `foregroundStyle` tints them.
- **Bundle lookup:** check `Bundle.main.resourceURL/<Target>_<Module>.bundle` **before** `Bundle.module`. SwiftPM's accessor `fatalError`s inside a packaged `.app`.

```swift
struct Icon: View {          // Icon(.search, size: 14)
    let icon: LucideIcon; var size: CGFloat = 15
    var body: some View {
        Image(nsImage: icon.image!).renderingMode(.template).resizable()
            .interpolation(.high).aspectRatio(contentMode: .fit).frame(width: size, height: size)
    }
}
```

| Size | Use |
|---|---|
| 9 / 11 | Chip remove × (small / regular) |
| 12 | Section chevrons |
| 13 | Inline actions (pencil, field reorder, trash in forms) |
| 14 | Search magnifier, paste, plus, dropdown type icons |
| 15 | Sidebar rows, property labels, card title icon, links |
| 16 | Panel toolbar, breadcrumb |
| 18 | Settings tabs |
| 28–30 | Drop target glyph, card placeholder |

### 6.2 Icon vocabulary

| Concept | Lucide | Concept | Lucide |
|---|---|---|---|
| All items | `layout-grid` | Search | `search` |
| Text / note | `sticky-note` | Clear field | `circle-x` |
| Link | `link` | Collapse | `chevron-down` |
| Image | `image` | Close panel | `chevrons-right` |
| PDF / document | `file-text` | Open externally | `external-link` |
| Custom type / collection | `layers` | Reveal in Finder | `folder` |
| Tag | `tag` | Copy | `copy` |
| Tags (property) | `list` | Trash | `trash-2` |
| Created time | `clock` | Add | `plus` / `minus` |
| Note / long text | `align-left` | Edit | `pencil` |
| Short text field | `type` | Remove | `x` |
| Color filter | `palette` | Website / source | `globe` |
| Drop target (idle) | `inbox` | Drop target (hover) | `arrow-down-to-line` |
| Working | `hourglass` | Success | `circle-check` |
| Error | `triangle-alert` | Paste | `clipboard-paste` |
| Settings / General | `settings` | Shortcuts | `keyboard` |
| Storage | `hard-drive` | Brand (breadcrumb) | `brain` |

Native menus (context menus, `Menu` items) keep **SF Symbols**. They're the only
place SF Symbols are used.

### 6.3 Brand icons
- **Menu bar:** a single-color glyph SVG (MiniBrain: `brain-4-line.svg`, fill `currentColor`) at **18×18**, `isTemplate = true`, so it follows light/dark menu bars.
  - Verify it loads. Fall back to an SF Symbol only as a last resort, and have a test assert the custom glyph loaded.
- **App icon:** `.icns` with all sizes (16–1024 @1x/@2x). Info.plist `CFBundleIconFile = AppIcon`. Also set `NSApp.applicationIconImage` when running unbundled.

---

## 7. Input system

The rules MiniBrain enforces. Implement them all in a new app.

### 7.1 Text-field safety (most important)
- App-wide shortcuts (⌘A, Esc, ⌘⌫, ←/→, Return) **never fire while a text field is being edited**.
  - Check `window.firstResponder is NSTextView && isEditable` before handling a key.
  - Use a window-scoped `NSEvent` local key monitor, not hidden `.keyboardShortcut` buttons. Hidden buttons steal keys from fields.
- **Clicking outside a text input ends editing.**
  - A left-mouse-down monitor calls `window.makeFirstResponder(nil)` unless the click lands on a text input or a region marked `.keepsTextFocus()`.
  - Example: the autocomplete list is marked, so clicking a suggestion doesn't end editing first.
- **Esc leaves a focused search field**, or first dismisses its dropdown if one is open.

### 7.2 Global & window shortcuts

| Keys | Action | Scope |
|---|---|---|
| ⌘⇧Space | Toggle floating capture panel | Global (configurable) |
| ⌘⇧B | Toggle main window | Global (configurable) |
| ⌘, | Settings | Every window, panel, menu-bar menu |
| ⌘F | Focus search | Main window |
| ⌘V | Paste into floating panel | Panel (handled in `performKeyEquivalent`; menu-bar apps have no Edit menu) |
| Esc | Clear selection / close panel / cancel inline edit | Context |

- **Global hotkeys:** Carbon `RegisterEventHotKey` (or KeyboardShortcuts in Xcode builds). Re-register live when changed.
- **Shortcut rules:**
  - A shortcut must include ⌘, ⌥ or ⌃, or be an F-key.
  - Reject one already used by the other hotkey.
  - If the system refuses a shortcut, restore the previous one and show the error inline.
- **Recording:** pause hotkeys while recording a new shortcut.
- **Menu bar:** the menu reads the current shortcuts; nothing is hard-coded.

### 7.3 Selection (grid)

| Input | Result |
|---|---|
| Click | Select only this item |
| ⌘-click | Add/remove item |
| ⇧-click | Range from the last-clicked item |
| ⌘A | Select all visible |
| Esc | Clear selection |
| ⌘⌫ | Move selection to Trash (recoverable for 30 days) |
| Double-click | Open |
| Plain ⌫ | **Nothing** — it must never delete items |

### 7.4 Search input
- **Placeholder:** rotates every 3.5s while the field is empty, with an opacity + 4pt slide transition.
  - Hints: "Search everything…", "Try type:image", "Try tag:‹your first tag›", "Try color:red", "Try "exact phrase"", "Try after:2025-01-01", "Try meta.price<100".
- **Syntax:** `words "phrases" type: tag: color: after: before: meta.key<op>value`. Unknown `key:value` pairs are searched as text.
- **Autocomplete:** completes the word being typed.
  - `ta` → `tag:`
  - `tag:cl` → matching tags (prefix matches first, then contains)
  - `type:` → built-in + custom types
  - `color:` → colors
- **Autocomplete keys:** ↑/↓ move, Tab/Return accept, Esc dismisses, click accepts. Accepting replaces only the current word, auto-quotes names with spaces, and appends a space.
- **Debounce:** 250ms while typing. Filter clicks search immediately.

### 7.5 Inline editing
- **Commit and cancel:** click a value to edit. Return or blur commits; Esc cancels.
- **Tag picker:** Return picks the first match or creates a tag. × on a chip removes it from this item only.
- **Deleting a tag** everywhere is done only from the sidebar context menu, with confirmation.

### 7.6 Capture input (floating panel)
- **Drag auto-show:** dragging anything in any app opens the panel. Detected by polling `NSPasteboard(name: .drag).changeCount` while the mouse button is down, at about 7 Hz. No Accessibility permission is needed.
- **Drop target:** the main zone saves. A category zone saves into that category, then opens a short field form (Return = Save, Esc = Skip).
- **Shift as modifier:** ⇧ while dropping opens a category chooser. Read ⇧ from `CGEventSource.flagsState(.combinedSessionState)`, sampled during hover too, because another app owns the drag.
- **Keyboard while the panel is key:** ← = Off, → = On, Return = toggle for the footer switch. No effect while typing.
- **Paste:** ⌘V or the paste button. ⇧⌘V pastes into a category.

### 7.7 Click & hover feedback
- **Hover:** `hover` fill on rows and values; cards get a stronger border + shadow.
- **Press:** 0.7 opacity on sidebar rows.
- **Motion:** `.snappy(duration: 0.15–0.2)` for state changes, `.easeOut(0.12)` for focus borders, `.easeInOut(0.35)` for placeholder rotation.

---

## 8. Platform conventions

- **Menu-bar app with an optional Dock icon.** Setting "Show in Dock": Always (default) / While a window is open / Never. Clicking the Dock icon opens the main window.
- **Settings:** a separate window (not a sheet), opened by ⌘, from anywhere.
- **Persist UI state in UserDefaults:** collapsed sections, panel position, window frame (`setFrameAutosaveName`), toggles.
- **Accessibility:**
  - Every icon-only button has `.help()` text.
  - Custom controls set an accessibility label and value.
  - The segmented switch supports `accessibilityAdjustableAction`.
- **Tests that touch UserDefaults** must use a suite path in the temp directory, never `~/Library/Preferences`.

---

## 9. Checklist for a new screen

- [ ] Uses only `Theme` tokens; checked in light and dark.
- [ ] Solid backgrounds, no materials.
- [ ] Lucide icons at the sizes in §6.1; SF Symbols only in native menus.
- [ ] Spacing from the scale in §4.1; radii from §4.3, continuous.
- [ ] Every action reachable by keyboard; keys inactive while typing (§7.1).
- [ ] Click-outside ends editing; Esc behaves per §7.1.
- [ ] Fixed-height list/grid items (no text wrapping changing heights).
- [ ] Empty values read "Empty"; empty screens use `ContentUnavailableView` with a next step.
- [ ] Icon-only buttons have `.help()`; custom controls have accessibility labels.
