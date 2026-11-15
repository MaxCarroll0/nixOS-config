#!/usr/bin/env python3
# Disk ledger and collector: every used byte of the root filesystem in one leaf, served live, reclaimed in one ranked order.

import collections
import ctypes
import glob
import hashlib
import importlib.util
import json
import os
import pwd
import re
import socket
import struct
import subprocess
import threading
import time
from pathlib import Path

GIB = 1024**3
MIB = 1024**2
DAY = 86400
MARGIN = 512 * MIB
RAMP = 4 * GIB
BURST = 1000
EMERGENCY_BURST = 4000
BURST_BYTES = GIB
PAUSE = 1.5
HISTORY_SECONDS = 900
HISTORY_LATE_SECONDS = 120
HISTORY_DAYS = 30
HISTORY_POINTS = 288
HISTORY_ITEMS = 40
PUSH_SECONDS = 0.1
FILE_SECONDS = 5
DB_SECONDS = 0.1
ROOTS_SECONDS = 60
MODEL_SECONDS = 60
MODEL_FLOOR = 1.0
SUMS_FLOOR = 0.5
FILES_FLOOR = 0.1
STORE_SETTLE = 1.0
LINKS_FLOOR = 5.0
HELD_SECONDS = 60
HELD_FLOOR = 5.0
INTERNALS_SECONDS = 3600
VERIFY_SECONDS = 0.01
COST_FACTOR = 20
ROWS = 400
EVENTS = 40

SEGMENTS = (
    ("running_system", "running system", "live", False),
    ("home_profile", "home profile", "live", False),
    ("profiles", "current user profiles", "live", False),
    ("previous", "previous generations", "live", False),
    ("shells", "live shells", "live", False),
    ("processes", "in use by processes", "live", False),
    ("roots", "other gc roots", "live", False),
    ("recent", "registered, roots pending", "live", False),
    ("building", "being built", "nix", False),
    ("metadata", "nix metadata", "nix", False),
    ("dead", "dead store paths", "reclaim", True),
    ("cache", "caches", "reclaim", True),
    ("temp", "leaked temp files", "reclaim", True),
    ("stale_shell", "stale shells", "reclaim", True),
    ("stray", "stray profiles", "reclaim", True),
    ("build", "build outputs", "reclaim", True),
    ("project", "project closures", "reclaim", True),
    ("deploy", "deployed to other hosts", "reclaim", True),
    ("generation", "older generations", "reclaim", True),
    ("agent", "agent work", "reclaim", True),
    ("home_files", "home files", "files", False),
    ("tmp_files", "live temp files", "files", False),
    ("system_files", "system files", "files", False),
    ("swap", "swapfile", "system", False),
    ("held", "deleted, still open", "system", False),
    ("filesystem", "filesystem internals", "system", False),
    ("changing", "not attributed", "system", False),
    ("reserved", "ext4 root reserve", "system", False),
)
SEGMENT_KEYS = [segment[0] for segment in SEGMENTS]
KIND_KEY = {"dead": "dead", "cache": "cache", "temp": "temp", "stale shell": "stale_shell", "stray profile": "stray", "build": "build", "project": "project", "deploy": "deploy", "generation": "generation", "agent": "agent"}
OLD_STAGES = {"scratch": "cache", "projects": "project", "store": "dead"}
CLASS_TEXT = {"running_system": "running system", "home_profile": "home profile", "profiles": "current profile", "previous": "kept for rollback", "shells": "live shell", "processes": "in use", "roots": "gc root"}
OLD_KEYS = {
    "system": "running_system", "home": "home_profile", "system_generations": "generation", "home_generations": "generation",
    "project_tier1": "project", "project_tier2": "project", "fetched": "project", "deployed": "deploy", "shells": "shells",
    "other": "roots", "garbage": "dead", "building": "building", "metadata": "metadata",
}


def load_module(name, variable):
    spec = importlib.util.spec_from_file_location(name, os.environ[variable])
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def blocks(path):
    try:
        return os.lstat(path).st_blocks * 512
    except OSError:
        return 0


def pressure(kind):
    try:
        with open(f"/proc/pressure/{kind}") as handle:
            return float(handle.readline().split("avg10=")[1].split()[0])
    except (OSError, IndexError, ValueError):
        return 0.0


def short(path, home):
    if path.startswith("/nix/store/"):
        return re.sub(r"^/nix/store/[a-z0-9]{32}-", "", path)
    return "~" + path[len(home):] if path.startswith(home + "/") else path


def family(name):
    return re.sub(r"\.(drv|patch|tar\.\w+|zip|lock)$", "", re.sub(r"-[0-9][^/]*$", "", name)) or name


LIBC = ctypes.CDLL(None, use_errno=True)
AT_SYMLINK_FOLLOW = 0x400
AT_HANDLE_CONNECTABLE = 0x002
FILEID_INO32_GEN = 1


def hypr_clients():
    clients = {}
    for path in glob.glob("/run/user/*/hypr/*/.socket.sock"):
        try:
            with socket.socket(socket.AF_UNIX) as conn:
                conn.settimeout(0.5)
                conn.connect(path)
                conn.sendall(b"j/clients")
                data = b""
                while chunk := conn.recv(65536):
                    data += chunk
            for client in json.loads(data):
                clients[client["pid"]] = client
        except (OSError, ValueError):
            continue
    return clients


def parent_pid(pid):
    try:
        with open(f"/proc/{pid}/stat") as handle:
            return int(handle.read().rsplit(")", 1)[1].split()[1])
    except (OSError, ValueError, IndexError):
        return 0


def shell_command(pid):
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as handle:
            args = handle.read().decode(errors="replace").split("\0")[:-1]
    except OSError:
        return ""
    if "--observed-command" in args:
        start = args.index("--observed-command")
        rest = args[start + 2:]
        if rest[:1] == ["--observed-real"]:
            rest = rest[2:]
        args = [args[start + 1]] + rest
    return " ".join(os.path.basename(arg) if index == 0 else arg for index, arg in enumerate(args))


def describe_shell(pid, home, clients):
    try:
        cwd = short(os.readlink(f"/proc/{pid}/cwd"), home)
    except OSError:
        cwd = ""
    window = None
    current = pid
    while current > 1 and window is None:
        window = clients.get(current)
        current = parent_pid(current)
    return shell_command(pid) or f"pid {pid}", cwd, window


def parents_within(path, stop):
    while len(path) > len(stop):
        path = os.path.dirname(path)
        yield path


def parent_dir(link, root_fd):
    buffer = ctypes.create_string_buffer(struct.pack("Ii", 128, 0), 136)
    mount = ctypes.c_int()
    if LIBC.name_to_handle_at(-100, link.encode(), buffer, ctypes.byref(mount), AT_SYMLINK_FOLLOW | AT_HANDLE_CONNECTABLE) < 0:
        return None
    size, _ = struct.unpack_from("Ii", buffer)
    words = struct.unpack_from(f"{size // 4}I", buffer, 8)
    if len(words) < 4:
        return None
    handle = ctypes.create_string_buffer(struct.pack("IiII", 8, FILEID_INO32_GEN, words[2], words[3]))
    fd = LIBC.open_by_handle_at(root_fd, handle, os.O_RDONLY | os.O_DIRECTORY)
    return fd if fd >= 0 else None


def dead_ancestors(link, root_fd):
    fd = parent_dir(link, root_fd)
    while fd is not None:
        info = os.fstat(fd)
        if info.st_nlink:
            os.close(fd)
            return
        yield os.readlink(f"/proc/self/fd/{fd}").removesuffix(" (deleted)"), info
        parent = os.open("..", os.O_RDONLY | os.O_DIRECTORY, dir_fd=fd)
        os.close(fd)
        fd = parent if parent != fd else None


def held_open(device):
    owners = {}
    root_fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    for how, pattern in (("open", "/proc/[0-9]*/fd/*"), ("mapped", "/proc/[0-9]*/map_files/*")):
        for link in glob.glob(pattern):
            try:
                target = os.readlink(link)
                if not target.endswith(" (deleted)"):
                    continue
                info = os.stat(link)
            except OSError:
                continue
            if info.st_dev != device or not os.path.stat.S_ISREG(info.st_mode):
                continue
            pid = link.split("/")[2]
            try:
                command = open(f"/proc/{pid}/comm").read().strip()
            except OSError:
                command = pid
            row = owners.setdefault(info.st_ino, {"path": target[: -len(" (deleted)")], "size": info.st_blocks * 512, "last_used": int(info.st_mtime), "how": how, "holders": set()})
            row["holders"].add(command)
            try:
                for path, directory in dead_ancestors(link, root_fd):
                    owners.setdefault(directory.st_ino, {"path": path, "size": directory.st_blocks * 512, "last_used": int(directory.st_mtime), "how": "as a parent", "holders": set()})["holders"].add(command)
            except OSError:
                pass
    os.close(root_fd)
    return sorted(({**row, "holders": sorted(row["holders"])} for row in owners.values() if row["size"]), key=lambda row: -row["size"])


def debugfs_stat(source, inode):
    out = subprocess.run(["debugfs", "-c", "-R", f"stat <{inode}>", source], capture_output=True, text=True).stdout
    found = re.search(r"Blockcount: (\d+)", out)
    return int(found.group(1)) * 512 if found else 0, out


def backup_groups(groups):
    found = {0, 1}
    for base in (3, 5, 7):
        power = base
        while power < groups:
            found.add(power)
            power *= base
    return len({group for group in found if group < groups})


def root_source(root):
    return subprocess.run(["findmnt", "-no", "SOURCE", root], capture_output=True, text=True).stdout.strip().split("[")[0]


def hidden_inodes(source):
    header = subprocess.run(["dumpe2fs", "-h", source], capture_output=True, text=True).stdout
    field = lambda name: int(re.search(rf"^{name}:\s+(\d+)", header, re.M).group(1))
    block = field("Block size")
    groups = -(-field("Block count") // field("Blocks per group"))
    rows = []
    for inode, label in ((3, "user quota"), (4, "group quota"), (12, "orphan file")):
        rows.append((label, debugfs_stat(source, inode)[0]))
    resize, _ = debugfs_stat(source, 7)
    rows.append(("resize index", max(0, resize - field("Reserved GDT blocks") * backup_groups(groups) * block)))
    journal, out = debugfs_stat(source, 8)
    size = re.search(r"Size: (\d+)", out)
    rows.append(("journal index", max(0, journal - int(size.group(1))) if size else 0))
    return [row for row in rows if row[1]]


def covered_mountpoints(root):
    device = os.lstat(root).st_dev
    targets = set()
    with open("/proc/self/mountinfo") as handle:
        for line in handle:
            target = line.split()[4].encode().decode("unicode_escape")
            if target == root:
                continue
            try:
                if os.lstat(target).st_dev != device and os.lstat(os.path.dirname(target)).st_dev == device:
                    targets.add(target)
            except OSError:
                continue
    return sorted(targets)


def shared_xattr_blocks(dirs, source, block_size):
    candidates = {}
    for directory in dirs:
        try:
            names = os.listdir(directory)
            for name in (".", *names):
                info = os.lstat(os.path.join(directory, name))
                if not os.path.stat.S_ISDIR(info.st_mode) or name == ".":
                    candidates[info.st_ino] = directory
        except OSError:
            continue
    if not candidates:
        return {}
    commands = "".join(f"stat <{inode}>\n" for inode in candidates)
    out = subprocess.run(["debugfs", "-c", "-f", "/dev/stdin", source], input=commands, capture_output=True, text=True).stdout
    sharers = {}
    for inode, block in re.findall(r"^Inode: (\d+).*?File ACL: (\d+)", out, re.M | re.S):
        if block != "0":
            sharers.setdefault(block, []).append(int(inode))
    extra = {}
    for inodes in sharers.values():
        for inode in inodes[1:]:
            extra[candidates[inode]] = extra.get(candidates[inode], 0) + block_size
    return extra


def write_file(path, text, owner):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(text)
    if owner is not None:
        os.chown(temporary, owner, -1)
    temporary.replace(path)


def downsample(points):
    if len(points) <= HISTORY_POINTS:
        return points
    step = len(points) / HISTORY_POINTS
    return [points[int(index * step)] for index in range(HISTORY_POINTS)] + points[-1:]


def migrate(point, total):
    if point.get("v") == 2:
        return point
    store = point.get("store_disk") or point.get("store") or {}
    files = point.get("files") or {}
    segments = collections.Counter()
    for key, value in store.items():
        if key in OLD_KEYS:
            segments[OLD_KEYS[key]] += value
    loose = sum(store.get(key, 0) for key in ("rescan",)) + max(0, point.get("measuring", 0)) + point.get("unaccounted", 0)
    if abs(loose) >= 64 * MIB or "swap" not in point or "reserved" not in point:
        return None
    segments["changing"] += max(0, loose)
    if isinstance(files, dict):
        segments["home_files"] += files.get("home", 0)
        segments["cache"] += files.get("caches", 0)
    segments["swap"] += point.get("swap", 0)
    segments["system_files"] += point.get("system", 0)
    segments["held"] += point.get("held", 0)
    segments["reserved"] += point.get("reserved", 0)
    closes = sum(segments.values()) + point.get("free", 0)
    if abs(closes - total) > 64 * MIB:
        return None
    return {"v": 2, "at": point["at"], "segments": dict(segments), "free": point.get("free", 0), "total": total, "migrated": True}


class Client:
    def __init__(self, connection):
        self.connection = connection
        self.buffer = b""
        self.watches = []
        self.sent = {}


class Ledger:
    def __init__(self):
        self.state = Path(os.environ["LEDGER_STATE_DIR"])
        self.state.mkdir(parents=True, exist_ok=True)
        self.home = os.environ["LEDGER_HOME"]
        self.user = os.environ["LEDGER_USER"]
        self.owner = int(os.environ["LEDGER_UID"])
        self.runtime = Path(os.environ["LEDGER_RUNTIME_DIR"])
        self.textfile = Path(os.environ["LEDGER_TEXTFILE"])
        self.server = self.listen()
        self.floor = int(os.environ["LEDGER_TARGET_BYTES"])
        self.target_file = os.environ.get("LEDGER_TARGET_FILE", "")
        self.emergency = int(os.environ.get("LEDGER_EMERGENCY_BYTES", 5 * GIB))
        self.collecting = os.environ.get("LEDGER_COLLECT") == "1"
        self.collector = load_module("collector", "COLLECT_MODULE")
        self.reclaim = load_module("reclaim", "RECLAIM_MODULE")
        tree_module = load_module("tree", "TREE_MODULE")
        retention = load_module("retention", "RETENTION_MODULE")
        started = time.monotonic()
        self.index = self.collector.Index()
        self.index.load()
        self.index.refresh_roots()
        self.tree = tree_module.Tree("/", self.skip)
        self.store_node = self.tree.find("/nix/store")
        self.resolver = tree_module.Resolver("/")
        self.store_path = tree_module.store_path
        try:
            self.opens = tree_module.Opens()
        except OSError:
            self.opens = None
        self.index.walk_pending(float("inf"))
        self.index.scan_links()
        self.device = os.stat("/").st_dev
        self.source = root_source("/")
        offload = os.environ.get("LEDGER_OFFLOAD_DIR") or None
        self.builds = self.reclaim.BuildTimes(store=str(self.state / "build-times.json"))
        self.builds.watch()
        self.model = self.reclaim.Model(self.index, self.home, self.user, retention, self.index.size, self.tree.size, self.tree.newest, offload=offload, worktrees=self.worktrees, builds=self.builds)
        self.model_cost = self.timed(self.model.refresh)
        self.by_path = {}
        self.index_items()
        self.startup_seconds = time.monotonic() - started
        self.clients = {}
        self.wake_read, self.wake_write = os.pipe()
        os.set_blocking(self.wake_read, False)
        self.worker = None
        self.result = None
        self.status = {"state": "idle"}
        self.last_event = None
        self.paused_until = 0.0
        self.store_dirty = {}
        self.links_dirty = None
        self.links_cost = 0.0
        self.db_checked = 0.0
        self.roots_at = time.monotonic()
        self.roots_due = None
        self.roots_cost = 0.0
        self.model_at = time.monotonic()
        self.model_dirty = False
        self.sums_dirty = True
        self.sums_at = 0.0
        self.sums_cost = 0.0
        self.sums = {}
        self.files_at = 0.0
        self.files_cost = 0.0
        self.files_total = None
        self.verified_at = 0.0
        self.held = []
        self.held_at = -HELD_SECONDS
        self.internals = hidden_inodes(self.source)
        self.internals_at = time.monotonic()
        self.xattr = {}
        self.xattr_dirs = None
        self.xattr_at = -INTERNALS_SECONDS
        self.overview = None
        self.version = 0
        self.pushed = 0.0
        self.pushed_version = -1
        self.written_at = 0.0
        self.written_version = -1
        self.residual_log = []
        self.history_path = self.state / "history.jsonl"
        self.points = self.load_history()
        self.history_version = 0
        self.events = self.load_events()
        self.target_mtime = None
        self.target_bytes = self.floor

    def timed(self, function):
        started = time.monotonic()
        function()
        return time.monotonic() - started

    def skip(self, parent, name):
        return parent == "/nix/store" and (name == ".links" or "/nix/store/" + name in self.index.nar)

    def worktrees(self):
        found = []
        for node in list(self.tree.named.get(".claude", ())):
            if not node.attached:
                continue
            holder = node.children.get("worktrees")
            if holder is not None:
                found.extend(self.tree.path(child) for child in holder.children.values())
        return found

    def index_items(self):
        self.by_path = {item.path: item for item in self.model.items}
        self.kind_items = collections.defaultdict(list)
        for item in self.model.items:
            self.kind_items[KIND_KEY[item.kind]].append(item)
        self.claim_of = {}
        for name, link, found, _ in self.model.protected_claims:
            for path in found:
                self.claim_of[path] = ("claim", link)
        for item in self.model.items:
            for path in item.store:
                self.claim_of[path] = ("item", item.path)
        self.claim_sets = {}
        self.sums_dirty = True

    def unknown(self, key):
        path = self.resolver.path(key)
        if not path:
            return
        if path.startswith("/nix/store/.links"):
            if self.links_dirty is None:
                self.links_dirty = time.monotonic()
            return
        found = self.store_path(path)
        if found in self.index.nar and found not in self.store_dirty:
            self.store_dirty[found] = time.monotonic()

    def touch(self, path, when):
        self.index.touch(path, when)

    def listen(self):
        path = self.runtime / "disk-tree.sock"
        path.unlink(missing_ok=True)
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(str(path))
        os.chown(path, self.owner, -1)
        os.chmod(path, 0o600)
        server.listen(64)
        server.setblocking(False)
        return server

    def target(self):
        if self.target_file:
            try:
                mtime = os.stat(self.target_file).st_mtime_ns
                if mtime != self.target_mtime:
                    self.target_mtime = mtime
                    self.target_bytes = int(float(Path(self.target_file).read_text().strip()) * GIB)
                    self.version += 1
            except (OSError, ValueError):
                self.target_bytes = self.floor
        return self.target_bytes

    def statfs(self):
        info = os.statvfs("/")
        total = info.f_blocks * info.f_frsize
        free = info.f_bavail * info.f_frsize
        used = (info.f_blocks - info.f_bfree) * info.f_frsize
        return total, used, free, total - used - free

    def load_history(self):
        total = self.statfs()[0]
        points = []
        changed = False
        now = time.time()
        if self.history_path.exists():
            for line in self.history_path.read_text().splitlines():
                try:
                    point = json.loads(line)
                except ValueError:
                    changed = True
                    continue
                if point.get("at", 0) < now - HISTORY_DAYS * DAY:
                    changed = True
                    continue
                migrated = migrate(point, total)
                if migrated is not point:
                    changed = True
                if migrated is not None:
                    points.append(migrated)
        if changed:
            self.save_history(points)
        return points

    def save_history(self, points):
        write_file(self.history_path, "".join(json.dumps(point, separators=(",", ":")) + "\n" for point in points), None)

    def load_events(self):
        path = self.state / "events.jsonl"
        if not path.exists():
            return []
        events = []
        for line in path.read_text().splitlines()[-EVENTS:]:
            try:
                event = json.loads(line)
            except ValueError:
                continue
            event.setdefault("segment", OLD_STAGES.get(event.get("stage"), KIND_KEY.get(event.get("stage"), "dead")))
            events.append(event)
        return events

    def record(self, event):
        with open(self.state / "events.jsonl", "a") as handle:
            handle.write(json.dumps(event, separators=(",", ":")) + "\n")
        self.events = (self.events + [event])[-EVENTS:]
        self.last_event = event
        self.version += 1

    def store_sums(self):
        size = self.index.size
        sums = collections.Counter()
        claimed = set()
        for name, link, found, _ in self.model.protected_claims:
            sums[name] += sum(size(path) for path in found)
            claimed.update(found)
        for item in self.model.items:
            item.store_bytes = sum(size(path) for path in item.store)
            sums[KIND_KEY[item.kind]] += item.store_bytes
            claimed.update(item.store)
        sums["recent"] = sum(size(path) for path in self.index.nar if path not in claimed)
        sums["dead"] += self.index.orphan_bytes
        self.sums = sums
        self.version += 1

    def file_parts(self):
        tree = self.tree
        root = tree.root
        nix = tree.find("/nix")
        home = tree.find("/home")
        tmp = tree.find("/tmp")
        swap = blocks("/swapfile")
        kinds = collections.Counter()
        under = collections.Counter()
        for item in self.model.file_items:
            if not item.file_bytes:
                continue
            kinds[KIND_KEY[item.kind]] += item.file_bytes
            top = "/" + item.path.split("/", 2)[1]
            under[top] += item.file_bytes
        extra = sum(self.xattr.values())
        extra_home = sum(value for path, value in self.xattr.items() if path.startswith("/home/"))
        extra_tmp = sum(value for path, value in self.xattr.items() if path.startswith("/tmp/"))
        home_total = home.total if home else 0
        tmp_total = tmp.total if tmp else 0
        nix_total = nix.total if nix else 0
        mounts = covered_mountpoints("/")
        parts = {
            "home_files": home_total - under["/home"] - extra_home,
            "tmp_files": tmp_total - under["/tmp"] - extra_tmp,
            "system_files": root.total - nix_total - home_total - tmp_total - swap - sum(value for key, value in under.items() if key not in ("/home", "/tmp")) - (extra - extra_home - extra_tmp),
            "swap": swap,
            "building": self.store_node.total - self.store_node.dir_blocks,
            "metadata": nix_total - self.store_node.total + self.store_node.dir_blocks + self.index.links_blocks,
            "filesystem": sum(value for _, value in self.internals) + 4096 * len(mounts),
        }
        self.mounts = mounts
        return parts, kinds

    def compose(self):
        total, used, free, reserved = self.statfs()
        parts, file_kinds = self.file_parts()
        segments = collections.Counter()
        for key, value in self.sums.items():
            segments[key] += value
        for key, value in file_kinds.items():
            segments[key] += value
        for key, value in parts.items():
            segments[key] += value
        segments["held"] = sum(row["size"] for row in self.held)
        residual = used - sum(segments.values())
        if residual and self.tree.dirty:
            target = self.dirty_segment()
            moved = max(residual, -segments[target])
            segments[target] += moved
            residual -= moved
        segments["changing"] = residual
        segments["reserved"] = reserved
        return total, used, free, reserved, segments, residual

    def dirty_segment(self):
        newest = max(self.tree.dirty.items(), key=lambda pair: pair[1])[0]
        path = self.tree.path(newest)
        if path.startswith("/home/"):
            return "home_files"
        if path.startswith("/tmp/"):
            return "tmp_files"
        if path.startswith("/nix/store"):
            return "building"
        if path.startswith("/nix/"):
            return "metadata"
        return "system_files"

    def cut(self, deficit):
        if deficit <= 0:
            return -1
        cumulative = 0
        for item in self.model.items:
            cumulative += item.freed
            if cumulative >= deficit:
                return item.rank
        return len(self.model.items) - 1

    def build_overview(self):
        total, used, free, reserved, segments, residual = self.compose()
        target = self.target()
        deficit = max(0, target + MARGIN - free)
        cut = self.cut(deficit)
        scheduled = collections.Counter()
        reclaimable = collections.Counter()
        for item in self.model.items:
            key = KIND_KEY[item.kind]
            reclaimable[key] += item.freed
            if item.rank <= cut:
                scheduled[key] += item.freed
        rows = []
        for key, label, group, can in SEGMENTS:
            value = segments.get(key, 0)
            rows.append({"key": key, "label": label, "group": group, "reclaimable": can, "bytes": value, "scheduled": scheduled.get(key, 0), "items": len(self.kind_items.get(key, ())) if can else 0})
        self.cut_rank = cut
        head = self.model.items[0] if self.model.items else None
        return {
            "next": {"path": head.path, "label": short(head.path, self.home), "kind": KIND_KEY[head.kind], "size": head.freed, "last_used": head.last_used} if head else None,
            "disk": {"total": total, "used": used, "free": free, "reserved": reserved},
            "free": free,
            "target": target,
            "deficit": deficit,
            "cut": cut,
            "reclaimable": sum(reclaimable.values()),
            "segments": rows,
            "residual": residual,
            "gc": self.status,
        }

    def tracker(self):
        return {
            "at": int(time.time()),
            "dirty": len(self.tree.dirty),
            "directories": len(self.tree.keys),
            "events": self.tree.events,
            "opens": self.opens.events if self.opens else 0,
            "store_paths": len(self.index.nar),
            "walked": len(self.index.own),
            "items": len(self.model.items),
            "model_seconds": round(self.model_cost, 3),
            "roots_seconds": round(self.roots_cost, 3),
            "sums_seconds": round(self.sums_cost, 3),
            "files_seconds": round(self.files_cost, 4),
            "startup_seconds": round(self.startup_seconds, 1),
            "walk_seconds": round(self.tree.walk_seconds, 1),
            "verify_pass_seconds": round(self.tree.pass_seconds, 1),
        }

    def item_kind_text(self, item):
        detail = item.detail
        if item.kind in ("generation", "stray profile"):
            return f"{os.path.basename(detail.get('profile', ''))} generation {detail.get('number')}, replaced {time.strftime('%Y-%m-%d %H:%M', time.localtime(item.last_used))}"
        if item.kind == "agent" and detail.get("worktree"):
            state = "merged" if detail.get("merged") else "unmerged"
            dirty = f", {detail['dirty']} uncommitted" if detail.get("dirty") else ""
            return f"agent worktree, {state}{dirty}"
        if item.kind == "build":
            return f"build output of {short(detail.get('project', ''), self.home)}" if detail.get("project") else "offloaded build output"
        if item.kind == "agent" and detail.get("session"):
            return "scratch of an ended agent session"
        if item.kind == "project":
            return f"project roots: {len(detail.get('roots', []))}"
        if item.kind == "stale shell":
            return f"shell roots of exited pid {detail.get('pid')}"
        return item.kind

    def item_row(self, item):
        return {
            "id": f"item:{item.path}",
            "label": short(item.path, self.home),
            "path": item.path,
            "size": item.freed,
            "store": item.store_bytes,
            "files": item.file_bytes,
            "last_used": item.last_used,
            "kind": self.item_kind_text(item) + rebuild_text(item.build),
            "build": item.build,
            "reclaimable": True,
            "rank": item.rank,
            "scheduled": item.rank <= self.cut_rank,
            "delvable": bool(item.store) or bool(item.files),
            "openable": bool(item.files) and not item.path.startswith("/nix/store/"),
            "roots": item.links[:6],
        }

    def day_items(self, key, day):
        return [item for item in self.kind_items.get(key, []) if time.strftime("%Y-%m-%d", time.localtime(item.last_used)) == day]

    def item_family_rows(self, owner_id, items):
        families = collections.defaultdict(list)
        for item in items:
            families[family(short(item.path, self.home))].append(item)
        rows = []
        for name, members in families.items():
            if len(members) < 3:
                rows.extend(self.item_row(item) for item in members)
                continue
            ranks = [item.rank for item in members]
            build = sum(item.build for item in members)
            rows.append({"id": f"items:{owner_id}:{name}", "label": f"{name} ×{len(members)}", "path": "", "size": sum(item.freed for item in members), "last_used": max(item.last_used for item in members), "kind": f"{len(members)} {members[0].kind} items, ranks {min(ranks)}–{max(ranks)}" + rebuild_text(build), "build": build, "reclaimable": True, "scheduled": min(ranks) <= self.cut_rank, "delvable": True, "openable": False})
        return rows

    def path_rows(self, paths, owner_id, reclaimable, scheduled):
        size = self.index.size
        families = collections.defaultdict(list)
        for path in paths:
            families[family(short(path, self.home))].append(path)
        rows = []
        for name, members in families.items():
            if len(members) >= 3:
                rows.append({"id": f"family:{owner_id}:{name}", "label": f"{name} ×{len(members)}", "path": "", "size": sum(size(path) for path in members), "last_used": max(self.index.used.get(path, 0) for path in members), "kind": f"{len(members)} store paths", "reclaimable": reclaimable, "scheduled": scheduled, "delvable": True, "openable": False})
            else:
                rows.extend(self.store_row(path, reclaimable, scheduled) for path in members)
        return rows

    def store_row(self, path, reclaimable, scheduled):
        return {"id": f"store:{path}", "label": short(path, self.home), "path": path, "size": self.index.size(path), "last_used": self.index.used.get(path, 0), "kind": "store path", "reclaimable": reclaimable, "scheduled": scheduled, "delvable": bool(self.index.references.get(path)), "openable": False}

    def claim_set(self, owner):
        if owner not in self.claim_sets:
            kind, key = owner
            if kind == "claim":
                found = self.claim_members(key)
            else:
                item = self.by_path.get(key)
                found = item.store if item else []
            self.claim_sets[owner] = set(found)
        return self.claim_sets[owner]

    def claim_members(self, key):
        found = set()
        for _, link, paths, _ in self.model.protected_claims:
            if link == key or link.startswith(key + "/"):
                found.update(paths)
        return list(found)

    def members(self, owner_id):
        if owner_id.startswith("claim:"):
            return self.claim_members(owner_id[6:])
        if owner_id.startswith("item:"):
            item = self.by_path.get(owner_id[5:])
            return item.store if item else []
        if owner_id == "segment:recent":
            claimed = self.model.live
            return [path for path in self.index.nar if path not in claimed]
        return []

    def dir_rows(self, path, context):
        node = self.tree.find(path)
        if node is None or not node.attached:
            return []
        claimed = [file for item in self.model.file_items if item.file_bytes for file in item.files] if context == "files" else []
        prefix = path.rstrip("/") + "/"
        buckets = collections.defaultdict(set)
        for file in claimed:
            if file.startswith(prefix):
                buckets[file[len(prefix):].split("/", 1)[0]].add(file)
        rows = []
        for name, child in node.children.items():
            child_path = prefix + name
            if child is self.store_node and context == "files":
                continue
            inside = buckets.get(name, set())
            if child_path in inside:
                continue
            top = [file for file in inside if not any(ancestor in inside for ancestor in parents_within(file, child_path))]
            size = child.total - sum(self.tree.size(file) for file in top)
            if size <= 0:
                continue
            rows.append({"id": f"dir:{context}:{child_path}", "label": name, "path": child_path, "size": size, "last_used": child.newest, "kind": "directory", "reclaimable": context == "item", "scheduled": False, "delvable": True, "openable": True})
        loose = node.own - (blocks("/swapfile") if path == "/" else 0)
        loose -= sum(self.tree.size(file) for file in claimed if os.path.dirname(file) == path.rstrip("/") and self.tree.find(file) is None)
        if loose > 0:
            rows.append({"id": f"loose:{path}", "label": "files", "path": path.rstrip("/") + "/*", "size": loose, "last_used": node.own_newest, "kind": "files directly here", "reclaimable": context == "item", "scheduled": False, "delvable": False, "openable": False})
        return rows

    def segment_rows(self, key):
        if key == "shells":
            groups = collections.defaultdict(list)
            for name, link, found, _ in self.model.protected_claims:
                if name == key:
                    groups[os.path.dirname(link)].append(found)
            clients = hypr_clients()
            rows = []
            for directory, founds in groups.items():
                paths = set().union(*founds)
                size = sum(self.index.size(path) for path in paths)
                if not size:
                    continue
                pid = int(os.path.basename(directory)) if os.path.basename(directory).isdigit() else 0
                command, cwd, window = describe_shell(pid, self.home, clients)
                place = f"{window['class']}: {window['title']}" if window else "no window"
                row = {"id": f"claim:{directory}", "label": f"{command} in {cwd}" if cwd else command, "path": directory, "size": size, "last_used": int(self.reclaim.lstat_time(directory)), "kind": f"live shell {pid}, {place}", "reclaimable": False, "scheduled": False, "delvable": True, "openable": False, "roots": sorted(glob.glob(directory + "/*"))}
                if window:
                    row["pid"] = window["pid"]
                rows.append(row)
            return rows
        if key in CLASS_TEXT:
            rows = []
            for name, link, found, _ in self.model.protected_claims:
                if name != key:
                    continue
                size = sum(self.index.size(path) for path in found)
                if not size:
                    continue
                label = short(link, self.home)
                match = re.match(r"^/proc/(\d+)/", link)
                if match:
                    try:
                        label = f"pid {match.group(1)} {open(f'/proc/{match.group(1)}/comm').read().strip()}"
                    except OSError:
                        label = f"pid {match.group(1)} (exited)"
                rows.append({"id": f"claim:{link}", "label": label, "path": link, "size": size, "last_used": int(self.reclaim.lstat_time(link)) if link.startswith("/") and not link.startswith("/proc/") else 0, "kind": f"{CLASS_TEXT[name]}: {self.model.protected.get(link, 'root')}", "reclaimable": False, "scheduled": False, "delvable": True, "openable": False, "roots": [link]})
            return rows
        if key == "recent":
            return self.path_rows(self.members("segment:recent"), "segment:recent", False, False)
        if key == "building":
            return self.dir_rows("/nix/store", "store")
        if key == "metadata":
            rows = self.dir_rows("/nix", "files")
            rows.append({"id": "meta:links", "label": "link table directory", "path": "/nix/store/.links", "size": self.index.links_blocks, "last_used": 0, "kind": f"directory entries for {len(self.index.holders)} shared files", "reclaimable": False, "scheduled": False, "delvable": False, "openable": False})
            rows.append({"id": "meta:store", "label": "store directory", "path": "/nix/store", "size": self.store_node.dir_blocks, "last_used": 0, "kind": f"directory entries for {len(self.index.nar)} paths", "reclaimable": False, "scheduled": False, "delvable": False, "openable": False})
            return rows
        if key in KIND_KEY.values():
            items = self.kind_items.get(key, [])
            rows = []
            if key == "dead" and self.index.orphan_bytes:
                rows.append({"id": "meta:orphans", "label": "unused link table entries", "path": "/nix/store/.links", "size": self.index.orphan_bytes, "last_used": 0, "kind": f"{self.index.orphan_count} files freed with the next deletion", "reclaimable": True, "scheduled": self.cut_rank >= 0, "delvable": False, "openable": False})
            if len(items) > ROWS:
                days = collections.OrderedDict()
                for item in items:
                    day = time.strftime("%Y-%m-%d", time.localtime(item.last_used))
                    days.setdefault(day, []).append(item)
                for day, members in days.items():
                    rows.append({"id": f"day:{key}:{day}", "label": day, "path": "", "size": sum(item.freed for item in members), "last_used": max(item.last_used for item in members), "kind": f"{len(members)} {key} items, ranks {members[0].rank}–{members[-1].rank}", "reclaimable": True, "scheduled": members[0].rank <= self.cut_rank, "delvable": True, "openable": False})
                return rows
            return rows + [self.item_row(item) for item in items]
        if key == "home_files":
            return self.dir_rows("/home", "files")
        if key == "tmp_files":
            return self.dir_rows("/tmp", "files")
        if key == "system_files":
            return [row for row in self.dir_rows("/", "files") if row["path"] not in ("/nix", "/home", "/tmp")]
        if key == "swap":
            return [{"id": "swap", "label": "/swapfile", "path": "/swapfile", "size": blocks("/swapfile"), "last_used": 0, "kind": "swap", "reclaimable": False, "scheduled": False, "delvable": False, "openable": False}]
        if key == "held":
            return [{"id": f"held:{row['path']}", "label": short(row["path"], self.home), "path": row["path"], "size": row["size"], "last_used": row["last_used"], "kind": f"deleted, still {row['how']} by {', '.join(row['holders'])}", "reclaimable": False, "scheduled": False, "delvable": False, "openable": False} for row in self.held]
        if key == "filesystem":
            rows = [{"id": f"fs:{label}", "label": label, "path": "", "size": value, "last_used": 0, "kind": "ext4 internal inode", "reclaimable": False, "scheduled": False, "delvable": False, "openable": False} for label, value in self.internals]
            rows.append({"id": "fs:mounts", "label": "mountpoints", "path": "", "size": 4096 * len(self.mounts), "last_used": 0, "kind": f"directories under {len(self.mounts)} mounts", "reclaimable": False, "scheduled": False, "delvable": False, "openable": False})
            return rows
        if key == "changing":
            return [{"id": f"dir:files:{self.tree.path(node)}", "label": short(self.tree.path(node), self.home), "path": self.tree.path(node), "size": node.total, "last_used": node.newest, "kind": "changed, rescan pending", "reclaimable": False, "scheduled": False, "delvable": True, "openable": True} for node in list(self.tree.dirty)[:ROWS]]
        return []

    def closure_rows(self, path):
        owner = self.claim_of.get(path)
        scope = self.claim_set(owner) if owner else {path}
        reclaimable = bool(owner and owner[0] == "item")
        item = self.by_path.get(owner[1]) if reclaimable else None
        scheduled = bool(item and item.rank <= self.cut_rank)
        assigned = {path}
        rows = [{**self.store_row(path, reclaimable, scheduled), "id": f"self:{path}", "label": f"{short(path, self.home)} itself", "delvable": False}]
        for reference in sorted(self.index.references.get(path, ())):
            if reference not in scope or reference in assigned:
                continue
            stack = [reference]
            group = []
            while stack:
                current = stack.pop()
                if current in assigned or current not in scope:
                    continue
                assigned.add(current)
                group.append(current)
                stack.extend(self.index.references.get(current, ()))
            rows.append({**self.store_row(reference, reclaimable, scheduled), "size": sum(self.index.size(member) for member in group), "kind": f"{len(group)} paths only reachable through it" if len(group) > 1 else "store path"})
        return rows

    def rows(self, node_id):
        kind, _, rest = node_id.partition(":")
        if kind == "segment":
            return self.segment_rows(rest)
        if kind == "item":
            item = self.by_path.get(rest)
            if item is None:
                return [{"missing": True}]
            scheduled = item.rank <= self.cut_rank
            rows = self.path_rows(item.store, node_id, True, scheduled)
            for path in item.files:
                node = self.tree.find(path)
                if node is not None:
                    rows.extend({**row, "scheduled": scheduled} for row in self.dir_rows(path, "item"))
                else:
                    rows.append({"id": f"file:{path}", "label": short(path, self.home), "path": path, "size": self.tree.size(path), "last_used": self.tree.newest(path), "kind": "file", "reclaimable": True, "scheduled": scheduled, "delvable": False, "openable": True})
            return rows
        if kind == "claim":
            return self.path_rows(self.members(node_id), node_id, False, False)
        if kind == "family":
            owner_id, _, name = rest.rpartition(":")
            members = [path for path in self.members(owner_id) if family(short(path, self.home)) == name]
            reclaimable = owner_id.startswith("item:")
            item = self.by_path.get(owner_id[5:]) if reclaimable else None
            scheduled = bool(item and item.rank <= self.cut_rank)
            return [self.store_row(path, reclaimable, scheduled) for path in members]
        if kind == "store":
            return self.closure_rows(rest)
        if kind == "day":
            key, _, day = rest.partition(":")
            return self.item_family_rows(node_id, self.day_items(key, day))
        if kind == "items":
            owner_id, _, name = rest.rpartition(":")
            _, key, day = owner_id.split(":", 2)
            return [self.item_row(item) for item in self.day_items(key, day) if family(short(item.path, self.home)) == name]
        if kind == "dir":
            context, _, path = rest.partition(":")
            return self.dir_rows(path, context)
        return [{"missing": True}]

    def payload(self, node_id):
        if node_id == "overview":
            return self.overview
        if node_id == "history":
            return {"points": downsample(self.points), "items": self.history_items}
        if node_id == "events":
            return self.events
        if node_id == "tracker":
            return self.tracker()
        try:
            return sorted(self.rows(node_id), key=lambda row: -row.get("size", 0))
        except Exception as error:
            return [{"missing": True, "error": str(error)}]

    def accept(self):
        while True:
            try:
                connection, _ = self.server.accept()
            except BlockingIOError:
                return
            connection.setblocking(False)
            self.clients[connection] = Client(connection)

    def drop(self, client):
        self.clients.pop(client.connection, None)
        try:
            client.connection.close()
        except OSError:
            pass

    def receive(self, client):
        try:
            data = client.connection.recv(65536)
        except BlockingIOError:
            return
        except OSError:
            data = b""
        if not data:
            self.drop(client)
            return
        client.buffer += data
        while b"\n" in client.buffer:
            line, client.buffer = client.buffer.split(b"\n", 1)
            try:
                request = json.loads(line)
            except ValueError:
                request = {"watch": [line.decode(errors="replace").strip()]}
            if isinstance(request, dict) and isinstance(request.get("watch"), list):
                client.watches = [str(entry) for entry in request["watch"]][:16]
                client.sent = {key: value for key, value in client.sent.items() if key in client.watches}
                self.push(client, force=True)

    def send(self, client, node_id, data):
        text = json.dumps({"id": node_id, "data": data}, separators=(",", ":"))
        digest = hashlib.blake2b(text.encode(), digest_size=16).digest()
        if client.sent.get(node_id) == digest:
            return True
        try:
            client.connection.setblocking(True)
            client.connection.settimeout(0.5)
            client.connection.sendall(text.encode() + b"\n")
            client.connection.setblocking(False)
        except OSError:
            self.drop(client)
            return False
        client.sent[node_id] = digest
        return True

    def push(self, client, force=False):
        cache = {}
        for node_id in list(client.watches):
            if node_id not in cache:
                cache[node_id] = self.payload(node_id)
            if not self.send(client, node_id, cache[node_id]):
                return

    def push_all(self):
        cache = {}
        for client in list(self.clients.values()):
            for node_id in list(client.watches):
                if node_id not in cache:
                    cache[node_id] = self.payload(node_id)
                if not self.send(client, node_id, cache[node_id]):
                    break

    def history_tick(self, overview):
        now = int(time.time())
        last = self.points[-1]["at"] if self.points else 0
        if now - last < HISTORY_SECONDS:
            return
        if overview["residual"] != 0 and now - last < HISTORY_SECONDS + HISTORY_LATE_SECONDS:
            return
        segments = {row["key"]: row["bytes"] for row in overview["segments"] if row["bytes"]}
        point = {"v": 2, "at": now, "segments": segments, "free": overview["free"], "total": overview["disk"]["total"]}
        if sum(segments.values()) + point["free"] != point["total"]:
            return
        self.points.append(point)
        self.points = [old for old in self.points if old["at"] >= now - HISTORY_DAYS * DAY]
        self.save_history(self.points)
        items = {}
        for key in ("dead", "cache", "temp", "stray", "build", "project", "deploy", "generation", "agent"):
            members = sorted(self.kind_items.get(key, []), key=lambda item: -item.freed)[:HISTORY_ITEMS]
            if members:
                items[key] = {item.path: item.freed for item in members}
        with open(self.state / "history-items.jsonl", "a") as handle:
            handle.write(json.dumps({"at": now, "items": items}, separators=(",", ":")) + "\n")
        self.history_version += 1
        self.load_history_items()

    def load_history_items(self):
        path = self.state / "history-items.jsonl"
        sampled = {point["at"] for point in downsample(self.points)}
        items = {}
        if path.exists():
            for line in path.read_text().splitlines():
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if entry.get("at") in sampled:
                    items[str(entry["at"])] = entry["items"]
        self.history_items = items

    def write_outputs(self, overview):
        ledger = {**overview, **self.tracker(), "history": downsample(self.points), "events": self.events}
        write_file(self.runtime / "disk-ledger.json", json.dumps(ledger, separators=(",", ":")) + "\n", self.owner)
        if self.textfile.parent.is_dir():
            lines = ["# TYPE node_disk_ledger_bytes gauge"]
            for row in overview["segments"]:
                lines.append(f'node_disk_ledger_bytes{{segment="{row["key"]}",group="{row["group"]}"}} {row["bytes"]}')
            lines.append(f'node_disk_ledger_bytes{{segment="free",group="disk"}} {overview["free"]}')
            lines.append(f'node_disk_ledger_bytes{{segment="target",group="disk"}} {overview["target"]}')
            lines.append(f'node_disk_ledger_bytes{{segment="reclaimable",group="disk"}} {overview["reclaimable"]}')
            write_file(self.textfile, "\n".join(lines) + "\n", None)

    def urgency(self, deficit, free):
        if free < self.emergency:
            return 1.0
        return min(1.0, deficit / RAMP)

    def collect(self, now):
        if self.worker is not None:
            return
        _, _, free, _ = self.statfs()
        target = self.target() + MARGIN
        deficit = target - free
        merged = [item for item in self.model.merged if os.path.isdir(item.path)]
        base = {"at": int(time.time()), "target": target, "free": free, "deficit": max(0, deficit), "collecting": self.collecting}
        if not self.collecting:
            self.set_status({**base, "state": "observing"})
            return
        if merged:
            self.start([merged[0]], 0.0)
            return
        if deficit <= 0:
            self.set_status({**base, "state": "idle"})
            return
        if now < self.paused_until:
            return
        level = self.urgency(deficit, free)
        cpu, io = pressure("cpu"), pressure("io")
        if cpu > 30 + 70 * level or io > 20 + 80 * level:
            self.set_status({**base, "state": "waiting", "urgency": level, "cpu": cpu, "io": io})
            return
        head = [item for item in self.model.items if os.path.lexists(item.path) or item.kind == "dead"]
        if not head:
            self.set_status({**base, "state": "exhausted"})
            return
        first = head[0]
        batch = [first]
        if first.kind == "dead":
            limit = EMERGENCY_BURST if free < self.emergency else BURST
            total = first.freed
            for item in head[1:]:
                if item.kind != "dead" or len(batch) >= limit or (limit == BURST and total + item.freed > BURST_BYTES):
                    break
                batch.append(item)
                total += item.freed
        self.start(batch, level, base)

    def set_status(self, status):
        if {key: value for key, value in status.items() if key != "at"} != {key: value for key, value in self.status.items() if key != "at"}:
            self.status = {**status, "last": self.last_event}
            self.version += 1

    def start(self, batch, level, base=None):
        paths = sorted({path for item in batch for path in (item.store if item.kind != "dead" else item.targets)})
        ordered, references = self.collector.deletion_plan(self.index, paths) if paths else ([], {})
        work = [{"kind": item.kind, "path": item.path, "links": list(item.links), "files": list(item.files), "freed": item.freed, "last_used": item.last_used, "rank": item.rank, "detail": dict(item.detail)} for item in batch]
        self.set_status({**(base or {}), "state": "collecting", "kind": batch[0].kind, "items": len(batch), "urgency": level, "head": [entry["path"] for entry in work[:6]]})
        self.level = level
        self.worker = threading.Thread(target=self.execute, args=(work, ordered, references), daemon=True)
        self.worker.start()

    def execute(self, work, ordered, references):
        started = time.time()
        before = self.statfs()[2]
        status = 0
        refused = set()
        removed = []
        try:
            busy = self.reclaim.busy_paths() if any(entry["files"] for entry in work) else set()
            boot = False
            for entry in work:
                if any(path in busy for path in entry["files"]):
                    refused.add(entry["path"])
                    continue
                for link in entry["links"]:
                    try:
                        os.unlink(link)
                    except FileNotFoundError:
                        pass
                if entry["detail"].get("worktree"):
                    repo = entry["detail"]["repo"]
                    self.reclaim.run_as(self.user, ["git", "-C", repo, "worktree", "remove", "--force", entry["path"]])
                for path in entry["files"]:
                    if os.path.lexists(path):
                        owner = entry["detail"].get("owner", self.user)
                        result = self.reclaim.run_as(owner, ["rm", "-rf", "--one-file-system", "--", path])
                        if result.returncode != 0:
                            status = result.returncode
                if entry["kind"] == "generation" and "/profiles/system" in entry["detail"].get("profile", "") and entry["detail"].get("profile", "").endswith("/system"):
                    boot = True
                removed.append(entry["path"])
            if ordered:
                _, _, refused_paths = self.collector.delete_ordered(ordered, references)
                refused |= refused_paths
            if boot:
                result = subprocess.run(["/nix/var/nix/profiles/system/bin/switch-to-configuration", "boot"], capture_output=True, text=True)
                status = status or result.returncode
        except Exception as error:
            status = -1
            removed.append(f"error: {error}")
        after = self.statfs()[2]
        self.result = {
            "at": int(started),
            "stage": work[0]["kind"],
            "segment": KIND_KEY[work[0]["kind"]],
            "status": status,
            "free_gib": round(before / GIB, 2),
            "freed": after - before,
            "claimed": sum(entry["freed"] for entry in work),
            "items": len(work),
            "refused": len(refused),
            "seconds": round(time.time() - started, 2),
            "taken": {entry["path"]: entry["freed"] for entry in work[:200]},
            "oldest": min(entry["last_used"] for entry in work),
            "newest": max(entry["last_used"] for entry in work),
        }
        os.write(self.wake_write, b"x")

    def finish(self):
        try:
            os.read(self.wake_read, 64)
        except BlockingIOError:
            pass
        if self.worker is None or self.worker.is_alive() or self.result is None:
            return
        self.worker = None
        self.record(self.result)
        self.result = None
        self.paused_until = time.monotonic() + PAUSE * (1 - getattr(self, "level", 0.0))
        self.roots_due = time.monotonic()
        self.model_dirty = True
        self.set_status({**self.status, "state": "settling"})

    def busy(self):
        return bool(self.index.pending or self.tree.dirty or self.store_dirty or self.links_dirty is not None or self.model_dirty or self.sums_dirty or self.roots_due is not None)

    def step(self):
        now = time.monotonic()
        if now - self.db_checked >= DB_SECONDS:
            self.db_checked = now
            if self.index.load():
                self.tree.mark(self.store_node)
                self.roots_due = self.roots_due or now
                self.sums_dirty = True
        if self.index.pending:
            if self.index.walk_pending(now + 0.05):
                self.sums_dirty = True
        ready = [path for path, since in self.store_dirty.items() if now - since >= STORE_SETTLE]
        for path in ready[:200]:
            self.store_dirty.pop(path, None)
            if path in self.index.nar and self.index.measure(path):
                self.sums_dirty = True
        if ready:
            self.index.cache.commit()
        if self.links_dirty is not None and now - self.links_dirty >= max(LINKS_FLOOR, COST_FACTOR * self.links_cost):
            self.links_dirty = None
            self.links_cost = self.timed(self.index.scan_links)
            self.sums_dirty = True
        settled_before = self.tree.scans
        self.tree.settle(now + 0.05)
        if now - self.verified_at >= 1.0:
            self.verified_at = now
            self.tree.verify(time.monotonic() + VERIFY_SECONDS)
        tree_changed = self.tree.scans != settled_before
        if (self.roots_due is not None and now - self.roots_due >= max(MODEL_FLOOR, COST_FACTOR * self.roots_cost)) or now - self.roots_at >= ROOTS_SECONDS:
            self.roots_cost = self.timed(self.index.refresh_roots)
            self.roots_at = time.monotonic()
            self.roots_due = None
            self.model_dirty = True
        if tree_changed and not self.model_dirty:
            self.model_dirty_files = True
        if (self.model_dirty and now - self.model_at >= max(MODEL_FLOOR, COST_FACTOR * self.model_cost)) or now - self.model_at >= MODEL_SECONDS:
            self.model_cost = self.timed(self.model.refresh)
            self.model_at = time.monotonic()
            self.model_dirty = False
            self.index_items()
        if self.sums_dirty and now - self.sums_at >= max(SUMS_FLOOR, COST_FACTOR * self.sums_cost):
            self.sums_cost = self.timed(self.store_sums)
            self.sums_at = time.monotonic()
            self.sums_dirty = False
        if self.tree.root.total != self.files_total and now - self.files_at >= max(FILES_FLOOR, COST_FACTOR * self.files_cost):
            self.files_cost = self.timed(self.model.measure_files)
            self.files_at = time.monotonic()
            self.files_total = self.tree.root.total
            self.version += 1
        if now - self.internals_at >= INTERNALS_SECONDS:
            self.internals = hidden_inodes(self.source)
            self.internals_at = now
        acl = self.tree.acl_dirs() if now - self.xattr_at >= INTERNALS_SECONDS else self.xattr_dirs
        if acl != self.xattr_dirs or now - self.xattr_at >= INTERNALS_SECONDS:
            self.xattr = shared_xattr_blocks(acl, self.source, os.statvfs("/").f_bsize)
            self.xattr_dirs = acl
            self.xattr_at = now
        self.collect(now)
        if self.opens and self.index.touched and len(self.index.touched) >= 1000:
            self.index.flush_used()
        if now - self.pushed >= PUSH_SECONDS:
            overview = self.build_overview()
            if overview["residual"] != 0 and not self.tree.dirty:
                self.tree.drain(self.unknown)
                if self.tree.dirty:
                    overview = self.build_overview()
            residual = overview["residual"]
            if residual != 0 and not self.tree.dirty and now - self.held_at >= HELD_FLOOR:
                self.held = held_open(self.device)
                self.held_at = time.monotonic()
                overview = self.build_overview()
            elif now - self.held_at >= HELD_SECONDS:
                self.held = held_open(self.device)
                self.held_at = time.monotonic()
                overview = self.build_overview()
            changed = overview != self.overview_compare()
            self.overview = overview
            self.pushed = time.monotonic()
            if changed:
                self.push_all()
            self.history_tick(overview)
            if now - self.written_at >= FILE_SECONDS and changed:
                self.write_outputs(overview)
                self.written_at = now
                if self.index.touched:
                    self.index.flush_used()

    def overview_compare(self):
        return self.overview

    def run(self):
        self.load_history_items()
        self.cut_rank = -1
        self.overview = self.build_overview()
        self.write_outputs(self.overview)
        while True:
            fds = [self.tree.fd, self.server, self.wake_read, *self.clients]
            if self.opens:
                fds.append(self.opens.fd)
            if self.builds.fd is not None:
                fds.append(self.builds.fd)
            timeout = 0.05 if self.busy() else 1.0
            readable = set(select_ready(fds, timeout))
            self.tree.drain(self.unknown)
            if self.opens:
                self.opens.drain(self.touch)
            self.builds.drain()
            if self.server in readable:
                self.accept()
            for connection in [fd for fd in readable if fd in self.clients]:
                client = self.clients.get(connection)
                if client is not None:
                    self.receive(client)
            if self.wake_read in readable:
                self.finish()
            self.step()


def rebuild_text(seconds):
    if seconds < 60:
        return ""
    if seconds < 3600:
        return f", rebuild ~{round(seconds / 60)} min"
    return f", rebuild ~{seconds / 3600:.1f} h"


def select_ready(fds, timeout):
    import select

    try:
        return select.select(fds, [], [], timeout)[0]
    except (OSError, ValueError):
        return []


if __name__ == "__main__":
    Ledger().run()
