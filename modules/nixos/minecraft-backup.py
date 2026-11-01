"""Minecraft backup driver: flush the server, snapshot the guest, ship the block delta to the NAS."""

import argparse
import base64
import json
import os
import socket
import struct
import subprocess
import sys
import time

CAPTURE = r"""
import json, os, socket, struct, subprocess, sys, time

snapdir, subvol, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
password = os.environ["MC_RCON_PASSWORD"]


def packet(sock, rid, kind, body):
    data = struct.pack("<ii", rid, kind) + body.encode() + b"\0\0"
    sock.sendall(struct.pack("<i", len(data)) + data)
    (length,) = struct.unpack("<i", sock.recv(4, socket.MSG_WAITALL))
    reply = sock.recv(length, socket.MSG_WAITALL)
    rid_back, _ = struct.unpack("<ii", reply[:8])
    return rid_back, reply[8:-2].decode(errors="replace")


try:
    sock = socket.create_connection(("127.0.0.1", port), timeout=120)
except OSError as e:
    print(json.dumps({"server": "down", "error": str(e)}))
    sys.exit(0)
if packet(sock, 1, 3, password)[0] == -1:
    print(json.dumps({"server": "auth"}))
    sys.exit(0)

os.makedirs(snapdir, exist_ok=True)
new = os.path.join(snapdir, "new")
if os.path.exists(new):
    subprocess.run(["btrfs", "-q", "subvolume", "delete", new], check=True)

held = time.monotonic()
try:
    packet(sock, 2, 2, "save-off")
    flush = time.monotonic()
    packet(sock, 3, 2, "save-all flush")
    stall = time.monotonic() - flush
    captured = time.time()
    subprocess.run(["btrfs", "-q", "subvolume", "snapshot", "-r", subvol, new], check=True)
finally:
    packet(sock, 4, 2, "save-on")
hold = time.monotonic() - held

base_id = None
try:
    with open(os.path.join(snapdir, "base.id")) as f:
        base_id = f.read().strip() or None
except FileNotFoundError:
    pass
if not os.path.isdir(os.path.join(snapdir, "base")):
    base_id = None

print(json.dumps({
    "server": "up",
    "id": str(time.time_ns()),
    "captured": captured,
    "stall_ms": round(stall * 1000),
    "hold_ms": round(hold * 1000),
    "base": base_id,
}))
"""

SETTLE = r"""
import os, subprocess, sys

snapdir, outcome, new_id = sys.argv[1], sys.argv[2], sys.argv[3]
base, new = os.path.join(snapdir, "base"), os.path.join(snapdir, "new")


def drop(path):
    if os.path.exists(path):
        subprocess.run(["btrfs", "-q", "subvolume", "delete", path], check=True)


if outcome == "ok":
    drop(base)
    os.rename(new, base)
    with open(os.path.join(snapdir, "base.id.tmp"), "w") as f:
        f.write(new_id)
    os.replace(os.path.join(snapdir, "base.id.tmp"), os.path.join(snapdir, "base.id"))
elif outcome == "resync":
    drop(new)
    drop(base)
else:
    drop(new)
"""

ENSURE_RCON = r"""
import os, sys

path, port = sys.argv[1], sys.argv[2]
if not os.path.exists(path):
    print("missing")
    sys.exit(0)
want = {"enable-rcon": "true", "rcon.port": port, "rcon.password": os.environ["MC_RCON_PASSWORD"]}
with open(path) as f:
    lines = f.read().splitlines()
seen, out = set(), []
for line in lines:
    key = line.split("=", 1)[0]
    if key in want:
        seen.add(key)
        line = f"{key}={want[key]}"
    out.append(line)
out += [f"{k}={v}" for k, v in want.items() if k not in seen]
if out != lines:
    with open(path, "r+") as f:
        f.seek(0)
        f.write("\n".join(out) + "\n")
        f.truncate()
    print("changed")
else:
    print("unchanged")
"""


class Guest:
    def __init__(self, domain):
        self.domain = domain

    def agent(self, command, timeout=30):
        out = subprocess.run(
            ["virsh", "-c", "qemu:///system", "qemu-agent-command", self.domain, json.dumps(command), "--timeout", str(timeout)],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
        return json.loads(out)["return"]

    def running(self):
        state = subprocess.run(
            ["virsh", "-c", "qemu:///system", "domstate", self.domain], capture_output=True, text=True
        ).stdout.strip()
        return state == "running"

    def python(self, source, args, env=(), timeout=120):
        pid = self.agent(
            {
                "execute": "guest-exec",
                "arguments": {
                    "path": "/usr/bin/python3",
                    "arg": ["-c", source, *args],
                    "env": list(env),
                    "capture-output": True,
                },
            }
        )["pid"]
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            status = self.agent({"execute": "guest-exec-status", "arguments": {"pid": pid}})
            if status.get("exited"):
                out = base64.b64decode(status.get("out-data", "")).decode(errors="replace")
                err = base64.b64decode(status.get("err-data", "")).decode(errors="replace")
                if status.get("exitcode") != 0:
                    raise RuntimeError(f"guest python exited {status.get('exitcode')}: {err.strip()}")
                return out
            time.sleep(0.05)
        raise TimeoutError("guest python did not finish")

    def fetch(self, path, dest):
        handle = self.agent({"execute": "guest-file-open", "arguments": {"path": path, "mode": "r"}})
        try:
            with open(dest, "wb") as out:
                while True:
                    chunk = self.agent(
                        {"execute": "guest-file-read", "arguments": {"handle": handle, "count": 8 << 20}}, timeout=120
                    )
                    out.write(base64.b64decode(chunk["buf-b64"]))
                    if chunk.get("eof") or chunk["count"] == 0:
                        break
        finally:
            self.agent({"execute": "guest-file-close", "arguments": {"handle": handle}})


def push(target, path, timeout):
    host, port = target.rsplit(":", 1)
    size = os.path.getsize(path)
    with socket.create_connection((host, int(port)), timeout=timeout) as sock, open(path, "rb") as f:
        sock.sendall(struct.pack("<Q", size))
        while chunk := f.read(1 << 20):
            sock.sendall(chunk)
        sock.shutdown(socket.SHUT_WR)
        return sock.makefile().readline().strip() or "error empty"


def log(message):
    print(message, flush=True)


def one_pass(args, guest, blockdelta, env):
    snapdir = args.snapshot_dir
    rel = os.path.relpath(args.server_dir, args.subvolume)
    capture = json.loads(guest.python(CAPTURE, [snapdir, args.subvolume, str(args.rcon_port)], env))
    if capture["server"] in ("down", "auth"):
        changed = guest.python(
            ENSURE_RCON, [os.path.join(args.server_dir, "server.properties"), str(args.rcon_port)], env
        ).strip()
        if changed == "changed":
            log("enabled rcon in server.properties; takes effect on the next server restart")
        return "server-down" if capture["server"] == "down" else "rcon-auth"

    header = {
        "stream": args.stream,
        "id": capture["id"],
        "base": capture["base"],
        "captured": capture["captured"],
        "stall_ms": capture["stall_ms"],
    }
    diff_args = ["diff", "--header", json.dumps(header)]
    if capture["base"]:
        diff_args += ["--base", os.path.join(snapdir, "base", rel)]
    diff_args += [os.path.join(snapdir, "new", rel), args.guest_delta]
    started = time.monotonic()
    summary = json.loads(guest.python(blockdelta, diff_args, timeout=1800))

    if capture["base"] and summary["records"] == 0:
        guest.python(SETTLE, [snapdir, "unchanged", capture["id"]])
        return "unchanged"

    local = os.path.join(args.state_dir, "delta")
    guest.fetch(args.guest_delta, local)
    diffed = time.monotonic() - started
    try:
        outcome = push(args.receiver, local, args.push_timeout)
    except OSError as e:
        outcome = f"unreachable ({e})"
    finally:
        os.unlink(local)
    settle = "ok" if outcome == "ok" else "resync" if outcome == "resync" else "failed"
    guest.python(SETTLE, [snapdir, settle, capture["id"]])
    log(
        f"point {capture['id']}: stall {capture['stall_ms']} ms, save-off held {capture['hold_ms']} ms, "
        f"{'full' if not capture['base'] else 'delta'} {summary['bytes']} B in {diffed:.1f}s, push {outcome}"
    )
    return settle


def main():
    parser = argparse.ArgumentParser(prog="minecraft-backup")
    parser.add_argument("--domain", required=True)
    parser.add_argument("--stream", required=True)
    parser.add_argument("--server-dir", required=True)
    parser.add_argument("--subvolume", required=True)
    parser.add_argument("--snapshot-dir", required=True)
    parser.add_argument("--guest-delta", default="/var/tmp/minecraft-backup.delta")
    parser.add_argument("--rcon-port", type=int, default=25575)
    parser.add_argument("--rcon-password-file", required=True)
    parser.add_argument("--receiver", required=True)
    parser.add_argument("--interval", type=float, default=60)
    parser.add_argument("--push-timeout", type=float, default=120)
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--blockdelta", required=True)
    args = parser.parse_args()

    with open(args.blockdelta) as f:
        blockdelta = f.read()
    with open(args.rcon_password_file) as f:
        env = [f"MC_RCON_PASSWORD={f.read().strip()}"]
    guest = Guest(args.domain)
    os.makedirs(args.state_dir, exist_ok=True)

    last = None
    while True:
        started = time.monotonic()
        try:
            state = one_pass(args, guest, blockdelta, env) if guest.running() else "vm-down"
        except (subprocess.CalledProcessError, RuntimeError, TimeoutError, ValueError, KeyError) as e:
            stderr = getattr(e, "stderr", "") or ""
            state = "error"
            log(f"pass failed: {e} {stderr.strip()}")
        if state != last and state in ("vm-down", "server-down", "rcon-auth", "unchanged"):
            log(f"idle: {state}")
        last = state
        time.sleep(max(0.0, args.interval - (time.monotonic() - started)))


if __name__ == "__main__":
    sys.exit(main())
