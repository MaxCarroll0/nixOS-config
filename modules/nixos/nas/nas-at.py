"""Time view and per-file history of the NILFS2 NAS branches."""

import argparse
import bisect
import errno
import fcntl
import fnmatch
import json
import os
import shutil
import sqlite3
import stat
import subprocess
import sys
import threading
import time
from collections import OrderedDict
from datetime import datetime

SCHEMA = """
CREATE TABLE IF NOT EXISTS checkpoints (
    branch  TEXT NOT NULL,
    cno     INTEGER NOT NULL,
    epoch   INTEGER NOT NULL,
    PRIMARY KEY (branch, cno)
);
CREATE INDEX IF NOT EXISTS checkpoints_epoch ON checkpoints (branch, epoch, cno);
CREATE TABLE IF NOT EXISTS lives (
    branch  TEXT NOT NULL,
    ino     INTEGER NOT NULL,
    vblk    INTEGER NOT NULL,
    n       INTEGER NOT NULL,
    s       INTEGER NOT NULL,
    e       INTEGER NOT NULL,
    seg     INTEGER,
    off     INTEGER NOT NULL,
    dead    INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS lives_ino ON lives (branch, ino, s);
CREATE INDEX IF NOT EXISTS lives_vblk ON lives (branch, s, vblk);
CREATE INDEX IF NOT EXISTS lives_seg ON lives (branch, seg);
CREATE INDEX IF NOT EXISTS lives_dead ON lives (branch, seg, s, n) WHERE dead=1 AND seg IS NOT NULL;
CREATE INDEX IF NOT EXISTS lives_closed ON lives (branch, ino, s, e, n, off, seg, dead) WHERE e<9223372036854775807;
CREATE TABLE IF NOT EXISTS tallies (
    branch  TEXT NOT NULL,
    ino     INTEGER NOT NULL,
    s       INTEGER NOT NULL,
    blocks  INTEGER NOT NULL,
    born    INTEGER NOT NULL,
    cur     INTEGER NOT NULL,
    data    INTEGER NOT NULL,
    ret     INTEGER NOT NULL,
    rec     INTEGER NOT NULL,
    PRIMARY KEY (branch, ino, s)
) WITHOUT ROWID;
CREATE TRIGGER IF NOT EXISTS lives_tally_insert AFTER INSERT ON lives BEGIN
    INSERT INTO tallies VALUES (NEW.branch, NEW.ino, NEW.s, TALLY(NEW))
    ON CONFLICT DO UPDATE SET UPSERT;
END;
CREATE TRIGGER IF NOT EXISTS lives_tally_delete AFTER DELETE ON lives BEGIN
    UPDATE tallies SET UNTALLY(OLD) WHERE branch=OLD.branch AND ino=OLD.ino AND s=OLD.s;
END;
CREATE TRIGGER IF NOT EXISTS lives_tally_update AFTER UPDATE ON lives BEGIN
    UPDATE tallies SET UNTALLY(OLD) WHERE branch=OLD.branch AND ino=OLD.ino AND s=OLD.s;
    INSERT INTO tallies VALUES (NEW.branch, NEW.ino, NEW.s, TALLY(NEW))
    ON CONFLICT DO UPDATE SET UPSERT;
END;
CREATE TABLE IF NOT EXISTS paths (
    branch  TEXT NOT NULL,
    ino     INTEGER NOT NULL,
    inc     INTEGER NOT NULL,
    path    TEXT NOT NULL,
    dir     TEXT NOT NULL,
    lo      INTEGER,
    hi      INTEGER,
    since   INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS paths_dir ON paths (branch, dir) WHERE hi IS NULL;
CREATE INDEX IF NOT EXISTS paths_path ON paths (branch, path);
CREATE INDEX IF NOT EXISTS paths_ino ON paths (branch, ino);
CREATE INDEX IF NOT EXISTS paths_unbounded ON paths (branch) WHERE lo IS NULL;
CREATE TABLE IF NOT EXISTS policy (
    id      INTEGER PRIMARY KEY,
    paths   TEXT NOT NULL,
    rule    TEXT NOT NULL,
    params  TEXT NOT NULL,
    lo      REAL,
    hi      REAL,
    created REAL NOT NULL,
    undone  REAL
);
CREATE TABLE IF NOT EXISTS drops (
    rule    INTEGER NOT NULL,
    branch  TEXT NOT NULL,
    ino     INTEGER NOT NULL,
    lo      INTEGER NOT NULL,
    hi      INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS drops_ino ON drops (branch, ino, lo);
CREATE INDEX IF NOT EXISTS drops_rule ON drops (rule, branch);
CREATE TABLE IF NOT EXISTS rendered (
    rule    INTEGER NOT NULL,
    branch  TEXT NOT NULL,
    at      REAL NOT NULL,
    PRIMARY KEY (rule, branch)
);
CREATE TABLE IF NOT EXISTS gc_runs (
    id      INTEGER PRIMARY KEY,
    branch  TEXT NOT NULL,
    at      REAL NOT NULL,
    segs    INTEGER NOT NULL,
    freed   INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS scan (
    branch  TEXT PRIMARY KEY,
    segnum  INTEGER NOT NULL,
    seq     INTEGER NOT NULL,
    blocknr INTEGER NOT NULL,
    sysfs_seq INTEGER NOT NULL DEFAULT -1,
    sysfs_blk INTEGER NOT NULL DEFAULT -1,
    events_offset INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS history_days (
    branch      TEXT NOT NULL,
    day         INTEGER NOT NULL,
    current     INTEGER NOT NULL,
    retained    INTEGER NOT NULL,
    reclaimable INTEGER NOT NULL,
    PRIMARY KEY (branch, day)
);
"""

OPEN = 2**63 - 1
LIVE = 0
QUANTA = (1, 5, 10, 30, 60, 300, 600, 1800, 3600, 86400, None)
GMT = "@GMT-%Y.%m.%d-%H.%M.%S"
BUILTIN = 0
LSSU_GAP = 64
TALLIES = {
    "blocks": "1",
    "born": "{r}.off>=0",
    "cur": "{r}.e={open}",
    "data": "{r}.e={open} AND {r}.off>=0",
    "ret": "{r}.e<{open} AND {r}.dead=0 AND {r}.seg IS NOT NULL",
    "rec": "{r}.dead=1 AND {r}.seg IS NOT NULL",
}


def tally(r, form):
    return ", ".join(form.format(col=col, n=f"{r}.n", when=when.format(r=r, open=OPEN)) for col, when in TALLIES.items())


SCHEMA = (
    SCHEMA.replace("TALLY(NEW)", tally("NEW", "{n} * ({when})"))
    .replace("UNTALLY(OLD)", tally("OLD", "{col}={col}-{n} * ({when})"))
    .replace("UPSERT", ", ".join(f"{col}={col}+excluded.{col}" for col in TALLIES))
)


def connect(path, timeout=600):
    db = sqlite3.connect(path, timeout=timeout, check_same_thread=False)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA synchronous=NORMAL")
    db.executescript(SCHEMA)
    if "ss" not in {r[1] for r in db.execute("PRAGMA table_info(checkpoints)")}:
        db.execute("ALTER TABLE checkpoints ADD COLUMN ss INTEGER NOT NULL DEFAULT 1")
        db.execute("CREATE INDEX IF NOT EXISTS checkpoints_ss ON checkpoints (branch, ss, epoch, cno)")
    db.commit()
    if one(db, "SELECT 1 FROM meta WHERE key='tallies'") is None:
        db.execute("BEGIN IMMEDIATE")
        if one(db, "SELECT 1 FROM meta WHERE key='tallies'") is None:
            db.execute("DELETE FROM tallies")
            db.execute(
                f"INSERT INTO tallies SELECT branch, ino, s, {tally('l', 'SUM(CASE WHEN {when} THEN {n} ELSE 0 END)')} "
                "FROM lives l GROUP BY branch, ino, s"
            )
            db.execute("INSERT INTO meta VALUES ('tallies', '1')")
        db.commit()
    return db


def one(db, sql, *args):
    row = db.execute(sql, args).fetchone()
    return row[0] if row else None


def chunks(items, size=500):
    items = list(items)
    for i in range(0, len(items), size):
        yield items[i : i + size]


def marks(items):
    return ",".join("?" * len(items))


def device_of(mount):
    out = subprocess.run(["findmnt", "-no", "SOURCE", "-M", mount], capture_output=True, text=True).stdout
    return out.split("\n")[0] or None


def generation(db):
    return int(one(db, "SELECT value FROM meta WHERE key='generation'") or 0)


def bump(db):
    db.execute(
        "INSERT INTO meta VALUES ('generation', '1') ON CONFLICT(key) DO UPDATE SET value=CAST(value AS INTEGER)+1"
    )
    db.commit()


def human(n):
    for unit in ("B", "K", "M", "G", "T"):
        if abs(n) < 1024 or unit == "T":
            return f"{n:.0f}{unit}" if unit == "B" else f"{n:.1f}{unit}"
        n /= 1024


def local(epoch):
    return datetime.fromtimestamp(epoch).strftime("%Y-%m-%d %H:%M:%S")


def parse_time(text):
    if text.startswith("@GMT-"):
        return float(datetime.strptime(text + "+0000", GMT + "%z").timestamp())
    if text.startswith("@"):
        return float(text[1:])
    if text == "now":
        return time.time()
    return datetime.fromisoformat(text).timestamp()


def parse_duration(text):
    if text in ("inf", "∞"):
        return None
    units = {"s": 1, "m": 60, "h": 3600, "d": 86400, "w": 604800}
    if text[-1] in units:
        return int(float(text[:-1]) * units[text[-1]])
    return int(text)


def parse_size(text):
    units = {"K": 2**10, "M": 2**20, "G": 2**30, "T": 2**40}
    if text[-1].upper() in units:
        return int(float(text[:-1]) * units[text[-1].upper()])
    return int(text)


def merge(ranges):
    out = []
    for lo, hi in sorted(map(tuple, ranges)):
        if out and lo <= out[-1][1]:
            out[-1][1] = max(out[-1][1], hi)
        else:
            out.append([lo, hi])
    return out


def covered(ranges, c):
    i = bisect.bisect_right(ranges, [c, OPEN + 1]) - 1
    return i >= 0 and ranges[i][0] <= c < ranges[i][1]


def any_between(sorted_cnos, lo, hi):
    i = bisect.bisect_left(sorted_cnos, lo)
    return i < len(sorted_cnos) and sorted_cnos[i] < hi


def retained(s, e, ranges, ss):
    at = s
    for lo, hi in ranges:
        if hi <= at:
            continue
        if lo >= e:
            break
        if lo > at and any_between(ss, at, lo):
            return True
        at = max(at, hi)
        if at >= e:
            return False
    return at < e and any_between(ss, at, e)


class Branch:
    def __init__(self, path):
        self.path = path
        self.name = os.path.basename(path)
        self.device = device_of(path) if os.path.ismount(path) else None
        real = os.path.realpath(self.device) if self.device else ""
        self.sysfs = f"/sys/fs/nilfs2/{os.path.basename(real)}" if real else None
        self.live = bool(self.sysfs and os.path.isdir(self.sysfs))
        self.bps = self.read("segments/blocks_per_segment") if self.live else 0
        self.bsize = os.statvfs(path).f_bsize if self.live else 4096

    def read(self, attr):
        with open(f"{self.sysfs}/{attr}") as f:
            return int(f.read().split()[0])

    def head(self):
        return self.read("segctor/last_seg_sequence"), self.read("segctor/last_pseg_block")


class Timeline:
    def __init__(self, db, branch):
        rows = db.execute("SELECT cno, epoch, ss FROM checkpoints WHERE branch=? ORDER BY cno", (branch,)).fetchall()
        self.epoch = {c: e for c, e, _ in rows}
        self.ss = [c for c, _, s in rows if s]
        self.last = rows[-1][0] if rows else 0
        self.protcno = self.ss[-1] if self.ss else 0
        self.cnos = [c for c, _, _ in rows]
        self.epochs = [e for _, e, _ in rows]

    def first_at(self, t):
        i = bisect.bisect_left(self.epochs, t)
        return self.cnos[i] if i < len(self.cnos) else self.last + 1

    def first_after(self, t):
        i = bisect.bisect_right(self.epochs, t)
        return self.cnos[i] if i < len(self.cnos) else self.last + 1


def index_branch(db, branch, promote):
    if not os.path.ismount(branch):
        return 0
    device = device_of(branch)
    if device is None:
        return 0
    last = one(db, "SELECT COALESCE(MAX(cno), 0) FROM checkpoints WHERE branch=?", branch)
    out = subprocess.run(["lscp", "-a", "-i", str(last + 1), device], capture_output=True, text=True, check=True).stdout
    rows, plain = [], []
    for line in out.splitlines()[1:]:
        fields = line.split()
        if len(fields) < 4 or not fields[0].isdigit():
            continue
        cno = int(fields[0])
        epoch = int(time.mktime(time.strptime(f"{fields[1]} {fields[2]}", "%Y-%m-%d %H:%M:%S")))
        minor = len(fields) > 4 and fields[4] == "i"
        if fields[3] == "cp" and not minor:
            plain.append(str(cno))
        rows.append((branch, cno, epoch, int(fields[3] == "ss" or (promote and not minor))))
    if promote:
        for batch in chunks(plain, 512):
            subprocess.run(["chcp", "ss", device, *batch], check=False, capture_output=True)
    db.executemany("INSERT OR IGNORE INTO checkpoints (branch, cno, epoch, ss) VALUES (?, ?, ?, ?)", rows)
    db.commit()
    return len(rows)


def lives(br, mode, *args, feed=None):
    cmd = ["nilfs-lives", mode, br.device, *map(str, args)]
    if feed is not None:
        done = subprocess.run(cmd, input=feed, capture_output=True, text=True)
        if done.returncode:
            raise RuntimeError(f"{' '.join(cmd)}: {done.stderr.strip()}")
        return done.stdout.splitlines()
    return subprocess.Popen(cmd, stdout=subprocess.PIPE, text=True)


def number(text):
    v = int(text)
    return OPEN if v >= OPEN else v


def carve(db, branch, s, lo, hi):
    start = one(db, "SELECT MAX(vblk) FROM lives WHERE branch=? AND s=? AND vblk<=?", branch, s, lo)
    pieces = []
    for rowid, ino, vblk, n, e, seg, off, dead in db.execute(
        "SELECT rowid, ino, vblk, n, e, seg, off, dead FROM lives WHERE branch=? AND s=? AND vblk>=? AND vblk<?",
        (branch, s, lo if start is None else start, hi),
    ).fetchall():
        if vblk + n <= lo:
            continue
        db.execute("DELETE FROM lives WHERE rowid=?", (rowid,))
        for a, b in ((vblk, lo), (hi, vblk + n)):
            if a < b and vblk <= a and b <= vblk + n:
                insert(db, branch, ino, a, b - a, s, e, seg, shift(off, a - vblk), dead)
        a, b = max(vblk, lo), min(vblk + n, hi)
        pieces.append((ino, a, b - a, e, seg, shift(off, a - vblk), dead))
    return pieces


def shift(off, by):
    return off if off < 0 else off + by


def insert(db, branch, ino, vblk, n, s, e, seg, off, dead=0):
    db.execute("INSERT INTO lives VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", (branch, ino, vblk, n, s, e, seg, off, dead))


def put_run(db, branch, ino, vblk, n, s, e, seg, off):
    carve(db, branch, s, vblk, vblk + n)
    insert(db, branch, ino, vblk, n, s, e, seg, off)


def set_end(db, branch, vblk, n, s, e):
    for ino, a, m, _, seg, off, dead in carve(db, branch, s, vblk, vblk + n):
        insert(db, branch, ino, a, m, s, e, seg, off)


def ingest(db, br, proc, touched):
    end = None
    for line in proc.stdout:
        f = line.split()
        if f[0] == "R":
            seg, ino, vblk, n, s = map(int, f[1:6])
            put_run(db, br.path, ino, vblk, n, s, number(f[6]), seg, int(f[7]))
            touched.add(ino)
        elif f[0] == "END":
            end = tuple(map(int, f[1:4]))
    if proc.wait():
        raise RuntimeError(f"nilfs-lives exited {proc.returncode} on {br.path}")
    return end


def probe(db, br, inos, also=()):
    rows = list(also)
    for batch in chunks(inos):
        rows += db.execute(
            f"SELECT vblk, n, s FROM lives WHERE branch=? AND e=? AND ino IN ({marks(batch)})",
            (br.path, OPEN, *batch),
        ).fetchall()
    if not rows:
        return
    seen = {}
    for line in lives(br, "probe", feed="".join(f"{v} {n}\n" for v, n, _ in rows)):
        f = line.split()
        if f[0] != "V" or f[5] == "0":
            continue
        vblk, n, s = int(f[3]), int(f[4]), int(f[5])
        set_end(db, br.path, vblk, n, s, number(f[6]))
        seen.setdefault(s, []).append((vblk, vblk + n))
    for vblk, n, s in rows:
        if not any(a < vblk + n and vblk < b for a, b in seen.get(s, ())):
            for ino, a, m, _, _, off, _ in carve(db, br.path, s, vblk, vblk + n):
                insert(db, br.path, ino, a, m, s, s + 1, None, off, 1)


def load_drops(db, branch, inos, below=None):
    out = {}
    for batch in chunks(inos):
        sql = f"SELECT ino, lo, hi FROM drops WHERE branch=? AND ino IN ({marks(batch)})"
        args = [branch, *batch]
        if below is not None:
            sql += " AND rule<?"
            args.append(below)
        for ino, lo, hi in db.execute(sql, args):
            out.setdefault(ino, []).append((lo, hi))
    return {ino: merge(r) for ino, r in out.items()}


def mark_dead(db, br, tl, inos):
    for batch in chunks(inos):
        drops = load_drops(db, br.path, batch)
        updates = []
        for rowid, ino, s, e, dead in db.execute(
            f"SELECT rowid, ino, s, e, dead FROM lives WHERE branch=? AND e<{OPEN} AND seg IS NOT NULL AND ino IN ({marks(batch)})",
            (br.path, *batch),
        ):
            d = int(e <= tl.protcno and not retained(s, e, drops.get(ino, []), tl.ss))
            if d != dead:
                updates.append((d, rowid))
        db.executemany("UPDATE lives SET dead=? WHERE rowid=?", updates)


def all_inos(db, branch):
    return [r[0] for r in db.execute("SELECT DISTINCT ino FROM lives WHERE branch=?", (branch,))]


def recount_days(db, brs):
    if not brs:
        return
    bsize = {br.path: br.bsize for br in brs}
    db.execute(f"DELETE FROM history_days WHERE branch IN ({marks(bsize)})", tuple(bsize))
    rows = db.execute(
        "SELECT t.branch, COALESCE(c.epoch / 86400 * 86400, 0) AS day, SUM(t.cur), SUM(t.ret), SUM(t.rec) "
        "FROM tallies t LEFT JOIN checkpoints c ON c.branch=t.branch AND c.cno=t.s "
        f"WHERE t.branch IN ({marks(bsize)}) GROUP BY t.branch, day",
        tuple(bsize),
    ).fetchall()
    db.executemany(
        "INSERT INTO history_days VALUES (?, ?, ?, ?, ?)",
        [(b, day, cur * bsize[b], ret * bsize[b], rec * bsize[b]) for b, day, cur, ret, rec in rows],
    )
    db.commit()


def published_counts(path):
    found = {}
    try:
        with open(path) as f:
            for line in f:
                name, _, value = line.strip().rpartition(" ")
                for metric, slot in (("nas_checkpoints{branch=\"", 0), ("nas_checkpoint_snapshots{branch=\"", 1)):
                    if name.startswith(metric) and name.endswith("\"}") and value.isdigit():
                        found.setdefault(name[len(metric) : -2], [None, None])[slot] = int(value)
    except FileNotFoundError:
        pass
    return {label: tuple(pair) for label, pair in found.items() if None not in pair}


def read_events(db, br, args):
    path = os.path.join(args.state, "events", br.name + ".jsonl")
    offset = one(db, "SELECT events_offset FROM scan WHERE branch=?", br.path) or 0
    try:
        size = os.path.getsize(path)
    except FileNotFoundError:
        return set(), set(), 0, {}
    if size < offset:
        offset = 0
    with open(path, "rb") as f:
        f.seek(offset)
        data = f.read(size - offset)
    data = data[: data.rfind(b"\n") + 1]
    offset += len(data)
    dirs, inos, written = set(), set(), {}
    root = br.path + "/"
    for line in data.splitlines():
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        p = ev.get("path") or (os.fsdecode(bytes(ev["path_raw"])) if "path_raw" in ev else None)
        if not p:
            continue
        if p.endswith(" (deleted)"):
            p = p[: -len(" (deleted)")]
        if p != br.path and not p.startswith(root):
            continue
        rel = p[len(root) :] if p != br.path else ""
        types = ev.get("types", "")
        if "W" in types:
            dirs.add(os.path.dirname(rel))
            if "inode" in ev:
                inos.add(ev["inode"])
                written[ev["inode"]] = rel
        if any(c in types for c in "+D<>"):
            dirs.add(rel)
    if size > args.rotate_bytes:
        subprocess.run(["systemctl", "restart", f"nas-history-watch-{br.name}.service"], check=False)
        offset = 0
    return dirs, inos, offset, written


def adopt(db, branch, written, cno):
    for ino, rel in written.items():
        try:
            if os.lstat(os.path.join(branch, rel)).st_ino == ino:
                continue
        except OSError:
            pass
        prior = db.execute("SELECT inc, hi FROM paths WHERE branch=? AND ino=?", (branch, ino)).fetchall()
        if any(hi is None for _, hi in prior):
            continue
        inc = max((i for i, _ in prior), default=-1) + 1
        db.execute(
            "INSERT INTO paths (branch, ino, inc, path, dir, lo, hi, since) VALUES (?, ?, ?, ?, ?, NULL, NULL, ?)",
            (branch, ino, inc, rel, os.path.dirname(rel), cno),
        )


def sync_dirs(db, br, dirs, cno, recursive=False):
    branch = br.path
    gone, found, todo, done = {}, [], sorted(set(dirs)), set()
    while todo:
        d = todo.pop()
        if d in done:
            continue
        done.add(d)
        try:
            entries = list(os.scandir(os.path.join(branch, d) if d else branch))
        except (FileNotFoundError, NotADirectoryError):
            entries = []
        rows = {
            p: (rowid, ino)
            for rowid, p, ino in db.execute(
                "SELECT rowid, path, ino FROM paths WHERE branch=? AND dir=? AND hi IS NULL", (branch, d)
            )
        }
        for ent in entries:
            rel = f"{d}/{ent.name}" if d else ent.name
            try:
                st = ent.stat(follow_symlinks=False)
            except FileNotFoundError:
                continue
            is_dir = stat.S_ISDIR(st.st_mode)
            old = rows.pop(rel, None)
            if old and old[1] == st.st_ino:
                if is_dir and recursive:
                    todo.append(rel)
                continue
            if old:
                gone.setdefault(old[1], []).append((old[0], rel))
                close_subtree(db, branch, rel, gone)
            found.append((rel, d, st.st_ino))
            if is_dir:
                todo.append(rel)
        for rel, (rowid, ino) in rows.items():
            gone.setdefault(ino, []).append((rowid, rel))
            close_subtree(db, branch, rel, gone)
    if not gone and not found:
        return set()
    candidates = set(gone) | {ino for _, _, ino in found}
    probe(db, br, candidates)
    renamed = set()
    for rel, d, ino in found:
        prior = db.execute(
            "SELECT rowid, path, inc, hi, since FROM paths WHERE branch=? AND ino=? ORDER BY since DESC, rowid DESC",
            (branch, ino),
        ).fetchall()
        inc, lo = 0, None
        if ino in gone:
            inc, lo = prior[0][2], cno
            renamed.add(ino)
        elif prior:
            elsewhere = [r for r in prior if r[3] is None]
            if elsewhere and same_inode(branch, elsewhere[0][1], ino):
                inc, lo = elsewhere[0][2], cno
            else:
                for r in elsewhere:
                    db.execute("UPDATE paths SET hi=? WHERE rowid=?", (cno, r[0]))
                last = prior[0]
                alive = one(
                    db, "SELECT 1 FROM lives WHERE branch=? AND ino=? AND e=? AND s<=? LIMIT 1", branch, ino, OPEN, last[4]
                )
                if alive:
                    inc, lo = last[2], cno
                else:
                    inc = max(r[2] for r in prior) + 1
        db.execute(
            "INSERT INTO paths (branch, ino, inc, path, dir, lo, hi, since) VALUES (?, ?, ?, ?, ?, ?, NULL, ?)",
            (branch, ino, inc, rel, d, lo, cno),
        )
    for ino, rows in gone.items():
        end = cno
        if ino not in renamed:
            end = cno + 1
            open_runs = one(db, "SELECT COUNT(*) FROM lives WHERE branch=? AND ino=? AND e=?", branch, ino, OPEN)
            death = one(db, "SELECT MAX(e) FROM lives WHERE branch=? AND ino=? AND e<?", branch, ino, OPEN)
            if not open_runs and death is not None:
                end = min(end, death)
        for rowid, _ in rows:
            db.execute("UPDATE paths SET hi=MAX(COALESCE(lo, 0), ?) WHERE rowid=?", (end, rowid))
    return candidates


def incarnation_start(db, branch, ino, since, present):
    front, start = None, 0
    for s, e in db.execute("SELECT s, e FROM lives WHERE branch=? AND ino=? ORDER BY s, e", (branch, ino)):
        if front is not None and front < s and front <= since:
            start = front
        front = e if front is None else max(front, e)
    if present and front is not None and front < OPEN and front <= since:
        start = front
    return start


def bound_incarnations(db, branch):
    rows = db.execute("SELECT rowid, ino, inc, since, hi IS NULL FROM paths WHERE branch=? AND lo IS NULL", (branch,)).fetchall()
    for rowid, ino, inc, since, present in rows:
        before = one(db, "SELECT MAX(hi) FROM paths WHERE branch=? AND ino=? AND inc<?", branch, ino, inc) or 0
        db.execute("UPDATE paths SET lo=? WHERE rowid=?", (max(before, incarnation_start(db, branch, ino, since, present)), rowid))
    return {ino for _, ino, _, _, _ in rows}


def same_inode(branch, rel, ino):
    try:
        return os.lstat(os.path.join(branch, rel)).st_ino == ino
    except OSError:
        return False


def close_subtree(db, branch, rel, gone):
    for rowid, p, ino in db.execute(
        "SELECT rowid, path, ino FROM paths WHERE branch=? AND hi IS NULL AND path>=? AND path<?",
        (branch, rel + "/", rel + "0"),
    ).fetchall():
        gone.setdefault(ino, []).append((rowid, p))


def under(path, scope):
    return scope == "" or path == scope or path.startswith(scope + "/")


def builtin_match(path, patterns):
    parts = path.split("/")
    return any(fnmatch.fnmatchcase("/".join(parts[:k]), pat) for k in range(1, len(parts) + 1) for pat in patterns)


class Rule:
    def __init__(self, row):
        self.id, paths, self.kind, params, self.lo, self.hi, self.created, self.undone = row
        self.paths = json.loads(paths)
        self.p = json.loads(params)

    @property
    def mode(self):
        return self.p.get("mode")

    @property
    def open(self):
        return bool(self.p.get("future")) or self.id == BUILTIN

    def describe(self):
        if self.kind == "pin":
            return f"#{self.id} pin {self.paths[0]}"
        if self.kind == "forget":
            return f"#{self.id} forget {' '.join(self.paths)}"
        mode = self.mode
        if mode == "quantum":
            q = self.p.get("q")
            what = f"quantum {q}s" if q else "landmarks only"
        elif mode == "pairs":
            what = f"pairs x{self.p.get('x', 1)}"
        else:
            what = mode
        span = "from now" if self.p.get("future") else (
            f"{local(self.lo) if self.lo else 'start'} .. {local(self.hi) if self.hi else local(self.created)}"
        )
        lm = "" if self.p.get("landmarks", True) else ", no landmarks"
        gap = f", gap {self.p.get('gap')}s" if mode in ("quantum", "pairs") and self.p.get("landmarks", True) else ""
        return f"#{self.id} {what}{gap}{lm}, {span}: {' '.join(p or '/' for p in self.paths)}"


def rules(db, include_undone=False):
    sql = "SELECT * FROM policy" + ("" if include_undone else " WHERE undone IS NULL") + " ORDER BY id"
    return [Rule(r) for r in db.execute(sql)]


def builtin_rule(args):
    return Rule((BUILTIN, json.dumps(args.historyless), "keep", json.dumps({"mode": "none", "builtin": True}), None, None, 0, None))


def scope_rows(db, branch, rule, patterns=None):
    out = {}
    if rule.id == BUILTIN:
        for pat in rule.paths:
            leaf = pat.rsplit("/", 1)[-1]
            sql = "SELECT ino, inc, path, lo, hi FROM paths WHERE branch=? AND (path=? OR path LIKE ? OR path LIKE ? OR path LIKE ?)"
            for ino, inc, path, lo, hi in db.execute(sql, (branch, leaf, leaf + "/%", "%/" + leaf, "%/" + leaf + "/%")):
                if builtin_match(path, [pat]):
                    out.setdefault(ino, set()).add((inc, path, lo, hi))
        return out
    for scope in rule.paths:
        if scope == "":
            rows = db.execute("SELECT ino, inc, path, lo, hi FROM paths WHERE branch=?", (branch,))
        else:
            rows = db.execute(
                "SELECT ino, inc, path, lo, hi FROM paths WHERE branch=? AND (path=? OR (path>=? AND path<?))",
                (branch, scope, scope + "/", scope + "0"),
            )
        for ino, inc, path, lo, hi in rows:
            out.setdefault(ino, set()).add((inc, path, lo, hi))
    return out


def ino_rows(db, sql, branch, inos, *args):
    inos = set(inos)
    if len(inos) > 2000:
        return [r for r in db.execute(sql.format(inos=""), (branch, *args)) if r[0] in inos]
    out = []
    for batch in chunks(inos):
        out += db.execute(sql.format(inos=f" AND ino IN ({marks(batch)})"), (branch, *batch, *args)).fetchall()
    return out


def inside(intervals, c):
    return any((lo is None or lo <= c) and (hi is None or c < hi) for _, _, lo, hi in intervals)


def interval_of(intervals, c):
    for _, _, lo, hi in intervals:
        if (lo is None or lo <= c) and (hi is None or c < hi):
            return (lo or 0), (OPEN if hi is None else hi)
    return None


def pin_instants(br, rule, edits_by_path, all_rules):
    out = set()
    for pin in all_rules:
        if pin.kind != "pin" or not in_scope(rule, pin.paths[0]):
            continue
        c = pin.p.get("cno", {}).get(br.path)
        later = [s for s in edits_by_path.get(pin.paths[0], ()) if c is not None and s > c]
        if later:
            out.add(min(later) - 1)
    return out


def frame(db, br, tl, rule, args, all_rules, now, scope=None):
    if rule.kind == "pin" or rule.mode == "continuous":
        return None
    scope = scope_rows(db, br.path, rule) if scope is None else scope
    if not scope:
        return None
    starts = ino_rows(db, "SELECT ino, s, born FROM tallies WHERE branch=?{inos} AND blocks>0", br.path, scope)
    created = rule.p.get("created_cno", {}).get(br.path, tl.last)
    future = rule.p.get("future") or rule.id == BUILTIN
    w_lo = tl.first_at(rule.lo) if rule.lo else 0
    edits = {}
    edits_by_path = {}
    for ino, s, _ in starts:
        intervals = scope[ino]
        if s < w_lo or not inside(intervals, s):
            continue
        edits.setdefault(ino, set()).add(s)
        for _, path, lo, hi in intervals:
            if (lo is None or lo <= s) and (hi is None or s < hi):
                edits_by_path.setdefault(path, set()).add(s)
    earlier = load_drops(db, br.path, list(edits), below=rule.id if rule.id != BUILTIN else 0)
    ss = set(tl.ss)
    instants = set()
    for ino, es in edits.items():
        for s in es:
            if s in ss and s <= tl.protcno and not covered(earlier.get(ino, []), s):
                instants.add(s)
    E = sorted(instants)
    gap = rule.p.get("gap", args.gap)
    if rule.hi:
        w_hi = tl.first_after(rule.hi)
    elif rule.mode == "none" and future:
        w_hi = tl.last + 1
    elif future:
        ends = [x for i, x in enumerate(E) if (E[i + 1] if i + 1 < len(E) else None) is not None and tl.epoch[E[i + 1]] - tl.epoch[x] >= gap]
        if E and now - tl.epoch[E[-1]] >= gap:
            ends.append(E[-1])
        w_hi = ends[-1] + 1 if ends else w_lo
    else:
        w_hi = created + 1
    E = [x for x in E if w_lo <= x < w_hi]
    pin_marks = {max((e for e in E if e <= x), default=None) for x in pin_instants(br, rule, edits_by_path, all_rules)} - {None}
    landmarks = set(pin_marks)
    if rule.p.get("landmarks", True) and rule.mode in ("quantum", "pairs"):
        for i, x in enumerate(E):
            nxt = E[i + 1] if i + 1 < len(E) else None
            if (nxt is not None and tl.epoch[nxt] - tl.epoch[x] >= gap) or (nxt is None and now - tl.epoch[x] >= gap):
                landmarks.add(x)
        growth = {}
        for ino, s, n in starts:
            if n:
                growth.setdefault(ino, {})[s] = n
        for ino, e, n in ino_rows(
            db, f"SELECT ino, e, SUM(n) FROM lives WHERE branch=?{{inos}} AND e<{OPEN} AND off>=0 GROUP BY ino, e", br.path, scope
        ):
            t = growth.setdefault(ino, {})
            t[e] = t.get(e, 0) - n
        landmarks |= removal_landmarks(scope, growth, E)
    return scope, edits, E, landmarks, pin_marks, (w_lo, w_hi)


def removal_landmarks(scope, growth, E):
    by_path = {}
    for ino, intervals in scope.items():
        for _, path, _, _ in intervals:
            by_path.setdefault(path, set()).add(ino)
    out = set()
    for path, inos in by_path.items():
        events = {}
        for ino in inos:
            for t, d in growth.get(ino, {}).items():
                events.setdefault(t, {})[ino] = d
        if len(events) < 2:
            continue
        sizes = dict.fromkeys(inos, 0)
        before = 0
        for t in sorted(events):
            for ino, d in events[t].items():
                sizes[ino] += d
            after = max(sizes.values())
            if before - after >= 16 and after <= before * 0.75:
                prior = max((x for x in E if x < t), default=None)
                if prior is not None:
                    out.add(prior)
            before = after
    return out


def stitch(fr, rule, tl):
    if fr is None:
        return {}, set()
    scope, edits, E, landmarks, pins, window = fr
    R = choose(E, landmarks, pins, rule, tl)
    if "" in rule.paths and rule.id != BUILTIN:
        w_lo, w_hi = window
        kept = set(R)
        return {}, {c for c in tl.ss if w_lo <= c < w_hi and c not in kept and c < tl.protcno}
    return gaps(scope, edits, R, window), set()


def choose(E, landmarks, pins, rule, tl):
    mode = rule.mode
    if mode == "continuous":
        return list(E)
    if mode == "none":
        return sorted(pins)
    keep = set(landmarks)
    pieces, piece = [], []
    for x in E:
        piece.append(x)
        if x in landmarks:
            pieces.append(piece)
            piece = []
    if piece:
        pieces.append(piece)
    for piece in pieces:
        if mode == "quantum":
            q = rule.p.get("q")
            if q is None:
                keep.add(piece[-1])
                continue
            last = {}
            for x in piece:
                ep = tl.epoch[x]
                last[(ep + time.localtime(ep).tm_gmtoff) // q] = x
            keep |= set(last.values())
        elif mode == "pairs":
            kept = piece
            for _ in range(rule.p.get("x", 1)):
                if len(kept) <= 2:
                    break
                kept = [kept[0]] + kept[1:-1][1::2] + [kept[-1]]
            keep |= set(kept)
    return sorted(keep)


def gaps(scope, edits, R, window):
    w_lo, w_hi = window
    out = {}
    for ino, es in edits.items():
        ranges = set()
        for s in es:
            if not w_lo <= s < w_hi:
                continue
            i = bisect.bisect_left(R, s)
            if i < len(R) and R[i] == s:
                continue
            lo = R[i - 1] + 1 if i > 0 else w_lo
            hi = R[i] if i < len(R) else w_hi
            iv = interval_of(scope[ino], s)
            if iv is None:
                continue
            a, b = max(lo, iv[0], 1), min(hi, iv[1])
            if a < b:
                ranges.add((a, b))
        if ranges:
            out[ino] = merge(ranges)
    return out


def forget_drops(db, br, tl, rule):
    scope = scope_rows(db, br.path, rule)
    out = {}
    incs = {}
    for ino, intervals in scope.items():
        for inc, _, _, _ in intervals:
            incs.setdefault((ino, inc), None)
    for ino, inc in incs:
        lo, hi, opened = one_row(db, br.path, ino, inc)
        hi = tl.last + 1 if opened else hi
        lo = lo or 1
        if lo < hi:
            out.setdefault(ino, []).append((lo, hi))
    return scope, {ino: merge(r) for ino, r in out.items()}


def one_row(db, branch, ino, inc):
    return db.execute(
        "SELECT MIN(COALESCE(lo, 0)), MAX(hi), MAX(hi IS NULL) FROM paths WHERE branch=? AND ino=? AND inc=?",
        (branch, ino, inc),
    ).fetchone()


def compute(db, br, tl, rule, args, all_rules, now):
    if rule.kind == "forget":
        return forget_drops(db, br, tl, rule)[1], set()
    return stitch(frame(db, br, tl, rule, args, all_rules, now), rule, tl)


def enforced_since(db, branch, at):
    return one(db, "SELECT 1 FROM gc_runs WHERE branch=? AND at>=? AND freed>0 LIMIT 1", branch, at) is not None


def in_scope(rule, path):
    if rule.id == BUILTIN:
        return builtin_match(path, rule.paths)
    return any(under(path, s) for s in rule.paths)


def render(db, br, tl, args, now, touched_paths=None):
    changed = set()
    all_rules = [builtin_rule(args)] + rules(db)
    demoted = False
    for rule in all_rules:
        done = one(db, "SELECT at FROM rendered WHERE rule=? AND branch=?", rule.id, br.path)
        if done is not None and not rule.open:
            continue
        if done is not None and touched_paths is not None and not any(in_scope(rule, p) for p in touched_paths):
            continue
        drops, demote = compute(db, br, tl, rule, args, all_rules, now)
        old = {}
        for ino, lo, hi in db.execute("SELECT ino, lo, hi FROM drops WHERE rule=? AND branch=?", (rule.id, br.path)):
            old.setdefault(ino, []).append((lo, hi))
        if old and enforced_since(db, br.path, rule.created):
            for ino, r in old.items():
                drops[ino] = merge(drops.get(ino, []) + r)
        old = {ino: merge(r) for ino, r in old.items()}
        if old != drops:
            db.execute("DELETE FROM drops WHERE rule=? AND branch=?", (rule.id, br.path))
            db.executemany(
                "INSERT INTO drops VALUES (?, ?, ?, ?, ?)",
                [(rule.id, br.path, ino, lo, hi) for ino, r in drops.items() for lo, hi in r],
            )
            changed |= {i for i in set(old) | set(drops) if old.get(i) != drops.get(i)}
        if demote:
            demoted |= demote_cnos(db, br, rule, demote)
        db.execute("INSERT OR REPLACE INTO rendered VALUES (?, ?, ?)", (rule.id, br.path, now))
    db.commit()
    if changed or demoted:
        write_policy(db, br, args)
        bump(db)
    return changed, demoted


def demote_cnos(db, br, rule, cnos):
    done = []
    for batch in chunks(sorted(cnos), 256):
        if subprocess.run(["chcp", "cp", br.device, *map(str, batch)], capture_output=True).returncode == 0:
            done += batch
        else:
            for c in batch:
                if subprocess.run(["chcp", "cp", br.device, str(c)], capture_output=True).returncode == 0:
                    done.append(c)
    if not done:
        return False
    db.executemany("UPDATE checkpoints SET ss=0 WHERE branch=? AND cno=?", [(br.path, c) for c in done])
    params = rule.p
    params.setdefault("demoted", {}).setdefault(br.path, []).extend(done)
    db.execute("UPDATE policy SET params=? WHERE id=?", (json.dumps(params), rule.id))
    return True


def policy_file(args, br):
    return os.path.join(args.state, br.name + ".policy")


def write_policy(db, br, args):
    path = policy_file(args, br)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        for ino, lo, hi in db.execute(
            "SELECT ino, lo, hi FROM drops WHERE branch=? AND ino>=11 ORDER BY ino, lo", (br.path,)
        ):
            f.write(f"{ino} {lo} {hi}\n")
    os.replace(tmp, path)


def foreign_cp_mounts(br, args):
    out = subprocess.run(["findmnt", "-rn", "-t", "nilfs2", "-o", "TARGET,SOURCE,OPTIONS"], capture_output=True, text=True).stdout
    found = []
    for line in out.splitlines():
        target, source, options = (line.split(" ") + ["", ""])[:3]
        if os.path.realpath(source) == os.path.realpath(br.device) and "cp=" in options:
            if not target.startswith(args.mount_dir + "/"):
                found.append(target)
    return found


def view_fds(args):
    prefix = args.mount_dir + "/"
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            for fd in os.listdir(f"/proc/{pid}/fd"):
                try:
                    if os.readlink(f"/proc/{pid}/fd/{fd}").startswith(prefix):
                        return True
                except OSError:
                    pass
        except OSError:
            pass
    return False


def dirty_segments(br, among=None):
    if among is None:
        windows = [[]]
    else:
        spans = []
        for seg in sorted(among):
            if spans and seg - spans[-1][1] <= LSSU_GAP:
                spans[-1][1] = seg
            else:
                spans.append([seg, seg])
        windows = [["-a", "-i", str(lo), "-n", str(hi - lo + 1)] for lo, hi in spans]
    segs = set()
    for window in windows:
        out = subprocess.run(["lssu", *window, br.device], capture_output=True, text=True, check=True).stdout
        for line in out.splitlines()[1:]:
            f = line.split()
            if len(f) >= 5 and "d" in f[3] and "a" not in f[3] and "e" not in f[3]:
                segs.add(int(f[0]))
    return segs if among is None else segs & set(among)


def reclaim(db, br, tl, args, force=False, dry_run=False):
    st = os.statvfs(br.path)
    free = st.f_bavail / st.f_blocks if st.f_blocks else 1
    if not force and free >= args.reclaim_free:
        return None
    threshold = args.reclaim_dead * br.bps
    head = br.read("segctor/last_pseg_block") // br.bps
    segs = [
        seg
        for seg, dead, oldest in db.execute(
            "SELECT seg, SUM(n), MIN(s) FROM lives INDEXED BY lives_dead WHERE branch=? AND dead=1 AND seg IS NOT NULL "
            "GROUP BY seg ORDER BY 3",
            (br.path,),
        )
        if dead >= threshold and seg != head
    ]
    candidates = dirty_segments(br, segs) if segs else set()
    segs = [seg for seg in segs if seg in candidates]
    if not segs:
        return {"segments": 0, "freed": 0}
    if dry_run:
        return run_reclaim(br, tl, args, segs, True)
    lock = open(args.lock, "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print(f"{br.path}: write lock held, reclaim postponed", file=sys.stderr)
        return None
    try:
        if foreign_cp_mounts(br, args):
            print(f"{br.path}: checkpoint mounted outside the view, reclaim refused", file=sys.stderr)
            return None
        if view_fds(args):
            print(f"{br.path}: view files open, reclaim postponed", file=sys.stderr)
            return None
        write_policy(db, br, args)
        bump(db)
        time.sleep(1)
        result = run_reclaim(br, tl, args, segs, False)
        pushed = []
        while result.get("protected_segs", 0) >= 4 and starved(br, args) and len(pushed) < 6:
            seg = push_log(br, tl, args, set(segs) | set(pushed))
            if seg is None:
                break
            pushed.append(seg)
            again = run_reclaim(br, tl, args, sorted(dirty_segments(br, segs)), False)
            again["freed_vblks"] = again.get("freed_vblks", 0) + result["freed_vblks"]
            result = again
        after = dirty_segments(br, segs + pushed)
        cleaned = [s for s in segs + pushed if s not in after]
        freed = result["freed_vblks"] * br.bsize
        db.execute("INSERT INTO gc_runs (branch, at, segs, freed) VALUES (?, ?, ?, ?)", (br.path, time.time(), len(cleaned), freed))
        for batch in chunks(cleaned):
            db.execute(
                f"UPDATE lives SET seg=NULL WHERE branch=? AND dead=1 AND seg IN ({marks(batch)})", (br.path, *batch)
            )
        db.commit()
        return {
            "segments": len(cleaned),
            "freed": freed,
            "cleaned": cleaned,
            "protected_segs": result.get("protected_segs", 0),
            "pushed": len(pushed),
        }
    finally:
        lock.close()


def starved(br, args):
    st = os.statvfs(br.path)
    return st.f_bavail < max(args.reclaim_free, 0.05) * st.f_blocks


def push_log(br, tl, args, held):
    head = br.read("segctor/last_pseg_block") // br.bps
    out = subprocess.run(["lssu", "-i", "0", "-n", "64", br.device], capture_output=True, text=True, check=True).stdout
    spare = [
        (int(f[4]), int(f[0]))
        for f in (line.split() for line in out.splitlines()[1:])
        if len(f) >= 5 and "d" in f[3] and "a" not in f[3] and "e" not in f[3] and int(f[0]) != head and int(f[0]) not in held
    ]
    if not spare:
        return None
    seg = max(spare)[1]
    run_reclaim(br, tl, args, [seg], False)
    os.sync()
    return seg


def run_reclaim(br, tl, args, segs, dry_run):
    total = {}
    for batch in chunks(segs, 64):
        cmd = ["nilfs-reclaim", "--policy", policy_file(args, br), "--protcno", str(max(tl.protcno, 1)), br.device, *map(str, batch)]
        if dry_run:
            cmd.insert(1, "--dry-run")
        out = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
        for kv in out.split():
            k, v = kv.split("=")
            total[k] = total.get(k, 0) + int(v)
    total.setdefault("freed_vblks", 0)
    return total


def follow(db, br, touched):
    row = db.execute("SELECT segnum, seq, blocknr FROM scan WHERE branch=?", (br.path,)).fetchone()
    seq, blk = br.head()
    proc = lives(br, "follow", row[0], row[1], row[2], seq, blk)
    end = ingest(db, br, proc, touched)
    if end is None:
        return
    if end[1] < seq:
        print(f"{br.path}: log chain broke at segment {end[0]}; run nas-at backfill", file=sys.stderr)
        db.execute("INSERT OR REPLACE INTO meta VALUES (?, '1')", (f"broken:{br.path}",))
        end = (blk // br.bps, seq, (blk // br.bps) * br.bps)
    db.execute(
        "UPDATE scan SET segnum=?, seq=?, blocknr=?, sysfs_seq=?, sysfs_blk=? WHERE branch=?",
        (*end, seq, blk, br.path),
    )


def backfill(db, br):
    seq, blk = br.head()
    db.execute(
        "INSERT OR REPLACE INTO scan (branch, segnum, seq, blocknr, sysfs_seq, sysfs_blk, events_offset) "
        "VALUES (?, ?, ?, ?, -1, -1, COALESCE((SELECT events_offset FROM scan WHERE branch=?), 0))",
        (br.path, blk // br.bps, seq, (blk // br.bps) * br.bps, br.path),
    )
    db.execute("DELETE FROM meta WHERE key=?", (f"broken:{br.path}",))
    db.commit()
    touched = set()
    segs = sorted(dirty_segments(br)) + [blk // br.bps]
    for i, batch in enumerate(chunks(segs, 256)):
        ingest(db, br, lives(br, "segments", *batch), touched)
        db.commit()
        print(f"{br.path}: {min((i + 1) * 256, len(segs))}/{len(segs)} segments", file=sys.stderr)
    return touched


def walk_branch(db, br, tl):
    touched = sync_dirs(db, br, [""], tl.last, recursive=True)
    orphans = [
        r[0]
        for r in db.execute(
            "SELECT DISTINCT ino FROM lives WHERE branch=? AND e=? AND ino NOT IN "
            "(SELECT ino FROM paths WHERE branch=? AND hi IS NULL)",
            (br.path, OPEN, br.path),
        )
        if r[0] >= 11
    ]
    probe(db, br, orphans)
    bound_incarnations(db, br.path)
    return touched | set(orphans)


def paths_of(db, branch, inos):
    out = set()
    for batch in chunks(inos):
        out |= {r[0] for r in db.execute(f"SELECT path FROM paths WHERE branch=? AND ino IN ({marks(batch)})", (branch, *batch))}
    return out


class History:
    def __init__(self, args):
        self.args = args
        self.db = connect(args.index)
        self.branches = [Branch(b) for b in args.branch]
        self.lock = None

    def hold(self):
        os.makedirs(os.path.dirname(self.args.history_lock), exist_ok=True)
        self.lock = open(self.args.history_lock, "w")
        fcntl.flock(self.lock, fcntl.LOCK_EX)

    def live(self):
        return [br for br in self.branches if br.live]

    def refresh(self, br, walk=False, force=False):
        db, args = self.db, self.args
        if one(db, "SELECT 1 FROM scan WHERE branch=?", br.path) is None:
            index_branch(db, br.path, promote=True)
            touched = backfill(db, br)
            tl = Timeline(db, br.path)
            touched |= walk_branch(db, br, tl)
            db.commit()
            return touched, True
        head = br.head()
        moved = head != db.execute("SELECT sysfs_seq, sysfs_blk FROM scan WHERE branch=?", (br.path,)).fetchone()
        dirs, inos, offset, written_paths = read_events(db, br, args)
        if not (moved or dirs or inos or walk or force):
            bounded = bound_incarnations(db, br.path)
            db.commit()
            return bounded, bool(bounded)
        index_branch(db, br.path, promote=True)
        written = set()
        if moved:
            follow(db, br, written)
        tl = Timeline(db, br.path)
        synced = walk_branch(db, br, tl) if walk else set()
        adopt(db, br.path, written_paths, tl.last)
        synced |= sync_dirs(db, br, dirs, tl.last)
        probe(db, br, (written | inos) - synced)
        touched = written | inos | synced | bound_incarnations(db, br.path)
        db.execute("UPDATE scan SET events_offset=? WHERE branch=?", (offset, br.path))
        db.commit()
        return touched, True

    def apply(self, br, touched, now):
        db = self.db
        tl = Timeline(db, br.path)
        changed, demoted = render(db, br, tl, self.args, now, paths_of(db, br.path, touched))
        if demoted:
            tl = Timeline(db, br.path)
            mark_dead(db, br, tl, all_inos(db, br.path))
        else:
            mark_dead(db, br, tl, touched | changed)
        db.commit()
        return tl

    def catch_up(self):
        now = time.time()
        for br in self.live():
            touched, worked = self.refresh(br)
            if worked:
                self.apply(br, touched, now)

    def settle(self, br, touched, now, reclaim_force=False, dry_run=False):
        db = self.db
        tl = self.apply(br, touched, now)
        result = reclaim(db, br, tl, self.args, force=reclaim_force, dry_run=dry_run)
        if result and result.get("cleaned"):
            moved = set()
            follow(db, br, moved)
            stale = db.execute(
                f"SELECT vblk, n, s FROM lives WHERE branch=? AND dead=0 AND seg IN ({marks(result['cleaned'])})",
                (br.path, *result["cleaned"]),
            ).fetchall()
            probe(db, br, [], also=stale)
            tl = Timeline(db, br.path)
            mark_dead(db, br, tl, moved)
            db.commit()
        return result

    def run(self, walk=False, force=False, reclaim_force=False):
        self.hold()
        now = time.time()
        results, recount, worked_on = {}, set(), set()
        for br in self.live():
            touched, worked = self.refresh(br, walk=walk, force=force)
            if worked or reclaim_force:
                worked_on.add(br.path)
                results[br.path] = self.settle(br, touched, now, reclaim_force=reclaim_force)
                if touched or (results[br.path] or {}).get("cleaned"):
                    recount.add(br.path)
        self.metrics(recount=recount, worked_on=worked_on)
        return results

    def metrics(self, recount=None, worked_on=None):
        args, db = self.args, self.db
        recount_days(
            db,
            [
                br
                for br in self.live()
                if recount is None
                or br.path in recount
                or one(db, "SELECT 1 FROM history_days WHERE branch=?", br.path) is None
            ],
        )
        if not args.metrics:
            return
        lines = [
            "# HELP nas_checkpoints Checkpoints on this branch.",
            "# TYPE nas_checkpoints gauge",
            "# HELP nas_checkpoint_snapshots Checkpoints that are snapshots, the instants history can return to.",
            "# TYPE nas_checkpoint_snapshots gauge",
            "# HELP nas_branch_used_ratio Space used on the branch.",
            "# TYPE nas_branch_used_ratio gauge",
            "# HELP nas_branch_size_bytes Branch capacity, for projecting when writes will stop.",
            "# TYPE nas_branch_size_bytes gauge",
            "# HELP nas_history_bytes Block bytes by state: current, retained history, reclaimable, freed so far.",
            "# TYPE nas_history_bytes gauge",
            "# HELP nas_history_metadata_bytes Used bytes not attributed to any file block: NILFS metadata and untracked blocks.",
            "# TYPE nas_history_metadata_bytes gauge",
            "# HELP nas_history_rules Active history rules.",
            "# TYPE nas_history_rules gauge",
            "# HELP nas_metrics_timestamp_seconds When this file was last written.",
            "# TYPE nas_metrics_timestamp_seconds gauge",
        ]
        published = published_counts(args.metrics) if worked_on is not None else {}
        for br in self.live():
            label = br.name
            counts = published.get(label) if br.path not in (worked_on or ()) else None
            checkpoints, snapshots = counts or (br.read("checkpoints/checkpoints_number"), br.read("checkpoints/snapshots_number"))
            st = os.statvfs(br.path)
            size = st.f_blocks * st.f_frsize
            used = (st.f_blocks - st.f_bfree) * st.f_frsize
            current, retained_b, reclaimable = db.execute(
                "SELECT COALESCE(SUM(current), 0), COALESCE(SUM(retained), 0), COALESCE(SUM(reclaimable), 0) "
                "FROM history_days WHERE branch=?",
                (br.path,),
            ).fetchone()
            freed = one(db, "SELECT COALESCE(SUM(freed), 0) FROM gc_runs WHERE branch=?", br.path)
            tracked = current + retained_b + reclaimable
            lines += [
                f'nas_checkpoints{{branch="{label}"}} {checkpoints}',
                f'nas_checkpoint_snapshots{{branch="{label}"}} {snapshots}',
                f'nas_branch_used_ratio{{branch="{label}"}} {used / size if size else 0:.6f}',
                f'nas_branch_size_bytes{{branch="{label}"}} {size}',
                f'nas_history_bytes{{branch="{label}",state="current"}} {current}',
                f'nas_history_bytes{{branch="{label}",state="retained"}} {retained_b}',
                f'nas_history_bytes{{branch="{label}",state="reclaimable"}} {reclaimable}',
                f'nas_history_bytes{{branch="{label}",state="freed"}} {freed}',
                f'nas_history_metadata_bytes{{branch="{label}"}} {max(0, used - tracked)}',
            ]
        lines.append(f"nas_history_rules {one(db, 'SELECT COUNT(*) FROM policy WHERE undone IS NULL')}")
        lines.append(f"nas_metrics_timestamp_seconds {int(time.time())}")
        tmp = args.metrics + ".tmp"
        with open(tmp, "w") as f:
            f.write("\n".join(lines) + "\n")
        os.replace(tmp, args.metrics)


MOUNT_SPACING = 0.5
REMOUNT_SETTLE = 10.0


class Mounts:
    def __init__(self, base, lock, suspend, idle, limit, on_evict):
        self.base = base
        self.on_evict = on_evict
        self.lock = lock
        self.suspend = suspend
        self.idle = idle
        self.limit = limit
        self.used = {}
        self.released = {}
        self.last_mount = 0.0
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
            if device is None or (self.suspend and os.path.exists(self.suspend)):
                self.used.pop(target, None)
                return None
            self.wait_for_quiet_root(target)
            mount_checkpoint(self.lock, device, cno, target)
            self.last_mount = time.monotonic()
            if not os.path.ismount(target):
                self.used.pop(target, None)
                return None
        self.evict()
        return target

    def wait_for_quiet_root(self, target):
        ready = max(self.last_mount + MOUNT_SPACING, self.released.get(target, 0.0) + REMOUNT_SETTLE)
        delay = ready - time.monotonic()
        if delay > 0:
            time.sleep(delay)
        self.released.pop(target, None)

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
                        self.released[target] = time.monotonic()
                        evicted = True
                        excess -= 1
                        try:
                            os.rmdir(target)
                        except OSError:
                            pass
        if evicted:
            self.on_evict()


def mount_checkpoint(lock, device, cno, target):
    os.makedirs(target, exist_ok=True)
    with open(lock, "w") as held:
        try:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            done = None
        else:
            done = subprocess.run(["mount.nilfs2", "-o", f"ro,nogc,cp={cno}", device, target], capture_output=True)
    if done is None or done.returncode != 0:
        if done is not None:
            print(f"mount cp {cno} at {target} failed: {done.stderr.decode().strip()}", file=sys.stderr)
        try:
            os.rmdir(target)
        except OSError:
            pass


class Resolver:
    def __init__(self, db, guard, mounts):
        self.db = db
        self.guard = guard
        self.mounts = mounts

    def q(self, sql, *args):
        with self.guard:
            return one(self.db, sql, *args)

    def at(self, branch, t):
        return self.q("SELECT MAX(cno) FROM checkpoints WHERE branch=? AND ss=1 AND epoch<=?", branch, int(t))

    def before(self, branch, cno):
        return self.q("SELECT MAX(cno) FROM checkpoints WHERE branch=? AND ss=1 AND cno<?", branch, cno)

    def dropped(self, branch, ino, cno):
        if ino < 11:
            return None
        return self.q("SELECT MIN(lo) FROM drops WHERE branch=? AND ino=? AND lo<=? AND ?<hi", branch, ino, cno, cno)

    def resolve(self, branch, cno, rel):
        parts = [p for p in rel.split("/") if p]
        for _ in range(64):
            if cno is None:
                return None
            root = self.mounts.path(branch, cno)
            if root is None:
                return None
            current, jumped = root, False
            for part in parts:
                current = os.path.join(current, part)
                try:
                    st = os.lstat(current)
                except (FileNotFoundError, NotADirectoryError):
                    return None
                lo = self.dropped(branch, st.st_ino, cno)
                if lo is not None:
                    cno = self.before(branch, lo)
                    jumped = True
                    break
            if not jumped:
                return cno, current
        return None

    def visible(self, branch, cno, directory, names):
        out = []
        inos = {}
        for name in names:
            try:
                inos[name] = os.lstat(os.path.join(directory, name)).st_ino
            except OSError:
                pass
        hit = set()
        for batch in chunks(list(set(inos.values()))):
            with self.guard:
                hit |= {
                    r[0]
                    for r in self.db.execute(
                        f"SELECT DISTINCT ino FROM drops WHERE branch=? AND lo<=? AND ?<hi AND ino IN ({marks(batch)})",
                        (branch, cno, cno, *batch),
                    )
                }
        for name, ino in inos.items():
            out.append((name, ino in hit))
        return out


class Deltas:
    def __init__(self, points, streams, cache_dir, cap):
        self.points = points
        self.roots = dict(streams)
        self.cache_dir = cache_dir
        self.cap = cap
        self.stores = {}
        self.trees = {}
        self.cached = OrderedDict()
        self.size = 0
        self.dirs = {}
        self.checked = -60.0
        shutil.rmtree(cache_dir, ignore_errors=True)

    def registered(self):
        if self.points is not None and time.monotonic() - self.checked > 30:
            try:
                rows = self.points.execute("SELECT stream, index_dir, data_dir FROM delta_streams").fetchall()
            except sqlite3.OperationalError:
                rows = []
            self.dirs = {name: (index, data) for name, index, data in rows if name in self.roots}
            self.checked = time.monotonic()
        return self.dirs

    def store(self, name):
        if name not in self.stores:
            import stream_delta

            self.stores[name] = stream_delta.Store(*self.registered()[name], write=False)
        return self.stores[name]

    def owner(self, rel):
        for name in self.registered():
            root = self.roots[name]
            if rel == root or rel.startswith(root + "/"):
                return name, rel[len(root) + 1 :]
        return None

    def point(self, name, t):
        found = self.store(name).point_at(t)
        return found[0] if found else None

    def ancestry(self, rel, t):
        for name in self.registered():
            root = self.roots[name]
            if (rel == "" or root.startswith(rel + "/")) and self.point(name, t) is not None:
                yield root[len(rel) + 1 :].split("/", 1)[0] if rel else root.split("/", 1)[0]

    def tree(self, name, point):
        key = (name, point)
        if key not in self.trees:
            if len(self.trees) >= 8:
                self.trees.clear()
            files = self.store(name).tree(point)
            dirs = {rel.rsplit("/", 1)[0] for rel in files if "/" in rel}
            for d in list(dirs):
                while "/" in d:
                    d = d.rsplit("/", 1)[0]
                    dirs.add(d)
            self.trees[key] = (files, dirs)
        return self.trees[key]

    def real(self, name, t, sub):
        point = self.point(name, t)
        if point is None:
            raise OSError(errno.ENOENT, sub)
        if sub == "":
            return None
        files, dirs = self.tree(name, point)
        if sub in dirs:
            return None
        if sub not in files:
            raise OSError(errno.ENOENT, sub)
        return self.render(name, point, sub, files[sub])

    def children(self, name, t, sub):
        files, dirs = self.tree(name, self.point(name, t))
        prefix = sub + "/" if sub else ""
        return sorted({rel[len(prefix) :].split("/", 1)[0] for group in (files, dirs) for rel in group if rel.startswith(prefix)})

    def render(self, name, point, sub, entry):
        store = self.store(name)
        version = store.region_version(point, sub) if entry is None else entry[3]
        path = os.path.join(self.cache_dir, name, f"v{version}", sub)
        if path in self.cached:
            self.cached.move_to_end(path)
            return path
        data, external = store.render(version, sub, entry)
        if external:
            raise OSError(errno.EFBIG, sub)
        stamp = store.captured(version) if entry is None else entry[2]
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path + ".tmp", "wb") as f:
            f.write(data)
        os.utime(path + ".tmp", (stamp, stamp))
        os.rename(path + ".tmp", path)
        self.cached[path] = len(data)
        self.size += len(data)
        while self.size > self.cap and len(self.cached) > 1:
            old, n = self.cached.popitem(last=False)
            self.size -= n
            try:
                os.unlink(old)
            except FileNotFoundError:
                pass
        return path


class View:
    def __init__(self, args):
        self.branches = args.branch
        self.index = connect(args.index, timeout=2)
        self.index_lock = threading.Lock()
        self.indexed_at = 0.0
        self.generation = generation(self.index)
        self.streams = [s.split("=", 1) for s in args.stream]
        self.points = sqlite3.connect(args.points, timeout=60, check_same_thread=False) if args.points else None
        self.deltas = Deltas(self.points, self.streams, args.delta_cache, args.delta_cache_bytes)
        self.cache = {}
        self.settle = args.settle
        self.mounts = Mounts(args.mount_dir, args.lock, args.suspend, args.idle, args.max_mounts, self.cache.clear)
        self.resolver = Resolver(self.index, self.index_lock, self.mounts)

    def refresh(self):
        with self.index_lock:
            g = generation(self.index)
            if g != self.generation:
                self.generation = g
                self.cache.clear()
            if time.monotonic() - self.indexed_at < 5:
                return
            for branch in self.branches:
                try:
                    if index_branch(self.index, branch, promote=True):
                        self.cache.clear()
                except (subprocess.CalledProcessError, sqlite3.OperationalError) as e:
                    print(f"index {branch}: {e}", file=sys.stderr)
            self.indexed_at = time.monotonic()

    def generations(self, count=24, bucket=900):
        with self.index_lock:
            rows = self.index.execute(
                "SELECT MAX(epoch) FROM checkpoints WHERE ss=1 GROUP BY epoch / ? ORDER BY 1 DESC LIMIT ?", (bucket, count)
            ).fetchall()
        return [time.strftime(GMT, time.gmtime(e)) for (e,) in rows]

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

    def point_streams(self):
        delta = self.deltas.registered()
        return [(name, root) for name, root in self.streams if name not in delta]

    def stream_point(self, rel, t):
        for name, root in self.point_streams():
            if rel == root or rel.startswith(root + "/"):
                row = self.point_at(name, t)
                return ("point", row) if row else ("none",)
        return None

    def stream_ancestry(self, rel, t):
        for name, root in self.point_streams():
            if rel == "" or root.startswith(rel + "/"):
                row = self.point_at(name, t)
                if row:
                    yield root, row

    def resolve(self, branch, t, rel):
        settled = time.time() - self.settle
        if t > settled:
            return self._resolve(branch, settled, rel)
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
            if point[0] == "none" or point[1][0] != branch:
                return None
            return self.resolver.resolve(branch, point[1][1], rel)
        found = self.resolver.resolve(branch, self.resolver.at(branch, t), rel)
        if found is not None:
            return found
        for _, (point_branch, cno) in self.stream_ancestry(rel, t):
            if point_branch == branch:
                found = self.resolver.resolve(branch, cno, rel)
                if found and os.path.isdir(found[1]):
                    return found
        return None

    def split(self, path):
        parts = path.strip("/").split("/", 1)
        if not parts[0]:
            return None, ""
        try:
            t = parse_time(parts[0])
        except ValueError:
            raise OSError(errno.ENOENT, "not a time")
        return t, parts[1] if len(parts) > 1 else ""

    def real(self, path):
        t, rel = self.split(path)
        if t is None:
            return None
        owned = self.deltas.owner(rel)
        if owned is not None:
            return self.deltas.real(owned[0], t, owned[1])
        self.refresh()
        for branch in self.branches:
            found = self.resolve(branch, t, rel)
            if found is not None:
                return found[1]
        if any(self.deltas.ancestry(rel, t)):
            return None
        raise OSError(errno.ENOENT, path)

    def listing(self, path):
        t, rel = self.split(path)
        owned = self.deltas.owner(rel)
        if owned is not None:
            return self.deltas.children(owned[0], t, owned[1])
        names = set(self.deltas.ancestry(rel, t))
        for branch in self.branches:
            found = self.resolve(branch, t, rel)
            if found is None or not os.path.isdir(found[1]):
                continue
            cno, real = found
            for name, dropped in self.resolver.visible(branch, cno, real, os.listdir(real)):
                if not dropped or self.resolve(branch, t, f"{rel}/{name}" if rel else name) is not None:
                    names.add(name)
        for root, (point_branch, _) in self.stream_ancestry(rel, t):
            if point_branch in self.branches:
                names.add(root[len(rel) + 1 :].split("/", 1)[0] if rel else root.split("/", 1)[0])
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
                return [".", ".."] + view.generations()
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


def locate(args, path):
    path = os.path.abspath(path)
    for root in [args.pool] + args.branch:
        if path == root or path.startswith(root + "/"):
            rel = os.path.relpath(path, root)
            return "" if rel == "." else rel
    if path == args.view or path.startswith(args.view + "/"):
        rel = os.path.relpath(path, args.view).split("/", 1)
        return rel[1] if len(rel) > 1 else ""
    sys.exit(f"{path} is not under {args.pool}")


def edits_of(db, branch, rel, bsize):
    rows = db.execute("SELECT ino, inc, lo, hi FROM paths WHERE branch=? AND path=?", (branch, rel)).fetchall()
    out = {}
    for ino, inc, lo, hi in rows:
        drops = load_drops(db, branch, [ino]).get(ino, [])
        for s, e, n, off, seg, dead in db.execute(
            "SELECT s, e, n, off, seg, dead FROM lives WHERE branch=? AND ino=?", (branch, ino)
        ):
            if (lo is not None and s < lo) or (hi is not None and s >= hi):
                continue
            key = (s, ino)
            ed = out.setdefault(key, {"branch": branch, "ino": ino, "inc": inc, "s": s, "bytes": 0, "live": False,
                                      "dropped": covered(drops, s), "freed": True, "e": 0})
            if off >= 0:
                ed["bytes"] += n * bsize
            ed["live"] |= e == OPEN
            ed["freed"] &= seg is None
            ed["e"] = max(ed["e"], e)
    return list(out.values())


def history_of(h, rel):
    eds = []
    for br in h.live():
        tl = Timeline(h.db, br.path)
        for ed in edits_of(h.db, br.path, rel, br.bsize):
            ed["epoch"] = tl.epoch.get(ed["s"], 0)
            ed["tl"] = tl
            eds.append(ed)
    eds.sort(key=lambda ed: (ed["epoch"], ed["s"]), reverse=True)
    n = 0
    for ed in eds:
        if ed["dropped"]:
            ed["n"] = None
        else:
            ed["n"] = n
            n += 1
    return eds


def run_log(args):
    h = History(args)
    h.hold()
    h.catch_up()
    rel = locate(args, args.path)
    eds = history_of(h, rel)
    starts = {}
    for ed in sorted(eds, key=lambda ed: ed["epoch"]):
        k = (ed["branch"], ed["ino"], ed["inc"])
        starts.setdefault(k, ed)
    moved = set()
    previous = None
    for k, ed in sorted(starts.items(), key=lambda kv: kv[1]["epoch"]):
        if previous and previous[0] != k[0]:
            moved.add(k)
        previous = k
    print(f"{rel or '/'}")
    applying = [r for r in [builtin_rule(args)] + rules(h.db) if r.kind != "pin" and (
        builtin_match(rel, r.paths) if r.id == BUILTIN else any(under(rel, p) for p in r.paths))]
    for r in applying:
        if r.id == BUILTIN:
            print(f"  historyless by default ({' '.join(r.paths)})")
        else:
            print(f"  {r.describe()}")
    for r in rules(h.db):
        if r.kind == "pin" and r.paths[0] == rel:
            print(f"  {r.describe()} at checkpoint {r.p.get('cno')}")
    if any(r.kind == "forget" for r in applying):
        print("  tagged: deleted")
    print(f"  {'N':>4}  {'WHEN':19}  {'CNO':>9}  {'BRANCH':8}  {'BYTES':>8}  STATE")
    for ed in eds:
        if ed["live"]:
            state = "current" if ed["e"] == OPEN and ed["n"] == 0 else "partly current"
        elif ed["dropped"]:
            state = "compressed, freed" if ed["freed"] else "compressed, awaiting reclaim"
        else:
            state = "retained"
        if (ed["branch"], ed["ino"], ed["inc"]) in moved and starts.get((ed["branch"], ed["ino"], ed["inc"])) is ed:
            state += ", moved"
        n = "-" if ed["n"] is None else str(ed["n"])
        print(f"  {n:>4}  {local(ed['epoch']):19}  {ed['s']:>9}  {os.path.basename(ed['branch']):8}  {human(ed['bytes']):>8}  {state}")


def run_top(args):
    h = History(args)
    rel = locate(args, args.dir) if args.dir else ""
    rows = []
    for br in h.live():
        sql = (
            "SELECT p.path, COALESCE(SUM(t.data), 0), COALESCE(SUM(t.ret + t.rec), 0) "
            "FROM paths p "
            "JOIN (SELECT ino, inc, MIN(COALESCE(lo, 0)) AS start FROM paths WHERE branch=? GROUP BY ino, inc) b "
            "ON b.ino=p.ino AND b.inc=p.inc "
            "JOIN tallies t ON t.branch=p.branch AND t.ino=p.ino AND t.s>=b.start "
            "WHERE p.branch=? AND p.hi IS NULL"
        )
        params = [br.path, br.path]
        if rel:
            sql += " AND (p.path=? OR (p.path>=? AND p.path<?))"
            params += [rel, rel + "/", rel + "0"]
        sql += " GROUP BY p.path"
        for path, cur, hist in h.db.execute(sql, params):
            rows.append((path, cur * br.bsize, hist * br.bsize, br.name))
    key = {"size": lambda r: r[1], "history": lambda r: r[2], "ratio": lambda r: r[2] / max(r[1], 4096)}[args.by]
    rows.sort(key=key, reverse=True)
    print(f"{'SIZE':>9}  {'HISTORY':>9}  {'RATIO':>7}  {'BRANCH':8}  PATH")
    for path, cur, hist, name in rows[: args.n]:
        print(f"{human(cur):>9}  {human(hist):>9}  {hist / max(cur, 4096):7.2f}  {name:8}  {path}")


def resolver_for(h):
    mounts = Mounts(os.path.join(h.args.mount_dir, f"revert-{os.getpid()}"), h.args.lock, h.args.suspend, h.args.idle, h.args.max_mounts, lambda: None)
    return Resolver(h.db, threading.Lock(), mounts), mounts


def snap(db, branch, rel, cno):
    for _ in range(256):
        lo = one(
            db,
            "SELECT MIN(d.lo) FROM drops d JOIN paths p ON d.branch=p.branch AND d.ino=p.ino "
            "WHERE p.branch=? AND (p.path=? OR (p.path>=? AND p.path<?)) AND d.lo<=? AND ?<d.hi",
            branch, rel, rel + "/", rel + "0", cno, cno,
        ) if rel else one(db, "SELECT MIN(lo) FROM drops WHERE branch=? AND lo<=? AND ?<hi", branch, cno, cno)
        if lo is None:
            return cno
        cno = one(db, "SELECT MAX(cno) FROM checkpoints WHERE branch=? AND ss=1 AND cno<?", branch, lo)
        if cno is None:
            return None
    return None


def run_revert(args):
    h = History(args)
    h.hold()
    h.catch_up()
    rel = locate(args, args.path)
    target = os.path.join(args.pool, rel)
    resolver, mounts = resolver_for(h)
    try:
        if args.n is not None:
            eds = [ed for ed in history_of(h, rel) if ed["n"] == args.n]
            if not eds:
                sys.exit(f"{rel}: no retained version {args.n}; see nas-at log")
            ed = eds[0]
            drops = load_drops(h.db, ed["branch"], [ed["ino"]]).get(ed["ino"], [])
            tl = ed["tl"]
            cno = next((c for c in tl.ss if ed["s"] <= c < ed["e"] and not covered(drops, c)), None)
            found = resolver.resolve(ed["branch"], cno, rel) if cno else None
            if found is None:
                sys.exit(f"{rel}: version {args.n} is not addressable")
            copy_in(found[1], target)
            print(f"reverted {rel} to version {args.n} (checkpoint {found[0]}, {local(tl.epoch[found[0]])})")
            return
        t = parse_time(args.at)
        sources = {}
        latest = None
        for br in h.live():
            c = resolver.at(br.path, t)
            c = snap(h.db, br.path, rel, c) if c else None
            if c is None:
                continue
            found = resolver.resolve(br.path, c, rel)
            if found is not None:
                epoch = Timeline(h.db, br.path).epoch[found[0]]
                sources[br.path] = found
                print(f"{br.name}: {rel or '/'} as of checkpoint {found[0]} ({local(epoch)})")
                if latest is None or epoch > latest[0]:
                    latest = (epoch, found[1])
        if not sources:
            sys.exit(f"{rel or '/'} did not exist at {local(t)}")
        if not os.path.isdir(latest[1]):
            copy_in(latest[1], target)
            return
        revert_tree(args, sources, rel, target)
    finally:
        mounts.evict(everything=True)
        for dirpath, _, _ in sorted(os.walk(mounts.base), reverse=True):
            try:
                os.rmdir(dirpath)
            except OSError:
                pass


def copy_in(src, dst):
    if os.path.islink(src):
        if os.path.lexists(dst):
            os.unlink(dst)
        os.symlink(os.readlink(src), dst)
        return
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if os.path.isdir(dst) and not os.path.islink(dst):
        shutil.rmtree(dst)
    with open(src, "rb") as fin, open(dst, "wb") as fout:
        shutil.copyfileobj(fin, fout, 1 << 20)
    st = os.lstat(src)
    os.utime(dst, ns=(st.st_atime_ns, st.st_mtime_ns))


def tree(root):
    out = {}
    for dirpath, dirnames, filenames in os.walk(root):
        for name in dirnames + filenames:
            full = os.path.join(dirpath, name)
            out[os.path.relpath(full, root)] = full
    return out


def revert_tree(args, sources, rel, target):
    wanted = {}
    for _, real in sources.values():
        for k, v in tree(real).items():
            wanted.setdefault(k, v)
    copied = removed = kept = 0
    for k in sorted(wanted):
        src, dst = wanted[k], os.path.join(target, k)
        if os.path.isdir(src) and not os.path.islink(src):
            os.makedirs(dst, exist_ok=True)
            continue
        if os.path.lexists(dst) and not os.path.isdir(dst) and same_file(src, dst):
            continue
        copy_in(src, dst)
        copied += 1
    current = tree(target) if os.path.isdir(target) else {}
    for k in sorted(current, reverse=True):
        if k in wanted:
            continue
        full = current[k]
        on_nilfs = any(os.path.lexists(os.path.join(b, rel, k)) for b in sources)
        if not on_nilfs:
            print(f"kept {os.path.join(rel, k)}: newer than the revert point but has no history to return to")
            kept += 1
            continue
        if os.path.isdir(full) and not os.path.islink(full):
            try:
                os.rmdir(full)
            except OSError:
                continue
        else:
            os.unlink(full)
        removed += 1
    print(f"{copied} copied, {removed} removed (still in history), {kept} kept")


def same_file(a, b):
    sa, sb = os.lstat(a), os.lstat(b)
    if sa.st_size != sb.st_size or stat.S_IFMT(sa.st_mode) != stat.S_IFMT(sb.st_mode):
        return False
    if stat.S_ISLNK(sa.st_mode):
        return os.readlink(a) == os.readlink(b)
    with open(a, "rb") as fa, open(b, "rb") as fb:
        while True:
            x, y = fa.read(1 << 20), fb.read(1 << 20)
            if x != y:
                return False
            if not x:
                return True


def new_rule(h, paths, kind, params, lo=None, hi=None):
    params["created_cno"] = {br.path: Timeline(h.db, br.path).last for br in h.live()}
    cur = h.db.execute(
        "INSERT INTO policy (paths, rule, params, lo, hi, created) VALUES (?, ?, ?, ?, ?, ?)",
        (json.dumps(paths), kind, json.dumps(params), lo, hi, time.time()),
    )
    h.db.commit()
    return cur.lastrowid


def savings(h, rule, args, cache):
    now = time.time()
    total_new = total_hist = 0
    for br in h.live():
        if br.path not in cache:
            tl = Timeline(h.db, br.path)
            all_rules = [builtin_rule(args)] + rules(h.db)
            scope = scope_rows(h.db, br.path, rule)
            fr = frame(h.db, br, tl, rule, args, all_rules, now, scope)
            closed = {}
            for ino, s, e, n in ino_rows(
                h.db,
                f"SELECT ino, s, e, SUM(n) FROM lives WHERE branch=?{{inos}} AND e<{OPEN} AND seg IS NOT NULL AND dead=0 GROUP BY ino, s, e",
                br.path,
                scope,
            ):
                closed.setdefault(ino, []).append((s, e, n))
            existing = load_drops(h.db, br.path, list(closed))
            w_lo = tl.first_at(rule.lo) if rule.lo else 0
            w_hi = tl.first_after(rule.hi) if rule.hi else OPEN
            hist = sum(n for rs in closed.values() for s, _, n in rs if w_lo <= s < w_hi) * br.bsize
            cache[br.path] = tl, fr, closed, existing, hist
        tl, fr, closed, existing, hist = cache[br.path]
        drops, demote = stitch(fr, rule, tl)
        ss = [c for c in tl.ss if c not in demote] if demote else tl.ss
        total_hist += hist
        for ino, rs in closed.items():
            ranges = merge(existing.get(ino, []) + drops[ino]) if ino in drops else existing.get(ino, [])
            for s, e, n in rs:
                if e <= tl.protcno and not retained(s, e, ranges, ss):
                    total_new += n * br.bsize
    return total_new, total_hist


def run_keep(args):
    h = History(args)
    h.hold()
    h.catch_up()
    paths = sorted({locate(args, p) for p in args.paths})
    future = args.from_ == "now"
    lo = None if future or args.from_ is None else parse_time(args.from_)
    hi = parse_time(args.until) if args.until else None
    params = {"landmarks": not args.no_landmarks, "gap": parse_duration(args.gap_text) if args.gap_text else args.gap}
    if future:
        params["future"] = True
    if args.none:
        params["mode"] = "none"
    elif args.continuous:
        params["mode"] = "continuous"
    elif args.pairs:
        params.update(mode="pairs", x=args.x)
    elif args.quantum:
        params.update(mode="quantum", q=parse_duration(args.quantum))
    else:
        if future:
            sys.exit("--target needs a past range")
        params["mode"] = "quantum"
    probe_rule = lambda p: Rule((10**12, json.dumps(paths), "keep", json.dumps(p), lo, hi, time.time(), None))
    cache = {}
    if args.target or args.target_ratio:
        for q in QUANTA:
            freed, hist = savings(h, probe_rule(dict(params, q=q)), args, cache)
            print(f"  quantum {q or 'inf'}: frees {human(freed)} of {human(hist)} history")
            if freed >= parse_size(args.target) if args.target else hist and freed / hist >= args.target_ratio:
                params["q"] = q
                break
        else:
            hint = "" if args.no_landmarks else "; landmarks are kept, --no-landmarks may reach it"
            print(f"target not reachable, the most is {human(freed)}{hint}")
            if not args.dry_run:
                sys.exit(1)
            return
    freed, hist = savings(h, probe_rule(params), args, cache)
    print(f"frees {human(freed)} of {human(hist)} history in range")
    if args.dry_run:
        return
    if future:
        for r in rules(h.db):
            if r.kind == "keep" and r.p.get("future") and all(any(under(p, s) for s in paths) for p in r.paths):
                r.p["future"] = False
                h.db.execute("UPDATE policy SET params=?, hi=? WHERE id=?", (json.dumps(r.p), time.time(), r.id))
                h.db.execute("DELETE FROM rendered WHERE rule=?", (r.id,))
    rid = new_rule(h, paths, "keep", params, lo, hi)
    print(f"rule #{rid}")
    for br in h.live():
        h.settle(br, set(), time.time())
    h.metrics()


def run_forget(args):
    h = History(args)
    h.hold()
    h.catch_up()
    paths = sorted({locate(args, p) for p in args.paths})
    if "" in paths:
        sys.exit("refusing to forget the whole pool")
    pins = [r for r in rules(h.db) if r.kind == "pin" and any(under(r.paths[0], p) for p in paths)]
    for p in paths:
        print(f"forget {p}")
    for r in pins:
        print(f"  drops pin {r.describe()}")
    if not args.yes:
        print("dry run; pass --yes to delete these and their history permanently")
        return
    for p in paths:
        full = os.path.join(args.pool, p)
        if os.path.isdir(full) and not os.path.islink(full):
            shutil.rmtree(full)
        elif os.path.lexists(full):
            os.unlink(full)
    os.sync()
    for r in pins:
        h.db.execute("UPDATE policy SET undone=? WHERE id=?", (time.time(), r.id))
    rid = new_rule(h, paths, "forget", {})
    for br in h.live():
        tl = Timeline(h.db, br.path)
        touched = sync_dirs(h.db, br, {os.path.dirname(p) for p in paths}, tl.last)
        bound_incarnations(h.db, br.path)
        h.settle(br, touched, time.time())
    h.metrics()
    print(f"rule #{rid}")


def run_pin(args):
    h = History(args)
    h.hold()
    h.catch_up()
    rel = locate(args, args.path)
    eds = history_of(h, rel)
    if args.n is not None:
        pick = [ed for ed in eds if ed["n"] == args.n]
    elif args.at:
        t = parse_time(args.at)
        pick = [ed for ed in eds if ed["epoch"] <= t and not ed["dropped"]][:1]
    else:
        pick = [ed for ed in eds if not ed["dropped"]][:1]
    if not pick:
        sys.exit(f"{rel}: no retained version to pin")
    ed = pick[0]
    later = [x["s"] for x in eds if x["branch"] == ed["branch"] and x["s"] > ed["s"]]
    cno = min(later) - 1 if later else Timeline(h.db, ed["branch"]).last
    rid = new_rule(h, [rel], "pin", {"cno": {ed["branch"]: cno}})
    print(f"rule #{rid}: pinned {rel} as of {local(ed['epoch'])} (checkpoint {ed['s']})")


def run_undo(args):
    h = History(args)
    h.hold()
    row = h.db.execute("SELECT * FROM policy WHERE id=?", (args.id,)).fetchone()
    if row is None:
        sys.exit(f"no rule #{args.id}")
    rule = Rule(row)
    if rule.undone:
        sys.exit(f"rule #{args.id} is already undone")
    for br in h.live():
        if rule.kind != "pin" and enforced_since(h.db, br.path, rule.created):
            sys.exit(f"rule #{args.id}: {br.name} has reclaimed space since it was made; its drops are permanent")
    h.db.execute("UPDATE policy SET undone=? WHERE id=?", (time.time(), rule.id))
    for br in h.live():
        for c in rule.p.get("demoted", {}).get(br.path, []):
            if subprocess.run(["chcp", "ss", br.device, str(c)], capture_output=True).returncode == 0:
                h.db.execute("UPDATE checkpoints SET ss=1 WHERE branch=? AND cno=?", (br.path, c))
        affected = [r[0] for r in h.db.execute("SELECT DISTINCT ino FROM drops WHERE rule>=? AND branch=?", (rule.id, br.path))]
        h.db.execute("DELETE FROM drops WHERE rule=? AND branch=?", (rule.id, br.path))
        h.db.execute("DELETE FROM rendered WHERE rule>=? AND branch=?", (rule.id, br.path))
        h.db.commit()
        h.settle(br, set(affected), time.time())
    h.metrics()
    print(f"undid {rule.describe()}")


def run_rules(args):
    h = History(args)
    print(f"#0 historyless by default: {' '.join(args.historyless)}")
    for r in rules(h.db, include_undone=args.all):
        print(r.describe() + (" (undone)" if r.undone else ""))


def run_reclaim_cli(args):
    h = History(args)
    h.hold()
    os.sync()
    for br in h.live():
        touched, _ = h.refresh(br)
        result = h.settle(br, touched, time.time(), reclaim_force=True, dry_run=args.dry_run)
        if result is None:
            print(f"{br.name}: not run")
            continue
        held = result.get("protected_segs", 0)
        held = f"; {held} segments newer than the superblock's log cursor held back" if held else ""
        if result.get("pushed"):
            held += f"; moved {result['pushed']} segments to advance that cursor"
        if args.dry_run:
            blocks = result.get("freed_vblks", 0)
            print(f"{br.name}: would free {human(blocks * br.bsize)} ({blocks} blocks){held}")
        else:
            print(f"{br.name}: {result['segments']} segments cleaned, {human(result['freed'])} freed ({result['freed'] // br.bsize} blocks){held}")
    h.metrics()


def run_index(args):
    db = connect(args.index)
    for branch in args.branch:
        added = index_branch(db, branch, promote=args.promote)
        if added:
            print(f"{branch}: {added} new checkpoints")


def run_pass(args):
    History(args).run(walk=args.walk)


def run_backfill(args):
    h = History(args)
    h.hold()
    for br in h.live():
        index_branch(h.db, br.path, promote=True)
        touched = backfill(h.db, br)
        tl = Timeline(h.db, br.path)
        touched |= walk_branch(h.db, br, tl)
        h.db.commit()
        h.settle(br, touched, time.time())
    h.metrics()


def resolve_cli(args):
    try:
        t = parse_time(args.time)
    except ValueError:
        sys.exit(f"cannot read time {args.time!r}; use e.g. '2026-11-01 14:03:27' or @<epoch>")
    rel = locate(args, args.path)
    view = os.path.join(args.view, f"@{int(t)}", rel)
    if not os.path.lexists(view):
        sys.exit(f"{rel or '/'} did not exist at {local(t)}")
    print(view)


def main():
    parser = argparse.ArgumentParser(prog="nas-at")
    parser.add_argument("--branch", action="append", default=[])
    parser.add_argument("--index", required=True)
    parser.add_argument("--state")
    parser.add_argument("--points")
    parser.add_argument("--stream", action="append", default=[])
    parser.add_argument("--delta-cache", default="/var/cache/nas-at-delta")
    parser.add_argument("--delta-cache-bytes", type=int, default=6 << 30)
    parser.add_argument("--historyless", action="append")
    parser.add_argument("--lock", default="/run/nas-nilfs-write.lock")
    parser.add_argument("--history-lock", default="/run/nas-history.lock")
    parser.add_argument("--suspend")
    parser.add_argument("--metrics")
    parser.add_argument("--mount-dir", default="/run/nas-at")
    parser.add_argument("--view", default="/srv/nas-at")
    parser.add_argument("--pool", default="/srv/nas")
    parser.add_argument("--idle", type=float, default=600)
    parser.add_argument("--settle", type=float, default=120)
    parser.add_argument("--max-mounts", type=int, default=48)
    parser.add_argument("--gap-default", type=int, default=600)
    parser.add_argument("--reclaim-free", type=float, default=0.15)
    parser.add_argument("--reclaim-dead", type=float, default=0.25)
    parser.add_argument("--rotate-bytes", type=int, default=64 << 20)
    sub = parser.add_subparsers(dest="cmd", required=True)
    i = sub.add_parser("index")
    i.add_argument("--promote", action="store_true")
    p = sub.add_parser("pass")
    p.add_argument("--walk", action="store_true")
    sub.add_parser("backfill")
    sub.add_parser("serve")
    r = sub.add_parser("resolve")
    r.add_argument("path")
    r.add_argument("time")
    lg = sub.add_parser("log")
    lg.add_argument("path")
    t = sub.add_parser("top")
    t.add_argument("dir", nargs="?")
    t.add_argument("--by", choices=("size", "history", "ratio"), default="history")
    t.add_argument("-n", type=int, default=20)
    rv = sub.add_parser("revert")
    rv.add_argument("path")
    g = rv.add_mutually_exclusive_group(required=True)
    g.add_argument("-n", type=int)
    g.add_argument("--at")
    f = sub.add_parser("forget")
    f.add_argument("paths", nargs="+")
    f.add_argument("--yes", action="store_true")
    k = sub.add_parser("keep")
    k.add_argument("paths", nargs="+")
    k.add_argument("--from", dest="from_")
    k.add_argument("--until")
    m = k.add_mutually_exclusive_group(required=True)
    m.add_argument("--quantum")
    m.add_argument("--pairs", action="store_true")
    m.add_argument("--none", action="store_true")
    m.add_argument("--continuous", action="store_true")
    m.add_argument("--target")
    m.add_argument("--target-ratio", type=float)
    k.add_argument("-x", type=int, default=1)
    k.add_argument("--no-landmarks", action="store_true")
    k.add_argument("--gap", dest="gap_text")
    k.add_argument("--dry-run", action="store_true")
    pn = sub.add_parser("pin")
    pn.add_argument("path")
    pg = pn.add_mutually_exclusive_group()
    pg.add_argument("-n", type=int)
    pg.add_argument("--at")
    u = sub.add_parser("undo")
    u.add_argument("id", type=int)
    rl = sub.add_parser("rules")
    rl.add_argument("--all", action="store_true")
    rc = sub.add_parser("reclaim")
    rc.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    args.state = args.state or os.path.dirname(args.index)
    args.historyless = args.historyless if args.historyless is not None else ["tmp", ".cache", "*/.cache"]
    args.gap = args.gap_default
    {
        "index": run_index,
        "pass": run_pass,
        "backfill": run_backfill,
        "serve": serve,
        "resolve": resolve_cli,
        "log": run_log,
        "top": run_top,
        "revert": run_revert,
        "forget": run_forget,
        "keep": run_keep,
        "pin": run_pin,
        "undo": run_undo,
        "rules": run_rules,
        "reclaim": run_reclaim_cli,
    }[args.cmd](args)


if __name__ == "__main__":
    main()
