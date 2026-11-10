"""Delta store for backup streams: per-object zstd patch-from chains, one point per captured state."""

import argparse
import contextlib
import fcntl
import gzip
import hashlib
import os
import random
import re
import shutil
import sqlite3
import struct
import sys
import time
import zlib

import zstandard

SCHEMA = """
CREATE TABLE IF NOT EXISTS points (
    id       INTEGER PRIMARY KEY,
    captured REAL NOT NULL,
    applied  REAL NOT NULL,
    source   TEXT NOT NULL,
    versions INTEGER NOT NULL,
    bytes    INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS points_captured ON points (captured);
CREATE TABLE IF NOT EXISTS objects (
    id  INTEGER PRIMARY KEY,
    key TEXT NOT NULL UNIQUE
);
CREATE TABLE IF NOT EXISTS versions (
    object INTEGER NOT NULL,
    point  INTEGER NOT NULL,
    kind   INTEGER NOT NULL,
    codec  INTEGER NOT NULL,
    meta   INTEGER NOT NULL,
    pack   INTEGER,
    offset INTEGER,
    length INTEGER,
    size   INTEGER,
    hash   BLOB,
    PRIMARY KEY (object, point)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS versions_point ON versions (point);
CREATE TABLE IF NOT EXISTS latest (
    object INTEGER PRIMARY KEY,
    point  INTEGER NOT NULL,
    chain  INTEGER NOT NULL,
    codec  INTEGER NOT NULL,
    meta   INTEGER NOT NULL,
    hash   BLOB,
    body   BLOB
);
CREATE INDEX IF NOT EXISTS latest_cached ON latest (point) WHERE body IS NOT NULL;
CREATE TABLE IF NOT EXISTS files (
    path  TEXT PRIMARY KEY,
    size  INTEGER NOT NULL,
    mtime INTEGER NOT NULL
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS slots (
    path     TEXT NOT NULL,
    idx      INTEGER NOT NULL,
    location INTEGER NOT NULL,
    stamp    INTEGER NOT NULL,
    PRIMARY KEY (path, idx)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS packs (
    id    INTEGER PRIMARY KEY,
    level INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS dicts (
    id    INTEGER PRIMARY KEY,
    grp   TEXT NOT NULL UNIQUE,
    data  BLOB NOT NULL
);
CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value INTEGER NOT NULL
);
"""

FULL, DELTA, GONE = 0, 1, 2
RAW, GZIP, CHUNK = 0, 1, 2
SECTOR = 4096
PACK_LIMIT = 256 << 20
CACHED_POINTS = 240
MAX_OUTPUT = 1 << 31
CHUNK_KEY = re.compile(r"^(.*\.mca)#(\d+)$")
PACK_NAME = re.compile(r"^(\d{8})\.")
DICT_NAME = re.compile(r"^(\d+)-(.+)\.dict$")
DICT_SIZE = 112 << 10
DICT_SAMPLES = 4000
IDX_MAGIC = b"SDX1"
IDX_HEAD = struct.Struct(">4sBB")
VREC = struct.Struct(">cIBBqQIQ16sH")
PREC = struct.Struct(">cIddIQH")
NO_HASH = bytes(16)


def dict_group(key):
    m = CHUNK_KEY.match(key)
    return os.path.basename(os.path.dirname(m.group(1))) if m else None


def digest(data):
    return hashlib.blake2b(data, digest_size=16).digest()


def is_region(path):
    return path.endswith(".mca")


def fsync_dir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def encode_version(key, point, kind, codec, meta, offset, length, size, h):
    k = key.encode()
    return VREC.pack(b"V", point, kind, codec, meta, offset or 0, length or 0, size or 0, h or NO_HASH, len(k)) + k


def encode_point(pid, captured, applied, versions, nbytes, source):
    s = source.encode()
    return PREC.pack(b"P", pid, captured, applied, versions, nbytes, len(s)) + s


def parse_records(body):
    records = []
    pos = 0
    while pos < len(body):
        tag = body[pos : pos + 1]
        if tag == b"V" and pos + VREC.size <= len(body):
            _, point, kind, codec, meta, offset, length, size, h, klen = VREC.unpack_from(body, pos)
            end = pos + VREC.size + klen
            if end > len(body):
                break
            key = body[pos + VREC.size : end].decode()
            if kind == GONE:
                records.append(("V", key, point, kind, codec, meta, None, None, None, None))
            else:
                records.append(("V", key, point, kind, codec, meta, offset, length, size, h))
        elif tag == b"P" and pos + PREC.size <= len(body):
            _, pid, captured, applied, versions, nbytes, slen = PREC.unpack_from(body, pos)
            end = pos + PREC.size + slen
            if end > len(body):
                break
            records.append(("P", pid, captured, applied, versions, nbytes, body[pos + PREC.size : end].decode()))
        else:
            break
        pos = end
    return records, pos


def read_idx(path):
    with open(path, "rb") as f:
        data = f.read()
    magic, level, packed = IDX_HEAD.unpack_from(data)
    if magic != IDX_MAGIC:
        sys.exit(f"{path}: not a pack index")
    body = data[IDX_HEAD.size :]
    if packed:
        body = zstandard.ZstdDecompressor().decompress(body, max_output_size=MAX_OUTPUT)
    records, used = parse_records(body)
    return level, packed, records, IDX_HEAD.size + used


class Store:
    def __init__(self, index, data, level=3, keyframe=32, write=True, db_name="index.db"):
        self.index = index
        self.data = data
        self.level = level
        self.keyframe = keyframe
        if write:
            os.makedirs(index, exist_ok=True)
            os.makedirs(os.path.join(data, "packs"), exist_ok=True)
            os.makedirs(os.path.join(data, "dicts"), exist_ok=True)
        self.db = sqlite3.connect(os.path.join(index, db_name), isolation_level=None, timeout=300, check_same_thread=False)
        if write:
            self.db.execute("PRAGMA journal_mode=WAL")
            self.db.execute("PRAGMA synchronous=NORMAL")
            self.db.executescript(SCHEMA)
        self.pack_file = None
        self.pack_id = None
        self.fast = zstandard.ZstdCompressor(level=1)
        self.unzstd = zstandard.ZstdDecompressor()
        self.object_ids = {}
        self.readers = {}
        self.dicts = {}
        self.compressors = {}
        self.decompressors = {0: self.unzstd}

    def get_meta(self, key):
        row = self.db.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
        return row[0] if row else None

    def set_meta(self, key, value):
        self.db.execute("INSERT OR REPLACE INTO meta VALUES (?, ?)", (key, value))

    def dict_by_id(self, did):
        if did not in self.dicts:
            row = self.db.execute("SELECT data FROM dicts WHERE id=?", (did,)).fetchone()
            if row is None:
                raise LookupError(f"dictionary {did} is missing from the store")
            self.dicts[did] = zstandard.ZstdCompressionDict(row[0])
        return self.dicts[did]

    def compress_full(self, key, raw, level):
        group = dict_group(key)
        row = self.db.execute("SELECT id FROM dicts WHERE grp=?", (group,)).fetchone() if group else None
        did = row[0] if row else 0
        cctx = self.compressors.get((did, level))
        if cctx is None:
            cctx = self.compressors[(did, level)] = (
                zstandard.ZstdCompressor(level=level, dict_data=self.dict_by_id(did)) if did else zstandard.ZstdCompressor(level=level)
            )
        return cctx.compress(raw)

    def decompress_full(self, blob, size):
        did = zstandard.get_frame_parameters(blob).dict_id
        dctx = self.decompressors.get(did)
        if dctx is None:
            dctx = self.decompressors[did] = zstandard.ZstdDecompressor(dict_data=self.dict_by_id(did))
        return dctx.decompress(blob, max_output_size=max(size, 1))

    def train_dicts(self):
        trained = {r[0] for r in self.db.execute("SELECT grp FROM dicts")}
        rows = {}
        for key, pack, offset, length, size in self.db.execute(
            "SELECT o.key, v.pack, v.offset, v.length, v.size FROM versions v JOIN objects o ON o.id = v.object WHERE v.kind=? AND v.size > 0",
            (FULL,),
        ):
            group = dict_group(key)
            if group and group not in trained:
                rows.setdefault(group, []).append((pack, offset, length, size))
        for group, candidates in sorted(rows.items()):
            if len(candidates) < 100:
                continue
            start = time.monotonic()
            samples = [self.decompress_full(self.read_blob(*c[:3]), c[3]) for c in random.sample(candidates, min(DICT_SAMPLES, len(candidates)))]
            used = {r[0] for r in self.db.execute("SELECT id FROM dicts")}
            did = next(i for i in iter(lambda: random.randrange(32768, 1 << 31), None) if i not in used)
            data = zstandard.train_dictionary(DICT_SIZE, samples, dict_id=did, level=19).as_bytes()
            path = os.path.join(self.data, "dicts", f"{did}-{group}.dict")
            with open(path + ".tmp", "wb") as f:
                f.write(data)
                f.flush()
                os.fsync(f.fileno())
            os.rename(path + ".tmp", path)
            fsync_dir(os.path.dirname(path))
            self.db.execute("INSERT INTO dicts VALUES (?, ?, ?)", (did, group, data))
            print(f"dictionary {did} for {group}: {len(samples)} samples, {len(data)} bytes in {time.monotonic() - start:.0f}s", flush=True)

    def pack_path(self, pack):
        return os.path.join(self.data, "packs", f"{pack:08d}.pack")

    def idx_path(self, pack):
        return os.path.join(self.data, "packs", f"{pack:08d}.idx")

    def newest_pack(self):
        on_disk = [int(m.group(1)) for m in map(PACK_NAME.match, os.listdir(os.path.join(self.data, "packs"))) if m]
        return max(on_disk + [r[0] for r in self.db.execute("SELECT id FROM packs")], default=0)

    def reserve_pack(self):
        while True:
            pid = self.newest_pack() + 1
            try:
                open(self.pack_path(pid), "xb").close()
                return pid
            except FileExistsError:
                continue

    def begin(self):
        self.db.execute("BEGIN IMMEDIATE")
        self.point_bytes = 0
        self.point_versions = 0
        self.pending = []
        hot = self.get_meta("hot")
        if hot is not None:
            committed = self.get_meta("hot_length")
            actual = os.path.getsize(self.idx_path(hot))
            if actual < committed:
                sys.exit(f"pack index {hot} is shorter than its committed length; run reindex")
            if actual > committed:
                os.truncate(self.idx_path(hot), committed)
        if hot is None or os.path.getsize(self.pack_path(hot)) >= PACK_LIMIT:
            hot = self.reserve_pack()
            with open(self.idx_path(hot), "xb") as f:
                f.write(IDX_HEAD.pack(IDX_MAGIC, self.level, 0))
                f.flush()
                os.fsync(f.fileno())
            fsync_dir(os.path.join(self.data, "packs"))
            self.db.execute("INSERT INTO packs VALUES (?, ?)", (hot, self.level))
            self.set_meta("hot", hot)
            self.set_meta("hot_length", IDX_HEAD.size)
        if self.pack_id != hot:
            if self.pack_file is not None:
                self.pack_file.close()
            self.pack_id = hot
            self.pack_file = open(self.pack_path(hot), "ab")

    def object_id(self, key):
        oid = self.object_ids.get(key)
        if oid is None:
            row = self.db.execute("SELECT id FROM objects WHERE key=?", (key,)).fetchone()
            oid = row[0] if row else self.db.execute("INSERT INTO objects (key) VALUES (?)", (key,)).lastrowid
            self.object_ids[key] = oid
        return oid

    def append(self, blob):
        offset = self.pack_file.tell()
        self.pack_file.write(blob)
        return self.pack_id, offset

    def put(self, key, raw, codec, meta):
        oid = self.object_id(key)
        row = self.db.execute("SELECT point, chain, hash, body, meta FROM latest WHERE object=?", (oid,)).fetchone()
        h = digest(raw)
        if row and row[2] == h and (codec != CHUNK or row[4] == meta):
            return False
        if row and row[2] is not None and row[1] + 1 < self.keyframe:
            prev = self.newest_raw(oid, row[0], row[2], row[3])
            blob = zstandard.ZstdCompressor(
                level=self.level, dict_data=zstandard.ZstdCompressionDict(prev, dict_type=zstandard.DICT_TYPE_RAWCONTENT)
            ).compress(raw)
            kind, chain = DELTA, row[1] + 1
        else:
            blob = self.compress_full(key, raw, self.level)
            kind, chain = FULL, 0
        pack, offset = self.append(blob)
        self.pending.append((key, oid, kind, codec, meta, pack, offset, len(blob), len(raw), h))
        self.db.execute(
            "INSERT OR REPLACE INTO latest VALUES (?, -1, ?, ?, ?, ?, ?)", (oid, chain, codec, meta, h, self.fast.compress(raw))
        )
        self.point_bytes += len(blob)
        self.point_versions += 1
        return True

    def newest_raw(self, oid, point, h, body):
        if body is not None:
            return self.unzstd.decompress(body, max_output_size=MAX_OUTPUT)
        raw = self.materialize(self.chain_for(oid, point))
        if digest(raw) != h:
            sys.exit(f"object {oid} point {point} does not reconstruct from its packs")
        return raw

    def remove(self, key):
        known = self.object_ids.get(key) or self.db.execute("SELECT id FROM objects WHERE key=?", (key,)).fetchone()
        if not known:
            return False
        oid = self.object_id(key)
        row = self.db.execute("SELECT hash FROM latest WHERE object=?", (oid,)).fetchone()
        if not row or row[0] is None:
            return False
        self.pending.append((key, oid, GONE, RAW, 0, None, None, None, None, None))
        self.db.execute("UPDATE latest SET chain=0, hash=NULL, body=NULL WHERE object=?", (oid,))
        self.point_versions += 1
        return True

    def commit(self, captured, source):
        self.pack_file.flush()
        os.fsync(self.pack_file.fileno())
        point = (self.db.execute("SELECT MAX(id) FROM points").fetchone()[0] or 0) + 1
        applied = time.time()
        records = b"".join(
            encode_version(key, point, kind, codec, meta, offset, length, size, h)
            for key, _, kind, codec, meta, _, offset, length, size, h in self.pending
        ) + encode_point(point, captured, applied, self.point_versions, self.point_bytes, source)
        with open(self.idx_path(self.pack_id), "ab") as f:
            f.write(records)
            f.flush()
            os.fsync(f.fileno())
            length = f.tell()
        self.db.execute(
            "INSERT INTO points VALUES (?, ?, ?, ?, ?, ?)", (point, captured, applied, source, self.point_versions, self.point_bytes)
        )
        self.db.executemany(
            "INSERT INTO versions VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [(oid, point, kind, codec, meta, pack, offset, length, size, h) for _, oid, kind, codec, meta, pack, offset, length, size, h in self.pending],
        )
        self.db.executemany("UPDATE latest SET point=? WHERE object=?", [(point, oid) for _, oid, kind, *_ in self.pending if kind != GONE])
        self.db.execute("UPDATE latest SET body=NULL WHERE body IS NOT NULL AND point < ?", (point - CACHED_POINTS,))
        self.set_meta("hot_length", length)
        self.db.execute("COMMIT")
        return point

    def read_blob(self, pack, offset, length):
        f = self.readers.get(pack)
        if f is None:
            f = self.readers[pack] = open(self.pack_path(pack), "rb")
        f.seek(offset)
        return f.read(length)

    def chain_for(self, oid, point):
        rows = self.db.execute(
            "SELECT point, kind, codec, meta, pack, offset, length, size, hash FROM versions WHERE object=? AND point<=? ORDER BY point DESC",
            (oid, point),
        )
        chain = []
        for row in rows:
            if row[1] == GONE and not chain:
                return None
            chain.append(row)
            if row[1] == FULL:
                break
        return chain[::-1] if chain else None

    def materialize(self, chain):
        raw = None
        for _, kind, _, _, pack, offset, length, size, _ in chain:
            raw = unpatch(self, None if kind == FULL else raw, self.read_blob(pack, offset, length), size)
        return raw

    def version_raw(self, oid, chain):
        row = self.db.execute("SELECT point, body FROM latest WHERE object=?", (oid,)).fetchone()
        if row and row[0] == chain[-1][0] and row[1] is not None:
            return self.unzstd.decompress(row[1], max_output_size=MAX_OUTPUT)
        return self.materialize(chain)

    def point_at(self, when):
        return self.db.execute("SELECT id, captured FROM points WHERE captured<=? ORDER BY captured DESC, id DESC LIMIT 1", (when,)).fetchone()

    def live(self, point, prefix=""):
        return self.db.execute(
            "SELECT o.key, o.id, v.codec, v.meta, v.point FROM objects o JOIN versions v ON v.object = o.id "
            "AND v.point = (SELECT MAX(point) FROM versions WHERE object = o.id AND point <= ?) "
            "WHERE o.key >= ? AND o.key < ? AND v.kind != ? ORDER BY o.key",
            (point, prefix, prefix + "\U0010ffff", GONE),
        ).fetchall()

    def tree(self, point, prefix=""):
        files = {}
        for key, oid, codec, meta, version in self.live(point, prefix):
            m = CHUNK_KEY.match(key)
            if m or is_region(key):
                files.setdefault(m.group(1) if m else key, None)
            else:
                files[key] = (oid, codec, meta, version)
        return files

    def region_version(self, point, rel):
        return self.db.execute(
            "SELECT MAX(v.point) FROM versions v JOIN objects o ON o.id = v.object "
            "WHERE (o.key = ? OR (o.key >= ? AND o.key < ?)) AND v.point <= ?",
            (rel, rel + "#", rel + "$", point),
        ).fetchone()[0]

    def captured(self, point):
        return self.db.execute("SELECT captured FROM points WHERE id=?", (point,)).fetchone()[0]

    def render(self, point, rel, entry):
        if entry is None:
            chunks = {}
            for key, oid, codec, meta, _ in self.live(point, rel + "#"):
                chunks[int(key.rsplit("#", 1)[1])] = (self.version_raw(oid, self.chain_for(oid, point)), meta)
            return region_image(chunks)
        oid, codec, meta, _ = entry
        raw = self.version_raw(oid, self.chain_for(oid, point))
        return (gzip.compress(raw, 6, mtime=meta) if codec == GZIP else raw), {}


def chunk_entries(image):
    entries = {}
    if len(image) < 2 * SECTOR:
        return entries
    for idx in range(1024):
        location = struct.unpack_from(">I", image, idx * 4)[0]
        if location:
            entries[idx] = (location, struct.unpack_from(">I", image, SECTOR + idx * 4)[0])
    return entries


def chunk_raw(image, location, region_path, idx):
    offset = (location >> 8) * SECTOR
    length, kind = struct.unpack_from(">IB", image, offset)
    payload = image[offset + 5 : offset + 4 + length]
    if kind & 0x80:
        x, z = (int(v) for v in os.path.basename(region_path).split(".")[1:3])
        cx, cz = x * 32 + idx % 32, z * 32 + idx // 32
        with open(os.path.join(os.path.dirname(region_path), f"c.{cx}.{cz}.mcc"), "rb") as f:
            payload = f.read()
    base = kind & 0x7F
    if base == 2:
        return zlib.decompress(payload), base
    if base == 1:
        return zlib.decompress(payload, 47), base
    return payload, base


def file_raw(path, data):
    if data[:2] == b"\x1f\x8b":
        try:
            return gzip.decompress(data), GZIP
        except (OSError, EOFError, zlib.error):
            pass
    return data, RAW


def ingest(store, mirror, captured, source, full):
    store.begin()
    known = dict((p, (s, m)) for p, s, m in store.db.execute("SELECT path, size, mtime FROM files"))
    full = full or not known
    seen = set()
    live = set()
    for dirpath, dirnames, filenames in os.walk(mirror):
        dirnames.sort()
        for name in sorted(filenames):
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, mirror)
            if name.endswith(".mcc"):
                continue
            st = os.lstat(path)
            if not os.path.isfile(path) or os.path.islink(path):
                continue
            seen.add(rel)
            sig = (st.st_size, st.st_mtime_ns)
            if not full and known.get(rel) == sig:
                continue
            with open(path, "rb") as f:
                data = f.read()
            if is_region(rel):
                live |= ingest_region(store, path, rel, data, full)
            else:
                raw, codec = file_raw(rel, data)
                store.put(rel, raw, codec, int(st.st_mtime))
                live.add(rel)
            store.db.execute("INSERT OR REPLACE INTO files VALUES (?, ?, ?)", (rel, *sig))
    for rel in set(known) - seen:
        if is_region(rel):
            for (idx,) in store.db.execute("SELECT idx FROM slots WHERE path=?", (rel,)).fetchall():
                store.remove(f"{rel}#{idx}")
            store.db.execute("DELETE FROM slots WHERE path=?", (rel,))
        store.remove(rel)
        store.db.execute("DELETE FROM files WHERE path=?", (rel,))
    if full:
        stale = [
            key
            for (key,) in store.db.execute("SELECT o.key FROM latest l JOIN objects o ON o.id = l.object WHERE l.hash IS NOT NULL")
            if key not in live
        ]
        for key in stale:
            store.remove(key)
    return store.commit(captured, source)


def ingest_region(store, path, rel, image, full):
    slots = dict(((i, (l, s)) for i, l, s in store.db.execute("SELECT idx, location, stamp FROM slots WHERE path=?", (rel,))))
    entries = chunk_entries(image)
    for idx, (location, stamp) in entries.items():
        if not full and slots.get(idx) == (location, stamp):
            continue
        try:
            raw, kind = chunk_raw(image, location, path, idx)
        except (zlib.error, struct.error, OSError, ValueError) as e:
            print(f"{rel}#{idx}: unreadable chunk ({e}); keeping the previous version", file=sys.stderr)
            continue
        store.put(f"{rel}#{idx}", raw, CHUNK, (stamp << 8) | kind)
        store.db.execute("INSERT OR REPLACE INTO slots VALUES (?, ?, ?, ?)", (rel, idx, location, stamp))
    for idx in set(slots) - set(entries):
        store.remove(f"{rel}#{idx}")
        store.db.execute("DELETE FROM slots WHERE path=? AND idx=?", (rel, idx))
    if entries:
        store.remove(rel)
        return {f"{rel}#{idx}" for idx in entries}
    store.put(rel, b"", RAW, 0)
    return {rel}


def encode_chunk(raw, kind):
    if kind == 1:
        return gzip.compress(raw, 6), 1
    if kind == 2:
        return zlib.compress(raw, 6), 2
    return raw, kind


def region_image(chunks):
    if not chunks:
        return b"", {}
    header = bytearray(2 * SECTOR)
    body = bytearray()
    external = {}
    next_sector = 2
    for idx in sorted(chunks):
        raw, meta = chunks[idx]
        data, kind = encode_chunk(raw, meta & 0xFF)
        record = struct.pack(">IB", len(data) + 1, kind) + data
        if len(record) > 255 * SECTOR:
            external[idx] = data
            record = struct.pack(">IB", 1, kind | 0x80)
        sectors = -(-len(record) // SECTOR)
        struct.pack_into(">I", header, idx * 4, (next_sector << 8) | sectors)
        struct.pack_into(">I", header, SECTOR + idx * 4, meta >> 8)
        body += record + bytes(sectors * SECTOR - len(record))
        next_sector += sectors
    return bytes(header + body), external


def external_name(rel, idx):
    x, z = (int(v) for v in os.path.basename(rel).split(".")[1:3])
    return os.path.join(os.path.dirname(rel), f"c.{x * 32 + idx % 32}.{z * 32 + idx // 32}.mcc")


def restore(store, when, out, prefix):
    found = store.point_at(when)
    if found is None:
        sys.exit(f"no point at or before {when}")
    point, captured = found
    files = 0
    for rel, entry in store.tree(point, prefix).items():
        data, external = store.render(point, rel, entry)
        target = os.path.join(out, rel)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "wb") as f:
            f.write(data)
        for idx, chunk in external.items():
            with open(os.path.join(out, external_name(rel, idx)), "wb") as f:
                f.write(chunk)
        stamp = store.captured(store.region_version(point, rel)) if entry is None else entry[2]
        os.utime(target, (stamp, stamp))
        files += 1
    print(f"restored point {point} captured {time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(captured))}: {files} files")


def check(store, sample):
    bad = total = 0
    oids = [r[0] for r in store.db.execute("SELECT id FROM objects ORDER BY id")]
    for oid in oids[:: max(1, sample)]:
        raw = None
        for _, kind, _, _, pack, offset, length, size, h in store.db.execute(
            "SELECT point, kind, codec, meta, pack, offset, length, size, hash FROM versions WHERE object=? ORDER BY point", (oid,)
        ).fetchall():
            if kind == GONE:
                raw = None
                continue
            raw = unpatch(store, None if kind == FULL else raw, store.read_blob(pack, offset, length), size)
            total += 1
            if digest(raw) != h:
                bad += 1
                print(f"object {oid}: version hash mismatch", file=sys.stderr)
    print(f"checked {total} versions of {len(oids[:: max(1, sample)])} objects: {bad} mismatches")
    return bad == 0


def mirror_state(mirror, prefix=""):
    expected = {}
    for dirpath, _, filenames in os.walk(mirror):
        for name in filenames:
            path = os.path.join(dirpath, name)
            rel = prefix + os.path.relpath(path, mirror)
            if name.endswith(".mcc") or os.path.islink(path) or not os.path.isfile(path):
                continue
            with open(path, "rb") as f:
                data = f.read()
            if is_region(rel):
                entries = chunk_entries(data)
                if not entries:
                    expected[rel] = (digest(b""), None)
                for idx, (location, stamp) in entries.items():
                    try:
                        raw, kind = chunk_raw(data, location, path, idx)
                    except (zlib.error, struct.error, OSError, ValueError):
                        continue
                    expected[f"{rel}#{idx}"] = (digest(raw), (stamp << 8) | kind)
            else:
                expected[rel] = (digest(file_raw(rel, data)[0]), None)
    return expected


def verify(store, mirror, when, prefix):
    point = store.point_at(when)[0]
    expected = mirror_state(mirror, prefix)
    stored = {}
    for key, oid, codec, meta, _ in store.live(point, prefix):
        chain = store.chain_for(oid, point)
        stored[key] = (chain[-1][-1], meta if CHUNK_KEY.match(key) else None)
    missing = sorted(set(expected) - set(stored))
    extra = sorted(set(stored) - set(expected))
    differ = sorted(k for k in set(expected) & set(stored) if expected[k] != stored[k])
    for label, keys in (("missing", missing), ("extra", extra), ("differ", differ)):
        for k in keys[:20]:
            print(f"{label}: {k}", file=sys.stderr)
    print(f"verified {len(expected)} objects against point {point}: {len(missing)} missing, {len(extra)} extra, {len(differ)} differ")
    return not (missing or extra or differ)


def patch(store, key, prev, raw, level):
    if prev is None:
        return store.compress_full(key, raw, level)
    return zstandard.ZstdCompressor(
        level=level, dict_data=zstandard.ZstdCompressionDict(prev, dict_type=zstandard.DICT_TYPE_RAWCONTENT)
    ).compress(raw)


def unpatch(store, prev, blob, size):
    if prev is None:
        return store.decompress_full(blob, size)
    return zstandard.ZstdDecompressor(
        dict_data=zstandard.ZstdCompressionDict(prev, dict_type=zstandard.DICT_TYPE_RAWCONTENT)
    ).decompress(blob, max_output_size=max(size, 1))


def tidy_packs(store):
    known = {r[0] for r in store.db.execute("SELECT id FROM packs")}
    hot = store.get_meta("hot")
    names = os.listdir(os.path.join(store.data, "packs"))
    for name in names:
        m = PACK_NAME.match(name)
        if m and name.endswith(".idx.tmp"):
            pid = int(m.group(1))
            if pid in known:
                os.rename(store.idx_path(pid) + ".tmp", store.idx_path(pid))
            else:
                os.unlink(os.path.join(store.data, "packs", name))
    for name in os.listdir(os.path.join(store.data, "packs")):
        m = PACK_NAME.match(name)
        if m and int(m.group(1)) not in known and int(m.group(1)) != hot:
            print(f"removing orphan {name}", flush=True)
            os.unlink(os.path.join(store.data, "packs", name))
    fsync_dir(os.path.join(store.data, "packs"))


@contextlib.contextmanager
def held(lock):
    if lock is None:
        yield
        return
    with open(lock, "w") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        yield


def recompress(store, old, level, staging):
    _, _, records, _ = read_idx(store.idx_path(old))
    versions = sorted((r for r in records if r[0] == "V" and r[3] != GONE), key=lambda r: (r[1], r[2]))
    others = [r for r in records if r[0] == "P" or r[3] == GONE]
    placed = []
    out_records = []
    before = 0
    with open(staging, "wb") as out:
        cached = (None, None, None)
        for _, key, point, kind, codec, meta, offset, length, size, h in versions:
            oid = store.object_id(key)
            prev = None
            if kind == DELTA:
                prev = cached[2] if cached[0] == oid and cached[1] == point else None
                if prev is None:
                    prev_point = store.db.execute("SELECT MAX(point) FROM versions WHERE object=? AND point<?", (oid, point)).fetchone()[0]
                    prev = store.materialize(store.chain_for(oid, prev_point))
            raw = unpatch(store, prev, store.read_blob(old, offset, length), size)
            blob = patch(store, key, prev, raw, level)
            if digest(unpatch(store, prev, blob, size)) != h or digest(raw) != h:
                sys.exit(f"pack {old}: {key} point {point} does not round-trip; leaving the pack untouched")
            placed.append((out.tell(), len(blob), oid, point))
            out_records.append(encode_version(key, point, kind, codec, meta, out.tell(), len(blob), size, h))
            out.write(blob)
            before += length
            following = store.db.execute("SELECT MIN(point) FROM versions WHERE object=? AND point>?", (oid, point)).fetchone()[0]
            cached = (oid, following, raw)
        out.flush()
        os.fsync(out.fileno())
    for r in others:
        out_records.append(encode_version(*r[1:]) if r[0] == "V" else encode_point(*r[1:]))
    index = IDX_HEAD.pack(IDX_MAGIC, level, 1) + zstandard.ZstdCompressor(level=19).compress(b"".join(out_records))
    return placed, index, before


def install(store, old, level, staging, placed, index):
    new = store.reserve_pack()
    with open(staging, "rb") as src, open(store.pack_path(new), "wb") as out:
        shutil.copyfileobj(src, out, 16 << 20)
        out.flush()
        os.fsync(out.fileno())
    with open(store.idx_path(new) + ".tmp", "wb") as f:
        f.write(index)
        f.flush()
        os.fsync(f.fileno())
    fsync_dir(os.path.join(store.data, "packs"))
    store.db.execute("BEGIN IMMEDIATE")
    store.db.execute("INSERT INTO packs VALUES (?, ?)", (new, level))
    store.db.execute("DELETE FROM packs WHERE id=?", (old,))
    store.db.executemany(
        "UPDATE versions SET pack=?, offset=?, length=? WHERE object=? AND point=?",
        [(new, offset, length, oid, point) for offset, length, oid, point in placed],
    )
    store.db.execute("COMMIT")
    os.rename(store.idx_path(new) + ".tmp", store.idx_path(new))
    fsync_dir(os.path.join(store.data, "packs"))
    store.readers.pop(old, None)
    os.unlink(store.idx_path(old))
    os.unlink(store.pack_path(old))
    fsync_dir(os.path.join(store.data, "packs"))
    return new


def compact(store, level, limit, lock):
    with held(lock):
        store.train_dicts()
        store.db.execute("BEGIN IMMEDIATE")
        tidy_packs(store)
        hot = store.get_meta("hot")
        sealed = [r[0] for r in store.db.execute("SELECT id FROM packs WHERE level < ? ORDER BY id", (level,)) if r[0] != hot]
        store.db.execute("COMMIT")
    staging = os.path.join(store.index, "staging.pack")
    try:
        for old in sealed[:limit]:
            start = time.monotonic()
            placed, index, before = recompress(store, old, level, staging)
            with held(lock):
                new = install(store, old, level, staging, placed, index)
            after = sum(length for _, length, _, _ in placed)
            print(f"pack {old} -> {new}: {len(placed)} versions, {before} -> {after} bytes in {time.monotonic() - start:.0f}s", flush=True)
    finally:
        if os.path.exists(staging):
            os.unlink(staging)


def reindex(index, data, level, keyframe):
    target = os.path.join(index, "index.db")
    for suffix in ("", "-wal", "-shm"):
        if os.path.exists(target + ".rebuild" + suffix):
            os.unlink(target + ".rebuild" + suffix)
    store = Store(index, data, level, keyframe, db_name="index.db.rebuild")
    store.db.execute("BEGIN")
    for name in sorted(os.listdir(os.path.join(data, "dicts"))):
        m = DICT_NAME.match(name)
        if m:
            with open(os.path.join(data, "dicts", name), "rb") as f:
                store.db.execute("INSERT INTO dicts VALUES (?, ?, ?)", (int(m.group(1)), m.group(2), f.read()))
    pack_ids = sorted({int(m.group(1)) for m in map(PACK_NAME.match, os.listdir(os.path.join(data, "packs"))) if m})
    points = {}
    versions = {}
    hot = None
    for pid in pack_ids:
        if not os.path.exists(store.idx_path(pid)):
            continue
        level_of, packed, records, used = read_idx(store.idx_path(pid))
        store.db.execute("INSERT INTO packs VALUES (?, ?)", (pid, level_of))
        if not packed:
            hot = (pid, used)
        for r in records:
            if r[0] == "P":
                points[r[1]] = r[2:]
            else:
                _, key, point, kind, codec, meta, offset, length, size, h = r
                versions[(key, point)] = (kind, codec, meta, None if kind == GONE else pid, offset, length, size, h)
    store.db.executemany("INSERT INTO points VALUES (?, ?, ?, ?, ?, ?)", [(pid, c, a, s, v, b) for pid, (c, a, v, b, s) in points.items()])
    rows = []
    for (key, point), (kind, codec, meta, pack, offset, length, size, h) in sorted(versions.items()):
        if point in points:
            rows.append((store.object_id(key), point, kind, codec, meta, pack, offset, length, size, h))
    store.db.executemany("INSERT INTO versions VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", rows)
    if hot:
        store.set_meta("hot", hot[0])
        store.set_meta("hot_length", hot[1])
    store.db.execute("COMMIT")
    store.db.execute("BEGIN")
    built = 0
    newest_point = max(points, default=0)
    for oid, point in store.db.execute("SELECT object, MAX(point) FROM versions GROUP BY object").fetchall():
        chain_rows = store.db.execute(
            "SELECT point, kind, codec, meta, pack, offset, length, size, hash FROM versions WHERE object=? ORDER BY point DESC", (oid,)
        ).fetchall()
        newest = chain_rows[0]
        if newest[1] == GONE:
            store.db.execute("INSERT INTO latest VALUES (?, ?, 0, ?, ?, NULL, NULL)", (oid, point, newest[2], newest[3]))
            continue
        chain = store.chain_for(oid, point)
        raw = store.materialize(chain)
        if digest(raw) != newest[8]:
            sys.exit(f"object {oid} point {point} does not reconstruct")
        store.db.execute(
            "INSERT INTO latest VALUES (?, ?, ?, ?, ?, ?, ?)",
            (oid, point, len(chain) - 1, newest[2], newest[3], newest[8], store.fast.compress(raw) if point >= newest_point - CACHED_POINTS else None),
        )
        built += 1
        if built % 20000 == 0:
            print(f"{built} latest bodies", flush=True)
    store.db.execute("COMMIT")
    store.db.close()
    for suffix in ("-wal", "-shm"):
        if os.path.exists(target + suffix):
            os.unlink(target + suffix)
    os.rename(target + ".rebuild", target)
    print(f"reindexed {len(points)} points, {len(rows)} versions, {built} live objects from {len(pack_ids)} packs")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--index", required=True)
    ap.add_argument("--data", required=True)
    ap.add_argument("--level", type=int, default=3)
    ap.add_argument("--keyframe", type=int, default=32)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("ingest")
    p.add_argument("--mirror", required=True)
    p.add_argument("--captured", type=float)
    p.add_argument("--source", default="ingest")
    p.add_argument("--full", action="store_true")
    p = sub.add_parser("restore")
    p.add_argument("--at", type=float, default=float("inf"))
    p.add_argument("--out", required=True)
    p.add_argument("--prefix", default="")
    p = sub.add_parser("check")
    p.add_argument("--sample", type=int, default=1)
    p = sub.add_parser("verify")
    p.add_argument("--mirror", required=True)
    p.add_argument("--at", type=float, default=float("inf"))
    p.add_argument("--prefix", default="")
    p = sub.add_parser("compact")
    p.add_argument("--to-level", type=int, default=19)
    p.add_argument("--limit", type=int, default=1)
    p.add_argument("--lock")
    sub.add_parser("reindex")
    sub.add_parser("points")
    args = ap.parse_args()
    if args.cmd == "reindex":
        reindex(args.index, args.data, args.level, args.keyframe)
        return
    store = Store(args.index, args.data, args.level, args.keyframe)
    if args.cmd == "ingest":
        start = time.monotonic()
        point = ingest(store, args.mirror, args.captured or time.time(), args.source, args.full)
        versions, size = store.db.execute("SELECT versions, bytes FROM points WHERE id=?", (point,)).fetchone()
        print(f"point {point}: {versions} versions, {size} bytes in {time.monotonic() - start:.2f}s")
    elif args.cmd == "restore":
        restore(store, args.at, args.out, args.prefix)
    elif args.cmd == "check":
        sys.exit(0 if check(store, args.sample) else 1)
    elif args.cmd == "verify":
        sys.exit(0 if verify(store, args.mirror, args.at, args.prefix) else 1)
    elif args.cmd == "compact":
        compact(store, args.to_level, args.limit, args.lock)
    elif args.cmd == "points":
        for pid, captured, source, versions, size in store.db.execute("SELECT id, captured, source, versions, bytes FROM points ORDER BY id"):
            print(f"{pid}\t{time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(captured))}\t{source}\t{versions}\t{size}")


if __name__ == "__main__":
    main()
