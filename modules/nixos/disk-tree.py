#!/usr/bin/env python3
# Per-directory size tree of one filesystem kept current from fanotify events, and last-open times of store paths.

import collections
import ctypes
import os
import select
import stat
import struct
import time

LIBC = ctypes.CDLL(None, use_errno=True)
LIBC.fanotify_mark.argtypes = [ctypes.c_int, ctypes.c_uint, ctypes.c_uint64, ctypes.c_int, ctypes.c_char_p]
FAN_NONBLOCK = 0x2
FAN_UNLIMITED_QUEUE = 0x10
FAN_REPORT_DFID_NAME = 0xC00
FAN_MARK_ADD = 0x1
FAN_MARK_FILESYSTEM = 0x100
FAN_MARK_MOUNT = 0x10
FAN_MARK_FLUSH = 0x80
FAN_MARK_IGNORED_SURV_MODIFY = 0x40
FAN_MARK_IGNORE = 0x400
FAN_OPEN = 0x20
FAN_OPEN_EXEC = 0x1000
FAN_EVENT_ON_CHILD = 0x08000000
FAN_MODIFY = 0x2
FAN_MOVED_FROM = 0x40
FAN_MOVED_TO = 0x80
FAN_CREATE = 0x100
FAN_DELETE = 0x200
FAN_Q_OVERFLOW = 0x4000
FAN_ONDIR = 0x40000000
WATCHED = FAN_MODIFY | FAN_MOVED_FROM | FAN_MOVED_TO | FAN_CREATE | FAN_DELETE | FAN_ONDIR
EVENT = struct.Struct("IBBHQii")
INFO = struct.Struct("BBH")
HANDLE = struct.Struct("Ii")
SETTLE = 0.05
COST_FACTOR = 20
NAMED = frozenset({".claude"})
STORE = "/nix/store/"


class Node:
    __slots__ = ("parent", "name", "ino", "children", "key", "dir_blocks", "files", "shared", "multi", "own", "total", "own_newest", "newest", "scanned", "cost", "attached", "acl")

    def __init__(self, parent, name, ino):
        self.parent = parent
        self.name = name
        self.ino = ino
        self.children = {}
        self.key = None
        self.dir_blocks = self.files = self.shared = self.own = self.total = 0
        self.multi = None
        self.own_newest = self.newest = 0
        self.scanned = 0.0
        self.cost = 0.0
        self.attached = True
        self.acl = False


def handle_key(path):
    buffer = ctypes.create_string_buffer(HANDLE.pack(128, 0), 136)
    mount = ctypes.c_int()
    if LIBC.name_to_handle_at(-100, path.encode(), buffer, ctypes.byref(mount), 0) < 0:
        return None
    size, kind = HANDLE.unpack_from(buffer)
    return struct.pack("i", kind) + buffer.raw[8 : 8 + size]


class Tree:
    def __init__(self, root, skip):
        self.skip = skip
        self.device = os.lstat(root).st_dev
        self.keys = {}
        self.holders = {}
        self.dirty = {}
        self.ring = collections.deque()
        self.overflowed = False
        self.named = {}
        self.last_event = 0.0
        self.events = 0
        self.scans = 0
        self.verified = 0
        self.pass_started = time.monotonic()
        self.pass_seconds = 0.0
        self.fd = LIBC.fanotify_init(FAN_UNLIMITED_QUEUE | FAN_REPORT_DFID_NAME | FAN_NONBLOCK, os.O_RDONLY)
        if self.fd < 0:
            raise OSError(ctypes.get_errno(), "fanotify_init")
        if LIBC.fanotify_mark(self.fd, FAN_MARK_ADD | FAN_MARK_FILESYSTEM, WATCHED, -100, root.encode()) < 0:
            raise OSError(ctypes.get_errno(), "fanotify_mark")
        self.root = Node(None, root, os.lstat(root).st_ino)
        started = time.monotonic()
        self.walk(self.root)
        self.walk_seconds = time.monotonic() - started

    def path(self, node):
        parts = []
        while node.parent is not None:
            parts.append(node.name)
            node = node.parent
        return os.path.join(node.name, *reversed(parts))

    def find(self, path):
        node = self.root
        relative = os.path.relpath(path, self.root.name)
        if relative == ".":
            return node
        for part in relative.split("/"):
            node = node.children.get(part)
            if node is None:
                return None
        return node

    def propagate(self, node, delta):
        while node is not None and delta:
            node.total += delta
            node = node.parent

    def raise_newest(self, node, newest):
        while node is not None and newest > node.newest:
            node.newest = newest
            node = node.parent

    def set_own(self, node):
        own = node.dir_blocks + node.files + node.shared
        delta = own - node.own
        node.own = own
        self.propagate(node, delta)

    def owned(self, node):
        if not node.multi:
            return 0
        return sum(blocks for ino, blocks in node.multi.items() if next(iter(self.holders[ino])) is node)

    def set_multi(self, node, multi):
        old = node.multi or {}
        touched = set()
        for ino in old.keys() - multi.keys():
            holders = self.holders[ino]
            first = next(iter(holders))
            del holders[node]
            if not holders:
                del self.holders[ino]
            elif first is node:
                touched.add(next(iter(holders)))
        for ino in multi.keys() - old.keys():
            self.holders.setdefault(ino, {})[node] = None
        node.multi = multi or None
        node.shared = self.owned(node)
        for other in touched:
            if not other.attached:
                continue
            other.shared = self.owned(other)
            self.set_own(other)

    def detach(self, node):
        self.propagate(node.parent, -node.total)
        subtree = [node]
        for current in subtree:
            current.attached = False
            subtree.extend(current.children.values())
        for current in subtree:
            if current.key is not None and self.keys.get(current.key) is current:
                del self.keys[current.key]
            if current.multi:
                self.set_multi(current, {})
            if current.name in NAMED:
                self.named.get(current.name, set()).discard(current)
            self.dirty.pop(current, None)

    def scan(self, node):
        started = time.monotonic()
        path = self.path(node)
        try:
            info = os.lstat(path)
            iterator = os.scandir(path)
        except OSError:
            if node.parent is not None and node.parent.attached:
                self.dirty.setdefault(node.parent, 0.0)
            return []
        if node.key is None:
            node.key = handle_key(path)
            if node.key is not None:
                self.keys[node.key] = node
        try:
            node.acl = "system.posix_acl_default" in os.listxattr(path)
        except OSError:
            node.acl = False
        files = 0
        newest = info.st_mtime
        multi = {}
        seen = set()
        new = []
        with iterator:
            for entry in iterator:
                name = entry.name
                if self.skip(path, name):
                    continue
                try:
                    entry_info = entry.stat(follow_symlinks=False)
                except OSError:
                    continue
                if entry_info.st_mtime > newest:
                    newest = entry_info.st_mtime
                if stat.S_ISDIR(entry_info.st_mode):
                    if entry_info.st_dev != self.device:
                        continue
                    seen.add(name)
                    child = node.children.get(name)
                    if child is not None and child.ino != entry_info.st_ino:
                        self.detach(node.children.pop(name))
                        child = None
                    if child is None:
                        child = Node(node, name, entry_info.st_ino)
                        node.children[name] = child
                        if name in NAMED:
                            self.named.setdefault(name, set()).add(child)
                        new.append(child)
                    continue
                blocks = entry_info.st_blocks * 512
                if entry_info.st_nlink > 1:
                    multi[entry_info.st_ino] = blocks
                else:
                    files += blocks
        for name in [name for name in node.children if name not in seen]:
            self.detach(node.children.pop(name))
        node.dir_blocks = info.st_blocks * 512
        node.files = files
        self.set_multi(node, multi)
        self.set_own(node)
        node.own_newest = int(newest)
        children_newest = max((child.newest for child in node.children.values()), default=0)
        node.newest = max(node.own_newest, children_newest)
        self.raise_newest(node.parent, node.newest)
        node.scanned = time.monotonic()
        node.cost = node.scanned - started
        self.scans += 1
        for child in new:
            self.ring.append(child)
        return new

    def walk(self, node):
        if node is self.root:
            self.ring.append(node)
        pending = [node]
        while pending:
            pending.extend(self.scan(pending.pop()))

    def wait(self, timeout, *others):
        select.select([self.fd, *others], [], [], timeout)

    def drain(self, unknown=None):
        now = time.monotonic()
        while True:
            try:
                data = os.read(self.fd, 1 << 20)
            except BlockingIOError:
                return
            offset = 0
            while offset < len(data):
                length, _, _, header, mask, _, _ = EVENT.unpack_from(data, offset)
                self.events += 1
                if mask & FAN_Q_OVERFLOW:
                    self.overflowed = True
                cursor = offset + header
                while cursor < offset + length:
                    _, _, size = INFO.unpack_from(data, cursor)
                    handle_bytes, kind = HANDLE.unpack_from(data, cursor + 12)
                    key = struct.pack("i", kind) + data[cursor + 20 : cursor + 20 + handle_bytes]
                    node = self.keys.get(key)
                    if node is not None:
                        if node not in self.dirty:
                            self.dirty[node] = now
                    elif unknown is not None:
                        unknown(key)
                    cursor += size
                offset += length
            self.last_event = now

    def mark(self, node):
        if node is not None and node.attached:
            self.dirty.setdefault(node, 0.0)

    def settle(self, deadline, force=False):
        if self.overflowed:
            self.overflowed = False
            for node in list(self.ring):
                self.mark(node)
        now = time.monotonic()
        ready = [node for node, since in self.dirty.items() if force or (now - since >= max(SETTLE, node.cost * COST_FACTOR) and now - node.scanned >= node.cost * COST_FACTOR)]
        for node in ready:
            if time.monotonic() > deadline:
                return
            self.dirty.pop(node, None)
            if node.attached:
                for child in self.scan(node):
                    self.walk(child)

    def verify(self, deadline):
        while self.ring and time.monotonic() < deadline:
            node = self.ring.popleft()
            if not node.attached:
                continue
            for child in self.scan(node):
                self.walk(child)
            self.ring.append(node)
            self.verified += 1
            if self.verified >= len(self.ring):
                self.pass_seconds = time.monotonic() - self.pass_started
                self.pass_started = time.monotonic()
                self.verified = 0

    def pending(self):
        return bool(self.dirty) or time.monotonic() - self.last_event < SETTLE

    def next_due(self):
        if not self.dirty:
            return None
        return min(max(since + max(SETTLE, node.cost * COST_FACTOR), node.scanned + node.cost * COST_FACTOR) for node, since in self.dirty.items())

    def size(self, path):
        node = self.find(path)
        if node is not None and node.attached:
            return node.total
        try:
            info = os.lstat(path)
        except OSError:
            return 0
        return info.st_blocks * 512 if info.st_dev == self.device and not stat.S_ISDIR(info.st_mode) else 0

    def newest(self, path):
        node = self.find(path)
        if node is not None and node.attached:
            return node.newest
        try:
            return int(os.lstat(path).st_mtime)
        except OSError:
            return 0

    def acl_dirs(self):
        found = []
        stack = [self.root]
        while stack:
            node = stack.pop()
            if node.acl:
                found.append(self.path(node))
            stack.extend(node.children.values())
        return found


def handle_buffer(key):
    kind = struct.unpack_from("i", key)[0]
    raw = key[4:]
    return ctypes.create_string_buffer(HANDLE.pack(len(raw), kind) + raw, 8 + len(raw))


class Resolver:
    def __init__(self, mount):
        self.mount = os.open(mount, os.O_RDONLY | os.O_DIRECTORY)
        self.cache = {}

    def open(self, key, flags=os.O_PATH):
        fd = LIBC.open_by_handle_at(self.mount, handle_buffer(key), flags)
        return fd if fd >= 0 else None

    def path(self, key):
        if key in self.cache:
            return self.cache[key]
        if len(self.cache) > 200000:
            self.cache.clear()
        fd = self.open(key)
        found = None
        if fd is not None:
            try:
                found = os.readlink(f"/proc/self/fd/{fd}")
            except OSError:
                found = None
            finally:
                os.close(fd)
        self.cache[key] = found
        return found


def store_path(path):
    if not path or not path.startswith(STORE):
        return None
    name = path[len(STORE):].split("/", 1)[0]
    return STORE + name if name and not name.startswith(".") else None


class Opens:
    def __init__(self, mount="/nix/store", flush_seconds=600):
        self.fd = LIBC.fanotify_init(FAN_REPORT_DFID_NAME | FAN_NONBLOCK, os.O_RDONLY)
        if self.fd < 0:
            raise OSError(ctypes.get_errno(), "fanotify_init")
        if LIBC.fanotify_mark(self.fd, FAN_MARK_ADD | FAN_MARK_MOUNT, FAN_OPEN | FAN_OPEN_EXEC, -100, mount.encode()) < 0:
            raise OSError(ctypes.get_errno(), "fanotify_mark")
        self.mount = mount
        self.resolver = Resolver(mount)
        self.root_key = handle_key(mount)
        self.flush_seconds = flush_seconds
        self.flushed = time.monotonic()
        self.ignoring = True
        self.events = 0
        self.ignored = 0
        self.pid = os.getpid()

    def ignore(self, key):
        if not self.ignoring:
            return
        fd = self.resolver.open(key, os.O_RDONLY | os.O_DIRECTORY)
        if fd is None:
            return
        try:
            if LIBC.fanotify_mark(self.fd, FAN_MARK_ADD | FAN_MARK_IGNORE | FAN_MARK_IGNORED_SURV_MODIFY, FAN_OPEN | FAN_OPEN_EXEC | FAN_EVENT_ON_CHILD, fd, None) < 0:
                self.ignoring = False
            else:
                self.ignored += 1
        finally:
            os.close(fd)

    def drain(self, touch):
        now = time.time()
        if time.monotonic() - self.flushed >= self.flush_seconds:
            LIBC.fanotify_mark(self.fd, FAN_MARK_FLUSH, 0, -100, self.mount.encode())
            self.resolver.cache.clear()
            self.flushed = time.monotonic()
            self.ignored = 0
        while True:
            try:
                data = os.read(self.fd, 1 << 20)
            except BlockingIOError:
                return
            offset = 0
            while offset < len(data):
                length, _, _, header, _, _, pid = EVENT.unpack_from(data, offset)
                self.events += 1
                cursor = offset + header
                if pid != self.pid and cursor < offset + length:
                    handle_bytes, kind = HANDLE.unpack_from(data, cursor + 12)
                    key = struct.pack("i", kind) + data[cursor + 20 : cursor + 20 + handle_bytes]
                    if key == self.root_key:
                        name = data[cursor + 20 + handle_bytes : offset + length].split(b"\0", 1)[0].decode(errors="replace")
                        touch(STORE + name, now)
                    else:
                        known = key in self.resolver.cache
                        found = store_path(self.resolver.path(key))
                        if found:
                            touch(found, now)
                            if not known:
                                self.ignore(key)
                offset += length
