#!/usr/bin/env python3
# Store index over the nix database, exact per-path disk use from shared-inode accounting, and dead-path deletion.

import argparse
import array
import json
import os
import re
import sqlite3
import stat
import subprocess
import time

GIB = 1024 ** 3
NIX_DB = "file:/nix/var/nix/db/db.sqlite?mode=ro"
CACHE = os.environ.get("STORE_INDEX_CACHE", "/var/lib/disk-ledger/store-index.sqlite")
LINKS = "/nix/store/.links"
DELETE_BATCH = 1000
FREED = re.compile(r"(\d+) store paths deleted, ([\d.]+) (KiB|MiB|GiB) freed")
UNITS = {"KiB": 1024, "MiB": 1024 ** 2, "GiB": 1024 ** 3}
ALIVE = re.compile(r"[Cc]annot delete path '([^']+)'")
STORE_PATH = re.compile(r"/nix/store/[^/\s]+")
O_NOATIME = 0o1000000
WALK_FLAGS = [os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC | O_NOATIME]


SETTINGS = {}


def setting(name):
    if name not in SETTINGS:
        SETTINGS[name] = subprocess.run(["nix", "config", "show", name], capture_output=True, text=True).stdout.strip() == "true"
    return SETTINGS[name]


def gc_roots():
    out = subprocess.run(["nix-store", "--gc", "--print-roots"], capture_output=True, text=True).stdout
    roots = {}
    for line in out.splitlines():
        link, _, target = line.rpartition(" -> ")
        link = link.strip().strip('"')
        match = STORE_PATH.match(target.strip().strip('"'))
        if match:
            roots.setdefault(match.group(0), []).append(link)
    return roots


def open_dir(relative, dir_fd=None):
    try:
        return os.open(relative, WALK_FLAGS[0], dir_fd=dir_fd)
    except PermissionError:
        if not WALK_FLAGS[0] & O_NOATIME:
            raise
        WALK_FLAGS[0] &= ~O_NOATIME
        return os.open(relative, WALK_FLAGS[0], dir_fd=dir_fd)


def walk(path):
    try:
        info = os.lstat(path)
    except OSError:
        return None
    own = 0
    used = 0
    shared = {}

    def account(entry):
        nonlocal own, used
        blocks = entry.st_blocks * 512
        if entry.st_nlink > 1 and not stat.S_ISDIR(entry.st_mode):
            shared[entry.st_ino] = blocks
        else:
            own += blocks
        if stat.S_ISREG(entry.st_mode) and entry.st_atime > used:
            used = entry.st_atime

    account(info)
    if stat.S_ISDIR(info.st_mode):
        try:
            root = open_dir(path)
        except OSError:
            return None
        try:
            stack = [None]
            while stack:
                relative = stack.pop()
                try:
                    fd = os.dup(root) if relative is None else open_dir(relative, root)
                except OSError:
                    continue
                try:
                    with os.scandir(fd) as entries:
                        for entry in entries:
                            try:
                                child = entry.stat(follow_symlinks=False)
                            except OSError:
                                continue
                            account(child)
                            if stat.S_ISDIR(child.st_mode):
                                stack.append(entry.name if relative is None else relative + "/" + entry.name)
                finally:
                    os.close(fd)
        finally:
            os.close(root)
    inodes = array.array("Q")
    for ino, blocks in shared.items():
        inodes.append(ino)
        inodes.append(blocks)
    return own, inodes, int(used)


class Index:
    def __init__(self, cache=CACHE):
        self.cache_path = cache
        self.cache = None
        self.db = None
        self.version = None
        self.root_links = None
        self.roots = set()
        self.live = set()
        self.dead = []
        self.effective = {}
        self.path_of = {}
        self.registered = {}
        self.nar = {}
        self.deriver = {}
        self.references = {}
        self.referrers = {}
        self.own = {}
        self.inodes = {}
        self.holders = {}
        self.blocks = {}
        self.claimant = {}
        self.sizes = {}
        self.used = {}
        self.pending = set()
        self.touched = set()
        self.own_total = 0
        self.shared_total = 0
        self.orphan_bytes = 0
        self.orphan_count = 0
        self.links_blocks = 0
        self.walked = 0

    def load(self):
        if self.db is None:
            self.db = sqlite3.connect(NIX_DB, uri=True, check_same_thread=False)
        version = self.db.execute("pragma data_version").fetchone()[0]
        if version == self.version:
            return False
        before = set(self.nar)
        self.load_paths()
        self.version = version
        if self.cache is None:
            self.load_cache()
        for path in before - self.nar.keys():
            self.forget(path)
        for path in self.nar.keys() - before:
            if path not in self.own:
                self.pending.add(path)
        return True

    def refresh(self):
        self.load()
        self.refresh_roots()
        return self

    def refresh_roots(self):
        self.root_links = gc_roots()
        self.liveness()

    def liveness(self):
        outputs = {}
        if setting("keep-outputs"):
            for drv, path in self.db.execute("select v.path, o.path from DerivationOutputs o join ValidPaths v on v.id = o.drv"):
                outputs.setdefault(drv, []).append(path)
        keep_derivations = setting("keep-derivations")
        self.roots = {path for path in self.root_links if path in self.nar}
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
        self.effective = self.effective_use(self.dead)

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

    def load_cache(self):
        os.makedirs(os.path.dirname(self.cache_path), exist_ok=True)
        self.cache = sqlite3.connect(self.cache_path, timeout=60, check_same_thread=False)
        self.cache.execute("pragma journal_mode=wal")
        self.cache.execute("drop table if exists disk")
        self.cache.execute("drop table if exists drift")
        self.cache.execute("create table if not exists store (path text primary key, own integer, used integer, inodes blob)")
        self.cache.commit()
        stale = []
        for path, own, used, blob in self.cache.execute("select path, own, used, inodes from store"):
            if path not in self.nar:
                stale.append((path,))
                continue
            inodes = array.array("Q")
            inodes.frombytes(blob)
            self.attach(path, own, inodes)
            self.used[path] = max(used, self.registered.get(path, 0))
        self.cache.executemany("delete from store where path = ?", stale)
        self.cache.commit()
        self.pending = {path for path in self.nar if path not in self.own}

    def attach(self, path, own, inodes):
        self.sizes.clear()
        self.own[path] = own
        self.inodes[path] = inodes
        self.own_total += own
        holders, blocks = self.holders, self.blocks
        for position in range(0, len(inodes), 2):
            ino = inodes[position]
            count = holders.get(ino, 0)
            if count == 0:
                blocks[ino] = inodes[position + 1]
                self.shared_total += inodes[position + 1]
            holders[ino] = count + 1

    def detach(self, path):
        self.sizes.clear()
        inodes = self.inodes.pop(path, None)
        self.own_total -= self.own.pop(path, 0)
        if inodes is None:
            return
        holders, blocks, claimant = self.holders, self.blocks, self.claimant
        for position in range(0, len(inodes), 2):
            ino = inodes[position]
            if claimant.get(ino) == path:
                del claimant[ino]
            count = holders[ino] - 1
            if count:
                holders[ino] = count
            else:
                del holders[ino]
                self.shared_total -= blocks.pop(ino)

    def forget(self, path):
        self.detach(path)
        self.used.pop(path, None)
        self.pending.discard(path)
        self.touched.discard(path)
        if self.cache is not None:
            self.cache.execute("delete from store where path = ?", (path,))

    def measure(self, path):
        result = walk(path)
        if result is None:
            return False
        own, inodes, used = result
        self.detach(path)
        self.attach(path, own, inodes)
        self.used[path] = max(self.used.get(path, 0), used, self.registered.get(path, 0))
        self.cache.execute("insert or replace into store values (?, ?, ?, ?)", (path, own, self.used[path], inodes.tobytes()))
        self.walked += 1
        return True

    def walk_pending(self, deadline):
        done = 0
        while self.pending and time.monotonic() < deadline:
            path = self.pending.pop()
            if path in self.nar and self.measure(path):
                done += 1
        if done:
            self.cache.commit()
        return done

    def touch(self, path, when):
        if path in self.nar and when > self.used.get(path, 0):
            self.used[path] = when
            self.touched.add(path)

    def flush_used(self):
        if self.touched:
            self.cache.executemany("update store set used = ? where path = ?", [(self.used[path], path) for path in self.touched if path in self.used])
            self.cache.commit()
            self.touched.clear()

    def scan_links(self):
        holders = self.holders
        orphan_bytes = orphan_count = 0
        try:
            self.links_blocks = os.lstat(LINKS).st_blocks * 512
            with os.scandir(LINKS) as entries:
                for entry in entries:
                    if entry.inode() not in holders:
                        try:
                            orphan_bytes += entry.stat(follow_symlinks=False).st_blocks * 512
                            orphan_count += 1
                        except OSError:
                            continue
        except OSError:
            pass
        self.orphan_bytes, self.orphan_count = orphan_bytes, orphan_count

    def registered_bytes(self):
        return self.own_total + self.shared_total

    def size(self, path):
        known = self.sizes.get(path)
        if known is not None:
            return known
        own = self.own.get(path)
        if own is None:
            return 0
        inodes = self.inodes[path]
        holders, blocks, claimant = self.holders, self.blocks, self.claimant
        total = own
        for position in range(0, len(inodes), 2):
            ino = inodes[position]
            share, remainder = divmod(blocks[ino], holders[ino])
            total += share
            if remainder and claimant.setdefault(ino, path) == path:
                total += remainder
        self.sizes[path] = total
        return total

    def sizes(self):
        return {path: self.size(path) for path in self.nar}

    def coverage(self):
        return len(self.own) / max(1, len(self.nar))

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
                    effective[path] = max([self.used.get(path, self.registered[path])] + [effective.get(up, 0) for up in above])
                    continue
                stack.append((path, True))
                stack.extend((up, False) for up in above if up not in effective)
        return effective

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


def delete(paths):
    result = subprocess.run(["nix-store", "--delete", *paths], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    output = result.stdout + result.stderr
    match = FREED.search(output)
    deleted = int(match.group(1)) if match else 0
    freed = float(match.group(2)) * UNITS[match.group(3)] if match else 0
    return result.returncode == 0, deleted, freed, set(ALIVE.findall(output))


def delete_ordered(ordered, references):
    deleted = freed = 0
    refused = set()
    for start in range(0, len(ordered), DELETE_BATCH):
        batch = [path for path in ordered[start : start + DELETE_BATCH] if path not in refused]
        while batch:
            ok, count, size, alive = delete(batch)
            deleted += count
            freed += size
            if ok:
                break
            live = set()
            stack = list(alive) if alive else list(batch)
            while stack:
                path = stack.pop()
                if path in live:
                    continue
                live.add(path)
                stack.extend(references.get(path, ()))
            refused |= live
            batch = [path for path in batch if path not in live and os.path.exists(path)]
    return deleted, freed, refused


def deletion_plan(index, paths):
    ordered = index.order(index.dependents(paths))
    chosen = set(ordered)
    return ordered, {path: [ref for ref in index.references[path] if ref in chosen] for path in ordered}


def main():
    parser = argparse.ArgumentParser(prog="store-collect")
    parser.add_argument("--walk", type=float, default=0, help="measure unwalked store paths for this many seconds first")
    parser.add_argument("--path", action="append", default=[], help="print the exact size of this store path")
    options = parser.parse_args()
    index = Index().refresh()
    index.walk_pending(time.monotonic() + options.walk)
    index.scan_links()
    for path in options.path:
        print("%14.0f %s" % (index.size(path), path))
    print(json.dumps({
        "paths": len(index.nar),
        "walked": len(index.own),
        "pending": len(index.pending),
        "registered_bytes": index.registered_bytes(),
        "orphan_bytes": index.orphan_bytes,
        "orphans": index.orphan_count,
        "links_dir_bytes": index.links_blocks,
        "dead_paths": len(index.dead),
        "dead_bytes": round(sum(index.size(path) for path in index.dead)),
    }, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
