"""Block delta: a tree diff at 4 KiB granularity, applied with pwrite and verified per file."""

import argparse
import hashlib
import json
import os
import shutil
import stat
import struct
import sys

MAGIC = b"BDLT1\n"
BLOCK = 4096
RUN_MAX = 1 << 20
ZERO = bytes(BLOCK)


class DeltaError(Exception):
    pass


def scan(root):
    entries = {}
    if root is None or not os.path.isdir(root):
        return entries
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in dirnames + sorted(filenames):
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root)
            st = os.lstat(full)
            if stat.S_ISDIR(st.st_mode):
                entries[rel] = ("d", st)
            elif stat.S_ISLNK(st.st_mode):
                entries[rel] = ("l", st)
            elif stat.S_ISREG(st.st_mode):
                entries[rel] = ("f", st)
    return entries


def same_file(a, b):
    return (a.st_ino, a.st_size, a.st_mtime_ns, a.st_ctime_ns, a.st_mode) == (
        b.st_ino,
        b.st_size,
        b.st_mtime_ns,
        b.st_ctime_ns,
        b.st_mode,
    )


class Writer:
    def __init__(self, out):
        self.out = out
        self.digest = hashlib.sha256()
        self.records = 0

    def raw(self, data):
        self.digest.update(data)
        self.out.write(data)

    def path(self, rel):
        encoded = os.fsencode(rel)
        self.raw(struct.pack("<H", len(encoded)) + encoded)

    def record(self, tag, rel=None):
        self.records += 1
        self.raw(tag)
        if rel is not None:
            self.path(rel)

    def finish(self):
        self.out.write(b"E" + self.digest.digest())


def changed_runs(new_path, old_path, size):
    sha = hashlib.sha256()
    runs = []
    old = open(old_path, "rb") if old_path else None
    try:
        with open(new_path, "rb") as new:
            offset = 0
            while offset < size:
                block = new.read(BLOCK)
                if not block:
                    break
                sha.update(block)
                if old is not None:
                    changed = old.read(len(block)) != block
                else:
                    changed = block != ZERO[: len(block)]
                if changed:
                    if runs and runs[-1][0] + runs[-1][1] == offset and runs[-1][1] < RUN_MAX:
                        runs[-1][1] += len(block)
                    else:
                        runs.append([offset, len(block)])
                offset += len(block)
            if offset != size or new.read(1):
                raise DeltaError(f"{new_path} changed size while being read")
    finally:
        if old is not None:
            old.close()
    return runs, sha.digest()


def write_file(w, rel, full, st, old_path, old_st):
    runs, digest = changed_runs(full, old_path, st.st_size)
    if old_st is not None and not runs and (old_st.st_size, old_st.st_mode, old_st.st_mtime_ns) == (
        st.st_size,
        st.st_mode,
        st.st_mtime_ns,
    ):
        return
    w.record(b"F", rel)
    w.raw(struct.pack("<IQqB", stat.S_IMODE(st.st_mode), st.st_size, st.st_mtime_ns, old_st is None))
    with open(full, "rb") as new:
        for offset, length in runs:
            w.raw(b"W" + struct.pack("<QI", offset, length) + os.pread(new.fileno(), length, offset))
            w.records += 1
    w.raw(b"H" + digest)


def diff(old_root, new_root, out, header):
    old = scan(old_root)
    new = scan(new_root)
    w = Writer(out)
    w.raw(MAGIC)
    encoded = json.dumps(header, sort_keys=True).encode()
    w.raw(struct.pack("<I", len(encoded)) + encoded)

    removed = []
    for rel in sorted(old):
        if rel not in new or new[rel][0] != old[rel][0]:
            if not any(rel.startswith(r + os.sep) for r in removed):
                removed.append(rel)
                w.record(b"R", rel)

    for rel in sorted(new):
        kind, st = new[rel]
        before = old.get(rel)
        if before is not None and before[0] != kind:
            before = None
        full = os.path.join(new_root, rel)
        if kind == "d":
            if before is None or before[1].st_mode != st.st_mode:
                w.record(b"D", rel)
                w.raw(struct.pack("<I", stat.S_IMODE(st.st_mode)))
        elif kind == "l":
            target = os.readlink(full)
            if before is None or os.readlink(os.path.join(old_root, rel)) != target:
                w.record(b"S", rel)
                w.path(target)
        elif before is None or not same_file(before[1], st):
            if before is None:
                write_file(w, rel, full, st, None, None)
            else:
                write_file(w, rel, full, st, os.path.join(old_root, rel), before[1])

    if header.get("full"):
        w.record(b"M")
        w.raw(struct.pack("<I", len(new)))
        for rel in sorted(new):
            w.path(rel)

    w.finish()
    return w.records


class Reader:
    def __init__(self, f):
        self.f = f
        self.digest = hashlib.sha256()

    def take(self, n):
        data = self.f.read(n)
        if len(data) != n:
            raise DeltaError("truncated stream")
        self.digest.update(data)
        return data

    def unpack(self, fmt):
        return struct.unpack(fmt, self.take(struct.calcsize(fmt)))

    def path(self):
        (n,) = self.unpack("<H")
        return os.fsdecode(self.take(n))


def read_header(r):
    if r.take(len(MAGIC)) != MAGIC:
        raise DeltaError("not a block delta")
    (n,) = r.unpack("<I")
    return json.loads(r.take(n))


def records(f):
    r = Reader(f)
    header = read_header(r)
    yield ("header", header)
    while True:
        tag = f.read(1)
        if not tag:
            raise DeltaError("truncated stream")
        if tag == b"E":
            if f.read(32) != r.digest.digest():
                raise DeltaError("checksum mismatch")
            if f.read(1):
                raise DeltaError("trailing data")
            return
        r.digest.update(tag)
        if tag == b"R":
            yield ("remove", r.path())
        elif tag == b"D":
            rel = r.path()
            yield ("dir", rel, r.unpack("<I")[0])
        elif tag == b"S":
            rel = r.path()
            yield ("symlink", rel, r.path())
        elif tag == b"F":
            rel = r.path()
            mode, size, mtime_ns, fresh = r.unpack("<IQqB")
            yield ("file", rel, mode, size, mtime_ns, fresh)
        elif tag == b"W":
            offset, n = r.unpack("<QI")
            yield ("write", offset, r.take(n))
        elif tag == b"H":
            yield ("hash", r.take(32))
        elif tag == b"M":
            (count,) = r.unpack("<I")
            yield ("manifest", {r.path() for _ in range(count)})
        else:
            raise DeltaError(f"unknown record {tag!r}")


def verify(path):
    with open(path, "rb") as f:
        header = None
        for rec in records(f):
            if rec[0] == "header":
                header = rec[1]
    return header


def safe_join(root, rel):
    if os.path.isabs(rel) or rel in ("", ".") or ".." in rel.split(os.sep):
        raise DeltaError(f"unsafe path {rel!r}")
    target = os.path.join(root, rel)
    real_root = os.path.realpath(root)
    parent = os.path.realpath(os.path.dirname(target))
    if parent != real_root and not parent.startswith(real_root + os.sep):
        raise DeltaError(f"{rel!r} escapes the tree")
    return target


def remove(path):
    if os.path.isdir(path) and not os.path.islink(path):
        shutil.rmtree(path)
    elif os.path.lexists(path):
        os.unlink(path)


def file_sha(fd):
    sha = hashlib.sha256()
    os.lseek(fd, 0, os.SEEK_SET)
    while chunk := os.read(fd, RUN_MAX):
        sha.update(chunk)
    return sha.digest()


def apply(root, path):
    header = verify(path)
    os.makedirs(root, exist_ok=True)
    touched_dirs = {root}
    fd, current, meta = None, None, None

    with open(path, "rb") as f:
        for rec in records(f):
            kind = rec[0]
            if kind == "remove":
                target = safe_join(root, rec[1])
                remove(target)
                touched_dirs.add(os.path.dirname(target))
            elif kind == "dir":
                target = safe_join(root, rec[1])
                if os.path.islink(target) or (os.path.lexists(target) and not os.path.isdir(target)):
                    os.unlink(target)
                os.makedirs(target, exist_ok=True)
                os.chmod(target, rec[2])
                touched_dirs.add(os.path.dirname(target))
            elif kind == "symlink":
                target = safe_join(root, rec[1])
                remove(target)
                os.symlink(rec[2], target)
                touched_dirs.add(os.path.dirname(target))
            elif kind == "file":
                target = safe_join(root, rec[1])
                if os.path.lexists(target) and not stat.S_ISREG(os.lstat(target).st_mode):
                    remove(target)
                fd = os.open(target, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
                if rec[5]:
                    os.ftruncate(fd, 0)
                os.ftruncate(fd, rec[3])
                current, meta = target, rec
                touched_dirs.add(os.path.dirname(target))
            elif kind == "write":
                os.pwrite(fd, rec[2], rec[1])
            elif kind == "hash":
                os.fsync(fd)
                if file_sha(fd) != rec[1]:
                    os.close(fd)
                    raise DeltaError(f"{current} diverged from the source")
                os.fchmod(fd, meta[2])
                os.utime(fd, ns=(meta[4], meta[4]))
                os.close(fd)
                fd = None
            elif kind == "manifest":
                keep = rec[1]
                for dirpath, dirnames, filenames in os.walk(root, topdown=False):
                    for name in filenames + dirnames:
                        full = os.path.join(dirpath, name)
                        if os.path.relpath(full, root) not in keep:
                            remove(full)
                            touched_dirs.add(dirpath)

    for d in touched_dirs:
        if os.path.isdir(d):
            dfd = os.open(d, os.O_RDONLY | os.O_DIRECTORY)
            os.fsync(dfd)
            os.close(dfd)
    return header


def main():
    parser = argparse.ArgumentParser(prog="blockdelta")
    sub = parser.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("diff")
    d.add_argument("--base")
    d.add_argument("--header", default="{}")
    d.add_argument("new")
    d.add_argument("out")
    a = sub.add_parser("apply")
    a.add_argument("root")
    a.add_argument("delta")
    v = sub.add_parser("verify")
    v.add_argument("delta")
    args = parser.parse_args()

    try:
        if args.cmd == "diff":
            header = json.loads(args.header)
            header["full"] = args.base is None
            tmp = args.out + ".tmp"
            with open(tmp, "wb") as out:
                count = diff(args.base, args.new, out, header)
                out.flush()
                os.fsync(out.fileno())
            os.replace(tmp, args.out)
            print(json.dumps({"records": count, "bytes": os.path.getsize(args.out)}))
        elif args.cmd == "apply":
            print(json.dumps(apply(args.root, args.delta)))
        else:
            print(json.dumps(verify(args.delta)))
    except DeltaError as e:
        print(f"blockdelta: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
