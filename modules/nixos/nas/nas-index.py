"""Browse index: per-user file tree, sizes, version counts and thumbnails, held in SQLite."""

import argparse
import os
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS entries (
    owner       TEXT NOT NULL,
    path        TEXT NOT NULL,
    parent      TEXT NOT NULL,
    name        TEXT NOT NULL,
    is_dir      INTEGER NOT NULL,
    size        INTEGER NOT NULL,
    mtime       INTEGER NOT NULL,
    versions    INTEGER NOT NULL DEFAULT 1,
    hidden      INTEGER NOT NULL DEFAULT 0,
    thumb       TEXT,
    PRIMARY KEY (owner, path)
);
CREATE INDEX IF NOT EXISTS entries_parent ON entries (owner, parent);
CREATE INDEX IF NOT EXISTS entries_mtime ON entries (owner, mtime);

CREATE TABLE IF NOT EXISTS scan_state (
    owner       TEXT PRIMARY KEY,
    last_gen    INTEGER NOT NULL DEFAULT 0,
    last_run    INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS history_marks (
    branch      TEXT PRIMARY KEY,
    seen        INTEGER NOT NULL,
    settled     INTEGER NOT NULL
);
DROP TABLE IF EXISTS versions;
"""

THUMBNAILABLE = {".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp", ".tiff", ".heic"}

HIDE_MARKER = ".nashidden"

RESERVED = {"lost+found"}

PRUNED_DIRS = {".snapshots", ".recycle", "lost+found"}


def is_hidden_path(root, path):
    current = path
    while True:
        if (current / HIDE_MARKER).exists():
            return True
        if current == root or current.parent == current:
            return False
        current = current.parent


def connect(db_path):
    db = sqlite3.connect(db_path, timeout=300)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA synchronous=NORMAL")
    db.executescript(SCHEMA)
    migrate(db)
    return db


def migrate(db):
    """CREATE TABLE IF NOT EXISTS never alters an existing table, so add columns explicitly."""
    have = {row[1] for row in db.execute("PRAGMA table_info(entries)")}
    for name, decl in (
        ("versions", "INTEGER NOT NULL DEFAULT 1"),
        ("hidden", "INTEGER NOT NULL DEFAULT 0"),
        ("thumb", "TEXT"),
    ):
        if name not in have:
            db.execute(f"ALTER TABLE entries ADD COLUMN {name} {decl}")
    db.commit()


def history_counts(history_db, owner):
    """Retained edits per path under owner, from the NILFS2 history index."""
    try:
        h = sqlite3.connect(f"file:{history_db}?mode=ro", uri=True, timeout=60)
        rows = h.execute(
            """
            SELECT p.path, COUNT(DISTINCT p.branch || ':' || l.s)
            FROM paths p CROSS JOIN lives l ON l.branch=p.branch AND l.ino=p.ino
            WHERE p.path >= ? AND p.path < ?
              AND (p.lo IS NULL OR l.s >= p.lo) AND (p.hi IS NULL OR l.s < p.hi)
              AND NOT EXISTS (SELECT 1 FROM drops d
                              WHERE d.branch=l.branch AND d.ino=l.ino AND d.lo<=l.s AND l.s<d.hi)
            GROUP BY p.path
            """,
            (owner + "/", owner + "0"),
        ).fetchall()
        h.close()
    except sqlite3.Error as e:
        print(f"history counts for {owner}: {e}", file=sys.stderr)
        return None
    return {path[len(owner) + 1:]: n for path, n in rows}


def history_changes(history_db, marks):
    try:
        h = sqlite3.connect(f"file:{history_db}?mode=ro", uri=True, timeout=60)
        h.execute("BEGIN")
        return read_changes(h, marks)
    except sqlite3.Error as e:
        print(f"history changes: {e}", file=sys.stderr)
        return {}, {}


def read_changes(h, marks):
    heads = dict(h.execute("SELECT branch, MAX(cno) FROM checkpoints GROUP BY branch"))
    changed = set()
    for branch in heads:
        if branch not in marks:
            continue
        settled = marks[branch][1]
        changed.update(
            path
            for (path,) in h.execute(
                """
                SELECT path FROM paths p
                WHERE branch=? AND (since > ? OR hi > ? OR (hi IS NULL AND EXISTS (
                    SELECT 1 FROM lives l WHERE l.branch=p.branch AND l.ino=p.ino AND l.s > ?)))
                """,
                (branch, settled, settled, settled),
            )
        )
    holder = dict(h.execute("SELECT path, branch FROM paths WHERE hi IS NULL")) if changed else {}
    h.close()
    return heads, {path: holder.get(path) for path in changed}


def hidden_in_index(db, owner, rel):
    parent = os.path.dirname(rel)
    return db.execute(
        "SELECT 1 FROM entries WHERE owner=? AND ((path=? AND hidden=1) OR path IN (?, ?)) LIMIT 1",
        (owner, parent, os.path.join(parent, HIDE_MARKER), os.path.join(rel, HIDE_MARKER)),
    ).fetchone() is not None


def apply_changes(db, owner, changes, thumb_dir, thumb_size, want_thumbs):
    for rel in sorted(changes):
        branch = changes[rel]
        if PRUNED_DIRS.intersection(rel.split("/")):
            continue
        if branch is None:
            db.execute(
                "DELETE FROM entries WHERE owner=? AND (path=? OR substr(path, 1, ?)=?)",
                (owner, rel, len(rel) + 1, rel + "/"),
            )
            continue
        root = Path(branch) / owner
        record(db, owner, root, root / rel, thumb_dir, thumb_size, want_thumbs,
               1 if hidden_in_index(db, owner, rel) else 0)
    db.commit()
    return len(changes)


def thumbnail_for(src, thumb_dir, size):
    if src.suffix.lower() not in THUMBNAILABLE:
        return None
    digest = str(abs(hash(str(src))))
    dest = thumb_dir / f"{digest}.jpg"
    if dest.exists() and dest.stat().st_mtime >= src.stat().st_mtime:
        return str(dest)
    dest.parent.mkdir(parents=True, exist_ok=True)
    try:
        subprocess.run(
            ["convert", f"{src}[0]", "-auto-orient", "-thumbnail",
             f"{size}x{size}>", "-quality", "72", str(dest)],
            capture_output=True, timeout=30, check=True,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return str(dest)


def record(db, owner, root, path, thumb_dir, thumb_size, want_thumbs, hidden=0):
    try:
        st = path.lstat()
    except OSError:
        db.execute("DELETE FROM entries WHERE owner=? AND path=?", (owner, str(path)))
        return
    if not (path.is_dir() or path.is_file()):
        return
    rel = str(path.relative_to(root))
    parent = str(path.parent.relative_to(root)) if path.parent != root else ""
    is_dir = 1 if path.is_dir() else 0
    thumb = None
    if want_thumbs and not is_dir:
        thumb = thumbnail_for(path, thumb_dir, thumb_size)
    db.execute(
        """
        INSERT INTO entries (owner, path, parent, name, is_dir, size, mtime, versions, hidden, thumb)
        VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
        ON CONFLICT(owner, path) DO UPDATE SET
            size=excluded.size,
            mtime=excluded.mtime,
            hidden=excluded.hidden,
            thumb=COALESCE(excluded.thumb, entries.thumb),
            versions=entries.versions + (excluded.mtime > entries.mtime)
        """,
        (owner, rel, parent, path.name, is_dir, st.st_size, int(st.st_mtime), hidden, thumb),
    )


def full_scan(db, owner, root, thumb_dir, thumb_size, want_thumbs):
    seen = 0
    for dirpath, dirnames, filenames in os.walk(root, onerror=lambda e: None):
        dirnames[:] = [d for d in dirnames if d not in PRUNED_DIRS]
        base = Path(dirpath)
        hidden = 1 if (HIDE_MARKER in filenames or is_hidden_path(root, base)) else 0
        for entry in dirnames + filenames:
            child = base / entry
            marked = hidden or (entry in dirnames and (child / HIDE_MARKER).exists())
            record(db, owner, root, child, thumb_dir, thumb_size, want_thumbs, 1 if marked else 0)
            seen += 1
            if seen % 2000 == 0:
                db.commit()
    db.commit()
    return seen


def export_metrics(db, out_path):
    rows = db.execute(
        """
        SELECT owner,
               SUM(CASE WHEN is_dir=0 THEN size ELSE 0 END),
               SUM(CASE WHEN is_dir=0 THEN 1 ELSE 0 END),
               SUM(CASE WHEN is_dir=1 THEN 1 ELSE 0 END)
        FROM entries GROUP BY owner
        """
    ).fetchall()
    lines = [
        "# HELP nas_user_bytes Bytes stored by this account, from the browse index.",
        "# TYPE nas_user_bytes gauge",
        "# HELP nas_user_files Files stored by this account.",
        "# TYPE nas_user_files gauge",
        "# HELP nas_user_directories Directories belonging to this account.",
        "# TYPE nas_user_directories gauge",
    ]
    for owner, size, files, dirs in rows:
        lines.append(f'nas_user_bytes{{owner="{owner}"}} {size or 0}')
        lines.append(f'nas_user_files{{owner="{owner}"}} {files or 0}')
        lines.append(f'nas_user_directories{{owner="{owner}"}} {dirs or 0}')

    lines += [
        "# HELP nas_age_bytes Bytes whose newest version is at least this old, by age bucket.",
        "# TYPE nas_age_bytes gauge",
        "# HELP nas_age_files Files whose newest version is at least this old, by age bucket.",
        "# TYPE nas_age_files gauge",
    ]
    now = int(time.time())
    for owner, bucket, size, count in db.execute(
        """
        SELECT owner,
               CASE
                 WHEN ? - mtime <    604800 THEN 'week'
                 WHEN ? - mtime <   2592000 THEN 'month'
                 WHEN ? - mtime <   7776000 THEN 'quarter'
                 WHEN ? - mtime <  31536000 THEN 'year'
                 WHEN ? - mtime <  94608000 THEN 'three_years'
                 ELSE 'ancient'
               END,
               SUM(size), COUNT(*)
        FROM entries WHERE is_dir=0
        GROUP BY owner, 2
        """,
        (now, now, now, now, now),
    ).fetchall():
        lines.append(f'nas_age_bytes{{owner="{owner}",bucket="{bucket}"}} {size or 0}')
        lines.append(f'nas_age_files{{owner="{owner}",bucket="{bucket}"}} {count or 0}')

    oldest = db.execute("SELECT owner, MIN(mtime) FROM entries WHERE is_dir=0 GROUP BY owner")
    lines += [
        "# HELP nas_oldest_file_seconds Age of the oldest file held by this account.",
        "# TYPE nas_oldest_file_seconds gauge",
    ]
    for owner, mtime in oldest.fetchall():
        if mtime:
            lines.append(f'nas_oldest_file_seconds{{owner="{owner}"}} {now - mtime}')
    tmp = f"{out_path}.tmp"
    Path(tmp).write_text("\n".join(lines) + "\n")
    os.replace(tmp, out_path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", required=True)
    ap.add_argument("--data-root", required=True)
    ap.add_argument("--thumb-dir", required=True)
    ap.add_argument("--thumb-size", type=int, default=256)
    ap.add_argument("--metrics-file")
    ap.add_argument("--no-thumbnails", action="store_true")
    ap.add_argument("--owner", action="append", default=[])
    ap.add_argument("--history-db")
    ap.add_argument("--full", action="store_true")
    args = ap.parse_args()

    data_root = Path(args.data_root)
    if not data_root.is_dir():
        return 0

    Path(args.db).parent.mkdir(parents=True, exist_ok=True)
    db = connect(args.db)
    thumb_dir = Path(args.thumb_dir)
    marks = {b: (seen, settled) for b, seen, settled in db.execute("SELECT branch, seen, settled FROM history_marks")}
    heads, changed = history_changes(args.history_db, marks) if args.history_db else ({}, {})
    incremental = bool(marks) and not args.full

    by_owner = {}
    for path, branch in changed.items():
        owner, _, rel = path.partition("/")
        if rel and owner not in RESERVED and not owner.startswith("."):
            by_owner.setdefault(owner, {})[rel] = branch

    if incremental:
        owners = sorted(by_owner)
    else:
        owners = [
            p.name
            for p in data_root.iterdir()
            if p.is_dir() and p.name not in RESERVED and not p.name.startswith(".")
        ]
    if args.owner:
        owners = [o for o in owners if o in args.owner]

    for owner in owners:
        root = data_root / owner
        changes = by_owner.get(owner, {})
        if incremental and not any(os.path.basename(r) == HIDE_MARKER for r in changes):
            touched = apply_changes(db, owner, changes, thumb_dir, args.thumb_size, not args.no_thumbnails)
        elif root.is_dir():
            touched = full_scan(db, owner, root, thumb_dir,
                                args.thumb_size, not args.no_thumbnails)
        else:
            continue

        counts = history_counts(args.history_db, owner) if args.history_db else None
        if counts is not None:
            db.executemany(
                "UPDATE entries SET versions=? WHERE owner=? AND path=? AND is_dir=0",
                [(n, owner, rel) for rel, n in counts.items()],
            )

        db.execute(
            """
            INSERT INTO scan_state (owner, last_gen, last_run) VALUES (?, 0, strftime('%s','now'))
            ON CONFLICT(owner) DO UPDATE SET last_run=excluded.last_run
            """,
            (owner,),
        )
        db.commit()
        print(f"{owner}: {touched} entries", file=sys.stderr)

    if not args.owner:
        db.executemany(
            """
            INSERT INTO history_marks (branch, seen, settled) VALUES (?, ?, ?)
            ON CONFLICT(branch) DO UPDATE SET settled=history_marks.seen, seen=excluded.seen
            """,
            [(b, head, head) for b, head in heads.items()],
        )
        db.commit()

    if incremental and not owners:
        db.close()
        return 0

    if args.metrics_file:
        export_metrics(db, args.metrics_file)
    db.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
