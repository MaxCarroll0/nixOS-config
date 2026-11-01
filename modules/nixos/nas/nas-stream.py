"""Stream receiver and applier: block deltas spooled on the SSD, applied as one NILFS2 snapshot each."""

import argparse
import fcntl
import json
import os
import re
import sqlite3
import struct
import subprocess
import sys
import tempfile
import time

import blockdelta

SCHEMA = """
CREATE TABLE IF NOT EXISTS points (
    stream    TEXT NOT NULL,
    id        TEXT NOT NULL,
    captured  REAL NOT NULL,
    applied   REAL NOT NULL,
    branch    TEXT NOT NULL,
    cno       INTEGER NOT NULL,
    stall_ms  INTEGER,
    bytes     INTEGER NOT NULL,
    PRIMARY KEY (stream, id)
);
CREATE INDEX IF NOT EXISTS points_captured ON points (stream, captured);
"""

ID = re.compile(r"^[0-9]{1,20}$")


def connect(path):
    db = sqlite3.connect(path, timeout=60)
    db.execute("PRAGMA journal_mode=WAL")
    db.executescript(SCHEMA)
    return db


def spool_entries(spool):
    return sorted(n for n in os.listdir(spool) if n.endswith(".delta"))


def spool_bytes(spool):
    return sum(os.path.getsize(os.path.join(spool, n)) for n in os.listdir(spool))


def read_head(path):
    try:
        with open(path) as f:
            return f.read().strip() or None
    except FileNotFoundError:
        return None


def write_atomic(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def valid_header(header, name):
    return (
        isinstance(header, dict)
        and header.get("stream") == name
        and isinstance(header.get("id"), str)
        and ID.match(header["id"])
        and (header.get("base") is None or (isinstance(header["base"], str) and ID.match(header["base"])))
        and isinstance(header.get("captured"), (int, float))
        and isinstance(header.get("full"), bool)
    )


def receive(args):
    sock_in = sys.stdin.buffer
    out = sys.stdout

    def reply(word):
        out.write(word + "\n")
        out.flush()

    raw = sock_in.read(8)
    if len(raw) != 8:
        return reply("error short")
    (length,) = struct.unpack("<Q", raw)
    if spool_bytes(args.spool) + length > args.spool_max:
        return reply("busy")

    fd, tmp = tempfile.mkstemp(dir=args.spool, suffix=".part")
    try:
        with os.fdopen(fd, "wb") as f:
            remaining = length
            while remaining:
                chunk = sock_in.read(min(remaining, 1 << 20))
                if not chunk:
                    return reply("error truncated")
                f.write(chunk)
                remaining -= len(chunk)
            f.flush()
            os.fsync(f.fileno())

        try:
            header = blockdelta.verify(tmp)
        except (blockdelta.DeltaError, ValueError) as e:
            print(f"rejected: {e}", file=sys.stderr)
            return reply("error corrupt")
        if not valid_header(header, args.name):
            return reply("error header")

        with open(args.head + ".lock", "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            head = read_head(args.head)
            if not header["full"] and header["base"] != head:
                print(f"base {header['base']} is not head {head}; asking for a full resync", file=sys.stderr)
                return reply("resync")
            final = os.path.join(args.spool, f"{int(header['id']):020d}.delta")
            os.replace(tmp, final)
            tmp = None
            dfd = os.open(args.spool, os.O_RDONLY | os.O_DIRECTORY)
            os.fsync(dfd)
            os.close(dfd)
            write_atomic(args.head, header["id"])
        print(f"spooled {header['id']} ({length} bytes, full={header['full']})", file=sys.stderr)
        reply("ok")
    finally:
        if tmp is not None and os.path.exists(tmp):
            os.unlink(tmp)


def device_of(mount):
    return subprocess.run(
        ["findmnt", "-no", "SOURCE", mount], check=True, capture_output=True, text=True
    ).stdout.split("\n")[0]


def snapshot(device):
    out = subprocess.run(["mkcp", "-s", "-p", device], check=True, capture_output=True, text=True).stdout
    return int(out.split()[0])


def write_metrics(args, db):
    if not args.metrics:
        return
    row = db.execute(
        "SELECT COUNT(*), MAX(captured), MAX(applied) FROM points WHERE stream=?", (args.name,)
    ).fetchone()
    pending = spool_entries(args.spool)
    label = f'stream="{args.name}"'
    lines = [
        f"nas_stream_points{{{label}}} {row[0]}",
        f"nas_stream_last_captured_seconds{{{label}}} {row[1] or 0}",
        f"nas_stream_last_applied_seconds{{{label}}} {row[2] or 0}",
        f"nas_stream_spool_bytes{{{label}}} {spool_bytes(args.spool)}",
        f"nas_stream_spool_deltas{{{label}}} {len(pending)}",
        f"nas_stream_spool_max_bytes{{{label}}} {args.spool_max}",
        f"nas_stream_head_valid{{{label}}} {0 if read_head(args.head) is None else 1}",
        f"nas_stream_branch_mounted{{{label}}} {1 if os.path.ismount(args.branch) else 0}",
    ]
    write_atomic(args.metrics, "\n".join(lines) + "\n")


def discard_incrementals(args):
    with open(args.head + ".lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        write_atomic(args.head, "")
        for name in spool_entries(args.spool):
            path = os.path.join(args.spool, name)
            with open(path, "rb") as f:
                header = blockdelta.read_header(blockdelta.Reader(f))
            if not header.get("full"):
                os.unlink(path)


def apply_one(args, db, path):
    size = os.path.getsize(path)
    with open(args.lock, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        header = blockdelta.apply(args.root, path)
        cno = snapshot(device_of(args.branch))
    db.execute(
        "INSERT OR IGNORE INTO points VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        (
            args.name,
            header["id"],
            header["captured"],
            time.time(),
            args.branch,
            cno,
            header.get("stall_ms"),
            size,
        ),
    )
    db.commit()
    os.unlink(path)
    lag = time.time() - header["captured"]
    print(f"applied {header['id']} as checkpoint {cno} ({size} bytes, {lag:.1f}s after capture)", file=sys.stderr)


def apply_loop(args):
    db = connect(args.db)
    failed = os.path.join(args.spool, "failed")
    os.makedirs(failed, exist_ok=True)
    while True:
        write_metrics(args, db)
        pending = spool_entries(args.spool)
        if not pending or not os.path.ismount(args.branch):
            time.sleep(2)
            continue
        path = os.path.join(args.spool, pending[0])
        try:
            apply_one(args, db, path)
        except blockdelta.DeltaError as e:
            print(f"{pending[0]} failed: {e}; discarding incrementals until a full resync", file=sys.stderr)
            os.replace(path, os.path.join(failed, pending[0]))
            discard_incrementals(args)


def list_points(args):
    db = connect(args.db)
    for captured, cno, stall, size, branch in db.execute(
        "SELECT captured, cno, stall_ms, bytes, branch FROM points WHERE stream=? ORDER BY captured",
        (args.name,),
    ):
        stamp = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(captured)) + f".{int(captured * 1000) % 1000:03d}"
        print(f"{stamp}  cp {cno:<8} {branch}  stall {stall if stall is not None else '-':>5} ms  {size} B")


def main():
    parser = argparse.ArgumentParser(prog="nas-stream")
    parser.add_argument("--name", required=True)
    parser.add_argument("--spool", required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--db", required=True)
    parser.add_argument("--branch", required=True)
    parser.add_argument("--root", required=True)
    parser.add_argument("--lock", required=True)
    parser.add_argument("--spool-max", type=int, required=True)
    parser.add_argument("--metrics")
    parser.add_argument("cmd", choices=["receive", "apply", "list"])
    args = parser.parse_args()
    os.makedirs(args.spool, exist_ok=True)
    {"receive": receive, "apply": apply_loop, "list": list_points}[args.cmd](args)


if __name__ == "__main__":
    main()
