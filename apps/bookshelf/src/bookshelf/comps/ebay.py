"""eBay Browse API: the one sanctioned source of current second-hand asking prices.

Needs a free developer application; the client id and secret are exchanged for an
application token, which is cached until shortly before it expires. Sold prices live
behind the separately-approved Marketplace Insights API, so what this returns is what
sellers are currently asking, which is an upper bound on what a thing fetches.
"""

from __future__ import annotations

import base64
import json
import time
from typing import Any, Final

from bookshelf.config import Settings
from bookshelf.fetch import Fetcher, ProviderUnavailable
from bookshelf.models import CompObservation, Condition

TOKEN_URL: Final = "https://api.ebay.com/identity/v1/oauth2/token"
SEARCH_URL: Final = "https://api.ebay.com/buy/browse/v1/item_summary/search"
SCOPE: Final = "https://api.ebay.com/oauth/api_scope"

#: eBay's condition vocabulary, mapped onto ours.
_CONDITIONS: Final[dict[str, Condition]] = {
    "NEW": Condition.LIKE_NEW,
    "LIKE_NEW": Condition.LIKE_NEW,
    "NEW_OTHER": Condition.LIKE_NEW,
    "VERY_GOOD": Condition.GOOD,
    "GOOD": Condition.GOOD,
    "USED_EXCELLENT": Condition.LIKE_NEW,
    "USED_VERY_GOOD": Condition.GOOD,
    "USED_GOOD": Condition.GOOD,
    "ACCEPTABLE": Condition.ACCEPTABLE,
    "USED_ACCEPTABLE": Condition.ACCEPTABLE,
    "FOR_PARTS_OR_NOT_WORKING": Condition.POOR,
}


class EbayProvider:
    name = "ebay"
    scraped = False

    def __init__(self) -> None:
        self._token: str | None = None
        self._expires_at = 0.0

    def available(self, settings: Settings) -> bool:
        return bool(settings.ebay_client_id and settings.ebay_client_secret)

    async def _access_token(self, fetcher: Fetcher, settings: Settings) -> str:
        if self._token is not None and time.monotonic() < self._expires_at:
            return self._token
        if not (settings.ebay_client_id and settings.ebay_client_secret):
            raise ProviderUnavailable("ebay: no credentials configured")

        secret = f"{settings.ebay_client_id}:{settings.ebay_client_secret}".encode()
        body = await fetcher.post_form(
            TOKEN_URL,
            provider=self.name,
            data={"grant_type": "client_credentials", "scope": SCOPE},
            headers={
                "Authorization": f"Basic {base64.b64encode(secret).decode()}",
                "Content-Type": "application/x-www-form-urlencoded",
            },
        )
        payload: dict[str, Any] = json.loads(body or "{}")
        token = payload.get("access_token")
        if not token:
            raise ProviderUnavailable("ebay: token refused")
        self._token = str(token)
        # Renew a minute early rather than racing the expiry.
        self._expires_at = time.monotonic() + float(payload.get("expires_in", 7200)) - 60
        return self._token

    async def search(
        self, *, title: str, identifier: str | None, fetcher: Fetcher
    ) -> list[CompObservation]:
        from bookshelf.config import SETTINGS

        token = await self._access_token(fetcher, SETTINGS)
        query = identifier or title
        body = await fetcher.get(
            SEARCH_URL,
            provider=self.name,
            params={
                "q": query,
                "limit": "50",
                "filter": "conditions:{USED}",
                "fieldgroups": "EXTENDED",
            },
            headers={
                "Authorization": f"Bearer {token}",
                "X-EBAY-C-MARKETPLACE-ID": SETTINGS.ebay_marketplace,
            },
            interval=0.5,
        )
        payload: dict[str, Any] = json.loads(body or "{}")

        out: list[CompObservation] = []
        for item in payload.get("itemSummaries") or []:
            price = (item.get("price") or {}).get("value")
            currency = (item.get("price") or {}).get("currency")
            if price is None or currency is None:
                continue
            shipping: float | None = None
            for option in item.get("shippingOptions") or []:
                cost = (option.get("shippingCost") or {}).get("value")
                if cost is not None:
                    shipping = float(cost)
                    break
            out.append(
                CompObservation(
                    source=self.name,
                    price=float(price),
                    currency=str(currency),
                    shipping=shipping,
                    condition=_CONDITIONS.get(str(item.get("conditionId") or item.get("condition") or "").upper()),
                    is_sold=False,
                    url=item.get("itemWebUrl"),
                    external_id=item.get("itemId"),
                )
            )
        return out
