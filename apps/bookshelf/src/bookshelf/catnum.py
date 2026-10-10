"""Catalogue numbers: pure syntax, with no knowledge of any particular publisher.

Publishers number editions in mutually inconsistent ways, and library records then store
those numbers inconsistently again. All of these are real, taken from MARC 028:
``HN 1234``, ``EP 11616``, ``EP20024``, ``Bestellnummer EP20037``, ``BA05583-90``,
``ChB 5394``, ``ED 20869D``, ``0827KK``, ``BB 1817``, ``27.317/50``, and bare ``18371``.

Rather than keep a table of who spells things how, this module recognises the three
*shapes* that cover all of them -- letters then digits, digits then letters, and no
letters at all -- and expands a typed number into every plausible spelling. Which
publisher a prefix belongs to is not guessed here: it is learned from catalogue records,
in :mod:`bookshelf.publishers`.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Final

#: Widths publishers zero-pad the numeric part to, beyond the width that was typed.
_PAD_WIDTHS: Final[tuple[int, ...]] = (4, 5, 6)

#: Noise words library records put in front of the number itself.
_NOISE: Final[re.Pattern[str]] = re.compile(
    r"^(?:bestellnummer|best\.-?nr\.?|verlagsnummer|verl\.-?nr\.?|plate|pl\.-?nr\.?)\s*",
    re.IGNORECASE,
)

#: Letters then digits, with an optional trailing part: "HN 1234", "BA05583-90".
_LEADING: Final[re.Pattern[str]] = re.compile(
    r"""^\s*
    (?P<prefix>[A-Za-z]{1,5}(?:\.[A-Za-z]\.?){0,3})   # HN, ChB, A.J.B.
    [\s.\-]*
    (?P<digits>\d{1,7})
    (?P<suffix>(?:[\s.\-]*[A-Za-z0-9]{1,6})*?)
    \s*$""",
    re.VERBOSE,
)

#: Digits then letters, as Kalmus prints them: "0827KK".
_TRAILING: Final[re.Pattern[str]] = re.compile(
    r"^\s*(?P<digits>\d{3,7})(?P<prefix>[A-Za-z]{1,4})\s*$"
)

#: A bare plate number. Some houses group thousands with a dot and name a part after a
#: slash, as in "27.317/50".
_BARE: Final[re.Pattern[str]] = re.compile(
    r"^\s*(?P<digits>\d{1,3}(?:\.\d{3})+|\d{3,6})(?:\s*/\s*(?P<part>\d{1,3}))?\s*$"
)

#: Leading words, which are a constraint on the search rather than part of the number.
_QUALIFIED: Final[re.Pattern[str]] = re.compile(
    r"^\s*(?P<words>(?:[^\W\d_][\w&.'-]*\s+){1,4})(?P<number>[\dA-Za-z][\w.\-/]*)\s*$",
    re.UNICODE,
)


@dataclass(frozen=True, slots=True)
class CatalogueNumber:
    """A catalogue number, split so it can be rendered the way any source spells it."""

    digits: str
    prefix: str = ""
    suffix: str = ""
    #: True when the letters follow the digits rather than leading them.
    trailing: bool = False
    #: Words typed alongside the number, used to narrow an otherwise ambiguous search.
    qualifier: str | None = None

    @property
    def prefixless(self) -> bool:
        return not self.prefix

    @property
    def distinctive(self) -> bool:
        """Whether this number means anything on its own.

        A letter prefix makes a number distinctive enough to search for by itself. A
        bare plate number does not: ``18371`` is a Durand plate number and also some
        publisher's book order number, so searching it alone returns nonsense. Such a
        number needs either a qualifier or a publisher supplied from elsewhere.
        """
        return bool(self.prefix) or self.qualifier is not None

    @property
    def canonical(self) -> str:
        """Unpadded uppercase key, for storage and deduplication."""
        digits = self.digits.lstrip("0") or "0"
        if self.prefixless:
            # A bare number is unique only within one publisher's own catalogue, so the
            # qualifier -- when there was one -- is part of the key.
            stem = re.sub(r"[^A-Z0-9]", "", (self.qualifier or "").upper())[:4]
            return f"{stem}-{digits}{self.suffix}" if stem else f"{digits}{self.suffix}"
        return f"{re.sub(r'[^A-Z0-9]', '', self.prefix)}{digits}{self.suffix}"

    def __str__(self) -> str:
        if self.prefixless:
            return f"{self.digits}{self.suffix}"
        if self.trailing:
            return f"{self.digits}{self.prefix}{self.suffix}"
        return f"{self.prefix} {self.digits}{self.suffix}"


def _bare(raw: str, qualifier: str | None = None) -> CatalogueNumber | None:
    """Read a bare plate number, dropping the thousands dots publishers print."""
    match = _BARE.match(raw)
    if match is None:
        return None
    part = match.group("part")
    return CatalogueNumber(
        digits=match.group("digits").replace(".", ""),
        suffix=f"-{part}" if part else "",
        qualifier=qualifier,
    )


def _trailing(raw: str, qualifier: str | None = None) -> CatalogueNumber | None:
    match = _TRAILING.match(raw)
    if match is None:
        return None
    return CatalogueNumber(
        prefix=match.group("prefix").upper(),
        digits=match.group("digits"),
        trailing=True,
        qualifier=qualifier,
    )


def _leading(raw: str, qualifier: str | None = None) -> CatalogueNumber | None:
    match = _LEADING.match(raw)
    if match is None:
        return None
    suffix = re.sub(r"[\s.]+", "", match.group("suffix")).upper()
    if suffix and not suffix.startswith("-") and suffix[0].isdigit():
        suffix = f"-{suffix}"
    return CatalogueNumber(
        prefix=match.group("prefix").upper().rstrip("."),
        digits=match.group("digits"),
        suffix=suffix,
        qualifier=qualifier,
    )


#: Order matters: a bare number must not be read as a prefixed one, and vice versa.
_READERS = (_bare, _trailing, _leading)


def parse(raw: str) -> CatalogueNumber | None:
    """Split a typed or recorded catalogue number, or return None if it is not one.

    Words in front of the number -- ``durand 18371``, ``boosey 16902`` -- are kept as a
    qualifier rather than being matched against a list of publishers. Whatever they are,
    handing them to the catalogue's word index is what makes a bare number findable.
    """
    cleaned = _NOISE.sub("", raw.strip())
    # A record may carry a price after the number: "BVE08076* : EUR 30.00".
    cleaned = re.split(r"[:*]", cleaned, maxsplit=1)[0].strip()
    # A parenthesised role annotates the number rather than belonging to it.
    cleaned = re.sub(r"\s*\([^)]*\)\s*$", "", cleaned).strip()
    if not cleaned:
        return None

    # The whole string first: "BA 5000" is a prefixed number, not the word "BA" in
    # front of a bare one. Only input that cannot be read as a number at all -- because
    # the leading word is too long to be a prefix -- is treated as qualified.
    for reader in _READERS:
        found = reader(cleaned)
        if found is not None:
            return found

    qualified = _QUALIFIED.match(cleaned)
    if qualified is not None:
        words = qualified.group("words").strip()
        number = qualified.group("number")
        for reader in _READERS:
            found = reader(number, words)
            if found is not None:
                return found
    return None


def as_qualified(number: CatalogueNumber) -> CatalogueNumber | None:
    """Re-read a short prefix as a publisher's name instead.

    "henle 1234" is indistinguishable by shape from a prefixed number, so it is read as
    one. A caller that can check the prefix against publishers actually seen in records
    -- and finds nothing -- can ask for the other reading instead of guessing here.
    """
    if number.prefixless or number.trailing or number.qualifier is not None:
        return None
    return CatalogueNumber(digits=number.digits, suffix=number.suffix, qualifier=number.prefix)


def _group_thousands(digits: str) -> str:
    """Render 27317 as 27.317, which is how some houses print a plate number."""
    if len(digits) <= 3:
        return digits
    return f"{digits[:-3]}.{digits[-3:]}"


def variants(number: CatalogueNumber, prefixes: tuple[str, ...] = ()) -> list[str]:
    """Every spelling of a number worth searching, most-likely first.

    Both separator styles crossed with the zero-paddings publishers actually use, so
    ``BA 5000`` also looks for ``BA05000``, which is how Bärenreiter is filed. Any
    ``prefixes`` passed in -- learned from records for whichever publisher a qualifier
    points at -- are offered too, which is what finds the editions a house files under a
    prefix when the number was typed bare.
    """
    bare = number.digits.lstrip("0") or "0"
    slashed = number.suffix.replace("-", "/", 1) if number.suffix else ""
    out: list[str] = []

    def offer(value: str) -> None:
        if value and value not in out:
            out.append(value)

    if number.prefixless:
        for digits in (number.digits, bare, _group_thousands(bare)):
            offer(f"{digits}{slashed}")
            if slashed:
                offer(digits)
    elif number.trailing:
        for digits in (number.digits, bare):
            offer(f"{digits}{number.prefix}{number.suffix}")
    else:
        paddings = [number.digits, bare]
        paddings += [bare.zfill(width) for width in _PAD_WIDTHS if len(bare) <= width]
        for digits in paddings:
            for separator in (" ", ""):
                offer(f"{number.prefix}{separator}{digits}{number.suffix}")

    for prefix in prefixes:
        if prefix == number.prefix:
            continue
        offer(f"{prefix} {bare}")
        offer(f"{prefix}{bare}")
    if prefixes and not number.prefixless:
        # The same house may also file editions with no prefix at all.
        offer(bare)

    return out


def looks_like_catalogue_number(raw: str) -> bool:
    """Whether to try the catalogue-number resolver, before falling back to free text."""
    number = parse(raw)
    if number is None:
        return False
    # An ISBN or ISMN is a different register and belongs to another resolver.
    if len(re.sub(r"\D", "", raw)) in (10, 13):
        return False
    # "Op 27" references a work, not an edition of one.
    return len(number.digits) >= 3 and number.distinctive
