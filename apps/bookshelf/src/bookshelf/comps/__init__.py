"""Used-market observations, from several providers of very different reliability.

Only eBay offers a sanctioned API. The others are scraped, which is fragile and against
those sites' terms, so they are off unless deliberately enabled, run only in the
background refresh job, and are skipped rather than retried once they start failing --
a provider going dark should cost a valuation one tier of confidence, not an error.
"""

from __future__ import annotations

import logging
from typing import Protocol

from bookshelf.config import SETTINGS, Settings
from bookshelf.fetch import Fetcher, ProviderUnavailable
from bookshelf.models import CompObservation

log = logging.getLogger(__name__)


class CompsProvider(Protocol):
    name: str
    #: Whether this provider works by scraping a site that has not invited it.
    scraped: bool

    def available(self, settings: Settings) -> bool:
        """Whether this provider is configured and permitted to run."""
        ...

    async def search(
        self, *, title: str, identifier: str | None, fetcher: Fetcher
    ) -> list[CompObservation]:
        ...


def providers() -> dict[str, CompsProvider]:
    from bookshelf.comps import abebooks, amazon, ebay

    return {
        "ebay": ebay.EbayProvider(),
        "abebooks": abebooks.AbeBooksProvider(),
        "amazon": amazon.AmazonProvider(),
    }


async def gather(
    *,
    title: str,
    identifier: str | None,
    fetcher: Fetcher,
    settings: Settings = SETTINGS,
) -> tuple[list[CompObservation], list[str]]:
    """Ask every enabled provider, keeping going when one of them fails."""
    registry = providers()
    out: list[CompObservation] = []
    problems: list[str] = []

    for name in (n.strip() for n in settings.comps_providers):
        provider = registry.get(name)
        if provider is None:
            continue
        if not provider.available(settings):
            continue
        if provider.scraped and not settings.scrapers_enabled:
            continue
        if fetcher.is_degraded(provider.name):
            problems.append(f"{provider.name} skipped: failing recently")
            continue
        try:
            out += await provider.search(title=title, identifier=identifier, fetcher=fetcher)
        except ProviderUnavailable as exc:
            problems.append(str(exc))
        except Exception:
            log.exception("comps provider %s failed", provider.name)
            problems.append(f"{provider.name}: unexpected error")

    return out, problems
