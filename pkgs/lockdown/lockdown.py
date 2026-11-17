# lockdown: scheduled Hyprland lockdown profiles, released by a goal check or a per-day password.

import argparse
import datetime as dt
import getpass
import json
import os
import subprocess
import sys
from pathlib import Path


def env_dir(var: str, fallback: str) -> Path:
    return Path(os.environ.get(var) or Path.home() / fallback)


CONFIG = Path(os.environ.get("LOCKDOWN_CONFIG") or env_dir("XDG_CONFIG_HOME", ".config") / "lockdown/profiles.json")
STATE = env_dir("XDG_STATE_HOME", ".local/state") / "lockdown"
RUNTIME = Path(os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}") / "lockdown"


def now() -> dt.datetime:
    forced = os.environ.get("LOCKDOWN_NOW")
    return dt.datetime.fromisoformat(forced) if forced else dt.datetime.now()


def profiles() -> dict:
    return json.loads(CONFIG.read_text())


def state_path(name: str) -> Path:
    return STATE / f"{name}.json"


def load_state(name: str) -> dict:
    try:
        return json.loads(state_path(name).read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save_state(name: str, state: dict) -> None:
    STATE.mkdir(parents=True, exist_ok=True)
    tmp = state_path(name).with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2))
    tmp.replace(state_path(name))


def minutes(hhmm: str) -> int:
    h, m = hhmm.split(":")
    return int(h) * 60 + int(m)


def scheduled(profile: dict, at: dt.datetime) -> bool:
    if at.isoweekday() not in profile["days"]:
        return False
    current = at.hour * 60 + at.minute
    return minutes(profile["start"]) <= current < minutes(profile.get("end", "24:00"))


def goal_met(profile: dict) -> bool:
    check = profile.get("release_check")
    if not check:
        return False
    try:
        return subprocess.run(check, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def evaluate(name: str, profile: dict, at: dt.datetime) -> tuple[bool, str]:
    state = load_state(name)
    today = at.date().isoformat()
    if state.get("forced") == today:
        if goal_met(profile):
            state["released"] = today
            state.pop("forced")
            save_state(name, state)
            return False, "goal met"
        return True, "forced for testing"
    if not scheduled(profile, at):
        return False, "outside schedule"
    if state.get("override") == today:
        return False, "unlocked with password today"
    if state.get("released") == today:
        return False, "goal met today"
    if goal_met(profile):
        state["released"] = today
        save_state(name, state)
        return False, "goal met today"
    return True, "scheduled"


def lua_string(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def lua_rules(rules: list[dict]) -> str:
    items = []
    for rule in rules:
        fields = ", ".join(f"{k} = {lua_string(v)}" for k, v in sorted(rule.items()))
        items.append("{ " + fields + " }")
    return "{ " + ", ".join(items) + " }"


def publish(active: dict | None) -> None:
    RUNTIME.mkdir(parents=True, exist_ok=True)
    lua, js = RUNTIME / "active.lua", RUNTIME / "active.json"
    if active is None:
        for f in (lua, js):
            f.unlink(missing_ok=True)
        return
    fields = [
        f"profile = {lua_string(active['profile'])}",
        f"substate = {lua_string(active['substate'])}",
        f"workspace = {lua_string(active['workspace'])}",
        f"allow = {lua_rules(active['allow'])}",
    ]
    text = "return { " + ", ".join(fields) + " }\n"
    for path, body in ((lua, text), (js, json.dumps(active))):
        tmp = path.with_suffix(".tmp")
        tmp.write_text(body)
        tmp.replace(path)


def run_hook(command: list[str] | None) -> None:
    if command:
        subprocess.run(command, check=False)


def apply(at: dt.datetime) -> dict:
    report = {}
    engaged = None
    for name, profile in sorted(profiles().items()):
        on, why = evaluate(name, profile, at)
        state = load_state(name)
        was = state.get("engaged", False)
        if on != was:
            state["engaged"] = on
            if on:
                state["substate"] = "active"
            save_state(name, state)
            run_hook(profile.get("on_engage") if on else profile.get("on_release"))
        report[name] = {"engaged": on, "reason": why, "substate": state.get("substate", "active")}
        if on and engaged is None:
            substate = state.get("substate", "active")
            allow = profile["allow"].get(substate, []) + profile.get("allow_always", [])
            engaged = {
                "profile": name,
                "substate": substate,
                "allow": allow,
                "workspace": profile.get("workspace") or name,
                "actions": profile.get("actions", []),
                "message": profile.get("message", ""),
                "reason": why,
            }
    publish(engaged)
    return report


def cmd_check(args) -> int:
    report = apply(now())
    if args.json:
        print(json.dumps(report))
    else:
        for name, r in report.items():
            print(f"{name}: {'ENGAGED' if r['engaged'] else 'released'} ({r['reason']})")
    return 0


def cmd_status(args) -> int:
    at = now()
    report = {}
    for name, profile in sorted(profiles().items()):
        state = load_state(name)
        report[name] = {
            "engaged": state.get("engaged", False),
            "substate": state.get("substate", "active"),
            "override": state.get("override") == at.date().isoformat(),
            "released": state.get("released") == at.date().isoformat(),
            "message": profile.get("message", ""),
        }
    print(json.dumps(report) if args.json else "\n".join(f"{n}: {r}" for n, r in report.items()))
    return 0


def cmd_unlock(args) -> int:
    profile = profiles()[args.profile]
    if sys.stdin.isatty():
        attempt = getpass.getpass(f"{profile.get('message') or args.profile}\npassword: ")
    else:
        attempt = sys.stdin.readline().rstrip("\n")
    if attempt != profile["password"]:
        print("wrong password", file=sys.stderr)
        return 1
    state = load_state(args.profile)
    state["override"] = now().date().isoformat()
    state.pop("forced", None)
    save_state(args.profile, state)
    apply(now())
    print(f"{args.profile} unlocked until midnight")
    return 0


def cmd_state(args) -> int:
    profile = profiles()[args.profile]
    if args.substate not in profile["allow"]:
        print(f"unknown substate {args.substate}; known: {', '.join(profile['allow'])}", file=sys.stderr)
        return 2
    state = load_state(args.profile)
    state["substate"] = args.substate
    save_state(args.profile, state)
    apply(now())
    return 0


def cmd_force(args) -> int:
    profiles()[args.profile]
    state = load_state(args.profile)
    state["forced"] = now().date().isoformat()
    state.pop("override", None)
    state.pop("released", None)
    save_state(args.profile, state)
    apply(now())
    return 0


def cmd_prompt(args) -> int:
    active = json.loads((RUNTIME / "active.json").read_text()) if (RUNTIME / "active.json").exists() else None
    if not active:
        print("no lockdown engaged")
        input("press enter to close")
        return 0
    print(active.get("message") or active["profile"])
    print(f"reason: {active['reason']}\n")
    while True:
        try:
            attempt = getpass.getpass("password (empty to cancel): ")
        except EOFError:
            return 1
        if not attempt:
            return 1
        result = subprocess.run([sys.argv[0], "unlock", active["profile"]], input=attempt + "\n", text=True, capture_output=True)
        print(result.stdout.strip() or result.stderr.strip())
        if result.returncode == 0:
            input("press enter to close")
            return 0


def main() -> int:
    parser = argparse.ArgumentParser(prog="lockdown")
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("check")
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_check)
    p = sub.add_parser("status")
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_status)
    p = sub.add_parser("unlock")
    p.add_argument("profile")
    p.set_defaults(fn=cmd_unlock)
    p = sub.add_parser("state")
    p.add_argument("profile")
    p.add_argument("substate")
    p.set_defaults(fn=cmd_state)
    p = sub.add_parser("force")
    p.add_argument("profile")
    p.set_defaults(fn=cmd_force)
    p = sub.add_parser("prompt")
    p.set_defaults(fn=cmd_prompt)
    args = parser.parse_args()
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
