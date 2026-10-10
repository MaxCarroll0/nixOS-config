"""Seed coefficients, so the valuation model is usable before any comps exist.

These are starting beliefs, not measurements: a catalogue with three books in it has
nothing to fit against, so the model begins here and is progressively displaced as real
observations accumulate. Every figure is expressed the way the model works -- as the log
of a ratio to the price new -- and a fit that beats the seed replaces it outright.
"""

from __future__ import annotations

import math
from typing import Any, Final


def publisher_key(publisher: str | None) -> str:
    """A publisher's identity for the model, as a normalised name rather than a tier.

    Nothing is assumed about which houses hold their value. Each publisher is simply a
    level of a factor, and the fit learns its offset from the comps once there are
    enough; a house never seen before falls back on the intercept, which is exactly the
    right behaviour for one book from an unfamiliar imprint.
    """
    from bookshelf.publishers import normalise_name

    return normalise_name(publisher or "") or "unknown"


def _log(ratio: float) -> float:
    return round(math.log(ratio), 4)


#: A like-new, paperbound, in-print urtext score fetches roughly three fifths of new.
SEED: Final[dict[str, Any]] = {
    "intercept": _log(0.60),
    "condition": {
        "like_new": 0.0,
        "good": _log(0.75),
        "acceptable": _log(0.50),
        "poor": _log(0.28),
    },
    "cover_type": {
        "soft": 0.0,
        "hard": _log(1.15),
        "cloth": _log(1.25),
    },
    # Learned per publisher, so an unseen house costs nothing and a known one is
    # whatever its own listings have shown it to be.
    "publisher": {},
    # Academic texts are superseded by new editions in a way that scores are not.
    "kind": {"score": 0.0, "book": _log(0.55)},
    "log_age": 0.0,
    "log_pages": 0.0,
    # Wide on purpose: a seeded estimate should read as uncertain, because it is.
    "sigma": 0.55,
}

#: Coefficient blocks that are per-level offsets rather than slopes.
FACTORS: Final[tuple[str, ...]] = ("condition", "cover_type", "publisher", "kind")

#: Factors whose levels come from the data rather than from this file.
LEARNED_FACTORS: Final[tuple[str, ...]] = ("publisher",)

#: Numeric slopes, each applied to log1p of the named feature.
SLOPES: Final[tuple[str, ...]] = ("log_age", "log_pages")
