"""MusicBrainz work relationships, which is where real movement lists live.

Open Opus names works; it does not break them into movements. MusicBrainz models a
multi-movement work as a parent with ``part of`` children, so a sonata's movements come
from walking those relations. Its rate limit is one request a second and is enforced.
"""

from __future__ import annotations

import json
import re
from typing import Any, Final

from bookshelf.fetch import Fetcher
from bookshelf.models import ContentItem

BASE: Final = "https://musicbrainz.org/ws/2"

_ORDINAL = re.compile(r"^\s*(?:(\d+)|([IVXLC]+))\s*[.:)]\s*")


def _sort_key(title: str) -> tuple[int, str]:
    """Movements are usually numbered in their titles; use that to order them."""
    roman = {"I": 1, "V": 5, "X": 10, "L": 50, "C": 100}
    match = _ORDINAL.match(title)
    if match is None:
        return (10**6, title)
    if match.group(1):
        return (int(match.group(1)), title)

    numeral, total, previous = match.group(2), 0, 0
    for char in reversed(numeral):
        value = roman[char]
        total = total - value if value < previous else total + value
        previous = max(previous, value)
    return (total, title)


async def find_work(title: str, composer: str | None, fetcher: Fetcher) -> str | None:
    """The MBID of the work best matching a title, or None."""
    query = f'work:"{title}"'
    if composer:
        query += f' AND artist:"{composer.split(",")[0].strip()}"'
    body = await fetcher.get(
        f"{BASE}/work",
        provider="musicbrainz",
        params={"query": query, "fmt": "json", "limit": "5"},
        interval=1.1,
    )
    payload: dict[str, Any] = json.loads(body or "{}")
    works = payload.get("works") or []
    return str(works[0]["id"]) if works else None


async def movements_for(mbid: str, fetcher: Fetcher) -> list[ContentItem]:
    """The movements of a work, from its ``part of`` child relations."""
    body = await fetcher.get(
        f"{BASE}/work/{mbid}",
        provider="musicbrainz",
        params={"fmt": "json", "inc": "work-rels"},
        interval=1.1,
    )
    payload: dict[str, Any] = json.loads(body or "{}")

    titles: list[str] = []
    for relation in payload.get("relations") or []:
        if relation.get("type") != "parts":
            continue
        # "parts" points both ways; the children are the backward direction.
        if relation.get("direction") != "forward":
            continue
        child = relation.get("work") or {}
        title = child.get("title")
        if title:
            titles.append(str(title))

    titles.sort(key=_sort_key)
    return [
        ContentItem(ordinal=index, label=title, work_title=title)
        for index, title in enumerate(titles, start=1)
    ]
