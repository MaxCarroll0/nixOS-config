import argparse
import collections
import concurrent.futures
import datetime
import json
import os
import re
import subprocess
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path


GIB = 1024**3
DAY = 24 * 60 * 60
RESULT_NAME = re.compile(r"result(?:-.+)?$")
EXPENSIVE = (
    "linux-",
    "emacs-",
    "ghc-",
    "llvm-",
    "clang-",
    "gcc-",
    "rustc-",
    "chromium-",
    "firefox-",
    "electron-",
    "qtwebengine-",
    "webkitgtk-",
)
FETCHED = re.compile(r"(?:^|-)source$|\.(?:tar(?:\.[a-z0-9]+)?|tgz|tbz2|txz|zip|crate|gem|whl)$|\.patch$")
TIERS = (1, 2, 3)


@dataclass
class Project:
    path: Path
    roots: list[Path] = field(default_factory=list)
    store_paths: list[str] = field(default_factory=list)
    last_used: float = 0
    last_built: float = 0
    closure: set[str] = field(default_factory=set)


def tier_of(store_path: str) -> int:
    name = os.path.basename(store_path).split("-", 1)[-1]
    if FETCHED.search(name):
        return 3
    if name.startswith(EXPENSIVE):
        return 2
    return 1


def tier_bytes(paths: set[str], sizes: dict[str, int]) -> dict[int, int]:
    totals = {tier: 0 for tier in TIERS}
    for path in paths:
        totals[tier_of(path)] += sizes[path]
    return totals


def project_for(root: Path) -> Path | None:
    marker = f"{os.sep}.direnv{os.sep}"
    root_string = str(root)
    if marker in root_string:
        return Path(root_string.split(marker, 1)[0])
    if RESULT_NAME.fullmatch(root.name):
        return root.parent
    for parent in (root.parent, *root.parent.parents):
        try:
            markers = (".git", ".envrc", "flake.nix")
            if any((parent / marker).exists() for marker in markers):
                return parent
        except OSError:
            continue
    return None


def discover_projects(gcroots: Path) -> dict[Path, Project]:
    projects: dict[Path, Project] = {}
    for automatic_root in gcroots.iterdir():
        if not automatic_root.is_symlink():
            continue
        target = Path(os.readlink(automatic_root))
        if not target.is_absolute():
            target = automatic_root.parent / target
        project_path = project_for(target)
        if project_path is None or not target.is_symlink():
            continue
        store_path = os.path.realpath(target)
        if not store_path.startswith("/nix/store/"):
            continue
        project = projects.setdefault(project_path, Project(project_path))
        project.roots.append(target)
        project.store_paths.append(store_path)
        link = target.lstat()
        used = [link.st_mtime, link.st_atime]
        try:
            used.append(os.stat(store_path).st_atime)
        except OSError:
            pass
        project.last_used = max(project.last_used, *used)
        project.last_built = max(project.last_built, link.st_mtime)
    return projects


def run(command: list[str]) -> str:
    return subprocess.run(
        command,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    ).stdout


def populate_closures(projects: dict[Path, Project]) -> None:
    def closure(project: Project) -> tuple[Path, set[str]]:
        output = run(["nix-store", "--query", "--requisites", *project.store_paths])
        return project.path, set(output.splitlines())

    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
        for path, paths in executor.map(closure, projects.values()):
            projects[path].closure = paths


def query_sizes(paths: set[str]) -> dict[str, int]:
    sizes: dict[str, int] = {}
    ordered = sorted(paths)
    for offset in range(0, len(ordered), 128):
        chunk = ordered[offset : offset + 128]
        output = run(["nix", "path-info", "--json", "--json-format", "1", *chunk])
        sizes.update({path: info["narSize"] for path, info in json.loads(output).items()})
    return sizes


def plan(
    projects: dict[Path, Project],
    sizes: dict[str, int],
    now: float,
    protect_days: int,
    budget_bytes: int | None,
    need_bytes: int | None,
) -> tuple[list[tuple[Project, dict[int, int]]], int, int]:
    references = collections.Counter(
        store_path for project in projects.values() for store_path in project.closure
    )
    retained = sum(sizes[path] for path in references)
    freed = 0
    remaining = dict(projects)
    floor = now - protect_days * DAY
    evictions: list[tuple[Project, dict[int, int]]] = []

    def exclusive(project: Project) -> dict[int, int]:
        totals = {tier: 0 for tier in TIERS}
        for store_path in project.closure:
            if references[store_path] == 1:
                totals[tier_of(store_path)] += sizes[store_path]
        return totals

    def satisfied() -> bool:
        within_budget = budget_bytes is None or retained <= budget_bytes
        enough_freed = need_bytes is None or freed >= need_bytes
        return within_budget and enough_freed

    while not satisfied():
        options = []
        for project in remaining.values():
            if project.last_used >= floor:
                continue
            totals = exclusive(project)
            if sum(totals.values()):
                options.append((project, totals))
        if not options:
            break
        victim, totals = max(
            options,
            key=lambda option: (
                int((now - option[0].last_used) // DAY),
                now - option[0].last_built,
                option[1][2] == 0,
                option[1][1] > 0,
                option[1][1] + option[1][3],
                str(option[0].path),
            ),
        )
        del remaining[victim.path]
        for store_path in victim.closure:
            references[store_path] -= 1
            if references[store_path] == 0:
                retained -= sizes[store_path]
                freed += sizes[store_path]
        evictions.append((victim, totals))

    return evictions, retained, freed


def angrr_config(roots: list[Path], protect_days: int) -> str:
    lines = [
        'store = "/nix/store"',
        'owned-only = "false"',
        "remove-root = false",
        'directory = ["/nix/var/nix/gcroots/auto"]',
    ]
    for index, root in enumerate(roots):
        lines.extend(
            [
                "",
                f"[temporary-root-policies.selected-{index}]",
                f"path-regex = {json.dumps('^' + re.escape(str(root)) + '$')}",
                f'period = "{protect_days}d"',
            ]
        )
    return "\n".join(lines) + "\n"


def remove_with_angrr(roots: list[Path], protect_days: int) -> None:
    with tempfile.NamedTemporaryFile(mode="w", suffix=".toml") as config:
        config.write(angrr_config(roots, protect_days))
        config.flush()
        subprocess.run(
            ["angrr", "--config", config.name, "run", "--no-prompt"],
            check=True,
        )


def format_size(size: int) -> str:
    return f"{size / GIB:.1f} GiB"


def format_tiers(totals: dict[int, int]) -> str:
    labels = {1: "cheap local", 2: "expensive local", 3: "fetched"}
    return "; ".join(f"{labels[tier]} {format_size(totals[tier])}" for tier in TIERS)


def self_test() -> None:
    now = 100 * DAY

    def project(name: str, days: float, paths: set[str]) -> Project:
        return Project(Path(name), last_used=now - days * DAY, closure=paths)

    sizes = {
        "/nix/store/aaa-foo": 10,
        "/nix/store/bbb-ghc-9.10": 100,
        "/nix/store/ccc-src.tar.gz": 30,
        "/nix/store/ddd-bar": 5,
    }
    assert tier_of("/nix/store/aaa-foo") == 1
    assert tier_of("/nix/store/bbb-ghc-9.10") == 2
    assert tier_of("/nix/store/ccc-src.tar.gz") == 3
    assert tier_of("/nix/store/eee-source") == 3

    def projects() -> dict[Path, Project]:
        built = [
            project("/p/cheap", 10, {"/nix/store/aaa-foo"}),
            project("/p/heavy", 11, {"/nix/store/bbb-ghc-9.10"}),
            project("/p/fetched", 12, {"/nix/store/ccc-src.tar.gz"}),
            project("/p/recent", 1, {"/nix/store/ddd-bar"}),
        ]
        return {item.path: item for item in built}

    names = lambda evictions: [victim.path.name for victim, _ in evictions]

    evictions, _, _ = plan(projects(), sizes, now, 3, 0, None)
    assert names(evictions) == ["cheap", "fetched", "heavy"], names(evictions)
    assert "recent" not in names(evictions)

    evictions, _, freed = plan(projects(), sizes, now, 3, None, 10)
    assert names(evictions) == ["cheap"] and freed == 10

    evictions, retained, _ = plan(projects(), sizes, now, 3, 110, None)
    assert names(evictions) == ["cheap", "fetched"], names(evictions)
    assert retained == 105

    evictions, _, freed = plan(projects(), sizes, now, 3, None, 10**12)
    assert freed == 140 and "recent" not in names(evictions)

    root = Path("/project/a/.direnv/flake-profile")
    config = angrr_config([root], 3)
    assert 'period = "3d"' in config
    assert f"path-regex = {json.dumps('^' + re.escape(str(root)) + '$')}" in config
    with tempfile.NamedTemporaryFile(mode="w", suffix=".toml") as config_file:
        config_file.write(config)
        config_file.flush()
        run(["angrr", "--config", config_file.name, "validate"])
    print("project-closure-retention self-test passed")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Retain project closures by tier, against a byte budget or a free-space need"
    )
    parser.add_argument("--apply", action="store_true", help="ask angrr to remove selected roots")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--gcroots", type=Path, default=Path("/nix/var/nix/gcroots/auto"))
    parser.add_argument("--protect-days", type=int, default=0)
    parser.add_argument("--budget-gib", type=int, help="evict until retained project closures fit")
    parser.add_argument("--need-gib", type=int, help="evict until this much is freed")
    parser.add_argument("--max-freed-gib", type=int, default=40, help="bound on --need-gib")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.self_test:
        self_test()
        return

    projects = discover_projects(args.gcroots)
    if not projects:
        print("No project GC roots found")
        return
    populate_closures(projects)
    union = set().union(*(project.closure for project in projects.values()))
    sizes = query_sizes(union)

    budget = args.budget_gib
    if budget is None and args.need_gib is None:
        budget = 90
    budget_bytes = None if budget is None else budget * GIB
    need_bytes = None
    if args.need_gib is not None:
        need_bytes = min(args.need_gib, args.max_freed_gib) * GIB

    evictions, retained, freed = plan(
        projects, sizes, time.time(), args.protect_days, budget_bytes, need_bytes
    )

    print(
        f"Projects: {len(projects)}; project closure union: "
        f"{format_size(sum(sizes[path] for path in union))}"
    )
    print(f"Tiers (all projects): {format_tiers(tier_bytes(union, sizes))}")
    mode = "Evict" if args.apply else "Would evict"
    for project, totals in evictions:
        used = (
            datetime.datetime.fromtimestamp(project.last_used)
            .astimezone()
            .strftime("%Y-%m-%d %H:%M")
        )
        print(f"{mode}: {project.path} (last used {used}; {format_tiers(totals)})")

    if need_bytes is not None and freed < need_bytes:
        print(f"Free-space need not reachable: freed {format_size(freed)} of {format_size(need_bytes)}")

    if args.apply and evictions:
        selected_roots = [root for project, _ in evictions for root in project.roots]
        remove_with_angrr(selected_roots, args.protect_days)

    evicted = {project.path for project, _ in evictions}
    kept = set().union(*(p.closure for path, p in projects.items() if path not in evicted))
    print(
        f"Retained: {len(projects) - len(evictions)} projects; "
        f"closure union {format_size(retained)}; {format_tiers(tier_bytes(kept, sizes))}"
    )
    print(f"Freed: {format_size(freed)}")


if __name__ == "__main__":
    main()
