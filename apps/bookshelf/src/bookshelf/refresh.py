"""The background job: refresh prices and comps, refit the model, revalue every copy.

Everything expensive lives here rather than in a request. It is the only place that
touches the scraped providers, and the only place that imports a scientific stack, so
the web service stays small and no page load ever waits on an external site.
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import sqlite3
from dataclasses import dataclass, field
from datetime import date
from typing import Any

from bookshelf import comps, db, enrich, store
from bookshelf.config import SETTINGS, Settings
from bookshelf.fetch import Fetcher, ProviderUnavailable
from bookshelf.models import CompObservation, Estimate, Method
from bookshelf.money import Money
from bookshelf.valuation import estimate_market, load_coefficients

log = logging.getLogger("bookshelf.refresh")


@dataclass
class Report:
    """What a refresh did, so the unit's log says something useful."""

    editions_checked: int = 0
    comps_added: int = 0
    movements_added: int = 0
    valuations_written: int = 0
    problems: list[str] = field(default_factory=list)
    fit: dict[str, Any] = field(default_factory=dict)

    def summary(self) -> str:
        bits = [
            f"{self.editions_checked} editions",
            f"{self.comps_added} new comps",
            f"{self.movements_added} movements",
            f"{self.valuations_written} valuations",
        ]
        if self.fit:
            bits.append(
                "model refitted" if self.fit.get("fitted") else f"model: {self.fit.get('using')}"
            )
        if self.problems:
            bits.append(f"{len(self.problems)} provider problems")
        return ", ".join(bits)


async def refresh_comps(
    conn: sqlite3.Connection,
    fetcher: Fetcher,
    report: Report,
    *,
    stale_days: int = 14,
    limit: int = 50,
    settings: Settings = SETTINGS,
) -> None:
    """Fetch used listings for editions whose comps are missing or old."""
    rows = db.all_rows(
        conn,
        """
        SELECT e.id, e.title, e.isbn13, e.ismn, e.cat_no_raw, p.name AS composer,
               MAX(c.observed_at) AS last_seen
        FROM edition e
        JOIN copy cp ON cp.edition_id = e.id
        LEFT JOIN person p ON p.id = e.person_id
        LEFT JOIN comp c ON c.edition_id = e.id
        GROUP BY e.id
        HAVING last_seen IS NULL OR last_seen < datetime('now', ?)
        ORDER BY last_seen IS NOT NULL, last_seen
        LIMIT ?
        """,
        f"-{stale_days} days",
        limit,
    )

    for row in rows:
        report.editions_checked += 1
        title = " ".join(
            part for part in (row["composer"], row["title"], row["cat_no_raw"]) if part
        )
        identifier = row["isbn13"] or row["ismn"]

        observations, problems = await comps.gather(
            title=title, identifier=identifier, fetcher=fetcher, settings=settings
        )
        report.problems += problems
        report.comps_added += _store_comps(conn, int(row["id"]), observations)


def _store_comps(
    conn: sqlite3.Connection, edition_id: int, observations: list[CompObservation]
) -> int:
    added = 0
    for observation in observations:
        cursor = conn.execute(
            """INSERT INTO comp
                 (edition_id, source, condition, price, shipping, currency,
                  is_sold, url, external_id)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT (source, external_id) DO UPDATE SET
                 price = excluded.price,
                 shipping = excluded.shipping,
                 observed_at = datetime('now')""",
            (
                edition_id,
                observation.source,
                observation.condition.value if observation.condition else None,
                observation.price,
                observation.shipping,
                observation.currency,
                int(observation.is_sold),
                observation.url,
                observation.external_id,
            ),
        )
        added += 1 if cursor.rowcount else 0
    return added


async def enrich_contents(
    conn: sqlite3.Connection,
    fetcher: Fetcher,
    report: Report,
    *,
    limit: int = 20,
) -> None:
    """Fill in movement lists for works that have none yet.

    Capped per run because MusicBrainz asks for one request a second and there is no
    hurry: a volume's movements do not change.
    """
    rows = db.all_rows(
        conn,
        """SELECT DISTINCT ec.edition_id
           FROM edition_content ec
           JOIN work w ON w.id = ec.work_id
           JOIN copy c ON c.edition_id = ec.edition_id
           WHERE w.mb_work_id IS NULL
             AND NOT EXISTS (SELECT 1 FROM movement m WHERE m.work_id = w.id)
           LIMIT ?""",
        limit,
    )

    for row in rows:
        try:
            report.movements_added += await enrich.enrich_edition(
                conn, int(row["edition_id"]), fetcher
            )
        except ProviderUnavailable as exc:
            report.problems.append(str(exc))
            # One refusal means the service is busy; the rest of the run would fare
            # no better, and it will be retried tomorrow.
            break


async def cost_basis(
    conn: sqlite3.Connection, row: sqlite3.Row, money: Money, currency: str
) -> tuple[float | None, str | None]:
    """What a copy cost: what was paid, else the price new restated into today's money.

    A price paid is a fact and is used as it stands. Without one, the publisher's list
    price is the next best thing -- but a 1985 Deutsche Mark price is not comparable to
    a 2026 one, so it is converted and then indexed by consumer prices.
    """
    if row["price_paid"] is not None:
        paid = float(row["price_paid"])
        source_currency = str(row["currency"] or currency)
        if source_currency == currency:
            return paid, "paid"
        try:
            return round(await money.convert(paid, source_currency, currency), 2), "paid"
        except ProviderUnavailable:
            return paid, f"paid ({source_currency}, unconverted)"

    price_new = store.latest_price_new(conn, int(row["edition_id"]))
    if price_new is None:
        return None, None

    amount = float(price_new["price"])
    source_currency = str(price_new["currency"])
    observed_year = int(str(price_new["observed_at"])[:4])

    try:
        if source_currency != currency:
            amount = await money.convert(amount, source_currency, currency)
    except ProviderUnavailable:
        return None, None

    this_year = date.today().year
    if observed_year < this_year:
        indexed = await money.index(amount, observed_year, this_year)
        if indexed is not None:
            return round(indexed, 2), f"list price {observed_year}, indexed"
    return round(amount, 2), f"list price {observed_year}"


async def revalue(
    conn: sqlite3.Connection,
    fetcher: Fetcher,
    report: Report,
    *,
    settings: Settings = SETTINGS,
) -> None:
    """Write a fresh valuation snapshot for every copy."""
    coefficients = load_coefficients(conn)
    money = Money(fetcher)
    currency = settings.currency

    for row in store.shelf_rows(conn):
        copy_id = int(row["copy_id"])
        # An explicit override is the reader's decision and is never recomputed over.
        if row["method"] == Method.MANUAL.value:
            continue

        observations = _comps_for(conn, int(row["edition_id"]), settings)
        price_new = store.latest_price_new(conn, int(row["edition_id"]))
        new_amount: float | None = None
        if price_new is not None:
            try:
                new_amount = await money.convert(
                    float(price_new["price"]), str(price_new["currency"]), currency
                )
            except ProviderUnavailable as exc:
                report.problems.append(str(exc))

        market: Estimate = estimate_market(
            comps=observations,
            price_new=new_amount,
            features=store.features_for(row),
            coefficients=coefficients,
            currency=currency,
            settings=settings,
        )
        basis, method = await cost_basis(conn, row, money, currency)
        store.record_valuation(
            conn, copy_id=copy_id, cost_basis=basis, cost_method=method, market=market
        )
        report.valuations_written += 1


def _comps_for(
    conn: sqlite3.Connection, edition_id: int, settings: Settings
) -> list[CompObservation]:
    rows = db.all_rows(
        conn,
        """SELECT source, price, shipping, currency, condition, is_sold, url, external_id
           FROM comp WHERE edition_id = ? AND observed_at > datetime('now', ?)""",
        edition_id,
        f"-{settings.comps_window_days} days",
    )
    return [
        CompObservation(
            source=str(row["source"]),
            price=float(row["price"]),
            shipping=float(row["shipping"]) if row["shipping"] is not None else None,
            currency=str(row["currency"]),
            condition=row["condition"],
            is_sold=bool(row["is_sold"]),
            url=row["url"],
            external_id=row["external_id"],
        )
        for row in rows
    ]


async def run(
    database: str,
    *,
    skip_comps: bool = False,
    skip_fit: bool = False,
    settings: Settings = SETTINGS,
) -> Report:
    """One full pass: comps, then refit, then revalue."""
    report = Report()
    conn = db.connect(database)
    try:
        async with Fetcher(conn, settings) as fetcher:
            if not skip_comps:
                await refresh_comps(conn, fetcher, report, settings=settings)
                await enrich_contents(conn, fetcher, report)

            if not skip_fit:
                # Imported here and nowhere else: this pulls in scipy, and the web
                # service must never pay for it.
                from bookshelf.valuation import model

                report.fit = model.refit(conn, settings.comps_window_days)

            await revalue(conn, fetcher, report, settings=settings)
    finally:
        conn.execute("PRAGMA optimize")
        conn.close()
    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Refresh prices and revalue the catalogue")
    parser.add_argument("--database", default=SETTINGS.database)
    parser.add_argument("--skip-comps", action="store_true", help="revalue without fetching")
    parser.add_argument("--skip-fit", action="store_true", help="revalue without refitting")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)s %(name)s: %(message)s",
    )

    report = asyncio.run(
        run(args.database, skip_comps=args.skip_comps, skip_fit=args.skip_fit)
    )
    log.info("%s", report.summary())
    for problem in report.problems:
        log.warning("%s", problem)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
