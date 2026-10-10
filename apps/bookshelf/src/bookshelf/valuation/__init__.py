"""Turning observations and a fitted model into a defensible pair of figures.

Two numbers are kept apart on purpose. The cost basis is what was paid, or the best
reconstruction of it; the market value is what the thing would fetch now. Neither is
ever reported bare: every estimate carries the method that produced it and an interval,
so it is obvious at a glance which figures rest on evidence and which on the model.
"""

from __future__ import annotations

import json
import math
import sqlite3
from dataclasses import dataclass
from statistics import median
from typing import Any

from bookshelf.config import SETTINGS, Settings
from bookshelf.models import CompObservation, Condition, CoverType, Estimate, Kind, Method
from bookshelf.valuation import priors


@dataclass(frozen=True, slots=True)
class Features:
    """What the model needs to know about an edition and the copy of it being valued."""

    condition: Condition
    cover_type: CoverType
    publisher: str
    kind: Kind
    age_years: float
    pages: int | None


def load_coefficients(conn: sqlite3.Connection) -> dict[str, Any]:
    """The most recent fit, or the seed when nothing has been fitted yet."""
    row = conn.execute(
        "SELECT coefficients, sigma FROM model_fit ORDER BY fitted_at DESC, id DESC LIMIT 1"
    ).fetchone()
    if row is None:
        return dict(priors.SEED)
    loaded: dict[str, Any] = json.loads(row["coefficients"])
    loaded.setdefault("sigma", row["sigma"])
    return loaded


def predict_log_ratio(coefficients: dict[str, Any], features: Features) -> float:
    """The model's log of used-over-new for these features."""
    total = float(coefficients.get("intercept", 0.0))

    levels: dict[str, str] = {
        "condition": features.condition.value,
        "cover_type": features.cover_type.value,
        "publisher": features.publisher,
        "kind": features.kind.value,
    }
    for factor in priors.FACTORS:
        block = coefficients.get(factor) or {}
        total += float(block.get(levels[factor], 0.0))

    total += float(coefficients.get("log_age", 0.0)) * math.log1p(max(features.age_years, 0.0))
    total += float(coefficients.get("log_pages", 0.0)) * math.log1p(float(features.pages or 0))
    return total


def condition_multiplier(coefficients: dict[str, Any], condition: Condition | None) -> float:
    """How a comp in one condition translates to another, from the fitted offsets."""
    if condition is None:
        return 1.0
    block = coefficients.get("condition") or {}
    return math.exp(float(block.get(condition.value, 0.0)))


def adjust_comps(
    comps: list[CompObservation],
    coefficients: dict[str, Any],
    target: Condition,
) -> list[float]:
    """Restate each comp as what it implies for a copy in the target condition."""
    target_factor = condition_multiplier(coefficients, target)
    out: list[float] = []
    for comp in comps:
        total = comp.price + (comp.shipping or 0.0)
        source_factor = condition_multiplier(coefficients, comp.condition)
        if source_factor <= 0:
            continue
        out.append(total * (target_factor / source_factor))
    return out


def estimate_market(
    *,
    comps: list[CompObservation],
    price_new: float | None,
    features: Features,
    coefficients: dict[str, Any],
    currency: str = "GBP",
    settings: Settings = SETTINGS,
) -> Estimate:
    """Blend observed comps with the model, in proportion to how many comps there are.

    With enough comps the observations speak for themselves. With none, only the model
    can. In between -- which is most of a personal collection most of the time -- the
    two are combined in log space with weight ``n / (n + k)``, so evidence displaces the
    model smoothly instead of switching over at a threshold.
    """
    adjusted = [value for value in adjust_comps(comps, coefficients, features.condition) if value > 0]
    n = len(adjusted)
    sigma = float(coefficients.get("sigma", priors.SEED["sigma"]))

    observed = median(adjusted) if adjusted else None
    modelled = (
        price_new * math.exp(predict_log_ratio(coefficients, features))
        if price_new is not None
        else None
    )

    # How much the listings themselves disagree. One listing says nothing about spread,
    # so the model's own sigma stands in until there are enough to measure it.
    observed_sigma = _dispersion(adjusted) if n >= 2 else 0.0
    observed_sigma = observed_sigma or sigma

    if observed is not None and modelled is not None:
        # Blending at every count, rather than switching to the raw median once some
        # threshold is passed, is what keeps the figure from jumping when one more
        # listing turns up. The weight converges on the observations as they accumulate;
        # the threshold only decides what the estimate is *called*.
        weight = n / (n + settings.shrinkage_k)
        value = math.exp(weight * math.log(observed) + (1.0 - weight) * math.log(modelled))
        spread = _blended_sigma(weight, observed_sigma, sigma, n)
        return _banded(value, spread, _label(n, settings), n, currency)

    if observed is not None:
        # Nothing to blend with, so the comps stand alone.
        return _banded(observed, observed_sigma / math.sqrt(n), _label(n, settings), n, currency)

    if modelled is not None:
        return _banded(modelled, sigma, Method.MODELLED, 0, currency)

    return Estimate(
        value=None,
        method=Method.UNKNOWN,
        n_comps=0,
        currency=currency,
        note="no comps and no price new; record a price paid or set a value by hand",
    )


def _blended_sigma(weight: float, observed_sigma: float, model_sigma: float, n: int) -> float:
    """Uncertainty of the blend: two independent estimates combined by their weights.

    The observed side sharpens as the square root of the number of listings; the model
    side does not sharpen at all. Adding the variances this way, rather than averaging
    the standard deviations, is what makes the band narrow as evidence arrives.
    """
    observed_var = (observed_sigma**2) / max(n, 1)
    return math.sqrt((weight**2) * observed_var + ((1.0 - weight) ** 2) * model_sigma**2)


def _label(n: int, settings: Settings) -> Method:
    """What to call an estimate: whether the observations or the model are carrying it."""
    if n == 0:
        return Method.MODELLED
    return Method.COMPS if n >= settings.comps_threshold else Method.BLENDED


def _dispersion(values: list[float]) -> float:
    """Spread of comps on the log scale, which is how the model treats price."""
    if len(values) < 2:
        return 0.0
    logs = [math.log(value) for value in values]
    middle = median(logs)
    # Median absolute deviation, scaled to a standard deviation for a normal sample.
    mad = median([abs(value - middle) for value in logs])
    return 1.4826 * mad


def _banded(
    value: float, sigma: float, method: Method, n: int, currency: str
) -> Estimate:
    sigma = max(sigma, 0.08)
    return Estimate(
        value=round(value, 2),
        lo=round(value * math.exp(-1.96 * sigma), 2),
        hi=round(value * math.exp(1.96 * sigma), 2),
        method=method,
        n_comps=n,
        currency=currency,
    )


def portfolio_total(estimates: list[Estimate]) -> dict[str, Any]:
    """Sum the estimates, and say how much of the total is evidenced rather than modelled.

    Variances add on the log scale, so the band is built from the per-item sigmas rather
    than by naively summing the per-item bands, which would overstate it badly.
    """
    valued = [e for e in estimates if e.value is not None]
    total = sum(float(e.value or 0.0) for e in valued)

    variance = 0.0
    for estimate in valued:
        value = float(estimate.value or 0.0)
        if estimate.lo is None or estimate.hi is None or value <= 0:
            continue
        sigma = math.log(float(estimate.hi) / value) / 1.96 if estimate.hi > value else 0.0
        variance += (value * sigma) ** 2

    spread = math.sqrt(variance)
    counts = {method.value: 0 for method in Method}
    for estimate in estimates:
        counts[estimate.method.value] += 1

    evidenced = sum(
        float(e.value or 0.0) for e in valued if e.method in (Method.COMPS, Method.MANUAL)
    )
    return {
        "total": round(total, 2),
        "lo": round(max(total - 1.96 * spread, 0.0), 2),
        "hi": round(total + 1.96 * spread, 2),
        "evidenced": round(evidenced, 2),
        "evidenced_share": round(evidenced / total, 3) if total > 0 else 0.0,
        "counts": counts,
        "n": len(estimates),
        "n_unvalued": len(estimates) - len(valued),
    }
