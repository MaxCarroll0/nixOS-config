"""One HTTP path for every external source: polite, cached, and health-tracked.

Sources differ wildly in how much traffic they tolerate, and several of the price
sources are scraped rather than offered as APIs, so every request goes through here:
one in flight per host, a floor on the interval between them, a persistent response
cache, and a record of which providers are currently failing.
"""

from __future__ import annotations

import asyncio
import sqlite3
import time
from collections import defaultdict
from dataclasses import dataclass
from types import TracebackType
from urllib.parse import urlsplit

import httpx

from bookshelf.config import SETTINGS, Settings


class ProviderUnavailable(Exception):
    """Raised when a source refuses or fails, so the caller can fall back a tier."""


@dataclass(slots=True)
class _HostGate:
    lock: asyncio.Lock
    last_call: float = 0.0


class Fetcher:
    """Shared HTTP client. One per process; cheap to construct, must be closed."""

    def __init__(self, conn: sqlite3.Connection | None = None, settings: Settings = SETTINGS):
        self._settings = settings
        self._conn = conn
        self._gates: dict[str, _HostGate] = defaultdict(lambda: _HostGate(asyncio.Lock()))
        self._client = httpx.AsyncClient(
            timeout=settings.http_timeout,
            follow_redirects=True,
            headers={
                "User-Agent": settings.user_agent,
                "Accept-Language": "en-GB,en;q=0.9,de;q=0.8",
            },
        )

    @property
    def conn(self) -> sqlite3.Connection | None:
        """The catalogue, when there is one; resolvers learn publisher attributions into it."""
        return self._conn

    async def __aenter__(self) -> Fetcher:
        return self

    async def __aexit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        tb: TracebackType | None,
    ) -> None:
        await self.aclose()

    async def aclose(self) -> None:
        await self._client.aclose()

    def _cached(self, url: str) -> str | None:
        if self._conn is None:
            return None
        row = self._conn.execute(
            """SELECT body FROM http_cache
               WHERE url = ? AND status = 200
                 AND fetched_at > datetime('now', ?)""",
            (url, f"-{self._settings.cache_days} days"),
        ).fetchone()
        return None if row is None else bytes(row["body"]).decode("utf-8", "replace")

    def _store(self, url: str, status: int, body: str) -> None:
        if self._conn is None:
            return
        self._conn.execute(
            """INSERT INTO http_cache (url, body, status, fetched_at)
               VALUES (?, ?, ?, datetime('now'))
               ON CONFLICT (url) DO UPDATE
                 SET body = excluded.body,
                     status = excluded.status,
                     fetched_at = excluded.fetched_at""",
            (url, body.encode("utf-8"), status),
        )

    def note_health(self, provider: str, ok: bool, error: str | None = None) -> None:
        """Record that a provider answered or failed, so a broken one can be skipped."""
        if self._conn is None:
            return
        self._conn.execute(
            """INSERT INTO provider_health (name, ok, last_ok_at, last_err_at, last_error, calls)
               VALUES (?, ?, CASE WHEN ? THEN datetime('now') END,
                             CASE WHEN ? THEN NULL ELSE datetime('now') END, ?, 1)
               ON CONFLICT (name) DO UPDATE SET
                 ok = excluded.ok,
                 last_ok_at = COALESCE(excluded.last_ok_at, provider_health.last_ok_at),
                 last_err_at = COALESCE(excluded.last_err_at, provider_health.last_err_at),
                 last_error = excluded.last_error,
                 calls = provider_health.calls + 1""",
            (provider, int(ok), ok, ok, error),
        )

    def is_degraded(self, provider: str) -> bool:
        """Whether a provider failed last time and should be left alone this run."""
        if self._conn is None:
            return False
        row = self._conn.execute(
            """SELECT ok FROM provider_health
               WHERE name = ? AND ok = 0 AND last_err_at > datetime('now', '-6 hours')""",
            (provider,),
        ).fetchone()
        return row is not None

    async def get(
        self,
        url: str,
        *,
        provider: str,
        params: dict[str, str] | None = None,
        headers: dict[str, str] | None = None,
        use_cache: bool = True,
        interval: float | None = None,
    ) -> str:
        """Fetch a URL as text, from cache when possible, raising ProviderUnavailable."""
        request = self._client.build_request("GET", url, params=params)
        key = str(request.url)

        if use_cache:
            hit = self._cached(key)
            if hit is not None:
                return hit

        host = urlsplit(key).netloc
        gate = self._gates[host]
        floor = self._settings.request_interval if interval is None else interval

        async with gate.lock:
            waited = floor - (time.monotonic() - gate.last_call)
            if waited > 0:
                await asyncio.sleep(waited)
            try:
                response = await self._client.get(url, params=params, headers=headers)
            except httpx.HTTPError as exc:
                self.note_health(provider, False, str(exc))
                raise ProviderUnavailable(f"{provider}: {exc}") from exc
            finally:
                gate.last_call = time.monotonic()

        if response.status_code == 429:
            retry_after = response.headers.get("Retry-After", "?")
            self.note_health(provider, False, f"429, Retry-After={retry_after}")
            raise ProviderUnavailable(f"{provider}: rate limited, retry after {retry_after}")
        if response.status_code >= 400:
            self.note_health(provider, False, f"HTTP {response.status_code}")
            raise ProviderUnavailable(f"{provider}: HTTP {response.status_code}")

        self.note_health(provider, True)
        if use_cache:
            self._store(key, response.status_code, response.text)
        return response.text

    async def get_bytes(
        self, url: str, *, provider: str, interval: float | None = None
    ) -> bytes:
        """Fetch a URL as bytes, for payloads that are not text -- a gzipped sitemap."""
        host = urlsplit(url).netloc
        gate = self._gates[host]
        floor = self._settings.request_interval if interval is None else interval

        async with gate.lock:
            waited = floor - (time.monotonic() - gate.last_call)
            if waited > 0:
                await asyncio.sleep(waited)
            try:
                response = await self._client.get(url)
            except httpx.HTTPError as exc:
                self.note_health(provider, False, str(exc))
                raise ProviderUnavailable(f"{provider}: {exc}") from exc
            finally:
                gate.last_call = time.monotonic()

        if response.status_code >= 400:
            self.note_health(provider, False, f"HTTP {response.status_code}")
            raise ProviderUnavailable(f"{provider}: HTTP {response.status_code}")
        self.note_health(provider, True)
        return response.content

    async def post_form(
        self,
        url: str,
        *,
        provider: str,
        data: dict[str, str],
        headers: dict[str, str] | None = None,
    ) -> str:
        """Uncached form post, used only for the eBay OAuth token exchange."""
        try:
            response = await self._client.post(url, data=data, headers=headers)
            response.raise_for_status()
        except httpx.HTTPError as exc:
            self.note_health(provider, False, str(exc))
            raise ProviderUnavailable(f"{provider}: {exc}") from exc
        self.note_health(provider, True)
        return response.text
