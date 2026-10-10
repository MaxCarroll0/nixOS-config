"""Runtime settings, all from the environment so the unit file is the only config."""

from __future__ import annotations

import os
from dataclasses import dataclass, field


def _flag(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


@dataclass(frozen=True, slots=True)
class Settings:
    database: str = os.environ.get("BOOKSHELF_DATABASE", "/var/lib/bookshelf/bookshelf.db")
    currency: str = os.environ.get("BOOKSHELF_CURRENCY", "GBP")

    identity_header: str = "Tailscale-User-Login"
    fake_identity: str | None = os.environ.get("BOOKSHELF_FAKE_IDENTITY")

    user_agent: str = os.environ.get(
        "BOOKSHELF_USER_AGENT",
        "bookshelf/0.1 (personal catalogue; +https://github.com/MaxCarroll0/bookshelf)",
    )

    google_books_key: str | None = os.environ.get("BOOKSHELF_GOOGLE_BOOKS_KEY")
    ebay_client_id: str | None = os.environ.get("BOOKSHELF_EBAY_CLIENT_ID")
    ebay_client_secret: str | None = os.environ.get("BOOKSHELF_EBAY_CLIENT_SECRET")
    ebay_marketplace: str = os.environ.get("BOOKSHELF_EBAY_MARKETPLACE", "EBAY_GB")

    #: Resolvers to try, in order. Dropping one here takes it out of the cascade.
    resolvers: tuple[str, ...] = field(
        default_factory=lambda: tuple(
            os.environ.get("BOOKSHELF_RESOLVERS", "dnb,isbn,freetext,publisher").split(",")
        )
    )

    #: Comps providers the refresh job may call.
    comps_providers: tuple[str, ...] = field(
        default_factory=lambda: tuple(
            os.environ.get("BOOKSHELF_COMPS_PROVIDERS", "ebay,abebooks,amazon").split(",")
        )
    )

    scrapers_enabled: bool = _flag("BOOKSHELF_SCRAPERS", True)

    #: Seconds between requests to one host, for the sources with no published limit.
    request_interval: float = float(os.environ.get("BOOKSHELF_REQUEST_INTERVAL", "2.0"))
    http_timeout: float = float(os.environ.get("BOOKSHELF_HTTP_TIMEOUT", "15.0"))
    cache_days: int = int(os.environ.get("BOOKSHELF_CACHE_DAYS", "30"))

    #: Comps at or above this count are trusted on their own; below it they are blended.
    comps_threshold: int = int(os.environ.get("BOOKSHELF_COMPS_THRESHOLD", "3"))
    #: Shrinkage constant k in w = n / (n + k).
    shrinkage_k: float = float(os.environ.get("BOOKSHELF_SHRINKAGE_K", "1.5"))
    #: How old a comp may be and still count.
    comps_window_days: int = int(os.environ.get("BOOKSHELF_COMPS_WINDOW_DAYS", "365"))


SETTINGS = Settings()
