"""The web service: a phone-first catalogue, server-rendered.

Nothing here calls a scraper or fits a model. Identification does reach out to the
library catalogues, because that is what the reader is waiting for, but prices and
valuations are only ever read from what the refresh job has already stored.
"""

from __future__ import annotations

import json
import logging
import sqlite3
from pathlib import Path
from typing import Any

from starlette.applications import Starlette
from starlette.datastructures import FormData
from starlette.requests import Request
from starlette.responses import JSONResponse, PlainTextResponse, RedirectResponse, Response
from starlette.routing import Mount, Route
from starlette.staticfiles import StaticFiles
from starlette.templating import Jinja2Templates

from bookshelf import db, publishers, query, store
from bookshelf.config import SETTINGS, Settings
from bookshelf.fetch import Fetcher
from bookshelf.models import Candidate, Condition, CoverType, Estimate, Kind, Method
from bookshelf.resolvers import resolve
from bookshelf.valuation import portfolio_total

log = logging.getLogger("bookshelf.app")

HERE = Path(__file__).parent
TEMPLATES = Jinja2Templates(directory=str(HERE / "templates"))


def identity(request: Request, settings: Settings) -> str:
    """Who is asking. The reverse proxy is the only source of this; there is no login."""
    header = request.headers.get(settings.identity_header)
    return header or settings.fake_identity or "unknown"


def _conn(request: Request) -> sqlite3.Connection:
    conn: sqlite3.Connection = request.app.state.conn
    return conn


def _settings(request: Request) -> Settings:
    settings: Settings = request.app.state.settings
    return settings


def _render(request: Request, template: str, context: dict[str, Any]) -> Response:
    settings = _settings(request)
    return TEMPLATES.TemplateResponse(
        request,
        template,
        {
            "identity": identity(request, settings),
            "currency": settings.currency,
            "Method": Method,
            **context,
        },
    )


async def home(request: Request) -> Response:
    conn = _conn(request)
    rows = store.shelf_rows(conn)
    estimates = [
        Estimate(
            value=row["market_value"],
            lo=row["market_lo"],
            hi=row["market_hi"],
            method=Method(row["method"]) if row["method"] else Method.UNKNOWN,
            n_comps=int(row["n_comps"] or 0),
            currency=str(row["currency"] or _settings(request).currency),
        )
        for row in rows
    ]
    paid = sum(float(row["price_paid"] or 0.0) for row in rows)
    basis = sum(float(row["cost_basis"] or 0.0) for row in rows)

    return _render(
        request,
        "index.html",
        {
            "rows": rows[:12],
            "counts": {
                "copies": len(rows),
                "editions": db.scalar(conn, "SELECT COUNT(*) FROM edition") or 0,
                "works": db.scalar(conn, "SELECT COUNT(*) FROM work") or 0,
                "composers": db.scalar(conn, "SELECT COUNT(*) FROM person") or 0,
            },
            "totals": portfolio_total(estimates),
            "paid": round(paid, 2),
            "basis": round(basis, 2),
        },
    )


async def add_form(request: Request) -> Response:
    return _render(request, "add.html", {"query": request.query_params.get("q", "")})


async def lookup(request: Request) -> Response:
    """Run the identification cascade for whatever was typed."""
    query = (request.query_params.get("q") or "").strip()
    if not query:
        return _render(request, "add.html", {"query": "", "candidates": None})

    conn = _conn(request)
    settings = _settings(request)
    async with Fetcher(conn, settings) as fetcher:
        candidates, problems = await resolve(query, fetcher, settings)

    attribution = None
    hint = publishers.for_number(conn, "")
    if candidates:
        publishers.seed_from_candidates(conn, list(candidates))

    context = {
        "query": query,
        "candidates": candidates,
        "problems": problems,
        "attribution": attribution or hint,
        "conditions": list(Condition),
        "covers": list(CoverType),
        "kinds": list(Kind),
    }
    if request.headers.get("HX-Request") or request.query_params.get("partial"):
        return _render(request, "_candidates.html", context)
    return _render(request, "add.html", context)


async def save(request: Request) -> Response:
    """Record a chosen candidate, or a manual entry, as a copy that is owned."""
    form: FormData = await request.form()
    conn = _conn(request)

    payload = form.get("candidate")
    with db.transaction(conn):
        if payload:
            candidate = Candidate.model_validate_json(str(payload))
            edition_id = store.save_candidate(conn, candidate)
            default_cover = candidate.cover_guess or CoverType.SOFT
        else:
            edition_id = store.save_manual(
                conn,
                title=str(form.get("title") or "").strip() or "(untitled)",
                composer=str(form.get("composer") or "").strip() or None,
                publisher=str(form.get("publisher") or "").strip() or None,
                cat_no=str(form.get("cat_no") or "").strip() or None,
                kind=Kind(str(form.get("kind") or Kind.SCORE.value)),
            )
            default_cover = CoverType.SOFT

        price_raw = str(form.get("price_paid") or "").strip()
        store.add_copy(
            conn,
            edition_id=edition_id,
            cover_type=CoverType(str(form.get("cover_type") or default_cover.value)),
            condition=Condition(str(form.get("condition") or Condition.GOOD.value)),
            acquired_on=str(form.get("acquired_on") or "").strip() or None,
            price_paid=float(price_raw) if price_raw else None,
            currency=str(form.get("currency") or _settings(request).currency),
            shelf=str(form.get("shelf") or "").strip() or None,
            notes=str(form.get("notes") or "").strip() or None,
        )

    return RedirectResponse(f"/edition/{edition_id}", status_code=303)


async def browse(request: Request) -> Response:
    conn = _conn(request)
    facet = request.query_params.get("facet")
    value = request.query_params.get("value")

    rows = store.shelf_rows(conn)
    if facet == "publisher":
        rows = [row for row in rows if (row["publisher"] or "unknown") == value]
    elif facet == "composer":
        rows = [row for row in rows if (row["composer"] or "unknown") == value]
    elif facet == "kind":
        rows = [row for row in rows if row["kind"] == value]

    return _render(
        request,
        "browse.html",
        {
            "rows": rows,
            "categories": store.categories(conn),
            "facet": facet,
            "value": value,
        },
    )


async def search(request: Request) -> Response:
    """Full-text search over editions, works and movements."""
    query = (request.query_params.get("q") or "").strip()
    results = store.search(_conn(request), query) if query else []
    context = {"query": query, "results": results}
    if request.query_params.get("partial"):
        return _render(request, "_results.html", context)
    return _render(request, "search.html", context)


async def edition(request: Request) -> Response:
    detail = store.edition_detail(_conn(request), int(request.path_params["edition_id"]))
    if detail is None:
        return Response("no such edition", status_code=404)
    return _render(
        request,
        "edition.html",
        {**detail, "conditions": list(Condition), "covers": list(CoverType)},
    )


async def valuation(request: Request) -> Response:
    conn = _conn(request)
    rows = store.shelf_rows(conn)
    estimates = [
        Estimate(
            value=row["market_value"],
            lo=row["market_lo"],
            hi=row["market_hi"],
            method=Method(row["method"]) if row["method"] else Method.UNKNOWN,
            n_comps=int(row["n_comps"] or 0),
            currency=str(row["currency"] or _settings(request).currency),
        )
        for row in rows
    ]
    fit = db.one(
        conn,
        """SELECT fitted_at, n_obs, sigma, r_squared, is_seed FROM model_fit
           ORDER BY fitted_at DESC, id DESC LIMIT 1""",
    )
    return _render(
        request,
        "valuation.html",
        {
            "rows": rows,
            "totals": portfolio_total(estimates),
            "paid": round(sum(float(row["price_paid"] or 0.0) for row in rows), 2),
            "basis": round(sum(float(row["cost_basis"] or 0.0) for row in rows), 2),
            "fit": fit,
        },
    )


async def set_value(request: Request) -> Response:
    """An explicit market value, which outranks the model and the comps."""
    form = await request.form()
    copy_id = int(request.path_params["copy_id"])
    raw = str(form.get("value") or "").strip()
    conn = _conn(request)
    if raw:
        with db.transaction(conn):
            store.set_manual_value(
                conn,
                copy_id=copy_id,
                value=float(raw),
                currency=str(form.get("currency") or _settings(request).currency),
            )
    edition_id = db.scalar(conn, "SELECT edition_id FROM copy WHERE id = ?", copy_id)
    return RedirectResponse(f"/edition/{edition_id}", status_code=303)


async def confirm_delete(request: Request) -> Response:
    """Say exactly what would be lost, before anything is."""
    conn = _conn(request)
    kind = request.path_params["kind"]
    target = int(request.path_params["target_id"])

    removal = (
        store.describe_copy_removal(conn, target)
        if kind == "copy"
        else store.describe_edition_removal(conn, target)
    )
    if removal is None:
        return Response("no such thing", status_code=404)
    return _render(request, "delete.html", {"removal": removal, "kind": kind, "target": target})


async def do_delete(request: Request) -> Response:
    """Delete, but only against an explicit confirmation from the form."""
    form = await request.form()
    if str(form.get("confirm") or "") != "yes":
        return Response("not confirmed", status_code=400)

    conn = _conn(request)
    kind = request.path_params["kind"]
    target = int(request.path_params["target_id"])

    with db.transaction(conn):
        if kind == "copy":
            remaining = store.delete_copy(conn, target)
        else:
            store.delete_edition(conn, target)
            remaining = None

    if remaining is not None:
        return RedirectResponse(f"/edition/{remaining}", status_code=303)
    return RedirectResponse("/browse", status_code=303)


async def console(request: Request) -> Response:
    """A read-only SQL console, for questions the browse pages do not anticipate."""
    settings = _settings(request)
    sql = (request.query_params.get("sql") or "").strip()

    result = None
    error = None
    readonly = query.connect_readonly(settings.database)
    try:
        if sql:
            try:
                result = query.run(readonly, sql)
            except query.QueryRefused as exc:
                error = str(exc)

        if result is not None and request.query_params.get("format") == "csv":
            return PlainTextResponse(
                result.to_csv(),
                media_type="text/csv",
                headers={"Content-Disposition": 'attachment; filename="bookshelf.csv"'},
            )

        tables = query.schema(readonly)
    finally:
        readonly.close()

    return _render(
        request,
        "sql.html",
        {
            "sql": sql,
            "result": result,
            "error": error,
            "tables": tables,
            "examples": query.EXAMPLES,
            "max_rows": query.MAX_ROWS,
        },
    )


async def health(request: Request) -> Response:
    """Provider state, which is how to tell a dead upstream from an empty catalogue."""
    conn = _conn(request)
    rows = db.all_rows(
        conn,
        "SELECT name, ok, last_ok_at, last_err_at, last_error, calls FROM provider_health"
        " ORDER BY name",
    )
    return JSONResponse(
        {
            "providers": [dict(row) for row in rows],
            "counts": {
                "editions": db.scalar(conn, "SELECT COUNT(*) FROM edition") or 0,
                "copies": db.scalar(conn, "SELECT COUNT(*) FROM copy") or 0,
                "comps": db.scalar(conn, "SELECT COUNT(*) FROM comp") or 0,
            },
            "learned_publishers": db.scalar(
                conn, "SELECT COUNT(DISTINCT publisher) FROM publisher_key"
            )
            or 0,
        }
    )


async def check_apis(request: Request) -> Response:
    """Prove outbound HTTP works from inside the service's own sandbox."""
    conn = _conn(request)
    settings = _settings(request)
    out: dict[str, str] = {}
    async with Fetcher(conn, settings) as fetcher:
        try:
            await fetcher.get(
                "https://services.dnb.de/sru/dnb.dma",
                provider="dnb",
                params={
                    "version": "1.1",
                    "operation": "searchRetrieve",
                    "query": 'NUM="HN 1234"',
                    "recordSchema": "MARC21-xml",
                    "maximumRecords": "1",
                },
                use_cache=False,
            )
            out["dnb"] = "ok"
        except Exception as exc:
            out["dnb"] = f"failed: {exc}"
    return JSONResponse(out)


def create_app(settings: Settings = SETTINGS) -> Starlette:
    conn = db.connect(settings.database)

    routes = [
        Route("/", home),
        Route("/add", add_form),
        Route("/lookup", lookup),
        Route("/save", save, methods=["POST"]),
        Route("/browse", browse),
        Route("/search", search),
        Route("/edition/{edition_id:int}", edition),
        Route("/copy/{copy_id:int}/value", set_value, methods=["POST"]),
        Route("/valuation", valuation),
        Route("/sql", console),
        Route("/delete/{kind:str}/{target_id:int}", confirm_delete),
        Route("/delete/{kind:str}/{target_id:int}", do_delete, methods=["POST"]),
        Route("/health", health),
        Route("/health/apis", check_apis),
        Mount("/static", StaticFiles(directory=str(HERE / "static")), name="static"),
    ]

    app = Starlette(routes=routes)
    app.state.conn = conn
    app.state.settings = settings

    TEMPLATES.env.filters["money"] = _money_filter(settings)
    TEMPLATES.env.filters["candidate_json"] = lambda c: c.model_dump_json()
    return app


def _money_filter(settings: Settings) -> Any:
    symbols = {"GBP": "£", "EUR": "€", "USD": "$"}

    def render(amount: Any, currency: str | None = None) -> str:
        if amount is None:
            return "—"
        code = currency or settings.currency
        return f"{symbols.get(code, code + ' ')}{float(amount):,.2f}"

    return render
