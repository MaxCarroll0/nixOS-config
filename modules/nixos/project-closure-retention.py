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
RESULT_NAME = re.compile(r"result(?:-.+)?$")


@dataclass
class Project:
    path: Path
    roots: list[Path] = field(default_factory=list)
    store_paths: list[str] = field(default_factory=list)
    last_used: float = 0
    closure: set[str] = field(default_factory=set)


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
        project.last_used = max(project.last_used, target.lstat().st_mtime)
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


def select_evictions(
    projects: dict[Path, Project],
    sizes: dict[str, int],
    now: float,
    protect_days: int,
    maximum: int,
    minimum: int,
    maximum_bytes: int,
) -> tuple[list[tuple[Project, int]], int]:
    remaining = dict(projects)
    references = collections.Counter(
        store_path for project in remaining.values() for store_path in project.closure
    )
    retained_bytes = sum(sizes[path] for path in references)
    protected_after = now - protect_days * 24 * 60 * 60
    evictions: list[tuple[Project, int]] = []

    while (len(remaining) > maximum or retained_bytes > maximum_bytes) and len(remaining) > minimum:
        candidates = [project for project in remaining.values() if project.last_used < protected_after]
        if not candidates:
            break
        oldest_day = min(datetime.datetime.fromtimestamp(p.last_used).date() for p in candidates)
        bucket = [
            project
            for project in candidates
            if datetime.datetime.fromtimestamp(project.last_used).date() == oldest_day
        ]

        def marginal_size(project: Project) -> int:
            return sum(sizes[path] for path in project.closure if references[path] == 1)

        victim = max(bucket, key=lambda project: (marginal_size(project), str(project.path)))
        marginal = marginal_size(victim)
        evictions.append((victim, marginal))
        del remaining[victim.path]
        for store_path in victim.closure:
            references[store_path] -= 1
            if references[store_path] == 0:
                retained_bytes -= sizes[store_path]

    return evictions, retained_bytes


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


def self_test() -> None:
    day = 24 * 60 * 60
    now = 100 * day
    projects: dict[Path, Project] = {}
    sizes: dict[str, int] = {"shared": 10}
    for index in range(42):
        path = Path(f"/project/{index:02d}")
        unique = f"unique-{index}"
        sizes[unique] = index + 1
        projects[path] = Project(
            path=path,
            last_used=now - (10 + index // 2) * day,
            closure={"shared", unique},
        )
    recent = Project(
        Path("/project/recent-large"),
        last_used=now - day,
        closure={"recent-large"},
    )
    projects[recent.path] = recent
    sizes["recent-large"] = 10_000

    evictions, _ = select_evictions(projects, sizes, now, 3, 40, 10, 10**9)
    assert len(evictions) == 3
    assert all(project.path != recent.path for project, _ in evictions)
    assert [str(project.path) for project, _ in evictions[:2]] == ["/project/41", "/project/40"]

    evictions, _ = select_evictions(projects, sizes, now, 3, 40, 10, 0)
    assert len(projects) - len(evictions) == 10
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
        description="Retain project closures using day-bucketed LRU"
    )
    parser.add_argument("--apply", action="store_true", help="ask angrr to remove selected roots")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--gcroots", type=Path, default=Path("/nix/var/nix/gcroots/auto"))
    parser.add_argument("--protect-days", type=int, default=3)
    parser.add_argument("--max-projects", type=int, default=40)
    parser.add_argument("--min-projects", type=int, default=10)
    parser.add_argument("--max-size-gib", type=int, default=90)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.self_test:
        self_test()
        return
    if args.min_projects > args.max_projects:
        raise SystemExit("--min-projects cannot exceed --max-projects")

    projects = discover_projects(args.gcroots)
    if not projects:
        print("No project GC roots found")
        return
    populate_closures(projects)
    sizes = query_sizes(set().union(*(project.closure for project in projects.values())))
    initial_bytes = sum(sizes.values())
    evictions, retained_bytes = select_evictions(
        projects,
        sizes,
        time.time(),
        args.protect_days,
        args.max_projects,
        args.min_projects,
        args.max_size_gib * GIB,
    )

    mode = "Evict" if args.apply else "Would evict"
    print(
        f"Projects: {len(projects)}; project closure union: {format_size(initial_bytes)}; "
        f"target: <= {args.max_projects} projects and <= {args.max_size_gib} GiB"
    )
    for project, marginal in evictions:
        used = (
            datetime.datetime.fromtimestamp(project.last_used)
            .astimezone()
            .strftime("%Y-%m-%d %H:%M")
        )
        print(f"{mode}: {project.path} (last used {used}; marginal {format_size(marginal)})")

    if args.apply:
        selected_roots = [root for project, _ in evictions for root in project.roots]
        remove_with_angrr(selected_roots, args.protect_days)

    print(
        f"Retained: {len(projects) - len(evictions)} projects; "
        f"project closure union: {format_size(retained_bytes)}"
    )
    if (
        len(projects) - len(evictions) > args.max_projects
        or retained_bytes > args.max_size_gib * GIB
    ):
        print("Targets remain exceeded because protected or minimum-retained projects cannot be evicted")


if __name__ == "__main__":
    main()
