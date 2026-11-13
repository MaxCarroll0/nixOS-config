import argparse
import os
import shutil
import subprocess
import time
from pathlib import Path


DAY = 24 * 60 * 60
PROJECT_IDLE_DAYS = 14
SHELL_TEMP_DAYS = 1
SCRATCHPAD_DAYS = 7
CACHE_DAYS = {
    ".cache/nix-logs": 30,
    ".cache/drkonqi": 30,
    ".cache/chromium": 30,
    ".cache/chromium-headless": 30,
    ".cache/mozilla": 30,
    ".cache/thumbnails": 30,
    ".cache/mesa_shader_cache": 60,
    ".cache/go-build": 60,
    ".cache/mpv": 60,
    ".cache/ghcide": 60,
    ".cache/curd": 60,
    ".cache/caelestia": 60,
    ".cache/fontconfig": 90,
    ".cache/plasma_theme_default.kcache": 90,
}




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


def newest(path):
    latest = path.lstat().st_mtime
    if path.is_dir() and not path.is_symlink():
        for root, dirs, files in os.walk(path):
            for name in dirs + files:
                try:
                    latest = max(latest, os.lstat(os.path.join(root, name)).st_mtime)
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


def artefact_candidates(state, now):
    candidates = []
    for record in state.glob("*/artefacts"):
        root_file = record.with_name("root")
        if not root_file.exists() or now - record.lstat().st_mtime < PROJECT_IDLE_DAYS * DAY:
            continue
        root = Path(root_file.read_text().strip())
        if not root.is_dir() or clean_worktree(root) is False:
            continue
        candidates.extend(manifest_paths(root, record))
    return candidates


def shell_temp_candidates(now):
    temp = Path("/tmp")
    return [
        entry
        for entry in temp.glob("nix-shell.*")
        if entry.lstat().st_uid == os.getuid() and now - entry.lstat().st_mtime > SHELL_TEMP_DAYS * DAY
    ]


def scratchpad_candidates(now):
    candidates = []
    for scratchpad in Path("/tmp/claude-%d" % os.getuid()).glob("*/*/scratchpad"):
        for entry in scratchpad.iterdir():
            if now - newest(entry) > SCRATCHPAD_DAYS * DAY:
                candidates.append(entry)
    return candidates


def cache_candidates(home, now):
    candidates = []
    for relative, days in CACHE_DAYS.items():
        entry = home / relative
        if entry.exists() and now - newest(entry) > days * DAY:
            candidates.append(entry)
    return candidates


def remove(path):
    if path.is_symlink() or path.is_file():
        path.unlink()
    else:
        shutil.rmtree(path)


def offload_candidates(root):
    if not root.is_dir():
        return []
    rows = []
    for path in root.iterdir():
        marker = path / ".dev-build-last-used"
        if path.is_symlink() or not path.is_dir() or not marker.exists():
            continue
        rows.append((marker.lstat().st_mtime, path))
    return sorted(rows)


def remove_offload(path):
    for link in sorted(path.glob(".dev-build-profile*")):
        link.unlink()
    shutil.rmtree(path)


def free_bytes():
    return shutil.disk_usage("/nix/store").free


def reclaim_offload(options):
    root = os.environ.get("SCRATCH_OFFLOAD_DIR", "")
    if not root:
        return
    target = int(os.environ.get("SCRATCH_MIN_FREE_BYTES", "0"))
    rows = offload_candidates(Path(root))
    free = free_bytes()
    pressure = free < target
    total = 0
    for last, path in rows:
        size = size_of(path)
        total += size
    print(
        f"offload: {len(rows)} projects, {total / 1024**3:.2f} GiB; "
        f"free {free / 1024**3:.1f} GiB, target {target / 1024**3:.1f} GiB; "
        f"{'under pressure' if pressure else 'not under pressure, nothing reclaimed'}"
    )
    removed = 0
    for last, path in rows:
        when = time.strftime("%Y-%m-%d", time.localtime(last))
        print(f"  {path} (last used {when})")
        if options.apply and pressure and free_bytes() < target:
            removed += size_of(path)
            remove_offload(path)
            print("    removed")
    if options.apply and pressure:
        print(f"offload removed {removed / 1024**3:.2f} GiB")


def main():
    parser = argparse.ArgumentParser(description="Remove rederivable build and cache leftovers")
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--home", type=Path, default=Path.home())
    parser.add_argument(
        "--state",
        type=Path,
        default=Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))) / "dev-build",
    )
    options = parser.parse_args()

    now = time.time()
    groups = [
        ("recorded build artefacts", artefact_candidates(options.state, now)),
        ("nix-shell temp", shell_temp_candidates(now)),
        ("scratchpad", scratchpad_candidates(now)),
        ("cache", cache_candidates(options.home, now)),
    ]

    total = 0
    for label, paths in groups:
        size = 0
        for path in paths:
            size += size_of(path)
            if options.apply:
                remove(path)
        total += size
        print(f"{label}: {len(paths)} entries, {size / 1024**3:.2f} GiB")
        for path in paths:
            print(f"  {path}")
    verb = "removed" if options.apply else "would remove"
    print(f"{verb} {total / 1024**3:.2f} GiB")
    reclaim_offload(options)


if __name__ == "__main__":
    main()
