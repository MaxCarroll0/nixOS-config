import collections
import ctypes
import fcntl
import glob
import re
import importlib.util
import json
import os
import shutil
import struct
import subprocess
import time
from pathlib import Path


GIB = 1024**3
DAY = 86400
HISTORY_DAYS = 30
HISTORY_POINTS = 288
PREVIEW_BYTES = 10 * GIB
SLACK_BYTES = GIB // 2
STORE_DU_SECONDS = 6 * 3600
FORCED_DU_SECONDS = 3600
XATTR_SECONDS = 3600
INTERNALS_SECONDS = 3600
HISTORY_SECONDS = 900
PUBLISH_SECONDS = 5
QUIET_SECONDS = 60
STORE_POLL_SECONDS = 2
ROOTS_SECONDS = 300
PLAN_SECONDS = 300
OFFLOAD_SECONDS = 600
VERIFY_SECONDS = 0.01
SETTLE_SECONDS = 0.5
SCAN_SECONDS = 0.5
MISMATCH_SECONDS = 600
MISMATCH_BYTES = 64 * 1024**2
HELD_SECONDS = 30
TICK_SECONDS = 0.25
DU_POLL_SECONDS = 10
NEED_STEP = 256 * 1024**2
KEEP_GENERATIONS = 10
SEGMENTS = ("system", "home", "system_generations", "home_generations", "project_tier1", "project_tier2", "fetched", "deployed", "shells", "other", "garbage", "building", "metadata", "rescan")


def load_module(name, variable):
    spec = importlib.util.spec_from_file_location(name, os.environ[variable])
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


INDEX = []


def closure(paths):
    return INDEX[0].closure(path for path in paths if path.startswith("/nix/store/"))


def resolve(path):
    return os.path.realpath(path)


def du(path):
    if not path.exists():
        return 0
    total = 0
    for root, _, files in os.walk(path):
        for name in files:
            try:
                total += os.lstat(os.path.join(root, name)).st_size
            except OSError:
                continue
    return total


def recorded_artefacts(path):
    manifest = path / ".dev-build-artefacts"
    if not manifest.exists():
        return 0
    return sum(du(path / line) for line in manifest.read_text().splitlines() if line)


def offload_segment(root, sizes):
    if not root.is_dir():
        return None
    projects = {}
    for path in sorted(root.iterdir()):
        if path.is_symlink() or not path.is_dir() or not (path / ".dev-build-last-used").exists():
            continue
        artefacts = recorded_artefacts(path)
        profile = Path(os.path.realpath(path / ".dev-build-profile"))
        shell = closure([str(profile)]) if profile.name else set()
        rooted = sum(sizes.get(item, 0) for item in shell) if profile.exists() else 0
        projects[path.name] = {
            "sources": du(path) - artefacts,
            "artefacts": artefacts,
            "rooted_shell": rooted,
        }
    return {
        "sources": sum(item["sources"] for item in projects.values()),
        "artefacts": sum(item["artefacts"] for item in projects.values()),
        "rooted_shells": sum(item["rooted_shell"] for item in projects.values()),
        "projects": projects,
    }


def scratch_plan(need):
    command = os.environ.get("LEDGER_SCRATCH_PLAN")
    if not command:
        return None
    result = subprocess.run(
        ["runuser", "-u", os.environ["LEDGER_USER"], "--", *command.split(), "--json", "--need-gib", str(need / GIB)],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0 or not result.stdout:
        return {"error": result.stderr.strip().splitlines()[-1:] or ["failed"], "selected": [], "freed": 0}
    return json.loads(result.stdout)


def store_plan(collector, index, need):
    _, chosen, freed = collector.select(index, need)
    rows = [{**row, "kind": "dead path"} for row in collector.rows(index, chosen)]
    largest = sorted(rows, key=lambda row: -row["size"])[:10]
    return {"selected": rows, "freed": freed, "largest": largest}


def queue(stages, deficit):
    candidates = [{**row, "stage": stage} for stage, plan in stages if plan is not None for row in plan["selected"]]
    candidates.sort(key=lambda row: row.get("last_used", 0))
    rows = []
    cumulative = 0
    cut = -1
    for row in candidates:
        cumulative += row["size"]
        rows.append({**row, "cumulative": cumulative})
        if cut < 0 and deficit > 0 and cumulative >= deficit:
            cut = len(rows) - 1
    return rows, cut


def load_history(path, now):
    points = []
    if path.exists():
        for line in path.read_text().splitlines():
            try:
                point = json.loads(line)
            except ValueError:
                continue
            if point.get("at", 0) >= now - HISTORY_DAYS * DAY:
                points.append(point)
    return points


def append_history(path, points, point):
    points.append(point)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp")
    temporary.write_text("".join(json.dumps(item, separators=(",", ":")) + "\n" for item in points))
    temporary.replace(path)
    os.chmod(path, 0o644)


def downsample(points):
    if len(points) <= HISTORY_POINTS:
        return points
    step = len(points) / HISTORY_POINTS
    return [points[int(index * step)] for index in range(HISTORY_POINTS)] + points[-1:]


def load_events(path):
    if not path.exists():
        return []
    events = []
    for line in path.read_text().splitlines()[-40:]:
        try:
            events.append(json.loads(line))
        except ValueError:
            continue
    return events


LIBC = ctypes.CDLL(None, use_errno=True)
AT_SYMLINK_FOLLOW = 0x400
AT_HANDLE_CONNECTABLE = 0x002
FILEID_INO32_GEN = 1


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
        stat = os.fstat(fd)
        if stat.st_nlink:
            os.close(fd)
            return
        yield os.readlink(f"/proc/self/fd/{fd}").removesuffix(" (deleted)"), stat
        parent = os.open("..", os.O_RDONLY | os.O_DIRECTORY, dir_fd=fd)
        os.close(fd)
        fd = parent if parent != fd else None


def held_open(device):
    owners = {}
    root_fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    for kind, pattern in (("open", "/proc/[0-9]*/fd/*"), ("mapped", "/proc/[0-9]*/map_files/*")):
        for link in glob.glob(pattern):
            try:
                target = os.readlink(link)
                if not target.endswith(" (deleted)"):
                    continue
                stat = os.stat(link)
            except OSError:
                continue
            if stat.st_dev != device or not os.path.stat.S_ISREG(stat.st_mode):
                continue
            pid = link.split("/")[2]
            try:
                command = open(f"/proc/{pid}/comm").read().strip()
            except OSError:
                command = pid
            row = owners.setdefault(stat.st_ino, {"path": target[: -len(" (deleted)")], "size": stat.st_blocks * 512, "last_used": int(stat.st_mtime), "how": kind, "inode": stat.st_ino, "holders": set()})
            row["holders"].add(command)
            try:
                for path, directory in dead_ancestors(link, root_fd):
                    owners.setdefault(directory.st_ino, {"path": path, "size": directory.st_blocks * 512, "last_used": int(directory.st_mtime), "how": "as a parent", "inode": directory.st_ino, "holders": set()})["holders"].add(command)
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


def hidden_inodes(root):
    source = root_source(root)
    header = subprocess.run(["dumpe2fs", "-h", source], capture_output=True, text=True).stdout
    field = lambda name: int(re.search(rf"^{name}:\s+(\d+)", header, re.M).group(1))
    block = field("Block size")
    groups = -(-field("Block count") // field("Blocks per group"))
    total = sum(debugfs_stat(source, inode)[0] for inode in (3, 4, 12))
    resize, _ = debugfs_stat(source, 7)
    total += max(0, resize - field("Reserved GDT blocks") * backup_groups(groups) * block)
    journal, out = debugfs_stat(source, 8)
    size = re.search(r"Size: (\d+)", out)
    total += max(0, journal - int(size.group(1))) if size else 0
    return total


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


def generation_rows(links, size_of):
    rows = []
    for link in links:
        name = os.path.basename(link)
        number = int(re.search(r"-(\d+)-link$", name).group(1)) if re.search(r"-(\d+)-link$", name) else 0
        profile = name.rsplit("-", 2)[0] if number else name
        rows.append({"path": link, "profile": profile, "number": number, "last_used": int(os.lstat(link).st_mtime), "size": size_of(link)})
    rows.sort(key=lambda row: (row["profile"], -row["number"]))
    rank = {}
    for row in rows:
        rank[row["profile"]] = rank.get(row["profile"], 0) + 1
        row["expiring"] = row["number"] > 0 and rank[row["profile"]] > KEEP_GENERATIONS
    return rows


def project_rows(projects, sizes, retention, path_row, listing, project_paths):
    counts = collections.Counter(path for project in projects.values() for path in project.closure)
    rows = []
    for index, project in enumerate(projects.values()):
        exclusive = {tier: 0 for tier in retention.TIERS}
        members = []
        for path in project.closure:
            if path in project_paths:
                tier = retention.tier_of(path)
                row = path_row(path)
                row["tier"] = tier
                row["projects"] = counts[path]
                exclusive[tier] += row["size"]
                members.append(row)
        rows.append({
            "path": str(project.path),
            "file": listing(f"disk-project-{index}.jsonl", members),
            "roots": [str(root) for root in project.roots],
            "size": sum(exclusive.values()),
            "shared": sum(sizes.get(path, 0) for path in project.closure) - sum(exclusive.values()),
            "tiers": {str(tier): exclusive[tier] for tier in retention.TIERS},
            "last_used": int(project.last_used),
            "last_built": int(project.last_built),
        })
    return sorted(rows, key=lambda row: -row["size"])


def write_lines(path, rows, owner):
    temporary = path.with_suffix(".tmp")
    temporary.write_text("".join(json.dumps(row, separators=(",", ":")) + "\n" for row in rows))
    os.chown(temporary, owner, -1)
    temporary.replace(path)


def write_json(path, ledger, owner):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(ledger, separators=(",", ":")) + "\n")
    os.chown(temporary, owner, -1)
    temporary.replace(path)


def write_textfile(path, ledger):
    lines = ["# TYPE node_disk_ledger_bytes gauge"]
    for segment, value in ledger["store"].items():
        lines.append(f'node_disk_ledger_bytes{{section="store",segment="{segment}"}} {value}')
    for segment, value in ledger["files"].items():
        lines.append(f'node_disk_ledger_bytes{{section="files",segment="{segment}"}} {value}')
    for segment in ("sources", "artefacts", "rooted_shells"):
        if "offload" in ledger:
            lines.append(f'node_disk_ledger_bytes{{section="offload",segment="{segment}"}} {ledger["offload"][segment]}')
    lines.append(f'node_disk_ledger_bytes{{section="disk",segment="free"}} {ledger["free"]}')
    lines.append(f'node_disk_ledger_bytes{{section="disk",segment="reserved"}} {ledger["reserved"]}')
    lines.append(f'node_disk_ledger_bytes{{section="disk",segment="target"}} {ledger["target"]}')
    temporary = path.with_suffix(".tmp")
    temporary.write_text("\n".join(lines) + "\n")
    temporary.replace(path)




def mtime(path):
    try:
        return os.stat(path).st_mtime_ns
    except OSError:
        return 0


def blocks(path):
    try:
        return os.lstat(path).st_blocks * 512
    except OSError:
        return 0


def shared_xattr_blocks(dirs, members, source, block_size):
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
            owner = next((member for member in members if (candidates[inode] + "/").startswith(member + "/")), None)
            if owner:
                extra[owner] = extra.get(owner, 0) + block_size
    return extra


def roots_of(index, path):
    targets = index.dependents([path]) & (index.root_links or {}).keys()
    links = sorted({link for target in targets for link in index.root_links[target] if not link.startswith("{")})
    return links[:6]


class Ledger:
    def __init__(self):
        self.state = Path(os.environ["LEDGER_STATE_DIR"])
        self.state.mkdir(parents=True, exist_ok=True)
        self.lock = open(self.state / "measure.lock", "a")
        self.retention = load_module("retention", "RETENTION_MODULE")
        self.collector = load_module("collector", "COLLECT_MODULE")
        self.home = Path(os.environ["LEDGER_HOME"])
        self.runtime = Path(os.environ["LEDGER_RUNTIME_DIR"])
        self.textfile = Path(os.environ["LEDGER_TEXTFILE"])
        self.owner = int(os.environ["LEDGER_UID"])
        self.offload_root = os.environ.get("LEDGER_OFFLOAD_DIR", "")
        self.index = self.collector.Index()
        self.index.refresh()
        INDEX.append(self.index)
        self.tree = load_module("tree", "TREE_MODULE").Tree("/", self.skip)
        self.store_node = self.tree.find("/nix/store")
        self.source = root_source("/")
        self.device = os.stat("/").st_dev
        self.signature = self.store_signature()
        self.roots_checked = time.monotonic()
        self.fresh = []
        self.view = None
        self.du = None
        self.du_path = self.state / "store-du.json"
        try:
            self.du_state = json.loads(self.du_path.read_text())
        except (OSError, ValueError):
            self.du_state = {"at": 0, "bytes": 0}
        if self.du_state["bytes"] and self.index.coverage() < 0.99:
            self.index.calibrate(self.du_state["bytes"] - self.inside_store() - self.building())
        self.internals = (0, 0.0)
        self.xattr = ({}, 0.0, None)
        self.scratch = (None, 0.0, 0)
        self.offload = (None, 0.0)
        self.points = load_history(self.state / "history.jsonl", int(time.time()))
        self.written = {}
        self.mismatch_since = None
        self.published = 0.0
        self.published_used = None
        self.published_total = None
        self.verified_at = 0.0
        self.polled = 0.0
        self.du_polled = 0.0
        self.held = ([], 0.0)

    def skip(self, parent, name):
        return parent == "/nix/store" and (name == ".links" or "/nix/store/" + name in self.index.nar)

    def store_signature(self):
        version = self.index.db.execute("pragma data_version").fetchone()[0]
        watched = [
            "/nix/var/nix/gcroots/auto",
            "/nix/var/nix/profiles",
            str(self.home / ".local/state/nix/profiles"),
            str(self.home / ".local/state/rebuild/roots"),
            *glob.glob("/run/user/*/nix-shell-roots/*"),
        ]
        return version, tuple(mtime(path) for path in watched)

    def inside_store(self):
        return blocks("/nix/store/.links") + blocks("/nix/store")

    def building(self):
        return self.store_node.total - self.store_node.dir_blocks

    def check_store(self, force=False):
        now = time.monotonic()
        if not force and now - self.polled < STORE_POLL_SECONDS:
            return
        self.polled = now
        signature = self.store_signature()
        if signature == self.signature and now - self.roots_checked < ROOTS_SECONDS:
            return
        known = set(self.index.nar)
        self.index.refresh()
        self.signature = signature
        self.roots_checked = now
        self.fresh.extend(path for path in self.index.nar if path not in known)
        if self.index.nar.keys() != known:
            for child in self.tree.scan(self.store_node):
                self.tree.walk(child)
        self.view = None

    def scan_fresh(self):
        if not self.fresh:
            return
        wanted = [path for path in self.fresh if path in self.index.nar]
        done, _ = self.index.scan(SCAN_SECONDS, wanted=wanted)
        self.fresh = [path for path in wanted if path not in self.index.disk]
        if done:
            self.view = None

    def store_view(self):
        index, home, retention = self.index, self.home, self.retention
        gcroot_targets = [resolve(os.path.join("/nix/var/nix/gcroots/auto", name)) for name in os.listdir("/nix/var/nix/gcroots/auto")]
        system_links = glob.glob("/nix/var/nix/profiles/system-*-link")
        home_links = glob.glob(str(home / ".local/state/nix/profiles/home-manager-*-link"))
        good_boot = "/nix/var/nix/gcroots/previous-successful-boot"
        if os.path.islink(good_boot):
            system_links.append(good_boot)
        system_generations = closure(resolve(link) for link in system_links)
        home_generations = closure(resolve(link) for link in home_links)
        generations = system_generations | home_generations
        system = closure([resolve("/run/current-system")])
        home_generation = closure([resolve(home / ".local/state/nix/profiles/home-manager")])
        roots = closure(gcroot_targets + [resolve("/run/booted-system")]) | generations | system
        deploy_links = glob.glob(str(home / ".local/state/rebuild/roots/*"))
        deployed = closure(resolve(link) for link in deploy_links)
        shell_links = [link for link in glob.glob("/run/user/*/nix-shell-roots/*/*") if os.path.islink(link)]
        shells = closure(resolve(link) for link in shell_links)
        projects = retention.discover_projects(Path("/nix/var/nix/gcroots/auto"))
        for project in projects.values():
            project.closure = index.closure(project.store_paths)
        project_union = set().union(*(project.closure for project in projects.values())) if projects else set()
        sizes = index.sizes("share")
        for path in roots | project_union:
            sizes.setdefault(path, 0)
        store = {segment: 0 for segment in SEGMENTS}
        members = {segment: set() for segment in SEGMENTS}
        assigned = set()

        def add(segment, paths):
            new = paths - assigned
            assigned.update(new)
            members[segment].update(new)
            store[segment] += sum(sizes.get(path, 0) for path in new)

        add("system", system)
        add("home", home_generation - system)
        add("system_generations", system_generations - system - home_generation)
        add("home_generations", home_generations - system - home_generation)
        for path in project_union:
            if path not in assigned:
                add({1: "project_tier1", 2: "project_tier2", 3: "fetched"}[retention.tier_of(path)], {path})
        add("deployed", deployed)
        add("shells", shells)
        add("garbage", set(index.dead))
        before_other = set(assigned)
        add("other", set(sizes) - assigned)
        largest_other = sorted(set(sizes) - before_other, key=lambda path: -sizes.get(path, 0))[:12]
        generation_closure = {}

        def closure_of(target):
            if target not in generation_closure:
                generation_closure[target] = closure([target])
            return generation_closure[target]

        def member_size(link, segment):
            return sum(sizes.get(item, 0) for item in closure_of(resolve(link)) if item in members[segment])

        generation_links = system_links + home_links
        generation_list = generation_rows(generation_links, lambda link: member_size(link, "system_generations" if link in system_links else "home_generations"))
        kept = closure(resolve(row["path"]) for row in generation_list if not row["expiring"])
        return {
            "store": store,
            "members": members,
            "sizes": sizes,
            "projects": projects,
            "generations": generation_list,
            "expiring": {segment: sum(sizes.get(path, 0) for path in members[segment] if path not in kept) for segment in ("system_generations", "home_generations")},
            "deployed": [{"path": link, "size": member_size(link, "deployed"), "last_used": int(os.lstat(link).st_mtime)} for link in sorted(deploy_links) if os.path.lexists(link)],
            "shells": [{"path": link, "size": member_size(link, "shells"), "last_used": int(os.lstat(link).st_mtime)} for link in sorted(shell_links) if os.path.lexists(link)],
            "other": [{"path": path, "size": sizes.get(path, 0), "last_used": 0, "roots": roots_of(index, path)} for path in largest_other],
            "listed": False,
        }

    def poll_du(self, now):
        if self.du is not None:
            if self.du.poll() is None:
                return
            out = self.du.stdout.read()
            self.du = None
            self.tree.settle(time.monotonic() + 5, force=True)
            if out:
                measured = int(out.split()[0])
                registered = measured - self.inside_store() - self.building()
                if self.index.coverage() < 0.99:
                    self.index.calibrate(registered)
                self.index.reconcile(sum(self.index.sizes("share").values()) - registered)
                self.du_state = {"at": now, "bytes": measured}
                self.du_path.write_text(json.dumps(self.du_state))
            fcntl.flock(self.lock, fcntl.LOCK_UN)
            self.view = None
            self.mismatch_since = None
            return
        age = now - self.du_state["at"]
        mismatched = self.mismatch_since is not None and now - self.mismatch_since >= MISMATCH_SECONDS
        if age >= STORE_DU_SECONDS or not self.index.reconciled() or (mismatched and age >= FORCED_DU_SECONDS):
            try:
                fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return
            self.du = subprocess.Popen(["du", "-sx", "--block-size=1", "/nix/store"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)

    def cached_internals(self, now):
        value, at = self.internals
        if now - at >= INTERNALS_SECONDS:
            self.internals = (hidden_inodes("/"), now)
        return self.internals[0]

    def cached_xattr(self, now, members):
        extra, at, dirs = self.xattr
        if now - at < XATTR_SECONDS:
            return extra
        found = self.tree.acl_dirs()
        if found != dirs or now - at >= XATTR_SECONDS:
            extra = shared_xattr_blocks(found, members, self.source, os.statvfs("/").f_bsize)
        self.xattr = (extra, now, found)
        return extra

    def cached_scratch(self, now, need):
        plan, at, planned = self.scratch
        if plan is None or now - at >= PLAN_SECONDS or abs(need - planned) >= GIB:
            self.scratch = (scratch_plan(need), now, need)
        return self.scratch[0]

    def cached_offload(self, now, sizes):
        if not self.offload_root:
            return None
        segment, at = self.offload
        if now - at >= OFFLOAD_SECONDS:
            self.offload = (offload_segment(Path(self.offload_root), sizes), now)
        return self.offload[0]

    def listing(self, name, rows):
        path = self.runtime / name
        text = "".join(json.dumps(row, separators=(",", ":")) + "\n" for row in rows)
        if self.written.get(name) != text or not path.exists():
            temporary = path.with_suffix(".tmp")
            temporary.write_text(text)
            os.chown(temporary, self.owner, -1)
            temporary.replace(path)
            self.written[name] = text
        return str(path)

    def children(self, root, skip, extra):
        node = self.tree.find(str(root))
        rows = []
        for name, child in node.children.items():
            if name in skip:
                continue
            path = os.path.join(str(root), name)
            rows.append({"path": path, "size": child.total - extra.get(path, 0), "last_used": child.newest})
        return node, rows

    def due(self, now):
        if now - self.published >= QUIET_SECONDS:
            return True
        if now - self.published < PUBLISH_SECONDS:
            return False
        used = shutil.disk_usage("/").used
        return self.view is None or self.published_used is None or abs(used - self.published_used) >= 1024**2 or self.tree.root.total != self.published_total

    def publish(self):
        now = int(time.time())
        self.check_store(force=True)
        opened = shutil.disk_usage("/nix/store")
        self.tree.settle(time.monotonic() + 5, force=True)
        if self.view is None:
            self.view = self.store_view()
        view = self.view
        index, home, retention = self.index, self.home, self.retention
        sizes = view["sizes"]
        target = int(os.environ["LEDGER_TARGET_BYTES"])
        try:
            target = int(float(Path(os.environ["LEDGER_TARGET_FILE"]).read_text().strip()) * GIB)
        except (OSError, ValueError, KeyError):
            pass

        drift = index.drift()
        store = dict(view["store"])
        building = self.building()
        nix = self.tree.find("/nix")
        store["building"] = building
        store["metadata"] = nix.total - building + blocks("/nix/store/.links")
        store["rescan"] = max(0, -drift)
        store_disk = sum(store.values())

        home_node = self.tree.find(str(home))
        system_skip = {"nix", "home"}
        members = [os.path.join(str(home), name) for name in home_node.children] + [os.path.join("/", name) for name in self.tree.root.children if name not in system_skip]
        extra = self.cached_xattr(now, members)
        _, home_dirs = self.children(home, {".cache"}, extra)
        home_dirs.append({"path": f"{home}/*", "size": home_node.own, "last_used": home_node.own_newest})
        home_dirs.sort(key=lambda row: -row["size"])
        cache_node = home_node.children.get(".cache")
        cache_path = str(home / ".cache")
        caches = cache_node.total - extra.get(cache_path, 0) if cache_node else 0
        home_parent = self.tree.find(str(home.parent))
        files = {"home": sum(row["size"] for row in home_dirs) + home_parent.total - home_node.total, "caches": caches}
        swap = blocks("/swapfile")
        covered = covered_mountpoints("/")
        _, system_dirs = self.children(Path("/"), system_skip, extra)
        system_dirs.append({"path": "/*", "size": self.tree.root.own - swap, "last_used": self.tree.root.own_newest})
        system_dirs.sort(key=lambda row: -row["size"])
        system_dirs += [
            {"path": "filesystem internals", "size": self.cached_internals(now), "last_used": 0, "kind": "ext4 orphan file, quota inodes, journal and resize index blocks", "leaf": True},
            {"path": "mountpoints", "size": 4096 * len(covered), "last_used": 0, "kind": f"directories under {len(covered)} mounts", "leaf": True},
        ]
        system_files = sum(row["size"] for row in system_dirs)
        base = store_disk + sum(files.values()) + swap + system_files - max(0, drift)
        usage = shutil.disk_usage("/nix/store")
        held, held_at = self.held
        if time.monotonic() - held_at >= HELD_SECONDS or abs(usage.used - base - sum(row["size"] for row in held)) >= 1024**2:
            held = held_open(self.device)
            self.held = (held, time.monotonic())
        held_bytes = sum(row["size"] for row in held)
        accounted = base + held_bytes
        low, high = min(opened.used, usage.used), max(opened.used, usage.used)
        settled = min(max(accounted, low), high)
        measuring = usage.used - settled
        unaccounted = settled - accounted
        if abs(unaccounted) < MISMATCH_BYTES:
            self.mismatch_since = None
        elif self.mismatch_since is None:
            self.mismatch_since = time.monotonic()

        free = usage.free
        reserved = usage.total - usage.used - free
        deficit = max(0, target - free)
        need = deficit + SLACK_BYTES if deficit else PREVIEW_BYTES
        scratch = self.cached_scratch(time.monotonic(), need)
        key = (need // NEED_STEP, deficit // NEED_STEP, id(scratch))
        if view.get("plan_key") != key:
            evictions, _, project_freed = retention.plan(view["projects"], sizes, now, 0, None, need)
            project_plan = {"selected": retention.eviction_rows(evictions), "freed": project_freed}
            dead_plan = store_plan(self.collector, index, need)
            rows, cut = queue([("scratch", scratch), ("projects", project_plan), ("store", dead_plan)], deficit)
            view.update(plan_key=key, plan=(rows, cut, dead_plan["largest"], self.listing("disk-queue.jsonl", rows)))
        rows, cut, largest_dead, queue_file = view["plan"]

        def path_row(path):
            return {"path": path, "size": sizes.get(path, 0), "last_used": index.used.get(path, 0)}

        self.runtime.mkdir(parents=True, exist_ok=True)
        if not view["listed"]:
            for segment in ("system", "home", "system_generations", "home_generations", "deployed", "shells", "other"):
                self.listing(f"disk-segment-{segment}.jsonl", [path_row(path) for path in sorted(view["members"][segment])])
            self.listing("disk-dead.jsonl", [{**path_row(path), "last_used": index.effective.get(path, 0)} for path in index.dead])
            view["project_rows"] = project_rows(view["projects"], sizes, retention, path_row, self.listing, view["members"]["project_tier1"] | view["members"]["project_tier2"] | view["members"]["fetched"])
            view["listed"] = True

        store_node = self.store_node
        building_rows = [{"path": f"/nix/store/{name}", "size": child.total, "last_used": child.newest} for name, child in store_node.children.items()]
        if store_node.own - store_node.dir_blocks:
            building_rows.append({"path": "/nix/store/*", "size": store_node.own - store_node.dir_blocks, "last_used": store_node.own_newest})
        ledger = {
            "at": now,
            "store": store,
            "store_disk": dict(store),
            "files": files,
            "swap": swap,
            "system_files": system_files,
            "held": held_bytes,
            "unaccounted": unaccounted,
            "measuring": measuring,
            "churn": usage.used - opened.used,
            "reserved": reserved,
            "disk": {"total": usage.total, "used": usage.used, "free": free, "reserved": reserved},
            "free": free,
            "target": target,
            "tracker": {"directories": len(self.tree.keys), "events": self.tree.events, "walk_seconds": round(self.tree.walk_seconds, 2), "verify_pass_seconds": round(self.tree.pass_seconds, 1), "store_du_at": self.du_state["at"], "store_du_running": self.du is not None},
            "provenance": {
                "generations": view["generations"],
                "expiring": view["expiring"],
                "deployed": view["deployed"],
                "projects": view["project_rows"],
                "home": home_dirs,
                "caches": [{"path": os.path.join(cache_path, name), "size": child.total, "last_used": child.newest} for name, child in sorted(cache_node.children.items())] if cache_node else [],
                "other": view["other"],
                "shells": view["shells"],
                "system": system_dirs,
                "building": sorted(building_rows, key=lambda row: -row["size"])[:200],
                "held": held,
            },
            "deficit": deficit,
            "need": need,
            "queue": rows[: max(cut + 1, 1)],
            "queue_file": queue_file,
            "cut": cut,
            "largest_dead": largest_dead,
            "history": [],
            "events": load_events(self.state / "events.jsonl"),
        }
        items = {}
        for name, group in ledger["provenance"].items():
            if not isinstance(group, list):
                continue
            for row in group:
                if row.get("path") and row.get("size"):
                    items.setdefault(name, {})[row["path"]] = row["size"]
        point = {"at": now, "store": dict(store), "files": files, "swap": swap, "system": system_files, "held": held_bytes, "measuring": measuring, "unaccounted": unaccounted, "reserved": reserved, "free": free, "items": items}
        persisted = [old for old in self.points if old.get("persisted", True)]
        if not persisted or now - persisted[-1].get("at", 0) >= HISTORY_SECONDS:
            append_history(self.state / "history.jsonl", persisted, point)
            self.points = persisted
        else:
            self.points = persisted + [{**point, "persisted": False}]
        self.points = [old for old in self.points if old.get("at", 0) >= now - HISTORY_DAYS * DAY]
        sampled = downsample(self.points)
        write_json(self.runtime / "disk-history-items.json", {str(old["at"]): old.get("items", {}) for old in sampled}, owner=self.owner)
        ledger["history"] = [{key: value for key, value in old.items() if key not in ("items", "persisted")} for old in sampled]
        if scratch and scratch.get("error"):
            ledger["scratch_error"] = scratch["error"]
        offload = self.cached_offload(now, sizes)
        if offload is not None:
            ledger["offload"] = offload
        write_json(self.runtime / "disk-ledger.json", ledger, owner=self.owner)
        if self.textfile.parent.is_dir():
            write_textfile(self.textfile, ledger)
        self.published = time.monotonic()
        self.published_used = usage.used
        self.published_total = self.tree.root.total

    def run(self):
        while True:
            started = time.monotonic()
            self.tree.wait(1.0)
            time.sleep(max(0.0, started + TICK_SECONDS - time.monotonic()))
            self.tree.drain()
            now = time.monotonic()
            self.tree.settle(now + SETTLE_SECONDS)
            self.check_store()
            self.scan_fresh()
            if self.du is not None or now - self.du_polled >= DU_POLL_SECONDS:
                self.du_polled = now
                self.poll_du(int(time.time()))
            if now - self.verified_at >= 1.0:
                self.tree.verify(time.monotonic() + VERIFY_SECONDS)
                self.verified_at = now
            if self.due(time.monotonic()):
                self.publish()


if __name__ == "__main__":
    Ledger().run()
