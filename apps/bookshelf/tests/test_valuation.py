"""The valuation model, which is what carries an item with too few comps to price it."""

from __future__ import annotations

import math
import random

import pytest

from bookshelf.config import Settings
from bookshelf.models import CompObservation, Condition, CoverType, Kind, Method
from bookshelf.valuation import (
    Features,
    adjust_comps,
    estimate_market,
    portfolio_total,
    priors,
)
from bookshelf.valuation.model import Observation, fit

SETTINGS = Settings()


def features(
    condition: Condition = Condition.GOOD,
    cover: CoverType = CoverType.SOFT,
    tier: str = "henle",
    kind: Kind = Kind.SCORE,
    age: float = 5.0,
    pages: int | None = 80,
) -> Features:
    return Features(
        condition=condition,
        cover_type=cover,
        publisher=tier,
        kind=kind,
        age_years=age,
        pages=pages,
    )


def comp(price: float, condition: Condition | None = Condition.GOOD) -> CompObservation:
    return CompObservation(source="test", price=price, currency="GBP", condition=condition)


def test_plenty_of_comps_is_reported_as_evidence() -> None:
    """Several listings dominate the model, without the model being switched off."""
    estimate = estimate_market(
        comps=[comp(20.0), comp(22.0), comp(24.0), comp(21.0)],
        price_new=40.0,
        features=features(),
        coefficients=dict(priors.SEED),
    )
    assert estimate.method is Method.COMPS
    assert estimate.n_comps == 4
    assert estimate.value is not None
    assert estimate.lo is not None and estimate.hi is not None
    assert estimate.lo < estimate.value < estimate.hi

    observed, modelled = 21.5, 40.0 * 0.60 * 0.75
    assert abs(estimate.value - observed) < abs(estimate.value - modelled)
    assert estimate.value == pytest.approx(observed, rel=0.10)


def test_no_comps_falls_back_to_the_model() -> None:
    estimate = estimate_market(
        comps=[], price_new=40.0, features=features(), coefficients=dict(priors.SEED)
    )
    assert estimate.method is Method.MODELLED
    assert estimate.n_comps == 0
    # A like-new urtext score seeds at 0.60 of new, and "good" discounts that by 0.75.
    assert estimate.value == pytest.approx(40.0 * 0.60 * 0.75, rel=0.02)


def test_nothing_at_all_refuses_to_invent_a_figure() -> None:
    estimate = estimate_market(
        comps=[], price_new=None, features=features(), coefficients=dict(priors.SEED)
    )
    assert estimate.value is None
    assert estimate.method is Method.UNKNOWN
    assert estimate.note


def test_one_comp_is_blended_not_trusted() -> None:
    estimate = estimate_market(
        comps=[comp(30.0)], price_new=40.0, features=features(), coefficients=dict(priors.SEED)
    )
    assert estimate.method is Method.BLENDED
    modelled = 40.0 * 0.60 * 0.75
    assert estimate.value is not None
    # It must sit between the lone observation and the model, not at either end.
    assert min(modelled, 30.0) < estimate.value < max(modelled, 30.0)


def test_the_blend_is_continuous_across_the_threshold() -> None:
    """Adding the comp that crosses the threshold must not jump the figure."""
    coefficients = dict(priors.SEED)
    kwargs = {"price_new": 40.0, "features": features(), "coefficients": coefficients}

    below = estimate_market(comps=[comp(26.0)] * 2, **kwargs)
    above = estimate_market(comps=[comp(26.0)] * 3, **kwargs)

    assert below.method is Method.BLENDED
    assert above.method is Method.COMPS
    assert below.value is not None and above.value is not None
    assert abs(below.value - above.value) / above.value < 0.12


def test_more_comps_pull_towards_the_observations() -> None:
    coefficients = dict(priors.SEED)
    modelled = 40.0 * 0.60 * 0.75
    observed = 30.0

    values = []
    for count in (1, 2):
        estimate = estimate_market(
            comps=[comp(observed)] * count,
            price_new=40.0,
            features=features(),
            coefficients=coefficients,
        )
        assert estimate.value is not None
        values.append(estimate.value)

    assert abs(values[1] - observed) < abs(values[0] - observed)
    assert abs(values[1] - modelled) > abs(values[0] - modelled)


def test_more_comps_narrow_the_band() -> None:
    coefficients = dict(priors.SEED)
    bands = []
    for count in (0, 1, 5):
        estimate = estimate_market(
            comps=[comp(30.0 + index) for index in range(count)],
            price_new=40.0,
            features=features(),
            coefficients=coefficients,
        )
        assert estimate.value and estimate.lo and estimate.hi
        bands.append((estimate.hi - estimate.lo) / estimate.value)
    assert bands[0] > bands[1] > bands[2]


def test_condition_is_adjusted_for_before_comparing() -> None:
    """A poor-condition listing says less about a good copy than a good one does."""
    coefficients = dict(priors.SEED)
    adjusted = adjust_comps([comp(10.0, Condition.POOR)], coefficients, Condition.GOOD)
    assert adjusted[0] > 10.0

    adjusted = adjust_comps([comp(10.0, Condition.LIKE_NEW)], coefficients, Condition.GOOD)
    assert adjusted[0] < 10.0


def test_cloth_is_valued_above_paperbound() -> None:
    coefficients = dict(priors.SEED)
    soft = estimate_market(
        comps=[], price_new=40.0, features=features(cover=CoverType.SOFT), coefficients=coefficients
    )
    cloth = estimate_market(
        comps=[], price_new=40.0, features=features(cover=CoverType.CLOTH), coefficients=coefficients
    )
    assert soft.value is not None and cloth.value is not None
    assert cloth.value > soft.value


def test_worse_condition_is_worth_less() -> None:
    coefficients = dict(priors.SEED)
    values = []
    for condition in (Condition.LIKE_NEW, Condition.GOOD, Condition.ACCEPTABLE, Condition.POOR):
        estimate = estimate_market(
            comps=[],
            price_new=40.0,
            features=features(condition=condition),
            coefficients=coefficients,
        )
        assert estimate.value is not None
        values.append(estimate.value)
    assert values == sorted(values, reverse=True)


def test_fit_recovers_known_coefficients() -> None:
    """Synthesise comps from a known truth and check the fit finds its way back."""
    random.seed(20261010)
    truth = {
        "intercept": math.log(0.55),
        "condition": {"like_new": 0.0, "good": math.log(0.8), "acceptable": math.log(0.55), "poor": math.log(0.3)},
        "cover_type": {"soft": 0.0, "hard": math.log(1.2), "cloth": math.log(1.3)},
        "publisher": {"henle": 0.0, "kalmus": math.log(0.7)},
        "kind": {"score": 0.0, "book": math.log(0.5)},
    }

    rows: list[Observation] = []
    for _ in range(600):
        condition = random.choice(list(truth["condition"]))
        cover = random.choice(list(truth["cover_type"]))
        tier = random.choice(list(truth["publisher"]))
        kind = random.choice(list(truth["kind"]))
        log_ratio = (
            truth["intercept"]
            + truth["condition"][condition]
            + truth["cover_type"][cover]
            + truth["publisher"][tier]
            + truth["kind"][kind]
            + random.gauss(0.0, 0.10)
        )
        rows.append(
            Observation(
                ratio=math.exp(log_ratio),
                condition=condition,
                cover_type=cover,
                publisher=tier,
                kind=kind,
                age_years=0.0,
                pages=0,
            )
        )

    fitted = fit(rows)
    assert fitted is not None
    coefficients, diagnostics = fitted

    # Only differences from each factor's reference level are identifiable; the
    # intercept absorbs the references, so it is checked through a prediction instead.
    for factor in ("condition", "cover_type", "publisher", "kind"):
        reference = next(iter(coefficients[factor]))
        for level, expected in truth[factor].items():
            if level not in coefficients[factor]:
                continue
            offset = expected - truth[factor][reference]
            assert coefficients[factor][level] == pytest.approx(offset, abs=0.08), (
                f"{factor}:{level}"
            )

    predicted = coefficients["intercept"] + sum(
        coefficients[factor][next(iter(coefficients[factor]))]
        for factor in ("condition", "cover_type", "publisher", "kind")
    )
    expected_for_references = truth["intercept"] + sum(
        truth[factor][next(iter(coefficients[factor]))]
        for factor in ("condition", "cover_type", "publisher", "kind")
    )
    assert predicted == pytest.approx(expected_for_references, abs=0.08)
    assert diagnostics["sigma"] == pytest.approx(0.10, abs=0.03)


def test_too_few_observations_keeps_the_seed() -> None:
    rows = [
        Observation(
            ratio=0.5,
            condition="good",
            cover_type="soft",
            publisher="henle",
            kind="score",
            age_years=1.0,
            pages=50,
        )
    ] * 4
    assert fit(rows) is None


def test_portfolio_total_separates_evidenced_from_modelled() -> None:
    evidenced = estimate_market(
        comps=[comp(20.0), comp(21.0), comp(22.0)],
        price_new=40.0,
        features=features(),
        coefficients=dict(priors.SEED),
    )
    modelled = estimate_market(
        comps=[], price_new=100.0, features=features(), coefficients=dict(priors.SEED)
    )

    summary = portfolio_total([evidenced, modelled])
    assert summary["n"] == 2
    assert summary["counts"]["comps"] == 1
    assert summary["counts"]["modelled"] == 1
    assert 0.0 < summary["evidenced_share"] < 1.0
    # The band must be narrower than naively adding the two item bands together.
    assert summary["hi"] - summary["lo"] < (
        (evidenced.hi or 0) - (evidenced.lo or 0) + (modelled.hi or 0) - (modelled.lo or 0)
    )


def test_portfolio_total_counts_what_it_cannot_value() -> None:
    unknown = estimate_market(
        comps=[], price_new=None, features=features(), coefficients=dict(priors.SEED)
    )
    summary = portfolio_total([unknown])
    assert summary["total"] == 0.0
    assert summary["n_unvalued"] == 1
