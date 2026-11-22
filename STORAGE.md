# MiniBrain Storage

Everything MiniBrain stores, where it lives, and how it changes over time.
Code references: `Sources/MiniBrainCore/Storage/`, `Enrichment/`, `Semantic/VectorStore.swift`,
`Sources/MiniBrainUI/Settings/AppPreferences.swift`.

---

## 1. Locations

| What | Default path |
|---|---|
| Library folder | `~/Library/Application Support/MiniBrain/` |
| Database | `<library>/brain.db` (+ `brain.db-wal`, `brain.db-shm`) |
| Files (images, PDFs, previews) | `<library>/blobs/<first 2 hex of hash>/<sha256>.<ext>` |
| Preferences | `~/Library/Preferences/app.minibrain.MiniBrain.plist` (UserDefaults) |
| Logs | `~/Library/Application Support/MiniBrain/Logs/minibrain.log` (always here, even when the library is moved) |

**Choosing the library folder** (`AppPreferences.libraryBaseDirectory`), first match wins:
1. `MINIBRAIN_DATA_DIR` environment variable (dev/testing).
2. Settings › Storage location (`libraryPath` preference).
3. The default above.

Folders are created on launch if missing (`AppPaths.ensureDirectories`, idempotent).

**Logs** (`Log.shared`, configured at launch; Settings › Storage › Diagnostics › Show Logs in Finder):
- **Format:** one line per event: `<ISO-8601 UTC time> <LEVEL> [<category>] <message>`. Levels: DEBUG, INFO, WARN, ERROR. Also mirrored to the unified system log (subsystem `app.minibrain`).
- **Categories:** `app` (launch, library path, quit, startup errors), `capture` (item id, type, host, byte size, queued jobs), `enrichment` (each job: kind, item id, duration, error and attempts on failure), `link-preview` (host, whether a title/image came back and its size, fetch/image errors), `watchdog` (main thread unresponsive ≥ 2 s, and how long until it recovered), `loop` (a UI event such as a hover or window-width change firing > 30×/s — names the view).
- **Rotation:** at 2 MB `minibrain.log` → `minibrain.1.log` → `minibrain.2.log` → `minibrain.3.log` (oldest dropped).
- **Privacy:** never item contents, clipboard data, titles or full URLs — only ids, kinds, hosts, sizes, timings and errors. Tests never write here (the logger stays off until configured).

**Moving the library** (Settings › Storage › Change… / Use Default, `LibraryMover`):
- **If the target has no `brain.db`:** the database is copied with SQLite's online backup (a consistent snapshot, WAL included), then all blob shards are copied.
- **If the target already has a library:** it's adopted as is, nothing is overwritten.
- **Afterwards:** the setting is saved and the app relaunches. The old library is **never deleted**.
- **Errors:** choosing the current folder → `sameLocation`; a folder that can't be written → `notWritable`.

---

## 2. Database

SQLite through GRDB 7.
- **Connection type:** `DatabasePool` (WAL mode) for the app. `DatabaseQueue` for in-memory tests and single-file fixtures.
- **Foreign keys:** on.
- **Every connection:** registers **sqlite-vec v0.1.6**, compiled in statically, so `vec0` tables and the `vec_*` functions work.

### 2.1 Migrations

| Version | Adds |
|---|---|
| `v1` | `items`, `tags`, `item_tags`, `items_fts` (+ 6 sync triggers), `enrichment_queue` |
| `v2` | `vec_items` (sqlite-vec) + delete trigger |
| `v3` | `custom_types`, `items.custom_type_id`, rebuilt `items_fts` with a `fields` column |

Migrations run automatically on open; re-running is a no-op. Opening an older library upgrades it in place without data loss. This is tested against `Tests/Fixtures/v1.sqlite`.

### 2.2 `items`

| Column | Type | Notes |
|---|---|---|
| `id` | TEXT PK | UUID string |
| `type` | TEXT | `text` · `link` · `image` · `pdf` |
| `title` | TEXT | Default `''`. Auto-derived on capture (first line / host+path / file name); may be replaced by a fetched page title if still the automatic one |
| `note` | TEXT | User note, default `''` |
| `content` | TEXT | Extracted text: the text itself, PDF text, or OCR text. Default `''` |
| `url` | TEXT NULL | Link URL, HTML source URL, or image source URL |
| `blob_hash` | TEXT NULL | SHA-256 of the stored file (images, PDFs) |
| `meta` | TEXT | JSON object, default `'{}'` (keys in §3) |
| `created_at` | DATETIME | GRDB date text, UTC |
| `updated_at` | DATETIME | Bumped on every edit |
| `trashed_at` | DATETIME NULL | Set when moved to Trash |
| `custom_type_id` | TEXT NULL | (v3) FK → `custom_types.id`, `ON DELETE SET NULL` |

Indexes: `type`, `created_at`, `trashed_at`, `blob_hash`, `custom_type_id`.

The item record writes `custom_type_id` only when it's set, so items can still be
inserted into v1 databases (fixtures, tools). To clear a type,
`CustomTypeRepository.assign(_, to: nil)` issues an explicit `UPDATE … = NULL`.

### 2.3 `tags` / `item_tags`

| Table | Columns |
|---|---|
| `tags` | `id` INTEGER PK AUTOINCREMENT, `name` TEXT UNIQUE `COLLATE NOCASE` |
| `item_tags` | `item_id` → items (CASCADE), `tag_id` → tags (CASCADE), `source` TEXT (`user` \| `ai`, default `user`), PK (`item_id`, `tag_id`) |

- Tag names are trimmed. Uniqueness ignores case ("Work" = "work"); the first spelling is kept.
- **A tag row is deleted automatically** when no item uses it (trigger on `item_tags` delete).
- **AI tags are never allowed to downgrade a user tag.** Attaching a tag that already exists as `user` keeps `user`.
- **Renaming** to an existing name merges the two tags.
- **Delete everywhere** (sidebar) removes the tag from all items and records it as suppressed on each item (§3).

### 2.4 `items_fts` (full-text search)

FTS5 table, `tokenize = 'unicode61 remove_diacritics 2'`, `prefix = '2 3'`.
Its `rowid` equals `items.rowid`.

| Column | Source | bm25 weight |
|---|---|---|
| `item_id` | `items.id` (UNINDEXED) | 0 |
| `title` | `items.title` | 10 |
| `note` | `items.note` | 5 |
| `content` | `items.content` | 1 |
| `tags` | space-joined tag names | 8 |
| `url` | `items.url` | 2 |
| `fields` | (v3) values in `meta.fields` | 1 |

Kept in sync **by triggers**:
- Item insert, item delete.
- Update of `title`/`note`/`content`/`url`/`meta`.
- Tag attach/detach, tag rename.

Searches exclude trashed items.

### 2.5 `vec_items` (semantic search)

```sql
CREATE VIRTUAL TABLE vec_items USING vec0(
  item_rowid INTEGER PRIMARY KEY,
  embedding float[512] distance_metric=cosine);
```
- **Vectors:** one per item, 512-dimensional (`EmbeddingConfig.dimension`), from `NLContextualEmbedding` (mean-pooled, L2-normalized).
- **Input text:** title + note + content + field values + tags, cut to the first 2000 characters.
- **Storage format:** raw float32 blobs. Upsert = delete + insert.
- **Cleanup:** an `items_vec_ad` trigger removes the vector when the item is deleted.

### 2.6 `custom_types` (v3)

| Column | Notes |
|---|---|
| `id` | TEXT PK (UUID) |
| `name` | TEXT UNIQUE `COLLATE NOCASE`, trimmed, non-empty |
| `fields` | JSON array of `{ "id": UUID, "name": String, "kind": "text" \| "large_text" \| "web_link" }` |
| `created_at` | DATETIME |

- **Field values** are stored per item in `items.meta.fields` (`{ fieldID: string }`). Empty values are dropped.
- **Removing a field** removes its values from all items.
- **Deleting a type** clears the item link (FK `SET NULL`) and its field values; the items stay.

### 2.7 `enrichment_queue`

| Column | Notes |
|---|---|
| `id` | INTEGER PK |
| `item_id` | → items (CASCADE) |
| `kind` | See below; UNIQUE (`item_id`, `kind`) |
| `status` | `pending` · `running` · `done` · `failed` |
| `attempts` | INTEGER, default 0 |
| `last_error` | TEXT NULL |
| `next_attempt_at` | DATETIME (backoff) |
| `created_at`, `updated_at` | DATETIME |

Index: (`status`, `next_attempt_at`).

**Job kinds, queued per item type in this order:**

| Item type | Jobs |
|---|---|
| image | `ocr` → `colors` → `image_tags` → `ai_tags` → `embedding` → `optimize_image` |
| pdf | `pdf_text` → `ai_tags` → `embedding` |
| link | `link_preview` → `ai_tags` → `embedding` |
| text | `ai_tags` → `embedding` |

**Rules:**
- **Retries:** on failure, retry with exponential backoff `30s × 2^(attempt−1)` (30s, 60s, 120s…). After **3** attempts the job is marked `failed`.
- **Interrupted jobs:** a job left `running` when the app quit or crashed goes back to `pending` on launch, and that counts as an attempt. A job that keeps crashing the app ends up `failed` instead of looping.
- **Unregistered kinds:** if no processor is registered for a kind, the job is marked `done`.
- **Re-queueing:** enqueueing an existing (`item_id`, `kind`) re-arms it (pending, attempts 0).
- **Backfill:** on launch, `link_preview` and `optimize_image` are added once for items that never had them (`INSERT OR IGNORE`).
- **Settings switches:** jobs disabled in Settings are skipped at capture and when they run:
  - OCR → `ocr`
  - Auto-tag → `ai_tags`, `image_tags`
  - Link previews → `link_preview`
  - WebP → `optimize_image`

---

## 3. `items.meta` keys

Free-form JSON. Search can filter any key with `meta.key<op>value`
(`=`, `!=`, `<`, `<=`, `>`, `>=`).

| Key | Type | Set by | Meaning |
|---|---|---|---|
| `byte_size` | number | capture, WebP job | Size of the stored file in bytes |
| `original_byte_size` | number | WebP job | Size before WebP conversion |
| `format` | string | capture, WebP job | Image format (`png`, `jpg`, `heic`, `webp`, …) |
| `webp_optimized` | bool | WebP job, link preview | Conversion was attempted (true even if the original was kept) |
| `source_url` | string | capture (image) | Web page the image was dragged from |
| `host` | string | capture (link/HTML) | Site host |
| `source` | string | capture | `html` when captured from an HTML snippet |
| `page_count` | number | `pdf_text` | Number of PDF pages |
| `encrypted` | bool | `pdf_text` | PDF is password-protected (no text extracted) |
| `has_text` | bool | `ocr` | Image contains recognizable text |
| `colors` | [string] | `colors` (images), `ai_tags` (others) | Named color buckets: red, orange, yellow, green, blue, purple, pink, brown, black, white, gray |
| `dominant_colors` | [string] | `colors` | Hex of the top-3 buckets (`#RRGGBB`) |
| `category` | string | `ai_tags` | Broad category (lowercase) |
| `summary` | string | `ai_tags` | One-sentence summary (≤ 280 chars) |
| `price` | number | `ai_tags` | Price when clearly stated |
| `preview_blob` | string | `link_preview`, WebP job | Blob hash of a link's preview image |
| `page_title` | string | `link_preview` | Fetched page title |
| `suppressed_ai_tags` | [string] | tag removal | Lowercased tags the user removed; AI never re-adds them |
| `fields` | object | custom types | `{ fieldID: value }` for the item's custom type |

---

## 4. Blob store (files)

`BlobStore` is content-addressed storage.

- **Address:** SHA-256 of the bytes (hex).
- **Path:** `blobs/<hash[0..1]>/<hash>.<ext>`. The extension only helps Finder and Quick Look; lookups are by hash.
- **Deduplication:** identical bytes are stored once. `store` reports whether a new file was created.
- **What gets stored:**
  - Images: the original bytes, later WebP.
  - PDFs: the original bytes.
  - Link previews: WebP when smaller.
  - Text and links have no file.
- **References:** a file is in use while any item (trashed or not) refers to it through `blob_hash` **or** `meta.preview_blob`.
- **Deletion:** `deleteIfUnreferenced` only removes unused files. It runs:
  - after a capture fails (rollback, so no orphan files);
  - after trash purge;
  - after WebP conversion (old file removed).

### 4.1 WebP optimization
- **Encoder:** vendored libwebp 1.4.0 (macOS can decode WebP but not encode it). Lossy, quality **82**.
- **Kept as is:**
  - The original is kept unless WebP saves **≥ 5%**.
  - Already-WebP files and animated GIFs are skipped.
  - Undecodable files are left alone.
- **Orientation:** EXIF orientation is applied to the pixels before encoding.
- **Order:** for new images it runs **last** (after OCR, colors and tagging), so analysis uses the original pixels.
- **Copying out:** copying a WebP image puts PNG + TIFF on the clipboard.

---

## 5. Lifecycle

| Event | Storage effect |
|---|---|
| Capture | One write transaction: blob (if any) → `items` row → FTS row (trigger) → queue rows. On error everything rolls back and a newly written blob is removed. |
| Edit (title/note/tags/fields) | Row updated, `updated_at` bumped, FTS re-indexed by trigger |
| Move to Trash | `trashed_at` set; hidden from lists and search; file kept |
| Restore | `trashed_at` cleared |
| Purge (on launch) | Items trashed **> 30 days** are deleted (tags, queue rows and vectors cascade); their files are removed if unused |
| Delete tag everywhere | Tag removed from all items, added to each item's `suppressed_ai_tags` |
| Clear recognized text (Settings) | `content = ''` and `meta.has_text` removed for all images; FTS updated |
| Move library | Snapshot copy to the new folder; old copy untouched (§1) |

---

## 6. Preferences (UserDefaults)

Domain `app.minibrain.MiniBrain`.

| Key | Type | Default | Meaning |
|---|---|---|---|
| `libraryPath` | String? | — | Custom library folder (absent = default) |
| `dropBoxPosition` | String | `topRight` | One of 9 anchors (`topLeft` … `bottomRight`) |
| `autoShowDropBoxOnDrag` | Bool | `true` | Pop the drop box up on any drag |
| `autoTag` | Bool | `true` | AI tagging for every drop |
| `ocrEnabled` | Bool | `true` | Recognize text in images |
| `showRecognizedText` | Bool | `false` | Show OCR text in the library |
| `linkPreviews` | Bool | `true` | Fetch link preview image/title (only network use) |
| `optimizeImages` | Bool | `true` | Convert images to WebP |
| `dockMode` | String | `always` | `always` · `whileWindowsOpen` · `never` |
| `appearance` | String | `system` | `system` · `light` · `dark` |
| `accentColor` | String | `default` | `default` · `red` · `orange` · `yellow` · `green` · `cyan` · `blue` · `violet` · `purple` · `pink` · `system` |
| `shortcut.toggleDropBox` | Data (JSON `KeyCombo`) | ⇧⌘Space | Empty data = cleared |
| `shortcut.toggleLibrary` | Data (JSON `KeyCombo`) | ⇧⌘B | Empty data = cleared |
| `library.detailPanelWidth` | Double | `460` | Saved detail-panel width |
| `sidebar.typesCollapsed` / `sidebar.tagsCollapsed` / `sidebar.colorsCollapsed` | Bool | `false` | Sidebar section state |
| `NSWindow Frame MiniBrainLibrary` | String | — | Library window frame (AppKit autosave) |

`KeyCombo` JSON: `{ "keyCode": UInt32, "modifiers": UInt }`. The modifiers are
`NSEvent.ModifierFlags` raw bits, limited to ⌃⌥⇧⌘.

Reads made off the main thread (capture, enrichment) use thread-safe static
accessors: `AppPreferences.isOCREnabled()`, `isAutoTagEnabled()`,
`areLinkPreviewsEnabled()`, `isImageOptimizationEnabled()`.

---

## 7. Privacy & network

- Everything stays on the Mac: no account, no sync, no telemetry.
- AI tagging uses on-device Apple Intelligence (Foundation Models). Embeddings use `NLContextualEmbedding`. Text recognition uses Vision. All of these run locally.
- **The only network use** is the optional link preview fetch (LinkPresentation), which downloads the saved page's preview image and title. It's controlled by `linkPreviews`.

---

## 8. Tests & fixtures

- **Isolation:**
  - Tests use in-memory databases and temp directories.
  - UserDefaults suites are **absolute paths in the temp dir**, so tests never write to `~/Library/Preferences`.
  - Time comes from a fake clock.
- **Fixtures:** `Tests/Fixtures/`. `v1.sqlite` is a schema-v1 library (regenerate with `make fixtures`).
- **Dev overrides:**
  - `MINIBRAIN_DATA_DIR=/path` runs against another library.
  - `MINIBRAIN_OPEN_SETTINGS=1` opens Settings at launch.

---

## 9. Inspecting a library

```sh
cd ~/Library/Application\ Support/MiniBrain
sqlite3 brain.db "SELECT type, count(*) FROM items WHERE trashed_at IS NULL GROUP BY type;"
sqlite3 brain.db "SELECT kind, status, count(*) FROM enrichment_queue GROUP BY 1,2;"
sqlite3 brain.db "SELECT name FROM tags ORDER BY name COLLATE NOCASE;"
du -sh blobs
defaults read app.minibrain.MiniBrain
```
The system `sqlite3` can't load sqlite-vec, so queries that touch `vec_items` only work inside the app.
