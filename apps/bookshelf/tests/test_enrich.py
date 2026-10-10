"""Movement lists, which are what turn one line in a contents listing into its parts."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest

from bookshelf.enrich.musicbrainz import _parts, _sort_key

FIXTURES = Path(__file__).parent / "fixtures"


def load(name: str) -> dict[str, Any]:
    payload: dict[str, Any] = json.loads((FIXTURES / name).read_text(encoding="utf-8"))
    return payload


def test_a_parent_points_forward_at_its_movements() -> None:
    children = _parts(load("mb-parent.json"), "forward")
    assert len(children) == 5
    assert all(child["title"] for child in children)


def test_a_movement_points_backward_at_its_parent() -> None:
    """The common case: a title search ranks movements above the work they belong to."""
    payload = load("mb-movement.json")
    assert _parts(payload, "forward") == [], "a movement has no movements of its own"

    parents = _parts(payload, "backward")
    assert len(parents) == 1
    assert "serenáda" in parents[0]["title"].lower()


def test_movements_come_back_in_performing_order() -> None:
    children = _parts(load("mb-parent.json"), "forward")
    ordered = sorted((str(c["title"]) for c in children), key=_sort_key)
    numerals = [title.split(":")[-1].strip().split(".")[0] for title in ordered]
    assert numerals == ["I", "II", "III", "IV", "V"]


@pytest.mark.parametrize(
    ("title", "position"),
    [
        ("I. Moderato", 1),
        ("IV. Larghetto", 4),
        ("IX. Finale", 9),
        ("2. Andante", 2),
        ("Unnumbered movement", 10**6),
    ],
)
def test_sort_key_reads_both_numbering_styles(title: str, position: int) -> None:
    assert _sort_key(title)[0] == position


def test_a_work_with_no_relations_yields_nothing() -> None:
    assert _parts({}, "forward") == []
    assert _parts({"relations": []}, "backward") == []


def test_relations_of_other_types_are_ignored() -> None:
    payload = {
        "relations": [
            {"type": "arrangement", "direction": "forward", "work": {"title": "X"}},
            {"type": "parts", "direction": "forward", "work": {"title": "Y"}},
        ]
    }
    assert [c["title"] for c in _parts(payload, "forward")] == ["Y"]


@pytest.mark.parametrize(
    ("title", "uniform", "expected"),
    [
        (
            "Bläserserenade d-Moll Opus 44",
            "Serenaden",
            ["Bläserserenade d-Moll Opus 44", "Serenaden", "Bläserserenade"],
        ),
        ("Messe in G, D 167", "Messen", ["Messe in G, D 167", "Messen", "Messe"]),
        ("Klavierstücke", "Stücke, Kl, op. 76", ["Klavierstücke", "Stücke, Kl, op. 76"]),
        (None, "Serenaden", ["Serenaden"]),
        (None, None, []),
    ],
)
def test_candidate_titles(title: str | None, uniform: str | None, expected: list[str]) -> None:
    """A library's uniform title is a filing heading, so the printed title is tried first."""
    from bookshelf.enrich import candidate_titles

    assert candidate_titles(title, uniform) == expected


def test_candidate_titles_never_exceeds_three_queries() -> None:
    """Each form costs a rate-limited request, so the list is capped."""
    from bookshelf.enrich import candidate_titles

    assert len(candidate_titles("Sonate in A-Dur op. 120 KV 331", "Sonaten")) <= 3
