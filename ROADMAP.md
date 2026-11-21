# MiniBrain — Roadmap

## Rules for Claude Code (apply to every task)
1. Do ONE task at a time, in order. Don't start the next until I say "next".
2. Each task: write tests first (or alongside), implement, then run `make test`.
3. A task is done only when ALL tests pass (new + existing). Paste the test summary.
4. Never delete or weaken an existing test to make it pass. Ask me instead.
5. Tests use Swift Testing, an in-memory GRDB DB, and a temp directory. No real
   user data, no network, no shared state between tests.
6. Inject time (`Clock`), file paths, and system services (NSWorkspace, models)
   via protocols so they can be faked.
7. Tests needing Apple Intelligence or a downloaded model are tagged
   `.integration` and skipped when unavailable. Every one has a fake-based
   unit test too.
8. Fixtures live in `Tests/Fixtures/` (sample PDF, PNGs, HTML snippets).
9. After each task, update `CHANGELOG.md` with one line.

---

## Phase 0 — Foundation
**T0.1 Project setup**
Xcode project (macOS 26, Swift 6), SPM deps (GRDB, KeyboardShortcuts), app + test
targets, `Makefile` with `make test` (`xcodebuild test`).
- Tests: smoke test runs; `make test` exits 0.

**T0.2 AppPaths**
Resolves `Application Support/MiniBrain/`, `brain.db`, and `blobs/`; base dir injectable.
- Tests: creates dirs, idempotent, respects injected base dir.

## Phase 1 — Storage
**T1.1 Migrations (schema v1)**
`items`, `tags`, `item_tags`, `items_fts`, `enrichment_queue`; WAL; foreign keys on.
- Tests: fresh migrate succeeds; all tables/indexes exist; re-run is a no-op; FK cascade works.

**T1.2 Item model + repository CRUD**
- Tests: insert/fetch/update/delete each type; `updated_at` changes on edit; `meta` JSON round-trips.

**T1.3 Tags**
- Tests: case-insensitive unique; attach/detach; tag deleted when no items use it.

**T1.4 FTS sync**
- Tests: new item searchable; edited title/note reflected; deleted item gone; tag rename reflected.

**T1.5 Trash + purge**
- Tests: trashed items hidden from queries; restore works; purge removes items older than 30 days (fake clock); blob removed if unreferenced.

## Phase 2 — Capture
**T2.1 BlobStore**
SHA-256 (CryptoKit) content-addressed storage.
- Tests: correct hash; same bytes stored once; read back equals input; delete unreferenced only.

**T2.2 Type detector**
Input: abstract `CapturePayload` (URL / plainText / html / imageData / pdfData).
- Tests: each type detected; URL wins over text; HTML extracts source URL; plain text that is only a URL becomes a link; unknown payload rejected with error.

**T2.3 CaptureService**
Payload → blob + item + FTS in one transaction.
- Tests: each type end-to-end into temp DB; failure rolls back (no orphan blob/item); paste path same as drop path.

## Phase 3 — Search
**T3.1 Query parser → AST**
Syntax: words, `"phrases"`, `type:`, `tag:`, `after:`, `before:`, `color:`, `meta.key<op>value`.
- Tests: each filter; mixed query; quoted phrases; invalid date → error; unknown filter treated as text; empty query.

**T3.2 SQL builder**
AST → parameterized SQL.
- Tests: expected SQL + args per AST; FTS special chars escaped; injection strings stay inert; filters combine with AND.

**T3.3 SearchService**
bm25 ranking, prefix match, highlighted snippets.
- Tests: seeded fixture DB returns expected order; filters + text combined; snippets highlight match; perf test: 10k items < 50 ms.

## Phase 4 — UI (v0 complete)
**T4.1 Menu-bar app + hotkeys**
`MenuBarExtra`, no Dock icon, `Cmd+Shift+Space` (drop box), `Cmd+Shift+B` (library).
- Tests: hotkey handler toggles state in AppState (fake shortcut trigger).

**T4.2 Drop box**
Floating non-activating `NSPanel`, all spaces + fullscreen, `.onDrop` → CaptureService.
- Tests: DropBoxViewModel states idle → hovering → saving → saved/error; NSItemProvider → CapturePayload mapping per UTType.
- Manual checklist: drag text from Safari & Chrome, URL, PNG, PDF; works over a fullscreen app.

**T4.3 Library window**
Search bar, filter sidebar, grid, detail editor.
- Tests: search debounce (fake clock); filter state → query string; editing note/tags persists; empty state shown.

**T4.4 Item actions**
Open, reveal in Finder, copy, trash.
- Tests: fake `Workspace` protocol receives correct calls; copy writes correct pasteboard content.

✅ **Milestone v0:** all acceptance criteria pass with Wi-Fi off; restart keeps data.

## Phase 5 — Local enrichment (v1)
**T5.1 Enrichment queue**
Actor-based worker, retries with backoff, max attempts.
- Tests: enqueue → processed; failure retried then marked failed; pending jobs resume after restart; capture never blocks on enrichment.

**T5.2 PDF text (PDFKit)**
- Tests: fixture PDF text extracted and searchable; page count in meta; empty/encrypted PDF handled.

**T5.3 OCR (Vision framework)**
- Tests: fixture image with known text → contains expected words; blank image → empty, no error.

**T5.4 Dominant colors (Core Image)**
Top 3 colors + named color buckets in `meta`.
- Tests: solid red → "red"; two-color image → both; `color:red` search finds it.

## Phase 6 — AI tagging (v2)
**T6.1 Tagger protocol + Foundation Models**
`@Generable` struct: tags, category, colors, price?, summary.
- Tests: pipeline with FakeTagger; output validation (trim, lowercase, max 8 tags); fallback when Apple Intelligence unavailable; `.integration` real-model test.

**T6.2 Image tagger (MLX Swift + Qwen2.5-VL 3B)**
ModelManager: load on demand, unload after 5 min idle.
- Tests: load/unload timing with fake clock and FakeModel; concurrent requests share one load; `.integration` real-model test on fixture image.

**T6.3 Tag merge**
AI tags marked `source=ai`; user tags always win; user can remove AI tags.
- Tests: merge rules; removed AI tag not re-added on re-enrich.

## Phase 7 — Semantic search (v3)
**T7.1 sqlite-vec in GRDB**
Custom SQLite build with sqlite-vec compiled in; `vec_items` table (migration v2).
- Tests: `vec_version()` returns; insert/query nearest; migration v1 → v2 on fixture DB keeps data.

**T7.2 Embedder**
Protocol + `NLContextualEmbedding` impl; embeddings queued via T5.1.
- Tests: correct dimension; deterministic; "sofa" closer to "couch" than to "invoice".

**T7.3 Hybrid search (RRF, k=60)**
- Tests: RRF math on known lists; synonym query finds item FTS misses; filters still applied.

**T7.4 Related items**
- Tests: top-N neighbors exclude self and trashed items.

## Phase 8 — Natural-language query (v4)
**T8.1 NL → SearchQuery**
Foundation Models `@Generable` → same AST as T3.1.
- Tests: FakeTranslator outputs map to correct SQL; invalid output falls back to plain FTS; `.integration` sample sentences.

**T8.2 Release**
Release build, `.dmg`, README.
- Tests: full suite green in Release config; app opens existing v1 DB fixture without data loss.
