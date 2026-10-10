"""SQLite access: schema application, row helpers, and the search index."""

from __future__ import annotations

import sqlite3
from collections.abc import Iterator
from contextlib import contextmanager
import unicodedata
from importlib import resources
from pathlib import Path
from typing import Any


def _schema() -> str:
    return resources.files("bookshelf").joinpath("schema.sql").read_text(encoding="utf-8")


def fold(text: str) -> str:
    """Lower-case and strip accents, so "Dvorak" reaches "Dvořák"."""
    decomposed = unicodedata.normalize("NFD", text.lower())
    return "".join(ch for ch in decomposed if not unicodedata.combining(ch))


def searchable(*parts: str | None) -> str:
    """Index both the text as written and a folded copy of it.

    The folded copy is what makes an accent-free search work, and keeping it in the same
    column means a substring scan -- which is how a German compound like
    "Blaeserserenade" is found from "serenade" -- has one place to look.
    """
    original = " ".join(part for part in parts if part)
    folded = fold(original)
    return original if folded == original.lower() else f"{original} {folded}"


def connect(database: str) -> sqlite3.Connection:
    """Open the catalogue, creating and migrating it if need be."""
    path = Path(database)
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(database, timeout=15.0, isolation_level=None)
    conn.row_factory = sqlite3.Row
    conn.executescript(_schema())
    return conn


@contextmanager
def transaction(conn: sqlite3.Connection) -> Iterator[sqlite3.Connection]:
    """A write transaction that rolls back on error; isolation_level is None."""
    conn.execute("BEGIN IMMEDIATE")
    try:
        yield conn
    except BaseException:
        conn.execute("ROLLBACK")
        raise
    conn.execute("COMMIT")


def one(conn: sqlite3.Connection, sql: str, *args: Any) -> sqlite3.Row | None:
    row: sqlite3.Row | None = conn.execute(sql, args).fetchone()
    return row


def all_rows(conn: sqlite3.Connection, sql: str, *args: Any) -> list[sqlite3.Row]:
    return conn.execute(sql, args).fetchall()


def scalar(conn: sqlite3.Connection, sql: str, *args: Any) -> Any:
    row = conn.execute(sql, args).fetchone()
    return None if row is None else row[0]


def insert(conn: sqlite3.Connection, table: str, **values: Any) -> int:
    columns = ", ".join(values)
    marks = ", ".join("?" for _ in values)
    cursor = conn.execute(
        f"INSERT INTO {table} ({columns}) VALUES ({marks})", tuple(values.values())
    )
    return int(cursor.lastrowid or 0)


def upsert_person(conn: sqlite3.Connection, name: str, gnd_id: str | None = None) -> int:
    """Find or create a person, preferring the GND id as identity when there is one."""
    if gnd_id:
        found = scalar(conn, "SELECT id FROM person WHERE gnd_id = ?", gnd_id)
        if found is not None:
            return int(found)
    found = scalar(conn, "SELECT id FROM person WHERE name = ? AND gnd_id IS NULL", name)
    if found is not None:
        if gnd_id:
            conn.execute("UPDATE person SET gnd_id = ? WHERE id = ?", (gnd_id, found))
        return int(found)
    return insert(conn, "person", name=name, gnd_id=gnd_id)


def reindex(conn: sqlite3.Connection) -> int:
    """Rebuild the whole search index from the catalogue tables.

    The index is derived, so it is left out of backups; restoring a dump therefore
    needs this to make the restored catalogue searchable again.
    """
    conn.execute("DELETE FROM search")
    editions = [int(row["id"]) for row in all_rows(conn, "SELECT id FROM edition")]
    for edition_id in editions:
        index_edition(conn, edition_id)
    return len(editions)


def index_edition(conn: sqlite3.Connection, edition_id: int) -> None:
    """Rebuild the FTS rows for one edition, its works and their movements.

    Searching a single movement title has to find the volume it is bound in, so the
    movement rows carry the edition id too.
    """
    conn.execute("DELETE FROM search WHERE edition_id = ?", (edition_id,))
    edition = one(
        conn,
        """SELECT e.*, p.name AS composer,
                  (SELECT GROUP_CONCAT(w.uniform_title, ' ')
                     FROM edition_content ec JOIN work w ON w.id = ec.work_id
                     WHERE ec.edition_id = e.id) AS uniform_titles
           FROM edition e LEFT JOIN person p ON p.id = e.person_id
           WHERE e.id = ?""",
        edition_id,
    )
    if edition is None:
        return

    parts = [
        edition["title"],
        edition["title_en"],
        edition["composer"],
        edition["publisher"],
        edition["cat_no_raw"],
        edition["cat_no_norm"],
        edition["ismn"],
        edition["isbn13"],
        edition["series"],
        edition["uniform_title"],
        edition["catalogue_label"],
        edition["instrumentation"],
        edition["uniform_titles"],
    ]
    conn.execute(
        "INSERT INTO search (kind, ref_id, edition_id, text) VALUES ('edition', ?, ?, ?)",
        (edition_id, edition_id, searchable(*parts)),
    )

    contents = all_rows(
        conn,
        """SELECT c.label, c.work_id, w.title AS work_title, w.catalogue_label, w.uniform_title
           FROM edition_content c LEFT JOIN work w ON w.id = c.work_id
           WHERE c.edition_id = ?""",
        edition_id,
    )
    for item in contents:
        text = searchable(
            item["label"],
            item["work_title"],
            item["uniform_title"],
            item["catalogue_label"],
        )
        conn.execute(
            "INSERT INTO search (kind, ref_id, edition_id, text) VALUES ('work', ?, ?, ?)",
            (item["work_id"], edition_id, text),
        )
        if item["work_id"] is None:
            continue
        for movement in all_rows(
            conn, "SELECT title, tempo FROM movement WHERE work_id = ?", item["work_id"]
        ):
            conn.execute(
                "INSERT INTO search (kind, ref_id, edition_id, text) VALUES ('movement', ?, ?, ?)",
                (item["work_id"], edition_id, searchable(movement["title"], movement["tempo"])),
            )
