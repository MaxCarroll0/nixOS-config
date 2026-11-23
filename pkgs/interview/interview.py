# interview: timed coding interviews with pause, review, an event stream for Claude and a practice log.

import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
import hmac
import re
import json
import math
import os
import select
import shlex
import signal
import shutil
import stat
import subprocess
import sys
import time
import tomllib
from pathlib import Path


def env_dir(var: str, fallback: str) -> Path:
    return Path(os.environ.get(var) or Path.home() / fallback)


CONFIG_PATH = Path(os.environ.get("INTERVIEW_CONFIG") or env_dir("XDG_CONFIG_HOME", ".config") / "interview/config.json")
STATE = Path(os.environ.get("INTERVIEW_STATE") or env_dir("XDG_STATE_HOME", ".local/state") / "interview")
CURRENT = STATE / "current.json"
EVENTS = STATE / "events.jsonl"
LOG = STATE / "log.jsonl"
LOCK = STATE / "lock"
SNOOZE = STATE / "snooze"
SETTINGS = STATE / "settings.json"
LOCKDOWN_PROFILES = Path(os.environ.get("LOCKDOWN_CONFIG") or env_dir("XDG_CONFIG_HOME", ".config") / "lockdown/profiles.json")

WEEKDAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
DIFFICULTIES = ["easy", "easy-medium", "medium", "medium-hard", "hard"]
RULES = [
    "A short statement with examples and constraints, solvable within the coding time at the track's difficulty.",
    "Solved as one function or a small API in the track's language, checked by visible and hidden unit tests.",
    "Workable without an agent: the prompt, HOWTO and hint ladder are enough to make progress.",
    "Has a straightforward first approach and a better one worth discussing in review.",
]

BUILD_DIRS = {"_build", "target", "bin", "obj", "__pycache__", ".pytest_cache", "build", "improved"}
REVIEW_FILES = {"review.md", "SOLUTIONS.md", ".interview.json", "benchmarks.json"}
EXTEND_CAP_MINUTES = 15
LEGACY_MAIN = {"ocaml": "solution.ml", "rust": "src/lib.rs", "c": "solution.c", "csharp": "Solution.cs", "python": "solution.py"}

EVENT_GUIDE = {
    "STARTED": "Interview clock started. Present the problem, then interview.",
    "WARN_15": "15 minutes of coding left. Make sure a working solution exists before polishing.",
    "WARN_5": "5 minutes of coding left. No new subproblems; help the candidate land and test what they have.",
    "PAUSED": "Candidate paused the clock and is with the tutor. Do not continue the interview until RESUMED.",
    "RESUMED": "Clock running again. Pick up where the interview left off.",
    "EXTENDED": "You extended the coding clock for an environment fault; the new time left is in `interview status`.",
    "FINISH_APPROVED": "You approved finishing early; the candidate can now press Finish early, or run `interview done` yourself if they asked to finish.",
    "HINT": "The candidate took the next ladder rung themselves; do not repeat it, build on it.",
    "CODING_OVER": "Coding phase over and the submission is frozen. Stop coaching and run /review now.",
    "REVIEW_WARN": "3 minutes of review left. Give the remaining top improvements and wrap up.",
    "REVIEW_OVER": "Review over and the interview is logged. Sign off in two lines; the next interview starts automatically after the break with a fresh interviewer.",
}


def track_entry(name: str, langs: list[str], context: str = "", difficulty: str = "easy-medium",
                enabled: bool = True, coding_minutes: int | None = None, review_minutes: int | None = None, **_) -> dict:
    return {"name": name, "langs": list(langs), "context": context, "difficulty": difficulty, "enabled": enabled,
            "coding_minutes": coding_minutes, "review_minutes": review_minutes}


def track_minutes(cfg: dict, track: str | None, key: str) -> int:
    entry = next((t for t in cfg["tracks"] if t["name"] == track), {})
    value = entry.get(key)
    return cfg[key] if value is None else value


def normal_tracks(tracks) -> list[dict]:
    if isinstance(tracks, dict):
        return [track_entry(name, langs) for name, langs in tracks.items()]
    return [track_entry(**t) for t in tracks]


def base_config() -> dict:
    cfg = {
        "repo": str(Path.home() / "Jobs/general"),
        "coding_minutes": 45,
        "review_minutes": 15,
        "required_per_day": 2,
        "context": "",
        "lockdown": True,
        "tracks": {"ocaml": ["ocaml"], "systems": ["rust", "c"], "managed": ["csharp", "python"]},
        "on_pause": None,
        "on_resume": None,
        "on_complete": None,
        "on_start": None,
        "auto": {"enabled": False, "days": ["Mon", "Tue", "Wed", "Thu", "Fri"], "start": "05:00", "break_minutes": 5, "snooze_minutes": 15},
    }
    with contextlib.suppress(FileNotFoundError):
        cfg.update(json.loads(CONFIG_PATH.read_text()))
    cfg["tracks"] = normal_tracks(cfg["tracks"])
    return cfg


def editable(cfg: dict) -> dict:
    auto = cfg["auto"]
    return {
        "days": [d for d in WEEKDAYS if d in auto["days"]],
        "start": auto["start"],
        "from": auto.get("from") or "",
        "auto_start": bool(auto.get("enabled")),
        "lockdown": bool(cfg.get("lockdown", True)),
        "coding_minutes": cfg["coding_minutes"],
        "review_minutes": cfg["review_minutes"],
        "break_minutes": auto["break_minutes"],
        "snooze_minutes": auto["snooze_minutes"],
        "required_per_day": cfg["required_per_day"],
        "context": cfg.get("context", ""),
        "tracks": cfg["tracks"],
    }


def overlay(cfg: dict, settings: dict) -> dict:
    auto = cfg["auto"]
    for key, target in (("days", "days"), ("start", "start"), ("from", "from"), ("auto_start", "enabled"),
                        ("break_minutes", "break_minutes"), ("snooze_minutes", "snooze_minutes")):
        if key in settings:
            auto[target] = settings[key]
    for key in ("lockdown", "coding_minutes", "review_minutes", "required_per_day", "context"):
        if key in settings:
            cfg[key] = settings[key]
    if "tracks" in settings:
        cfg["tracks"] = normal_tracks(settings["tracks"])
    return cfg


def lockdown_password(cfg: dict) -> str | None:
    try:
        return json.loads(LOCKDOWN_PROFILES.read_text())[cfg["auto"]["lockdown_profile"]]["password"]
    except (OSError, KeyError, TypeError, json.JSONDecodeError):
        return None


def sign(password: str, settings: dict) -> str:
    return hmac.new(password.encode(), json.dumps(settings, sort_keys=True).encode(), hashlib.sha256).hexdigest()


def stored_settings(cfg: dict) -> dict:
    try:
        doc = json.loads(SETTINGS.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}
    password = lockdown_password(cfg)
    if not password or not isinstance(doc, dict) or not hmac.compare_digest(str(doc.get("signature", "")), sign(password, doc.get("settings", {}))):
        return {}
    return doc["settings"]


def config() -> dict:
    cfg = base_config()
    return overlay(cfg, stored_settings(cfg))


def languages(repo: str | None = None) -> dict[str, dict]:
    root = Path(repo or base_config()["repo"], "langs")
    out = {}
    for path in sorted(root.glob("*/lang.toml")):
        with contextlib.suppress(OSError, tomllib.TOMLDecodeError):
            meta = tomllib.loads(path.read_text())
            out[path.parent.name] = {"id": path.parent.name, "name": meta.get("name", path.parent.name),
                                     "colour": meta.get("colour", ""), "main": meta["main"], "scaffold": meta.get("scaffold", False)}
    for lang, main in LEGACY_MAIN.items():
        out.setdefault(lang, {"id": lang, "name": lang, "colour": "", "main": main, "scaffold": True})
    return out


def main_file(lang: str) -> str:
    return languages()[lang]["main"]


def active_tracks(cfg: dict) -> list[dict]:
    return [t for t in cfg["tracks"] if t.get("enabled", True)]


def now() -> float:
    forced = os.environ.get("INTERVIEW_NOW")
    return dt.datetime.fromisoformat(forced).timestamp() if forced else time.time()


def iso(t: float) -> str:
    return dt.datetime.fromtimestamp(t).isoformat(timespec="seconds")


def day_of(t: float) -> str:
    return dt.datetime.fromtimestamp(t).date().isoformat()


@contextlib.contextmanager
def locked():
    STATE.mkdir(parents=True, exist_ok=True)
    with open(LOCK, "w") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        yield


def load_current() -> dict | None:
    try:
        return json.loads(CURRENT.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def save_current(cur: dict | None) -> None:
    if cur is None:
        CURRENT.unlink(missing_ok=True)
        return
    tmp = CURRENT.with_suffix(".tmp")
    tmp.write_text(json.dumps(cur, indent=2))
    tmp.replace(CURRENT)


def append(path: Path, entry: dict) -> None:
    STATE.mkdir(parents=True, exist_ok=True)
    with open(path, "a") as handle:
        handle.write(json.dumps(entry) + "\n")


def read_jsonl(path: Path) -> list[dict]:
    try:
        lines = path.read_text().splitlines()
    except FileNotFoundError:
        return []
    out = []
    for line in lines:
        with contextlib.suppress(json.JSONDecodeError):
            out.append(json.loads(line))
    return out


def emit(cur: dict, event: str, detail: str = "") -> None:
    append(EVENTS, {"t": iso(now()), "event": event, "session": cur["id"], "detail": detail})


def log(kind: str, cur: dict, start: float, end: float, **extra) -> None:
    append(LOG, {
        "kind": kind,
        "date": day_of(start),
        "start": iso(start),
        "end": iso(end),
        "seconds": round(end - start),
        "session": cur["id"],
        "track": cur["track"],
        "lang": cur["lang"],
        "problem": cur["problem"],
        **extra,
    })


def coding_used(cur: dict, at: float) -> float:
    used = cur["used_before"]
    if cur.get("running_since") is not None:
        used += at - cur["running_since"]
    return used


def coding_left(cur: dict, at: float) -> float:
    return cur["coding_budget"] - coding_used(cur, at)


def review_left(cur: dict, at: float) -> float:
    return cur["review_budget"] - (at - cur["review_started"])


def run_hook(command: list[str] | None) -> None:
    if command:
        subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def git(repo: Path, *args: str, check: bool = False) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=check)


def solution_files(root: Path):
    for path in root.rglob("*"):
        if any(part in BUILD_DIRS for part in path.relative_to(root).parts):
            continue
        if path.is_file() and path.name not in REVIEW_FILES:
            yield path


def digest(root: Path) -> str:
    h = hashlib.sha256()
    for path in sorted(solution_files(root)):
        h.update(str(path.relative_to(root)).encode() + b"\0" + path.read_bytes() + b"\0")
    return h.hexdigest()


def freeze(cur: dict) -> None:
    repo = Path(config()["repo"])
    session = Path(cur["dir"])
    for path in solution_files(session):
        mode = path.stat().st_mode
        path.chmod(mode & ~(stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH))
    git(repo, "add", "--", str(session))
    git(repo, "commit", "-q", "-m", f"interview: submission {cur['id']}", "--", str(session))
    git(repo, "tag", "-f", f"sub/{cur['id']}")
    elisp = (
        "(dolist (b (buffer-list)) (with-current-buffer b"
        f" (when (and buffer-file-name (string-prefix-p {json.dumps(str(session))} buffer-file-name))"
        " (revert-buffer t t t) (read-only-mode 1))))"
    )
    with contextlib.suppress(OSError, subprocess.TimeoutExpired):
        subprocess.run(["emacsclient", "--eval", elisp], capture_output=True, timeout=5)


REVIEW_TEMPLATE = """# Review: {lang} {problem}

Fill this in during the review phase. Compare against SOLUTIONS.md beside it.

## Result

- finished: {how} after {minutes} active minutes
- hidden tests: {hidden} (rerun with `interview submit-tests`; full output is shown during review)
- benchmark, the ideal complexity: {benchmark}
- hints used: {hints}
- extended: {extended}

## My approach

- method:
- time and space:

## Against the listed solutions

- closest listed method:
- what the better method does that mine does not:

## Mistakes and slow spots

-

## Three improvements

1.
2.
3.

## Revisit

- redo in `improved/` (`interview revisit {dir}`)? yes / no
"""


def extended_minutes(cur: dict) -> int:
    return sum(e["minutes"] for e in cur.get("extensions", []))


def extensions_line(cur: dict) -> str:
    given = cur.get("extensions", [])
    if not given:
        return "no"
    return "; ".join(f"{e['minutes']} min ({e['reason']})" for e in given)


def open_review(cur: dict, early: bool) -> None:
    session = Path(cur["dir"])
    solutions = problem_dir(cur["problem"]) / "SOLUTIONS.md"
    with contextlib.suppress(OSError):
        if solutions.exists():
            shutil.copyfile(solutions, session / "SOLUTIONS.md")
        review = session / "review.md"
        if not review.exists():
            review.write_text(REVIEW_TEMPLATE.format(
                lang=cur["lang"], problem=cur["problem"], dir=cur["dir"],
                how="early" if early else "at time", minutes=round(cur["used_before"] / 60),
                hidden=cur.get("hidden_tests") or "not run", benchmark=cur.get("benchmark") or "not run", hints=len(cur.get("hints", [])),
                extended=extensions_line(cur)))


def end_coding(cur: dict, at: float, early: bool) -> dict:
    if cur.get("running_since") is not None:
        cur["used_before"] = coding_used(cur, at)
        cur["running_since"] = None
    if cur["phase"] == "paused":
        log("paused", cur, cur["pause_started"], at)
        cur["pause_seconds"] += at - cur["pause_started"]
        run_hook(config()["on_resume"])
    log("coding", cur, cur["started"], at, seconds=round(cur["used_before"]), active=round(cur["used_before"]), early=early)
    freeze(cur)
    open_review(cur, early)
    cur["phase"] = "review"
    cur["review_started"] = at
    cur["early"] = early
    emit(cur, "CODING_OVER", f"{'finished early' if early else 'time up'} after {round(cur['used_before'] / 60)} active minutes; submission tagged sub/{cur['id']}")
    return cur


def finish(cur: dict, at: float, reason: str) -> None:
    log("review", cur, cur["review_started"], at)
    log("complete", cur, cur["started"], at,
        coding=round(cur["used_before"]), pauses=round(cur["pause_seconds"]),
        review=round(at - cur["review_started"]), early=cur.get("early", False),
        hidden_tests=cur.get("hidden_tests"), benchmark=cur.get("benchmark"), dir=cur["dir"],
        worked=edited(cur["problem"], cur["lang"], cur["dir"]))
    meta = {k: v for k, v in cur.items() if k not in ("running_since",)}
    meta["finished"] = iso(at)
    with contextlib.suppress(OSError):
        Path(cur["dir"], ".interview.json").write_text(json.dumps(meta, indent=2))
    emit(cur, "REVIEW_OVER", reason)
    save_current(None)
    run_hook(config()["on_complete"])


def tick(at: float) -> None:
    cur = load_current()
    if not cur:
        return
    warned = set(cur.get("warned", []))
    if cur["phase"] == "coding":
        left = coding_left(cur, at)
        for mark, name in ((15 * 60, "WARN_15"), (5 * 60, "WARN_5")):
            if left <= mark and name not in warned and cur["coding_budget"] > mark:
                warned.add(name)
                cur["warned"] = sorted(warned)
                emit(cur, name, f"{max(0, round(left / 60))} minutes left")
        if left <= 0:
            cur = end_coding(cur, at, early=False)
        save_current(cur)
    elif cur["phase"] == "review":
        left = review_left(cur, at)
        if left <= 3 * 60 and "REVIEW_WARN" not in warned:
            warned.add("REVIEW_WARN")
            cur["warned"] = sorted(warned)
            emit(cur, "REVIEW_WARN", f"{max(0, round(left / 60))} minutes left")
            save_current(cur)
        if left <= 0:
            finish(cur, at, "review time up")


def edited(problem: str, lang: str, session: str) -> bool:
    main = languages().get(lang, {}).get("main")
    if not main:
        return True
    try:
        return Path(session, main).read_bytes() != (problem_dir(problem) / "templates" / lang / main).read_bytes()
    except OSError:
        return False


def worked(e: dict) -> bool:
    if "worked" in e:
        return e["worked"]
    return edited(e["problem"], e["lang"], e.get("dir", ""))


def completed_on(date: str) -> list[dict]:
    return [e for e in read_jsonl(LOG) if e["kind"] == "complete" and e["date"] == date and worked(e)]


def schedule() -> dict:
    try:
        return tomllib.loads(Path(config()["repo"], "schedule.toml").read_text())
    except (FileNotFoundError, tomllib.TOMLDecodeError):
        return {}


def interview_day(at: float) -> bool:
    auto = config()["auto"]
    moment = dt.datetime.fromtimestamp(at)
    if auto.get("from") and moment.date().isoformat() < auto["from"]:
        return False
    return moment.strftime("%a") in auto["days"]


def plan_today(at: float) -> list[dict]:
    cfg = config()
    today = day_of(at)
    due = "pending" if interview_day(at) else "off"
    done = {e["track"]: e for e in completed_on(today)}
    history = [e for e in read_jsonl(LOG) if e["kind"] == "complete"]
    planned = schedule().get(today, {})
    cur = load_current()
    out = []
    claimed = set()
    for entry in active_tracks(cfg):
        track, langs = entry["name"], entry["langs"]
        if track in done:
            out.append({"track": track, "lang": done[track]["lang"], "status": "done", "problem": done[track]["problem"]})
            continue
        if cur and cur["track"] == track:
            out.append({"track": track, "lang": cur["lang"], "status": cur["phase"], "problem": cur["problem"]})
            continue
        slot = planned.get(track)
        if isinstance(slot, dict) and slot.get("problem"):
            out.append({"track": track, "lang": slot.get("lang", langs[0]), "status": due, "problem": slot["problem"]})
            continue
        lang = next((lang for lang in langs if isinstance(planned.get(lang), str) and lang not in claimed), None)
        if lang:
            claimed.add(lang)
            out.append({"track": track, "lang": lang, "status": due, "problem": planned[lang]})
            continue
        count = sum(1 for e in history if e["track"] == track)
        out.append({"track": track, "lang": langs[count % len(langs)], "status": due, "problem": None})
    return out


def pick(at: float, choice: str | None) -> tuple[str, str, str] | str:
    plan = [p for p in plan_today(at) if p["status"] == "pending"]
    if choice:
        plan = [p for p in plan if choice in (p["track"], p["lang"])]
    for p in plan:
        if p["problem"]:
            return p["track"], p["lang"], p["problem"]
    if not plan:
        return f"nothing pending today{' for ' + choice if choice else ''}; see `interview today`"
    return f"no problem scheduled today for {plan[0]['lang']}; add one to schedule.toml or pass LANG PROBLEM"


def status_dict(at: float) -> dict:
    cfg = config()
    cur = load_current()
    today = day_of(at)
    out = {
        "now": iso(at),
        "date": today,
        "completed_today": len({e["track"] for e in completed_on(today)}),
        "required_per_day": cfg["required_per_day"],
        "phase": "idle",
        "interview_day": interview_day(at),
    }
    if cur:
        out.update({
            "phase": cur["phase"],
            "session": cur["id"],
            "track": cur["track"],
            "lang": cur["lang"],
            "problem": cur["problem"],
            "dir": cur["dir"],
            "main": str(Path(cur["dir"]) / main_file(cur["lang"])),
            "coding_budget": cur["coding_budget"],
            "used_before": cur["used_before"],
            "running_since": cur.get("running_since"),
            "pause_started": cur.get("pause_started"),
            "pause_seconds": cur["pause_seconds"],
            "finish_approved": cur.get("finish_approved"),
            "extended_minutes": extended_minutes(cur),
            "hidden_tests": cur.get("hidden_tests"),
            "benchmark": cur.get("benchmark") and (cur["benchmark"].split(" (")[0] if cur["phase"] in ("coding", "paused") else cur["benchmark"]),
            "hints": len(cur.get("hints", [])),
        })
        if cur["phase"] in ("coding", "paused"):
            out["can_finish"] = bool(cur.get("finish_approved")) or (
                cur.get("hidden_tests") == "pass" and cur.get("hidden_digest") == digest(Path(cur["dir"])))
        if cur["phase"] in ("coding", "paused"):
            out["coding_left"] = max(0, round(coding_left(cur, at)))
        if cur["phase"] == "review":
            out["review_started"] = cur["review_started"]
            out["review_budget"] = cur["review_budget"]
            out["review_left"] = max(0, round(review_left(cur, at)))
    return out


def status_line(s: dict) -> str:
    head = f"[interview clock {s['now']}] today {s['completed_today']}/{s['required_per_day']} required interviews done."
    if s["phase"] == "idle":
        if not s["interview_day"]:
            return f"[interview clock {s['now']}] No interviews today; nothing is due."
        return head + " No interview running."
    where = f"{s['lang']} {s['problem']} ({s['dir']})"
    if s["phase"] == "coding":
        approved = " Finishing early is allowed (approved or hidden tests pass)." if s.get("can_finish") else ""
        return head + f" CODING {where}: {s['coding_left'] // 60}m{s['coding_left'] % 60:02d}s of coding left; scope every request to fit.{approved}"
    if s["phase"] == "paused":
        return head + f" PAUSED {where}: clock stopped with {s['coding_left'] // 60}m{s['coding_left'] % 60:02d}s left; candidate is with the tutor."
    return head + f" REVIEW {where}: {s['review_left'] // 60}m{s['review_left'] % 60:02d}s of review left; submission frozen at tag sub/{s['session']}."


def problem_dir(problem: str) -> Path:
    return Path(config()["repo"], "problems", problem)


HOWTO = """# Working on {lang} {problem}

The clock is running: {minutes} minutes of coding, paused with SUPER+F5 or the bar. Read PROMPT.md,
then edit {main}. All commands work without the interviewer.

| step | command |
|---|---|
| run the visible tests | `interview run` |
| run the hidden tests, then the benchmark (pass or fail and a count, met or not met) | `interview submit-tests` |
| next hint from the ladder | `interview hint` |
| time left | `interview status` |
| finish early (hidden tests passed on the current code) | `interview done` |
| end the review and log the interview | `interview close` |

`interview done` works once `interview submit-tests` has passed on exactly the files as they are
now; otherwise wait for the clock, or ask the interviewer to approve. Hidden tests are small: any
correct solution passes them, brute force included, and passing them solves the problem. The
benchmark runs large inputs against a time limit per case; meeting it is the ideal complexity, not
a requirement. When coding ends the files
freeze, and SOLUTIONS.md (a short list of methods with their complexity) and a review.md
template appear here. During review, `interview submit-tests` shows the full hidden output and
`interview hint --all` the whole ladder with its follow-ups. Compare your approach against
SOLUTIONS.md, fill in review.md, then `interview close`.
"""


def emacs_open(*paths: Path) -> bool:
    with contextlib.suppress(OSError, subprocess.TimeoutExpired):
        frames = subprocess.run(["emacsclient", "--eval", "(seq-some (lambda (f) (and (window-system f) (frame-visible-p f))) (frame-list))"],
                                capture_output=True, text=True, timeout=5)
        create = ["-c"] if frames.stdout.strip() in ("", "nil") else []
        return subprocess.run(["emacsclient", *create, "-n", *map(str, paths)], capture_output=True, timeout=10).returncode == 0
    return False


def open_files(dest: Path, lang: str) -> None:
    emacs_open(dest / "PROMPT.md", dest / main_file(lang))


def begin(at: float, lang: str | None, problem: str | None, minutes: int | None = None,
          review_minutes: int | None = None, again: bool = False, track: str | None = None) -> tuple[dict, Path] | str:
    cfg = config()
    known = languages(cfg["repo"])
    if load_current():
        return "an interview is already running; see `interview status`"
    if not problem:
        if lang is not None and lang not in known and lang not in {t["name"] for t in cfg["tracks"]}:
            return f"unknown track or language {lang}"
        chosen = pick(at, track or lang)
        if isinstance(chosen, str):
            return chosen
        track, lang, problem = chosen
    if lang not in known:
        return f"unknown language {lang}; languages live in {Path(cfg['repo'], 'langs')}"
    track = track or next((t["name"] for t in active_tracks(cfg) if lang in t["langs"]), "extra")
    if track in {e["track"] for e in completed_on(day_of(at))} and not again:
        return f"{track} is already done today; pass --again to repeat it"
    template = problem_dir(problem) / "templates" / lang
    if not template.is_dir():
        return f"no template at {template}"
    sid = f"{day_of(at)}-{lang}-{problem}"
    dest = Path(cfg["repo"], "sessions", day_of(at), f"{lang}-{problem}")
    if dest.exists():
        return f"{dest} exists; this problem was already attempted in {lang} today"
    shutil.copytree(template, dest)
    budget = (minutes or track_minutes(cfg, track, "coding_minutes")) * 60
    prompt = problem_dir(problem) / "PROMPT.md"
    if prompt.exists():
        shutil.copyfile(prompt, dest / "PROMPT.md")
    (dest / "HOWTO.md").write_text(HOWTO.format(lang=lang, problem=problem, minutes=budget // 60, main=known[lang]["main"]))
    repo = Path(cfg["repo"])
    git(repo, "add", "--", str(dest))
    git(repo, "commit", "-q", "-m", f"interview: start {sid}", "--", str(dest))
    cur = {
        "id": sid,
        "track": track,
        "lang": lang,
        "problem": problem,
        "dir": str(dest),
        "phase": "coding",
        "started": at,
        "coding_budget": budget,
        "review_budget": (review_minutes if review_minutes is not None else track_minutes(cfg, track, "review_minutes")) * 60,
        "used_before": 0,
        "running_since": at,
        "pause_seconds": 0,
        "warned": [],
    }
    save_current(cur)
    emit(cur, "STARTED", f"{lang} {problem}, {budget // 60} minutes, files in {dest}")
    return cur, dest


def cmd_start(args) -> int:
    with locked():
        started = begin(now(), args.lang, args.problem, args.minutes, args.review_minutes, args.again, args.track)
    if isinstance(started, str):
        print(started, file=sys.stderr)
        return 1
    cur, dest = started
    print(f"started {cur['id']}: {dest}\nread {dest / 'PROMPT.md'}, edit {dest / main_file(cur['lang'])}; {dest / 'HOWTO.md'} lists the commands")
    if args.open:
        open_files(dest, cur["lang"])
    return 0


def unlocked_today(cfg: dict) -> bool:
    profile = cfg["auto"].get("lockdown_profile")
    if not profile:
        return False
    try:
        out = subprocess.run([cfg["auto"].get("lockdown", "lockdown"), "status", "--json"], capture_output=True, text=True, timeout=10).stdout
        return bool(json.loads(out).get(profile, {}).get("override"))
    except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError):
        return False


def auto_due(at: float) -> str | None:
    cfg = config()
    auto = cfg["auto"]
    moment = dt.datetime.fromtimestamp(at)
    if not auto.get("enabled"):
        return "automatic start is off"
    if auto.get("from") and moment.date().isoformat() < auto["from"]:
        return f"interviews begin on {auto['from']}"
    if moment.strftime("%a") not in auto["days"]:
        return f"no interviews on {moment.strftime('%A')}"
    if moment.strftime("%H:%M") < auto["start"]:
        return f"interviews start at {auto['start']}"
    if load_current():
        return "an interview is running"
    done = completed_on(day_of(at))
    if len({e["track"] for e in done}) >= auto.get("count", cfg["required_per_day"]):
        return "today's interviews are done"
    if done:
        last = max(dt.datetime.fromisoformat(e["end"]).timestamp() for e in done)
        wait = last + auto["break_minutes"] * 60 - at
        if wait > 0:
            return f"break: next interview in {round(wait / 60)} minutes"
    if unlocked_today(cfg):
        return "unlocked with the password today"
    return None


def snoozed(at: float) -> bool:
    try:
        return at < float(SNOOZE.read_text())
    except (FileNotFoundError, ValueError):
        return False


def ask(cfg: dict, track: str, lang: str, problem: str) -> bool:
    command = [cfg["auto"].get("notify", "notify-send"), "--app-name=interview", "--urgency=critical", "--wait",
               "--action=start=Start", "--action=later=Later",
               "Interview due", f"{lang} {problem}: start the {track_minutes(cfg, track, 'coding_minutes')}-minute clock?"]
    try:
        answer = subprocess.run(command, capture_output=True, text=True).stdout.strip()
    except OSError:
        return False
    return answer == "start"


def cmd_auto(args) -> int:
    cfg = config()
    at = now()
    with locked():
        reason = auto_due(at)
    if reason is None and snoozed(at):
        reason = "prompt snoozed"
    chosen = pick(at, None) if reason is None else reason
    if isinstance(chosen, str):
        if args.verbose:
            print(f"not starting: {chosen}")
        return 0
    track, lang, problem = chosen
    if not ask(cfg, track, lang, problem):
        SNOOZE.write_text(str(now() + cfg["auto"]["snooze_minutes"] * 60))
        print(f"declined; asking again in {cfg['auto']['snooze_minutes']} minutes")
        return 0
    with locked():
        started = begin(now(), lang, problem, track=track)
    if isinstance(started, str):
        print(started, file=sys.stderr)
        return 1
    cur, dest = started
    print(f"started {cur['id']}: {dest}")
    hook = cfg["on_start"]
    if hook:
        run_hook([*hook, str(dest / "PROMPT.md"), str(dest / main_file(cur["lang"]))])
    return 0


def mutate(fn) -> int:
    at = now()
    with locked():
        cur = load_current()
        if not cur:
            print("no interview running", file=sys.stderr)
            return 1
        message = fn(cur, at)
        if isinstance(message, int):
            return message
    if message:
        print(message)
    return 0


def do_pause(cur: dict, at: float):
    if cur["phase"] != "coding":
        print(f"cannot pause during {cur['phase']}", file=sys.stderr)
        return 1
    cur["used_before"] = coding_used(cur, at)
    cur["running_since"] = None
    cur["pause_started"] = at
    cur["phase"] = "paused"
    save_current(cur)
    emit(cur, "PAUSED", f"{round(coding_left(cur, at) / 60)} minutes left on the clock")
    run_hook(config()["on_pause"])
    return "paused"


def do_resume(cur: dict, at: float):
    if cur["phase"] != "paused":
        print(f"cannot resume during {cur['phase']}", file=sys.stderr)
        return 1
    log("paused", cur, cur["pause_started"], at)
    cur["pause_seconds"] += at - cur["pause_started"]
    cur["pause_started"] = None
    cur["running_since"] = at
    cur["phase"] = "coding"
    save_current(cur)
    emit(cur, "RESUMED", f"{round(coding_left(cur, at) / 60)} minutes left")
    run_hook(config()["on_resume"])
    return "resumed"


def do_toggle(cur: dict, at: float):
    return do_pause(cur, at) if cur["phase"] == "coding" else do_resume(cur, at)


def do_done(cur: dict, at: float):
    if cur["phase"] not in ("coding", "paused"):
        print(f"cannot finish coding during {cur['phase']}", file=sys.stderr)
        return 1
    solved = cur.get("hidden_tests") == "pass" and cur.get("hidden_digest") == digest(Path(cur["dir"]))
    if not (cur.get("finish_approved") or solved):
        print("finishing early needs `interview submit-tests` to pass on the current files, or the interviewer's approval", file=sys.stderr)
        return 1
    save_current(end_coding(cur, at, early=True))
    return "coding finished; review started"


def cmd_approve_finish(args) -> int:
    def approve(cur: dict, at: float):
        if cur["phase"] not in ("coding", "paused"):
            print(f"nothing to approve during {cur['phase']}", file=sys.stderr)
            return 1
        cur["finish_approved"] = args.reason
        save_current(cur)
        emit(cur, "FINISH_APPROVED", args.reason)
        return "finishing early approved"
    return mutate(approve)


def cmd_extend(args) -> int:
    def extend(cur: dict, at: float):
        if cur["phase"] not in ("coding", "paused"):
            print(f"the clock can only be extended before coding ends, not during {cur['phase']}", file=sys.stderr)
            return 1
        if args.minutes <= 0:
            print("extend by a positive number of minutes", file=sys.stderr)
            return 1
        room = EXTEND_CAP_MINUTES - extended_minutes(cur)
        if args.minutes > room:
            print(f"at most {EXTEND_CAP_MINUTES} minutes per interview; {room} left to grant", file=sys.stderr)
            return 1
        cur["coding_budget"] += args.minutes * 60
        cur.setdefault("extensions", []).append({"t": iso(at), "minutes": args.minutes, "reason": args.reason})
        left = coding_left(cur, at)
        cur["warned"] = [w for w in cur.get("warned", []) if not (w.startswith("WARN_") and left > int(w[5:]) * 60)]
        save_current(cur)
        emit(cur, "EXTENDED", f"{args.minutes} minutes: {args.reason}; {round(left / 60)} minutes left")
        return f"coding extended by {args.minutes} minutes; {round(left / 60)} minutes left"
    return mutate(extend)


def do_close(cur: dict, at: float):
    if cur["phase"] != "review":
        print(f"cannot close during {cur['phase']}; finish coding first with `interview done`", file=sys.stderr)
        return 1
    finish(cur, at, "review closed")
    return "interview complete"


def cmd_abandon(args) -> int:
    def abandon(cur: dict, at: float):
        if cur["phase"] not in ("coding", "paused"):
            print(f"only a coding interview can be abandoned, not one in {cur['phase']}; `interview close` ends a review", file=sys.stderr)
            return 1
        if cur["phase"] == "paused":
            log("paused", cur, cur["pause_started"], at)
            run_hook(config()["on_resume"])
        log("abandoned", cur, cur["started"], at, reason=args.reason, dir=cur["dir"])
        meta = {k: v for k, v in cur.items() if k != "running_since"}
        meta.update(abandoned=iso(at), reason=args.reason)
        session = Path(cur["dir"])
        with contextlib.suppress(OSError):
            (session / ".interview.json").write_text(json.dumps(meta, indent=2))
        repo = Path(config()["repo"])
        git(repo, "add", "--", str(session))
        git(repo, "commit", "-q", "-m", f"interview: abandon {cur['id']}", "--", str(session))
        emit(cur, "ABANDONED", args.reason)
        save_current(None)
        return f"abandoned {cur['id']}; not counted, a new interview can start"
    return mutate(abandon)


def in_shell(repo: Path, lang: str | None, command: list[str]) -> list[str]:
    if not (shutil.which("nix") and (repo / "flake.nix").exists()):
        return command
    ref = f"{repo}#{lang}" if lang and (repo / "langs" / lang / "shell.nix").exists() else str(repo)
    return ["nix", "develop", ref, "--command", "bash", "-c", shlex.join(command), "interview"]


def nix_run(repo: Path, cwd: Path, command: list[str], lang: str | None = None) -> int:
    return subprocess.run(in_shell(repo, lang, command), cwd=cwd).returncode


def session_lang(session: Path) -> str | None:
    cur = load_current()
    if cur and Path(cur["dir"]) == session:
        return cur["lang"]
    name = session.parent.name if session.name == "improved" else session.name
    lang = name.split("-", 1)[0]
    return lang if lang in languages() else None


def session_dir(arg: str | None) -> Path:
    if arg:
        return Path(arg).resolve()
    cur = load_current()
    if cur:
        return Path(cur["dir"])
    raise SystemExit("no interview running; pass a session directory")


def cmd_run(args) -> int:
    session = session_dir(args.dir)
    return nix_run(Path(config()["repo"]), session, ["just", "test"], session_lang(session))


def test_counts(output: str) -> str:
    passed = failed = 0
    for m in re.finditer(r"^(\d+)/(\d+) passed$", output, re.M):
        passed += int(m[1])
        failed += int(m[2]) - int(m[1])
    for m in re.finditer(r"test result: \w+\. (\d+) passed; (\d+) failed", output):
        passed += int(m[1])
        failed += int(m[2])
    for line in re.findall(r"^.* in [\d.]+s.*$", output, re.M):
        counts = dict((kind, int(n)) for n, kind in re.findall(r"(\d+) (passed|failed|errors?)", line))
        passed += counts.get("passed", 0)
        failed += counts.get("failed", 0) + counts.get("error", 0) + counts.get("errors", 0)
    return f"{passed}/{passed + failed} cases pass" if passed + failed else "no cases ran: the code may not compile, see `interview run`"


HIDDEN_SECONDS = 300
BENCH_BUILD_SECONDS = 300
BENCH_SETUP_SECONDS = 60


def test_copy(session: Path, extra: Path, name: str) -> Path:
    scratch = STATE / name
    shutil.rmtree(scratch, ignore_errors=True)
    shutil.copytree(session, scratch, ignore=shutil.ignore_patterns(*BUILD_DIRS, *REVIEW_FILES))
    for path in scratch.rglob("*"):
        path.chmod(path.stat().st_mode | stat.S_IWUSR)
    if extra.is_dir():
        shutil.copytree(extra, scratch, dirs_exist_ok=True)
    return scratch


def kill_group(proc: subprocess.Popen) -> None:
    with contextlib.suppress(ProcessLookupError, PermissionError):
        os.killpg(proc.pid, signal.SIGKILL)
    proc.wait()


def run_capped(command: list[str], cwd: Path, seconds: float) -> tuple[int | None, str]:
    proc = subprocess.Popen(command, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
    try:
        out, _ = proc.communicate(timeout=seconds)
        return proc.returncode, out
    except subprocess.TimeoutExpired:
        kill_group(proc)
        return None, proc.stdout.read() if proc.stdout else ""


def run_bench(command: list[str], cwd: Path) -> dict:
    proc = subprocess.Popen(command, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
    fd = proc.stdout.fileno()
    limits: list[float] = []
    done: dict[int, tuple[str, float]] = {}
    killed: tuple[int, float] | None = None
    output, pending = [], b""
    deadline, running, started = time.monotonic() + BENCH_BUILD_SECONDS, None, 0.0
    while True:
        wait = deadline - time.monotonic()
        if wait <= 0:
            if running is not None:
                killed = (running, time.monotonic() - started)
            kill_group(proc)
            break
        ready, _, _ = select.select([fd], [], [], wait)
        if not ready:
            continue
        chunk = os.read(fd, 65536)
        if not chunk:
            proc.wait()
            break
        pending += chunk
        *lines, pending = pending.split(b"\n")
        for raw in lines:
            line = raw.decode(errors="replace")
            output.append(line)
            if m := re.search(r"BENCH limits ([\d. ]*)$", line):
                limits = [float(x) for x in m[1].split()]
            elif m := re.search(r"BENCH start (\d+)", line):
                running, started = int(m[1]), time.monotonic()
                limit = limits[running] if running < len(limits) else 1.0
                deadline = started + 3 * limit + 1
            elif m := re.search(r"BENCH done (\d+) (\w+) ([\d.]+)", line):
                done[int(m[1])] = (m[2], float(m[3]))
                running, deadline = None, time.monotonic() + BENCH_SETUP_SECONDS
    cases = []
    for k, limit in enumerate(limits):
        if k in done:
            status, seconds = done[k]
            cases.append({"case": k, "limit": limit, "status": status, "seconds": seconds,
                          "met": status in ("ok", "unchecked") and seconds <= limit})
        elif killed and killed[0] == k:
            cases.append({"case": k, "limit": limit, "status": "killed", "seconds": killed[1], "met": False})
        else:
            cases.append({"case": k, "limit": limit, "status": "not run", "seconds": None, "met": False})
    return {"cases": cases, "output": output}


WRONG_STATUSES = ("wrong", "raised")


def wrong_lines(output: str) -> int:
    return len(re.findall(r"^(?:FAIL\b|test .* \.\.\. FAILED$|FAILED )", output, re.M))


def classify(hidden: str, cases: list[dict], hidden_wrong: int = 0) -> tuple[str, str]:
    if hidden == "fail":
        return "wrong", "unknown"
    if hidden == "timeout":
        return ("wrong" if hidden_wrong else "unknown"), "slow"
    if any(c["status"] in WRONG_STATUSES for c in cases):
        return "wrong", "slow" if any(c["status"] == "killed" for c in cases) else "unknown"
    if not cases:
        return ("correct" if hidden == "pass" else "unknown"), "unknown"
    return "correct", "met" if all(c["met"] for c in cases) else "slow"


def bench_summary(result: dict | None) -> str:
    if result is None:
        return "none for this problem"
    if isinstance(result, str):
        return result
    cases = result["cases"]
    met = sum(c["met"] for c in cases)
    within = f"{met}/{len(cases)} within limit"
    wrong = [c for c in cases if c["status"] in WRONG_STATUSES]
    if wrong:
        named = ", ".join(f"case {c['case']} {c['status']}" for c in wrong)
        return f"wrong answer (correctness: {named}; {within})"
    if met == len(cases):
        return f"met ({within})"
    parts = [within]
    over = sum(1 for c in cases if c["status"] in ("ok", "unchecked") and not c["met"])
    if over:
        parts.append(f"{over} finished over the limit")
    for c in cases:
        if c["status"] == "killed":
            parts.append(f"case {c['case']} too slow")
    skipped = sum(1 for c in cases if c["status"] == "not run")
    if skipped:
        parts.append(f"{skipped} not run after that")
    return f"not met: too slow (performance: {'; '.join(parts)})"


def hidden_line(hidden: str, counts: str, wrong: int) -> str:
    if hidden == "pass":
        return f"PASS ({counts})" if counts else "PASS"
    if hidden == "fail":
        return f"FAIL: wrong answer or no build (correctness{': ' + counts if counts else ''})"
    stopped = f"TIMEOUT after {HIDDEN_SECONDS}s: too slow or never ends"
    if wrong:
        return f"{stopped} (performance); also {wrong} wrong before the stop (correctness)"
    return f"{stopped} (performance; no wrong answer before the stop)"


def bench_case_line(c: dict) -> str:
    if c["status"] == "not run":
        return f"  case {c['case']}: not run (limit {c['limit']:g}s)"
    if c["status"] == "killed":
        return f"  case {c['case']}: too slow (limit {c['limit']:g}s)"
    return f"  case {c['case']}: {c['status']} in {short_time(c['seconds'])} (limit {c['limit']:g}s)"


def cmd_submit_tests(args) -> int:
    session = session_dir(args.dir)
    cur = load_current()
    meta = cur if cur and Path(cur["dir"]) == session else None
    problem = meta["problem"] if meta else session.name.split("-", 1)[1]
    lang = meta["lang"] if meta else session.name.split("-", 1)[0]
    hidden = problem_dir(problem) / "hidden" / lang
    bench = problem_dir(problem) / "bench" / lang
    secret = bool(meta) and meta["phase"] in ("coding", "paused") and not args.show
    repo = Path(config()["repo"])
    if not hidden.is_dir():
        print(f"no hidden tests at {hidden}; running visible tests only")
    state = digest(session)
    scratch = test_copy(session, hidden, "hidden-run")
    code, out = run_capped(in_shell(repo, lang, ["just", "test"]), scratch, HIDDEN_SECONDS)
    shutil.rmtree(scratch, ignore_errors=True)
    hidden_result = "timeout" if code is None else "pass" if code == 0 else "fail"
    if not secret:
        print(out, end="" if out.endswith("\n") else "\n")
    print(f"hidden tests: {hidden_line(hidden_result, test_counts(out) if secret else '', wrong_lines(out))}")
    if hidden_result != "pass":
        bench_result = "skipped (hidden tests do not pass)"
    elif not bench.is_dir():
        bench_result = None
    else:
        scratch = test_copy(session, bench, "bench-run")
        bench_result = run_bench(in_shell(repo, lang, ["just", "bench"]), scratch)
        shutil.rmtree(scratch, ignore_errors=True)
        if not bench_result["cases"]:
            if not secret:
                print("\n".join(bench_result["output"][-30:]))
            bench_result = "not run (the benchmark did not build)"
    line = bench_summary(bench_result)
    print(f"benchmark: {line.split(' (')[0] if secret and isinstance(bench_result, dict) else line}")
    if not secret and isinstance(bench_result, dict):
        for c in bench_result["cases"]:
            print(bench_case_line(c))
    if meta:
        with locked():
            cur = load_current()
            if cur and cur["id"] == meta["id"]:
                cur["hidden_tests"] = hidden_result
                cur["hidden_digest"] = state if hidden_result == "pass" else None
                cur["benchmark"] = line
                save_current(cur)
    if secret and hidden_result == "pass" and meta["phase"] == "coding":
        print("you may finish early now with `interview done` (or keep improving)")
    return 0 if hidden_result == "pass" else 1


ALIAS_LANGS = {"ocaml": "let {fn} = {expr}", "python": "{fn} = {expr}"}
FORWARD_LANGS = {"rust", "c", "csharp"}


def target_name(problem: str, lang: str) -> str:
    spec = problem_dir(problem) / "spec.json"
    name = json.loads(spec.read_text())["name"] if spec.exists() else problem.split("-", 1)[1].replace("-", "_")
    if lang == "csharp":
        return "".join(part.capitalize() for part in name.split("_"))
    return name


def closing_paren(text: str, i: int) -> int:
    depth = 0
    for j in range(i, len(text)):
        depth += {"(": 1, ")": -1}.get(text[j], 0)
        if depth == 0:
            return j
    raise ValueError("unbalanced parentheses")


def param_names(params: str) -> list[str]:
    names, depth, cur = [], 0, ""
    for ch in params + ",":
        if ch in "(<[":
            depth += 1
        elif ch in ")>]":
            depth -= 1
        if ch == "," and depth == 0:
            if cur.strip():
                names.append(re.findall(r"\w+", cur)[-1])
            cur = ""
        else:
            cur += ch
    return names


def candidate_definition(text: str, fn: str) -> tuple[int, int, int]:
    for m in re.finditer(rf"\b{fn}\s*\(", text):
        close = closing_paren(text, m.end() - 1)
        if re.match(r"\s*(\{|=>|->)", text[close + 1:]):
            line = text.rfind("\n", 0, m.start()) + 1
            return line, m.start(), close
    raise ValueError(f"no definition of {fn} found")


def apply_version(scratch: Path, lang: str, fn: str, expr: str) -> None:
    main = scratch / main_file(lang)
    text = main.read_text()
    if lang in ALIAS_LANGS:
        text += "\n" + ALIAS_LANGS[lang].format(fn=fn, expr=expr) + "\n"
    elif lang in FORWARD_LANGS:
        line, name, close = candidate_definition(text, fn)
        renamed = text[:name] + fn + "_submitted" + text[name + len(fn):]
        if lang == "rust":
            text = renamed + f"\npub use self::{expr} as {fn};\n"
        else:
            head = text[line:close + 1]
            call = f"{expr}({', '.join(param_names(text[text.index('(', name) + 1:close]))})"
            if lang == "c":
                text = renamed + f"\n{head.strip()}\n{{\n    return {call};\n}}\n"
            else:
                text = renamed[:line] + f"{head} => {call};\n\n" + renamed[line:]
    else:
        raise ValueError(f"versions are not supported for {lang}")
    main.write_text(text)


def evaluate(session: Path, problem: str, lang: str, fn: str, expr: str | None) -> dict:
    repo = Path(config()["repo"])
    result = {"hidden": "none", "benchmark": None}
    for tier, extra in (("hidden", problem_dir(problem) / "hidden" / lang), ("bench", problem_dir(problem) / "bench" / lang)):
        if not extra.is_dir():
            continue
        scratch = test_copy(session, extra, f"{tier}-version")
        try:
            if expr:
                apply_version(scratch, lang, fn, expr)
            if tier == "hidden":
                code, out = run_capped(in_shell(repo, lang, ["just", "test"]), scratch, HIDDEN_SECONDS)
                result["hidden"] = "timeout" if code is None else "pass" if code == 0 else "fail"
                result["hidden_counts"] = test_counts(out)
                result["hidden_wrong"] = wrong_lines(out)
                if code != 0:
                    result["output"] = out.splitlines()[-30:]
                    break
            else:
                bench = run_bench(in_shell(repo, lang, ["just", "bench"]), scratch)
                if not bench["cases"]:
                    result["benchmark"] = "not run (the benchmark did not build)"
                    result["output"] = bench["output"][-30:]
                else:
                    cases = bench["cases"]
                    result.update(benchmark=bench_summary(bench), met=sum(c["met"] for c in cases), total=len(cases),
                                  slowest=max((c["seconds"] or 0) for c in cases), cases=cases)
        finally:
            shutil.rmtree(scratch, ignore_errors=True)
    result["correctness"], result["performance"] = classify(result["hidden"], result.get("cases", []), result.get("hidden_wrong", 0))
    return result


def bench_cases(problem: str, versions: list[dict]) -> list[dict]:
    spec = problem_dir(problem) / "spec.json"
    specced = json.loads(spec.read_text()).get("bench", []) if spec.exists() else []
    limits = {}
    for v in versions:
        for c in v.get("cases", []):
            limits.setdefault(c["case"], c["limit"])
    return [{"case": k, "label": (specced[k].get("label") if k < len(specced) else None) or f"case {k}", "limit": limits[k]}
            for k in sorted(limits)]


BAR_FLOOR = 1e-6
RATIO_FLOOR = 1e-5
BAR_WIDTH = 32
TIMED_STATUSES = ("ok", "unchecked", "killed")


def short_time(seconds: float) -> str:
    if seconds < 1e-6:
        return "<1µs"
    if seconds < 1e-3:
        return f"{seconds * 1e6:.0f}µs"
    if seconds < 1:
        return f"{seconds * 1e3:.{1 if seconds < 0.01 else 0}f}ms"
    return f"{seconds:.2f}s"


def short_ratio(ratio: float) -> str:
    return f"{ratio:.1f}x" if ratio < 10 else f"{ratio:.0f}x"


def with_ratios(versions: list[dict]) -> list[dict]:
    best: dict[int, float] = {}
    for v in versions:
        for c in v.get("cases", []):
            if c["status"] in ("ok", "unchecked"):
                best[c["case"]] = min(best.get(c["case"], math.inf), max(c["seconds"], RATIO_FLOOR))
    out = []
    for v in versions:
        cases = []
        for c in v.get("cases", []):
            timed = c["status"] in TIMED_STATUSES and c["case"] in best
            cases.append(c | {"ratio": max(c["seconds"], RATIO_FLOOR) / best[c["case"]] if timed else None})
        ratios = sorted(c["ratio"] for c in cases if c["ratio"] is not None)
        worst = max((c for c in cases if c["ratio"] is not None), key=lambda c: c["ratio"], default=None)
        tail = None
        if ratios:
            tail = {"median": ratios[len(ratios) // 2], "worst": worst["ratio"], "worst_case": worst["case"],
                    "over2": sum(r > 2 for r in ratios), "measured": len(ratios)}
        out.append(v | {"cases": cases, "tail": tail})
    return out


def bar_scale(cases: list[dict], versions: list[dict]) -> float:
    longest = max((c.get("seconds") or 0 for v in versions for c in v.get("cases", [])), default=0)
    return max([longest] + [4 * c["limit"] for c in cases] + [BAR_FLOOR * 10])


def ratio_scale(versions: list[dict]) -> float:
    return max([10.0] + [v["tail"]["worst"] for v in versions if v["tail"]])


def log_position(value: float, low: float, high: float) -> float:
    return min(1.0, math.log(max(value, low) / low) / math.log(high / low))


def bar_text(seconds: float | None, limit: float, top: float) -> str:
    filled = 0 if seconds is None else max(1, round(log_position(seconds, BAR_FLOOR, top) * BAR_WIDTH * 8))
    cells = [" ▏▎▍▌▋▊▉█"[max(0, min(8, filled - 8 * i))] for i in range(BAR_WIDTH)]
    tick = min(BAR_WIDTH - 1, int(log_position(limit, BAR_FLOOR, top) * BAR_WIDTH))
    if cells[tick] == " ":
        cells[tick] = "┊"
    return "".join(cells)


def strip_text(ratios: list[float], top: float) -> str:
    counts = [0] * BAR_WIDTH
    for r in ratios:
        counts[min(BAR_WIDTH - 1, int(log_position(r, 1.0, top) * BAR_WIDTH))] += 1
    return "".join(" ·:⁝⁞"[min(n, 4)] for n in counts)


def case_status(c: dict) -> str:
    if c["status"] == "killed":
        return "too slow"
    if c["status"] == "not run":
        return "not run"
    if c["status"] in WRONG_STATUSES:
        return c["status"].upper()
    return f"{short_time(c['seconds'])}{'' if c['met'] else ' over'}"


def print_bench_chart(problem: str, record: dict) -> None:
    versions = with_ratios([v for v in record["versions"] if v.get("cases")])
    if not versions:
        return
    cases = bench_cases(problem, versions)
    labels = {c["case"]: c["label"] for c in cases}
    width = max(len(v["name"]) for v in versions)
    rtop = ratio_scale(versions)
    print(f"\ntails: each case's slowdown against the fastest version on it (log scale 1x to {short_ratio(rtop)}; · one case, : two, ⁝ three, ⁞ more)")
    for v in versions:
        tail = v["tail"]
        if not tail:
            print(f"  {v['name']:<{width}} {' ' * BAR_WIDTH} no timed cases")
            continue
        strip = strip_text([c["ratio"] for c in v["cases"] if c["ratio"] is not None], rtop)
        missing = len(v["cases"]) - tail["measured"]
        print(f"  {v['name']:<{width}} {strip} median {short_ratio(tail['median'])}, worst {short_ratio(tail['worst'])} "
              f"(case {tail['worst_case']}: {labels.get(tail['worst_case'], '')}), {tail['over2']} over 2x"
              f"{f', {missing} not timed' if missing else ''}")
    top = bar_scale(cases, versions)
    print(f"\nper case (log scale 1µs to {short_time(top)}, ┊ marks the limit, Nx is the slowdown against the fastest)")
    for case in cases:
        print(f"case {case['case']}: {case['label']} (limit {case['limit']:g}s)")
        for v in versions:
            c = next((c for c in v["cases"] if c["case"] == case["case"]), None)
            if c is None:
                continue
            ratio = f" {'>' if c['status'] == 'killed' else ''}{short_ratio(c['ratio'])}" if c["ratio"] is not None and c["ratio"] >= 1.05 else ""
            print(f"  {v['name']:<{width}} {bar_text(c['seconds'] if c['status'] != 'not run' else None, case['limit'], top)} {case_status(c)}{ratio}")


def cmd_bench(args) -> int:
    session = session_dir(args.dir)
    cur = load_current()
    if cur and cur["phase"] in ("coding", "paused"):
        print("benchmarks run once the coding phase is over", file=sys.stderr)
        return 1
    meta = json.loads((session / ".interview.json").read_text())
    lang, problem = meta["lang"], meta["problem"]
    fn = args.target or target_name(problem, lang)
    versions = [("submitted", None)]
    for v in args.versions:
        name, sep, expr = v.partition("=")
        if not sep or not name or not expr or name == "submitted":
            print(f"version {v!r}: expected NAME=EXPR, NAME not 'submitted'", file=sys.stderr)
            return 2
        versions.append((name, expr))
    if args.versions_only:
        versions = versions[1:]
    store = session / "benchmarks.json"
    record = json.loads(store.read_text()) if store.exists() else {"target": fn, "versions": []}
    if args.report:
        print_bench_chart(problem, record)
        return 0
    failed = False
    for name, expr in versions:
        try:
            r = evaluate(session, problem, lang, fn, expr)
        except ValueError as error:
            print(f"{name}: {error}", file=sys.stderr)
            return 2
        entry = {"name": name, "expr": expr, "at": iso(now()), **{k: v for k, v in r.items() if k != "output"}}
        record["versions"] = [v for v in record["versions"] if v["name"] != name] + [entry]
        bench = r["benchmark"] or ("skipped (hidden tests do not pass)" if r["hidden"] != "pass" else "none for this problem")
        print(f"{name}: correctness {r['correctness']}, performance {r['performance']}")
        print(f"  hidden {hidden_line(r['hidden'], r.get('hidden_counts', ''), r.get('hidden_wrong', 0))}")
        print(f"  benchmark {bench}")
        for c in r.get("cases", []):
            print(bench_case_line(c))
        if r.get("output"):
            print("\n".join("  | " + line for line in r["output"]))
        failed |= expr is not None and r["hidden"] != "pass"
    record["versions"].sort(key=lambda v: v["name"] != "submitted")
    record["target"] = fn
    store.write_text(json.dumps(record, indent=1) + "\n")
    print_bench_chart(problem, record)
    print(f"recorded in {store}")
    return 1 if failed else 0


def ladder_rungs(problem: str) -> list[str]:
    text = (problem_dir(problem) / "LADDER.md").read_text()
    rungs, current = [], None
    for line in text.splitlines():
        if re.match(r"^\d+\.\s", line):
            current = re.sub(r"^\d+\.\s+", "", line)
            rungs.append(current)
        elif current is not None and line.startswith("   ") and line.strip():
            rungs[-1] += " " + line.strip()
    return rungs


def for_lang(rungs: list[str], lang: str) -> list[str]:
    meta = languages().get(lang, {"id": lang, "name": lang})
    own = {meta["id"].lower(), meta["name"].lower()}

    def keep(rung: str) -> bool:
        m = re.match(r"(?:hint|follow-up) \(([^)]+)\):", rung, re.IGNORECASE)
        return m is None or m.group(1).strip().lower() in own
    return [r for r in rungs if keep(r)]


def cmd_hint(args) -> int:
    with locked():
        cur = load_current()
        if not cur:
            print("no interview running", file=sys.stderr)
            return 1
        rungs = for_lang(ladder_rungs(cur["problem"]), cur["lang"])
        if args.all:
            if cur["phase"] != "review":
                print("the whole ladder opens during review; `interview hint` gives the next rung", file=sys.stderr)
                return 1
            for n, rung in enumerate(rungs, 1):
                print(f"{n}. {rung}")
            return 0
        given = cur.get("hints", [])
        hints = [r for r in rungs if not r.lower().startswith("follow-up")]
        if len(given) >= len(hints):
            print("no hints left; follow-ups open during review with `interview hint --all`")
            return 0
        rung = hints[len(given)]
        cur["hints"] = given + [now()]
        save_current(cur)
        emit(cur, "HINT", f"candidate revealed ladder hint {len(given) + 1}: {rung}")
    print(f"hint {len(given) + 1}/{len(hints)}: {rung}")
    return 0


def cmd_status(args) -> int:
    s = status_dict(now())
    print(json.dumps(s) if args.json else status_line(s))
    return 0


def cmd_events(args) -> int:
    def render(e: dict) -> str:
        guide = EVENT_GUIDE.get(e["event"], "")
        return f"INTERVIEW {e['event']} [{e['session']}] {e['detail']}. {guide}".strip()

    if not args.follow:
        for e in read_jsonl(EVENTS)[-args.last:]:
            print(render(e))
        return 0
    STATE.mkdir(parents=True, exist_ok=True)
    EVENTS.touch()
    with open(EVENTS) as handle:
        handle.seek(0, os.SEEK_END)
        while True:
            line = handle.readline()
            if not line:
                time.sleep(0.5)
                continue
            with contextlib.suppress(json.JSONDecodeError):
                e = json.loads(line)
                print(render(e), flush=True)
                if e["event"] == "REVIEW_OVER" and args.until_complete:
                    return 0


def cmd_today(args) -> int:
    at = now()
    plan = plan_today(at)
    if args.json:
        print(json.dumps(plan))
        return 0
    if not interview_day(at) and not any(p["status"] != "off" for p in plan):
        print(f"no interviews on {dt.datetime.fromtimestamp(at).strftime('%A')}")
        return 0
    tw = max([5] + [len(p["track"]) for p in plan])
    lw = max([4] + [len(p["lang"]) for p in plan])
    for p in plan:
        print(f"{p['track']:{tw}} {p['lang']:{lw}} {p['status']:8} {p['problem'] or ''}")
    done = sum(1 for p in plan if p["status"] == "done")
    print(f"{done}/{config()['required_per_day']} required done")
    return 0


def cmd_check_day(args) -> int:
    done = len({e["track"] for e in completed_on(day_of(now()))})
    return 0 if done >= config()["required_per_day"] else 1


def problems_list() -> list[dict]:
    root = Path(config()["repo"], "problems")
    attempts = read_jsonl(LOG)
    out = []
    for d in sorted(root.glob("*/meta.toml")):
        meta = tomllib.loads(d.read_text())
        pid = d.parent.name
        meta["id"] = pid
        meta["langs"] = sorted(p.name for p in (d.parent / "templates").glob("*") if p.is_dir())
        meta["attempted"] = sorted({e["lang"] for e in attempts if e["kind"] == "complete" and e["problem"] == pid and worked(e)})
        out.append(meta)
    return out


def cmd_problems(args) -> int:
    items = problems_list()
    if args.json:
        print(json.dumps(items))
        return 0
    for m in items:
        print(f"{m['id']:32} {m.get('topic', ''):20} {m.get('difficulty', ''):8} {'mutable' if m.get('mutable') else '':8} langs={','.join(m['langs'])} done={','.join(m['attempted'])}")
    ocaml = [m for m in items if "ocaml" in m["langs"]]
    mutable = [m for m in ocaml if m.get("mutable")]
    if ocaml:
        print(f"ocaml mutable share: {len(mutable)}/{len(ocaml)} ({100 * len(mutable) // len(ocaml)}%, cap 25%)")
    return 0


def cmd_log(args) -> int:
    at = now()
    entries = read_jsonl(LOG)
    cur = load_current()
    if cur:
        if cur["phase"] in ("coding", "paused"):
            entries.append({"kind": "coding", "date": day_of(cur["started"]), "start": iso(cur["started"]), "seconds": round(coding_used(cur, at)), "session": cur["id"], "track": cur["track"], "lang": cur["lang"], "problem": cur["problem"], "live": True})
        if cur["phase"] == "paused":
            entries.append({"kind": "paused", "date": day_of(cur["pause_started"]), "start": iso(cur["pause_started"]), "seconds": round(at - cur["pause_started"]), "session": cur["id"], "track": cur["track"], "lang": cur["lang"], "problem": cur["problem"], "live": True})
        if cur["phase"] == "review":
            entries.append({"kind": "review", "date": day_of(cur["review_started"]), "start": iso(cur["review_started"]), "seconds": round(at - cur["review_started"]), "session": cur["id"], "track": cur["track"], "lang": cur["lang"], "problem": cur["problem"], "live": True})
    since = (dt.date.fromtimestamp(at) - dt.timedelta(days=args.days - 1)).isoformat()
    days: dict[str, dict] = {}
    for e in entries:
        if e["date"] < since:
            continue
        if e["kind"] == "learning":
            e = {**e, "kind": "paused"}
        if e["kind"] == "coding" and "active" in e:
            e = {**e, "seconds": e["active"]}
        d = days.setdefault(e["date"], {"coding": 0, "paused": 0, "review": 0, "tutor": 0, "sessions": {}, "completed": 0})
        if e["kind"] in ("coding", "paused", "review", "tutor"):
            d[e["kind"]] += e["seconds"]
        if e["kind"] == "tutor":
            continue
        s = d["sessions"].setdefault(e["session"], {"session": e["session"], "lang": e["lang"], "track": e["track"], "problem": e["problem"], "coding": 0, "paused": 0, "review": 0, "complete": False})
        if e["kind"] in ("coding", "paused", "review"):
            s[e["kind"]] += e["seconds"]
        if e["kind"] == "complete" and worked(e):
            sdir = Path(e.get("dir", ""))
            review = sdir / "review.md"
            store = sdir / "benchmarks.json"
            versions, cases = [], []
            with contextlib.suppress(OSError, ValueError, KeyError):
                stored = with_ratios(json.loads(store.read_text())["versions"])
                cases = bench_cases(e["problem"], stored)
                for v in stored:
                    time_sum = round(sum(c.get("seconds") or 0 for c in v.get("cases", [])), 6)
                    correctness, performance = classify(v.get("hidden", "none"), v.get("cases", []), v.get("hidden_wrong", 0))
                    entry = {k: v.get(k) for k in ("name", "hidden", "benchmark", "met", "total", "slowest")}
                    entry.update(time=time_sum, correctness=correctness, performance=performance,
                                 tail=v["tail"], cases=[{k: c.get(k) for k in ("seconds", "status", "met", "ratio")} for c in v["cases"]])
                    versions.append(entry)
            s.update(complete=True, early=e.get("early"), hidden_tests=e.get("hidden_tests"), benchmark=e.get("benchmark"), dir=e.get("dir"),
                     review_md=str(review) if review.exists() else None, versions=versions, bench_cases=cases)
            d["completed"] += 1
        if e.get("live"):
            s["live"] = True
    for d in days.values():
        d["sessions"] = list(d["sessions"].values())
        d["total"] = d["coding"] + d["review"] + d["tutor"]
    if args.json:
        print(json.dumps({"today": day_of(at), "required_per_day": config()["required_per_day"], "days": days}))
        return 0
    for date in sorted(days):
        d = days[date]
        print(f"{date}  total {d['total'] // 60:4}m  coding {d['coding'] // 60:3}m  tutor {d['tutor'] // 60:3}m  paused {d['paused'] // 60:3}m  review {d['review'] // 60:3}m  completed {d['completed']}")
    return 0


def check_settings(raw: dict, known: dict) -> tuple[dict, list[str]]:
    errors = []
    out = {}

    def need(ok: bool, message: str) -> bool:
        if not ok:
            errors.append(message)
        return ok

    days = raw.get("days")
    if need(isinstance(days, list) and all(d in WEEKDAYS for d in days), "days: a list of Mon, Tue, Wed, Thu, Fri, Sat, Sun"):
        out["days"] = [d for d in WEEKDAYS if d in days]
    start = raw.get("start")
    if need(isinstance(start, str) and re.fullmatch(r"([01]\d|2[0-3]):[0-5]\d", start) is not None, "start: HH:MM, 24-hour"):
        out["start"] = start
    first = raw.get("from", "")
    valid_first = isinstance(first, str)
    if valid_first and first:
        try:
            dt.date.fromisoformat(first)
        except ValueError:
            valid_first = False
    if need(valid_first, "from: empty or an ISO date such as 2026-11-23"):
        out["from"] = first
    for key in ("auto_start", "lockdown"):
        if need(isinstance(raw.get(key), bool), f"{key}: true or false"):
            out[key] = raw[key]
    for key, low, high in (("coding_minutes", 5, 240), ("review_minutes", 0, 60), ("break_minutes", 0, 240), ("snooze_minutes", 1, 240)):
        value = raw.get(key)
        if need(isinstance(value, int) and not isinstance(value, bool) and low <= value <= high, f"{key}: a whole number from {low} to {high}"):
            out[key] = value
    context = raw.get("context", "")
    if need(isinstance(context, str) and len(context) <= 4000, "context: text of at most 4000 characters"):
        out["context"] = context.strip()
    tracks = raw.get("tracks")
    names = set()
    cleaned = []
    if need(isinstance(tracks, list) and 1 <= len(tracks) <= 12, "tracks: between 1 and 12"):
        for i, t in enumerate(tracks):
            label = f"track {i + 1}"
            if not need(isinstance(t, dict), f"{label}: an object"):
                continue
            name = t.get("name")
            if need(isinstance(name, str) and re.fullmatch(r"[a-z][a-z0-9-]{0,23}", name or "") is not None, f"{label}: name of lowercase letters, digits and dashes, starting with a letter"):
                need(name not in names, f"{label}: name {name} is used twice")
                names.add(name)
                label = f"track {name}"
            langs = t.get("langs")
            good_langs = need(isinstance(langs, list) and len(langs) > 0 and all(isinstance(lang, str) for lang in langs), f"{label}: at least one language")
            if good_langs:
                unknown = [lang for lang in langs if lang not in known]
                need(not unknown, f"{label}: unknown languages {', '.join(unknown)}")
            track_context = t.get("context", "")
            need(isinstance(track_context, str) and len(track_context) <= 2000, f"{label}: context of at most 2000 characters")
            need(t.get("difficulty", "easy-medium") in DIFFICULTIES, f"{label}: difficulty one of {', '.join(DIFFICULTIES)}")
            need(isinstance(t.get("enabled", True), bool), f"{label}: enabled true or false")
            lengths = {}
            for key, low, high in (("coding_minutes", 5, 240), ("review_minutes", 0, 60)):
                value = t.get(key)
                if need(value is None or (isinstance(value, int) and not isinstance(value, bool) and low <= value <= high),
                        f"{label}: {key} empty for the default, or a whole number from {low} to {high}"):
                    lengths[key] = value
            if good_langs and isinstance(name, str) and isinstance(track_context, str):
                cleaned.append(track_entry(name, list(dict.fromkeys(langs)), context=track_context.strip(),
                                           difficulty=t.get("difficulty", "easy-medium"), enabled=t.get("enabled", True), **lengths))
        enabled = [t for t in cleaned if t["enabled"]]
        need(len(enabled) > 0, "tracks: at least one enabled")
        out["tracks"] = cleaned
        required = raw.get("required_per_day")
        if need(isinstance(required, int) and not isinstance(required, bool) and 1 <= required <= max(1, len(enabled)),
                f"required_per_day: from 1 to the number of enabled tracks ({len(enabled)})"):
            out["required_per_day"] = required
    return out, errors


def read_password() -> str:
    if sys.stdin.isatty():
        import getpass
        return getpass.getpass("password: ")
    return sys.stdin.readline().rstrip("\n")


def cmd_settings(args) -> int:
    base = base_config()
    if args.action == "show":
        cfg = overlay(base_config(), stored_settings(base))
        doc = {
            "settings": editable(cfg),
            "defaults": editable(base),
            "customised": bool(stored_settings(base)),
            "languages": sorted(languages(cfg["repo"]).values(), key=lambda m: m["name"].lower()),
            "weekdays": WEEKDAYS,
            "difficulties": DIFFICULTIES,
            "rules": RULES,
        }
        if args.json:
            print(json.dumps(doc))
        else:
            s = doc["settings"]
            print(f"days {' '.join(s['days']) or 'none'} from {s['start']}{', starting ' + s['from'] if s['from'] else ''}; auto start {'on' if s['auto_start'] else 'off'}; lockdown {'on' if s['lockdown'] else 'off'}")
            print(f"{s['coding_minutes']} min coding, {s['review_minutes']} min review, {s['break_minutes']} min break; {s['required_per_day']} of {len([t for t in s['tracks'] if t['enabled']])} questions required")
            print("always: " + " ".join(doc["rules"]))
            print(f"style: {s['context'] or '(none)'}")
            for t in s["tracks"]:
                lengths = "".join(f"; {t[k]} min {k.split('_')[0]}" for k in ("coding_minutes", "review_minutes") if t[k] is not None)
                print(f"track {t['name']}{'' if t['enabled'] else ' (off)'}: {', '.join(t['langs'])}; {t['difficulty']}{lengths}; {t['context'] or '(no extra context)'}")
            print("settings: " + ("customised in the desktop UI" if doc["customised"] else "nix defaults"))
        return 0
    password = lockdown_password(base)
    if not password:
        print("no lockdown password is configured, so settings cannot be changed", file=sys.stderr)
        return 1
    attempt = read_password()
    if not hmac.compare_digest(attempt, password):
        print("wrong password", file=sys.stderr)
        return 1
    if args.action == "verify":
        print("password accepted")
        return 0
    if args.action == "reset":
        SETTINGS.unlink(missing_ok=True)
        print("settings reset to the nix defaults")
        return 0
    try:
        raw = json.loads(sys.stdin.read())
    except json.JSONDecodeError as error:
        print(f"settings are not valid JSON: {error}", file=sys.stderr)
        return 2
    merged = {**editable(base), **(raw if isinstance(raw, dict) else {})}
    settings, errors = check_settings(merged, languages(base["repo"]))
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 2
    STATE.mkdir(parents=True, exist_ok=True)
    tmp = SETTINGS.with_suffix(".tmp")
    tmp.write_text(json.dumps({"settings": settings, "signature": sign(password, settings)}, indent=2))
    tmp.replace(SETTINGS)
    print("settings saved")
    return 0


def cmd_langs(args) -> int:
    items = sorted(languages().values(), key=lambda m: m["name"].lower())
    if args.json:
        print(json.dumps(items))
        return 0
    for m in items:
        print(f"{m['id']:12} {m['name']:12} {m['main']:16} {'scaffold' if m['scaffold'] else 'hand-written'}")
    return 0


def cmd_tutor(args) -> int:
    at = now()
    marker = STATE / "tutor-open.json"
    if args.action == "start":
        STATE.mkdir(parents=True, exist_ok=True)
        marker.write_text(json.dumps({"start": at}))
        return 0
    try:
        start = json.loads(marker.read_text())["start"]
    except (FileNotFoundError, json.JSONDecodeError, KeyError):
        return 0
    marker.unlink(missing_ok=True)
    append(LOG, {"kind": "tutor", "date": day_of(start), "start": iso(start), "end": iso(at), "seconds": round(at - start), "session": "tutor", "track": "tutor", "lang": "", "problem": ""})
    return 0


def revisit(session: Path) -> Path:
    dest = session / "improved"
    if dest.exists():
        print(f"{dest} already exists")
        return dest
    shutil.copytree(session, dest, ignore=shutil.ignore_patterns(*BUILD_DIRS, *REVIEW_FILES))
    for path in dest.rglob("*"):
        path.chmod(path.stat().st_mode | stat.S_IWUSR)
    print(f"writable copy at {dest}")
    return dest


def cmd_revisit(args) -> int:
    if load_current():
        print("finish the running interview first", file=sys.stderr)
        return 1
    revisit(Path(args.dir).resolve())
    return 0


def cmd_open(args) -> int:
    session = Path(args.dir).resolve()
    cur = load_current()
    if cur and Path(cur["dir"]).resolve() != session:
        print("past sessions open once the running interview is over", file=sys.stderr)
        return 1
    meta = json.loads((session / ".interview.json").read_text())
    if args.what == "revisit":
        if cur:
            print("finish the running interview first", file=sys.stderr)
            return 1
        target = revisit(session) / main_file(meta["lang"])
    else:
        target = session / {"prompt": "PROMPT.md", "code": main_file(meta["lang"]), "review": "review.md"}[args.what]
    if not target.exists():
        print(f"{target} does not exist", file=sys.stderr)
        return 1
    if not emacs_open(target):
        print("emacsclient could not open it; is the Emacs server running?", file=sys.stderr)
        return 1
    return 0


def cmd_daemon(args) -> int:
    while True:
        with locked():
            try:
                tick(now())
            except Exception as error:
                print(f"tick failed: {error!r}", file=sys.stderr, flush=True)
        time.sleep(1)


def main() -> int:
    parser = argparse.ArgumentParser(prog="interview")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("start", help="start an interview on a problem")
    p.add_argument("lang", nargs="?", help="language or track; default: the first pending scheduled one")
    p.add_argument("problem", nargs="?", help="default: today's problem from schedule.toml")
    p.add_argument("--open", action="store_true", help="open PROMPT.md and the solution file in Emacs")
    p.add_argument("--minutes", type=int)
    p.add_argument("--review-minutes", type=int)
    p.add_argument("--again", action="store_true")
    p.add_argument("--track", help="count the interview toward this track")
    p.set_defaults(fn=cmd_start)

    p = sub.add_parser("settings", help="show the schedule, tracks and context; changing them needs the lockdown password on the first stdin line")
    p.add_argument("action", nargs="?", default="show", choices=["show", "verify", "set", "reset"])
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_settings)

    p = sub.add_parser("langs", help="languages with a dev shell and example template in langs/")
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_langs)

    for name, fn in (("pause", do_pause), ("resume", do_resume), ("toggle", do_toggle), ("done", do_done), ("close", do_close)):
        p = sub.add_parser(name)
        p.set_defaults(fn=lambda _a, fn=fn: mutate(fn))

    p = sub.add_parser("approve-finish", help="interviewer only: allow the candidate to finish coding early")
    p.add_argument("reason")
    p.set_defaults(fn=cmd_approve_finish)

    p = sub.add_parser("extend", help=f"interviewer only: add coding minutes for an environment fault, at most {EXTEND_CAP_MINUTES} per interview")
    p.add_argument("minutes", type=int)
    p.add_argument("reason")
    p.set_defaults(fn=cmd_extend)

    p = sub.add_parser("abandon", help="drop the running interview before review: logged as abandoned, never counted")
    p.add_argument("--reason", required=True)
    p.set_defaults(fn=cmd_abandon)
    p = sub.add_parser("status")
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_status)

    p = sub.add_parser("events")
    p.add_argument("--follow", action="store_true")
    p.add_argument("--until-complete", action="store_true")
    p.add_argument("--last", type=int, default=20)
    p.set_defaults(fn=cmd_events)

    p = sub.add_parser("today")
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_today)

    p = sub.add_parser("check-day")
    p.set_defaults(fn=cmd_check_day)

    p = sub.add_parser("problems")
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_problems)

    p = sub.add_parser("run", help="run the visible tests")
    p.add_argument("dir", nargs="?")
    p.set_defaults(fn=cmd_run)

    p = sub.add_parser("submit-tests", help="run the hidden tests")
    p.add_argument("dir", nargs="?")
    p.add_argument("--show", action="store_true", help="print the full output even while coding")
    p.set_defaults(fn=cmd_submit_tests)

    p = sub.add_parser("hint", help="reveal the next ladder hint; --all shows the whole ladder during review")
    p.add_argument("--all", action="store_true")
    p.set_defaults(fn=cmd_hint)

    p = sub.add_parser("log")
    p.add_argument("--json", action="store_true")
    p.add_argument("--days", type=int, default=42)
    p.set_defaults(fn=cmd_log)

    p = sub.add_parser("tutor")
    p.add_argument("action", choices=["start", "stop"])
    p.set_defaults(fn=cmd_tutor)

    p = sub.add_parser("revisit")
    p.add_argument("dir")
    p.set_defaults(fn=cmd_revisit)

    p = sub.add_parser("bench", help="after coding: run hidden tests and the benchmark on the submission and on reviewed versions, recorded in DIR/benchmarks.json")
    p.add_argument("dir")
    p.add_argument("versions", nargs="*", metavar="NAME=EXPR", help="a reviewed version: EXPR replaces the problem function (OCaml Reviewed.Pruned.coin_change, Python Reviewed.Pruned.coin_change, Rust reviewed::pruned::coin_change, C# Reviewed.Pruned.CoinChange, C reviewed_pruned_coin_change)")
    p.add_argument("--target", help="the function the tests call; default from spec.json")
    p.add_argument("--versions-only", action="store_true", help="skip re-running the submission")
    p.add_argument("--report", action="store_true", help="print the per-case chart from DIR/benchmarks.json without running anything")
    p.set_defaults(fn=cmd_bench)

    p = sub.add_parser("open", help="open a past session's prompt, code or review in Emacs, or revisit it as a writable improved/ copy")
    p.add_argument("dir")
    p.add_argument("what", choices=["prompt", "code", "review", "revisit"])
    p.set_defaults(fn=cmd_open)

    p = sub.add_parser("auto", help="if an interview is due, ask with a notification and start it only on Start; run by the shell while the candidate is at the keyboard")
    p.add_argument("--verbose", action="store_true")
    p.set_defaults(fn=cmd_auto)

    p = sub.add_parser("daemon")
    p.set_defaults(fn=cmd_daemon)

    args = parser.parse_args()
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
