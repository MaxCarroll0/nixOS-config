import collections
import glob
import re
import importlib.util
import json
import os
import shutil
import subprocess
import time
from pathlib import Path


GIB = 1024**3
DAY = 86400
HISTORY_DAYS = 30
HISTORY_POINTS = 288
PREVIEW_BYTES = 10 * GIB
SLACK_BYTES = GIB // 2
KEEP_GENERATIONS = 10
SEGMENTS = ("system", "home", "system_generations", "home_generations", "project_tier1", "project_tier2", "fetched", "deployed", "shells", "other", "garbage", "metadata", "rescan")


def load_module(name, variable):
    spec = importlib.util.spec_from_file_location(name, os.environ[variable])
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


INDEX = []


def closure(paths):
    return INDEX[0].closure(path for path in paths if path.startswith("/nix/store/"))


def store_metadata():
    return var_bytes() + inside_store_metadata()


def inside_store_metadata():
    links = os.lstat("/nix/store/.links").st_blocks * 512 if os.path.isdir("/nix/store/.links") else 0
    return links + os.lstat("/nix/store").st_blocks * 512


def var_bytes():
    total = 0
    for root, dirs, files in os.walk("/nix/var"):
        for name in dirs + files:
            try:
                total += os.lstat(os.path.join(root, name)).st_blocks * 512
            except OSError:
                continue
    return total


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


def disk_bytes(path):
    out = subprocess.run(["du", "-sx", "--block-size=1", path], capture_output=True, text=True).stdout
    return int(out.split()[0]) if out else 0


def measured_bytes(path, cache, now, max_age):
    try:
        entry = json.loads(cache.read_text())
        if now - entry["at"] < max_age:
            return entry["bytes"], False
    except (OSError, ValueError, KeyError):
        pass
    size = disk_bytes(path)
    cache.parent.mkdir(parents=True, exist_ok=True)
    cache.write_text(json.dumps({"at": now, "bytes": size}))
    return size, True


def held_open(device):
    owners = {}
    for fd in glob.glob("/proc/[0-9]*/fd/*"):
        try:
            target = os.readlink(fd)
            if not target.endswith(" (deleted)"):
                continue
            stat = os.stat(fd)
        except OSError:
            continue
        if stat.st_dev != device or not os.path.stat.S_ISREG(stat.st_mode):
            continue
        pid = fd.split("/")[2]
        try:
            command = open(f"/proc/{pid}/comm").read().strip()
        except OSError:
            command = pid
        row = owners.setdefault(stat.st_ino, {"path": target[: -len(" (deleted)")], "size": stat.st_blocks * 512, "last_used": int(stat.st_mtime), "holders": set()})
        row["holders"].add(command)
    return sorted(({**row, "holders": sorted(row["holders"])} for row in owners.values() if row["size"]), key=lambda row: -row["size"])


def entries(root, skip):
    device = os.lstat(root).st_dev
    return [entry for entry in sorted(root.iterdir()) if entry.name not in skip and os.lstat(entry).st_dev == device]


def usage_once(paths):
    out = subprocess.run(["du", "-sx", "--time", "--time-style=+%s", "--block-size=1", "--", *map(str, paths)], capture_output=True, text=True).stdout
    usage = {}
    for line in out.splitlines():
        size, newest, path = line.split("\t", 2)
        usage[path] = (int(size), int(newest))
    return usage


def top_level_sizes(root, members, usage):
    rows = []
    loose = os.lstat(root).st_blocks * 512
    newest = int(root.lstat().st_mtime)
    for entry in members:
        size, last = usage.get(str(entry), (0, 0))
        if entry.is_symlink() or not entry.is_dir():
            loose += size
            newest = max(newest, last)
            continue
        rows.append({"path": str(entry), "size": size, "last_used": last or int(entry.lstat().st_mtime)})
    rows.append({"path": f"{root}/*", "size": loose, "last_used": newest})
    return sorted(rows, key=lambda row: -row["size"])


def other_rows(paths, sizes):
    largest = sorted(paths, key=lambda path: -sizes.get(path, 0))[:12]
    rows = []
    for path in largest:
        rows.append({"path": path, "size": sizes.get(path, 0), "last_used": 0, "roots": root_links(path)[:6]})
    return rows


def root_links(path):
    out = subprocess.run(["nix-store", "--query", "--roots", path], capture_output=True, text=True).stdout
    links = []
    for line in out.splitlines():
        link = line.split(" -> ")[0].strip()
        if link and not link.startswith("{") and link not in links:
            links.append(link)
    return links


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


def main():
    now = int(time.time())
    retention = load_module("retention", "RETENTION_MODULE")
    collector = load_module("collector", "COLLECT_MODULE")
    home = Path(os.environ["LEDGER_HOME"])
    target = int(os.environ["LEDGER_TARGET_BYTES"])
    try:
        target = int(float(Path(os.environ["LEDGER_TARGET_FILE"]).read_text().strip()) * GIB)
    except (OSError, ValueError, KeyError):
        pass
    runtime = Path(os.environ["LEDGER_RUNTIME_DIR"])
    textfile = Path(os.environ["LEDGER_TEXTFILE"])

    index = collector.Index().refresh()
    INDEX.append(index)
    gcroot_targets = [
        resolve(os.path.join("/nix/var/nix/gcroots/auto", name))
        for name in os.listdir("/nix/var/nix/gcroots/auto")
    ]
    system_links = glob.glob("/nix/var/nix/profiles/system-*-link")
    home_links = glob.glob(str(home / ".local/state/nix/profiles/home-manager-*-link"))
    good_boot = "/nix/var/nix/gcroots/previous-successful-boot"
    if os.path.islink(good_boot):
        system_links.append(good_boot)
    generation_links = system_links + home_links
    system_generations = closure(resolve(link) for link in system_links)
    home_generations = closure(resolve(link) for link in home_links)
    generations = system_generations | home_generations
    system = closure([resolve("/run/current-system")])
    home_generation = closure([resolve(home / ".local/state/nix/profiles/home-manager")])
    roots = closure(gcroot_targets + [resolve("/run/booted-system")]) | generations | system
    deploy_links = glob.glob(str(home / ".local/state/rebuild/roots/*"))
    deployed = closure(resolve(link) for link in deploy_links)
    shell_links = glob.glob("/run/user/*/nix-shell-roots/*/*")
    shells = closure(resolve(link) for link in shell_links)

    projects = retention.discover_projects(Path("/nix/var/nix/gcroots/auto"))
    retention.populate_closures(projects)
    project_union = set().union(*(p.closure for p in projects.values())) if projects else set()
    state = Path(os.environ["LEDGER_STATE_DIR"])
    metadata = store_metadata()
    measured, fresh = measured_bytes("/nix/store", state / "store-du.json", now, 6 * 3600 if index.reconciled() else 0)
    if index.coverage() < 0.99:
        index.calibrate(measured - inside_store_metadata())
    sizes = index.sizes("share")
    if fresh:
        index.reconcile(sum(sizes.values()) - (measured - inside_store_metadata()))
    drift = index.drift()
    for path in roots | project_union:
        sizes.setdefault(path, 0)
    dead = list(index.dead)
    dead_set = set(dead)

    store = {segment: 0 for segment in SEGMENTS}
    assigned = set()

    members = {segment: set() for segment in SEGMENTS}

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
        if path in assigned:
            continue
        segment = {1: "project_tier1", 2: "project_tier2", 3: "fetched"}[retention.tier_of(path)]
        add(segment, {path})
    add("deployed", deployed)
    add("shells", shells)
    add("garbage", dead_set)
    assigned_before_other = set(assigned)
    add("other", set(sizes) - assigned)
    store["metadata"] = metadata
    store["rescan"] = max(0, -drift)

    usage = shutil.disk_usage("/nix/store")
    store_disk = sum(store.values())
    store_disk_segments = dict(store)
    home_members = entries(home, {".cache"})
    system_members = entries(Path("/"), {"nix", "home", "swapfile"})
    swapfile = [Path("/swapfile")] if os.path.exists("/swapfile") else []
    caches_dir = [home / ".cache"] if (home / ".cache").is_dir() else []
    usage_all = usage_once(home_members + caches_dir + system_members + swapfile)
    home_dirs = top_level_sizes(home, home_members, usage_all)
    caches = sum(usage_all.get(str(path), (0, 0))[0] for path in caches_dir)
    files = {"home": sum(row["size"] for row in home_dirs) + os.lstat(home.parent).st_blocks * 512, "caches": caches}
    swap = usage_all.get("/swapfile", (0, 0))[0]
    system_dirs = top_level_sizes(Path("/"), system_members, usage_all)
    held = held_open(os.stat("/").st_dev)
    held_bytes = sum(row["size"] for row in held)
    system_files = sum(row["size"] for row in system_dirs)
    accounted = store_disk + sum(files.values()) + swap + system_files + held_bytes - max(0, drift)
    unaccounted = usage.used - accounted

    free = usage.free
    reserved = usage.total - usage.used - free
    deficit = max(0, target - free)
    need = deficit + SLACK_BYTES if deficit else PREVIEW_BYTES

    scratch = scratch_plan(need)
    evictions, _, project_freed = retention.plan(projects, sizes, now, 0, None, need)
    project_plan = {"selected": retention.eviction_rows(evictions), "freed": project_freed}
    dead_plan = store_plan(collector, index, need)
    rows, cut = queue([("scratch", scratch), ("projects", project_plan), ("store", dead_plan)], deficit)

    generation_closure = {}

    def closure_of(target):
        if target not in generation_closure:
            generation_closure[target] = closure([target])
        return generation_closure[target]

    def path_row(path):
        return {"path": path, "size": sizes.get(path, 0), "last_used": index.used.get(path, 0)}

    def member_size(link, segment):
        return sum(sizes.get(item, 0) for item in closure_of(resolve(link)) if item in members[segment])

    runtime.mkdir(parents=True, exist_ok=True)
    owner = int(os.environ["LEDGER_UID"])

    def listing(name, rows):
        write_lines(runtime / name, rows, owner)
        return str(runtime / name)

    for segment in ("system", "home", "system_generations", "home_generations", "deployed", "shells", "other"):
        listing(f"disk-segment-{segment}.jsonl", [path_row(path) for path in sorted(members[segment])])
    generations = generation_rows(generation_links, lambda link: member_size(link, "system_generations" if link in system_links else "home_generations"))
    kept = closure(resolve(row["path"]) for row in generations if not row["expiring"])
    expiring = {
        segment: sum(sizes.get(path, 0) for path in members[segment] if path not in kept)
        for segment in ("system_generations", "home_generations")
    }
    listing("disk-dead.jsonl", [{**path_row(path), "last_used": index.effective.get(path, 0)} for path in dead])

    ledger = {
        "at": now,
        "store": store,
        "store_disk": store_disk_segments,
        "files": files,
        "swap": swap,
        "system_files": system_files,
        "held": held_bytes,
        "unaccounted": unaccounted,
        "reserved": reserved,
        "disk": {"total": usage.total, "used": usage.used, "free": free, "reserved": reserved},
        "free": free,
        "target": target,
        "provenance": {
            "generations": generations,
            "expiring": expiring,
            "deployed": [{"path": link, "size": member_size(link, "deployed"), "last_used": int(os.lstat(link).st_mtime)} for link in sorted(deploy_links)],
            "projects": project_rows(projects, sizes, retention, path_row, listing, members["project_tier1"] | members["project_tier2"] | members["fetched"]),
            "home": home_dirs,
            "caches": [{"path": str(home / ".cache" / entry.name), "size": disk_bytes(home / ".cache" / entry.name), "last_used": int(entry.lstat().st_mtime)} for entry in sorted((home / ".cache").iterdir(), key=lambda e: e.name) if entry.is_dir() and not entry.is_symlink()] if (home / ".cache").is_dir() else [],
            "other": other_rows(set(sizes) - assigned_before_other, sizes),
            "shells": [{"path": link, "size": member_size(link, "shells"), "last_used": int(os.lstat(link).st_mtime)} for link in sorted(shell_links) if os.path.islink(link)],
            "system": system_dirs,
            "held": held,
        },
        "deficit": deficit,
        "need": need,
        "queue": rows,
        "cut": cut,
        "largest_dead": dead_plan["largest"],
        "history": [],
        "events": load_events(state / "events.jsonl"),
    }
    history_path = state / "history.jsonl"
    points = load_history(history_path, now)
    items = {}
    for group in ledger["provenance"].values():
        if not isinstance(group, list):
            continue
        for row in group:
            if row.get("path") and row.get("size"):
                items[row["path"]] = row["size"]
    point = {"at": now, "store": store_disk_segments, "files": files, "swap": swap, "system": system_files, "held": held_bytes, "unaccounted": unaccounted, "reserved": reserved, "free": free, "items": items}

    append_history(history_path, points, point)
    ledger["history"] = downsample(points)
    if scratch and scratch.get("error"):
        ledger["scratch_error"] = scratch["error"]
    offload_root = os.environ.get("LEDGER_OFFLOAD_DIR", "")
    if offload_root:
        segment = offload_segment(Path(offload_root), sizes)
        if segment is not None:
            ledger["offload"] = segment

    write_json(runtime / "disk-ledger.json", ledger, owner=owner)
    if textfile.parent.is_dir():
        write_textfile(textfile, ledger)


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


if __name__ == "__main__":
    main()
