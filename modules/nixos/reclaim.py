#!/usr/bin/env python3
# Reclaim candidates: every removable item, the bytes deleting it frees and its rank, shared by the collector and the ledger.

import ctypes
import glob
import json
import os
import pwd
import re
import struct
import subprocess
import sys
import time
from pathlib import Path

DAY = 86400
WEIGHTS = {
    "dead": 64,
    "cache": 64,
    "temp": 64,
    "stale shell": 64,
    "stray profile": 16,
    "build": 4,
    "project": 4,
    "deploy": 4,
    "generation": 1,
    "agent": 0.25,
}
KNOWN_PROFILES = {"system", "home-manager", "profile", "default"}
GENERATION = re.compile(r"^(.+)-(\d+)-link$")
DERIVABLE_TEMP = re.compile(r"^(nix-shell[.-].*|nix-\d+-\d+|nix-build-.*|nix-develop-\d+-\d+|\.?org\.chromium\.Chromium\..*|scoped_dir.*|nixwatch-.*\.log|pytest-of-.*|babel-.*|epdfinfo.*|tmp\..*|tmp[a-z0-9_]{8}|\.?[a-z]+-[0-9a-f]{6,}\.(log|json|txt))$")
RUNTIME_TEMP = re.compile(r"^(\.[A-Za-z0-9]+-unix|hsperfdata_.*|cc-daemon-\d+|claude-\d+|claude-mcp-.*|systemd-private-.*|\.X\d+-lock|tmux-\d+|zellij-\d+|emacs\d+|ssh-.*|gpg-.*|pulse-.*|dbus-.*|kitty-.*|nvim.*|xdg-.*|lost\+found)$")
SESSION = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
DERIVABLE_OUTPUT = re.compile(r"^(target|dist|dist-newstyle|build|_build|out|\.lake|node_modules|__pycache__|\.mypy_cache|\.pytest_cache|\.ruff_cache|\.direnv|\.venv|venv|\.tox|\.stack-work|\.gradle|\.zig-cache|zig-out|elm-stuff|\.next|\.parcel-cache|_opam|result(-.*)?)$")
CACHES = (".cargo/registry/cache", ".cabal/packages", ".opam/download-cache")
CLOCK_TICKS = os.sysconf("SC_CLK_TCK")
BUILD_LOGS = "/nix/var/log/nix/drvs"
REBUILD_SCALE = 300
STATX_MTIME = 0x40
STATX_SIZE = 0x200
STATX_BTIME = 0x800
AT_FDCWD = -100
AT_SYMLINK_NOFOLLOW = 0x100
TRUSTED_SPAN = 3600
EMPTY_LOG = 64
IN_OPEN = 0x20
IN_CLOSE_WRITE = 0x8
IN_CLOSE_NOWRITE = 0x10
IN_CREATE = 0x100
IN_ISDIR = 0x40000000
IN_NONBLOCK = 0o4000
IN_CLOEXEC = 0o2000000
PROTECTED_CLASSES = ("running_system", "home_profile", "profiles", "previous", "shells", "processes", "roots")


def protected_class(link, reason):
    name = os.path.basename(link)
    if link in ("/run/current-system", "/run/booted-system") or reason == "booted generation" or (reason == "current generation" and name.startswith("system-")):
        return "running_system"
    if link.endswith("/gcroots/current-home") or (reason == "current generation" and name.startswith("home-manager-")):
        return "home_profile"
    if reason == "current generation":
        return "profiles"
    if reason == "previous generation" or name == "previous-successful-boot":
        return "previous"
    if reason.startswith("live shell"):
        return "shells"
    if link.startswith(("/proc/", "{")) or reason in ("in use by a process", "live agent session"):
        return "processes"
    return "roots"


class BuildTimes:
    def __init__(self, root=BUILD_LOGS, store=None):
        self.root = root
        self.store = store
        self.shards = {}
        self.seconds = {}
        self.measured = {}
        self.opened = {}
        self.watches = {}
        self.fd = None
        self.libc = ctypes.CDLL(None, use_errno=True)
        self.buffer = ctypes.create_string_buffer(256)
        if store:
            try:
                self.measured = json.loads(Path(store).read_text())
            except (OSError, ValueError):
                self.measured = {}

    def span(self, path):
        if self.libc.statx(AT_FDCWD, os.fsencode(path), AT_SYMLINK_NOFOLLOW, STATX_BTIME | STATX_MTIME | STATX_SIZE, self.buffer) != 0:
            return 0
        if not struct.unpack_from("I", self.buffer, 0)[0] & STATX_BTIME or struct.unpack_from("Q", self.buffer, 40)[0] <= EMPTY_LOG:
            return 0
        span = struct.unpack_from("q", self.buffer, 112)[0] - struct.unpack_from("q", self.buffer, 80)[0]
        return span if 0 <= span < TRUSTED_SPAN else 0

    def watch(self):
        self.fd = self.libc.inotify_init1(IN_NONBLOCK | IN_CLOEXEC)
        if self.fd < 0:
            self.fd = None
            return
        self.add(self.root, "", IN_CREATE)
        for shard in os.listdir(self.root):
            self.add(os.path.join(self.root, shard), shard, IN_OPEN | IN_CLOSE_WRITE | IN_CLOSE_NOWRITE)

    def add(self, path, shard, mask):
        wd = self.libc.inotify_add_watch(self.fd, os.fsencode(path), mask)
        if wd >= 0:
            self.watches[wd] = shard

    def fileno(self):
        return self.fd

    def drain(self):
        if self.fd is None:
            return
        now = time.time()
        changed = False
        while True:
            try:
                data = os.read(self.fd, 65536)
            except (BlockingIOError, InterruptedError):
                break
            offset = 0
            while offset < len(data):
                wd, mask, _, length = struct.unpack_from("iIII", data, offset)
                name = data[offset + 16 : offset + 16 + length].rstrip(b"\0").decode(errors="replace")
                offset += 16 + length
                shard = self.watches.get(wd)
                if shard is None:
                    continue
                if shard == "":
                    if mask & IN_CREATE and mask & IN_ISDIR:
                        self.add(os.path.join(self.root, name), name, IN_OPEN | IN_CLOSE_WRITE | IN_CLOSE_NOWRITE)
                    continue
                if mask & IN_ISDIR or not name:
                    continue
                drv = shard + name.removesuffix(".bz2")
                if mask & IN_OPEN:
                    self.opened.setdefault(drv, now)
                elif mask & IN_CLOSE_WRITE and drv in self.opened:
                    self.measured[drv] = round(now - self.opened.pop(drv))
                    changed = True
                elif mask & IN_CLOSE_NOWRITE:
                    self.opened.pop(drv, None)
        if changed and self.store:
            temporary = f"{self.store}.tmp"
            Path(temporary).write_text(json.dumps(self.measured))
            os.replace(temporary, self.store)

    def refresh(self):
        try:
            shards = os.listdir(self.root)
        except OSError:
            return
        for shard in shards:
            directory = os.path.join(self.root, shard)
            try:
                stamp = os.stat(directory).st_mtime_ns
                names = os.listdir(directory) if self.shards.get(shard) != stamp else ()
            except OSError:
                continue
            self.shards[shard] = stamp
            for name in names:
                self.seconds[shard + name.removesuffix(".bz2")] = self.span(os.path.join(directory, name))

    def of(self, drv, inputs_ready=None):
        name = os.path.basename(drv)
        if name in self.measured:
            return self.measured[name]
        span = self.seconds.get(name, 0)
        return min(span, inputs_ready) if span and inputs_ready is not None else span


def glob_worktrees(home):
    return [path for path in glob.glob(str(Path(home) / "**/.claude/worktrees/*"), recursive=True) if "/.claude/worktrees/" not in path.split("/.claude/worktrees/", 1)[1]]


class Item:
    __slots__ = ("kind", "path", "last_used", "links", "files", "targets", "store", "store_bytes", "file_bytes", "detail", "rank", "build")

    def __init__(self, kind, path, last_used, links=(), files=(), detail=None):
        self.kind = kind
        self.path = path
        self.last_used = int(last_used)
        self.links = list(links)
        self.files = list(files)
        self.targets = set()
        self.store = []
        self.store_bytes = 0
        self.file_bytes = 0
        self.detail = detail or {}
        self.rank = 0
        self.build = 0

    @property
    def weight(self):
        return WEIGHTS[self.kind]

    @property
    def freed(self):
        return self.store_bytes + self.file_bytes

    def score(self, now):
        return max(0, now - self.last_used) * self.weight / (1 + self.build / REBUILD_SCALE)

    def row(self):
        return {"path": self.path, "kind": self.kind, "size": self.freed, "store": self.store_bytes, "files": self.file_bytes, "last_used": self.last_used, "rank": self.rank, "build": self.build, **self.detail}


def lstat_time(path):
    try:
        return os.lstat(path).st_mtime
    except OSError:
        return 0


def boot_time():
    with open("/proc/stat") as handle:
        for line in handle:
            if line.startswith("btime "):
                return int(line.split()[1])
    return 0


def alive(pid, started=None):
    try:
        with open(f"/proc/{pid}/stat") as handle:
            fields = handle.read().rsplit(")", 1)[1].split()
    except (OSError, IndexError):
        return False
    return started is None or fields[19] == str(started)


def live_sessions(home):
    found = []
    booted = boot_time()
    for record in glob.glob(str(home / ".claude/sessions/*.json")):
        try:
            data = json.loads(Path(record).read_text())
        except (OSError, ValueError):
            continue
        pid = data.get("pid") or int(Path(record).stem)
        if not alive(pid, data.get("procStart")):
            continue
        ids = {data.get("sessionId")} | {former.get("sessionId") for former in data.get("formerNames") or []}
        started = booted + int(data.get("procStart", 0)) / CLOCK_TICKS
        found.append({"pid": pid, "ids": {sid for sid in ids if sid}, "cwd": data.get("cwd"), "started": started})
    return found


def busy_paths():
    found = set()
    for proc in glob.glob("/proc/[0-9]*"):
        for link in ("cwd", "root"):
            try:
                found.add(os.readlink(f"{proc}/{link}"))
            except OSError:
                pass
        try:
            for name in os.listdir(f"{proc}/fd"):
                try:
                    target = os.readlink(f"{proc}/fd/{name}")
                except OSError:
                    continue
                if target.startswith("/"):
                    found.add(target.removesuffix(" (deleted)"))
        except OSError:
            pass
        try:
            with open(f"{proc}/environ", "rb") as handle:
                for entry in handle.read().split(b"\0"):
                    if entry.startswith((b"TMPDIR=", b"NIX_BUILD_TOP=")):
                        found.add(entry.split(b"=", 1)[1].decode(errors="replace"))
        except OSError:
            pass
    ancestors = set()
    for path in found:
        while path not in ancestors and path not in ("/", ""):
            ancestors.add(path)
            path = os.path.dirname(path)
    return ancestors


def profile_generations(directory):
    profiles = {}
    try:
        names = os.listdir(directory)
    except OSError:
        return profiles
    for name in names:
        match = GENERATION.match(name)
        if match:
            profiles.setdefault(match.group(1), {})[int(match.group(2))] = os.path.join(directory, name)
    current = {}
    for profile in profiles:
        try:
            match = GENERATION.match(os.readlink(os.path.join(directory, profile)))
            current[profile] = int(match.group(2)) if match else None
        except OSError:
            current[profile] = None
    return [(profile, links, current[profile]) for profile, links in profiles.items()]


def run_as(user, command, cwd=None, input=None):
    if os.geteuid() == 0 and user != "root":
        entry = pwd.getpwnam(user)
        command = ["setpriv", f"--reuid={entry.pw_uid}", f"--regid={entry.pw_gid}", "--init-groups", "--", *command]
    return subprocess.run(command, capture_output=True, text=True, cwd=cwd, input=input)


def default_branch(repo, user):
    head = run_as(user, ["git", "-C", repo, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"]).stdout.strip()
    for branch in (head, "main", "master"):
        if branch and run_as(user, ["git", "-C", repo, "rev-parse", "--verify", "--quiet", branch]).returncode == 0:
            return branch
    return None


def worktree_state(repo, worktree, user):
    dirty = run_as(user, ["git", "-C", worktree, "status", "--porcelain"])
    if dirty.returncode != 0:
        return None
    branch = default_branch(repo, user)
    merged = branch is not None and run_as(user, ["git", "-C", worktree, "merge-base", "--is-ancestor", "HEAD", branch]).returncode == 0
    return {"dirty": len(dirty.stdout.splitlines()), "merged": merged, "into": branch}


def ignored(root, lines, user):
    if not lines:
        return []
    result = run_as(user, ["git", "-C", str(root), "check-ignore", "--no-index", "-z", "--stdin"], input="\0".join(lines) + "\0")
    return [line for line in result.stdout.split("\0") if line]


class Model:
    def __init__(self, index, home, user, retention, size, file_size, file_used, tmp="/tmp", offload=None, worktrees=None, builds=None):
        self.index = index
        self.home = Path(home)
        self.user = user
        self.uid = pwd.getpwnam(user).pw_uid
        self.retention = retention
        self.size = size
        self.file_size = file_size
        self.file_used = file_used
        self.tmp = tmp
        self.offload = offload
        self.find_worktrees = worktrees or (lambda: glob_worktrees(self.home))
        self.worktrees = {}
        self.ignored = {}
        self.items = []
        self.file_items = []
        self.merged = []
        self.protected = {}
        self.protected_claims = []
        self.protected_store = []
        self.owner = {}
        self.live = set()
        self.now = 0
        self.builds = builds or BuildTimes()

    def link_target(self):
        target = {}
        for path, links in (self.index.root_links or {}).items():
            for link in links:
                target.setdefault(link, set()).add(path)
        return target

    def generation_items(self, items, explicit):
        directories = ["/nix/var/nix/profiles", str(self.home / ".local/state/nix/profiles"), *glob.glob("/nix/var/nix/profiles/per-user/*")]
        running = {os.path.realpath(path): reason for path, reason in (("/run/booted-system", "booted generation"), ("/run/current-system", "current generation"))}
        for directory in directories:
            for profile, links, current in profile_generations(directory):
                numbers = sorted(links)
                stray = profile not in KNOWN_PROFILES
                keep = set() if stray else {number for number in numbers if current is not None and number <= current}
                keep = set(sorted(keep)[-2:])
                for position, number in enumerate(numbers):
                    link = links[number]
                    if number in keep:
                        self.protected[link] = "current generation" if number == current else "previous generation"
                        continue
                    if os.path.realpath(link) in running:
                        self.protected[link] = running[os.path.realpath(link)]
                        continue
                    successor = numbers[position + 1] if position + 1 < len(numbers) else None
                    used = lstat_time(links[successor]) if successor is not None else lstat_time(link)
                    kind = "stray profile" if stray else "generation"
                    item = Item(kind, link, used, links=[link], detail={"profile": os.path.join(directory, profile), "number": number, "current": number == current})
                    items.append(item)
                    explicit[link] = item

    def shell_items(self, items, explicit):
        for directory in glob.glob("/run/user/*/nix-shell-roots/*"):
            pid = os.path.basename(directory)
            links = sorted(glob.glob(directory + "/*"))
            if not pid.isdigit() or alive(int(pid)):
                for link in links:
                    self.protected[link] = f"live shell {pid}"
                continue
            item = Item("stale shell", directory, lstat_time(directory), links=links, files=[directory], detail={"pid": int(pid)})
            items.append(item)
            for link in links:
                explicit[link] = item

    def deploy_items(self, items, explicit):
        for link in glob.glob(str(self.home / ".local/state/rebuild/roots/*")) + glob.glob("/var/lib/flake-sync/result*"):
            item = Item("deploy", link, lstat_time(link), links=[link])
            items.append(item)
            explicit[link] = item

    def container_items(self, items, busy, sessions):
        containers = {}

        def add(item):
            if item.path in busy:
                self.protected[item.path] = "in use by a process"
                return
            items.append(item)
            containers[item.path] = item

        for base, owner in ((self.home / ".cache", self.user), (Path("/root/.cache"), "root")):
            try:
                children = sorted(base.iterdir())
            except OSError:
                continue
            for child in children:
                add(Item("cache", str(child), self.file_used(str(child)), files=[str(child)], detail={"owner": owner}))
        for relative in CACHES:
            path = self.home / relative
            if path.exists():
                add(Item("cache", str(path), self.file_used(str(path)), files=[str(path)], detail={"owner": self.user}))
        for item in self.tmp_items(sessions):
            add(item)
        for item in self.agent_worktrees():
            add(item)
        for item in self.build_items():
            add(item)
        return containers

    def tmp_items(self, sessions):
        session_ids = {sid for session in sessions for sid in session["ids"]}
        oldest = min((session["started"] for session in sessions if not session["ids"]), default=None)
        try:
            entries = os.listdir(self.tmp)
        except OSError:
            entries = []
        for name in sorted(entries):
            path = os.path.join(self.tmp, name)
            try:
                info = os.lstat(path)
            except OSError:
                continue
            if RUNTIME_TEMP.match(name) or not (os.path.stat.S_ISDIR(info.st_mode) or os.path.stat.S_ISREG(info.st_mode)):
                continue
            owner = pwd.getpwuid(info.st_uid).pw_name if info.st_uid in (0, self.uid) else None
            if owner is None:
                continue
            kind = "temp" if DERIVABLE_TEMP.match(name) else "agent"
            yield Item(kind, path, self.file_used(path), files=[path], detail={"owner": owner})
        for session_dir in glob.glob(f"{self.tmp}/claude-{self.uid}/*/*"):
            name = os.path.basename(session_dir)
            if not SESSION.match(name):
                continue
            used = self.file_used(session_dir)
            if name in session_ids or (oldest is not None and used >= oldest):
                self.protected[session_dir] = "live agent session"
                continue
            yield Item("agent", session_dir, used, files=[session_dir], detail={"owner": self.user, "session": name})

    def agent_worktrees(self):
        for worktree in self.find_worktrees():
            if not os.path.isdir(worktree):
                continue
            repo = worktree.split("/.claude/worktrees/", 1)[0]
            key = (worktree, lstat_time(os.path.join(worktree, ".git")), self.file_used(worktree))
            if self.worktrees.get(worktree, (None,))[0] != key:
                self.worktrees[worktree] = (key, worktree_state(repo, worktree, self.user))
            state = self.worktrees[worktree][1]
            if state is None:
                continue
            kind = "agent"
            detail = {"owner": self.user, "repo": repo, **state, "worktree": True}
            yield Item(kind, worktree, self.file_used(worktree), files=[worktree], detail=detail)

    def build_items(self):
        state = self.home / ".local/state/dev-build"
        for record in state.glob("*/artefacts"):
            try:
                root = Path((record.parent / "root").read_text().strip())
            except OSError:
                continue
            if not root.is_dir():
                continue
            key = (str(record), lstat_time(record), lstat_time(root / ".gitignore"))
            if self.ignored.get(str(record), (None,))[0] != key:
                lines = [line for line in record.read_text().splitlines() if line and not line.startswith(".dev-build-")]
                self.ignored[str(record)] = (key, ignored(root, lines, self.user))
            for line in self.ignored[str(record)][1]:
                target = root / line
                if DERIVABLE_OUTPUT.match(target.name) and target.exists() and not target.is_symlink():
                    yield Item("build", str(target), self.file_used(str(target)), files=[str(target)], detail={"owner": self.user, "project": str(root), "artefact": True})
        if self.offload and os.path.isdir(self.offload):
            for path in sorted(Path(self.offload).iterdir()):
                marker = path / ".dev-build-last-used"
                if path.is_dir() and not path.is_symlink() and marker.exists():
                    yield Item("build", str(path), lstat_time(marker), files=[str(path)], detail={"owner": self.user, "offload": True})

    def owner_of(self, link, explicit, containers, projects):
        if link in explicit:
            return explicit[link]
        if link in self.protected:
            return None
        path = link
        while path not in ("/", ""):
            if path in containers:
                return containers[path]
            if path in self.protected:
                return None
            path = os.path.dirname(path)
        if link.startswith(("/proc/", "{", "/run/current-system", "/run/booted-system", "/nix/var/nix/")) or not link.startswith("/home/"):
            return None
        project = self.retention.project_for(Path(link))
        if project is None:
            return None
        key = str(project)
        if key not in projects:
            projects[key] = Item("project", key, 0, detail={"roots": []})
        item = projects[key]
        item.links.append(link)
        item.detail["roots"].append(link)
        item.last_used = max(item.last_used, int(lstat_time(link)))
        return item

    def refresh(self, now=None):
        now = int(now or time.time())
        self.protected = {}
        items = []
        explicit = {}
        sessions = live_sessions(self.home)
        busy = busy_paths()
        self.generation_items(items, explicit)
        self.shell_items(items, explicit)
        self.deploy_items(items, explicit)
        containers = self.container_items(items, busy, sessions)
        projects = {}
        protected_links = {}
        self.owner = {}
        for link, targets in self.link_target().items():
            item = self.owner_of(link, explicit, containers, projects)
            if item is None:
                protected_links[link] = targets
                self.protected.setdefault(link, "root")
                self.owner[link] = None
            else:
                item.targets |= targets
                self.owner[link] = item
        items.extend(projects.values())
        for path in self.index.dead:
            items.append(Item("dead", path, self.index.effective.get(path, self.index.used.get(path, 0)), detail={}))
            items[-1].targets = {path}
        references = self.index.references

        def claim(starts, live):
            found = []
            stack = [path for path in starts if path in references and path not in live]
            while stack:
                path = stack.pop()
                if path in live:
                    continue
                live.add(path)
                found.append(path)
                stack.extend(ref for ref in references[path] if ref not in live)
            return found

        protected_live = set()
        order = {name: position for position, name in enumerate(PROTECTED_CLASSES)}
        classed = sorted(((protected_class(link, self.protected.get(link, "root")), link) for link in protected_links), key=lambda pair: (order[pair[0]], pair[1]))
        self.protected_claims = []
        for name, link in classed:
            found = claim(protected_links[link], protected_live)
            self.protected_claims.append((name, link, found, sum(self.size(path) for path in found)))
        self.protected_store = [path for _, _, found, _ in self.protected_claims for path in found]
        self.builds.refresh()
        deriver = self.index.deriver
        for final in (False, True):
            items.sort(key=lambda item: (-item.score(now), item.path))
            for rank, item in enumerate(items):
                item.rank = rank
            live = set(protected_live)
            for item in reversed(items):
                item.store = claim(item.targets, live)
                item.build = self.build_seconds(item.store, deriver)
                if final:
                    item.store_bytes = sum(self.size(path) for path in item.store)
        self.live = live
        self.items = items
        self.file_items = [item for item in items if item.files]
        self.merged = [item for item in self.file_items if item.detail.get("worktree") and item.detail.get("merged") and not item.detail.get("dirty")]
        self.measure_files()
        self.now = now
        return items

    def build_seconds(self, paths, deriver):
        registered = self.index.registered
        references = self.index.references
        seconds = {}
        for path in paths:
            drv = deriver.get(path)
            if drv is None:
                continue
            end = registered.get(path, 0)
            ready = max((registered.get(ref, 0) for ref in references.get(path, ()) if ref != path and registered.get(ref, 0) <= end), default=0)
            estimate = self.builds.of(drv, end - ready if ready else None)
            seconds[drv] = max(seconds.get(drv, 0), estimate)
        return sum(seconds.values())

    def measure_files(self):
        claimed = []
        for item in self.file_items:
            total = 0
            for path in item.files:
                if any(path == done or path.startswith(done + "/") for done in claimed):
                    continue
                inside = [done for done in claimed if done.startswith(path + "/")]
                top = [done for done in inside if not any(done != other and done.startswith(other + "/") for other in inside)]
                total += max(0, self.file_size(path) - sum(self.file_size(done) for done in top))
                claimed.append(path)
            item.file_bytes = total

    def store_owner(self):
        owner = {}
        for item in self.items:
            for path in item.store:
                owner[path] = item
        return owner


def walk_size(path):
    total = 0
    stack = [path]
    seen = set()
    while stack:
        current = stack.pop()
        try:
            info = os.lstat(current)
        except OSError:
            continue
        if info.st_ino in seen:
            continue
        seen.add(info.st_ino)
        total += info.st_blocks * 512
        if os.path.stat.S_ISDIR(info.st_mode):
            try:
                stack.extend(os.path.join(current, name) for name in os.listdir(current))
            except OSError:
                pass
    return total


def walk_used(path):
    newest = lstat_time(path)
    for root, dirs, files in os.walk(path):
        for name in dirs + files:
            newest = max(newest, lstat_time(os.path.join(root, name)))
    return newest


def load(path):
    import importlib.util

    spec = importlib.util.spec_from_file_location(Path(path).stem.replace("-", "_"), path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    import argparse

    parser = argparse.ArgumentParser(prog="reclaim")
    parser.add_argument("--home", default=os.path.expanduser("~"))
    parser.add_argument("--user", default=os.environ.get("USER", "max"))
    parser.add_argument("--limit", type=int, default=60)
    parser.add_argument("--kind")
    options = parser.parse_args()
    collector = load(os.environ["COLLECT_MODULE"])
    retention = load(os.environ["RETENTION_MODULE"])
    index = collector.Index()
    index.refresh()
    index.walk_pending(float("inf"))
    model = Model(index, options.home, options.user, retention, index.size, walk_size, walk_used)
    started = time.monotonic()
    items = model.refresh()
    print(f"refresh {time.monotonic() - started:.2f}s")
    shown = [item for item in items if options.kind is None or item.kind == options.kind]
    if options.kind is None:
        shown = [item for item in shown if item.kind != "dead"]
    for item in shown[: options.limit]:
        print(f"{item.rank:7d} {item.kind:13} {item.freed / 2**30:8.3f} GiB {item.build:6d}s {time.strftime('%Y-%m-%d %H:%M', time.localtime(item.last_used))} {item.path}")
    print("protected:")
    for path, why in sorted(model.protected.items()):
        if not path.startswith("/proc/"):
            print(f"  {why:22} {path}")
    print(f"items {len(items)}; dead {sum(1 for item in items if item.kind == 'dead')}; freed total {sum(item.freed for item in items) / 2**30:.2f} GiB; protected store {sum(model.size(path) for path in model.protected_store) / 2**30:.2f} GiB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
