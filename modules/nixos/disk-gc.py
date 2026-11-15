#!/usr/bin/env python3
# Continuous least-recently-used reclaim: one queue over scratch, project roots and dead store paths, paced by deficit and pressure.

import importlib.util
import json
import os
import pwd
import subprocess
import time

GIB = 1024 ** 3
MIB = 1024 ** 2
MARGIN = 512 * MIB
RAMP = 4 * GIB
BURST = 1000
EMERGENCY_BURST = 4000
REFRESH_SECONDS = 60
PLAN_SECONDS = 60
IDLE_SECONDS = 30
SCAN_SECONDS = 10
LEDGER_SECONDS = 300
TAKEN_ROWS = 200
PAUSE = 3


def load(variable):
    spec = importlib.util.spec_from_file_location(variable.lower(), os.environ[variable])
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


collector = load("COLLECT_MODULE")
STATE = os.environ["GC_STATE_DIR"]
STATUS = os.environ["GC_STATUS"]
UID = int(os.environ["GC_UID"])
USER = os.environ["GC_USER"]
FLOOR = int(os.environ["GC_TARGET_BYTES"])
TARGET_FILE = os.environ["GC_TARGET_FILE"]
EMERGENCY = int(os.environ["GC_EMERGENCY_BYTES"])
SCRATCH = os.environ["GC_SCRATCH"].split()
RETENTION = os.environ["GC_RETENTION"].split()


def target():
    try:
        floor = int(float(open(TARGET_FILE).read().strip()) * GIB)
    except (OSError, ValueError):
        floor = FLOOR
    return floor + MARGIN


def free():
    stat = os.statvfs("/nix/store")
    return stat.f_bavail * stat.f_frsize


def pressure(kind):
    try:
        with open(f"/proc/pressure/{kind}") as handle:
            return float(handle.readline().split("avg10=")[1].split()[0])
    except (OSError, IndexError, ValueError):
        return 0.0


def urgency(deficit, available):
    if available < EMERGENCY:
        return 1.0
    return min(1.0, deficit / RAMP)


def burst(available):
    return EMERGENCY_BURST if available < EMERGENCY else BURST


def busy(level):
    cpu, io = pressure("cpu"), pressure("io")
    return (cpu > 30 + 70 * level or io > 20 + 80 * level), cpu, io


def run_json(command):
    result = subprocess.run(command, capture_output=True, text=True)
    try:
        return result.returncode, json.loads(result.stdout or "{}")
    except ValueError:
        return result.returncode or 1, {}


def as_user(command):
    return ["setpriv", f"--reuid={USER}", f"--regid={pwd.getpwnam(USER).pw_gid}", "--init-groups", "--reset-env", "--", *command]


def write_status(state):
    temporary = STATUS + ".tmp"
    try:
        with open(temporary, "w") as handle:
            json.dump(state, handle, separators=(",", ":"))
        os.chown(temporary, UID, -1)
        os.replace(temporary, STATUS)
    except OSError:
        pass


def record(event):
    with open(os.path.join(STATE, "events.jsonl"), "a") as handle:
        handle.write(json.dumps(event, separators=(",", ":")) + "\n")


class Queue:
    def __init__(self):
        self.index = collector.Index()
        self.refreshed = 0
        self.planned = 0
        self.plans = {}

    def refresh(self, force=False):
        if force or time.monotonic() - self.refreshed > REFRESH_SECONDS:
            self.index.refresh()
            self.refreshed = time.monotonic()

    def plan_stages(self, need, force=False):
        if not force and time.monotonic() - self.planned < PLAN_SECONDS and self.plans:
            return
        gib = "%.3f" % (need / GIB)
        _, scratch = run_json(as_user([*SCRATCH, "--json", "--need-gib", gib]))
        _, projects = run_json([*RETENTION, "--json", "--need-gib", gib])
        self.plans = {"scratch": scratch.get("selected", []), "projects": projects.get("selected", [])}
        self.planned = time.monotonic()

    def rows(self, need):
        _, chosen, _ = collector.select(self.index, need)
        store = [{**row, "stage": "store"} for row in collector.rows(self.index, chosen)]
        others = [{**row, "stage": stage} for stage, rows in self.plans.items() for row in rows]
        merged = sorted(store + others, key=lambda row: (row.get("last_used", 0), row["path"]))
        out, total = [], 0
        for row in merged:
            if total >= need:
                break
            total += row.get("size", 0)
            out.append(row)
        return out

    def forget(self, paths):
        gone = set(paths)
        self.index.dead = [path for path in self.index.dead if path not in gone]
        for path in gone:
            self.index.nar.pop(path, None)
            self.index.effective.pop(path, None)


def step(queue, rows, limit):
    stage = rows[0]["stage"]
    run = []
    for row in rows:
        if row["stage"] != stage or (stage == "store" and len(run) >= limit) or (stage != "store" and run):
            break
        run.append(row)
    started = time.time()
    before = free()
    status = 0
    claimed = sum(row.get("size", 0) for row in run)
    paths = []
    if stage == "store":
        paths = queue.index.dependents(row["path"] for row in run)
        _, _, refused = collector.delete_all(queue.index, paths)
        queue.forget(refused | {path for path in paths if not os.path.exists(path)})
    else:
        cutoff = str(run[-1].get("last_used", 0) + 1)
        need = "%.3f" % max(claimed / GIB, 0.001)
        command = [*SCRATCH, "--apply"] if stage == "scratch" else [*RETENTION, "--apply"]
        command = as_user(command) if stage == "scratch" else command
        status, _ = run_json([*command, "--json", "--before", cutoff, "--need-gib", need])
        queue.planned = 0
        queue.refreshed = 0
    after = free()
    event = {
        "at": int(started),
        "stage": stage,
        "status": status,
        "free_gib": round(before / GIB, 2),
        "need_gib": round(max(0, target() - before) / GIB, 2),
        "freed": after - before,
        "claimed": claimed,
        "items": len(paths) if stage == "store" else len(run),
        "refused": len(refused) if stage == "store" else 0,
        "seconds": round(time.time() - started, 2),
        "taken": {row["path"]: row.get("size", 0) for row in run[:TAKEN_ROWS]},
        "oldest": run[0].get("last_used", 0),
        "newest": run[-1].get("last_used", 0),
    }
    record(event)
    return event


def ledger():
    subprocess.run(["systemctl", "start", "--no-block", "disk-ledger.service"], capture_output=True)


def main():
    os.makedirs(STATE, exist_ok=True)
    queue = Queue()
    last_ledger = time.monotonic()
    collected = False
    last = None
    while True:
        goal = target()
        available = free()
        deficit = goal - available
        base = {"at": int(time.time()), "target": goal, "free": available, "deficit": max(0, deficit), "last": last}
        if deficit <= 0:
            if collected:
                ledger()
                last_ledger = time.monotonic()
                collected = False
            stalled, cpu, io = busy(0.0)
            if not stalled:
                queue.refresh()
                done, remaining = queue.index.scan(SCAN_SECONDS)
                base.update(scanned=done, unscanned=remaining)
            write_status({**base, "running": False, "stage": "", "state": "idle", "cpu": cpu, "io": io})
            time.sleep(IDLE_SECONDS)
            continue
        level = urgency(deficit, available)
        stalled, cpu, io = busy(level)
        if stalled:
            write_status({**base, "running": False, "stage": "", "state": "waiting", "urgency": level, "cpu": cpu, "io": io})
            time.sleep(2)
            continue
        queue.refresh()
        queue.plan_stages(deficit)
        rows = queue.rows(deficit)
        head = [{key: row.get(key) for key in ("path", "stage", "size", "last_used")} for row in rows[:12]]
        if not rows:
            write_status({**base, "running": False, "stage": "", "state": "exhausted", "urgency": level, "queue": head})
            queue.refresh(force=True)
            time.sleep(IDLE_SECONDS)
            continue
        write_status({**base, "running": True, "stage": rows[0]["stage"], "state": "collecting", "urgency": level, "cpu": cpu, "io": io, "queue": head, "need_gib": round(deficit / GIB, 2)})
        last = step(queue, rows, burst(available))
        collected = True
        if time.monotonic() - last_ledger > LEDGER_SECONDS:
            ledger()
            last_ledger = time.monotonic()
        time.sleep(PAUSE * (1 - level))


if __name__ == "__main__":
    main()
