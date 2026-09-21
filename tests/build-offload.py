#!/usr/bin/env python3
"""Test the nix build hook wrapper: build-offload.py [MODULE_DIR]."""

import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

MODULE = Path(sys.argv[1] if len(sys.argv) > 1 else "modules/nixos").resolve()
HOOK = MODULE / "build-offload.py"

STUB = '''
import sys
sys.path.insert(0, %r)
from importlib.machinery import SourceFileLoader

offload = SourceFileLoader("offload", %r).load_module()
replies = %r

open(%r, "a").write("spawn ")

reader = offload.Reader()
offload.read_settings(reader)
for reply in replies:
    if offload.read_request(reader) is None:
        break
    sys.stderr.write(reply)
    sys.stderr.flush()
'''


def u64(value):
    return struct.pack("<Q", value)


def text(value):
    raw = value.encode()
    return u64(len(raw)) + raw + b"\0" * ((8 - len(raw) % 8) % 8)


def texts(values):
    return u64(len(values)) + b"".join(text(value) for value in values)


def preamble():
    return u64(1) + text("builders") + text("@/dev/null") + u64(0)


def request(system="x86_64-linux", features=()):
    return text("try") + u64(1) + text(system) + text("/nix/store/a.drv") + texts(list(features))


def run(tmp, replies, probe, requests, grace=0, stall=600, machines=None):
    state = tmp / "state"
    state.mkdir(exist_ok=True)
    stub = tmp / "stub.py"
    spawns = tmp / "spawns"
    stub.write_text(STUB % (str(MODULE), str(HOOK), replies, str(spawns)))

    source = tmp / "machines"
    source.write_text(
        machines
        if machines is not None
        else "ssh-ng://nixremote@desktopnew-builder?remote-program=/x"
        " x86_64-linux /key 16 20 big-parallel,kvm - -\n"
    )

    marker = tmp / "woken"
    config = {
        "hook": [sys.executable, str(stub)],
        "graceSeconds": grace,
        "stallSeconds": stall,
        "probeSeconds": 0,
        "wakeSeconds": 0,
        "leaseSeconds": 3600,
        "source": str(source),
        "builders": [
            {
                "host": "desktopnew",
                "systems": ["x86_64-linux"],
                "features": ["big-parallel", "kvm"],
                "uri": "ssh-ng://nixremote@desktopnew-builder",
                "probe": ["true"] if probe else ["false"],
                "wake": ["touch", str(marker)],
                "lease": ["true"],
            }
        ],
    }
    config_path = tmp / "config.json"
    config_path.write_text(json.dumps(config))

    null = os.open(os.devnull, os.O_RDWR)
    os.dup2(null, 4)
    os.dup2(null, 5)
    os.set_inheritable(4, True)
    os.set_inheritable(5, True)

    child = subprocess.Popen(
        [sys.executable, str(HOOK), str(config_path), "0"],
        stdin=subprocess.PIPE,
        stderr=subprocess.PIPE,
        stdout=subprocess.DEVNULL,
        pass_fds=(4, 5),
        env=dict(os.environ, NIX_OFFLOAD_STATE=str(state)),
    )
    out = child.communicate(preamble() + b"".join(requests), timeout=60)[1]
    verdicts = [
        line[2:] for line in out.decode().splitlines() if line.startswith("# ")
    ]
    return verdicts, out.decode(), marker.exists()


def check(name, got, want):
    if got == want:
        print("ok   %s" % name)
        return 0
    print("FAIL %s\n  got  %r\n  want %r" % (name, got, want))
    return 1


def main():
    failures = 0
    with tempfile.TemporaryDirectory() as raw:
        root = Path(raw)

        def case(name):
            target = root / name
            target.mkdir()
            return target

        verdicts, _, woken = run(
            case("asleep"), ["# decline\n"], False, [request()], grace=0
        )
        failures += check("unreachable builder declines locally", verdicts, ["decline"])
        failures += check("unreachable builder is woken", woken, True)

        verdicts, _, _ = run(
            case("grace"), ["# decline\n"], True, [request()], grace=600
        )
        failures += check("decline passes through inside the grace", verdicts, ["decline"])

        verdicts, _, _ = run(
            case("cutover"), ["# decline\n"], True, [request()], grace=0
        )
        failures += check("decline becomes postpone after the grace", verdicts, ["postpone"])

        verdicts, _, _ = run(
            case("unsupported"),
            ["# decline\n"],
            True,
            [request(system="aarch64-linux")],
            grace=0,
        )
        failures += check(
            "unsupported system still builds locally", verdicts, ["decline"]
        )

        verdicts, _, _ = run(
            case("feature"),
            ["# decline\n"],
            True,
            [request(features=["gccarch-x86-64-v4"])],
            grace=0,
        )
        failures += check(
            "unsupported feature still builds locally", verdicts, ["decline"]
        )

        verdicts, _, _ = run(
            case("permanent"), ["# decline-permanently\n"], True, [request()], grace=600
        )
        failures += check(
            "decline-permanently is never forwarded", verdicts, ["decline"]
        )

        verdicts, out, _ = run(
            case("accept"),
            ["# accept\nssh-ng://desktopnew\n"],
            True,
            [request()],
            grace=0,
        )
        failures += check("accept is forwarded", verdicts, ["accept"])
        failures += check(
            "store uri follows the accept", "ssh-ng://desktopnew" in out, True
        )

        verdicts, _, _ = run(
            case("stall"),
            ["# decline\n", "# decline\n"],
            True,
            [request(), request()],
            grace=0,
            stall=0,
        )
        failures += check(
            "stall guard releases work back to the laptop",
            verdicts,
            ["postpone", "decline"],
        )

        verdicts, _, _ = run(
            case("postpone"), ["# postpone\n"], True, [request()], grace=600
        )
        failures += check("postpone passes through", verdicts, ["postpone"])

        sequence = case("sequence")
        verdicts, _, _ = run(
            sequence,
            ["# decline\n", "# decline\n"],
            True,
            [request(), request()],
            grace=0,
        )
        failures += check(
            "consecutive requests still postpone", verdicts, ["postpone", "postpone"]
        )
        failures += check(
            "a decline a reachable builder could serve respawns the child",
            (sequence / "spawns").read_text().count("spawn"),
            2,
        )

        held = case("held")
        verdicts, _, _ = run(
            held,
            ["# postpone\n", "# postpone\n"],
            True,
            [request(), request()],
            grace=0,
        )
        failures += check(
            "a postponing child is reused", (held / "spawns").read_text().count("spawn"), 1
        )

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
