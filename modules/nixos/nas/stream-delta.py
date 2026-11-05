"""Delta store for backup streams: per-object zstd patch-from chains, one point per captured state."""

import argparse
import gzip
import hashlib
import os
import random
import re
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
"""

FULL, DELTA, GONE = 0, 1, 2
RAW, GZIP, CHUNK = 0, 1, 2
SECTOR = 4096
PACK_LIMIT = 256 << 20
MAX_OUTPUT = 1 << 31
CHUNK_KEY = re.compile(r"^(.*\.mca)#(\d+)$")
DICT_SIZE = 112 << 10
DICT_SAMPLES = 4000


def dict_group(key):
    m = CHUNK_KEY.match(key)
    return os.path.basename(os.path.dirname(m.group(1))) if m else None


def digest(data):
    return hashlib.blake2b(data, digest_size=16).digest()


def is_region(path):
    return path.endswith(".mca")


def is_gzip_nbt(path):
    return path.endswith(".dat") or path.endswith(".dat_old")


class Store:
    def __init__(self, root, level, keyframe):
        self.root = root
        self.level = level
        self.keyframe = keyframe
        os.makedirs(os.path.join(root, "packs"), exist_ok=True)
        self.db = sqlite3.connect(os.path.join(root, "index.db"), isolation_level=None, timeout=300)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=NORMAL")
        self.db.executescript(SCHEMA)
        self.pack_file = None
        self.fast = zstandard.ZstdCompressor(level=1)
        self.unzstd = zstandard.ZstdDecompressor()
        self.object_ids = {}
        self.readers = {}
        self.dicts = {}
        self.compressors = {}
        self.decompressors = {0: self.unzstd}

    def dict_by_id(self, did):
        if did not in self.dicts:
            row = self.db.execute("SELECT data FROM dicts WHERE id=?", (did,)).fetchone()
            if row is None:
                sys.exit(f"dictionary {did} is missing from the store")
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
            self.db.execute("INSERT INTO dicts VALUES (?, ?, ?)", (did, group, data))
            print(f"dictionary {did} for {group}: {len(samples)} samples, {len(data)} bytes in {time.monotonic() - start:.0f}s", flush=True)

    def begin(self):
        self.db.execute("BEGIN IMMEDIATE")
        self.point_bytes = 0
        self.point_versions = 0
        self.pending = []

    def object_id(self, key):
        oid = self.object_ids.get(key)
        if oid is None:
            row = self.db.execute("SELECT id FROM objects WHERE key=?", (key,)).fetchone()
            oid = row[0] if row else self.db.execute("INSERT INTO objects (key) VALUES (?)", (key,)).lastrowid
            self.object_ids[key] = oid
        return oid

    def open_pack(self):
        if self.pack_file is None:
            self.pack_id = self.newest_pack()
            if self.db.execute("SELECT 1 FROM packs WHERE id=?", (self.pack_id,)).fetchone():
                self.pack_id += 1
            self.pack_file = open(self.pack_path(self.pack_id), "ab")
        if self.pack_file.tell() >= PACK_LIMIT:
            self.pack_file.close()
            self.pack_id = self.newest_pack() + 1
            self.pack_file = open(self.pack_path(self.pack_id), "ab")
        return self.pack_file

    def newest_pack(self):
        packs = [int(n.split(".")[0]) for n in os.listdir(os.path.join(self.root, "packs")) if n.endswith(".pack")]
        return max(packs + [r[0] for r in self.db.execute("SELECT id FROM packs")], default=0)

    def pack_path(self, pack):
        return os.path.join(self.root, "packs", f"{pack:08d}.pack")

    def append(self, blob):
        f = self.open_pack()
        offset = f.tell()
        f.write(blob)
        return self.pack_id, offset

    def put(self, key, raw, codec, meta):
        oid = self.object_id(key)
        row = self.db.execute("SELECT chain, hash, body FROM latest WHERE object=?", (oid,)).fetchone()
        h = digest(raw)
        if row and row[1] == h:
            return False
        prev = self.unzstd.decompress(row[2], max_output_size=MAX_OUTPUT) if row and row[2] is not None else None
        if prev is not None and row[0] + 1 < self.keyframe:
            blob = zstandard.ZstdCompressor(
                level=self.level, dict_data=zstandard.ZstdCompressionDict(prev, dict_type=zstandard.DICT_TYPE_RAWCONTENT)
            ).compress(raw)
            kind, chain = DELTA, row[0] + 1
        else:
            blob = self.compress_full(key, raw, self.level)
            kind, chain = FULL, 0
        pack, offset = self.append(blob)
        self.pending.append((oid, kind, codec, meta, pack, offset, len(blob), len(raw), h))
        self.db.execute(
            "INSERT OR REPLACE INTO latest VALUES (?, -1, ?, ?, ?, ?, ?)", (oid, chain, codec, meta, h, self.fast.compress(raw))
        )
        self.point_bytes += len(blob)
        self.point_versions += 1
        return True

    def remove(self, key):
        known = self.object_ids.get(key) or self.db.execute("SELECT id FROM objects WHERE key=?", (key,)).fetchone()
        if not known:
            return False
        oid = self.object_id(key)
        row = self.db.execute("SELECT body FROM latest WHERE object=?", (oid,)).fetchone()
        if not row or row[0] is None:
            return False
        self.pending.append((oid, GONE, RAW, 0, None, None, None, None, None))
        self.db.execute("UPDATE latest SET chain=0, hash=NULL, body=NULL WHERE object=?", (oid,))
        self.point_versions += 1
        return True

    def commit(self, captured, source):
        if self.pack_file is not None:
            self.pack_file.flush()
            os.fsync(self.pack_file.fileno())
        point = self.db.execute(
            "INSERT INTO points (captured, applied, source, versions, bytes) VALUES (?, ?, ?, ?, ?)",
            (captured, time.time(), source, self.point_versions, self.point_bytes),
        ).lastrowid
        self.db.executemany(
            "INSERT INTO versions VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [(oid, point, kind, codec, meta, pack, offset, length, size, h) for oid, kind, codec, meta, pack, offset, length, size, h in self.pending],
        )
        self.db.execute("UPDATE latest SET point=? WHERE point=-1", (point,))
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
            blob = self.read_blob(pack, offset, length)
            if kind == FULL:
                raw = self.decompress_full(blob, size)
            else:
                raw = zstandard.ZstdDecompressor(
                    dict_data=zstandard.ZstdCompressionDict(raw, dict_type=zstandard.DICT_TYPE_RAWCONTENT)
                ).decompress(blob, max_output_size=max(size, 1))
        return raw

    def point_at(self, when):
        row = self.db.execute("SELECT id, captured FROM points WHERE captured<=? ORDER BY captured DESC, id DESC LIMIT 1", (when,)).fetchone()
        if row is None:
            sys.exit(f"no point at or before {when}")
        return row


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
    seen = set()
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
                ingest_region(store, path, rel, data, full)
            else:
                raw, codec = file_raw(rel, data)
                store.put(rel, raw, codec, int(st.st_mtime))
            store.db.execute("INSERT OR REPLACE INTO files VALUES (?, ?, ?)", (rel, *sig))
    for rel in set(known) - seen:
        if is_region(rel):
            for (idx,) in store.db.execute("SELECT idx FROM slots WHERE path=?", (rel,)).fetchall():
                store.remove(f"{rel}#{idx}")
            store.db.execute("DELETE FROM slots WHERE path=?", (rel,))
        store.remove(rel)
        store.db.execute("DELETE FROM files WHERE path=?", (rel,))
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
    else:
        store.put(rel, b"", RAW, 0)


def encode_chunk(raw, kind):
    if kind == 1:
        return gzip.compress(raw, 6), 1
    if kind == 3:
        return raw, 3
    if kind == 2:
        return zlib.compress(raw, 6), 2
    return raw, kind


def write_region(path, chunks):
    if not chunks:
        open(path, "wb").close()
        return
    header = bytearray(2 * SECTOR)
    body = bytearray()
    next_sector = 2
    for idx in sorted(chunks):
        raw, meta = chunks[idx]
        data, kind = encode_chunk(raw, meta & 0xFF)
        record = struct.pack(">IB", len(data) + 1, kind) + data
        if len(record) > 255 * SECTOR:
            x, z = (int(v) for v in os.path.basename(path).split(".")[1:3])
            with open(os.path.join(os.path.dirname(path), f"c.{x * 32 + idx % 32}.{z * 32 + idx // 32}.mcc"), "wb") as f:
                f.write(data)
            record = struct.pack(">IB", 1, kind | 0x80)
        sectors = -(-len(record) // SECTOR)
        struct.pack_into(">I", header, idx * 4, (next_sector << 8) | sectors)
        struct.pack_into(">I", header, SECTOR + idx * 4, meta >> 8)
        body += record + bytes(sectors * SECTOR - len(record))
        next_sector += sectors
    with open(path, "wb") as f:
        f.write(header)
        f.write(body)


def live_objects(store, point, prefix):
    rows = store.db.execute(
        "SELECT o.id, o.key FROM objects o WHERE o.key >= ? AND o.key < ? ORDER BY o.key", (prefix, prefix + "\U0010ffff")
    ).fetchall()
    for oid, key in rows:
        chain = store.chain_for(oid, point)
        if chain:
            yield key, chain


def restore(store, when, out, prefix):
    point, captured = store.point_at(when)
    regions = {}
    files = 0
    for key, chain in live_objects(store, point, prefix):
        raw = store.materialize(chain)
        _, _, codec, meta, *_ = chain[-1]
        m = CHUNK_KEY.match(key)
        if m:
            regions.setdefault(m.group(1), {})[int(m.group(2))] = (raw, meta)
            continue
        if is_region(key):
            regions.setdefault(key, {})
            continue
        target = os.path.join(out, key)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "wb") as f:
            f.write(gzip.compress(raw, 6, mtime=meta) if codec == GZIP else raw)
        os.utime(target, (meta, meta))
        files += 1
    for rel, chunks in regions.items():
        target = os.path.join(out, rel)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        write_region(target, chunks)
        os.utime(target, (captured, captured))
    print(f"restored point {point} captured {time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(captured))}: {files} files, {len(regions)} region files")


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
            blob = store.read_blob(pack, offset, length)
            if kind == FULL:
                raw = store.decompress_full(blob, size)
            else:
                raw = zstandard.ZstdDecompressor(
                    dict_data=zstandard.ZstdCompressionDict(raw, dict_type=zstandard.DICT_TYPE_RAWCONTENT)
                ).decompress(blob, max_output_size=max(size, 1))
            total += 1
            if digest(raw) != h:
                bad += 1
                print(f"object {oid}: version hash mismatch", file=sys.stderr)
    print(f"checked {total} versions of {len(oids[:: max(1, sample)])} objects: {bad} mismatches")
    return bad == 0


def verify(store, mirror, when, prefix):
    point = store.point_at(when)[0]
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
                if not chunk_entries(data):
                    expected[rel] = digest(b"")
                for idx, (location, _) in chunk_entries(data).items():
                    try:
                        expected[f"{rel}#{idx}"] = digest(chunk_raw(data, location, path, idx)[0])
                    except (zlib.error, struct.error, OSError, ValueError):
                        pass
            else:
                expected[rel] = digest(file_raw(rel, data)[0])
    stored = {}
    for oid, key in store.db.execute("SELECT id, key FROM objects").fetchall():
        if not key.startswith(prefix):
            continue
        chain = store.chain_for(oid, point)
        if chain:
            stored[key] = chain[-1][-1]
    missing = sorted(set(expected) - set(stored))
    extra = sorted(set(stored) - set(expected))
    differ = sorted(k for k in set(expected) & set(stored) if expected[k] != stored[k])
    for label, keys in (("missing", missing), ("extra", extra), ("differ", differ)):
        for k in keys[:20]:
            print(f"{label}: {k}", file=sys.stderr)
    print(f"verified {len(expected)} objects against point {point}: {len(missing)} missing, {len(extra)} extra, {len(differ)} differ")
    return not (missing or extra or differ)


def import_versions(store, versions, prefixes, deletions, reference, reference_prefix):
    record = struct.Struct(">dI")
    events = []
    keys = {}
    for name in sorted(os.listdir(versions)):
        rel = name.replace("__", "/")
        if any(rel.startswith(p) for p in prefixes):
            m = re.match(r"^(.*\.mca)\.(\d+)$", rel)
            keys[f"{m.group(1)}#{m.group(2)}" if m else rel] = name
    directories = {key.rsplit("/", 1)[0] for key in keys if "/" in key}
    while True:
        parents = {d.rsplit("/", 1)[0] for d in directories if "/" in d} - directories
        if not parents:
            break
        directories |= parents
    if reference:
        directories |= {key for key in keys if key.startswith(reference_prefix) and os.path.isdir(os.path.join(reference, key[len(reference_prefix):]))}
    for key, name in keys.items():
        if key in directories:
            continue
        with open(os.path.join(versions, name), "rb") as f:
            data = f.read()
        pos = 0
        while pos < len(data):
            t, length = record.unpack_from(data, pos)
            pos += record.size
            events.append((t, 1, key, name, pos, length))
            pos += length
    if deletions:
        with open(deletions) as f:
            for line in f:
                t, key = line.rstrip("\n").split("\t", 1)
                if key not in directories and any(key.startswith(p) for p in prefixes):
                    events.append((float(t), 0, key, None, 0, 0))
    events.sort()
    unzstd = zstandard.ZstdDecompressor()
    i = points = removed = 0
    start = time.monotonic()
    while i < len(events):
        t = events[i][0]
        store.begin()
        while i < len(events) and events[i][0] == t:
            _, kind, key, name, pos, length = events[i]
            i += 1
            if kind == 0:
                removed += store.remove(key)
                continue
            with open(os.path.join(versions, name), "rb") as f:
                f.seek(pos)
                raw = unzstd.decompress(f.read(length), max_output_size=MAX_OUTPUT)
            if CHUNK_KEY.match(key):
                store.put(key, raw, CHUNK, (int(t) << 8) | 2)
            else:
                store.put(key, raw, file_codec(key, reference, reference_prefix), int(t))
        store.commit(t, "import")
        points += 1
        if points % 200 == 0:
            print(f"{points} points, {i}/{len(events)} events, {time.monotonic() - start:.0f}s", flush=True)
    print(f"imported {len(events)} events over {points} points, {removed} removals")


def file_codec(key, reference, reference_prefix):
    if reference and key.startswith(reference_prefix):
        try:
            with open(os.path.join(reference, key[len(reference_prefix):]), "rb") as f:
                return GZIP if f.read(2) == b"\x1f\x8b" else RAW
        except OSError:
            pass
    return GZIP if is_gzip_nbt(key) or key.endswith(".gz") else RAW


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


def compact(store, level, limit):
    store.train_dicts()
    cold = {r[0] for r in store.db.execute("SELECT id FROM packs")}
    hot_tip = max((p for p in range(store.newest_pack() + 1) if p not in cold and os.path.exists(store.pack_path(p))), default=None)
    sealed = [r[0] for r in store.db.execute("SELECT DISTINCT pack FROM versions WHERE pack IS NOT NULL ORDER BY pack") if r[0] not in cold and r[0] != hot_tip]
    for old in sealed[:limit]:
        start = time.monotonic()
        store.db.execute("BEGIN IMMEDIATE")
        new = store.newest_pack() + 1
        store.db.execute("INSERT INTO packs VALUES (?, ?)", (new, level))
        store.db.execute("COMMIT")
        rows = store.db.execute(
            "SELECT v.object, v.point, v.kind, v.offset, v.length, v.size, v.hash, o.key FROM versions v JOIN objects o ON o.id = v.object WHERE v.pack=? ORDER BY v.object, v.point",
            (old,),
        ).fetchall()
        moved = []
        before = after = 0
        with open(store.pack_path(new), "xb") as out:
            cached = (None, None, None)
            for oid, point, kind, offset, length, size, h, key in rows:
                if kind == DELTA:
                    prev = cached[2] if cached[0] == oid and cached[1] == point else None
                    if prev is None:
                        prev_point = store.db.execute(
                            "SELECT MAX(point) FROM versions WHERE object=? AND point<?", (oid, point)
                        ).fetchone()[0]
                        prev = store.materialize(store.chain_for(oid, prev_point))
                else:
                    prev = None
                raw = unpatch(store, prev, store.read_blob(old, offset, length), size)
                blob = patch(store, key, prev, raw, level)
                if digest(unpatch(store, prev, blob, size)) != h or digest(raw) != h:
                    sys.exit(f"pack {old}: object {oid} point {point} does not round-trip; leaving the pack untouched")
                moved.append((new, out.tell(), len(blob), oid, point))
                out.write(blob)
                before += length
                after += len(blob)
                following = store.db.execute(
                    "SELECT MIN(point) FROM versions WHERE object=? AND point>?", (oid, point)
                ).fetchone()[0]
                cached = (oid, following, raw)
            out.flush()
            os.fsync(out.fileno())
        store.db.execute("BEGIN IMMEDIATE")
        store.db.executemany("UPDATE versions SET pack=?, offset=?, length=? WHERE object=? AND point=?", moved)
        store.db.execute("COMMIT")
        store.readers.pop(old, None)
        os.unlink(store.pack_path(old))
        print(f"pack {old} -> {new}: {len(moved)} versions, {before} -> {after} bytes in {time.monotonic() - start:.0f}s", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--store", required=True)
    ap.add_argument("--level", type=int, default=3)
    ap.add_argument("--keyframe", type=int, default=32)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("ingest")
    p.add_argument("--mirror", required=True)
    p.add_argument("--captured", type=float)
    p.add_argument("--source", default="ingest")
    p.add_argument("--full", action="store_true")
    p = sub.add_parser("import")
    p.add_argument("--versions", required=True)
    p.add_argument("--prefix", action="append", default=[])
    p.add_argument("--deletions")
    p.add_argument("--reference")
    p.add_argument("--reference-prefix", default="")
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
    sub.add_parser("points")
    args = ap.parse_args()
    store = Store(args.store, args.level, args.keyframe)
    if args.cmd == "ingest":
        start = time.monotonic()
        point = ingest(store, args.mirror, args.captured or time.time(), args.source, args.full)
        versions, size = store.db.execute("SELECT versions, bytes FROM points WHERE id=?", (point,)).fetchone()
        print(f"point {point}: {versions} versions, {size} bytes in {time.monotonic() - start:.2f}s")
    elif args.cmd == "import":
        import_versions(store, args.versions, args.prefix or [""], args.deletions, args.reference, args.reference_prefix)
    elif args.cmd == "restore":
        restore(store, args.at, args.out, args.prefix)
    elif args.cmd == "check":
        sys.exit(0 if check(store, args.sample) else 1)
    elif args.cmd == "verify":
        sys.exit(0 if verify(store, args.mirror, args.at, args.prefix) else 1)
    elif args.cmd == "compact":
        compact(store, args.to_level, args.limit)
    elif args.cmd == "points":
        for pid, captured, source, versions, size in store.db.execute("SELECT id, captured, source, versions, bytes FROM points ORDER BY id"):
            print(f"{pid}\t{time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(captured))}\t{source}\t{versions}\t{size}")


if __name__ == "__main__":
    main()
