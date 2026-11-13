#!/usr/bin/env python3
# One status line per minute for a nix build or deploy log written with NIX_OBSERVER_PLAIN=1.
# Every line names the stage, its progress, the current derivation, log growth, elapsed and time in stage.

import argparse
import os
import re
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

TAIL_BYTES = 400_000
PROGRESS = re.compile(rb'"fields":\[(\d+),(\d+),(\d+),(\d+)\],"id":\d+,"type":105')
DRV = re.compile(rb"/nix/store/[0-9a-z]{32}-([^\"'\s/]+?)\.drv")
ALARM = re.compile(rb"[^\n]*(?:error:|Cannot build|Failed to |Rolling back|De-activating)[^\n]*")
VERDICT = re.compile(rb"(?m)^(VERIFIED|ROLLED BACK):.*$")
EXIT = re.compile(rb"(?m)^EXIT=(\d+)")
STALL_MINUTES = 3
FLAT_MINUTES = 15


def stage_of(data, tail):
    if b"Deployment confirmed" in data:
        return "CONFIRM"
    if b"Rolling back" in data:
        return "ROLLBACK"
    if b"Activating profile" in data or b"activating the configuration" in data:
        return "ACTIVATE"
    if b"to 'ssh://" in tail:
        return "COPY"
    if b"from 'https://" in tail:
        return "DOWNLOAD"
    if b"from 'ssh://" in tail:
        return "SEED"
    if b'"action":"start"' in tail and b".drv" in tail:
        return "BUILD"
    if b'"type":112' in tail:
        return "FETCH"
    return "EVAL"


def sample(path):
    try:
        data = Path(path).read_bytes()
    except OSError:
        data = b""
    tail = data[-TAIL_BYTES:]
    progress = max(
        (tuple(int(n) for n in m.groups()) for m in PROGRESS.finditer(tail)),
        key=lambda item: item[1],
        default=(0, 0, 0, 0),
    )
    drvs = DRV.findall(tail)
    return data, {
        "bytes": len(data),
        "progress": progress,
        "drv": drvs[-1].decode() if drvs else "-",
        "stage": stage_of(data, tail),
    }, tail


def minutes(seconds):
    return "%dm" % round(seconds / 60)


def describe(signals, delta, stalled, tail, started, stage_since):
    done, expected, running, failed = signals["progress"]
    pct = f"{done * 100 // expected}% ({done}/{expected})" if expected else "n/a"
    alarms = ALARM.findall(tail)
    head = "STALLED %d" % stalled if stalled else signals["stage"]
    now = time.time()
    line = "%s %s %s %s run=%d fail=%d +%dB t=%s stage=%s" % (
        datetime.now().strftime("%H:%M:%S"),
        head,
        pct,
        signals["drv"],
        running,
        failed,
        delta,
        minutes(now - started),
        minutes(now - stage_since),
    )
    if alarms:
        line += " | " + alarms[-1].decode(errors="replace").strip()[:160]
    return line


def busy(path):
    try:
        data = path.read_bytes()
    except OSError:
        return False
    return bool(data) and not EXIT.search(data) and time.time() - path.stat().st_mtime < 900


def launch(log, command):
    path = Path(log)
    path.parent.mkdir(parents=True, exist_ok=True)
    if busy(path):
        print("log busy: %s is being written by a job without EXIT= yet; pick another path" % log, file=sys.stderr)
        sys.exit(4)
    env = dict(os.environ, NIX_OBSERVER_PLAIN="1")
    with path.open("wb") as out:
        child = subprocess.Popen(
            ["bash", "-c", '"$@"; echo "EXIT=$?"', "nix-watch", *command],
            stdin=subprocess.DEVNULL,
            stdout=out,
            stderr=subprocess.STDOUT,
            env=env,
            start_new_session=True,
        )
    print("launched pid=%d log=%s: %s" % (child.pid, log, " ".join(command)), flush=True)


def main():
    argv = sys.argv[1:]
    command = []
    if "--" in argv:
        split = argv.index("--")
        argv, command = argv[:split], argv[split + 1 :]
    parser = argparse.ArgumentParser(
        prog="nix-watch",
        usage="nix-watch [--interval SECONDS] [--ticks N] LOG [-- COMMAND ...]",
        description="One status line per minute for a nix log. With a COMMAND, start it detached into LOG first; with --ticks, return after N lines (exit 3) while it runs.",
    )
    parser.add_argument("log")
    parser.add_argument("--interval", type=float, default=60.0, help="seconds between lines")
    parser.add_argument("--ticks", type=int, default=0, help="return after this many lines with exit 3 while the job runs")
    options = parser.parse_args(argv)
    if command:
        launch(options.log, command)
    flat = {"bytes": 0, "progress": 0, "drv": 0, "stage": 0}
    previous = None
    started = time.time()
    stage_since = started
    ticks = 0
    while True:
        if options.ticks and ticks >= options.ticks:
            print("RUNNING log=%s" % options.log, flush=True)
            return 3
        data, signals, tail = sample(options.log)
        delta = signals["bytes"] - (previous["bytes"] if previous else 0)
        if previous is not None:
            for key in flat:
                flat[key] = flat[key] + 1 if signals[key] == previous[key] else 0
            if signals["stage"] != previous["stage"]:
                stage_since = time.time()
        exits = EXIT.findall(data)
        if exits:
            verdicts = VERDICT.findall(data)
            print(describe(signals, delta, 0, tail, started, stage_since), flush=True)
            if verdicts:
                print("verdict: " + VERDICT.search(data).group(0).decode(errors="replace"), flush=True)
            print("EXIT=%s log=%s" % (exits[-1].decode(), options.log), flush=True)
            return 0 if exits[-1] == b"0" else 1
        if min(flat.values()) >= FLAT_MINUTES:
            print(
                "FLAT %dmin: %s log=%s"
                % (FLAT_MINUTES, " ".join(f"{k}={v}" for k, v in flat.items()), options.log),
                flush=True,
            )
            return 2
        stalled = flat["bytes"] if flat["bytes"] >= STALL_MINUTES else 0
        print(describe(signals, delta, stalled, tail, started, stage_since), flush=True)
        previous = signals
        ticks += 1
        if options.ticks and ticks >= options.ticks:
            continue
        time.sleep(options.interval)


if __name__ == "__main__":
    sys.exit(main())
