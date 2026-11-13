import argparse
import importlib.util
import os
import shutil
import subprocess
import time
from pathlib import Path


DAY = 24 * 60 * 60
PROJECT_IDLE_DAYS = 14
PROJECT_OUTPUTS = ("dist-newstyle", "_build", "target", ".direnv")
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


def load_retention():
    spec = importlib.util.spec_from_file_location("retention", os.environ["RETENTION_MODULE"])
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


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


def project_candidates(retention, gcroots, now):
    candidates = []
    for path, project in retention.discover_projects(gcroots).items():
        if now - project.last_used < PROJECT_IDLE_DAYS * DAY:
            continue
        if clean_worktree(path) is not True:
            continue
        for name in PROJECT_OUTPUTS:
            target = path / name
            if target.exists() or target.is_symlink():
                candidates.append(target)
        for entry in path.glob("result*"):
            if entry.is_symlink():
                candidates.append(entry)
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


def main():
    parser = argparse.ArgumentParser(description="Remove rederivable build and cache leftovers")
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--gcroots", type=Path, default=Path("/nix/var/nix/gcroots/auto"))
    parser.add_argument("--home", type=Path, default=Path.home())
    options = parser.parse_args()

    retention = load_retention()
    now = time.time()
    groups = [
        ("project outputs", project_candidates(retention, options.gcroots, now)),
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


if __name__ == "__main__":
    main()
