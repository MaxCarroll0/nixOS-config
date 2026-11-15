#!/usr/bin/env python3
# Store index over the nix database plus a persistent per-path disk cache, and LRU dead-path collection.

import argparse
import json
import os
import re
import sqlite3
import subprocess
import time

GIB = 1024 ** 3
NIX_DB = "file:/nix/var/nix/db/db.sqlite?mode=ro"
CACHE = os.environ.get("STORE_INDEX_CACHE", "/var/lib/disk-ledger/store-index.sqlite")
DELETE_BATCH = 1000
FREED = re.compile(r"(\d+) store paths deleted, ([\d.]+) (KiB|MiB|GiB) freed")
UNITS = {"KiB": 1024, "MiB": 1024 ** 2, "GiB": 1024 ** 3}
ALIVE = re.compile(r"[Cc]annot delete path '([^']+)'")
STORE_PATH = re.compile(r"/nix/store/[^/\s]+")


def setting(name):
    out = subprocess.run(["nix", "config", "show", name], capture_output=True, text=True).stdout.strip()
    return out == "true"


def gc_roots():
    out = subprocess.run(["nix-store", "--gc", "--print-roots"], capture_output=True, text=True).stdout
    roots = {}
    for line in out.splitlines():
        link, _, target = line.rpartition(" -> ")
        match = STORE_PATH.match(target)
        if match:
            roots.setdefault(match.group(0), []).append(link)
    return roots


class Index:
    def __init__(self, cache=CACHE):
        self.cache_path = cache
        self.cache = None
        self.disk = {}
        self.cache_seen = 0
        self.calibrated = None
        self.db = None
        self.version = None
        self.root_links = None
        self.path_of = {}
        self.registered = {}
        self.nar = {}
        self.deriver = {}
        self.references = {}
        self.referrers = {}

    def refresh(self):
        if self.db is None:
            self.db = sqlite3.connect(NIX_DB, uri=True, check_same_thread=False)
        version = self.db.execute("pragma data_version").fetchone()[0]
        changed = version != self.version
        if changed:
            self.load_paths()
            self.version = version
        roots = gc_roots()
        if not changed and roots == self.root_links:
            self.load_cache()
            return False
        self.root_links = roots
        outputs = {}
        if setting("keep-outputs"):
            for drv, path in self.db.execute("select v.path, o.path from DerivationOutputs o join ValidPaths v on v.id = o.drv"):
                outputs.setdefault(drv, []).append(path)
        keep_derivations = setting("keep-derivations")
        self.roots = {path for path in roots if path in self.nar}
        live = set()
        stack = list(self.roots)
        while stack:
            path = stack.pop()
            if path in live:
                continue
            live.add(path)
            stack.extend(ref for ref in self.references[path] if ref not in live)
            if keep_derivations and self.deriver.get(path) in self.nar:
                stack.append(self.deriver[path])
            stack.extend(out for out in outputs.get(path, []) if out in self.nar)
        self.live = live
        self.dead = [path for path in self.nar if path not in live]
        self.used = {}
        for path in self.nar:
            try:
                accessed = os.lstat(path).st_atime
            except OSError:
                accessed = 0
            self.used[path] = int(max(self.registered[path], accessed))
        self.effective = self.effective_use(self.dead)
        self.load_cache()
        return True

    def load_paths(self):
        ids = {row[0] for row in self.db.execute("select id from ValidPaths")}
        for gone in [key for key in self.path_of if key not in ids]:
            path = self.path_of.pop(gone)
            for ref in self.references.pop(path, ()):
                self.referrers.get(ref, set()).discard(path)
            for up in self.referrers.pop(path, ()):
                self.references.get(up, set()).discard(path)
            for table in (self.registered, self.nar, self.deriver):
                table.pop(path, None)
        new = sorted(ids - self.path_of.keys())
        for start in range(0, len(new), 900):
            chunk = new[start : start + 900]
            marks = ",".join("?" * len(chunk))
            for key, path, registered, nar, deriver in self.db.execute(f"select id, path, registrationTime, narSize, deriver from ValidPaths where id in ({marks})", chunk):
                self.path_of[key] = path
                self.registered[path] = registered or 0
                self.nar[path] = nar or 0
                if deriver:
                    self.deriver[path] = deriver
                self.references.setdefault(path, set())
                self.referrers.setdefault(path, set())
        for start in range(0, len(new), 900):
            chunk = new[start : start + 900]
            marks = ",".join("?" * len(chunk))
            for referrer, reference in self.db.execute(f"select referrer, reference from Refs where referrer in ({marks})", chunk):
                if referrer == reference:
                    continue
                source, target = self.path_of.get(referrer), self.path_of.get(reference)
                if source and target:
                    self.references[source].add(target)
                    self.referrers[target].add(source)

    def closure(self, paths):
        found = set()
        stack = [path for path in paths if path in self.nar]
        while stack:
            path = stack.pop()
            if path in found:
                continue
            found.add(path)
            stack.extend(ref for ref in self.references[path] if ref not in found)
        return found

    def dependents(self, paths):
        found = set()
        stack = [path for path in paths if path in self.nar]
        while stack:
            path = stack.pop()
            if path in found:
                continue
            found.add(path)
            stack.extend(up for up in self.referrers[path] if up not in found and os.path.exists(up))
        return found

    def effective_use(self, dead):
        dead_set = set(dead)
        effective = {}
        for start in dead:
            if start in effective:
                continue
            stack = [(start, False)]
            while stack:
                path, expanded = stack.pop()
                if path in effective:
                    continue
                above = [up for up in self.referrers[path] if up in dead_set]
                if expanded:
                    effective[path] = max([self.used[path]] + [effective.get(up, 0) for up in above])
                    continue
                stack.append((path, True))
                stack.extend((up, False) for up in above if up not in effective)
        return effective

    def load_cache(self):
        if self.cache is None:
            os.makedirs(os.path.dirname(self.cache_path), exist_ok=True)
            self.cache = sqlite3.connect(self.cache_path, timeout=60, check_same_thread=False)
            self.cache.execute("pragma journal_mode=wal")
            self.cache.execute("create table if not exists disk (path text primary key, share integer, own integer, scanned integer)")
            self.cache.execute("create table if not exists drift (id integer primary key check (id = 0), bytes integer, reconciled integer)")
            self.cache.execute("insert or ignore into drift values (0, 0, 0)")
            self.cache.commit()
        self.cache.execute("begin immediate")
        for path, share, own, scanned in self.cache.execute("select path, share, own, scanned from disk where scanned >= ?", (self.cache_seen,)).fetchall():
            self.disk[path] = (share, own, scanned)
            self.cache_seen = max(self.cache_seen, scanned)
        for path in [path for path in self.disk if path not in self.nar]:
            share, own, _ = self.disk.pop(path)
            if self.cache.execute("delete from disk where path = ?", (path,)).rowcount:
                self.shift(own - share)
        self.cache.commit()

    def shift(self, delta):
        if delta:
            self.cache.execute("update drift set bytes = bytes + ? where id = 0", (delta,))

    def reconcile(self, bytes):
        self.cache.execute("update drift set bytes = ?, reconciled = ? where id = 0", (bytes, int(time.time())))
        self.cache.commit()

    def drift(self):
        return self.cache.execute("select bytes from drift where id = 0").fetchone()[0]

    def reconciled(self):
        return self.cache.execute("select reconciled from drift where id = 0").fetchone()[0]

    def ratio(self):
        if self.calibrated is not None:
            return self.calibrated
        scanned = [path for path in self.disk if path in self.nar]
        nar = sum(self.nar[path] for path in scanned)
        return sum(self.disk[path][0] for path in scanned) / nar if nar else 1.0

    def calibrate(self, store_bytes):
        scanned = sum(share for path, (share, _, _) in self.disk.items() if path in self.nar)
        unscanned = sum(nar for path, nar in self.nar.items() if path not in self.disk)
        self.calibrated = max(0.0, store_bytes - scanned) / unscanned if unscanned else 1.0

    def sizes(self, kind="share"):
        column = 0 if kind == "share" else 1
        ratio = self.ratio()
        return {path: self.disk[path][column] if path in self.disk else int(self.nar[path] * ratio) for path in self.nar}

    def coverage(self):
        return len(self.disk) / max(1, len(self.nar))

    def scan(self, budget_seconds, stale_after=7 * 86400, wanted=None):
        deadline = time.monotonic() + budget_seconds
        now = int(time.time())
        pending = [path for path in (self.nar if wanted is None else wanted) if path in self.nar and (path not in self.disk or now - self.disk[path][2] > stale_after)]
        pending.sort(key=lambda path: (path in self.disk, self.disk.get(path, (0, 0, 0))[2]))
        done = 0
        oldest = min((entry[2] for entry in self.disk.values()), default=now)
        for path in pending:
            if time.monotonic() > deadline:
                break
            row = self.cache.execute("select share, own, scanned from disk where path = ?", (path,)).fetchone()
            if row and now - row[2] <= stale_after and row[2] > self.disk.get(path, (0, 0, 0))[2]:
                self.disk[path] = tuple(row)
                continue
            share, own = walk(path)
            if path in self.disk:
                self.shift(share - self.disk[path][0])
            elif self.registered.get(path, 0) > oldest:
                self.shift(share - own)
            self.disk[path] = (share, own, now)
            self.cache.execute("insert or replace into disk values (?, ?, ?, ?)", (path, share, own, now))
            done += 1
            if done % 500 == 0:
                self.cache.commit()
        self.cache.commit()
        return done, len(pending) - done

    def order(self, paths):
        chosen = set(paths)
        pending = {path: sum(1 for up in self.referrers[path] if up in chosen) for path in chosen}
        ready = sorted((path for path, count in pending.items() if count == 0), key=lambda p: self.effective.get(p, 0))
        out = []
        while ready:
            path = ready.pop()
            out.append(path)
            for ref in self.references[path]:
                if ref in pending:
                    pending[ref] -= 1
                    if pending[ref] == 0:
                        ready.append(ref)
        return out


def walk(path):
    share = own = 0
    seen = set()
    stack = [path]
    while stack:
        current = stack.pop()
        try:
            stat = os.lstat(current)
        except OSError:
            continue
        if stat.st_ino in seen:
            continue
        seen.add(stat.st_ino)
        size = stat.st_blocks * 512
        if os.path.stat.S_ISDIR(stat.st_mode):
            share += size
            own += size
            try:
                stack.extend(os.path.join(current, name) for name in os.listdir(current))
            except OSError:
                pass
            continue
        links = stat.st_nlink
        share += size // (links - 1) if links > 2 else size
        if links <= 2:
            own += size
    return share, own


def select(index, need, before=None):
    sizes = index.sizes("own")
    old = sorted((p for p in index.dead if before is None or index.effective[p] < before), key=lambda p: (index.effective[p], p))
    chosen = []
    freed = 0
    for path in old:
        if freed >= need and index.effective[path] != index.effective[chosen[-1]]:
            break
        chosen.append(path)
        freed += sizes[path]
    return old, chosen, freed


def rows(index, chosen):
    sizes = index.sizes("own")
    return [{"path": path, "size": sizes[path], "last_used": index.effective.get(path, index.used[path])} for path in chosen]


def delete(paths):
    result = subprocess.run(["nix-store", "--delete", *paths], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    output = result.stdout + result.stderr
    match = FREED.search(output)
    deleted = int(match.group(1)) if match else 0
    freed = float(match.group(2)) * UNITS[match.group(3)] if match else 0
    return result.returncode == 0, deleted, freed, set(ALIVE.findall(output))


def delete_all(index, paths):
    deleted = freed = 0
    refused = set()
    ordered = index.order(index.dependents(paths))
    for start in range(0, len(ordered), DELETE_BATCH):
        batch = [path for path in ordered[start : start + DELETE_BATCH] if path not in refused]
        while batch:
            ok, count, size, alive = delete(batch)
            deleted += count
            freed += size
            if ok:
                break
            live = index.closure(alive) & set(ordered) if alive else set(batch)
            refused |= live
            batch = [path for path in batch if path not in live and os.path.exists(path)]
    return deleted, freed, refused


def main():
    parser = argparse.ArgumentParser(prog="store-collect")
    parser.add_argument("--need-gib", type=float, required=True, help="free this much, least recently used dead paths first")
    parser.add_argument("--apply", action="store_true", help="delete; the default only reports")
    parser.add_argument("--json", action="store_true", help="print the selection as JSON")
    parser.add_argument("--before", type=float, help="only paths last used before this epoch second")
    options = parser.parse_args()

    started = time.time()
    index = Index().refresh()
    need = options.need_gib * GIB
    old, chosen, claimed = select(index, need, options.before)
    own = index.sizes("own")
    dead_bytes = sum(own[p] for p in old)

    deleted = freed = 0
    refused = set()
    if options.apply:
        deleted, freed, refused = delete_all(index, chosen)

    if options.json:
        print(json.dumps({
            "stage": "store",
            "applied": options.apply,
            "dead_paths": len(old),
            "dead_bytes": dead_bytes,
            "need": need,
            "freed": freed if options.apply else claimed,
            "claimed": claimed,
            "deleted": deleted,
            "refused": len(refused),
            "seconds": round(time.time() - started, 1),
            "selected": rows(index, chosen),
        }))
        return 0

    print("dead %d paths (%.1f GiB); selected %d (%.2f GiB of %.2f GiB needed)" % (len(old), dead_bytes / GIB, len(chosen), claimed / GIB, need / GIB))
    if chosen:
        print("last used between %s and %s" % (time.strftime("%Y-%m-%d %H:%M", time.localtime(index.effective[chosen[0]])), time.strftime("%Y-%m-%d %H:%M", time.localtime(index.effective[chosen[-1]]))))
    if options.apply:
        print("deleted %d paths, %.2f GiB freed, %d refused" % (deleted, freed / GIB, len(refused)))
    else:
        for path in sorted(chosen, key=lambda p: -own[p])[:20]:
            print("  %8.1f MiB  %s" % (own[path] / 2 ** 20, path))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
