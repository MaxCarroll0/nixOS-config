"""Deutsche Nationalbibliothek, via its SRU interface. No key, no registration.

The music archive (``dnb.dma``) is the only free source that resolves a publisher
catalogue number -- HN, BA, EP, EB -- to a composer, a work, and the binding of that
particular printing. MARC 024 $c is what distinguishes the cloth-bound issue from the
paperbound one, which is the choice the reader is being offered.
"""

from __future__ import annotations

import io
import re
import unicodedata
from dataclasses import dataclass
from typing import Any, Final
from xml.etree import ElementTree

from pymarc import Record, marcxml

from bookshelf import catnum, publishers
from bookshelf.fetch import Fetcher
from bookshelf.models import Candidate, ContentItem, Kind

MUSIC_ARCHIVE: Final = "https://services.dnb.de/sru/dnb.dma"
MAIN_CATALOGUE: Final = "https://services.dnb.de/sru/dnb.dnb"

_SRW: Final = "{http://www.loc.gov/zing/srw/}"
_MARC: Final = "{http://www.loc.gov/MARC21/slim}"

#: Abbreviations that end in a full stop mid-title, which a naive split would break on.
_ABBREVIATIONS: Final[frozenset[str]] = frozenset(
    {
        "op",
        "opus",
        "hob",
        "anh",
        "nr",
        "no",
        "kv",
        "bwv",
        "wwv",
        "wab",
        "hwv",
        "rv",
        "bb",
        "sz",
        "kl",
        "vl",
        "vc",
        "fl",
        "ob",
        "fag",
        "hr",
        "tr",
        "bd",
        "h",
        "s",
        "d",
        "t",
        "a",
        "b",
        "c",
        "f",
        "g",
        "e",
    }
)

_PRICE: Final = re.compile(
    r"(?P<currency>EUR|DM|CHF|GBP|USD|£|\$)\s*(?P<amount>\d+(?:[.,]\d{2})?)",
    re.IGNORECASE,
)

_UNIFORM: Final = re.compile(r"\s*\[\s*Einheitssacht\.?:\s*(?P<uniform>[^\]]+?)\s*\]")


def _records(xml: str) -> list[Record]:
    """Pull the MARC records out of an SRU envelope."""
    root = ElementTree.fromstring(xml)
    out: list[Record] = []
    for holder in root.iter(f"{_SRW}recordData"):
        marc = holder.find(f"{_MARC}record")
        if marc is None:
            continue
        parsed: list[Record] = marcxml.parse_xml_to_array(  # type: ignore[no-untyped-call]
            io.BytesIO(ElementTree.tostring(marc, encoding="utf-8"))
        )
        out.extend(record for record in parsed if record is not None)
    return out


def _nfc(text: str) -> str:
    """Compose accents, so "Dvořák" is one spelling and not two."""
    return unicodedata.normalize("NFC", text)


def _subfield(field: Any, code: str) -> str | None:
    """The first value of a subfield, or None. pymarc is untyped, so this is the seam."""
    values = field.get_subfields(code)
    return str(values[0]).strip() if values else None


def _first(record: Record, tag: str, code: str) -> str | None:
    for field in record.get_fields(tag):
        value = field.get_subfields(code)
        if value and value[0].strip():
            return _nfc(str(value[0]).strip().rstrip(" /:;,"))
    return None


def _gnd(record: Record, tag: str) -> str | None:
    """The GND authority id from a $0, which is the stable identity for a name or work."""
    for field in record.get_fields(tag):
        for raw in field.get_subfields("0"):
            match = re.fullmatch(r"\(DE-588\)(\S+)", str(raw).strip())
            if match:
                return match.group(1)
    return None


def split_contents(note: str) -> list[ContentItem]:
    """Split a MARC 505 contents note into the pieces it lists.

    The note is free text -- ``Scherzo, opus 4 [Einheitssacht.: Scherzi, Kl, op. 4].
    Vier Balladen, opus 10 [...]`` -- so this is best-effort by design: entries are
    separated by a full stop, and an abbreviation list keeps ``op. 4`` and ``Hob. XVII``
    from being read as a boundary. The raw note is kept so nothing is lost.
    """
    uniforms: list[str | None] = []

    def stash(match: re.Match[str]) -> str:
        uniforms.append(match.group("uniform"))
        return "\x00"

    masked = _UNIFORM.sub(stash, _nfc(note.strip()))

    tokens = re.split(r"(?<=\.)\s+", masked)
    pieces: list[str] = []
    buffer: list[str] = []
    for index, token in enumerate(tokens):
        buffer.append(token)
        words = token.rstrip(".").split()
        stem = re.sub(r"[^\w]", "", words[-1]) if words else ""
        if stem.lower() in _ABBREVIATIONS:
            continue
        following = tokens[index + 1] if index + 1 < len(tokens) else None
        # A lower-case continuation means the full stop was an abbreviation we do not
        # know, not the end of an entry.
        if following is not None and following[:1].islower():
            continue
        pieces.append(" ".join(buffer).strip())
        buffer = []
    if buffer:
        pieces.append(" ".join(buffer).strip())

    out: list[ContentItem] = []
    marker = 0
    for piece in pieces:
        label = piece.rstrip(". ").strip()
        uniform: str | None = None
        while "\x00" in label:
            uniform = uniforms[marker] if marker < len(uniforms) else None
            marker += 1
            label = label.replace("\x00", "", 1).strip()
        label = re.sub(r"\s{2,}", " ", label).strip(" .")
        if not label:
            continue
        out.append(
            ContentItem(ordinal=len(out) + 1, label=label, work_title=uniform or None)
        )
    return out


def _qualifier(raw: str) -> tuple[str | None, float | None, str | None]:
    """Split a MARC qualifier into its binding wording and any list price it carries."""
    text = str(raw).strip()
    price_match = _PRICE.search(text)

    # Catalogue records sometimes run the identifier straight into the wording, as in
    # "979-0-006-53071-7Broschur".
    head = re.sub(r"^[\d\sX-]{8,}", "", text.split(":")[0]).strip()
    binding: str | None = head or None
    if binding and (
        re.fullmatch(r"[\d\sXx.-]+", binding) or catnum.looks_like_catalogue_number(binding)
    ):
        binding = None

    if price_match is None:
        return binding, None, None
    symbols = {"£": "GBP", "$": "USD"}
    raw_currency = price_match.group("currency")
    currency = symbols.get(raw_currency, raw_currency.upper())
    amount = float(price_match.group("amount").replace(",", "."))
    return binding, amount, currency


def _pages(extent: str | None) -> int | None:
    if not extent:
        return None
    match = re.search(r"(\d+)\s*(?:S\.|Seiten|p\.|pages)", extent)
    return int(match.group(1)) if match else None


def _year(record: Record) -> int | None:
    for tag, code in (("264", "c"), ("260", "c")):
        raw = _first(record, tag, code)
        if raw:
            match = re.search(r"(1[5-9]\d{2}|20\d{2})", raw)
            if match:
                return int(match.group(1))
    return None


@dataclass(frozen=True, slots=True)
class _Issue:
    """One physical issue of an edition: its own binding, identifier and price."""

    binding: str | None = None
    ismn: str | None = None
    ismn_hyphenated: str | None = None
    isbn13: str | None = None
    price: float | None = None
    currency: str | None = None


def _issues(record: Record) -> list[_Issue]:
    """The separately-published issues a record describes, one per binding.

    A record often lists the paperbound and the cloth-bound printing side by side as
    repeated 024 or 020 fields, each with its own qualifier and sometimes its own
    identifier. Those are the alternatives the reader is choosing between, so each
    becomes its own candidate rather than being collapsed into the first one found.
    """
    found: list[_Issue] = []
    for tag in ("024", "020"):
        for field in record.get_fields(tag):
            identifier = _subfield(field, "a")
            digits = re.sub(r"[^0-9X]", "", identifier.upper()) if identifier else ""
            hyphenated = _subfield(field, "9")
            qualifier = _subfield(field, "c")
            binding, price, currency = (
                _qualifier(str(qualifier)) if qualifier else (None, None, None)
            )
            found.append(
                _Issue(
                    binding=binding,
                    ismn=digits if digits.startswith("9790") else None,
                    ismn_hyphenated=str(hyphenated).strip() if hyphenated else None,
                    isbn13=digits if len(digits) == 13 and not digits.startswith("9790") else None,
                    price=price,
                    currency=currency,
                )
            )

    # Repeated fields for the same binding are cataloguing noise, not real alternatives.
    merged: dict[str | None, _Issue] = {}
    for issue in found:
        existing = merged.get(issue.binding)
        if existing is None:
            merged[issue.binding] = issue
            continue
        merged[issue.binding] = _Issue(
            binding=issue.binding,
            ismn=existing.ismn or issue.ismn,
            ismn_hyphenated=existing.ismn_hyphenated or issue.ismn_hyphenated,
            isbn13=existing.isbn13 or issue.isbn13,
            price=existing.price if existing.price is not None else issue.price,
            currency=existing.currency or issue.currency,
        )

    # A binding-less entry adds nothing once a named binding is known.
    if len(merged) > 1 and None in merged:
        bare = merged.pop(None)
        if bare.ismn or bare.isbn13:
            for key, issue in list(merged.items()):
                if issue.ismn is None and issue.isbn13 is None:
                    merged[key] = _Issue(
                        binding=issue.binding,
                        ismn=bare.ismn,
                        ismn_hyphenated=bare.ismn_hyphenated,
                        isbn13=bare.isbn13,
                        price=issue.price if issue.price is not None else bare.price,
                        currency=issue.currency or bare.currency,
                    )

    return list(merged.values()) or [_Issue()]


def to_candidates(record: Record, source: str) -> list[Candidate]:
    """Turn one MARC record into a candidate per issue it describes."""
    title = _first(record, "245", "a") or _first(record, "240", "a") or "(untitled)"
    subtitle = _first(record, "245", "b")
    title_en = _first(record, "246", "a")
    if title_en is None and subtitle and re.match(r"^\s*=", subtitle):
        title_en = subtitle.lstrip("= ").strip()

    cat_no_raw: str | None = None
    for field in record.get_fields("028"):
        cat_no_raw = _subfield(field, "a")
        if cat_no_raw:
            break
    parsed = catnum.parse(cat_no_raw) if cat_no_raw else None

    issues = _issues(record)

    instrumentation = None
    for field in record.get_fields("240"):
        parts = [str(v).strip() for v in field.get_subfields("m")]
        if parts:
            instrumentation = ", ".join(parts)
            break

    contents: list[ContentItem] = []
    for field in record.get_fields("505"):
        for raw in field.get_subfields("a"):
            contents.extend(split_contents(str(raw)))
    for index, item in enumerate(contents, start=1):
        item.ordinal = index

    extent = _first(record, "300", "a")
    leader = str(record.leader)
    kind = Kind.SCORE if len(leader) > 6 and leader[6] in {"c", "d", "j"} else Kind.BOOK

    shared = Candidate(
        source=source,
        source_ref=_first(record, "016", "a") or (record["001"].data if record["001"] else None),
        title=title,
        title_en=title_en,
        composer=_first(record, "100", "a") or _first(record, "110", "a"),
        composer_gnd=_gnd(record, "100"),
        publisher=_first(record, "264", "b") or _first(record, "260", "b"),
        cat_no=str(parsed) if parsed else cat_no_raw,
        cat_no_norm=parsed.canonical if parsed else None,
        uniform_title=_first(record, "240", "a"),
        catalogue_label=_first(record, "240", "n"),
        music_key=_first(record, "240", "r"),
        instrumentation=instrumentation,
        gnd_work_id=_gnd(record, "240"),
        edition_statement=_first(record, "250", "a"),
        series=_first(record, "490", "a") or _first(record, "830", "a"),
        year=_year(record),
        pages=_pages(extent),
        extent=extent,
        kind=kind,
        contents=contents,
        score=0.95 if parsed else 0.7,
    )

    return [
        shared.model_copy(
            update={
                "ismn": issue.ismn,
                "ismn_hyphenated": issue.ismn_hyphenated,
                "isbn13": issue.isbn13,
                "binding": issue.binding,
                "price_new": issue.price,
                "price_currency": issue.currency,
            }
        )
        for issue in issues
    ]


def _quote(value: str) -> str:
    """CQL has no escape for a double quote, so a value carrying one cannot be sent."""
    return value.replace('"', "")


def _confirm_publisher(found: list[Candidate], guard: str | None) -> list[Candidate]:
    """Drop results whose publisher is not the one that was asked for.

    A word index matches a word anywhere in a record, so searching a bare plate number
    narrowed by "durand" still turns up another house's edition that merely mentions
    Durand somewhere. Since the number alone carries no publisher, an unconfirmed hit is
    worse than none: it would be filed under the wrong house and valued as it.
    """
    if not guard:
        return found

    from bookshelf.publishers import normalise_name

    wanted = normalise_name(guard)
    if not wanted:
        return found

    confirmed = [
        candidate
        for candidate in found
        if candidate.publisher and _names_agree(normalise_name(candidate.publisher), wanted)
    ]
    return confirmed


def _names_agree(found: str, wanted: str) -> bool:
    """Whether two normalised publisher names plausibly denote the same house."""
    if not found or not wanted:
        return False
    if found == wanted or found.startswith(wanted) or wanted.startswith(found):
        return True
    # "boosey hawkes" against "boosey": any shared word is enough once the noise words
    # that every imprint carries have already been stripped out.
    return bool(set(found.split()) & set(wanted.split()))


@dataclass(frozen=True, slots=True)
class Catalogue:
    """One SRU catalogue, with the index names it happens to use."""

    name: str
    endpoint: str
    number_index: str
    word_index: str
    schema: str = "MARC21-xml"
    #: Seconds to leave between requests; neither service publishes a limit.
    interval: float = 1.0

    def number_query(self, spellings: list[str], guard: str | None) -> str:
        clause = " or ".join(f'{self.number_index}="{_quote(s)}"' for s in spellings)
        if not guard:
            return clause
        # A bare plate number collides across publishers -- 18371 is a Durand plate
        # number and also a law textbook's order number -- so it has to be pinned down
        # by whatever words were typed alongside it.
        words = [word for word in re.split(r"\s+", guard.strip()) if len(word) > 1][:3]
        if not words:
            return clause
        narrowing = " and ".join(f'{self.word_index}="{_quote(word)}"' for word in words)
        return f"({clause}) and {narrowing}"

    def words_query(self, words: list[str]) -> str:
        return " and ".join(f'{self.word_index}="{_quote(word)}"' for word in words)


#: German national bibliography, music archive. Best for the German publishers'
#: catalogue numbers, and the only source that records binding.
DNB_MUSIC = Catalogue("dnb", MUSIC_ARCHIVE, "NUM", "WOE")

#: The same for books rather than scores.
DNB_BOOKS = Catalogue("dnb", MAIN_CATALOGUE, "NUM", "WOE")

#: German union catalogue. Far broader holdings of foreign imprints -- Durand, Kalmus,
#: Alfred, Ricordi -- which the national bibliography barely has.
K10PLUS = Catalogue(
    "k10plus",
    "https://sru.k10plus.de/opac-de-627",
    "pica.num",
    "pica.all",
    schema="marcxml",
)


class DnbResolver:
    """Resolves catalogue numbers and identifiers against the library SRU catalogues."""

    name = "dnb"

    def handles(self, query: str) -> bool:
        return True

    async def search(self, query: str, fetcher: Fetcher) -> list[Candidate]:
        number = catnum.parse(query)
        if number is not None and catnum.looks_like_catalogue_number(query):
            # Whichever house this prefix has been seen to belong to may file other
            # editions under a different prefix, or none; offer those spellings too.
            prefixes: tuple[str, ...] = ()
            conn = fetcher.conn
            if conn is not None:
                attribution = publishers.for_number(conn, number.prefix)
                if attribution is not None:
                    prefixes = publishers.prefixes_for(conn, attribution.publisher)
                elif number.qualifier:
                    for name in publishers.matching_names(conn, number.qualifier):
                        prefixes = publishers.prefixes_for(conn, name)
                        if prefixes:
                            break

            out = await self._by_number(number, prefixes, fetcher)
            if out:
                return out

            # "henle 1234" has the shape of a prefixed number and was read as one. If
            # that prefix is not one any record has ever used, the leading word was
            # probably the publisher's name, so try it the other way round.
            if conn is not None and publishers.for_number(conn, number.prefix) is None:
                alternative = catnum.as_qualified(number)
                if alternative is not None:
                    names = publishers.matching_names(conn, alternative.qualifier or "")
                    prefixes = publishers.prefixes_for(conn, names[0]) if names else ()
                    out = await self._by_number(alternative, prefixes, fetcher)
                    if out:
                        return out

        digits = re.sub(r"[^0-9X]", "", query.upper())
        if len(digits) in (10, 13):
            out = []
            for catalogue in (DNB_MUSIC, DNB_BOOKS, K10PLUS):
                out += await self._query(
                    catalogue, catalogue.number_query([digits, query.strip()], None), fetcher
                )
                if out:
                    break
            return out

        return []

    async def _by_number(
        self,
        number: catnum.CatalogueNumber,
        prefixes: tuple[str, ...],
        fetcher: Fetcher,
    ) -> list[Candidate]:
        """Ask each catalogue for every spelling of a number, stopping at the first hit."""
        spellings = catnum.variants(number, prefixes)
        # Only an indistinctive number needs narrowing; a prefixed one stands alone, and
        # narrowing it would drop records that spell the publisher differently.
        guard = number.qualifier if number.prefixless else None

        for catalogue in (DNB_MUSIC, K10PLUS):
            found = await self._query(
                catalogue, catalogue.number_query(spellings, guard), fetcher
            )
            found = _confirm_publisher(found, guard)
            if found:
                return found
        return []

    async def _query(self, catalogue: Catalogue, cql: str, fetcher: Fetcher) -> list[Candidate]:
        xml = await fetcher.get(
            catalogue.endpoint,
            provider=catalogue.name,
            params={
                "version": "1.1",
                "operation": "searchRetrieve",
                "query": cql,
                "recordSchema": catalogue.schema,
                "maximumRecords": "20",
            },
            interval=catalogue.interval,
        )
        found = [
            candidate
            for record in _records(xml)
            for candidate in to_candidates(record, catalogue.name)
        ]
        # Every record pairs a number and an ISMN with a publisher, which is where the
        # prefix-to-publisher mapping comes from in the first place.
        if fetcher.conn is not None and found:
            publishers.seed_from_candidates(fetcher.conn, list(found))
        return found

    async def free_text(self, query: str, fetcher: Fetcher) -> list[Candidate]:
        """Composer, title and publisher words -- the route that works for the French
        and American houses, whose plate numbers libraries do not index."""
        words = [word for word in re.split(r"\s+", query.strip()) if len(word) > 1][:6]
        if not words:
            return []

        out: list[Candidate] = []
        for catalogue in (DNB_MUSIC, K10PLUS):
            out += await self._query(catalogue, catalogue.words_query(words), fetcher)
        for candidate in out:
            candidate.score = 0.45
        return out
