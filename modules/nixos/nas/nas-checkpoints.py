"""NILFS2 checkpoints: promote, expose a rolling window as @GMT- mounts, prune, export metrics."""

import argparse
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

GMT_FORMAT = "@GMT-%Y.%m.%d-%H.%M.%S"
GMT_RE = re.compile(r"^@GMT-\d{4}\.\d{2}\.\d{2}-\d{2}\.\d{2}\.\d{2}$")


def run(args, **kw):
    return subprocess.run(args, capture_output=True, text=True, timeout=120, **kw)


def checkpoints(branch):
    """[(cno, datetime, is_snapshot)] newest first, or [] if the branch is not NILFS2."""
    out = run(["lscp", "-r", str(branch)])
    if out.returncode != 0:
        return []
    found = []
    for line in out.stdout.splitlines():
        parts = line.split()
        if len(parts) < 5 or not parts[0].isdigit():
            continue
        cno = int(parts[0])
        try:
            when = datetime.strptime(f"{parts[1]} {parts[2]}", "%Y-%m-%d %H:%M:%S")
        except ValueError:
            continue
        found.append((cno, when.replace(tzinfo=timezone.utc), parts[3] == "ss"))
    return found


def promote(branch, cno):
    return run(["chcp", "ss", str(branch), str(cno)]).returncode == 0


def demote(branch, cno):
    return run(["chcp", "cp", str(branch), str(cno)]).returncode == 0


def remove(branch, cno):
    return run(["rmcp", str(branch), str(cno)]).returncode == 0


def mounted_windows(snapdir):
    live = {}
    try:
        for line in Path("/proc/self/mounts").read_text().splitlines():
            parts = line.split()
            if len(parts) > 2 and parts[2] == "nilfs2" and parts[1].startswith(str(snapdir)):
                live[Path(parts[1]).name] = parts[1]
    except OSError:
        pass
    return live


def mount_checkpoint(device, cno, target):
    target.mkdir(parents=True, exist_ok=True)
    return run(["mount", "-t", "nilfs2", "-o", f"cp={cno},ro", str(device), str(target)]).returncode == 0


def unmount(target):
    ok = run(["umount", str(target)]).returncode == 0
    if ok:
        try:
            Path(target).rmdir()
        except OSError:
            pass
    return ok


def cmd_promote(args):
    """Promote every unpromoted checkpoint so the GC cannot reclaim it."""
    promoted = 0
    for branch in args.branch:
        for cno, _when, is_ss in checkpoints(branch):
            if not is_ss and promote(branch, cno):
                promoted += 1
    print(f"promoted {promoted}")
    return 0


def cmd_window(args):
    """Expose the newest N snapshots as @GMT- mounts inside each branch."""
    for branch in args.branch:
        branch = Path(branch)
        device = device_for(branch)
        if device is None:
            continue
        snapdir = branch / args.snapshot_dir
        snapdir.mkdir(parents=True, exist_ok=True)

        wanted = {}
        for cno, when, is_ss in checkpoints(branch):
            if not is_ss:
                continue
            wanted[when.strftime(GMT_FORMAT)] = cno
            if len(wanted) >= args.window:
                break

        live = mounted_windows(snapdir)
        for name, path in live.items():
            if name not in wanted and GMT_RE.match(name):
                unmount(path)
        for name, cno in wanted.items():
            if name not in live:
                mount_checkpoint(device, cno, snapdir / name)

        print(f"{branch}: {len(wanted)} exposed")
    return 0


def device_for(branch):
    try:
        for line in Path("/proc/self/mounts").read_text().splitlines():
            parts = line.split()
            if len(parts) > 2 and parts[1] == str(branch) and parts[2] == "nilfs2":
                return parts[0]
    except OSError:
        pass
    return None


def cmd_prune(args):
    """Manual only. Removes snapshots older than a cutoff; nothing does this on a timer."""
    cutoff = datetime.now(timezone.utc).timestamp() - args.older_than_days * 86400
    removed = 0
    for branch in args.branch:
        for cno, when, is_ss in checkpoints(branch):
            if when.timestamp() >= cutoff:
                continue
            if args.dry_run:
                print(f"would remove {branch} cp={cno} {when.isoformat()}")
                continue
            if is_ss:
                demote(branch, cno)
            if remove(branch, cno):
                removed += 1
    if not args.dry_run:
        print(f"removed {removed}")
    return 0


def cmd_metrics(args):
    lines = [
        "# HELP nas_checkpoints Checkpoints present on this branch.",
        "# TYPE nas_checkpoints gauge",
        "# HELP nas_checkpoint_snapshots Checkpoints promoted to snapshots, which the GC cannot reclaim.",
        "# TYPE nas_checkpoint_snapshots gauge",
        "# HELP nas_checkpoints_exposed Generations currently mounted for SMB Previous Versions.",
        "# TYPE nas_checkpoints_exposed gauge",
        "# HELP nas_checkpoint_oldest_seconds Age of the oldest retained checkpoint.",
        "# TYPE nas_checkpoint_oldest_seconds gauge",
    ]
    now = datetime.now(timezone.utc).timestamp()
    for branch in args.branch:
        found = checkpoints(branch)
        if not found:
            continue
        label = Path(branch).name
        snaps = [c for c in found if c[2]]
        exposed = len(mounted_windows(Path(branch) / args.snapshot_dir))
        oldest = min(c[1].timestamp() for c in found)
        lines.append(f'nas_checkpoints{{branch="{label}"}} {len(found)}')
        lines.append(f'nas_checkpoint_snapshots{{branch="{label}"}} {len(snaps)}')
        lines.append(f'nas_checkpoints_exposed{{branch="{label}"}} {exposed}')
        lines.append(f'nas_checkpoint_oldest_seconds{{branch="{label}"}} {now - oldest:.0f}')

    tmp = f"{args.output}.tmp"
    Path(tmp).write_text("\n".join(lines) + "\n")
    os.replace(tmp, args.output)
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--branch", action="append", required=True)
    ap.add_argument("--snapshot-dir", default="snapshots")
    sub = ap.add_subparsers(dest="command", required=True)

    sub.add_parser("promote").set_defaults(func=cmd_promote)

    w = sub.add_parser("window")
    w.add_argument("--window", type=int, default=24)
    w.set_defaults(func=cmd_window)

    p = sub.add_parser("prune")
    p.add_argument("--older-than-days", type=int, required=True)
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(func=cmd_prune)

    m = sub.add_parser("metrics")
    m.add_argument("--output", required=True)
    m.set_defaults(func=cmd_metrics)

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
