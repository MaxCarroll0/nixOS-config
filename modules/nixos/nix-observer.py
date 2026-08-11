#!/usr/bin/env python3

import argparse
import hashlib
import json
import os
import re
import secrets
import shlex
import socket
import subprocess
import sys
import syslog
import tempfile
import time
import urllib.request
from pathlib import Path


BUILD_LOG = 101
BUILD_PHASE = 104
SECRET = re.compile(
    r"(?i)(authorization|access[-_]?token|api[-_]?key|password|passwd|cookie)(=|:|\s+)([^\s]+)"
)
STORE_NAME = re.compile(r"/nix/store/[0-9a-z]{32}-([^/]+?)(?:\.drv)?$")


def redact(value):
    return SECRET.sub(r"\1\2<redacted>", value)


def project_name(cwd):
    path = Path(cwd)
    for candidate in (path, *path.parents):
        if (candidate / ".git").exists():
            return candidate.name
    return path.name or "/"


def package_name(path):
    match = STORE_NAME.search(path or "")
    return match.group(1) if match else (path or "unknown")


def otlp_attr(key, value):
    if isinstance(value, bool):
        encoded = {"boolValue": value}
    elif isinstance(value, int):
        encoded = {"intValue": str(value)}
    elif isinstance(value, float):
        encoded = {"doubleValue": value}
    else:
        encoded = {"stringValue": str(value)}
    return {"key": key, "value": encoded}


class Observer:
    def __init__(self, command, argv):
        self.command = command
        self.argv = argv
        self.cwd = os.getcwd()
        self.project = project_name(self.cwd)
        self.host = socket.gethostname()
        self.kind = os.environ.get("NIX_OBSERVER_KIND", self.detect_kind())
        self.unattended = os.environ.get("NIX_OBSERVER_UNATTENDED") == "1"
        self.target = os.environ.get("NIX_OBSERVER_TARGET", self.host)
        self.trace_id = secrets.token_hex(16)
        self.root_span_id = secrets.token_hex(8)
        self.started = time.time_ns()
        self.activities = {}
        self.completed = []
        self.error = ""
        self.failed_drv = ""
        self.compiled = 0
        self.substituted = 0
        self.closure_paths = 0
        self.closure_nar_bytes = 0

    def detect_kind(self):
        joined = " ".join(self.argv)
        if "nixos-rebuild" in joined or self.command == "nixos-rebuild":
            return "rebuild"
        if self.command == "home-manager":
            return "home-rebuild"
        return "nix-build"

    def has_build_intent(self):
        if self.command in {
            "nix-build",
            "nix-env",
            "nix-prefetch-url",
            "nix-shell",
            "nixos-rebuild",
            "home-manager",
            "nh",
        }:
            return True
        if self.command != "nix":
            return False
        words = [arg for arg in self.argv if not arg.startswith("-")]
        if not words:
            return False
        pair = " ".join(words[:2])
        return words[0] in {"build", "develop", "run", "shell"} or pair in {
            "flake check",
            "profile install",
            "profile upgrade",
            "store repair",
        }

    def span_id(self, activity_id):
        return hashlib.blake2b(str(activity_id).encode(), digest_size=8).hexdigest()

    def parse(self, raw):
        if not raw.startswith("@nix "):
            return
        try:
            event = json.loads(raw[5:])
        except json.JSONDecodeError:
            return
        action = event.get("action")
        activity_id = event.get("id")
        if action == "start":
            fields = event.get("fields", [])
            text = event.get("text", "")
            drv = fields[0] if fields and isinstance(fields[0], str) and fields[0].endswith(".drv") else ""
            classification = "activity"
            if drv:
                classification = "compiled_remote" if len(fields) > 1 and fields[1] else "compiled_local"
                self.compiled += 1
            elif re.search(r"copy|download|fetch|substitut", text, re.I):
                classification = "substituted"
                self.substituted += 1
            self.activities[activity_id] = {
                "id": activity_id,
                "parent": event.get("parent", 0),
                "started": time.time_ns(),
                "text": text,
                "fields": fields,
                "drv": drv,
                "package": package_name(drv or text),
                "classification": classification,
                "builder": str(fields[1]) if drv and len(fields) > 1 and fields[1] else self.host,
                "phase": "",
                "logs": tempfile.TemporaryFile(mode="w+t", encoding="utf-8") if drv else None,
            }
        elif action == "result" and activity_id in self.activities:
            activity = self.activities[activity_id]
            fields = event.get("fields", [])
            if event.get("type") == BUILD_PHASE and fields:
                activity["phase"] = str(fields[0])
            if event.get("type") == BUILD_LOG and fields and activity["logs"]:
                activity["logs"].write(str(fields[0]) + "\n")
        elif action == "stop" and activity_id in self.activities:
            activity = self.activities.pop(activity_id)
            activity["ended"] = time.time_ns()
            self.completed.append(activity)
        elif action == "msg":
            message = event.get("msg", "")
            if event.get("level", 1) == 0 or message.startswith("error:"):
                self.error = message
                match = re.search(r"(/nix/store/[0-9a-z]{32}-[^ '\"]+\.drv)", message)
                if match:
                    self.failed_drv = match.group(1)

    def log(self, event):
        event.update(
            {
                "host": self.host,
                "project": self.project,
                "trace_id": self.trace_id,
                "kind": self.kind,
                "target": self.target,
            }
        )
        identifier = "nix-observer-summary" if event["event"] == "nix_build" else "nix-observer"
        syslog.openlog(identifier)
        syslog.syslog(syslog.LOG_INFO, json.dumps(event, separators=(",", ":")))

    def export_trace(self, exit_code, ended):
        spans = []
        for activity in self.completed:
            attributes = {
                "host.name": self.host,
                "nix.project": self.project,
                "nix.kind": self.kind,
                "nix.classification": activity["classification"],
                "nix.package": activity["package"],
                "nix.derivation": activity["drv"],
                "nix.phase": activity["phase"],
                "nix.builder": activity["builder"],
            }
            parent = self.root_span_id
            if activity["parent"] in {item["id"] for item in self.completed}:
                parent = self.span_id(activity["parent"])
            failed = bool(exit_code and activity["drv"] == self.failed_drv)
            spans.append(
                {
                    "traceId": self.trace_id,
                    "spanId": self.span_id(activity["id"]),
                    "parentSpanId": parent,
                    "name": activity["package"] if activity["drv"] else activity["text"],
                    "kind": 1,
                    "startTimeUnixNano": str(activity["started"]),
                    "endTimeUnixNano": str(activity["ended"]),
                    "attributes": [otlp_attr(key, value) for key, value in attributes.items() if value],
                    "status": {"code": 2 if failed else 1, "message": self.error if failed else ""},
                }
            )
        root_attrs = {
            "host.name": self.host,
            "nix.project": self.project,
            "nix.kind": self.kind,
            "nix.target": self.target,
            "nix.command": redact(shlex.join([self.command, *self.argv])),
            "nix.unattended": self.unattended,
            "nix.exit_code": exit_code,
            "nix.compiled": self.compiled,
            "nix.substituted": self.substituted,
            "nix.closure_paths": self.closure_paths,
            "nix.closure_nar_bytes": self.closure_nar_bytes,
        }
        spans.append(
            {
                "traceId": self.trace_id,
                "spanId": self.root_span_id,
                "name": f"{self.kind} {self.project}",
                "kind": 1,
                "startTimeUnixNano": str(self.started),
                "endTimeUnixNano": str(ended),
                "attributes": [otlp_attr(key, value) for key, value in root_attrs.items()],
                "status": {"code": 2 if exit_code else 1, "message": self.error if exit_code else ""},
            }
        )
        payload = {
            "resourceSpans": [
                {
                    "resource": {
                        "attributes": [
                            otlp_attr("service.name", "nix-build"),
                            otlp_attr("host.name", self.host),
                        ]
                    },
                    "scopeSpans": [{"scope": {"name": "nix-observer"}, "spans": spans}],
                }
            ]
        }
        request = urllib.request.Request(
            "http://127.0.0.1:14318/v1/traces",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
        )
        try:
            urllib.request.urlopen(request, timeout=0.25).read()
        except Exception:
            pass

    def closure_summary(self):
        if self.failed_drv:
            return
        derivations = sorted({activity["drv"] for activity in self.completed if activity["drv"]})
        if not derivations:
            return
        real_store = os.environ.get("NIX_OBSERVER_REAL_NIX_STORE")
        real_nix = os.environ.get("NIX_OBSERVER_REAL_NIX")
        if not real_store or not real_nix:
            return
        try:
            outputs = subprocess.run(
                [real_store, "--query", "--outputs", *derivations],
                check=True,
                capture_output=True,
                text=True,
                timeout=30,
            ).stdout.split()
            if not outputs:
                return
            info = subprocess.run(
                [real_nix, "path-info", "--json", "-S", "-r", *outputs],
                check=True,
                capture_output=True,
                text=True,
                timeout=60,
            )
            paths = json.loads(info.stdout)
            items = paths.values() if isinstance(paths, dict) else paths
            self.closure_paths = len(paths)
            self.closure_nar_bytes = sum(item.get("narSize", 0) for item in items)
        except (OSError, subprocess.SubprocessError, json.JSONDecodeError):
            pass

    def finish(self, exit_code):
        ended = time.time_ns()
        for activity in list(self.activities.values()):
            activity["ended"] = ended
            self.completed.append(activity)
        duration = (ended - self.started) / 1_000_000_000
        if exit_code and not self.failed_drv:
            candidates = [activity["drv"] for activity in self.completed if activity["drv"]]
            if candidates:
                self.failed_drv = candidates[-1]
        self.closure_summary()
        failed_package = package_name(self.failed_drv) if self.failed_drv else ""
        for activity in self.completed:
            if not activity["drv"]:
                continue
            failed = bool(exit_code and activity["drv"] == self.failed_drv)
            self.log(
                {
                    "event": "nix_derivation",
                    "package": activity["package"],
                    "derivation": activity["drv"],
                    "classification": activity["classification"],
                    "duration_seconds": round((activity["ended"] - activity["started"]) / 1e9, 3),
                    "status": "failed" if failed else "success",
                    "phase": activity["phase"],
                    "builder": activity["builder"],
                }
            )
            if failed and activity["logs"]:
                activity["logs"].seek(0)
                for line in activity["logs"]:
                    self.log(
                        {
                            "event": "nix_build_log",
                            "package": activity["package"],
                            "derivation": activity["drv"],
                            "message": redact(line.rstrip("\n")),
                        }
                    )
            if activity["logs"]:
                activity["logs"].close()
        if not (self.has_build_intent() or self.compiled or self.substituted or self.kind != "nix-build"):
            return
        alert_eligible = self.unattended or self.kind in {"rebuild", "home-rebuild"}
        self.log(
            {
                "event": "nix_build",
                "status": "failed" if exit_code else "success",
                "exit_code": exit_code,
                "duration_seconds": round(duration, 3),
                "compiled": self.compiled,
                "substituted": self.substituted,
                "required": self.compiled + self.substituted,
                "closure_paths": self.closure_paths,
                "closure_nar_bytes": self.closure_nar_bytes,
                "failed_package": failed_package,
                "error": redact(self.error),
                "alert_eligible": alert_eligible,
                "command": redact(shlex.join([self.command, *self.argv])),
                "cwd": self.cwd,
            }
        )
        self.export_trace(exit_code, ended)


def add_log_options(argv):
    if "--log-format" in argv:
        return argv
    options = ["--log-format", "internal-json", "-v"]
    if "--" in argv:
        split = argv.index("--")
        return argv[:split] + options + argv[split:]
    return argv + options


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--command", required=True)
    parser.add_argument("--real", required=True)
    options, forwarded = parser.parse_known_args()
    observer = Observer(options.command, forwarded)
    command = [options.real, *add_log_options(forwarded)]
    if os.environ.get("NIX_OBSERVER_NOVPN") == "1" and Path("/run/wrappers/bin/sg").exists():
        command = ["/run/wrappers/bin/sg", "novpn", "-c", "exec " + shlex.join(command)]
    nom = subprocess.Popen(
        [os.environ.get("NIX_OBSERVER_NOM", "nom"), "--json"],
        stdin=subprocess.PIPE,
        text=True,
    )
    child = subprocess.Popen(command, stderr=subprocess.PIPE, text=True, bufsize=1)
    try:
        for line in child.stderr:
            observer.parse(line.rstrip("\n"))
            try:
                nom.stdin.write(line)
                nom.stdin.flush()
            except BrokenPipeError:
                sys.stderr.write(line)
        exit_code = child.wait()
    except KeyboardInterrupt:
        child.send_signal(2)
        exit_code = child.wait()
    finally:
        try:
            nom.stdin.close()
        except (BrokenPipeError, AttributeError):
            pass
        nom.wait()
    observer.finish(exit_code)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
