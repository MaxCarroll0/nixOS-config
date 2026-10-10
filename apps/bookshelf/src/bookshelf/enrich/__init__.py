"""Filling in works and movements, so a volume's contents can be browsed offline."""

from __future__ import annotations

import re
import sqlite3
from typing import TYPE_CHECKING

from bookshelf.enrich.musicbrainz import find_work, movements_for
from bookshelf.enrich.openopus import works_for

if TYPE_CHECKING:
    from bookshelf.fetch import Fetcher

__all__ = ["enrich_edition", "find_work", "movements_for", "works_for"]


#: Key, opus and thematic-catalogue clauses, which libraries append to a title.
_DECORATION = re.compile(
    r"""\s*(?:
        ,?\s*[A-H](?:is|es)?[-\s](?:Moll|Dur|minor|major)
      | ,?\s*op(?:us)?\.?\s*\d+[a-z]?
      | ,?\s*(?:KV|BWV|D|B|Hob\.?|HWV|RV)\s*[IVXLC]*:?\s*\d+
      | ,?\s*(?:in|f\u00fcr)\s+[A-H](?:is|es)?\b
    )\s*$""",
    re.IGNORECASE | re.VERBOSE,
)


def candidate_titles(title: str | None, uniform_title: str | None) -> list[str]:
    """Title forms worth asking a recording database about, most promising first.

    A library's uniform title is a filing heading rather than a name: Dvořák's wind
    serenade is filed under the bare genre plural "Serenaden", which matches nothing
    outside a library catalogue. The title as printed is the better query, and the
    cataloguing decoration on it -- key, opus, scoring -- is worth stripping as a third
    attempt, since a search engine scores a shorter query more generously.
    """
    forms: list[str] = []

    def offer(value: str | None) -> None:
        cleaned = re.sub(r"\s{2,}", " ", (value or "")).strip(" .,:;")
        if cleaned and len(cleaned) > 2 and cleaned not in forms:
            forms.append(cleaned)

    offer(title)
    offer(uniform_title)

    if title:
        # Strip the cataloguing decoration a clause at a time, since a title carries
        # several: "Bläserserenade d-Moll Opus 44" -> "Bläserserenade".
        bare = title
        while True:
            shorter = _DECORATION.sub("", bare).strip(" .,:;")
            if shorter == bare or len(shorter) < 3:
                break
            bare = shorter
        offer(bare)

    return forms[:3]


async def enrich_edition(
    conn: sqlite3.Connection,
    edition_id: int,
    fetcher: "Fetcher",
) -> int:
    """Fill in the movements of the works an edition contains.

    A MARC contents note breaks an anthology into its pieces, but says nothing about the
    movements inside each one -- a sonata arrives as a single line. MusicBrainz models a
    multi-movement work as a parent with ``part of`` children, so walking those is what
    turns "Sonata in A" into its four movements and makes them searchable.
    """
    from bookshelf import db

    works = db.all_rows(
        conn,
        """SELECT w.id, w.title, w.uniform_title, p.name AS composer
           FROM work w
           JOIN edition_content ec ON ec.work_id = w.id
           LEFT JOIN person p ON p.id = w.person_id
           WHERE ec.edition_id = ?
             AND NOT EXISTS (SELECT 1 FROM movement m WHERE m.work_id = w.id)""",
        edition_id,
    )
    added = 0
    for work in works:
        movements = []
        for title in candidate_titles(work["title"], work["uniform_title"]):
            mbid = await find_work(title, work["composer"], fetcher)
            if mbid is None:
                continue
            movements = await movements_for(mbid, fetcher)
            if movements:
                break
        if not movements:
            continue

        conn.execute("UPDATE work SET mb_work_id = ? WHERE id = ?", (mbid, work["id"]))
        for movement in movements:
            conn.execute(
                """INSERT OR IGNORE INTO movement (work_id, ordinal, title)
                   VALUES (?, ?, ?)""",
                (work["id"], movement.ordinal, movement.label),
            )
            added += 1

    if added:
        db.index_edition(conn, edition_id)
    return added
