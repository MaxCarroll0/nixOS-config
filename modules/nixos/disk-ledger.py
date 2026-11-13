import glob
import importlib.util
import json
import os
import shutil
import subprocess
import time
from pathlib import Path


GIB = 1024**3


def load_retention():
    spec = importlib.util.spec_from_file_location("retention", os.environ["RETENTION_MODULE"])
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


def all_sizes():
    output = subprocess.run(
        ["nix", "path-info", "--all", "--json", "--json-format", "1"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return {path: info["narSize"] for path, info in json.loads(output).items() if info}


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


def free_bytes():
    return shutil.disk_usage("/nix/store").free


def main():
    retention = load_retention()
    home = Path(os.environ["LEDGER_HOME"])
    target = int(os.environ["LEDGER_TARGET_BYTES"])
    runtime = Path(os.environ["LEDGER_RUNTIME_DIR"])
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
    sizes = all_sizes()
    for path in roots | project_union:
        sizes.setdefault(path, 0)

    store = {
        "system": 0,
        "home": 0,
        "generations": 0,
        "project_tier1": 0,
        "project_tier2": 0,
        "fetched": 0,
        "garbage": 0,
    }
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
        tier = retention.tier_of(path)
        segment = {1: "project_tier1", 2: "project_tier2", 3: "fetched"}[tier]
        add(segment, {path})
    store["garbage"] = sum(size for path, size in sizes.items() if path not in roots and path not in project_union)

    files = {
        "videos": du(home / "Videos"),
        "downloads": du(home / "Downloads"),
        "cache": du(home / ".cache"),
        "local_share": du(home / ".local/share"),
    }

    ledger = {
        "at": int(time.time()),
        "store": store,
        "files": files,
        "free": free_bytes(),
        "target": target,
    }
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
    temporary.write_text(json.dumps(ledger, indent=2) + "\n")
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
