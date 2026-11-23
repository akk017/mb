# MiniBrain Python API

Add, search, **import and export (CSV)** MiniBrain items from Python (or any
language that can send HTTP), including **custom types** like `Products` with
their fields, tags and images.

- **Client:** [`clients/python/minibrain.py`](clients/python/minibrain.py). It uses only the standard library and needs Python 3.8 or later.
- **Server:** a small HTTP API inside the MiniBrain app. It listens on `127.0.0.1` only, is off by default, and needs a token.

---

## 1. Setup

1. Open **MiniBrain › Settings › API** and switch on **Enable local API**.
   The status shows `Running at http://127.0.0.1:7777`.
2. Get the client:
   - From the repo: `clients/python/minibrain.py`
   - From the app: Settings › API › **Show Python Client**. It's bundled in
     `MiniBrain.app/Contents/Resources/minibrain.py`.
3. Put `minibrain.py` next to your script, or add its folder to `PYTHONPATH`.
4. Check it:

   ```bash
   python3 minibrain.py        # prints health + your custom types
   ```

You don't need to copy the token anywhere. The client reads it from
`~/Library/Application Support/MiniBrain/api-token`.

The MiniBrain app must be running. If it isn't, calls raise
`MiniBrainError(0, "Can't reach MiniBrain …")`.

---

## 2. Quick start

```python
import minibrain

mb = minibrain.MiniBrain()

# What custom types do I have?
for t in mb.types():
    print(t["name"], [f["name"] for f in t["fields"]])
# Products ['Price', 'Buy Link', 'Description']

# A product: a link, its picture, fields and tags
item = mb.add(
    type="Products",
    title="Sony WH-1000XM5",
    url="amazon.com/dp/B09XS7JWHH",
    image="~/Pictures/headphones.jpg",
    fields={"Price": 349, "Description": "Noise cancelling, black"},
    tags=["audio", "wishlist"],
)
print(item["id"], item["custom_type"], item["fields"])

# Search (same syntax as the search box)
for p in mb.search("type:Products tag:audio"):
    print(p["title"], p["fields"].get("Price"))
```

---

## 3. The client

### `MiniBrain(url=None, token=None, timeout=30)`

| Argument | Default |
|---|---|
| `url` | `$MINIBRAIN_API_URL`, else `http://127.0.0.1:7777` |
| `token` | `$MINIBRAIN_API_TOKEN`, else the token file |
| `timeout` | seconds per request |

### `mb.add(...) -> dict`

Saves **one** item and returns it (see [Item](#6-item-json)). Every argument is keyword-only and optional, but there has to be something to save.

| Argument | Type | Meaning |
|---|---|---|
| `type` | `str` | Custom type name (any letter case) or id, e.g. `"Products"` |
| `title` | `str` | Item title. Without it, a title is detected: the page title for links, the first line for text, the file name for images. |
| `url` | `str` | Makes a **link**. Accepts `https://…`, `http://…`, `www.…` or a bare host like `blog.example.com` (gets `https://`). The page title and preview image are fetched. |
| `text` | `str` | Makes a **text** note. When given together with `url`, it's saved as the link's note instead. |
| `image` | path · `bytes` · `http(s)` URL | **Alone:** makes an **Image** item. **With `url`/`text`/`pdf`:** becomes that item's **picture** (cover). A URL is downloaded by the client. |
| `pdf` | path · `bytes` | Makes a **PDF** item. Its text is extracted for search. |
| `fields` | `dict` | Custom field values by field **name** (any letter case) or id. Values can be strings or numbers; `349` is stored as `"349"`. Needs `type`. |
| `tags` | iterable of `str` | Tags to attach. Surrounding spaces are trimmed and empty strings ignored. |
| `note` | `str` | The item's Note property. |

**What gets created:**

| You pass | Item kind | Picture |
|---|---|---|
| `url` (+ `image`) | Link | the `image`, else the page's preview image |
| `text` (+ `image`) | Text | the `image` |
| `pdf` (+ `image`) | PDF | the `image`, else the first page |
| `image` only | Image | the image itself |
| `title` only | Text (the title is the text) | — |

After saving, background processing runs just as it does for a drop: link preview, OCR, colours, AI tags (if on in Settings) and search indexing. The library window updates within a second.

### `mb.types() -> list[dict]`

```python
[{"id": "…", "name": "Products",
  "fields": [{"id": "…", "name": "Price", "kind": "text"},
             {"id": "…", "name": "Buy Link", "kind": "web_link"},
             {"id": "…", "name": "Description", "kind": "large_text"}]}]
```

Field kinds: `text`, `large_text`, `web_link`.

### `mb.search(query="", limit=50) -> list[dict]`

The same syntax as the app's search box. An empty query lists the newest items. `limit` is 1–500.

| Syntax | Example |
|---|---|
| words | `noise cancelling` |
| exact phrase | `"bloom filter"` |
| item kind | `type:link` · `type:image` · `type:pdf` · `type:text` |
| custom type | `type:Products` · `type:"Reading List"` |
| tag | `tag:audio` |
| colour (images) | `color:red` |
| date | `after:2026-01-01` · `before:2026-12-31` |
| metadata | `meta.price<100` |

Combine them: `type:Products tag:audio after:2026-11-01 sony`.

### `mb.import_csv(source, type=None, dry_run=False, skip_invalid=False, download_images=True) -> dict`

Imports a CSV file (a path) or CSV text, with **one row per item**.

```python
report = mb.import_csv("products.csv", type="Products")
print(report["imported_count"], "imported")
```

**Columns.** Header names are matched in any letter case. The separator (`,`, `;` or tab) is detected automatically.

| Column | Becomes |
|---|---|
| `title` / `name` | title |
| `url` / `link` / `website` | the link |
| `text` / `content` / `body` | text (or the link's note when there's a url) |
| `note` / `notes` | Note |
| `tags` | tags, split on `,` `;` or `|` (`audio; wishlist`) |
| `image` / `picture` / `photo` / `cover` | an image file: relative to the CSV, absolute, `~/…`, or an `http(s)` URL (downloaded by the client). Alone it makes an Image item; with a url or text it becomes the item's picture. |
| `type` | a custom type for **that row**. Only used when you don't pass `type=`. |
| any field name of the type | that field, e.g. `Price`, `Buy Link` |
| anything else | ignored (listed in `ignored_columns`) |

If the chosen type has a field with the same name as a built-in column (e.g. a field called `URL`), the field wins.

**Validation.** Every row is checked first, using exactly the same rules as `add()`.
- **Default (all-or-nothing):** if any row has a problem, nothing is saved, and `MiniBrainError(400)` is raised with `e.details["errors"] = [{"row": 3, "message": "…"}]`. Row numbers count the header as row 1.
- **`skip_invalid=True`:** imports the good rows and reports the bad ones.
- **`dry_run=True`:** only checks and saves nothing. Use it to preview the column mapping.

```python
try:
    mb.import_csv("products.csv", type="Products")
except minibrain.MiniBrainError as e:
    for err in e.details.get("errors", []):
        print(f"row {err['row']}: {err['message']}")
```

**Returns:**

```python
{"imported": ["id1", "id2"], "imported_count": 2, "total_rows": 3, "valid_rows": 2,
 "errors": [{"row": 4, "message": "Buy Link must be a web address, got 'x'"}],
 "columns": [{"header": "Name", "maps_to": "Title"}, ...],
 "ignored_columns": ["Colour"], "dry_run": False}
```

The limit is 10,000 rows per file.

### `mb.export_csv(path=None, type=None, query="") -> str`

Exports items as CSV and returns the text. If `path` is given, it also writes the file.

```python
mb.export_csv("products-backup.csv", type="Products")
mb.export_csv("audio.csv", query="tag:audio")
```

Columns: `title, kind, url, text, note, tags, image, type, created_at, id`, then one column per custom field. The `image` column holds the path of the stored file, so **an export can be re-imported** with `import_csv` (into the same library or another one).

### `mb.get(item_id) -> dict`

One item by id. Raises 404 if it doesn't exist or is in the trash.

### `mb.health() -> dict`

`{"ok": True, "version": "0.1.0"}`. Doesn't need a token.

### Errors

Every failure raises `minibrain.MiniBrainError`, which has `.status` (the HTTP status, or `0` if the app couldn't be reached) and `.message`.

```python
try:
    mb.add(url="hello world")
except minibrain.MiniBrainError as e:
    print(e.status, e.message)
# 400 url 'hello world' is not a valid web address (e.g. https://example.com or blog.example.com)
```

| Status | When |
|---|---|
| `0` | App not running, API switched off, or wrong port |
| `400` | Bad input: invalid URL, unknown field, field without `type`, bad web-link field value, not an image, invalid base64, malformed JSON, nothing to save |
| `401` | Missing or wrong token (e.g. after **Regenerate**) |
| `403` | Request came from a browser, or used a non-local Host |
| `404` | Unknown custom type (the message lists your types), or unknown item id |
| `413` | Body larger than 30 MB |

**A failed `add` saves nothing.** All input is checked before anything is written.

---

## 4. Recipes

**Import a CSV of products**

```python
# products.csv
# Name,Price,Buy Link,Image,Tags
# Sony WH-1000XM5,349,amazon.com/dp/B09XS7JWHH,images/sony.jpg,audio; wishlist
# Kindle,99,,https://example.com/kindle.jpg,reading
report = mb.import_csv("products.csv", type="Products", skip_invalid=True)
print(report["imported_count"], "imported;", len(report["errors"]), "skipped")
```

**Or row by row with `add()` (custom logic per row)**

```python
import csv
with open("products.csv", newline="") as f:
    for row in csv.DictReader(f):
        mb.add(type="Products", title=row["Name"], fields={"Price": row["Price"]})
```

**Save a folder of screenshots**

```python
from pathlib import Path
for png in sorted(Path("~/Desktop/shots").expanduser().glob("*.png")):
    mb.add(image=png, tags=["screenshot"])
```

**Bookmark with a custom picture from the web**

```python
mb.add(url="https://antonz.org/probabilistic-data-structures/",
       image="https://example.com/cover.jpg", tags=["go", "read-later"])
```

**Fill a type's Web Link field**

```python
mb.add(type="Products", title="Kindle", fields={"Buy Link": "amazon.com/dp/B0CFPJYX7P"})
```

**Export a custom type to JSON**

```python
import json
json.dump(mb.search("type:Products", limit=500), open("products.json", "w"), indent=2)
```

---

## 5. HTTP reference (without the client)

Base URL: `http://127.0.0.1:<port>` (default port `7777`, changeable in Settings › API).

Every route except `/health` needs `Authorization: Bearer <token>`. Request and response bodies are JSON (`Content-Type: application/json`).

| Method | Path | Body / query | Success |
|---|---|---|---|
| GET | `/health` | — | `200 {"ok": true, "version": "…"}` |
| GET | `/types` | — | `200 {"types": [...]}` |
| POST | `/items` | JSON below | `201` + item |
| GET | `/items` | `?q=<query>&limit=<1-500>` | `200 {"items": [...]}` |
| GET | `/items/{id}` | — | `200` + item |
| POST | `/import/csv` | CSV body (`Content-Type: text/csv`, options in the query: `type`, `dry_run`, `skip_invalid`, `base_dir`) or JSON `{"csv", "type", "dry_run", "skip_invalid", "base_dir"}` | `201` imported · `200` dry run / nothing imported · `400` rows with problems (nothing saved) + report |
| GET | `/export/csv` | `?type=Products&q=<query>&limit=` | `200 text/csv` |

**`POST /items` body** (all keys optional, but something must be saved):

```json
{
  "type": "Products",
  "title": "Sony WH-1000XM5",
  "url": "amazon.com/dp/B09XS7JWHH",
  "text": "…",
  "note": "gift idea",
  "image_base64": "<base64 PNG/JPEG/HEIC/WebP/GIF/TIFF>",
  "pdf_base64": "<base64 PDF>",
  "fields": {"Price": 349, "Buy Link": "amazon.com/dp/B09XS7JWHH"},
  "tags": ["audio"]
}
```

`image_base64` follows the same rule as in the client: alone it makes an Image item, and together with `url`, `text` or `pdf_base64` it becomes that item's cover.

**Errors:** `{"error": "<message>"}` with the status codes listed above.

**curl:**

```bash
TOKEN=$(cat ~/Library/Application\ Support/MiniBrain/api-token)

curl -s http://127.0.0.1:7777/types -H "Authorization: Bearer $TOKEN"

curl -s http://127.0.0.1:7777/items \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"type": "Products", "title": "Kindle", "fields": {"Price": "99"}, "tags": ["reading"]}'

curl -s "http://127.0.0.1:7777/items?q=type%3AProducts" -H "Authorization: Bearer $TOKEN"

curl -s "http://127.0.0.1:7777/import/csv?type=Products&skip_invalid=1" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: text/csv" --data-binary @products.csv

curl -s "http://127.0.0.1:7777/export/csv?type=Products" -H "Authorization: Bearer $TOKEN" -o products.csv
```

`base_dir` is the folder that relative image paths in the CSV are resolved against. Over HTTP, the `image` column must hold file paths on this Mac. Only the Python client downloads image URLs.

**Protocol limits:** HTTP/1.1, one request per connection (`Connection: close`). The body needs a `Content-Length` header; chunked uploads get 411. Headers can be at most 32 KB, the body at most 30 MB, and a request times out after 30 s.

---

## 6. Item JSON

```json
{
  "id": "6E68165D-DF5D-41A7-8E8B-BA6310B2A6F6",
  "kind": "link",
  "title": "Sony WH-1000XM5",
  "url": "https://amazon.com/dp/B09XS7JWHH",
  "note": "",
  "custom_type": "Products",
  "fields": {"Price": "349", "Description": "Noise cancelling, black"},
  "tags": ["audio", "wishlist"],
  "has_image": true,
  "created_at": "2026-11-22T09:24:32Z"
}
```

| Key | Notes |
|---|---|
| `kind` | `text` · `link` · `image` · `pdf` |
| `url` | `null` when the item has none |
| `custom_type` | type name, or `null` |
| `fields` | non-empty values only, keyed by field **name** |
| `tags` | your tags plus AI tags once they've run |
| `has_image` | the item is an image, or has a cover or link preview |
| `text` | only for `text` items: the note's content |
| `created_at` | ISO-8601, UTC |

Titles and tags filled in later by background processing (link page titles, AI tags) appear when you fetch the item again with `mb.get(id)` a few seconds afterwards.

---

## 7. Security

- **Off by default.** Settings › API › Enable local API.
- **This Mac only.** The server listens on `127.0.0.1` and isn't reachable from the network.
- **Token.** It's 256-bit and random, stored in `~/Library/Application Support/MiniBrain/api-token` with mode `0600` (only your user can read it). **Regenerate** in Settings replaces it, and scripts using the old token get `401`.
- **No browser access.** Requests with an `Origin` header, or whose `Host` isn't `127.0.0.1`, `localhost` or `[::1]`, are refused with `403`. This stops a web page from calling the API, including through DNS rebinding.
- **Logging.** Each request is logged as `[api] POST /items → 201 in 12ms` in `~/Library/Application Support/MiniBrain/Logs/minibrain.log`. Bodies, tokens and item contents are never logged.
- **No outbound fetches.** The app doesn't download URLs passed to the API. When `image=` is an http(s) URL, the Python client downloads it before sending.

---

## 8. Troubleshooting

| Symptom | Fix |
|---|---|
| `MiniBrainError(0, "Can't reach MiniBrain …")` | Start the app and switch on Settings › API. Check the port matches (`MINIBRAIN_API_URL`). |
| Settings shows `Port 7777 is already in use` | Pick another port in Settings › API, then set `MINIBRAIN_API_URL=http://127.0.0.1:<port>`. |
| `401` | The token changed (Regenerate). The client re-reads the token file on every new `MiniBrain()`. |
| `404 Unknown type 'X'. Known: …` | Use one of the listed names, or create the type in Settings › Types. |
| `400 Unknown field 'X' for type Products. Fields: …` | Use one of the listed field names. |
| `400 N row(s) have problems; nothing was saved` | Read `e.details["errors"]`, fix those rows, or pass `skip_invalid=True`. |
| `400 None of the columns can be imported` | Rename the headers to `title`/`url`/`text`/`image` or the type's field names. |
| Item saved but no preview yet | Previews and AI tags run in the background for a few seconds. Search, or `mb.get(id)`, again. |

Not supported yet: creating custom types, or editing and deleting items, through the API.
