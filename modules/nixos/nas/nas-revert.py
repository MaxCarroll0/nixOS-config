"""List and restore earlier versions of a file from NILFS2 checkpoints."""

import argparse
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path


def run(args):
    return subprocess.run(args, capture_output=True, text=True, timeout=120)


def owner_of(path):
    try:
        import pwd

        return pwd.getpwuid(path.stat().st_uid).pw_name
    except (OSError, KeyError):
        return None


def branch_for(path):
    """Longest mounted NILFS2 prefix of path, with its device."""
    best = None
    try:
        for line in Path("/proc/self/mounts").read_text().splitlines():
            parts = line.split()
            if len(parts) > 2 and parts[2] == "nilfs2":
                mount = Path(parts[1])
                if path == mount or mount in path.parents:
                    if best is None or len(str(mount)) > len(str(best[1])):
                        best = (parts[0], mount)
    except OSError:
        pass
    return best


def versions_for(db_path, owner, rel):
    if not Path(db_path).is_file():
        return []
    db = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    try:
        return db.execute(
            "SELECT checkpoint, size, mtime, seen FROM versions "
            "WHERE owner=? AND path=? ORDER BY checkpoint DESC",
            (owner, rel),
        ).fetchall()
    except sqlite3.Error:
        return []
    finally:
        db.close()


def human(n):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024:
            return f"{n:.0f}{unit}"
        n /= 1024
    return f"{n:.1f}PB"


def cmd_list(args):
    path = Path(args.path).resolve()
    owner = args.owner or owner_of(path)
    found = branch_for(path)
    if found is None:
        print(f"{path} is not on a NILFS2 branch", file=sys.stderr)
        return 1
    _device, mount = found
    rel = str(path.relative_to(mount))

    rows = versions_for(args.db, owner, rel)
    if not rows:
        print("no recorded versions")
        return 0
    print(f"{'CHECKPOINT':>10}  {'SIZE':>8}  MODIFIED")
    for cno, size, mtime, _seen in rows:
        when = datetime.fromtimestamp(mtime, timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
        print(f"{cno:>10}  {human(size):>8}  {when}")
    return 0


def cmd_restore(args):
    path = Path(args.path).resolve()
    found = branch_for(path)
    if found is None:
        print(f"{path} is not on a NILFS2 branch", file=sys.stderr)
        return 1
    device, mount = found
    rel = path.relative_to(mount)

    with tempfile.TemporaryDirectory(prefix="nas-revert-") as tmp:
        mounted = run(["mount", "-t", "nilfs2", "-o", f"cp={args.checkpoint},ro", device, tmp])
        if mounted.returncode != 0:
            print(f"could not mount checkpoint {args.checkpoint}: {mounted.stderr.strip()}",
                  file=sys.stderr)
            return 1
        try:
            source = Path(tmp) / rel
            if not source.exists():
                print(f"{rel} does not exist in checkpoint {args.checkpoint}", file=sys.stderr)
                return 1
            target = Path(args.output) if args.output else path
            if target.exists() and not args.force:
                print(f"{target} exists; pass --force to overwrite", file=sys.stderr)
                return 1
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
            print(f"restored {rel} from checkpoint {args.checkpoint} to {target}")
        finally:
            run(["umount", tmp])
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--db", default="/var/lib/nas-index/index.db")
    ap.add_argument("--owner")
    sub = ap.add_subparsers(dest="command", required=True)

    l = sub.add_parser("list", help="show recorded versions of a file")
    l.add_argument("path")
    l.set_defaults(func=cmd_list)

    r = sub.add_parser("restore", help="copy a version out of a checkpoint")
    r.add_argument("path")
    r.add_argument("--checkpoint", type=int, required=True)
    r.add_argument("--output")
    r.add_argument("--force", action="store_true")
    r.set_defaults(func=cmd_restore)

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
