"""Parsing recorded MARC, so resolver behaviour is pinned without touching the network.

The fixtures are real SRU responses, captured from the live service for the catalogue
numbers the design was verified against.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from bookshelf.models import CoverType
from bookshelf.resolvers.dnb import _qualifier, _records, split_contents, to_candidates

FIXTURES = Path(__file__).parent / "fixtures"


def _candidates(name: str) -> list:
    xml = (FIXTURES / name).read_text(encoding="utf-8")
    return [c for record in _records(xml) for c in to_candidates(record, "dnb")]


def test_henle_number_resolves_to_the_work() -> None:
    found = _candidates("dnb-hn1234.xml")
    assert len(found) == 1
    candidate = found[0]
    assert candidate.composer == "Dvořák, Antonín"
    assert candidate.composer_gnd == "11852836X"
    assert candidate.cat_no_norm == "HN1234"
    assert candidate.ismn == "9790201812342"
    assert candidate.publisher == "G. Henle Verlag"
    assert candidate.music_key == "d-Moll"
    assert candidate.catalogue_label == "B 77"
    assert candidate.gnd_work_id == "300048017"
    assert "Oboe (2)" in (candidate.instrumentation or "")
    assert candidate.year == 2021


def test_binding_becomes_a_cover_type() -> None:
    candidate = _candidates("dnb-hn1234.xml")[0]
    assert candidate.binding == "Broschur"
    assert candidate.cover_guess is CoverType.SOFT


def test_one_record_with_two_bindings_offers_both() -> None:
    """The paperbound and the unbound issue are the choice the reader is making."""
    found = _candidates("dnb-or-variants.xml")
    bindings = {candidate.binding for candidate in found}
    assert bindings == {"Broschur", "keine Bindung"}
    assert all(candidate.cat_no_norm == "BA5583" for candidate in found)


@pytest.mark.parametrize(
    "name", ["dnb-ep20024.xml", "dnb-eb9478.xml", "dnb-ba4501.xml"]
)
def test_other_publishers_parse(name: str) -> None:
    found = _candidates(name)
    assert found
    assert all(candidate.title for candidate in found)
    assert all(candidate.cat_no_norm for candidate in found)


@pytest.mark.parametrize(
    ("qualifier", "binding", "price", "currency"),
    [
        ("Broschur", "Broschur", None, None),
        ("Gewebe", "Gewebe", None, None),
        ("Festeinband : EUR 220.00 (DE), EUR 226.20 (AT)", "Festeinband", 220.0, "EUR"),
        ("Leinen : EUR 89,00", "Leinen", 89.0, "EUR"),
        ("979-0-006-53071-7Broschur", "Broschur", None, None),
        ("BA 4501 : DM 65.00", None, 65.0, "DM"),
    ],
)
def test_qualifier_splits_into_binding_and_price(
    qualifier: str, binding: str | None, price: float | None, currency: str | None
) -> None:
    assert _qualifier(qualifier) == (binding, price, currency)


def test_cloth_wording_is_recognised() -> None:
    from bookshelf.models import cover_from_binding

    assert cover_from_binding("Gewebe") is CoverType.CLOTH
    assert cover_from_binding("Leinen") is CoverType.CLOTH
    assert cover_from_binding("Festeinband") is CoverType.HARD
    assert cover_from_binding("Broschur") is CoverType.SOFT


def test_contents_note_splits_into_pieces() -> None:
    note = (
        "Scherzo, opus 4 [Einheitssacht.: Scherzi, Kl, op. 4]. "
        "Vier Balladen, opus 10 [Einheitssacht.: Balladen, Kl, op. 10]. "
        "Zwei Rhapsodien, opus 79 [Einheitssacht.: Rhapsodien, Kl, op. 79]."
    )
    items = split_contents(note)
    assert [item.label for item in items] == [
        "Scherzo, opus 4",
        "Vier Balladen, opus 10",
        "Zwei Rhapsodien, opus 79",
    ]
    assert items[0].work_title == "Scherzi, Kl, op. 4"


def test_thematic_catalogue_abbreviations_do_not_split_an_entry() -> None:
    note = "Capriccio in G Hob. XVII:1. Variationen in A Hob. XVII:2."
    assert [item.label for item in split_contents(note)] == [
        "Capriccio in G Hob. XVII:1",
        "Variationen in A Hob. XVII:2",
    ]
