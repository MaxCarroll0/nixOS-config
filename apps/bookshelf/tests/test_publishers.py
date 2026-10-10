"""Attribution is learned from records rather than hardcoded, so test that it learns."""

from __future__ import annotations

import sqlite3
from pathlib import Path

import pytest

from bookshelf import db, publishers
from bookshelf.resolvers.dnb import _records, to_candidates

FIXTURES = Path(__file__).parent / "fixtures"


@pytest.fixture
def conn(tmp_path: Path) -> sqlite3.Connection:
    return db.connect(str(tmp_path / "test.db"))


@pytest.mark.parametrize(
    ("ismn", "element"),
    [
        ("979-0-2018-1234-2", "2018"),
        ("979-0-006-57967-9", "006"),
        ("979-0-004-18958-0", "004"),
        ("979-0-0065-7993-8", "0065"),
        ("9790201812342", None),
    ],
)
def test_ismn_publisher_element(ismn: str, element: str | None) -> None:
    """The publisher element identifies the house, but only the hyphenated form splits."""
    assert publishers.ismn_publisher_element(ismn) == element


@pytest.mark.parametrize(
    ("name", "stem"),
    [
        ("Bärenreiter", "baerenreiter"),
        ("Bärenreiter-Verlag", "baerenreiter"),
        ("Baerenreiter Verlag Kassel", "baerenreiter kassel"),
        ("G. Henle Verlag", "g henle"),
        ("Breitkopf & Härtel", "breitkopf haertel"),
        ("Edition Peters", "peters"),
    ],
)
def test_names_collapse_to_a_comparable_stem(name: str, stem: str) -> None:
    assert publishers.normalise_name(name) == stem


def test_learns_a_prefix_from_a_real_record(conn: sqlite3.Connection) -> None:
    """Nothing knows that HN means Henle until a record says so."""
    assert publishers.for_number(conn, "HN") is None

    xml = (FIXTURES / "dnb-hn1234.xml").read_text(encoding="utf-8")
    found = [c for record in _records(xml) for c in to_candidates(record, "dnb")]
    publishers.seed_from_candidates(conn, list(found))

    attribution = publishers.for_number(conn, "HN")
    assert attribution is not None
    assert attribution.publisher == "G. Henle Verlag"
    assert attribution.confidence == 1.0


def test_learns_the_ismn_element_too(conn: sqlite3.Connection) -> None:
    xml = (FIXTURES / "dnb-hn1234.xml").read_text(encoding="utf-8")
    found = [c for record in _records(xml) for c in to_candidates(record, "dnb")]
    publishers.seed_from_candidates(conn, list(found))

    attribution = publishers.for_ismn(conn, "979-0-2018-9999-1")
    assert attribution is not None
    assert attribution.publisher == "G. Henle Verlag"


def test_learns_across_several_publishers(conn: sqlite3.Connection) -> None:
    for name in ("dnb-hn1234.xml", "dnb-ep20024.xml", "dnb-eb9478.xml", "dnb-or-variants.xml"):
        xml = (FIXTURES / name).read_text(encoding="utf-8")
        found = [c for record in _records(xml) for c in to_candidates(record, "dnb")]
        publishers.seed_from_candidates(conn, list(found))

    assert (a := publishers.for_number(conn, "HN")) and a.publisher == "G. Henle Verlag"
    assert (a := publishers.for_number(conn, "EP")) and "Peters" in a.publisher
    assert (a := publishers.for_number(conn, "EB")) and "Breitkopf" in a.publisher
    assert (a := publishers.for_number(conn, "BA")) and "renreiter" in a.publisher


def test_a_name_finds_the_prefixes_that_house_uses(conn: sqlite3.Connection) -> None:
    """This is what lets a bare number typed with a name be looked up by prefix."""
    publishers.learn(conn, publisher="Boosey & Hawkes", prefix="BB")
    publishers.learn(conn, publisher="Boosey & Hawkes", prefix="BB")
    publishers.learn(conn, publisher="Boosey and Hawkes Ltd", prefix="HPS")

    assert publishers.prefixes_for(conn, "Boosey & Hawkes") == ("BB", "HPS")
    assert "Boosey & Hawkes" in publishers.matching_names(conn, "boosey")


def test_confidence_reports_disagreement(conn: sqlite3.Connection) -> None:
    """A prefix two houses both use should not be reported as if it were certain."""
    for _ in range(3):
        publishers.learn(conn, publisher="One Press", prefix="XX")
    publishers.learn(conn, publisher="Another Press", prefix="XX")

    attribution = publishers.for_number(conn, "XX")
    assert attribution is not None
    assert attribution.publisher == "One Press"
    assert attribution.confidence == pytest.approx(0.75)


def test_an_unknown_prefix_is_simply_unknown(conn: sqlite3.Connection) -> None:
    assert publishers.for_number(conn, "ZZZ") is None
    assert publishers.prefixes_for(conn, "Nobody") == ()
    assert publishers.matching_names(conn, "nobody") == []
