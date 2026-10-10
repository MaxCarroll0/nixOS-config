"""Who a catalogue number belongs to -- learned from records, not from a hardcoded list.

Every catalogue record that carries a publisher number also names its publisher, and
every ISMN contains a publisher element allocated to exactly one house. So the mapping
from ``HN`` to Henle, or from ``979-0-006`` to Bärenreiter, does not have to be written
down in advance: it can be read off the records as they arrive and accumulated.

That matters for more than tidiness. A hardcoded table only ever knows the publishers
somebody thought to list, and silently mislabels the rest. A learned one covers whatever
is actually in the collection, reports how confident it is, and gets better with use.
"""

from __future__ import annotations

import re
import sqlite3
from dataclasses import dataclass
from typing import Final

#: How an ISMN is laid out: 979-0, then a publisher element, then the item and a check
#: digit. The element has no fixed width, which is why the hyphenated form matters.
_HYPHENATED_ISMN: Final[re.Pattern[str]] = re.compile(
    r"^979[-\s]*0[-\s]*(?P<publisher>\d{3,7})[-\s]"
)

#: Sources disagree on a house's exact styling; compare on the stem.
_NOISE_WORDS: Final[frozenset[str]] = frozenset(
    {
        "verlag",
        "verlags",
        "edition",
        "editions",
        "editio",
        "musikverlag",
        "publishers",
        "publisher",
        "publishing",
        "music",
        "musik",
        "limited",
        "ltd",
        "gmbh",
        "co",
        "and",
        "inc",
        "press",
        "the",
    }
)


def ismn_publisher_element(ismn: str) -> str | None:
    """The publisher element of a hyphenated ISMN, which identifies the house.

    Only the hyphenated form can be split: the element runs from three to seven digits
    and nothing in the bare digit string says where it ends.
    """
    match = _HYPHENATED_ISMN.match(ismn.strip())
    return match.group("publisher") if match else None


def normalise_name(name: str) -> str:
    """A comparison key for a publisher name, so stylings collapse together.

    "Bärenreiter", "Bärenreiter-Verlag" and "Baerenreiter Verlag Kassel" are one house.
    """
    folded = name.lower().replace("ä", "ae").replace("ö", "oe").replace("ü", "ue")
    folded = folded.replace("ß", "ss").replace("&", " and ")
    words = [word for word in re.split(r"[^a-z0-9]+", folded) if word]
    kept = [word for word in words if word not in _NOISE_WORDS]
    return " ".join(kept or words)


@dataclass(frozen=True, slots=True)
class Attribution:
    """A publisher this key has been seen to belong to, and how often."""

    publisher: str
    seen: int
    #: Share of sightings of this key that named this publisher.
    confidence: float


def learn(
    conn: sqlite3.Connection,
    *,
    publisher: str | None,
    prefix: str | None = None,
    ismn: str | None = None,
) -> None:
    """Record that a prefix or an ISMN element was seen alongside a publisher."""
    if not publisher:
        return
    stem = normalise_name(publisher)
    if not stem:
        return

    keys: list[tuple[str, str]] = []
    if prefix:
        keys.append(("catnum", prefix.upper()))
    if ismn:
        element = ismn_publisher_element(ismn)
        if element:
            keys.append(("ismn", element))

    for kind, key in keys:
        conn.execute(
            """INSERT INTO publisher_key (kind, key, stem, publisher, seen)
               VALUES (?, ?, ?, ?, 1)
               ON CONFLICT (kind, key, stem) DO UPDATE SET
                 seen = publisher_key.seen + 1,
                 publisher = excluded.publisher""",
            (kind, key, stem, publisher.strip()),
        )


def attribute(conn: sqlite3.Connection, kind: str, key: str) -> Attribution | None:
    """The publisher a key most often belongs to, with how sure that is."""
    rows = conn.execute(
        "SELECT publisher, seen FROM publisher_key WHERE kind = ? AND key = ? ORDER BY seen DESC",
        (kind, key.upper()),
    ).fetchall()
    if not rows:
        return None
    total = sum(int(row["seen"]) for row in rows)
    best = rows[0]
    return Attribution(
        publisher=str(best["publisher"]),
        seen=int(best["seen"]),
        confidence=int(best["seen"]) / total if total else 0.0,
    )


def for_number(conn: sqlite3.Connection, prefix: str) -> Attribution | None:
    """Which house a catalogue-number prefix belongs to, if it has been seen before."""
    if not prefix:
        return None
    return attribute(conn, "catnum", re.sub(r"[^A-Z0-9]", "", prefix.upper()))


def for_ismn(conn: sqlite3.Connection, ismn: str) -> Attribution | None:
    """Which house an ISMN belongs to, from its publisher element."""
    element = ismn_publisher_element(ismn)
    return attribute(conn, "ismn", element) if element else None


def prefixes_for(conn: sqlite3.Connection, publisher: str, limit: int = 4) -> tuple[str, ...]:
    """Prefixes this house has been seen to use, most common first.

    This is what lets a bare number typed as ``boosey 16902`` also be looked for as
    ``BB 16902``, without anyone having written down that Boosey uses ``BB``.
    """
    stem = normalise_name(publisher)
    if not stem:
        return ()
    rows = conn.execute(
        """SELECT key FROM publisher_key
           WHERE kind = 'catnum' AND stem = ?
           ORDER BY seen DESC LIMIT ?""",
        (stem, limit),
    ).fetchall()
    return tuple(str(row["key"]) for row in rows)


def matching_names(conn: sqlite3.Connection, words: str) -> list[str]:
    """Publisher names a typed qualifier might mean, best first.

    ``durand`` should find "Durand", and ``boosey`` should find "Boosey & Hawkes",
    without either being listed anywhere: both have been seen on records already.
    """
    stem = normalise_name(words)
    if not stem:
        return []
    rows = conn.execute(
        """SELECT publisher, SUM(seen) AS seen FROM publisher_key
           WHERE stem = ? OR stem LIKE ? OR ? LIKE stem || '%'
           GROUP BY publisher ORDER BY seen DESC LIMIT 5""",
        (stem, f"{stem}%", stem),
    ).fetchall()
    return [str(row["publisher"]) for row in rows]


def seed_from_candidates(conn: sqlite3.Connection, candidates: list[object]) -> None:
    """Learn from a batch of resolver results, which is where the mapping comes from."""
    for candidate in candidates:
        publisher = getattr(candidate, "publisher", None)
        if not publisher:
            continue
        raw_number = getattr(candidate, "cat_no", None)
        prefix = None
        if raw_number:
            from bookshelf import catnum

            parsed = catnum.parse(str(raw_number))
            if parsed is not None and parsed.prefix:
                prefix = parsed.prefix
        learn(
            conn,
            publisher=str(publisher),
            prefix=prefix,
            ismn=getattr(candidate, "ismn_hyphenated", None)
            or getattr(candidate, "ismn", None),
        )
