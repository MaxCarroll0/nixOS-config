"""A read-only SQL console, for the questions the browse pages do not anticipate.

Read-only here is enforced three ways rather than promised once: the connection is
opened with SQLite's own ``mode=ro`` so the driver refuses writes outright; the
statement is checked to be a single query of an allowed kind before it is run; and a
progress handler aborts anything that runs too long, so a careless cross join cannot
tie up the one worker this service has.
"""

from __future__ import annotations

import csv
import io
import re
import sqlite3
import time
from dataclasses import dataclass, field
from typing import Any, Final

#: Statements worth allowing. Everything else -- including PRAGMA and ATTACH, which can
#: reach outside this database -- is refused.
_ALLOWED_START: Final[re.Pattern[str]] = re.compile(r"^\s*(?:select|with)\b", re.IGNORECASE)

#: Keywords that have no business in a read-only query even inside a CTE.
_FORBIDDEN: Final[re.Pattern[str]] = re.compile(
    r"\b(?:attach|detach|pragma|vacuum|insert|update|delete|replace|drop|alter|create"
    r"|reindex|analyze|begin|commit|rollback|savepoint)\b",
    re.IGNORECASE,
)

#: Functions that can read or write the filesystem.
_FORBIDDEN_FUNCTIONS: Final[re.Pattern[str]] = re.compile(
    r"\b(?:readfile|writefile|edit|fsdir|load_extension)\s*\(", re.IGNORECASE
)

MAX_ROWS: Final = 2000
TIMEOUT_SECONDS: Final = 5.0

#: Tables whose contents are machinery rather than catalogue, hidden from the schema
#: listing to keep it readable. They remain queryable.
_NOISE_TABLES: Final[frozenset[str]] = frozenset({"http_cache", "search_data", "search_idx"})


class QueryRefused(Exception):
    """The statement is not something this console will run."""


@dataclass
class Result:
    columns: list[str] = field(default_factory=list)
    rows: list[tuple[Any, ...]] = field(default_factory=list)
    elapsed_ms: int = 0
    truncated: bool = False

    def to_csv(self) -> str:
        buffer = io.StringIO()
        writer = csv.writer(buffer)
        writer.writerow(self.columns)
        writer.writerows(self.rows)
        return buffer.getvalue()


def check(sql: str) -> str:
    """Return the statement to run, or raise QueryRefused explaining why not."""
    statement = sql.strip().rstrip(";").strip()
    if not statement:
        raise QueryRefused("nothing to run")

    # One statement only: a trailing semicolon is fine, a second statement is not.
    if ";" in statement:
        raise QueryRefused("one statement at a time")
    if not _ALLOWED_START.match(statement):
        raise QueryRefused("only SELECT and WITH queries are allowed")

    stripped = _strip_literals(statement)
    found = _FORBIDDEN.search(stripped)
    if found:
        raise QueryRefused(f"{found.group(0).upper()} is not allowed here")
    if _FORBIDDEN_FUNCTIONS.search(stripped):
        raise QueryRefused("filesystem functions are not allowed")
    return statement


def _strip_literals(sql: str) -> str:
    """Blank out string literals and comments, so keywords inside them do not count."""
    without_comments = re.sub(r"--[^\n]*", " ", sql)
    without_comments = re.sub(r"/\*.*?\*/", " ", without_comments, flags=re.DOTALL)
    return re.sub(r"'(?:[^']|'')*'", "''", without_comments)


def connect_readonly(database: str) -> sqlite3.Connection:
    """Open the catalogue in a mode the driver itself will not let us write through."""
    conn = sqlite3.connect(f"file:{database}?mode=ro", uri=True, timeout=5.0)
    conn.row_factory = sqlite3.Row
    return conn


def run(conn: sqlite3.Connection, sql: str, *, limit: int = MAX_ROWS) -> Result:
    """Run a checked query under a wall-clock cap."""
    statement = check(sql)
    deadline = time.monotonic() + TIMEOUT_SECONDS

    def abort_if_slow() -> int:
        return 1 if time.monotonic() > deadline else 0

    started = time.monotonic()
    conn.set_progress_handler(abort_if_slow, 10_000)
    try:
        cursor = conn.execute(statement)
        rows = cursor.fetchmany(limit + 1)
        columns = [description[0] for description in (cursor.description or [])]
    except sqlite3.OperationalError as exc:
        message = str(exc)
        if "interrupted" in message:
            raise QueryRefused(f"query took longer than {TIMEOUT_SECONDS:g}s and was stopped")
        raise QueryRefused(message) from exc
    except sqlite3.Error as exc:
        raise QueryRefused(str(exc)) from exc
    finally:
        conn.set_progress_handler(None, 0)

    truncated = len(rows) > limit
    return Result(
        columns=columns,
        rows=[tuple(row) for row in rows[:limit]],
        elapsed_ms=int((time.monotonic() - started) * 1000),
        truncated=truncated,
    )


def schema(conn: sqlite3.Connection) -> list[dict[str, Any]]:
    """Tables, their columns and their row counts, as a reference beside the editor."""
    tables = conn.execute(
        """SELECT name, type FROM sqlite_master
           WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%'
           ORDER BY type, name"""
    ).fetchall()

    out: list[dict[str, Any]] = []
    for table in tables:
        name = str(table["name"])
        if name in _NOISE_TABLES or name.startswith("search_"):
            continue
        columns = conn.execute(f'PRAGMA table_info("{name}")').fetchall()
        try:
            count = conn.execute(f'SELECT COUNT(*) FROM "{name}"').fetchone()[0]
        except sqlite3.Error:
            count = None
        out.append(
            {
                "name": name,
                "kind": str(table["type"]),
                "rows": count,
                "columns": [
                    {"name": str(column["name"]), "type": str(column["type"])}
                    for column in columns
                ],
            }
        )
    return out


#: Starting points, which double as documentation of how the tables fit together.
EXAMPLES: Final[tuple[tuple[str, str], ...]] = (
    (
        "Everything owned, with its latest valuation",
        """SELECT p.name AS composer, e.title, e.publisher, e.cat_no_raw,
       c.cover_type, c.condition, c.price_paid,
       v.market_value, v.method, v.n_comps
FROM copy c
JOIN edition e ON e.id = c.edition_id
LEFT JOIN person p ON p.id = e.person_id
LEFT JOIN valuation v ON v.id = (
  SELECT id FROM valuation WHERE copy_id = c.id ORDER BY as_of DESC LIMIT 1
)
ORDER BY p.name, e.title""",
    ),
    (
        "What each publisher is worth, and how well evidenced it is",
        """SELECT e.publisher,
       COUNT(*) AS copies,
       ROUND(SUM(v.market_value), 2) AS market,
       ROUND(SUM(c.price_paid), 2) AS paid,
       SUM(v.method = 'comps') AS from_listings,
       SUM(v.method = 'modelled') AS modelled
FROM copy c
JOIN edition e ON e.id = c.edition_id
LEFT JOIN valuation v ON v.id = (
  SELECT id FROM valuation WHERE copy_id = c.id ORDER BY as_of DESC LIMIT 1
)
GROUP BY e.publisher
ORDER BY market DESC""",
    ),
    (
        "Which pieces appear in more than one volume",
        """SELECT w.title, COUNT(DISTINCT ec.edition_id) AS volumes,
       GROUP_CONCAT(e.cat_no_raw, ', ') AS editions
FROM edition_content ec
JOIN work w ON w.id = ec.work_id
JOIN edition e ON e.id = ec.edition_id
GROUP BY w.id
HAVING volumes > 1
ORDER BY volumes DESC""",
    ),
    (
        "Items whose value rests on nothing but the model",
        """SELECT p.name AS composer, e.title, e.publisher,
       v.market_value, v.market_lo, v.market_hi
FROM copy c
JOIN edition e ON e.id = c.edition_id
LEFT JOIN person p ON p.id = e.person_id
JOIN valuation v ON v.id = (
  SELECT id FROM valuation WHERE copy_id = c.id ORDER BY as_of DESC LIMIT 1
)
WHERE v.method = 'modelled'
ORDER BY v.market_value DESC""",
    ),
    (
        "Catalogue-number prefixes learned so far",
        """SELECT kind, key, publisher, seen
FROM publisher_key
ORDER BY kind, seen DESC""",
    ),
)
