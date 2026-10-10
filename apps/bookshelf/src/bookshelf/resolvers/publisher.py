"""Publisher websites, for the current list price and the binding variants on sale.

Only routes a publisher invites crawlers to are used. Henle advertises a sitemap
covering every product page, so the catalogue number is resolved to a URL from that
index rather than by driving the site's search -- which its robots.txt disallows -- and
the product pages themselves carry schema.org microdata, so the price is read from
structured data rather than from layout.
"""

from __future__ import annotations

import gzip
import re
import time
from typing import Final
from xml.etree import ElementTree

from selectolax.parser import HTMLParser

from bookshelf import catnum
from bookshelf.fetch import Fetcher, ProviderUnavailable
from bookshelf.models import Candidate

HENLE_SITEMAP: Final = "https://www.henle.de/sitemap.xml"
_SITEMAP_NS: Final = "{http://www.sitemaps.org/schemas/sitemap/0.9}"
_HN_URL: Final = re.compile(r"/HN-(\d+)$")

#: Prefixes this resolver can reach a product page for.
SUPPORTED_PREFIXES: Final[frozenset[str]] = frozenset({"HN"})

_SITEMAP_TTL_SECONDS: Final = 7 * 24 * 3600


class _HenleIndex:
    """HN number to product URL, built once from the sitemap and reused."""

    def __init__(self) -> None:
        self._urls: dict[str, str] = {}
        self._built_at = 0.0

    def fresh(self) -> bool:
        return bool(self._urls) and (time.monotonic() - self._built_at) < _SITEMAP_TTL_SECONDS

    async def build(self, fetcher: Fetcher) -> None:
        index = await fetcher.get(HENLE_SITEMAP, provider="henle", interval=1.0)
        root = ElementTree.fromstring(index)
        children = [
            loc.text.strip()
            for loc in root.iter(f"{_SITEMAP_NS}loc")
            if loc.text and "-en-" in loc.text
        ]

        urls: dict[str, str] = {}
        for child in children:
            raw = await fetcher.get_bytes(child, provider="henle", interval=1.0)
            text = _maybe_gunzip(raw)
            for loc in ElementTree.fromstring(text).iter(f"{_SITEMAP_NS}loc"):
                if loc.text is None:
                    continue
                match = _HN_URL.search(loc.text.strip())
                if match:
                    urls[f"HN{int(match.group(1))}"] = loc.text.strip()

        if urls:
            self._urls = urls
            self._built_at = time.monotonic()

    def lookup(self, canonical: str) -> str | None:
        return self._urls.get(canonical)


def _maybe_gunzip(raw: bytes) -> str:
    """Sitemap children are served as .xml.gz, but a server may hand back plain XML."""
    if raw[:2] == b"\x1f\x8b":
        try:
            raw = gzip.decompress(raw)
        except OSError as exc:
            raise ProviderUnavailable(f"henle: unreadable sitemap child ({exc})") from exc
    return raw.decode("utf-8", "replace")


_INDEX = _HenleIndex()


def parse_product(
    html: str, url: str, number: catnum.CatalogueNumber, publisher: str | None = None
) -> Candidate | None:
    """Read a publisher product page's microdata: title, price, currency."""
    tree = HTMLParser(html)

    price: float | None = None
    currency: str | None = None
    for meta in tree.css("meta[itemprop]"):
        prop = meta.attributes.get("itemprop")
        content = meta.attributes.get("content")
        if not content:
            continue
        if prop == "price":
            try:
                price = float(content)
            except ValueError:
                price = None
        elif prop == "priceCurrency":
            currency = content

    heading = tree.css_first("h1")
    title = (heading.text(strip=True) if heading else "") or None
    if title is None and price is None:
        return None

    return Candidate(
        source="henle",
        source_ref=number.canonical,
        url=url,
        title=title or str(number),
        publisher=publisher,
        cat_no=str(number),
        cat_no_norm=number.canonical,
        price_new=price,
        price_currency=currency,
        score=0.6,
    )


class PublisherResolver:
    """Current list price and title from the publisher's own product page."""

    name = "publisher"

    def handles(self, query: str) -> bool:
        number = catnum.parse(query)
        return number is not None and number.prefix in SUPPORTED_PREFIXES

    async def search(self, query: str, fetcher: Fetcher) -> list[Candidate]:
        number = catnum.parse(query)
        if number is None or number.prefix not in SUPPORTED_PREFIXES:
            return []

        if not _INDEX.fresh():
            await _INDEX.build(fetcher)
        url = _INDEX.lookup(number.canonical)
        if url is None:
            return []

        html = await fetcher.get(url, provider=self.name, interval=2.0)
        found = parse_product(html, url, number, "G. Henle Verlag")
        return [] if found is None else [found]
