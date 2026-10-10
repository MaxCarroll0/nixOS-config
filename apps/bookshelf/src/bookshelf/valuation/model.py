"""Fitting the used-over-new ratio model, with statsmodels.

This is the only module that imports a scientific stack, and it is imported only by the
refresh job: on a small always-on server the web service must not carry scipy's resident
footprint just to multiply a few stored coefficients together.

The model is a weighted least squares fit of ``log(used / new)`` on dummy-coded
condition, cover type, publisher tier and kind, plus log age and log extent. Fitting the
ratio rather than the price is what lets a £12 study score and a £220 Gesamtausgabe
volume inform one another. statsmodels is used rather than hand-rolled linear algebra
because the standard errors and prediction intervals are the point -- an estimate with no
honest band is worse than no estimate.
"""

from __future__ import annotations

import json
import math
import sqlite3
from collections import Counter
from dataclasses import dataclass
from typing import Any

import numpy as np
import statsmodels.api as sm

from bookshelf.models import Condition, CoverType, Kind
from bookshelf.valuation import priors

#: Below this many observations a fit is worse than the seed, so the seed is kept.
MIN_OBSERVATIONS = 12


@dataclass(frozen=True, slots=True)
class Observation:
    """One comp paired with the price new of the thing it is a comp for."""

    ratio: float
    condition: str
    cover_type: str
    publisher: str
    kind: str
    age_years: float
    pages: int | None
    weight: float = 1.0


def observations(conn: sqlite3.Connection, window_days: int = 365) -> list[Observation]:
    """Every comp that can be paired with a price new, as a fittable ratio.

    Comps are weighted by how many an edition has, so a single edition with forty
    listings cannot dominate the fit for the whole collection.
    """
    rows = conn.execute(
        """
        WITH latest_new AS (
          SELECT edition_id, price, currency, MAX(observed_at) AS observed_at
          FROM price_new GROUP BY edition_id
        )
        SELECT c.price, c.shipping, c.condition, c.currency AS comp_currency,
               n.price AS new_price, n.currency AS new_currency,
               e.publisher, e.kind, e.pages, e.year,
               (SELECT COUNT(*) FROM comp c2 WHERE c2.edition_id = c.edition_id) AS siblings,
               (SELECT cover_type FROM copy cp WHERE cp.edition_id = c.edition_id LIMIT 1) AS cover_type
        FROM comp c
        JOIN latest_new n ON n.edition_id = c.edition_id
        JOIN edition e ON e.id = c.edition_id
        WHERE c.observed_at > datetime('now', ?)
          AND n.price > 0 AND c.currency = n.currency
        """,
        (f"-{window_days} days",),
    ).fetchall()

    now_year = int(
        conn.execute("SELECT CAST(strftime('%Y','now') AS INTEGER)").fetchone()[0]
    )

    out: list[Observation] = []
    for row in rows:
        total = float(row["price"]) + float(row["shipping"] or 0.0)
        ratio = total / float(row["new_price"])
        # A ratio outside this range is a data error -- a boxed set listed against a
        # single volume's price, or a misparsed figure -- not a signal about condition.
        if not 0.02 <= ratio <= 3.0:
            continue
        out.append(
            Observation(
                ratio=ratio,
                condition=str(row["condition"] or Condition.GOOD.value),
                cover_type=str(row["cover_type"] or CoverType.SOFT.value),
                publisher=priors.publisher_key(row["publisher"]),
                kind=str(row["kind"] or Kind.SCORE.value),
                age_years=float(max(now_year - int(row["year"] or now_year), 0)),
                pages=int(row["pages"]) if row["pages"] else None,
                weight=1.0 / math.sqrt(max(int(row["siblings"] or 1), 1)),
            )
        )
    return out


#: A publisher needs at least this many listings before it earns its own coefficient;
#: below it, one odd listing would become that whole house's reputation.
MIN_PER_PUBLISHER = 5


def _factor_values(row: Observation) -> dict[str, str]:
    return {
        "condition": row.condition,
        "cover_type": row.cover_type,
        "publisher": row.publisher,
        "kind": row.kind,
    }


def levels(factor: str, rows: list[Observation]) -> list[str]:
    """Levels of a factor, with the first as the reference the intercept absorbs.

    Most factors have a fixed vocabulary. Publisher does not -- it is whatever is in the
    collection -- so its levels are read off the data, and a house with too few listings
    to say anything about is pooled into the reference rather than given a coefficient.
    """
    if factor not in priors.LEARNED_FACTORS:
        block = priors.SEED[factor]
        assert isinstance(block, dict)
        return list(block)

    counts = Counter(_factor_values(row)[factor] for row in rows)
    frequent = sorted(
        (name for name, count in counts.items() if count >= MIN_PER_PUBLISHER),
        key=lambda name: (-counts[name], name),
    )
    if not frequent:
        return []
    # The commonest level is the reference the intercept absorbs. Giving every level its
    # own column instead would make the design collinear with the intercept, since every
    # row has exactly one publisher; and it leaves unseen houses falling back on the
    # reference, which is the right default for an unfamiliar imprint.
    return frequent


def design(
    rows: list[Observation],
) -> tuple[Any, Any, Any, list[str], dict[str, list[str]]]:
    """Dummy-code the factors into a design matrix, plus the response and weights."""
    vocabulary = {factor: levels(factor, rows) for factor in priors.FACTORS}

    columns: list[str] = ["intercept"]
    for factor in priors.FACTORS:
        columns += [f"{factor}:{level}" for level in vocabulary[factor][1:]]
    columns += list(priors.SLOPES)

    matrix: list[list[float]] = []
    for row in rows:
        values = _factor_values(row)
        line = [1.0]
        for factor in priors.FACTORS:
            line += [
                1.0 if values[factor] == level else 0.0 for level in vocabulary[factor][1:]
            ]
        line += [math.log1p(row.age_years), math.log1p(float(row.pages or 0))]
        matrix.append(line)

    return (
        np.array(matrix, dtype=float),
        np.array([math.log(row.ratio) for row in rows], dtype=float),
        np.array([row.weight for row in rows], dtype=float),
        columns,
        vocabulary,
    )


def fit(rows: list[Observation]) -> tuple[dict[str, Any], dict[str, Any]] | None:
    """Fit the model, or return None when there is too little to improve on the seed."""
    if len(rows) < MIN_OBSERVATIONS:
        return None

    exog, endog, weights, columns, vocabulary = design(rows)

    # A factor level nobody has an example of is unidentifiable; drop those columns and
    # let the seed keep speaking for them.
    keep = [index for index in range(exog.shape[1]) if exog[:, index].any()]
    if len(keep) >= exog.shape[0]:
        return None

    result = sm.WLS(endog, exog[:, keep], weights=weights).fit()
    estimated = dict(zip([columns[index] for index in keep], map(float, result.params)))

    coefficients: dict[str, Any] = {
        "intercept": estimated.get("intercept", priors.SEED["intercept"]),
        "sigma": float(math.sqrt(max(float(result.mse_resid), 1e-6))),
    }
    for factor in priors.FACTORS:
        seed_block = priors.SEED[factor]
        assert isinstance(seed_block, dict)
        reference = vocabulary[factor][0]
        block: dict[str, float] = {reference: 0.0} if reference else {}
        for level in vocabulary[factor][1:]:
            fallback = float(seed_block.get(level, 0.0))
            block[level] = estimated.get(f"{factor}:{level}", fallback)
        coefficients[factor] = block
    for slope in priors.SLOPES:
        coefficients[slope] = estimated.get(slope, float(priors.SEED[slope]))

    diagnostics = {
        "n_obs": len(rows),
        "r_squared": float(result.rsquared) if not math.isnan(result.rsquared) else None,
        "sigma": coefficients["sigma"],
        "dropped": [columns[i] for i in range(exog.shape[1]) if i not in keep],
    }
    return coefficients, diagnostics


def refit(conn: sqlite3.Connection, window_days: int = 365) -> dict[str, Any]:
    """Fit against what the catalogue now knows and record the result."""
    rows = observations(conn, window_days)
    fitted = fit(rows)

    if fitted is None:
        already = conn.execute("SELECT id FROM model_fit WHERE is_seed = 1 LIMIT 1").fetchone()
        if already is None:
            conn.execute(
                """INSERT INTO model_fit (n_obs, sigma, r_squared, coefficients, is_seed)
                   VALUES (?, ?, NULL, ?, 1)""",
                (len(rows), float(priors.SEED["sigma"]), json.dumps(priors.SEED)),
            )
        return {
            "fitted": False,
            "n_obs": len(rows),
            "needed": MIN_OBSERVATIONS,
            "using": "seed coefficients",
        }

    coefficients, diagnostics = fitted
    conn.execute(
        """INSERT INTO model_fit (n_obs, sigma, r_squared, coefficients, is_seed)
           VALUES (?, ?, ?, ?, 0)""",
        (
            diagnostics["n_obs"],
            diagnostics["sigma"],
            diagnostics["r_squared"],
            json.dumps(coefficients),
        ),
    )
    return {"fitted": True, **diagnostics}
