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

CREATE TABLE IF NOT EXISTS versions (
    owner       TEXT NOT NULL,
    path        TEXT NOT NULL,
    checkpoint  INTEGER NOT NULL,
    size        INTEGER NOT NULL,
    mtime       INTEGER NOT NULL,
    seen        INTEGER NOT NULL,
    PRIMARY KEY (owner, path, checkpoint)
);
CREATE INDEX IF NOT EXISTS versions_path ON versions (owner, path, seen DESC);
"""

THUMBNAILABLE = {".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp", ".tiff", ".heic"}

HIDE_MARKER = ".nashidden"

# Not accounts: indexing these would multiply the index by the checkpoint window.
RESERVED = {"snapshots", "lost+found"}


def is_hidden_path(root, path):
    current = path
    while True:
        if (current / HIDE_MARKER).exists():
            return True
        if current == root or current.parent == current:
            return False
        current = current.parent


def connect(db_path):
    db = sqlite3.connect(db_path)
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


def current_checkpoint(path):
    """Newest NILFS2 checkpoint number for the filesystem holding path, or None."""
    try:
        out = subprocess.run(
            ["lscp", "-r", str(path)],
            capture_output=True, text=True, timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    for line in out.stdout.splitlines():
        parts = line.split()
        if parts and parts[0].isdigit():
            return int(parts[0])
    return None


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
        dirnames[:] = [d for d in dirnames if d not in (".snapshots", ".recycle", "lost+found")]
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


def note_version(db, owner, root, path, checkpoint):
    """Record which checkpoint holds this version, so revert is a lookup not a search."""
    if checkpoint is None:
        return
    try:
        st = path.lstat()
    except OSError:
        return
    db.execute(
        """
        INSERT INTO versions (owner, path, checkpoint, size, mtime, seen)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(owner, path, checkpoint) DO NOTHING
        """,
        (owner, str(path.relative_to(root)), checkpoint,
         st.st_size, int(st.st_mtime), int(time.time())),
    )


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
    args = ap.parse_args()

    data_root = Path(args.data_root)
    if not data_root.is_dir():
        return 0

    Path(args.db).parent.mkdir(parents=True, exist_ok=True)
    db = connect(args.db)
    thumb_dir = Path(args.thumb_dir)
    owners = args.owner or [
        p.name
        for p in data_root.iterdir()
        if p.is_dir() and p.name not in RESERVED and not p.name.startswith(".")
    ]

    for owner in owners:
        root = data_root / owner
        if not root.is_dir():
            continue
        checkpoint = current_checkpoint(root)

        touched = full_scan(db, owner, root, thumb_dir,
                            args.thumb_size, not args.no_thumbnails)

        if checkpoint is not None:
            for row in db.execute(
                "SELECT path FROM entries WHERE owner=? AND is_dir=0", (owner,)
            ).fetchall():
                note_version(db, owner, root, root / row[0], checkpoint)

        db.execute(
            """
            INSERT INTO scan_state (owner, last_gen, last_run) VALUES (?, ?, strftime('%s','now'))
            ON CONFLICT(owner) DO UPDATE SET last_gen=excluded.last_gen, last_run=excluded.last_run
            """,
            (owner, checkpoint or 0),
        )
        db.commit()
        print(f"{owner}: {touched} entries", file=sys.stderr)

    if args.metrics_file:
        export_metrics(db, args.metrics_file)
    db.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
