"""Amazon used offers, by scraping the offer-listing page.

Amazon's Product Advertising API needs qualifying affiliate sales, so the only way in
is the public page. Amazon actively blocks automated access and this breaks regularly;
like AbeBooks it is off unless explicitly enabled, and it reports unavailability rather
than inventing a figure.
"""

from __future__ import annotations

import re
from typing import Final

from selectolax.parser import HTMLParser

from bookshelf.config import Settings
from bookshelf.fetch import Fetcher, ProviderUnavailable
from bookshelf.models import CompObservation, Condition

OFFERS_URL: Final = "https://www.amazon.co.uk/gp/offer-listing/{asin}"

_MONEY: Final = re.compile(r"£\s*(\d+(?:[.,]\d{2})?)")

_CONDITION_WORDS: Final[dict[str, Condition]] = {
    "used - like new": Condition.LIKE_NEW,
    "used - very good": Condition.GOOD,
    "used - good": Condition.GOOD,
    "used - acceptable": Condition.ACCEPTABLE,
    "collectible": Condition.GOOD,
}


def parse_offers(html: str, asin: str) -> list[CompObservation]:
    tree = HTMLParser(html)
    out: list[CompObservation] = []

    for row in tree.css("#aod-offer, div.olpOffer, div[id^='aod-offer']"):
        text = row.text(separator=" ", strip=True).lower()
        match = _MONEY.search(row.text(separator=" ", strip=True))
        if match is None:
            continue
        condition: Condition | None = None
        for wording in sorted(_CONDITION_WORDS, key=len, reverse=True):
            if wording in text:
                condition = _CONDITION_WORDS[wording]
                break
        out.append(
            CompObservation(
                source="amazon",
                price=float(match.group(1).replace(",", ".")),
                currency="GBP",
                condition=condition,
                url=OFFERS_URL.format(asin=asin),
            )
        )
    return out


class AmazonProvider:
    name = "amazon"
    scraped = True

    def available(self, settings: Settings) -> bool:
        return settings.scrapers_enabled

    async def search(
        self, *, title: str, identifier: str | None, fetcher: Fetcher
    ) -> list[CompObservation]:
        # The offer-listing page is addressed by ASIN, and for books a 10-digit ISBN is
        # the ASIN; without one there is no page to ask for.
        if identifier is None or not re.fullmatch(r"[0-9]{9}[0-9X]", identifier):
            return []

        html = await fetcher.get(
            OFFERS_URL.format(asin=identifier), provider=self.name, interval=5.0
        )
        if "captcha" in html.lower() or "api-services-support@amazon.com" in html:
            raise ProviderUnavailable("amazon: blocked as automated traffic")
        return parse_offers(html, identifier)
