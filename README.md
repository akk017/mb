# MiniBrain

A local-first "second brain" for macOS 26. Drop or paste links, text, images and
PDFs into a floating box, then find them again with full-text, filter, semantic and
natural-language search. Everything stays on your Mac: no account, no cloud. (Only optional link previews fetch the saved page.)

- **⌘⇧Space** — toggle the drop box (floats over every Space and full-screen apps)
- **⌘⇧B** — open the library
- Menu bar icon only; no Dock icon
- ⌘V (or the paste button) in the drop box saves the clipboard
- Library: ⌘-click / ⇧-click / ⌘A to select several items for bulk tag, type or trash
- Dragging anything from any app pops the drop box up; it hides again after you drop or let go
- **Custom types** (Settings › Types): e.g. “Products” with your own fields — Text, Large Text,
  Web Link (clickable). Drop onto a type’s zone under “Save to type” in the drop box (or hold ⇧
  while dropping) and fill its fields right there. Filter by type in the library sidebar or search `type:products`; field values are searchable.
- **Settings… (⌘,)** from the menu bar: drop-box position (9 spots: top-left … bottom-right),
  pop-up-on-drag toggle, change both shortcuts, and see/change where the library is stored

## Features

| Area | What it does |
|---|---|
| Capture | Links, plain text, HTML snippets (keeps the source URL), images, PDFs. Drag & drop or paste; both use the same pipeline. Binary files are stored once, content-addressed (SHA-256). |
| Storage | SQLite (GRDB, WAL) in `~/Library/Application Support/MiniBrain/` — `brain.db` plus `blobs/`. Trash keeps items for 30 days. |
| Search | FTS5 with bm25 ranking, prefix matching and highlighted snippets. |
| Link previews | Page preview image and title via LinkPresentation (the only feature that uses the internet; can be turned off). |
| Local enrichment | Background queue: PDF text (PDFKit), OCR (Vision), dominant colors (Core Image). |
| AI tagging | Apple Intelligence (Foundation Models) suggests tags, category, price and a summary. Falls back to keyword extraction when Apple Intelligence is off. Images get tags from Vision's classifier, or Qwen2.5-VL 3B via MLX when built in. Tags you add always win; AI tags you remove never come back. |
| Semantic search | `NLContextualEmbedding` vectors in sqlite-vec, fused with full-text results using Reciprocal Rank Fusion (k = 60). |
| Natural language | Sentence-like queries ("red chairs I saved under 500") are turned into the same structured query via Foundation Models, with a plain full-text fallback. |

### Search syntax

```
walnut "mid century" type:image tag:wishlist tag:"living room"
after:2024-01-01 before:2024-07-01 color:red meta.price<500 meta.brand=ikea
```

`type:` accepts text, link, image, pdf (plurals and a few aliases work).
`after:` is inclusive, `before:` exclusive. Unknown `key:value` pairs are searched as text.

## Building

Requirements: macOS 26 on Apple Silicon, Swift 6.2.

```sh
make test          # full test suite (Debug)
make test-release  # full test suite (Release)
make app           # dist/MiniBrain.app (ad-hoc signed)
make dmg           # dist/MiniBrain.dmg
make fixtures      # regenerate Tests/Fixtures
```

With Xcode installed, `make test` runs `xcodebuild test` on the package and you can
open `Package.swift` in Xcode. With only the Command Line Tools, it runs `swift test`
plus a sudo-free workaround for stale files some CLT installs ship
(`scripts/clt-workaround.sh`, output in `.build-tools/`). In that mode:

- KeyboardShortcuts is left out (its `#Preview` macros need Xcode); hotkeys use Carbon
  `RegisterEventHotKey` with MiniBrain's own shortcut recorder in Settings.
- The Foundation Models `Generable` types are hand-written conformances (the
  `@Generable` macro plugin ships only with Xcode); the schema is identical.

Optional MLX image tagging (needs Xcode for the Metal toolchain):

```sh
MB_WITH_MLX=1 xcodebuild -scheme MiniBrain build
```

Library location: `MINIBRAIN_DATA_DIR` env var > Settings › Storage > `~/Library/Application Support/MiniBrain`.
Changing it in Settings copies the library (or adopts an existing one at the new folder) and restarts;
the old copy is never deleted. `MINIBRAIN_OPEN_SETTINGS=1` opens Settings at launch (dev aid).

## Project layout

```
Sources/
  CSQLiteVec/      sqlite-vec v0.1.6 amalgamation, compiled in (SQLITE_CORE)
  MiniBrainCore/   storage, capture, search, enrichment, AI, semantic, NL (no UI)
  MiniBrainUI/     AppState, hotkeys, drop box, library, item actions (SwiftUI/AppKit)
  MiniBrainApp/    @main MenuBarExtra app
  mbtool/          dev tool: fixture generation
Tests/
  MiniBrainTests/  Swift Testing suites, one folder per roadmap phase
  Fixtures/        sample PDFs, PNGs, HTML snippets, schema-v1 database
```

Tests use an in-memory database, temp directories, a fake clock and fakes for
workspace, pasteboard, hotkeys and models. Tests that need Apple Intelligence or a
downloaded model are tagged `.integration` and skip themselves when it's unavailable.

## Manual QA checklist (drop box)

- [ ] Drag selected text from Safari → saved as text with the page URL
- [ ] Drag selected text from Chrome → saved as text with the page URL
- [ ] Drag a link from the address bar → saved as link
- [ ] Drag a PNG from Finder and from a web page → saved as image
- [ ] Drag a PDF from Finder → saved as PDF; text searchable after enrichment
- [ ] ⌘V in the drop box saves the clipboard
- [ ] Drop box appears and accepts drops over a full-screen app
- [ ] Works with Wi-Fi off; quitting and relaunching keeps everything

## Credits

- Icons: [Lucide](https://lucide.dev) (ISC license, `Sources/MiniBrainUI/Resources/Icons/LICENSE-lucide.txt`)
- Colors: Firefox Developer Edition design tokens (`colors-firefox-dev.json`)
- Vector search: [sqlite-vec](https://github.com/asg017/sqlite-vec) v0.1.6
