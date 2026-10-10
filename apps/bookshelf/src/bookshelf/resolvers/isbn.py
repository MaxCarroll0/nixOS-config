"""ISBN and ISMN lookup: Open Library first, then Google Books.

Open Library needs no key and is tried first; Google Books fills gaps but is quota
limited. Neither knows much about sheet music, so a 979-0 ISMN is handed back to the
DNB resolver rather than asked of them.
"""

from __future__ import annotations

import json
import re
from typing import Any, Final

import isbnlib

from bookshelf.fetch import Fetcher, ProviderUnavailable
from bookshelf.models import Candidate, Kind

OPEN_LIBRARY: Final = "https://openlibrary.org/api/books"
OPEN_LIBRARY_ISBN: Final = "https://openlibrary.org/isbn"
OPEN_LIBRARY_BASE: Final = "https://openlibrary.org"
GOOGLE_BOOKS: Final = "https://www.googleapis.com/books/v1/volumes"


def normalise(raw: str) -> str | None:
    """Canonical ISBN-13 for anything that is one, else None."""
    digits = re.sub(r"[^0-9Xx]", "", raw)
    if not digits:
        return None
    if isbnlib.is_isbn13(digits):
        return digits
    if isbnlib.is_isbn10(digits):
        converted = isbnlib.to_isbn13(digits)
        return str(converted) if converted else None
    return None


def is_ismn(raw: str) -> bool:
    """ISMNs share the 979 prefix with some ISBNs but are a different register."""
    digits = re.sub(r"[^0-9]", "", raw)
    return len(digits) == 13 and digits.startswith("9790")


def _year(raw: Any) -> int | None:
    match = re.search(r"(1[5-9]\d{2}|20\d{2})", str(raw or ""))
    return int(match.group(1)) if match else None


class IsbnResolver:
    name = "isbn"

    def handles(self, query: str) -> bool:
        return normalise(query) is not None or is_ismn(query)

    async def search(self, query: str, fetcher: Fetcher) -> list[Candidate]:
        isbn13 = normalise(query)
        if isbn13 is None:
            return []
        out = await self._open_library(isbn13, fetcher)
        if not out:
            out = await self._google(isbn13, fetcher)
        return out

    async def _open_library(self, isbn13: str, fetcher: Fetcher) -> list[Candidate]:
        body = await fetcher.get(
            OPEN_LIBRARY,
            provider="openlibrary",
            params={"bibkeys": f"ISBN:{isbn13}", "format": "json", "jscmd": "data"},
            interval=1.0,
        )
        payload: dict[str, Any] = json.loads(body or "{}")
        record = payload.get(f"ISBN:{isbn13}")
        if not isinstance(record, dict):
            return []

        publishers = record.get("publishers") or []
        authors = record.get("authors") or []
        pages = record.get("number_of_pages")
        subjects = [str(s["name"]) for s in (record.get("subjects") or []) if s.get("name")]

        description = await self._description(isbn13, fetcher)
        return [
            Candidate(
                source="openlibrary",
                source_ref=record.get("key"),
                url=record.get("url"),
                title=str(record.get("title") or "(untitled)"),
                composer=str(authors[0]["name"]) if authors else None,
                publisher=str(publishers[0]["name"]) if publishers else None,
                isbn13=isbn13,
                year=_year(record.get("publish_date")),
                pages=int(pages) if isinstance(pages, int) else None,
                description=description,
                subjects=subjects[:12],
                kind=Kind.BOOK,
                score=0.85,
            )
        ]

    async def _description(self, isbn13: str, fetcher: Fetcher) -> str | None:
        """Open Library keeps prose on the *work*, not the edition, so follow the link."""
        try:
            edition = json.loads(
                await fetcher.get(
                    f"{OPEN_LIBRARY_ISBN}/{isbn13}.json", provider="openlibrary", interval=1.0
                )
                or "{}"
            )
            works = edition.get("works") or []
            if not works:
                return None
            key = str(works[0].get("key") or "")
            if not key:
                return None
            work = json.loads(
                await fetcher.get(
                    f"{OPEN_LIBRARY_BASE}{key}.json", provider="openlibrary", interval=1.0
                )
                or "{}"
            )
        except ProviderUnavailable:
            return None

        # The field is sometimes a bare string and sometimes a typed-value object.
        raw = work.get("description")
        if isinstance(raw, dict):
            raw = raw.get("value")
        return str(raw).strip() if raw else None

    async def _google(self, isbn13: str, fetcher: Fetcher) -> list[Candidate]:
        from bookshelf.config import SETTINGS

        params = {"q": f"isbn:{isbn13}", "maxResults": "5"}
        if SETTINGS.google_books_key:
            params["key"] = SETTINGS.google_books_key
        body = await fetcher.get(
            GOOGLE_BOOKS, provider="googlebooks", params=params, interval=1.0
        )
        payload: dict[str, Any] = json.loads(body or "{}")

        out: list[Candidate] = []
        for item in payload.get("items") or []:
            info = item.get("volumeInfo") or {}
            authors = info.get("authors") or []
            categories = [str(c) for c in (info.get("categories") or [])]
            out.append(
                Candidate(
                    source="googlebooks",
                    source_ref=str(item.get("id") or "") or None,
                    url=info.get("infoLink"),
                    title=str(info.get("title") or "(untitled)"),
                    title_en=info.get("subtitle"),
                    composer=str(authors[0]) if authors else None,
                    publisher=info.get("publisher"),
                    isbn13=isbn13,
                    year=_year(info.get("publishedDate")),
                    pages=info.get("pageCount") if isinstance(info.get("pageCount"), int) else None,
                    description=str(info["description"]).strip()
                    if info.get("description")
                    else None,
                    subjects=categories[:12],
                    kind=Kind.BOOK,
                    score=0.8,
                )
            )
        return out
