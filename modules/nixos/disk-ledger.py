import collections
import glob
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
SLACK_BYTES = 5 * GIB
SEGMENTS = ("system", "home", "generations", "project_tier1", "project_tier2", "fetched", "other", "garbage")


def load_module(name, variable):
    spec = importlib.util.spec_from_file_location(name, os.environ[variable])
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def closure(paths):
    paths = sorted({path for path in paths if path.startswith("/nix/store/")})
    if not paths:
        return set()
    return set(
        subprocess.run(
            ["nix-store", "--query", "--requisites", *paths],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.split()
    )


def all_path_info():
    output = subprocess.run(
        ["nix", "path-info", "--all", "--json", "--json-format", "1"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return {path: info for path, info in json.loads(output).items() if info}


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


def store_plan(collector, dead, info, need):
    _, chosen, freed = collector.select(dead, info, need)
    buckets = collections.OrderedDict()
    for row in collector.rows(chosen, info):
        day = time.strftime("%Y-%m-%d", time.localtime(row["last_used"]))
        bucket = buckets.setdefault(day, {"path": "", "kind": "dead paths", "size": 0, "count": 0, "last_used": row["last_used"]})
        bucket["size"] += row["size"]
        bucket["count"] += 1
        bucket["last_used"] = max(bucket["last_used"], row["last_used"])
    rows = []
    for day, bucket in buckets.items():
        bucket["path"] = f"{bucket['count']} store paths last used {day}"
        rows.append(bucket)
    largest = sorted(collector.rows(chosen, info), key=lambda row: -row["size"])[:10]
    return {"selected": rows, "freed": freed, "largest": largest}


def queue(stages, deficit):
    rows = []
    cumulative = 0
    cut = -1
    for stage, plan in stages:
        if plan is None:
            continue
        for row in plan["selected"]:
            cumulative += row["size"]
            rows.append({**row, "stage": stage, "cumulative": cumulative})
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


def free_bytes():
    return shutil.disk_usage("/nix/store").free


def main():
    now = int(time.time())
    retention = load_module("retention", "RETENTION_MODULE")
    collector = load_module("collector", "COLLECT_MODULE")
    home = Path(os.environ["LEDGER_HOME"])
    target = int(os.environ["LEDGER_TARGET_BYTES"])
    max_freed = int(os.environ["LEDGER_MAX_FREED_BYTES"])
    runtime = Path(os.environ["LEDGER_RUNTIME_DIR"])
    state = Path(os.environ["LEDGER_STATE_DIR"])
    textfile = Path(os.environ["LEDGER_TEXTFILE"])

    gcroot_targets = [
        resolve(os.path.join("/nix/var/nix/gcroots/auto", name))
        for name in os.listdir("/nix/var/nix/gcroots/auto")
    ]
    generation_links = glob.glob("/nix/var/nix/profiles/system-*-link") + glob.glob(
        str(home / ".local/state/nix/profiles/home-manager-*-link")
    )
    generations = closure(resolve(link) for link in generation_links)
    system = closure([resolve("/run/current-system")])
    home_generation = closure([resolve(home / ".local/state/nix/profiles/home-manager")])
    roots = closure(gcroot_targets + [resolve("/run/booted-system")]) | generations | system

    projects = retention.discover_projects(Path("/nix/var/nix/gcroots/auto"))
    retention.populate_closures(projects)
    project_union = set().union(*(p.closure for p in projects.values())) if projects else set()
    info = all_path_info()
    sizes = {path: entry.get("narSize", 0) for path, entry in info.items()}
    for path in roots | project_union:
        sizes.setdefault(path, 0)
    dead = [path for path in collector.dead_paths() if path in info]
    dead_set = set(dead)

    store = {segment: 0 for segment in SEGMENTS}
    assigned = set()

    def add(segment, paths):
        new = paths - assigned
        assigned.update(new)
        store[segment] += sum(sizes.get(path, 0) for path in new)

    add("system", system)
    add("home", home_generation - system)
    add("generations", generations - system - home_generation)
    for path in project_union:
        if path in assigned:
            continue
        segment = {1: "project_tier1", 2: "project_tier2", 3: "fetched"}[retention.tier_of(path)]
        add(segment, {path})
    add("garbage", dead_set)
    add("other", set(sizes) - assigned)

    files = {
        "videos": du(home / "Videos"),
        "downloads": du(home / "Downloads"),
        "cache": du(home / ".cache"),
        "local_share": du(home / ".local/share"),
    }

    free = free_bytes()
    deficit = max(0, target - free)
    need = min(max_freed, deficit + SLACK_BYTES if deficit else PREVIEW_BYTES)

    scratch = scratch_plan(need)
    remaining = max(0, need - (scratch or {}).get("freed", 0))
    evictions, _, project_freed = retention.plan(projects, sizes, now, 0, None, remaining) if remaining else ([], 0, 0)
    project_rows = {"selected": retention.eviction_rows(evictions), "freed": project_freed}
    remaining = max(0, remaining - project_freed)
    dead_plan = store_plan(collector, dead, info, remaining) if remaining else {"selected": [], "freed": 0, "largest": []}
    rows, cut = queue([("scratch", scratch), ("projects", project_rows), ("store", dead_plan)], deficit)

    history_path = state / "history.jsonl"
    points = load_history(history_path, now)
    point = {"at": now, "store": store, "files": sum(files.values()), "free": free}
    append_history(history_path, points, point)

    ledger = {
        "at": now,
        "store": store,
        "files": files,
        "free": free,
        "target": target,
        "deficit": deficit,
        "need": need,
        "queue": rows,
        "cut": cut,
        "largest_dead": dead_plan["largest"],
        "history": downsample(points),
        "events": load_events(state / "events.jsonl"),
    }
    if scratch and scratch.get("error"):
        ledger["scratch_error"] = scratch["error"]
    offload_root = os.environ.get("LEDGER_OFFLOAD_DIR", "")
    if offload_root:
        segment = offload_segment(Path(offload_root), sizes)
        if segment is not None:
            ledger["offload"] = segment

    runtime.mkdir(parents=True, exist_ok=True)
    write_json(runtime / "disk-ledger.json", ledger, owner=int(os.environ["LEDGER_UID"]))
    if textfile.parent.is_dir():
        write_textfile(textfile, ledger)


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
    lines.append(f'node_disk_ledger_bytes{{section="disk",segment="target"}} {ledger["target"]}')
    temporary = path.with_suffix(".tmp")
    temporary.write_text("\n".join(lines) + "\n")
    temporary.replace(path)


if __name__ == "__main__":
    main()
