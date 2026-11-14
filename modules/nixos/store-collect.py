#!/usr/bin/env python3
# Bounded store collection: delete dead paths least recently used first until a deficit is met.

import argparse
import json
import os
import subprocess
import sys
import time

GIB = 1024 ** 3
BATCH = 200


def dead_paths():
    out = subprocess.run(
        ["nix-store", "--gc", "--print-dead"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    ).stdout
    return [line for line in out.splitlines() if line.startswith("/nix/store/")]


def path_info(paths):
    info = {}
    for start in range(0, len(paths), BATCH):
        chunk = paths[start : start + BATCH]
        out = subprocess.run(
            ["nix", "path-info", "--json", *chunk],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        ).stdout
        if out:
            info.update({path: entry for path, entry in json.loads(out).items() if entry})
    return info


def last_used(path, entry):
    try:
        accessed = os.lstat(path).st_atime
    except OSError:
        accessed = 0
    return max(entry.get("registrationTime", 0), accessed)


def select(dead, info, need):
    old = sorted((p for p in dead if p in info), key=lambda p: last_used(p, info[p]))
    chosen = []
    freed = 0
    for path in old:
        if freed >= need:
            break
        chosen.append(path)
        freed += info[path].get("narSize", 0)
    return old, chosen, freed


def rows(chosen, info):
    return [
        {"path": path, "size": info[path].get("narSize", 0), "last_used": int(last_used(path, info[path]))}
        for path in chosen
    ]


def delete(paths):
    subprocess.run(
        ["nix-store", "--delete", *paths],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def main():
    parser = argparse.ArgumentParser(prog="store-collect")
    parser.add_argument("--need-gib", type=float, required=True, help="free this much, oldest dead paths first")
    parser.add_argument("--apply", action="store_true", help="delete; the default only reports")
    parser.add_argument("--json", action="store_true", help="print the selection as JSON")
    options = parser.parse_args()

    started = time.time()
    dead = dead_paths()
    info = path_info(dead)
    need = options.need_gib * GIB
    old, chosen, freed = select(dead, info, need)
    dead_bytes = sum(info[p].get("narSize", 0) for p in old)

    if options.apply:
        for start in range(0, len(chosen), BATCH):
            delete(chosen[start : start + BATCH])

    if options.json:
        print(
            json.dumps(
                {
                    "stage": "store",
                    "applied": options.apply,
                    "dead_paths": len(old),
                    "dead_bytes": dead_bytes,
                    "need": need,
                    "freed": freed,
                    "seconds": round(time.time() - started, 1),
                    "selected": rows(chosen, info),
                }
            )
        )
        return 0

    print(
        "dead %d paths (%.1f GiB); selected %d oldest (%.1f GiB of %.1f GiB needed)"
        % (len(old), dead_bytes / GIB, len(chosen), freed / GIB, need / GIB)
    )
    if chosen:
        oldest = time.strftime("%Y-%m-%d", time.localtime(last_used(chosen[0], info[chosen[0]])))
        newest = time.strftime("%Y-%m-%d %H:%M", time.localtime(last_used(chosen[-1], info[chosen[-1]])))
        print("last used between %s and %s" % (oldest, newest))
    if options.apply:
        print("deleted %d paths" % len(chosen))
    else:
        for path in chosen[:20]:
            print("  " + path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
