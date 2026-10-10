"""Saving, searching, removing, and the restore path a backup depends on."""

from __future__ import annotations

import sqlite3
from pathlib import Path

import pytest

from bookshelf import db, store
from bookshelf.models import Candidate, Condition, ContentItem, CoverType, Kind
from bookshelf.resolvers.dnb import _records, to_candidates

FIXTURES = Path(__file__).parent / "fixtures"


@pytest.fixture
def conn(tmp_path: Path) -> sqlite3.Connection:
    return db.connect(str(tmp_path / "test.db"))


def henle() -> Candidate:
    xml = (FIXTURES / "dnb-hn1234.xml").read_text(encoding="utf-8")
    return next(c for record in _records(xml) for c in to_candidates(record, "dnb"))


def test_saving_keeps_the_work_identity(conn: sqlite3.Connection) -> None:
    """The thematic number, key and scoring are the most useful facts on the record."""
    edition_id = store.save_candidate(conn, henle())
    row = db.one(conn, "SELECT * FROM edition WHERE id = ?", edition_id)
    assert row is not None
    assert row["uniform_title"] == "Serenaden"
    assert row["catalogue_label"] == "B 77"
    assert row["music_key"] == "d-Moll"
    assert "Kontrafagott" in row["instrumentation"]
    assert row["gnd_work_id"] == "300048017"


def test_saving_twice_does_not_duplicate_the_edition(conn: sqlite3.Connection) -> None:
    first = store.save_candidate(conn, henle())
    second = store.save_candidate(conn, henle())
    assert first == second
    assert db.scalar(conn, "SELECT COUNT(*) FROM edition") == 1


def test_a_thinner_source_does_not_erase_what_is_known(conn: sqlite3.Connection) -> None:
    edition_id = store.save_candidate(conn, henle())
    store.save_candidate(
        conn,
        Candidate(source="henle", title="Wind Serenade", cat_no_norm="HN1234", price_new=51.0),
    )
    row = db.one(conn, "SELECT * FROM edition WHERE id = ?", edition_id)
    assert row is not None
    assert row["music_key"] == "d-Moll", "a source with no key must not clear the key"
    assert db.scalar(conn, "SELECT COUNT(*) FROM price_new WHERE edition_id = ?", edition_id) == 1


@pytest.mark.parametrize(
    "query", ["serenade", "Serenaden", "dvorak", "Dvořák", "henle", "B 77", "Kontrafagott"]
)
def test_search_finds_an_edition_many_ways(conn: sqlite3.Connection, query: str) -> None:
    """Substring, accent-free, thematic number and scoring all have to work."""
    edition_id = store.save_candidate(conn, henle())
    store.add_copy(
        conn, edition_id=edition_id, cover_type=CoverType.CLOTH, condition=Condition.GOOD
    )
    assert [row["id"] for row in store.search(conn, query)] == [edition_id]


def test_search_reaches_a_movement_inside_a_volume(conn: sqlite3.Connection) -> None:
    """Finding one piece has to turn up the volume it is bound in."""
    edition_id = store.save_candidate(
        conn,
        Candidate(
            source="dnb",
            title="Klavierstücke",
            composer="Brahms, Johannes",
            cat_no_norm="HN9999",
            contents=[
                ContentItem(ordinal=1, label="Scherzo, opus 4", work_title="Scherzi, Kl, op. 4"),
                ContentItem(ordinal=2, label="Vier Balladen, opus 10"),
            ],
        ),
    )
    assert [row["id"] for row in store.search(conn, "Balladen")] == [edition_id]
    assert store.search(conn, "Scherzi")[0]["matched_on"] in {"work", "edition"}


def test_removing_a_copy_takes_the_edition_when_it_was_the_last(
    conn: sqlite3.Connection,
) -> None:
    edition_id = store.save_candidate(conn, henle())
    copy_id = store.add_copy(
        conn, edition_id=edition_id, cover_type=CoverType.SOFT, condition=Condition.GOOD
    )
    assert store.delete_copy(conn, copy_id) is None
    assert db.scalar(conn, "SELECT COUNT(*) FROM edition") == 0
    assert db.scalar(conn, "SELECT COUNT(*) FROM search") == 0


def test_removing_one_of_two_copies_keeps_the_edition(conn: sqlite3.Connection) -> None:
    edition_id = store.save_candidate(conn, henle())
    first = store.add_copy(
        conn, edition_id=edition_id, cover_type=CoverType.SOFT, condition=Condition.GOOD
    )
    store.add_copy(
        conn, edition_id=edition_id, cover_type=CoverType.CLOTH, condition=Condition.POOR
    )
    assert store.delete_copy(conn, first) == edition_id
    assert db.scalar(conn, "SELECT COUNT(*) FROM copy") == 1


def test_removal_is_described_before_it_happens(conn: sqlite3.Connection) -> None:
    edition_id = store.save_candidate(conn, henle())
    store.add_copy(
        conn, edition_id=edition_id, cover_type=CoverType.SOFT, condition=Condition.GOOD
    )
    described = store.describe_edition_removal(conn, edition_id)
    assert described is not None
    assert described.copies == 1
    assert "Dvořák" in described.label


def test_deleting_an_edition_leaves_learned_attributions_alone(
    conn: sqlite3.Connection,
) -> None:
    """What the catalogue learned about publishers is not about any one item."""
    from bookshelf import publishers

    edition_id = store.save_candidate(conn, henle())
    publishers.seed_from_candidates(conn, [henle()])
    before = db.scalar(conn, "SELECT COUNT(*) FROM publisher_key")

    store.delete_edition(conn, edition_id)
    assert db.scalar(conn, "SELECT COUNT(*) FROM publisher_key") == before


def test_the_index_can_be_rebuilt_from_the_tables(conn: sqlite3.Connection) -> None:
    """Backups leave the index out, so a restore has to be able to recreate it."""
    edition_id = store.save_candidate(conn, henle())
    store.add_copy(
        conn, edition_id=edition_id, cover_type=CoverType.SOFT, condition=Condition.GOOD
    )
    conn.execute("DELETE FROM search")
    assert store.search(conn, "dvorak") == []

    assert db.reindex(conn) == 1
    assert [row["id"] for row in store.search(conn, "dvorak")] == [edition_id]


def test_manual_entry_is_accepted_without_any_source(conn: sqlite3.Connection) -> None:
    edition_id = store.save_manual(
        conn,
        title="A privately bound volume",
        composer=None,
        publisher="Unknown",
        cat_no=None,
        kind=Kind.SCORE,
    )
    row = db.one(conn, "SELECT resolved_from, title FROM edition WHERE id = ?", edition_id)
    assert row is not None
    assert row["resolved_from"] == "manual"
