"""Time view: the checkpoint index, and /srv/nas-at/<time>/<path> showing the NAS as it was at that instant."""

import argparse
import errno
import fcntl
import math
import os
import sqlite3
import stat
import subprocess
import sys
import threading
import time
from datetime import datetime

SCHEMA = """
CREATE TABLE IF NOT EXISTS checkpoints (
    branch  TEXT NOT NULL,
    cno     INTEGER NOT NULL,
    epoch   INTEGER NOT NULL,
    PRIMARY KEY (branch, cno)
);
CREATE INDEX IF NOT EXISTS checkpoints_epoch ON checkpoints (branch, epoch, cno);
"""

LIVE = 0


def connect(path):
    db = sqlite3.connect(path, timeout=60, check_same_thread=False)
    db.execute("PRAGMA journal_mode=WAL")
    db.executescript(SCHEMA)
    return db


def device_of(mount):
    out = subprocess.run(["findmnt", "-no", "SOURCE", mount], capture_output=True, text=True).stdout
    return out.split("\n")[0] or None


def index_branch(db, branch, promote):
    if not os.path.ismount(branch):
        return 0
    device = device_of(branch)
    if device is None:
        return 0
    (last,) = db.execute("SELECT COALESCE(MAX(cno), 0) FROM checkpoints WHERE branch=?", (branch,)).fetchone()
    out = subprocess.run(
        ["lscp", "-a", "-i", str(last + 1), device], capture_output=True, text=True, check=True
    ).stdout
    rows, plain = [], []
    for line in out.splitlines()[1:]:
        fields = line.split()
        if len(fields) < 4 or not fields[0].isdigit():
            continue
        cno = int(fields[0])
        epoch = int(time.mktime(time.strptime(f"{fields[1]} {fields[2]}", "%Y-%m-%d %H:%M:%S")))
        rows.append((branch, cno, epoch))
        if fields[3] == "cp":
            plain.append(str(cno))
    db.executemany("INSERT OR IGNORE INTO checkpoints VALUES (?, ?, ?)", rows)
    db.commit()
    if promote and plain:
        for i in range(0, len(plain), 512):
            subprocess.run(["chcp", "ss", device, *plain[i : i + 512]], check=False)
    return len(rows)


def parse_time(text):
    if text.startswith("@"):
        return float(text[1:])
    return datetime.fromisoformat(text).timestamp()


class Mounts:
    def __init__(self, base, lock, idle, limit, on_evict):
        self.base = base
        self.on_evict = on_evict
        self.lock = lock
        self.idle = idle
        self.limit = limit
        self.used = {}
        self.guard = threading.Lock()

    def path(self, branch, cno):
        if cno == LIVE:
            return branch
        target = os.path.join(self.base, os.path.basename(branch), str(cno))
        with self.guard:
            self.used[target] = time.monotonic()
            if os.path.ismount(target):
                return target
            device = device_of(branch)
            if device is None:
                return None
            mount_checkpoint(self.lock, device, cno, target)
            if not os.path.ismount(target):
                self.used.pop(target, None)
                return None
        self.evict()
        return target

    def evict(self, everything=False):
        now = time.monotonic()
        evicted = False
        with self.guard:
            order = sorted(self.used.items(), key=lambda kv: kv[1])
            excess = len(order) - self.limit
            for target, last in order:
                if everything or excess > 0 or now - last > self.idle:
                    if subprocess.run(["umount", target], capture_output=True).returncode == 0 or not os.path.ismount(
                        target
                    ):
                        self.used.pop(target, None)
                        evicted = True
                        excess -= 1
                        try:
                            os.rmdir(target)
                        except OSError:
                            pass
        if evicted:
            self.on_evict()


class View:
    def __init__(self, args):
        self.branches = args.branch
        self.hidden = set(args.hide)
        self.index = connect(args.index)
        self.index_lock = threading.Lock()
        self.indexed_at = 0.0
        self.streams = [s.split("=", 1) for s in args.stream]
        self.points = sqlite3.connect(args.points, timeout=60, check_same_thread=False) if args.points else None
        self.cache = {}
        self.mounts = Mounts(args.mount_dir, args.lock, args.idle, args.max_mounts, self.cache.clear)

    def refresh(self):
        with self.index_lock:
            if time.monotonic() - self.indexed_at < 5:
                return
            for branch in self.branches:
                try:
                    if index_branch(self.index, branch, promote=False):
                        self.cache.clear()
                except subprocess.CalledProcessError as e:
                    print(f"index {branch}: {e}", file=sys.stderr)
            self.indexed_at = time.monotonic()

    def candidates(self, branch, t):
        second = math.floor(t)
        with self.index_lock:
            q = self.index.execute
            after = q(
                "SELECT cno FROM checkpoints WHERE branch=? AND epoch>? ORDER BY cno LIMIT 1", (branch, second)
            ).fetchone()
            same = q(
                "SELECT cno FROM checkpoints WHERE branch=? AND epoch=? ORDER BY cno DESC", (branch, second)
            ).fetchall()
            before = q(
                "SELECT cno FROM checkpoints WHERE branch=? AND epoch<? ORDER BY cno DESC LIMIT 1", (branch, second)
            ).fetchone()
        newest = [after[0] if after else LIVE]
        return newest + [c for (c,) in same], (before[0] if before else None)

    def point_at(self, name, t):
        if self.points is None:
            return None
        try:
            return self.points.execute(
                "SELECT branch, cno FROM points WHERE stream=? AND captured<=? ORDER BY captured DESC LIMIT 1",
                (name, t),
            ).fetchone()
        except sqlite3.OperationalError:
            return None

    def stream_point(self, rel, t):
        for name, root in self.streams:
            if rel == root or rel.startswith(root + "/"):
                row = self.point_at(name, t)
                return ("point", row) if row else ("none",)
        return None

    def stream_ancestry(self, rel, t):
        for name, root in self.streams:
            if rel == "" or root.startswith(rel + "/"):
                row = self.point_at(name, t)
                if row:
                    yield root, row

    def resolve(self, branch, t, rel):
        key = (branch, t, rel)
        if key in self.cache:
            return self.cache[key]
        result = self._resolve(branch, t, rel)
        if len(self.cache) > 50000:
            self.cache.clear()
        self.cache[key] = result
        return result

    def _resolve(self, branch, t, rel):
        point = self.stream_point(rel, t)
        if point is not None:
            if point[0] == "none":
                return None
            point_branch, cno = point[1]
            if point_branch != branch:
                return None
            root = self.mounts.path(branch, cno)
            full = os.path.join(root, rel) if root else None
            return full if full and os.path.lexists(full) else None

        found = self.resolve_native(branch, t, rel)
        if found is not None:
            return found
        for _, (point_branch, cno) in self.stream_ancestry(rel, t):
            if point_branch == branch:
                root = self.mounts.path(branch, cno)
                if root and os.path.isdir(os.path.join(root, rel)):
                    return os.path.join(root, rel)
        return None

    def resolve_native(self, branch, t, rel):
        newer, before = self.candidates(branch, t)
        t_ns = int(t * 1e9)

        if rel:
            parent = self.resolve(branch, t, os.path.dirname(rel))
            if parent is None or not os.path.isdir(parent):
                return None
            if os.path.basename(rel) not in os.listdir(parent) and not any(
                True for _ in self.stream_ancestry(rel, t)
            ):
                return None

        fallback = None
        for cno in newer:
            root = self.mounts.path(branch, cno)
            if root is None:
                continue
            full = os.path.join(root, rel)
            try:
                st = os.lstat(full)
            except FileNotFoundError:
                continue
            if st.st_ctime_ns <= t_ns:
                return full
            fallback = fallback or full
        if before is not None:
            root = self.mounts.path(branch, before)
            if root is not None and os.path.lexists(os.path.join(root, rel)):
                return os.path.join(root, rel)
        if not rel and before is None:
            return None
        return fallback

    def split(self, path):
        parts = path.strip("/").split("/", 1)
        if not parts[0]:
            return None, ""
        try:
            t = parse_time(parts[0])
        except ValueError:
            raise OSError(errno.ENOENT, "not a time")
        rel = parts[1] if len(parts) > 1 else ""
        if rel.split("/", 1)[0] in self.hidden:
            raise OSError(errno.ENOENT, "hidden")
        return t, rel

    def real(self, path):
        t, rel = self.split(path)
        if t is None:
            return None
        self.refresh()
        for branch in self.branches:
            full = self.resolve(branch, t, rel)
            if full is not None:
                return full
        raise OSError(errno.ENOENT, path)

    def listing(self, path):
        t, rel = self.split(path)
        names = set()
        for branch in self.branches:
            full = self.resolve(branch, t, rel)
            if full is not None and os.path.isdir(full):
                names.update(os.listdir(full))
        for root, (point_branch, _) in self.stream_ancestry(rel, t):
            if point_branch in self.branches:
                names.add(root[len(rel) + 1 :].split("/", 1)[0] if rel else root.split("/", 1)[0])
        if not rel:
            names -= self.hidden
        return sorted(names)


def serve(args):
    from fuse import FUSE, FuseOSError, Operations

    view = View(args)

    def wrap(fn):
        def inner(*a):
            try:
                return fn(*a)
            except OSError as e:
                raise FuseOSError(e.errno or errno.EIO)

        return inner

    class TimeView(Operations):
        @wrap
        def getattr(self, path, fh=None):
            real = view.real(path)
            if real is None:
                return {"st_mode": stat.S_IFDIR | 0o555, "st_nlink": 2, "st_uid": 0, "st_gid": 0}
            st = os.lstat(real)
            return {
                k: getattr(st, k)
                for k in ("st_mode", "st_nlink", "st_uid", "st_gid", "st_size", "st_atime", "st_mtime", "st_ctime")
            }

        @wrap
        def readdir(self, path, fh):
            if view.split(path)[0] is None:
                return [".", ".."]
            view.real(path)
            return [".", ".."] + view.listing(path)

        @wrap
        def readlink(self, path):
            return os.readlink(view.real(path))

        @wrap
        def open(self, path, flags):
            if flags & (os.O_WRONLY | os.O_RDWR | os.O_APPEND | os.O_TRUNC):
                raise OSError(errno.EROFS, path)
            return os.open(view.real(path), os.O_RDONLY)

        @wrap
        def read(self, path, size, offset, fh):
            return os.pread(fh, size, offset)

        @wrap
        def release(self, path, fh):
            os.close(fh)

    def reaper():
        while True:
            time.sleep(60)
            view.mounts.evict()

    threading.Thread(target=reaper, daemon=True).start()
    os.makedirs(args.view, exist_ok=True)
    try:
        FUSE(TimeView(), args.view, foreground=True, ro=True, allow_other=True, default_permissions=True, nothreads=True)
    finally:
        view.mounts.evict(everything=True)


def run_index(args):
    db = connect(args.index)
    for branch in args.branch:
        added = index_branch(db, branch, promote=args.promote)
        if added:
            print(f"{branch}: {added} new checkpoints")


def mount_checkpoint(lock, device, cno, target):
    os.makedirs(target, exist_ok=True)
    with open(lock, "w") as held:
        fcntl.flock(held, fcntl.LOCK_EX)
        subprocess.run(["chcp", "ss", device, str(cno)], capture_output=True)
        done = subprocess.run(["mount.nilfs2", "-o", f"ro,nogc,cp={cno}", device, target], capture_output=True)
    if done.returncode != 0:
        print(f"mount cp {cno} at {target} failed: {done.stderr.decode().strip()}", file=sys.stderr)
        try:
            os.rmdir(target)
        except OSError:
            pass


def run_window(args):
    db = connect(args.index)
    for branch in args.branch:
        index_branch(db, branch, promote=False)
        device = device_of(branch) if os.path.ismount(branch) else None
        if device is None:
            continue
        snapdir = os.path.join(branch, args.snapshot_dir)
        os.makedirs(snapdir, exist_ok=True)
        wanted = {}
        for cno, epoch in db.execute(
            "SELECT MAX(cno), MAX(epoch) FROM checkpoints WHERE branch=? GROUP BY epoch / ? ORDER BY 1 DESC LIMIT ?",
            (branch, args.bucket, args.generations),
        ):
            wanted[time.strftime("@GMT-%Y.%m.%d-%H.%M.%S", time.gmtime(epoch))] = cno
        for name, cno in wanted.items():
            target = os.path.join(snapdir, name)
            if not os.path.ismount(target):
                mount_checkpoint(args.lock, device, cno, target)
        for name in os.listdir(snapdir):
            target = os.path.join(snapdir, name)
            if name.startswith("@GMT-") and name not in wanted:
                if subprocess.run(["umount", target], capture_output=True).returncode == 0 or not os.path.ismount(target):
                    try:
                        os.rmdir(target)
                    except OSError:
                        pass


def resolve_cli(args):
    try:
        t = parse_time(args.time)
    except ValueError:
        sys.exit(f"cannot read time {args.time!r}; use e.g. '2026-11-01 14:03:27.250' or @<epoch>")
    path = os.path.abspath(args.path)
    roots = [args.pool] + args.branch
    rel = None
    for root in roots:
        if path == root or path.startswith(root + "/"):
            rel = os.path.relpath(path, root)
            break
    if rel is None:
        sys.exit(f"{path} is not under {args.pool}")
    rel = "" if rel == "." else rel
    name = datetime.fromtimestamp(t).isoformat(timespec="milliseconds")
    view = os.path.join(args.view, name, rel)
    if not os.path.lexists(view):
        sys.exit(f"{rel or '/'} did not exist at {name}")
    print(view)


def main():
    parser = argparse.ArgumentParser(prog="nas-at")
    parser.add_argument("--branch", action="append", default=[])
    parser.add_argument("--index", required=True)
    parser.add_argument("--points")
    parser.add_argument("--stream", action="append", default=[])
    parser.add_argument("--hide", action="append", default=[])
    parser.add_argument("--lock", default="/run/nas-nilfs-write.lock")
    parser.add_argument("--mount-dir", default="/run/nas-at")
    parser.add_argument("--view", default="/srv/nas-at")
    parser.add_argument("--pool", default="/srv/nas")
    parser.add_argument("--idle", type=float, default=600)
    parser.add_argument("--max-mounts", type=int, default=48)
    sub = parser.add_subparsers(dest="cmd", required=True)
    i = sub.add_parser("index")
    i.add_argument("--promote", action="store_true")
    sub.add_parser("serve")
    w = sub.add_parser("window")
    w.add_argument("--snapshot-dir", default="snapshots")
    w.add_argument("--bucket", type=int, default=900)
    w.add_argument("--generations", type=int, default=24)
    r = sub.add_parser("resolve")
    r.add_argument("path")
    r.add_argument("time")
    args = parser.parse_args()
    {"index": run_index, "serve": serve, "window": run_window, "resolve": resolve_cli}[args.cmd](args)


if __name__ == "__main__":
    main()
