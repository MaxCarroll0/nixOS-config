"""Catalogue numbers are recorded inconsistently; the expansion is what bridges that.

These tests are about *shape* only. Which publisher a prefix belongs to is deliberately
not asserted here, because the parser does not claim to know: that mapping is learned
from catalogue records and is tested in ``test_publishers.py``.
"""

from __future__ import annotations

import pytest

from bookshelf.catnum import looks_like_catalogue_number, parse, variants


@pytest.mark.parametrize(
    ("raw", "prefix", "digits", "canonical"),
    [
        ("HN 1234", "HN", "1234", "HN1234"),
        ("HN240", "HN", "240", "HN240"),
        ("BA 5000", "BA", "5000", "BA5000"),
        ("BA05583-90", "BA", "05583", "BA5583-90"),
        ("EP20024", "EP", "20024", "EP20024"),
        ("Bestellnummer EP20037", "EP", "20037", "EP20037"),
        ("EB 9478", "EB", "9478", "EB9478"),
        ("ChB 5394", "CHB", "5394", "CHB5394"),
        ("ED 20869D", "ED", "20869", "ED20869D"),
        ("BB 1817", "BB", "1817", "BB1817"),
    ],
)
def test_letters_then_digits(raw: str, prefix: str, digits: str, canonical: str) -> None:
    number = parse(raw)
    assert number is not None
    assert (number.prefix, number.digits) == (prefix, digits)
    assert number.canonical == canonical
    assert number.distinctive


def test_digits_then_letters() -> None:
    """Kalmus prints its letters after the number."""
    number = parse("0827KK")
    assert number is not None
    assert number.trailing
    assert (number.prefix, number.digits) == ("KK", "0827")
    assert str(number) == "0827KK"


@pytest.mark.parametrize(
    ("raw", "digits", "suffix"),
    [
        ("18371", "18371", ""),
        ("27.317/50", "27317", "-50"),
        ("27.317/50 (Partitur)", "27317", "-50"),
    ],
)
def test_bare_plate_numbers(raw: str, digits: str, suffix: str) -> None:
    """The French houses, and much of Boosey, use no letters at all."""
    number = parse(raw)
    assert number is not None
    assert number.prefixless
    assert (number.digits, number.suffix) == (digits, suffix)


def test_a_bare_number_is_not_distinctive_on_its_own() -> None:
    """18371 is a Durand plate number and also somebody's book order number."""
    number = parse("18371")
    assert number is not None
    assert not number.distinctive
    assert not looks_like_catalogue_number("18371")


def test_words_in_front_become_a_qualifier() -> None:
    """Whatever was typed is kept as a search constraint, not matched to a list."""
    number = parse("durand 18371")
    assert number is not None
    assert number.qualifier == "durand"
    assert number.distinctive
    assert looks_like_catalogue_number("durand 18371")
    # The qualifier is part of the key: a bare number is unique only within one house.
    assert number.canonical == "DURA-18371"


def test_a_qualifier_works_for_any_publisher_named() -> None:
    """Nothing is hardcoded, so an unfamiliar house works exactly as well."""
    number = parse("obscure-press 4412")
    assert number is not None
    assert number.qualifier == "obscure-press"
    assert number.distinctive


def test_zero_padded_spelling_is_searched() -> None:
    """Bärenreiter files BA 5000 as BA05000, so the typed form alone finds nothing."""
    number = parse("BA 5000")
    assert number is not None
    spellings = variants(number)
    assert "BA05000" in spellings
    assert "BA 5000" in spellings
    assert spellings[0] == "BA 5000", "the typed form should still be tried first"


def test_learned_prefixes_are_offered_too() -> None:
    """A house that files some editions bare and others under a prefix gets both."""
    number = parse("boosey 16902")
    assert number is not None
    spellings = variants(number, prefixes=("BB", "HPS"))
    assert "16902" in spellings
    assert "BB 16902" in spellings
    assert "HPS16902" in spellings


def test_dotted_thousands_are_offered_both_ways() -> None:
    number = parse("durand 18371")
    assert number is not None
    assert set(variants(number)) >= {"18371", "18.371"}


def test_suffix_survives_expansion() -> None:
    number = parse("BA05583-90")
    assert number is not None
    assert all(spelling.endswith("-90") for spelling in variants(number))


def test_price_suffix_is_not_part_of_the_number() -> None:
    number = parse("BVE08076* : EUR 30.00")
    assert number is not None
    assert number.digits == "08076"


@pytest.mark.parametrize("raw", ["9790201812342", "978-3-16-148410-0", "", "   "])
def test_identifiers_and_nothing_are_not_catalogue_numbers(raw: str) -> None:
    assert not looks_like_catalogue_number(raw)


def test_a_work_reference_is_not_an_edition() -> None:
    assert not looks_like_catalogue_number("Op 27")


def test_variants_are_unique() -> None:
    number = parse("HN 1234")
    assert number is not None
    spellings = variants(number, prefixes=("HN", "BA"))
    assert len(spellings) == len(set(spellings))
