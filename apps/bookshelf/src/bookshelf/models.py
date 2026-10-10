"""Typed values shared across resolvers, storage and templates."""

from __future__ import annotations

from enum import StrEnum
from typing import Annotated

from pydantic import BaseModel, Field


class Condition(StrEnum):
    LIKE_NEW = "like_new"
    GOOD = "good"
    ACCEPTABLE = "acceptable"
    POOR = "poor"


class CoverType(StrEnum):
    SOFT = "soft"
    HARD = "hard"
    CLOTH = "cloth"


class Kind(StrEnum):
    SCORE = "score"
    BOOK = "book"


class Method(StrEnum):
    """How a market value was arrived at; shown to the reader as a badge."""

    COMPS = "comps"
    BLENDED = "blended"
    MODELLED = "modelled"
    MANUAL = "manual"
    UNKNOWN = "unknown"


#: Binding wording as libraries and publishers record it, mapped to a cover type.
BINDING_TO_COVER: dict[str, CoverType] = {
    "broschur": CoverType.SOFT,
    "broschiert": CoverType.SOFT,
    "kartoniert": CoverType.SOFT,
    "paperback": CoverType.SOFT,
    "paperbound": CoverType.SOFT,
    "softcover": CoverType.SOFT,
    "geheftet": CoverType.SOFT,
    "keine bindung": CoverType.SOFT,
    "leinen": CoverType.CLOTH,
    "gewebe": CoverType.CLOTH,
    "linen": CoverType.CLOTH,
    "clothbound": CoverType.CLOTH,
    "cloth": CoverType.CLOTH,
    "halbleinen": CoverType.CLOTH,
    "gebunden": CoverType.HARD,
    "pappband": CoverType.HARD,
    "hardcover": CoverType.HARD,
    "hardback": CoverType.HARD,
    "festeinband": CoverType.HARD,
}


def cover_from_binding(binding: str | None) -> CoverType | None:
    """Guess a cover type from recorded binding wording, so entry can prefill it."""
    if not binding:
        return None
    needle = binding.strip().lower()
    for wording, cover in BINDING_TO_COVER.items():
        if wording in needle:
            return cover
    return None


class ContentItem(BaseModel):
    """One piece inside an edition, as listed by its source."""

    ordinal: int
    label: str
    work_title: str | None = None
    composer: str | None = None
    page_from: int | None = None


class Candidate(BaseModel):
    """A possible edition match, as offered to the reader for selection."""

    source: str
    source_ref: str | None = None
    url: str | None = None

    title: str
    title_en: str | None = None
    composer: str | None = None
    composer_gnd: str | None = None

    publisher: str | None = None
    cat_no: str | None = None
    cat_no_norm: str | None = None
    ismn: str | None = None
    #: The hyphenated form, whose publisher element identifies the house.
    ismn_hyphenated: str | None = None
    isbn13: str | None = None

    uniform_title: str | None = None
    catalogue_label: str | None = None
    music_key: str | None = None
    instrumentation: str | None = None
    gnd_work_id: str | None = None

    edition_statement: str | None = None
    series: str | None = None
    year: int | None = None
    pages: int | None = None
    extent: str | None = None
    binding: str | None = None
    price_new: float | None = None
    price_currency: str | None = None

    #: Publisher's or library's prose about the work; books have it, scores rarely do.
    description: str | None = None
    #: Subject headings, which make a serviceable automatic category.
    subjects: list[str] = Field(default_factory=list)

    kind: Kind = Kind.SCORE
    contents: list[ContentItem] = Field(default_factory=list)
    score: Annotated[float, Field(ge=0.0, le=1.0)] = 0.5

    @property
    def cover_guess(self) -> CoverType | None:
        return cover_from_binding(self.binding)

    @property
    def summary(self) -> str:
        """One line distinguishing this candidate from its siblings in a picker."""
        bits = [b for b in (self.publisher, self.cat_no, self.binding) if b]
        if self.year:
            bits.append(str(self.year))
        if self.extent:
            bits.append(self.extent)
        return " · ".join(bits)


class CompObservation(BaseModel):
    """A used-market listing or sale, from any comps provider."""

    source: str
    price: float
    currency: str
    condition: Condition | None = None
    shipping: float | None = None
    is_sold: bool = False
    url: str | None = None
    external_id: str | None = None


class Estimate(BaseModel):
    """A market-value estimate with the evidence behind it made explicit."""

    value: float | None
    lo: float | None = None
    hi: float | None = None
    method: Method = Method.UNKNOWN
    n_comps: int = 0
    currency: str = "GBP"
    note: str | None = None
