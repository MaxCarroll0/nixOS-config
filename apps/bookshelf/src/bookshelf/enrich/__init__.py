"""Filling in works and movements, so a volume's contents can be browsed offline."""

from __future__ import annotations

import sqlite3
from typing import TYPE_CHECKING

from bookshelf.enrich.musicbrainz import find_work, movements_for
from bookshelf.enrich.openopus import works_for

if TYPE_CHECKING:
    from bookshelf.fetch import Fetcher

__all__ = ["enrich_edition", "find_work", "movements_for", "works_for"]


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
        title = work["uniform_title"] or work["title"]
        if not title:
            continue
        mbid = await find_work(title, work["composer"], fetcher)
        if mbid is None:
            continue
        movements = await movements_for(mbid, fetcher)
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
