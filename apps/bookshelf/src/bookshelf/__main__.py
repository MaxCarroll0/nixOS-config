"""Entry point: serve the catalogue, or run the refresh job."""

from __future__ import annotations

import argparse
import logging
import sys

from bookshelf.config import SETTINGS


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="bookshelf", description=__doc__)
    parser.add_argument("--listen", default="127.0.0.1", help="address to bind")
    parser.add_argument("--port", type=int, default=8090)
    parser.add_argument("--database", default=SETTINGS.database)
    parser.add_argument("--refresh", action="store_true", help="run the refresh job and exit")
    parser.add_argument(
        "--reindex", action="store_true", help="rebuild the search index and exit"
    )
    parser.add_argument("--skip-comps", action="store_true")
    parser.add_argument("--skip-fit", action="store_true")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)s %(name)s: %(message)s",
    )

    if args.reindex:
        from bookshelf import db

        conn = db.connect(args.database)
        try:
            with db.transaction(conn):
                count = db.reindex(conn)
        finally:
            conn.close()
        logging.getLogger("bookshelf").info("reindexed %d editions", count)
        return 0

    if args.refresh:
        from bookshelf.refresh import main as refresh_main

        extra = ["--database", args.database]
        if args.skip_comps:
            extra.append("--skip-comps")
        if args.skip_fit:
            extra.append("--skip-fit")
        if args.verbose:
            extra.append("--verbose")
        return refresh_main(extra)

    import uvicorn

    from bookshelf.app import create_app
    from bookshelf.config import Settings

    settings = Settings(database=args.database)
    uvicorn.run(
        create_app(settings),
        host=args.listen,
        port=args.port,
        log_level="debug" if args.verbose else "info",
        # One worker: the catalogue is a single SQLite file and a single reader.
        workers=1,
        access_log=False,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
