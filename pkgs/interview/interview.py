# interview: timed coding interviews with pause, review, an event stream for Claude and a practice log.

import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
import re
import json
import os
import shlex
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

BUILD_DIRS = {"_build", "target", "bin", "obj", "__pycache__", ".pytest_cache", "build", "improved"}
REVIEW_FILES = {"review.md", "SOLUTIONS.md", ".interview.json"}
MAIN_FILE = {"ocaml": "solution.ml", "rust": "src/lib.rs", "c": "solution.c", "csharp": "Solution.cs", "python": "solution.py"}

EVENT_GUIDE = {
    "STARTED": "Interview clock started. Present the problem, then interview.",
    "WARN_15": "15 minutes of coding left. Make sure a working solution exists before polishing.",
    "WARN_5": "5 minutes of coding left. No new subproblems; help the candidate land and test what they have.",
    "PAUSED": "Candidate paused the clock and is with the tutor. Do not continue the interview until RESUMED.",
    "RESUMED": "Clock running again. Pick up where the interview left off.",
    "FINISH_APPROVED": "You approved finishing early; the candidate can now press Finish early, or run `interview done` yourself if they asked to finish.",
    "HINT": "The candidate took the next ladder rung themselves; do not repeat it, build on it.",
    "CODING_OVER": "Coding phase over and the submission is frozen. Stop coaching and run /review now.",
    "REVIEW_WARN": "3 minutes of review left. Give the remaining top improvements and wrap up.",
    "REVIEW_OVER": "Review over and the interview is logged. Sign off in two lines; the next interview starts automatically after the break with a fresh interviewer.",
}


def config() -> dict:
    cfg = {
        "repo": str(Path.home() / "Jobs/general"),
        "coding_minutes": 45,
        "review_minutes": 15,
        "required_per_day": 2,
        "tracks": {"ocaml": ["ocaml"], "systems": ["rust", "c"], "managed": ["csharp", "python"]},
        "on_pause": None,
        "on_resume": None,
        "on_complete": None,
        "on_start": None,
        "auto": {"enabled": False, "days": ["Mon", "Tue", "Wed", "Thu", "Fri"], "start": "05:00", "break_minutes": 5, "snooze_minutes": 15},
    }
    with contextlib.suppress(FileNotFoundError):
        cfg.update(json.loads(CONFIG_PATH.read_text()))
    return cfg


def now() -> float:
    forced = os.environ.get("INTERVIEW_NOW")
    return dt.datetime.fromisoformat(forced).timestamp() if forced else time.time()


def iso(t: float) -> str:
    return dt.datetime.fromtimestamp(t).isoformat(timespec="seconds")


def day_of(t: float) -> str:
    return dt.datetime.fromtimestamp(t).date().isoformat()


def track_of(lang: str) -> str:
    for track, langs in config()["tracks"].items():
        if lang in langs:
            return track
    raise SystemExit(f"unknown language {lang}")


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
- hints used: {hints}

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
                hidden=cur.get("hidden_tests") or "not run", hints=len(cur.get("hints", []))))


def end_coding(cur: dict, at: float, early: bool) -> dict:
    if cur.get("running_since") is not None:
        cur["used_before"] = coding_used(cur, at)
        cur["running_since"] = None
    if cur["phase"] == "paused":
        log("learning", cur, cur["pause_started"], at)
        cur["pause_seconds"] += at - cur["pause_started"]
        run_hook(config()["on_resume"])
    log("coding", cur, cur["started"], at, active=round(cur["used_before"]), early=early)
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
        hidden_tests=cur.get("hidden_tests"), dir=cur["dir"])
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


def completed_on(date: str) -> list[dict]:
    return [e for e in read_jsonl(LOG) if e["kind"] == "complete" and e["date"] == date]


def schedule() -> dict:
    try:
        return tomllib.loads(Path(config()["repo"], "schedule.toml").read_text())
    except (FileNotFoundError, tomllib.TOMLDecodeError):
        return {}


def plan_today(at: float) -> list[dict]:
    cfg = config()
    today = day_of(at)
    done = {e["track"]: e for e in completed_on(today)}
    history = [e for e in read_jsonl(LOG) if e["kind"] == "complete"]
    planned = schedule().get(today, {})
    cur = load_current()
    out = []
    for track, langs in cfg["tracks"].items():
        if track in done:
            out.append({"track": track, "lang": done[track]["lang"], "status": "done", "problem": done[track]["problem"]})
            continue
        if cur and cur["track"] == track:
            out.append({"track": track, "lang": cur["lang"], "status": cur["phase"], "problem": cur["problem"]})
            continue
        lang = next((lang for lang in langs if lang in planned), None)
        if lang:
            out.append({"track": track, "lang": lang, "status": "pending", "problem": planned[lang]})
            continue
        count = sum(1 for e in history if e["track"] == track)
        out.append({"track": track, "lang": langs[count % len(langs)], "status": "pending", "problem": None})
    return out


def pick(at: float, choice: str | None) -> tuple[str, str] | str:
    plan = [p for p in plan_today(at) if p["status"] == "pending"]
    if choice:
        plan = [p for p in plan if choice in (p["track"], p["lang"])]
    for p in plan:
        if p["problem"]:
            return p["lang"], p["problem"]
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
    }
    if cur:
        out.update({
            "phase": cur["phase"],
            "session": cur["id"],
            "track": cur["track"],
            "lang": cur["lang"],
            "problem": cur["problem"],
            "dir": cur["dir"],
            "coding_budget": cur["coding_budget"],
            "used_before": cur["used_before"],
            "running_since": cur.get("running_since"),
            "pause_started": cur.get("pause_started"),
            "pause_seconds": cur["pause_seconds"],
            "finish_approved": cur.get("finish_approved"),
            "hidden_tests": cur.get("hidden_tests"),
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
| run the hidden tests (pass or fail and a count only) | `interview submit-tests` |
| next hint from the ladder | `interview hint` |
| time left | `interview status` |
| finish early (hidden tests passed on the current code) | `interview done` |
| end the review and log the interview | `interview close` |

`interview done` works once `interview submit-tests` has passed on exactly the files as they are
now; otherwise wait for the clock, or ask the interviewer to approve. When coding ends the files
freeze, and SOLUTIONS.md (a short list of methods with their complexity) and a review.md
template appear here. During review, `interview submit-tests` shows the full hidden output and
`interview hint --all` the whole ladder with its follow-ups. Compare your approach against
SOLUTIONS.md, fill in review.md, then `interview close`.
"""


def open_files(dest: Path, lang: str) -> None:
    with contextlib.suppress(OSError, subprocess.TimeoutExpired):
        subprocess.run(["emacsclient", "-n", str(dest / "PROMPT.md"), str(dest / MAIN_FILE[lang])],
                       capture_output=True, timeout=5)


def begin(at: float, lang: str | None, problem: str | None, minutes: int | None = None,
          review_minutes: int | None = None, again: bool = False) -> tuple[dict, Path] | str:
    cfg = config()
    if load_current():
        return "an interview is already running; see `interview status`"
    if not problem:
        if lang not in cfg["tracks"] and lang not in MAIN_FILE and lang is not None:
            return f"unknown track or language {lang}"
        chosen = pick(at, lang)
        if isinstance(chosen, str):
            return chosen
        lang, problem = chosen
    if lang not in MAIN_FILE:
        return f"unknown language {lang}"
    track = track_of(lang)
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
    budget = (minutes or cfg["coding_minutes"]) * 60
    prompt = problem_dir(problem) / "PROMPT.md"
    if prompt.exists():
        shutil.copyfile(prompt, dest / "PROMPT.md")
    (dest / "HOWTO.md").write_text(HOWTO.format(lang=lang, problem=problem, minutes=budget // 60, main=MAIN_FILE[lang]))
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
        "review_budget": (review_minutes or cfg["review_minutes"]) * 60,
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
        started = begin(now(), args.lang, args.problem, args.minutes, args.review_minutes, args.again)
    if isinstance(started, str):
        print(started, file=sys.stderr)
        return 1
    cur, dest = started
    print(f"started {cur['id']}: {dest}\nread {dest / 'PROMPT.md'}, edit {dest / MAIN_FILE[cur['lang']]}; {dest / 'HOWTO.md'} lists the commands")
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


def ask(cfg: dict, lang: str, problem: str) -> bool:
    command = [cfg["auto"].get("notify", "notify-send"), "--app-name=interview", "--urgency=critical", "--wait",
               "--action=start=Start", "--action=later=Later",
               "Interview due", f"{lang} {problem}: start the {cfg['coding_minutes']}-minute clock?"]
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
    lang, problem = chosen
    if not ask(cfg, lang, problem):
        SNOOZE.write_text(str(now() + cfg["auto"]["snooze_minutes"] * 60))
        print(f"declined; asking again in {cfg['auto']['snooze_minutes']} minutes")
        return 0
    with locked():
        started = begin(now(), lang, problem)
    if isinstance(started, str):
        print(started, file=sys.stderr)
        return 1
    cur, dest = started
    print(f"started {cur['id']}: {dest}")
    hook = cfg["on_start"]
    if hook:
        run_hook([*hook, str(dest / "PROMPT.md"), str(dest / MAIN_FILE[cur["lang"]])])
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
    log("learning", cur, cur["pause_started"], at)
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


def do_close(cur: dict, at: float):
    if cur["phase"] != "review":
        print(f"cannot close during {cur['phase']}; finish coding first with `interview done`", file=sys.stderr)
        return 1
    finish(cur, at, "review closed")
    return "interview complete"


def nix_run(repo: Path, cwd: Path, command: list[str]) -> int:
    if shutil.which("nix") and (repo / "flake.nix").exists():
        command = ["nix", "develop", str(repo), "--command", "bash", "-c", shlex.join(command), "interview"]
    return subprocess.run(command, cwd=cwd).returncode


def session_dir(arg: str | None) -> Path:
    if arg:
        return Path(arg).resolve()
    cur = load_current()
    if cur:
        return Path(cur["dir"])
    raise SystemExit("no interview running; pass a session directory")


def cmd_run(args) -> int:
    return nix_run(Path(config()["repo"]), session_dir(args.dir), ["just", "test"])


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


def cmd_submit_tests(args) -> int:
    session = session_dir(args.dir)
    cur = load_current()
    meta = cur if cur and Path(cur["dir"]) == session else None
    problem = meta["problem"] if meta else session.name.split("-", 1)[1]
    lang = meta["lang"] if meta else session.name.split("-", 1)[0]
    hidden = problem_dir(problem) / "hidden" / lang
    secret = bool(meta) and meta["phase"] in ("coding", "paused") and not args.show
    scratch = STATE / "hidden-run"
    shutil.rmtree(scratch, ignore_errors=True)
    shutil.copytree(session, scratch, ignore=shutil.ignore_patterns(*BUILD_DIRS, *REVIEW_FILES))
    for path in scratch.rglob("*"):
        path.chmod(path.stat().st_mode | stat.S_IWUSR)
    if hidden.is_dir():
        shutil.copytree(hidden, scratch, dirs_exist_ok=True)
    else:
        print(f"no hidden tests at {hidden}; running visible tests only")
    state = digest(session)
    if secret:
        repo = Path(config()["repo"])
        command = ["nix", "develop", str(repo), "--command", "bash", "-c", "just test", "interview"] if shutil.which("nix") and (repo / "flake.nix").exists() else ["just", "test"]
        result = subprocess.run(command, cwd=scratch, capture_output=True, text=True)
        code = result.returncode
        summary = test_counts(result.stdout + result.stderr)
    else:
        code = nix_run(Path(config()["repo"]), scratch, ["just", "test"])
        summary = ""
    shutil.rmtree(scratch, ignore_errors=True)
    if meta:
        with locked():
            cur = load_current()
            if cur and cur["id"] == meta["id"]:
                cur["hidden_tests"] = "pass" if code == 0 else "fail"
                cur["hidden_digest"] = state if code == 0 else None
                save_current(cur)
    print(f"hidden tests: {'PASS' if code == 0 else 'FAIL'}{' (' + summary + ')' if summary else ''}")
    if secret and code == 0 and meta["phase"] == "coding":
        print("you may finish early now with `interview done` (or keep improving)")
    return code


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


def cmd_hint(args) -> int:
    with locked():
        cur = load_current()
        if not cur:
            print("no interview running", file=sys.stderr)
            return 1
        rungs = ladder_rungs(cur["problem"])
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
    for p in plan:
        print(f"{p['track']:8} {p['lang']:7} {p['status']:8} {p['problem'] or ''}")
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
        meta["attempted"] = sorted({e["lang"] for e in attempts if e["kind"] == "complete" and e["problem"] == pid})
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
            entries.append({"kind": "learning", "date": day_of(cur["pause_started"]), "start": iso(cur["pause_started"]), "seconds": round(at - cur["pause_started"]), "session": cur["id"], "track": cur["track"], "lang": cur["lang"], "problem": cur["problem"], "live": True})
        if cur["phase"] == "review":
            entries.append({"kind": "review", "date": day_of(cur["review_started"]), "start": iso(cur["review_started"]), "seconds": round(at - cur["review_started"]), "session": cur["id"], "track": cur["track"], "lang": cur["lang"], "problem": cur["problem"], "live": True})
    since = (dt.date.fromtimestamp(at) - dt.timedelta(days=args.days - 1)).isoformat()
    days: dict[str, dict] = {}
    for e in entries:
        if e["date"] < since:
            continue
        d = days.setdefault(e["date"], {"coding": 0, "learning": 0, "review": 0, "tutor": 0, "sessions": {}, "completed": 0})
        if e["kind"] in ("coding", "learning", "review", "tutor"):
            d[e["kind"]] += e["seconds"]
        if e["kind"] == "tutor":
            continue
        s = d["sessions"].setdefault(e["session"], {"session": e["session"], "lang": e["lang"], "track": e["track"], "problem": e["problem"], "coding": 0, "learning": 0, "review": 0, "complete": False})
        if e["kind"] in ("coding", "learning", "review"):
            s[e["kind"]] += e["seconds"]
        if e["kind"] == "complete":
            s.update(complete=True, early=e.get("early"), hidden_tests=e.get("hidden_tests"), dir=e.get("dir"), review_md=str(Path(e.get("dir", ""), "review.md")))
            d["completed"] += 1
        if e.get("live"):
            s["live"] = True
    for d in days.values():
        d["sessions"] = list(d["sessions"].values())
        d["total"] = d["coding"] + d["learning"] + d["review"] + d["tutor"]
    if args.json:
        print(json.dumps({"today": day_of(at), "required_per_day": config()["required_per_day"], "days": days}))
        return 0
    for date in sorted(days):
        d = days[date]
        print(f"{date}  total {d['total'] // 60:4}m  coding {d['coding'] // 60:3}m  learning {(d['learning'] + d['tutor']) // 60:3}m  review {d['review'] // 60:3}m  completed {d['completed']}")
    return 0


def cmd_tutor(args) -> int:
    at = now()
    marker = STATE / "tutor-open.json"
    if args.action == "start":
        cur = load_current()
        if cur and cur["phase"] == "paused":
            return 0
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


def cmd_revisit(args) -> int:
    if load_current():
        print("finish the running interview first", file=sys.stderr)
        return 1
    session = Path(args.dir).resolve()
    dest = session / "improved"
    if dest.exists():
        print(f"{dest} already exists")
        return 0
    shutil.copytree(session, dest, ignore=shutil.ignore_patterns(*BUILD_DIRS, *REVIEW_FILES))
    for path in dest.rglob("*"):
        path.chmod(path.stat().st_mode | stat.S_IWUSR)
    print(f"writable copy at {dest}")
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
    p.set_defaults(fn=cmd_start)

    for name, fn in (("pause", do_pause), ("resume", do_resume), ("toggle", do_toggle), ("done", do_done), ("close", do_close)):
        p = sub.add_parser(name)
        p.set_defaults(fn=lambda _a, fn=fn: mutate(fn))

    p = sub.add_parser("approve-finish", help="interviewer only: allow the candidate to finish coding early")
    p.add_argument("reason")
    p.set_defaults(fn=cmd_approve_finish)

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

    p = sub.add_parser("auto", help="if an interview is due, ask with a notification and start it only on Start; run by the shell while the candidate is at the keyboard")
    p.add_argument("--verbose", action="store_true")
    p.set_defaults(fn=cmd_auto)

    p = sub.add_parser("daemon")
    p.set_defaults(fn=cmd_daemon)

    args = parser.parse_args()
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
