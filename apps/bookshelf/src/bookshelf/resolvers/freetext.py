"""Free-text search, for when nothing identifier-shaped was typed.

Asks the DNB for the words as a conjunction and Open Library's search index in
parallel, which between them cover scores and academic books.
"""

from __future__ import annotations

import json
import re
from typing import Any, Final

from bookshelf import catnum
from bookshelf.fetch import Fetcher, ProviderUnavailable
from bookshelf.models import Candidate, Kind
from bookshelf.resolvers import dnb
from bookshelf.resolvers.isbn import normalise

OPEN_LIBRARY_SEARCH: Final = "https://openlibrary.org/search.json"


class FreeTextResolver:
    name = "freetext"

    def handles(self, query: str) -> bool:
        cleaned = query.strip()
        if len(cleaned) < 3:
            return False
        # Identifier-shaped input belongs to the resolvers that can do it properly.
        return normalise(cleaned) is None and not catnum.looks_like_catalogue_number(cleaned)

    async def search(self, query: str, fetcher: Fetcher) -> list[Candidate]:
        out: list[Candidate] = []
        try:
            out += await dnb.DnbResolver().free_text(query, fetcher)
        except ProviderUnavailable:
            pass
        try:
            out += await self._open_library(query, fetcher)
        except ProviderUnavailable:
            pass
        return out

    async def _open_library(self, query: str, fetcher: Fetcher) -> list[Candidate]:
        body = await fetcher.get(
            OPEN_LIBRARY_SEARCH,
            provider="openlibrary",
            params={
                "q": query,
                "limit": "10",
                "fields": "key,title,author_name,publisher,first_publish_year,isbn,number_of_pages_median",
            },
            interval=1.0,
        )
        payload: dict[str, Any] = json.loads(body or "{}")

        out: list[Candidate] = []
        for doc in payload.get("docs") or []:
            isbns = [i for i in (doc.get("isbn") or []) if len(re.sub(r"\D", "", i)) == 13]
            publishers = doc.get("publisher") or []
            authors = doc.get("author_name") or []
            out.append(
                Candidate(
                    source="openlibrary",
                    source_ref=doc.get("key"),
                    title=str(doc.get("title") or "(untitled)"),
                    composer=str(authors[0]) if authors else None,
                    publisher=str(publishers[0]) if publishers else None,
                    isbn13=isbns[0] if isbns else None,
                    year=doc.get("first_publish_year"),
                    pages=doc.get("number_of_pages_median"),
                    kind=Kind.BOOK,
                    score=0.4,
                )
            )
        return out
