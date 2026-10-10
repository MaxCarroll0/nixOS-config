"""Filling in works and movements, so a volume's contents can be browsed offline."""

from __future__ import annotations

from bookshelf.enrich.musicbrainz import movements_for
from bookshelf.enrich.openopus import works_for

__all__ = ["movements_for", "works_for"]
