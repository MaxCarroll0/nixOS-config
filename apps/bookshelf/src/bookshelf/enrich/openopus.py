"""Open Opus: canonical work lists per composer. Free, public domain, no registration."""

from __future__ import annotations

import json
from typing import Any, Final

from bookshelf.fetch import Fetcher, ProviderUnavailable
from bookshelf.models import ContentItem

BASE: Final = "https://api.openopus.org"


async def composer_id(name: str, fetcher: Fetcher) -> str | None:
    """Open Opus's id for a composer named like this, by its own fuzzy search."""
    surname = name.split(",")[0].strip() or name.strip()
    body = await fetcher.get(
        f"{BASE}/composer/list/search/{surname}.json", provider="openopus", interval=1.0
    )
    payload: dict[str, Any] = json.loads(body or "{}")
    composers = payload.get("composers") or []
    return str(composers[0]["id"]) if composers else None


async def works_for(name: str, fetcher: Fetcher) -> list[ContentItem]:
    """Every catalogued work by a composer, as selectable content items."""
    identifier = await composer_id(name, fetcher)
    if identifier is None:
        return []

    body = await fetcher.get(
        f"{BASE}/work/list/composer/{identifier}/genre/all.json",
        provider="openopus",
        interval=1.0,
    )
    payload: dict[str, Any] = json.loads(body or "{}")
    works = payload.get("works")
    if works is None:
        raise ProviderUnavailable("openopus: no works for composer")

    return [
        ContentItem(
            ordinal=index,
            label=str(work.get("title") or "(untitled)"),
            work_title=str(work.get("title") or ""),
            composer=name,
        )
        for index, work in enumerate(works, start=1)
    ]
