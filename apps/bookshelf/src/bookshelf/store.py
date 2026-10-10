"""Writing candidates and copies into the catalogue, and reading it back for the UI."""

from __future__ import annotations

import sqlite3
from dataclasses import dataclass
from datetime import date
from typing import Any

from bookshelf import db
from bookshelf.models import (
    Candidate,
    Condition,
    ContentItem,
    CoverType,
    Estimate,
    Kind,
    Method,
    cover_from_binding,
)


def save_candidate(conn: sqlite3.Connection, candidate: Candidate) -> int:
    """Insert or update the edition a candidate describes, returning its id.

    Identity is the ISMN, then the ISBN, then the catalogue number: the cloth and
    paperbound issues of one work have different ISMNs and so stay separate rows, which
    is the whole point of offering them as separate choices.
    """
    existing: int | None = None
    for column, value in (
        ("ismn", candidate.ismn),
        ("isbn13", candidate.isbn13),
        ("cat_no_norm", candidate.cat_no_norm),
    ):
        if not value:
            continue
        found = db.scalar(conn, f"SELECT id FROM edition WHERE {column} = ?", value)
        if found is not None:
            existing = int(found)
            break

    person_id = (
        db.upsert_person(conn, candidate.composer, candidate.composer_gnd)
        if candidate.composer
        else None
    )

    fields: dict[str, Any] = {
        "publisher": candidate.publisher,
        "cat_no_raw": candidate.cat_no,
        "cat_no_norm": candidate.cat_no_norm,
        "ismn": candidate.ismn,
        "isbn13": candidate.isbn13,
        "title": candidate.title,
        "title_en": candidate.title_en,
        "edition_statement": candidate.edition_statement,
        "series": candidate.series,
        "year": candidate.year,
        "pages": candidate.pages,
        "extent": candidate.extent,
        "binding": candidate.binding,
        "person_id": person_id,
        "uniform_title": candidate.uniform_title,
        "catalogue_label": candidate.catalogue_label,
        "music_key": candidate.music_key,
        "instrumentation": candidate.instrumentation,
        "gnd_work_id": candidate.gnd_work_id,
        "description": candidate.description,
        "subjects": ", ".join(candidate.subjects) or None,
        "kind": candidate.kind.value,
        "resolved_from": candidate.source,
        "source_ref": candidate.source_ref,
    }

    if existing is None:
        edition_id = db.insert(conn, "edition", **fields)
    else:
        edition_id = existing
        # Never overwrite something known with a None from a thinner source.
        present = {key: value for key, value in fields.items() if value is not None}
        if present:
            assignments = ", ".join(f"{key} = ?" for key in present)
            conn.execute(
                f"UPDATE edition SET {assignments} WHERE id = ?",
                (*present.values(), edition_id),
            )

    if candidate.price_new is not None:
        conn.execute(
            """INSERT INTO price_new (edition_id, price, currency, source, url)
               VALUES (?, ?, ?, ?, ?)""",
            (
                edition_id,
                candidate.price_new,
                candidate.price_currency or "EUR",
                candidate.source,
                candidate.url,
            ),
        )

    _save_contents(conn, edition_id, candidate)
    db.index_edition(conn, edition_id)
    return edition_id


def _save_contents(conn: sqlite3.Connection, edition_id: int, candidate: Candidate) -> None:
    """Record what is inside an edition, as one work per piece.

    An edition of a single work gets one entry rather than none, so that every edition
    has a work to hang movements off and the two cases -- an anthology and a single
    sonata -- are stored the same way.
    """
    contents = candidate.contents
    if not contents and (candidate.uniform_title or candidate.title):
        contents = [
            ContentItem(
                ordinal=1,
                label=candidate.title,
                work_title=candidate.uniform_title or candidate.title,
            )
        ]
    if not contents:
        return

    already = db.scalar(
        conn, "SELECT COUNT(*) FROM edition_content WHERE edition_id = ?", edition_id
    )
    if already:
        return

    person_id = db.scalar(conn, "SELECT person_id FROM edition WHERE id = ?", edition_id)
    for item in contents:
        title = item.work_title or item.label
        work_id = db.scalar(
            conn,
            "SELECT id FROM work WHERE title = ? AND IFNULL(person_id, -1) = IFNULL(?, -1)",
            title,
            person_id,
        )
        if work_id is None:
            work_id = db.insert(
                conn,
                "work",
                person_id=person_id,
                title=title,
                uniform_title=item.work_title,
                catalogue_label=candidate.catalogue_label if item.ordinal == 1 else None,
                music_key=candidate.music_key if item.ordinal == 1 else None,
                mb_work_id=None,
            )
        db.insert(
            conn,
            "edition_content",
            edition_id=edition_id,
            work_id=work_id,
            ordinal=item.ordinal,
            label=item.label,
            page_from=item.page_from,
        )


def add_copy(
    conn: sqlite3.Connection,
    *,
    edition_id: int,
    cover_type: CoverType,
    condition: Condition,
    acquired_on: str | None = None,
    price_paid: float | None = None,
    currency: str = "GBP",
    shelf: str | None = None,
    notes: str | None = None,
) -> int:
    return db.insert(
        conn,
        "copy",
        edition_id=edition_id,
        cover_type=cover_type.value,
        condition=condition.value,
        acquired_on=acquired_on,
        price_paid=price_paid,
        currency=currency,
        shelf=shelf,
        notes=notes,
    )


def save_manual(
    conn: sqlite3.Connection,
    *,
    title: str,
    composer: str | None,
    publisher: str | None,
    cat_no: str | None,
    kind: Kind,
) -> int:
    """An edition the sources could not identify, recorded from what was typed."""
    from bookshelf import catnum

    number = catnum.parse(cat_no) if cat_no else None
    return save_candidate(
        conn,
        Candidate(
            source="manual",
            title=title,
            composer=composer,
            publisher=publisher,
            cat_no=str(number) if number else cat_no,
            cat_no_norm=number.canonical if number else None,
            kind=kind,
            score=1.0,
        ),
    )


def latest_price_new(conn: sqlite3.Connection, edition_id: int) -> sqlite3.Row | None:
    return db.one(
        conn,
        """SELECT price, currency, source, observed_at FROM price_new
           WHERE edition_id = ? ORDER BY observed_at DESC, id DESC LIMIT 1""",
        edition_id,
    )


def record_valuation(
    conn: sqlite3.Connection,
    *,
    copy_id: int,
    cost_basis: float | None,
    cost_method: str | None,
    market: Estimate,
) -> None:
    db.insert(
        conn,
        "valuation",
        copy_id=copy_id,
        cost_basis=cost_basis,
        cost_method=cost_method,
        market_value=market.value,
        market_lo=market.lo,
        market_hi=market.hi,
        method=market.method.value,
        n_comps=market.n_comps,
        currency=market.currency,
    )


def set_manual_value(
    conn: sqlite3.Connection, *, copy_id: int, value: float, currency: str = "GBP"
) -> None:
    """An explicit override, which outranks anything the model or the comps say."""
    record_valuation(
        conn,
        copy_id=copy_id,
        cost_basis=None,
        cost_method=None,
        market=Estimate(
            value=value,
            lo=value,
            hi=value,
            method=Method.MANUAL,
            n_comps=0,
            currency=currency,
            note="set by hand",
        ),
    )


#: Below this many words-index hits, fall back to a substring scan as well.
_SUBSTRING_FALLBACK_BELOW = 5

_SEARCH_SELECT = """
    SELECT e.id, e.title, e.title_en, e.publisher, e.cat_no_raw, e.binding,
           e.year, e.kind, p.name AS composer,
           (SELECT COUNT(*) FROM copy c WHERE c.edition_id = e.id) AS copies,
           MIN(s.kind) AS matched_on
    FROM search s
    JOIN edition e ON e.id = s.edition_id
    LEFT JOIN person p ON p.id = e.person_id
"""


def search(conn: sqlite3.Connection, query: str, limit: int = 60) -> list[sqlite3.Row]:
    """Search editions, their works and those works' movements.

    Two passes, because one is not enough. The full-text index handles whole words and
    prefixes and is accent-insensitive, so "dvorak" finds Dvořák. But a prefix query
    cannot find "serenade" inside "Bläserserenade", and German compounds are full of
    that, so a thin result set is topped up with a substring scan over the same rows.
    """
    cleaned = query.strip()
    if not cleaned:
        return []

    words = [word for word in cleaned.split() if word]
    # The table is aliased, so MATCH and bm25 must name the alias, not the table.
    terms = " ".join(f'"{word}"*' for word in words)

    found: list[sqlite3.Row] = []
    seen: set[int] = set()
    try:
        found = db.all_rows(
            conn,
            f"{_SEARCH_SELECT} WHERE s MATCH ? GROUP BY e.id ORDER BY bm25(s) LIMIT ?",
            terms,
            limit,
        )
    except sqlite3.OperationalError:
        # A query FTS5 cannot parse is not an error worth showing; the scan below will
        # still answer it.
        found = []
    seen = {int(row["id"]) for row in found}

    if len(found) < _SUBSTRING_FALLBACK_BELOW:
        patterns = [f"%{db.fold(word)}%" for word in words]
        clause = " AND ".join("s.text LIKE ?" for _ in patterns)
        extra = db.all_rows(
            conn,
            f"{_SEARCH_SELECT} WHERE {clause} GROUP BY e.id ORDER BY e.title LIMIT ?",
            *patterns,
            limit,
        )
        found = [*found, *(row for row in extra if int(row["id"]) not in seen)]

    return found[:limit]


def shelf_rows(conn: sqlite3.Connection) -> list[sqlite3.Row]:
    """Every copy owned, with its edition and most recent valuation."""
    return db.all_rows(
        conn,
        """
        SELECT c.id AS copy_id, c.cover_type, c.condition, c.price_paid, c.currency,
               c.acquired_on, c.shelf,
               e.id AS edition_id, e.title, e.publisher, e.cat_no_raw, e.kind,
               e.year, e.pages, e.binding,
               p.name AS composer,
               v.market_value, v.market_lo, v.market_hi, v.method, v.n_comps,
               v.cost_basis, v.cost_method
        FROM copy c
        JOIN edition e ON e.id = c.edition_id
        LEFT JOIN person p ON p.id = e.person_id
        LEFT JOIN valuation v ON v.id = (
          SELECT id FROM valuation WHERE copy_id = c.id ORDER BY as_of DESC, id DESC LIMIT 1
        )
        ORDER BY p.name IS NULL, p.name, e.title
        """,
    )


def edition_detail(conn: sqlite3.Connection, edition_id: int) -> dict[str, Any] | None:
    edition = db.one(
        conn,
        """SELECT e.*, p.name AS composer, p.gnd_id AS composer_gnd
           FROM edition e LEFT JOIN person p ON p.id = e.person_id
           WHERE e.id = ?""",
        edition_id,
    )
    if edition is None:
        return None

    return {
        "edition": edition,
        "contents": db.all_rows(
            conn,
            """SELECT c.ordinal, c.label, c.page_from, c.work_id, w.title AS work_title,
                      w.catalogue_label
               FROM edition_content c LEFT JOIN work w ON w.id = c.work_id
               WHERE c.edition_id = ? ORDER BY c.ordinal""",
            edition_id,
        ),
        "copies": db.all_rows(
            conn,
            """SELECT c.*, v.market_value, v.market_lo, v.market_hi, v.method, v.n_comps,
                      v.cost_basis, v.cost_method
               FROM copy c
               LEFT JOIN valuation v ON v.id = (
                 SELECT id FROM valuation WHERE copy_id = c.id
                 ORDER BY as_of DESC, id DESC LIMIT 1
               )
               WHERE c.edition_id = ? ORDER BY c.id""",
            edition_id,
        ),
        "comps": db.all_rows(
            conn,
            """SELECT source, price, shipping, currency, condition, url, observed_at
               FROM comp WHERE edition_id = ? ORDER BY observed_at DESC LIMIT 25""",
            edition_id,
        ),
        "price_new": latest_price_new(conn, edition_id),
    }


def categories(conn: sqlite3.Connection) -> list[sqlite3.Row]:
    """The browse tree: publishers and composers with how much sits under each."""
    return db.all_rows(
        conn,
        """
        SELECT 'publisher' AS facet, IFNULL(e.publisher, 'unknown') AS name,
               COUNT(DISTINCT c.id) AS copies
        FROM edition e JOIN copy c ON c.edition_id = e.id
        GROUP BY e.publisher
        UNION ALL
        SELECT 'composer', IFNULL(p.name, 'unknown'), COUNT(DISTINCT c.id)
        FROM edition e JOIN copy c ON c.edition_id = e.id
        LEFT JOIN person p ON p.id = e.person_id
        GROUP BY p.name
        UNION ALL
        SELECT 'kind', e.kind, COUNT(DISTINCT c.id)
        FROM edition e JOIN copy c ON c.edition_id = e.id
        GROUP BY e.kind
        ORDER BY facet, copies DESC
        """,
    )


def features_for(row: sqlite3.Row) -> Any:
    """Build the model's feature vector from a shelf row."""
    from bookshelf.valuation import Features, priors

    today = date.today().year
    return Features(
        condition=Condition(row["condition"]),
        cover_type=CoverType(row["cover_type"]),
        publisher=priors.publisher_key(row["publisher"]),
        kind=Kind(row["kind"] or Kind.SCORE.value),
        age_years=float(max(today - int(row["year"] or today), 0)),
        pages=int(row["pages"]) if row["pages"] else None,
    )


def cover_default(binding: str | None) -> CoverType:
    return cover_from_binding(binding) or CoverType.SOFT


@dataclass(frozen=True, slots=True)
class Removal:
    """What deleting something would take with it, so the reader can be told first."""

    kind: str
    label: str
    copies: int = 0
    contents: int = 0
    comps: int = 0
    valuations: int = 0


def describe_copy_removal(conn: sqlite3.Connection, copy_id: int) -> Removal | None:
    row = db.one(
        conn,
        """SELECT c.id, c.cover_type, c.condition, e.title, p.name AS composer,
                  (SELECT COUNT(*) FROM valuation v WHERE v.copy_id = c.id) AS valuations
           FROM copy c
           JOIN edition e ON e.id = c.edition_id
           LEFT JOIN person p ON p.id = e.person_id
           WHERE c.id = ?""",
        copy_id,
    )
    if row is None:
        return None
    label = " · ".join(
        part for part in (row["composer"], row["title"], row["cover_type"]) if part
    )
    return Removal(kind="copy", label=label, copies=1, valuations=int(row["valuations"]))


def describe_edition_removal(conn: sqlite3.Connection, edition_id: int) -> Removal | None:
    row = db.one(
        conn,
        """SELECT e.title, p.name AS composer,
                  (SELECT COUNT(*) FROM copy WHERE edition_id = e.id) AS copies,
                  (SELECT COUNT(*) FROM edition_content WHERE edition_id = e.id) AS contents,
                  (SELECT COUNT(*) FROM comp WHERE edition_id = e.id) AS comps
           FROM edition e LEFT JOIN person p ON p.id = e.person_id
           WHERE e.id = ?""",
        edition_id,
    )
    if row is None:
        return None
    return Removal(
        kind="edition",
        label=" · ".join(part for part in (row["composer"], row["title"]) if part),
        copies=int(row["copies"]),
        contents=int(row["contents"]),
        comps=int(row["comps"]),
    )


def delete_copy(conn: sqlite3.Connection, copy_id: int) -> int | None:
    """Remove one physical copy, leaving the edition and its contents in place.

    The edition goes too if that was the last copy of it: an edition nothing is owned
    of is a search result, not a catalogue entry.
    """
    edition_id = db.scalar(conn, "SELECT edition_id FROM copy WHERE id = ?", copy_id)
    if edition_id is None:
        return None

    conn.execute("DELETE FROM copy WHERE id = ?", (copy_id,))
    remaining = db.scalar(
        conn, "SELECT COUNT(*) FROM copy WHERE edition_id = ?", edition_id
    )
    if not remaining:
        delete_edition(conn, int(edition_id))
        return None
    return int(edition_id)


def delete_edition(conn: sqlite3.Connection, edition_id: int) -> None:
    """Remove an edition and everything hanging off it.

    Works and composers are deliberately left alone unless nothing references them any
    more: they are shared between editions, and losing a composer because one volume
    was deleted would be wrong.
    """
    conn.execute("DELETE FROM search WHERE edition_id = ?", (edition_id,))
    # The schema cascades copies, contents, comps and valuations from here.
    conn.execute("DELETE FROM edition WHERE id = ?", (edition_id,))
    _prune_orphans(conn)


def _prune_orphans(conn: sqlite3.Connection) -> None:
    conn.execute(
        """DELETE FROM work WHERE id NOT IN (
             SELECT work_id FROM edition_content WHERE work_id IS NOT NULL
           )"""
    )
    conn.execute(
        """DELETE FROM person WHERE id NOT IN (
             SELECT person_id FROM edition WHERE person_id IS NOT NULL
             UNION SELECT person_id FROM work WHERE person_id IS NOT NULL
           )"""
    )
