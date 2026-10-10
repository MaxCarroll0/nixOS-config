"""AbeBooks used listings, by scraping its search results.

AbeBooks has the best coverage of out-of-print academic books and older scores, and no
public API, so this parses its result page. That is against AbeBooks' terms of use and
its markup will change without notice; the provider is therefore off unless explicitly
enabled, and reports itself unavailable rather than guessing when the page no longer
matches.
"""

from __future__ import annotations

import re
from typing import Final

from selectolax.parser import HTMLParser

from bookshelf.config import Settings
from bookshelf.fetch import Fetcher, ProviderUnavailable
from bookshelf.models import CompObservation, Condition

SEARCH_URL: Final = "https://www.abebooks.co.uk/servlet/SearchResults"

_MONEY: Final = re.compile(r"(?:£|GBP\s*)\s*(\d+(?:[.,]\d{2})?)")

_CONDITION_WORDS: Final[dict[str, Condition]] = {
    "as new": Condition.LIKE_NEW,
    "fine": Condition.LIKE_NEW,
    "near fine": Condition.LIKE_NEW,
    "very good": Condition.GOOD,
    "good": Condition.GOOD,
    "acceptable": Condition.ACCEPTABLE,
    "fair": Condition.ACCEPTABLE,
    "poor": Condition.POOR,
    "ex-library": Condition.ACCEPTABLE,
}


def _condition(text: str) -> Condition | None:
    lowered = text.lower()
    # Longest wording first, so "near fine" is not read as "fine".
    for wording in sorted(_CONDITION_WORDS, key=len, reverse=True):
        if wording in lowered:
            return _CONDITION_WORDS[wording]
    return None


def parse_results(html: str) -> list[CompObservation]:
    """Pull listings out of a search results page, by itemprop where possible."""
    tree = HTMLParser(html)
    out: list[CompObservation] = []

    for node in tree.css("[itemtype*='Product'], li.cf, div.result-item"):
        text = node.text(separator=" ", strip=True)
        price: float | None = None

        offer = node.css_first("[itemprop='price']")
        if offer is not None:
            raw = offer.attributes.get("content") or offer.text(strip=True)
            match = _MONEY.search(raw or "") or re.search(r"(\d+(?:[.,]\d{2})?)", raw or "")
            if match:
                price = float(match.group(1).replace(",", "."))
        if price is None:
            match = _MONEY.search(text)
            if match:
                price = float(match.group(1).replace(",", "."))
        if price is None:
            continue

        link = node.css_first("a[href]")
        href = link.attributes.get("href") if link else None
        out.append(
            CompObservation(
                source="abebooks",
                price=price,
                currency="GBP",
                condition=_condition(text),
                url=f"https://www.abebooks.co.uk{href}" if href and href.startswith("/") else href,
            )
        )
    return out


class AbeBooksProvider:
    name = "abebooks"
    scraped = True

    def available(self, settings: Settings) -> bool:
        return settings.scrapers_enabled

    async def search(
        self, *, title: str, identifier: str | None, fetcher: Fetcher
    ) -> list[CompObservation]:
        params = {"isbn": identifier} if identifier else {"kn": title}
        params["sortby"] = "17"
        html = await fetcher.get(SEARCH_URL, provider=self.name, params=params, interval=3.0)
        found = parse_results(html)
        if not found and "SearchResults" in html and "itemprop" not in html:
            # The page loaded but carries none of the markup we read: treat that as the
            # layout having changed, not as "this book has no listings".
            raise ProviderUnavailable("abebooks: result markup no longer recognised")
        return found
