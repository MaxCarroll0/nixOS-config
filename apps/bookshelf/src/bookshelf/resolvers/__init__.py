"""The identification cascade: try each source in turn, merge what they say.

Every resolver is tried in the order configured, and a resolver that fails or is
degraded is skipped rather than failing the search -- entry must keep working when an
upstream is down, falling through to free text and finally to the manual form.
"""

from __future__ import annotations

import asyncio
import logging
from typing import Protocol

from bookshelf.config import SETTINGS, Settings
from bookshelf.fetch import Fetcher, ProviderUnavailable
from bookshelf.models import Candidate

log = logging.getLogger(__name__)


class Resolver(Protocol):
    """A source that can turn typed text into candidate editions."""

    name: str

    def handles(self, query: str) -> bool:
        """Whether this source is worth asking about this query at all."""
        ...

    async def search(self, query: str, fetcher: Fetcher) -> list[Candidate]:
        """Candidates for the query, best first; an empty list is a normal answer."""
        ...


def _registry() -> dict[str, Resolver]:
    from bookshelf.resolvers import dnb, freetext, isbn, publisher

    return {
        "dnb": dnb.DnbResolver(),
        "isbn": isbn.IsbnResolver(),
        "freetext": freetext.FreeTextResolver(),
        "publisher": publisher.PublisherResolver(),
    }


def _identifiers(candidate: Candidate) -> set[str]:
    """Every handle that could tie this candidate to the same edition from elsewhere."""
    out: set[str] = set()
    if candidate.ismn:
        out.add(f"ismn:{candidate.ismn}")
    if candidate.isbn13:
        out.add(f"isbn:{candidate.isbn13}")
    if candidate.cat_no_norm:
        # The binding is part of the identity: the cloth and paperbound printings of one
        # work share a catalogue number but are different things to own.
        out.add(f"cat:{candidate.cat_no_norm}:{(candidate.binding or '').lower()}")
    return out


def merge(candidates: list[Candidate]) -> list[Candidate]:
    """Collapse candidates that are plainly the same edition, keeping the fuller one.

    Sources describe an edition with different handles -- a library record has the ISMN,
    a publisher's page has only its own catalogue number -- so candidates are grouped by
    *any* shared identifier rather than by one chosen key. Getting this wrong leaves the
    publisher's price attached to a separate half-empty entry instead of to the record
    that has the work on it.
    """
    groups: list[tuple[set[str], Candidate]] = []
    loose: list[Candidate] = []

    # A record with a catalogue number but no binding -- a publisher's price page, say --
    # describes whatever that number sells as, so it is folded into the records that do
    # name a binding rather than standing beside them as a separate choice.
    def is_bindingless(candidate: Candidate) -> bool:
        return bool(candidate.cat_no_norm) and not candidate.binding and not candidate.ismn

    bindingless = [c for c in candidates if is_bindingless(c)]
    rest = [c for c in candidates if not is_bindingless(c)]

    for candidate in rest:
        keys = _identifiers(candidate)
        if not keys:
            loose.append(candidate)
            continue

        # A candidate may bridge two groups that had no handle in common until now.
        touching = [index for index, (known, _) in enumerate(groups) if known & keys]
        if not touching:
            groups.append((keys, candidate))
            continue

        merged_keys = set(keys)
        merged = candidate
        for index in reversed(touching):
            known, other = groups.pop(index)
            merged_keys |= known
            merged = _combine(merged, other)
        groups.append((merged_keys, merged))

    for extra in bindingless:
        absorbed = False
        for index, (keys, candidate) in enumerate(groups):
            if any(key.startswith(f"cat:{extra.cat_no_norm}:") for key in keys):
                groups[index] = (keys, _combine(candidate, extra))
                absorbed = True
        if not absorbed:
            groups.append((_identifiers(extra), extra))

    out = [*(candidate for _, candidate in groups), *loose]
    out.sort(key=lambda c: (-c.score, c.title))
    return out


def _combine(one: Candidate, other: Candidate) -> Candidate:
    """Keep the fuller record, filling its gaps from the thinner one."""
    richer, poorer = (one, other) if _filled(one) >= _filled(other) else (other, one)

    gaps = {
        field: getattr(poorer, field)
        for field in (
            "binding",
            "price_new",
            "price_currency",
            "url",
            "ismn",
            "ismn_hyphenated",
            "isbn13",
            "composer",
            "composer_gnd",
            "publisher",
            "year",
            "pages",
            "extent",
            "edition_statement",
            "description",
        )
        if getattr(richer, field) in (None, "") and getattr(poorer, field) not in (None, "")
    }
    if not richer.contents and poorer.contents:
        gaps["contents"] = poorer.contents
    if not richer.subjects and poorer.subjects:
        gaps["subjects"] = poorer.subjects
    # The better-scoring source stays the headline, but a confirmed match from a second
    # source is worth more than either alone.
    gaps["score"] = min(1.0, max(richer.score, poorer.score) + 0.03)
    return richer.model_copy(update=gaps)


def _filled(candidate: Candidate) -> int:
    return sum(1 for value in candidate.model_dump().values() if value not in (None, [], ""))


async def resolve(
    query: str,
    fetcher: Fetcher,
    settings: Settings = SETTINGS,
) -> tuple[list[Candidate], list[str]]:
    """Run the cascade. Returns the merged candidates and a note per source that failed."""
    registry = _registry()
    problems: list[str] = []
    wanted = [name.strip() for name in settings.resolvers]
    chosen = [
        registry[name]
        for name in wanted
        if name in registry and registry[name].handles(query)
    ]

    async def ask(resolver: Resolver) -> list[Candidate]:
        if fetcher.is_degraded(resolver.name):
            problems.append(f"{resolver.name} skipped: failing recently")
            return []
        try:
            return await resolver.search(query, fetcher)
        except ProviderUnavailable as exc:
            problems.append(str(exc))
            return []
        except Exception:
            log.exception("resolver %s failed on %r", resolver.name, query)
            problems.append(f"{resolver.name}: unexpected error")
            return []

    results = await asyncio.gather(*(ask(resolver) for resolver in chosen))
    return merge([c for batch in results for c in batch]), problems
