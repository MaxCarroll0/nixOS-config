# bookshelf

A catalogue of books and sheet music: what is owned, what is inside each volume, and
what it is worth.

Served from a Raspberry Pi over a Tailscale tailnet and used mostly from a phone.

## What it does

**Identification.** Type a publisher catalogue number (`HN 1234`, `BA05583`,
`EP20024`, `EB 9478`, `ED 20869D`), an ISBN or ISMN, or just a composer and title.
The cascade asks the Deutsche Nationalbibliothek music archive and the K10plus union
catalogue — both free, neither needing a key — then Open Library and Google Books for
books, then the publisher's own product page for a current list price. Where one
catalogue number covers several printings, each binding is offered as its own choice,
which is the cloth-versus-paperbound distinction. Nothing resolves? A manual form,
prefilled with whatever was typed, always takes the entry anyway.

Catalogue numbers are recorded wildly inconsistently, so a typed number is expanded
into every plausible spelling before anything is searched: `BA 5000` is also looked for
as `BA05000`, which is how Bärenreiter is actually filed.

Which publisher a prefix belongs to is **learned, not hardcoded**. Every record pairs a
number and an ISMN with a publisher, so the mapping builds itself from use and covers
whatever is in the collection rather than whatever somebody thought to list.

**Contents.** MARC contents notes are parsed into the individual pieces in a volume,
and work lists and movement hierarchies come from Open Opus and MusicBrainz. Searching
a single movement finds the volume it is bound in.

**Valuation.** Two figures, never conflated. The *cost basis* is what was paid, or the
publisher's list price converted and indexed for inflation when there is no receipt.
The *market value* is what it would fetch second-hand now — blended from observed used
listings and a fitted model in proportion to how much evidence there is, and always
reported with an interval and a badge saying which. See `src/bookshelf/valuation/`.

**Queries.** A read-only SQL console for anything the browse pages do not anticipate.

## Running it

```bash
nix develop              # or: direnv allow
python -m bookshelf --port 8099 --database .dev/bookshelf.db
python -m bookshelf --refresh --database .dev/bookshelf.db
```

`BOOKSHELF_FAKE_IDENTITY` stands in for the identity header the reverse proxy sets.

```bash
nix flake check          # mypy --strict and the tests
nix build .#bookshelf
```

## Configuration

Everything comes from the environment; see `src/bookshelf/config.py`. The ones that
matter: `BOOKSHELF_DATABASE`, `BOOKSHELF_CURRENCY`, `BOOKSHELF_RESOLVERS`,
`BOOKSHELF_COMPS_PROVIDERS`, `BOOKSHELF_SCRAPERS`, and the eBay and Google Books
credentials.

## A note on the comps providers

eBay's Browse API is sanctioned and needs a free developer key. The AbeBooks and Amazon
providers scrape pages those sites do not offer an API for; that breaks periodically and
is against their terms, so they are off unless `BOOKSHELF_SCRAPERS` is set, run only in
the background job, rate-limited, and skipped once they start failing. A provider going
dark costs a valuation one tier of confidence, not an error.
