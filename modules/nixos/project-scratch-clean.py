import argparse
import json
import os
import shutil
import stat
import subprocess
import sys
import time
from pathlib import Path


GIB = 1024**3
CACHES = [
    ".cache/nix-logs",
    ".cache/drkonqi",
    ".cache/chromium",
    ".cache/chromium-headless",
    ".cache/mozilla",
    ".cache/thumbnails",
    ".cache/mesa_shader_cache",
    ".cache/go-build",
    ".cache/mpv",
    ".cache/ghcide",
    ".cache/curd",
    ".cache/caelestia",
    ".cache/fontconfig",
    ".cache/plasma_theme_default.kcache",
    ".cache/pip",
    ".cache/npm",
    ".cargo/registry/cache",
    ".cabal/packages",
    ".opam/download-cache",
]




def size_of(path):
    if path.is_symlink() or path.is_file():
        return path.lstat().st_size
    total = 0
    for root, _, files in os.walk(path):
        for name in files:
            try:
                total += os.lstat(os.path.join(root, name)).st_size
            except OSError:
                continue
    return total


def last_used(path):
    stat = path.lstat()
    latest = max(stat.st_mtime, stat.st_atime)
    if path.is_dir() and not path.is_symlink():
        for root, dirs, files in os.walk(path):
            for name in dirs + files:
                try:
                    entry = os.lstat(os.path.join(root, name))
                    latest = max(latest, entry.st_mtime, entry.st_atime)
                except OSError:
                    continue
    return latest


def clean_worktree(project):
    try:
        status = subprocess.run(
            ["git", "-C", str(project), "status", "--porcelain"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError):
        return None
    return status == ""


def manifest_paths(root, manifest):
    paths = []
    for line in manifest.read_text().splitlines():
        if not line or line.startswith(".dev-build-"):
            continue
        target = root / line
        if target.exists() or target.is_symlink():
            paths.append(target)
    return paths


def artefact_candidates(state):
    rows = []
    for record in state.glob("*/artefacts"):
        root_file = record.with_name("root")
        if not root_file.exists():
            continue
        root = Path(root_file.read_text().strip())
        if not root.is_dir() or clean_worktree(root) is False:
            continue
        used = record.lstat().st_mtime
        rows.extend((used, path, "artefact", remove) for path in manifest_paths(root, record))
    return rows


def shell_temp_candidates():
    return [
        (entry.lstat().st_mtime, entry, "nix-shell temp", remove)
        for entry in Path("/tmp").glob("nix-shell.*")
        if entry.lstat().st_uid == os.getuid()
    ]


def scratchpad_candidates():
    return [
        (last_used(entry), entry, "scratchpad", remove)
        for scratchpad in Path("/tmp/claude-%d" % os.getuid()).glob("*/*/scratchpad")
        for entry in scratchpad.iterdir()
    ]


def cache_candidates(home):
    rows = []
    for relative in CACHES:
        entry = home / relative
        if entry.exists():
            rows.append((last_used(entry), entry, "cache", remove))
    return rows


def writable_retry(function, failed, error):
    if not isinstance(error, PermissionError):
        raise error
    parent = os.path.dirname(failed)
    os.chmod(parent, os.lstat(parent).st_mode | stat.S_IWUSR | stat.S_IXUSR)
    function(failed)


def remove(path):
    if path.is_symlink() or path.is_file():
        path.unlink()
    else:
        shutil.rmtree(path, onexc=writable_retry)


def offload_candidates(root):
    if not root.is_dir():
        return []
    rows = []
    for path in root.iterdir():
        marker = path / ".dev-build-last-used"
        if path.is_symlink() or not path.is_dir() or not marker.exists():
            continue
        rows.append((marker.lstat().st_mtime, path, "offload", remove_offload))
    return rows


def remove_offload(path):
    for link in sorted(path.glob(".dev-build-profile*")):
        link.unlink()
    shutil.rmtree(path)


def main():
    parser = argparse.ArgumentParser(description="Reclaim rederivable build and cache leftovers, least recently used first")
    parser.add_argument("--apply", action="store_true", help="remove; needs --need-gib")
    parser.add_argument("--need-gib", type=float, help="stop once this much has been reclaimed")
    parser.add_argument("--json", action="store_true", help="print the selection as JSON")
    parser.add_argument("--home", type=Path, default=Path.home())
    parser.add_argument(
        "--state",
        type=Path,
        default=Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))) / "dev-build",
    )
    options = parser.parse_args()
    if options.apply and options.need_gib is None:
        parser.error("--apply needs --need-gib")

    rows = sorted(
        artefact_candidates(options.state)
        + shell_temp_candidates()
        + scratchpad_candidates()
        + cache_candidates(options.home)
        + offload_candidates(Path(os.environ.get("SCRATCH_OFFLOAD_DIR", "") or "/nonexistent")),
        key=lambda row: row[0],
    )
    started = time.time()
    need = (options.need_gib or 0) * GIB
    reclaimed = 0
    selected = []
    say = (lambda *_: None) if options.json else print
    say(f"{len(rows)} reclaimable entries, least recently used first" + (f"; need {need / GIB:.1f} GiB" if need else ""))
    for used, path, kind, removal in rows:
        if need and reclaimed >= need:
            break
        size = size_of(path)
        when = time.strftime("%Y-%m-%d", time.localtime(used))
        say(f"  {when} {size / GIB:6.2f} GiB {kind:14} {path}")
        if options.apply:
            try:
                removal(path)
            except OSError as error:
                print(f"  skipped {path}: {error}", file=sys.stderr)
                continue
        reclaimed += size
        selected.append({"path": str(path), "kind": kind, "size": size, "last_used": int(used)})
    if options.json:
        print(
            json.dumps(
                {
                    "stage": "scratch",
                    "applied": options.apply,
                    "candidates": len(rows),
                    "need": need,
                    "freed": reclaimed,
                    "seconds": round(time.time() - started, 1),
                    "selected": selected,
                }
            )
        )
        return
    verb = "reclaimed" if options.apply else "would reclaim"
    print(f"{verb} {reclaimed / GIB:.2f} GiB")


if __name__ == "__main__":
    main()
