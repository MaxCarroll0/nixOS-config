"""Browse index: per-user file tree, sizes, version counts and thumbnails, held in SQLite."""

import argparse
import os
import sqlite3
import subprocess
import sys
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
"""

THUMBNAILABLE = {".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp", ".tiff", ".heic"}


def connect(db_path):
    db = sqlite3.connect(db_path)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA synchronous=NORMAL")
    db.executescript(SCHEMA)
    return db


def btrfs_generation(root):
    try:
        out = subprocess.run(
            ["btrfs", "subvolume", "show", str(root)],
            capture_output=True, text=True, timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    for line in out.stdout.splitlines():
        if "Generation:" in line:
            try:
                return int(line.split(":")[1].strip())
            except (IndexError, ValueError):
                return None
    return None


def changed_since(root, generation):
    try:
        out = subprocess.run(
            ["btrfs", "subvolume", "find-new", str(root), str(generation)],
            capture_output=True, text=True, timeout=300,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    paths = set()
    for line in out.stdout.splitlines():
        marker = " gen "
        if not line.startswith("inode ") or marker not in line:
            continue
        parts = line.split()
        if parts[-1] not in (".", ".."):
            paths.add(root / parts[-1])
    return paths


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


def record(db, owner, root, path, thumb_dir, thumb_size, want_thumbs):
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
        INSERT INTO entries (owner, path, parent, name, is_dir, size, mtime, versions, thumb)
        VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?)
        ON CONFLICT(owner, path) DO UPDATE SET
            size=excluded.size,
            mtime=excluded.mtime,
            thumb=COALESCE(excluded.thumb, entries.thumb),
            versions=entries.versions + (excluded.mtime > entries.mtime)
        """,
        (owner, rel, parent, path.name, is_dir, st.st_size, int(st.st_mtime), thumb),
    )


def full_scan(db, owner, root, thumb_dir, thumb_size, want_thumbs):
    seen = 0
    for dirpath, dirnames, filenames in os.walk(root, onerror=lambda e: None):
        dirnames[:] = [d for d in dirnames if d not in (".snapshots", ".recycle", "lost+found")]
        base = Path(dirpath)
        for entry in dirnames + filenames:
            record(db, owner, root, base / entry, thumb_dir, thumb_size, want_thumbs)
            seen += 1
            if seen % 2000 == 0:
                db.commit()
    db.commit()
    return seen


def incremental(db, owner, root, since, thumb_dir, thumb_size, want_thumbs):
    paths = changed_since(root, since)
    if paths is None:
        return None
    for path in paths:
        record(db, owner, root, path, thumb_dir, thumb_size, want_thumbs)
    db.commit()
    return len(paths)


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
    owners = args.owner or [p.name for p in data_root.iterdir() if p.is_dir()]

    for owner in owners:
        root = data_root / owner
        if not root.is_dir():
            continue
        row = db.execute("SELECT last_gen FROM scan_state WHERE owner=?", (owner,)).fetchone()
        last_gen = row[0] if row else 0
        generation = btrfs_generation(root)

        touched = None
        if last_gen and generation:
            touched = incremental(db, owner, root, last_gen, thumb_dir,
                                  args.thumb_size, not args.no_thumbnails)
        if touched is None:
            touched = full_scan(db, owner, root, thumb_dir,
                                args.thumb_size, not args.no_thumbnails)

        db.execute(
            """
            INSERT INTO scan_state (owner, last_gen, last_run) VALUES (?, ?, strftime('%s','now'))
            ON CONFLICT(owner) DO UPDATE SET last_gen=excluded.last_gen, last_run=excluded.last_run
            """,
            (owner, generation or 0),
        )
        db.commit()
        print(f"{owner}: {touched} entries", file=sys.stderr)

    if args.metrics_file:
        export_metrics(db, args.metrics_file)
    db.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
