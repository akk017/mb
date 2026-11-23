"""MiniBrain local API client — standard library only (Python 3.8+).

Turn the API on in MiniBrain › Settings › API, then:

    import minibrain
    mb = minibrain.MiniBrain()            # finds the token file automatically
    mb.types()                            # your custom types and their fields
    mb.add(type="Products", title="Sony WH-1000XM5",
           url="amazon.com/dp/B09XS7JWHH",          # the item is this link …
           image="headphones.jpg",                  # … and this is its picture
           fields={"Price": 349}, tags=["audio"])
    mb.add(url="www.imdb.com/title/tt2187153/")
    mb.add(image="poster.png", title="Poster")      # image alone = an Image item
    mb.add(image="https://example.com/a.jpg")       # URLs are downloaded here
    mb.search("type:Products tag:audio")
    mb.import_csv("products.csv", type="Products")  # one row = one item
    mb.export_csv("products-backup.csv", type="Products")

Configuration (all optional):
    MINIBRAIN_API_URL    default http://127.0.0.1:7777
    MINIBRAIN_API_TOKEN  default: read from
                         ~/Library/Application Support/MiniBrain/api-token
"""

from __future__ import annotations

import base64
import csv
import io
import json
import os
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Union

__all__ = ["MiniBrain", "MiniBrainError"]

DEFAULT_URL = "http://127.0.0.1:7777"
TOKEN_FILE = Path.home() / "Library" / "Application Support" / "MiniBrain" / "api-token"


class MiniBrainError(Exception):
    """Raised for API errors; `status` is the HTTP status (0 = couldn't connect)."""

    def __init__(self, status: int, message: str, details: Optional[Dict[str, Any]] = None):
        super().__init__(f"{status}: {message}" if status else message)
        self.status = status
        self.message = message
        # Full JSON error body, e.g. a CSV import's per-row "errors".
        self.details = details or {}


class MiniBrain:
    def __init__(self, url: Optional[str] = None, token: Optional[str] = None, timeout: float = 30):
        self.url = (url or os.environ.get("MINIBRAIN_API_URL") or DEFAULT_URL).rstrip("/")
        self.token = token or os.environ.get("MINIBRAIN_API_TOKEN") or _read_token()
        self.timeout = timeout

    # -- API -------------------------------------------------------------

    def health(self) -> Dict[str, Any]:
        return self._request("GET", "/health")

    def types(self) -> List[Dict[str, Any]]:
        """Custom types: [{"id", "name", "fields": [{"id", "name", "kind"}]}]."""
        return self._request("GET", "/types")["types"]

    def add(
        self,
        *,
        type: Optional[str] = None,
        title: Optional[str] = None,
        text: Optional[str] = None,
        url: Optional[str] = None,
        image: Union[str, Path, bytes, None] = None,
        pdf: Union[str, Path, bytes, None] = None,
        fields: Optional[Dict[str, Any]] = None,
        tags: Optional[Iterable[str]] = None,
        note: Optional[str] = None,
    ) -> Dict[str, Any]:
        """Saves one item and returns it.

        Content: pdf, url, text or title. `image` alone makes an Image item;
        sent together with url/text/pdf it becomes that item's picture (cover).
        `type` is a custom type name; `fields` maps its field names to values.
        `image` takes a file path, bytes, or an http(s) URL (downloaded by this
        client); `pdf` takes a path or bytes. Text next to a url is the note.
        """
        body: Dict[str, Any] = {}
        for key, value in (("type", type), ("title", title), ("text", text), ("url", url), ("note", note)):
            if value is not None:
                body[key] = value
        if image is not None:
            body["image_base64"] = _b64(image)
        if pdf is not None:
            body["pdf_base64"] = _b64(pdf)
        if fields:
            body["fields"] = fields
        if tags:
            body["tags"] = list(tags)
        return self._request("POST", "/items", body)

    def search(self, query: str = "", limit: int = 50) -> List[Dict[str, Any]]:
        """Same syntax as the search box: words, type:, tag:, color:, …"""
        qs = urllib.parse.urlencode({"q": query, "limit": limit})
        return self._request("GET", f"/items?{qs}")["items"]

    def import_csv(
        self,
        source: Union[str, Path],
        *,
        type: Optional[str] = None,
        dry_run: bool = False,
        skip_invalid: bool = False,
        download_images: bool = True,
    ) -> Dict[str, Any]:
        """Imports a CSV (path, or the CSV text itself): one row = one item.

        Columns: title/name, url, text, note, tags ("a; b"), image (file path
        relative to the CSV, absolute, or an http(s) URL — downloaded here),
        type (per row, when `type` isn't given), and the type's field names.

        Every row is validated first. By default one bad row means nothing is
        saved: MiniBrainError(400) with `.details["errors"]` = [{row, message}].
        `skip_invalid=True` imports the good rows; `dry_run=True` only checks.
        Returns {"imported": [ids], "imported_count", "total_rows",
        "valid_rows", "errors", "columns", "ignored_columns", "dry_run"}.
        """
        text, base_dir = _csv_source(source)
        with tempfile.TemporaryDirectory(prefix="minibrain-csv-") as tmp:
            if download_images:
                text = _download_csv_images(text, Path(tmp))
            body: Dict[str, Any] = {"csv": text, "dry_run": dry_run, "skip_invalid": skip_invalid}
            if type:
                body["type"] = type
            if base_dir:
                body["base_dir"] = base_dir
            return self._request("POST", "/import/csv", body)

    def export_csv(self, path: Union[str, Path, None] = None, *, type: Optional[str] = None,
                   query: str = "") -> str:
        """Items as CSV (one column per custom field). Writes `path` if given;
        always returns the CSV text. The image column holds file paths, so the
        export can be re-imported with import_csv."""
        params = {k: v for k, v in (("type", type), ("q", query)) if v}
        qs = f"?{urllib.parse.urlencode(params)}" if params else ""
        text = self._request("GET", f"/export/csv{qs}", raw=True)
        if path is not None:
            Path(path).expanduser().write_text(text, encoding="utf-8")
        return text

    def get(self, item_id: str) -> Dict[str, Any]:
        return self._request("GET", f"/items/{urllib.parse.quote(item_id)}")

    # -- HTTP ------------------------------------------------------------

    def _request(self, method: str, path: str, body: Optional[Dict[str, Any]] = None, raw: bool = False) -> Any:
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.url + path, data=data, method=method)
        req.add_header("Accept", "text/csv" if raw else "application/json")
        if data is not None:
            req.add_header("Content-Type", "application/json")
        if self.token:
            req.add_header("Authorization", f"Bearer {self.token}")
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                payload = resp.read()
                return payload.decode("utf-8") if raw else json.loads(payload or b"{}")
        except urllib.error.HTTPError as e:
            details: Dict[str, Any] = {}
            try:
                details = json.loads(e.read())
                message = details.get("error", e.reason)
            except Exception:
                message = e.reason
            raise MiniBrainError(e.code, str(message), details) from None
        except urllib.error.URLError as e:
            raise MiniBrainError(
                0, f"Can't reach MiniBrain at {self.url} ({e.reason}). Is the app running with Settings › API on?"
            ) from None


def _read_token() -> Optional[str]:
    try:
        return TOKEN_FILE.read_text().strip() or None
    except OSError:
        return None


IMAGE_COLUMNS = {"image", "image_path", "picture", "photo", "cover"}


def _csv_source(source: Union[str, Path]):
    """(csv text, absolute folder for relative image paths or None)."""
    if isinstance(source, Path) or ("\n" not in str(source) and Path(str(source)).expanduser().is_file()):
        path = Path(source).expanduser().resolve()
        return path.read_text(encoding="utf-8-sig"), str(path.parent)
    return str(source), os.getcwd()


def _download_csv_images(text: str, folder: Path) -> str:
    """Downloads http(s) URLs in the image column to `folder`; rewrites the cells."""
    sample = text.split("\n", 1)[0]
    delimiter = max([",", ";", "\t"], key=sample.count)
    rows = list(csv.reader(io.StringIO(text), delimiter=delimiter))
    if not rows:
        return text
    image_cols = [i for i, h in enumerate(rows[0]) if h.strip().lower() in IMAGE_COLUMNS]
    changed = False
    for n, row in enumerate(rows[1:], start=1):
        for i in image_cols:
            if i < len(row) and row[i].strip().lower().startswith(("http://", "https://")):
                target = folder / f"row{n}-{i}"
                target.write_bytes(base64.b64decode(_b64(row[i].strip())))
                row[i] = str(target)
                changed = True
    if not changed:
        return text
    out = io.StringIO()
    csv.writer(out, delimiter=delimiter).writerows(rows)
    return out.getvalue()


def _b64(value: Union[str, Path, bytes]) -> str:
    if isinstance(value, bytes):
        data = value
    elif isinstance(value, str) and value.lower().startswith(("http://", "https://")):
        req = urllib.request.Request(value, headers={"User-Agent": "minibrain-python"})
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                data = resp.read()
        except urllib.error.URLError as e:
            raise MiniBrainError(0, f"Couldn't download image {value}: {e}") from None
    else:
        data = Path(value).expanduser().read_bytes()
    return base64.b64encode(data).decode()


if __name__ == "__main__":  # quick check: python3 minibrain.py
    mb = MiniBrain()
    print(json.dumps({"health": mb.health(), "types": mb.types()}, indent=2))
