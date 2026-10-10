"""Currency conversion and inflation indexing, for prices recorded decades apart.

A catalogue holds a Deutsche Mark price from 1985 next to a euro price from last week.
To compare them, or to reconstruct what a book cost new when no receipt exists, both
have to be moved onto one currency and one year: the ECB's published rates handle the
first, World Bank consumer price indices the second. Legacy euro-area currencies use
their irrevocable statutory conversion rates, which no rates service still carries.
"""

from __future__ import annotations

import json
from typing import Final

from bookshelf.fetch import Fetcher, ProviderUnavailable

FRANKFURTER: Final = "https://api.frankfurter.dev/v1"
WORLD_BANK: Final = "https://api.worldbank.org/v2/country/{country}/indicator/FP.CPI.TOTL"

#: Irrevocable conversion rates fixed when each currency joined the euro, in units per EUR.
LEGACY_PER_EURO: Final[dict[str, float]] = {
    "DEM": 1.95583,
    "DM": 1.95583,
    "ATS": 13.7603,
    "FRF": 6.55957,
    "ITL": 1936.27,
    "NLG": 2.20371,
    "ESP": 166.386,
    "BEF": 40.3399,
    "FIM": 5.94573,
    "IEP": 0.787564,
    "PTE": 200.482,
    "GRD": 340.750,
}


class Money:
    """Converts between currencies and across years, caching what it looks up."""

    def __init__(self, fetcher: Fetcher, country: str = "GB") -> None:
        self._fetcher = fetcher
        self._country = country
        self._fx: dict[tuple[str, str, str], float] = {}
        self._cpi: dict[int, float] | None = None

    async def rate(self, source: str, target: str, on: str = "latest") -> float:
        """Units of target per unit of source, on a date or today."""
        source, target = source.upper(), target.upper()
        if source == target:
            return 1.0

        # A legacy currency is a fixed multiple of the euro; convert through it.
        if source in LEGACY_PER_EURO:
            return await self.rate("EUR", target, on) / LEGACY_PER_EURO[source]
        if target in LEGACY_PER_EURO:
            return await self.rate(source, "EUR", on) * LEGACY_PER_EURO[target]

        key = (source, target, on)
        if key in self._fx:
            return self._fx[key]

        body = await self._fetcher.get(
            f"{FRANKFURTER}/{on}",
            provider="frankfurter",
            params={"base": source, "symbols": target},
            interval=1.0,
        )
        rates = json.loads(body or "{}").get("rates") or {}
        if target not in rates:
            raise ProviderUnavailable(f"frankfurter: no {source}->{target} rate for {on}")
        value = float(rates[target])
        self._fx[key] = value
        return value

    async def convert(
        self, amount: float, source: str, target: str, on: str = "latest"
    ) -> float:
        return amount * await self.rate(source, target, on)

    async def cpi(self) -> dict[int, float]:
        """Consumer price index by year, so a historic price can be restated."""
        if self._cpi is not None:
            return self._cpi

        body = await self._fetcher.get(
            WORLD_BANK.format(country=self._country),
            provider="worldbank",
            params={"format": "json", "per_page": "200", "date": "1960:2030"},
            interval=1.0,
        )
        payload = json.loads(body or "[]")
        series: dict[int, float] = {}
        if isinstance(payload, list) and len(payload) > 1 and isinstance(payload[1], list):
            for row in payload[1]:
                value = row.get("value")
                if value is None:
                    continue
                series[int(row["date"])] = float(value)
        if not series:
            raise ProviderUnavailable("worldbank: no CPI series")
        self._cpi = series
        return series

    async def index(self, amount: float, from_year: int, to_year: int) -> float | None:
        """Restate an amount from one year's money into another's, or None if unknown."""
        if from_year == to_year:
            return amount
        try:
            series = await self.cpi()
        except ProviderUnavailable:
            return None

        # The index lags by a year or two; fall back to the latest year published.
        latest = max(series)
        start = series.get(from_year)
        end = series.get(to_year) or series.get(latest)
        if start is None or end is None or start <= 0:
            return None
        return amount * (end / start)
