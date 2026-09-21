# Nix build hook: build locally while a sleeping builder wakes, then hand the rest over.

import fcntl
import json
import os
import struct
import subprocess
import sys
import threading
import time

STATE_DIR = os.environ.get("NIX_OFFLOAD_STATE", "/run/nix-offload")
MACHINES = os.path.join(STATE_DIR, "machines")


def read_exact(count):
    out = bytearray()
    while len(out) < count:
        chunk = os.read(0, count - len(out))
        if not chunk:
            raise EOFError
        out += chunk
    return bytes(out)


class Reader:
    def __init__(self):
        self.raw = bytearray()

    def take(self):
        data = bytes(self.raw)
        self.raw.clear()
        return data

    def blob(self, count):
        data = read_exact(count)
        self.raw += data
        return data

    def number(self):
        return struct.unpack("<Q", self.blob(8))[0]

    def text(self):
        size = self.number()
        data = self.blob(size)
        self.blob((8 - size % 8) % 8)
        return data.decode(errors="replace")

    def texts(self):
        return [self.text() for _ in range(self.number())]


def read_settings(reader):
    while reader.number():
        reader.text()
        reader.text()


def read_request(reader):
    if reader.text() != "try":
        return None
    reader.number()
    system = reader.text()
    reader.text()
    return system, set(reader.texts())


def with_state(path, mutate):
    with open(path, "a+") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        handle.seek(0)
        try:
            state = json.loads(handle.read() or "{}")
        except ValueError:
            state = {}
        result = mutate(state)
        handle.seek(0)
        handle.truncate()
        handle.write(json.dumps(state))
        return result


def stale(path, interval):
    def check(state):
        if time.time() - state.get("at", 0) < interval:
            return False
        state["at"] = time.time()
        return True

    return with_state(path, check)


def detached(argv):
    # A hook process is retired as soon as it accepts, so this must outlive it.
    subprocess.Popen(
        argv,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


class Offload:
    def __init__(self, config, verbosity):
        self.config = config
        self.verbosity = verbosity
        self.session = os.path.join(STATE_DIR, "session-%d" % os.getppid())
        self.child = None
        self.serving = None

    def started(self):
        def begin(state):
            state.setdefault("start", time.time())
            return state["start"]

        return with_state(self.session, begin)

    def reachable(self):
        up = []
        for builder in self.config["builders"]:
            path = os.path.join(STATE_DIR, "probe-" + builder["host"])

            def check(state, builder=builder):
                if time.time() - state.get("at", 0) < self.config["probeSeconds"]:
                    return state.get("up", False)
                answered = (
                    subprocess.call(
                        builder["probe"],
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                    )
                    == 0
                )
                state["at"] = time.time()
                state["up"] = answered
                return answered

            if with_state(path, check):
                up.append(builder)
            elif stale(
                os.path.join(STATE_DIR, "wake-" + builder["host"]),
                self.config["wakeSeconds"],
            ):
                detached(builder["wake"])
        return up

    def hold_awake(self, builders):
        for builder in builders:
            if stale(
                os.path.join(STATE_DIR, "lease-" + builder["host"]),
                self.config["leaseSeconds"],
            ):
                detached(builder["lease"])

    def usable(self, builders, system, features):
        for builder in builders:
            if system in builder["systems"] and features <= set(builder["features"]):
                return True
        return False

    def stop_child(self):
        if self.child:
            self.child.kill()
            self.child.wait()
        self.child = None
        self.serving = None

    def machine_lines(self, builders):
        wanted = tuple(builder["uri"] for builder in builders)
        with open(self.config["source"]) as handle:
            return [
                line
                for line in handle.read().splitlines()
                if line.split(" ")[0].startswith(wanted)
            ]

    def start_child(self, builders, preamble):
        temporary = MACHINES + ".%d" % os.getpid()
        with open(temporary, "w") as handle:
            handle.write("".join(line + "\n" for line in self.machine_lines(builders)))
        os.replace(temporary, MACHINES)
        self.child = subprocess.Popen(
            self.config["hook"] + [self.verbosity],
            stdin=subprocess.PIPE,
            stderr=subprocess.PIPE,
            pass_fds=(4, 5),
        )
        self.serving = [builder["host"] for builder in builders]
        self.child.stdin.write(preamble)
        self.child.stdin.flush()

    def answer(self, word):
        sys.stderr.buffer.write(("# %s\n" % word).encode())
        sys.stderr.buffer.flush()

    def relay_until_verdict(self):
        while True:
            line = self.child.stderr.readline()
            if not line:
                return None
            if line.startswith(b"# "):
                return line[2:].decode(errors="replace").strip()
            sys.stderr.buffer.write(line)
            sys.stderr.buffer.flush()

    def passthrough(self):
        def pump():
            try:
                while True:
                    data = os.read(0, 65536)
                    if not data:
                        break
                    self.child.stdin.write(data)
                    self.child.stdin.flush()
            except OSError:
                pass

        threading.Thread(target=pump, daemon=True).start()
        while True:
            line = self.child.stderr.readline()
            if not line:
                break
            sys.stderr.buffer.write(line)
            sys.stderr.buffer.flush()
        return self.child.wait()

    def offload_only(self):
        grace = self.config["graceSeconds"]
        stall = self.config["stallSeconds"]

        def judge(state):
            now = time.time()
            if now - state.get("start", now) < grace:
                return False
            if now < state.get("bypass", 0):
                return False
            since = state.get("since")
            if since is None or state.get("accepted", 0) > since:
                since = now
                state["since"] = since
            if now - since > stall:
                state["bypass"] = now + stall
                state["since"] = None
                return False
            return True

        return with_state(self.session, judge)

    def note_accept(self):
        def mark(state):
            state["accepted"] = time.time()
            state["since"] = None

        with_state(self.session, mark)

    def run(self):
        reader = Reader()
        read_settings(reader)
        preamble = reader.take()
        self.started()

        while True:
            try:
                request = read_request(reader)
            except EOFError:
                return 0
            if request is None:
                return 0
            payload = reader.take()
            system, features = request

            builders = self.reachable()
            self.hold_awake(builders)
            if [builder["host"] for builder in builders] != self.serving:
                self.stop_child()
            if not builders:
                self.answer("decline")
                continue
            if not self.child:
                self.start_child(builders, preamble)

            self.child.stdin.write(payload)
            self.child.stdin.flush()
            verdict = self.relay_until_verdict()

            if verdict == "accept":
                self.note_accept()
                self.answer("accept")
                return self.passthrough()
            if verdict is None or verdict == "decline-permanently":
                # Forwarding it would set worker.tryBuildHook = false, retiring the
                # hook for the whole nix session, so a later wake could never join.
                self.stop_child()
                self.answer("decline")
                continue
            if verdict == "decline" and self.usable(builders, system, features):
                # build-remote disables a machine in-process after a failed
                # connection and never reconsiders it, so without a respawn one
                # dropped link retires the builder for this child's whole life.
                self.stop_child()
                if self.offload_only():
                    verdict = "postpone"
            self.answer(verdict)


def main():
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(sys.argv[1]) as handle:
        config = json.load(handle)
    return Offload(config, sys.argv[2]).run()


if __name__ == "__main__":
    sys.exit(main())
