// Reclaim candidates: every removable item, the bytes deleting it frees and its rank.

use crate::store::{Store, UNRANKED};
use crate::sys;
use regex::Regex;
use serde_json::{json, Map, Value};
use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::process::{Command, Output, Stdio};
use std::sync::OnceLock;

const REBUILD_PENALTY: [(f64, f64); 4] = [(60.0, 1.0), (120.0, 1.25), (300.0, 2.0), (600.0, 4.0)];

pub fn rebuild_penalty(seconds: f64) -> f64 {
    let (last, top) = REBUILD_PENALTY[REBUILD_PENALTY.len() - 1];
    if seconds >= last {
        return top * seconds / last;
    }
    let mut previous = (0.0, 1.0);
    for point in REBUILD_PENALTY {
        if seconds < point.0 {
            let share = (seconds - previous.0) / (point.0 - previous.0);
            return previous.1 + share * (point.1 - previous.1);
        }
        previous = point;
    }
    top
}
pub const UNKNOWN_TEMP_FACTOR: f64 = 1.0 / 4.0;
pub const UNMERGED_AGENT_FACTOR: f64 = 1.0 / 4.0;
pub const DIRTY_CLONE_FACTOR: f64 = 1.0 / 4.0;
pub const WEIGHT_PEAK_SECONDS: f64 = 30.0 * 86400.0;
pub const WEIGHT_TAIL_SECONDS: f64 = 60.0 * 86400.0;
pub const WEIGHT_STRENGTH: f64 = 0.5;

pub fn weight_influence(age: f64) -> f64 {
    WEIGHT_STRENGTH
        * if age <= WEIGHT_PEAK_SECONDS {
            age / WEIGHT_PEAK_SECONDS
        } else {
            (-(age - WEIGHT_PEAK_SECONDS) / WEIGHT_TAIL_SECONDS).exp()
        }
}
const TRUSTED_SPAN: i64 = 3600;
const EMPTY_LOG: u64 = 64;
const BUILD_LOGS: &str = "/nix/var/log/nix/drvs";
pub const CACHES: [&str; 18] = [
    ".cargo/registry/cache",
    ".cabal/packages",
    ".opam/download-cache",
    ".local/share/Steam/config/htmlcache",
    ".local/share/Steam/appcache/httpcache",
    ".local/share/Steam/appcache/librarycache",
    ".local/share/Steam/depotcache",
    ".nuget/packages",
    ".yarn/berry/cache",
    ".yarn/berry/metadata",
    ".bun/install/cache",
    ".zoom/data/cefcache",
    ".zoom/data/Emojis",
    ".zoom/data/PresenterLayoutWallpaper",
    ".zoom/data/PresenterLayoutWallpaper_Thumb",
    ".zoom/data/ZoomAppResource",
    ".zoom/data/ZoomAppIcon",
    ".zoom/logs",
];
pub const EMACS_TEMP: [&str; 2] = [".local/state/emacs/backups", ".local/state/emacs/auto-save"];
const KNOWN_PROFILES: [&str; 4] = ["system", "home-manager", "profile", "default"];
pub const ACTIVE_REASONS: [&str; 5] = [
    "in use by a process",
    "live agent session",
    "owner process alive",
    "chromium running",
    "pytest running",
];
pub const PROTECTED_CLASSES: [&str; 8] = [
    "running_system",
    "home_profile",
    "profiles",
    "previous",
    "shells",
    "processes",
    "tmp_roots",
    "roots",
];

macro_rules! pattern {
    ($name:ident, $text:expr) => {
        pub fn $name() -> &'static Regex {
            static CELL: OnceLock<Regex> = OnceLock::new();
            CELL.get_or_init(|| Regex::new($text).unwrap())
        }
    };
}

pattern!(generation_name, r"^(.+)-(\d+)-link$");
pattern!(
    derivable_temp,
    r"^(nix-shell\.[A-Za-z0-9]{6}|nix-shell-\d+-\d+|nix-\d+-\d+|nix-build-.+|nix-develop-\d+-\d+|\.?org\.chromium\.Chromium\..+|scoped_dir.+|nixwatch-.+\.log|pytest-of-.+|babel-[A-Za-z0-9]{6}|babel-stable-\d+|epdfinfo[A-Za-z0-9]{6}|tmp\.[A-Za-z0-9]{10}|tmp[a-z0-9_]{8})$"
);
pattern!(pid_temp, r"^nix(?:-develop|-shell)?-(\d+)-\d+$");
pattern!(
    chromium_temp,
    r"^(\.?org\.chromium\.Chromium\..+|scoped_dir.+)$"
);
pattern!(
    runtime_temp,
    r"^(\.[A-Za-z0-9]+-unix|hsperfdata_.*|cc-daemon-\d+|claude-\d+|claude-mcp-.*|systemd-private-.*|\.X\d+-lock|tmux-\d+|zellij-\d+|emacs\d+|ssh-.*|gpg-.*|pulse-.*|dbus-.*|kitty-.*|nvim.*|xdg-.*|lost\+found)$"
);
pattern!(
    session_name,
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
);
pattern!(
    derivable_output,
    r"^(target|dist|dist-newstyle|build|_build|out|\.lake|node_modules|__pycache__|\.mypy_cache|\.pytest_cache|\.ruff_cache|\.direnv|\.venv|venv|\.tox|\.stack-work|\.gradle|\.zig-cache|zig-out|elm-stuff|\.next|\.parcel-cache|_opam|result(-.*)?)$"
);
pattern!(result_name, r"^result(?:-.+)?$");
pattern!(shell_roots_dir, r"^/run/user/\d+/nix-shell-roots$");

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum Kind {
    Dead,
    Cache,
    Temp,
    StaleShell,
    Stray,
    Build,
    Project,
    Deploy,
    Generation,
    Agent,
    Repo,
    Game,
    Trash,
    Download,
}

pub const KINDS: [Kind; 14] = [
    Kind::Dead,
    Kind::Cache,
    Kind::Temp,
    Kind::StaleShell,
    Kind::Stray,
    Kind::Build,
    Kind::Project,
    Kind::Deploy,
    Kind::Generation,
    Kind::Agent,
    Kind::Repo,
    Kind::Game,
    Kind::Trash,
    Kind::Download,
];

impl Kind {
    pub fn name(self) -> &'static str {
        match self {
            Kind::Dead => "dead",
            Kind::Cache => "cache",
            Kind::Temp => "temp",
            Kind::StaleShell => "stale shell",
            Kind::Stray => "stray profile",
            Kind::Build => "build",
            Kind::Project => "project",
            Kind::Deploy => "deploy",
            Kind::Generation => "generation",
            Kind::Agent => "agent",
            Kind::Repo => "git clone",
            Kind::Game => "game",
            Kind::Trash => "recycle bin",
            Kind::Download => "download",
        }
    }

    pub fn key(self) -> &'static str {
        match self {
            Kind::StaleShell => "stale_shell",
            Kind::Stray => "stray",
            Kind::Repo => "repo",
            Kind::Trash => "trash",
            Kind::Download => "downloads",
            other => other.name(),
        }
    }

    pub fn weight(self) -> f64 {
        match self {
            Kind::Dead | Kind::StaleShell => 64.0,
            Kind::Build | Kind::Stray => 16.0,
            Kind::Cache | Kind::Project | Kind::Deploy => 4.0,
            Kind::Temp | Kind::Generation | Kind::Agent | Kind::Trash | Kind::Download => 1.0,
            Kind::Repo => 1.0 / 16.0,
            Kind::Game => 1.0 / 4.0,
        }
    }

    pub fn from_name(name: &str) -> Option<Kind> {
        KINDS
            .iter()
            .copied()
            .find(|kind| kind.name() == name || kind.key() == name)
    }
}

#[derive(Clone)]
pub struct Item {
    pub kind: Kind,
    pub path: String,
    pub last_used: i64,
    pub links: Vec<String>,
    pub files: Vec<String>,
    pub targets: Vec<u32>,
    pub store: Vec<u32>,
    pub store_bytes: u64,
    pub file_bytes: u64,
    pub detail: Map<String, Value>,
    pub rank: usize,
    pub build: i64,
    pub factor: f64,
}

fn permute<T>(items: &mut [T], mut order: Vec<usize>) {
    for start in 0..order.len() {
        let mut current = start;
        while order[current] != start {
            let next = order[current];
            items.swap(current, next);
            order[current] = current;
            current = next;
        }
        order[current] = current;
    }
}

impl Item {
    pub fn new(kind: Kind, path: impl Into<String>, last_used: f64) -> Item {
        Item {
            kind,
            path: path.into(),
            last_used: last_used as i64,
            links: Vec::new(),
            files: Vec::new(),
            targets: Vec::new(),
            store: Vec::new(),
            store_bytes: 0,
            file_bytes: 0,
            detail: Map::new(),
            rank: 0,
            build: 0,
            factor: 1.0,
        }
    }

    pub fn with_files(mut self, files: Vec<String>) -> Item {
        self.files = files;
        self
    }

    pub fn with_links(mut self, links: Vec<String>) -> Item {
        self.links = links;
        self
    }

    pub fn with_detail(mut self, detail: Value) -> Item {
        if let Value::Object(map) = detail {
            self.detail = map;
        }
        self
    }

    pub fn weight(&self) -> f64 {
        self.kind.weight() * self.factor
    }

    pub fn freed(&self) -> u64 {
        self.store_bytes + self.file_bytes
    }

    pub fn score(&self, now: i64) -> f64 {
        let age = (now - self.last_used).max(0) as f64;
        age * self.weight().powf(weight_influence(age)) / rebuild_penalty(self.build as f64)
    }

    pub fn flag(&self, key: &str) -> bool {
        self.detail.get(key).map(truthy).unwrap_or(false)
    }

    pub fn text(&self, key: &str) -> &str {
        self.detail.get(key).and_then(Value::as_str).unwrap_or("")
    }
}

pub fn truthy(value: &Value) -> bool {
    match value {
        Value::Null => false,
        Value::Bool(flag) => *flag,
        Value::Number(number) => number.as_f64().map(|value| value != 0.0).unwrap_or(false),
        Value::String(text) => !text.is_empty(),
        Value::Array(list) => !list.is_empty(),
        Value::Object(map) => !map.is_empty(),
    }
}

pub fn protected_class(link: &str, reason: &str) -> &'static str {
    let name = basename(link);
    if link == "/run/current-system"
        || link == "/run/booted-system"
        || reason == "booted generation"
        || (reason == "current generation" && name.starts_with("system-"))
    {
        return "running_system";
    }
    if link.ends_with("/gcroots/current-home")
        || (reason == "current generation" && name.starts_with("home-manager-"))
    {
        return "home_profile";
    }
    if reason == "current generation" {
        return "profiles";
    }
    if reason == "previous generation" || name == "previous-successful-boot" {
        return "previous";
    }
    if reason.starts_with("live shell") {
        return "shells";
    }
    if link.starts_with("/proc/") || link.starts_with('{') || ACTIVE_REASONS.contains(&reason) {
        return "processes";
    }
    if link.starts_with("/tmp/") {
        return "tmp_roots";
    }
    "roots"
}

pub fn basename(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}

pub fn dirname(path: &str) -> &str {
    match path.rfind('/') {
        Some(0) => "/",
        Some(index) => &path[..index],
        None => "",
    }
}

pub fn join(base: &str, name: &str) -> String {
    if base.ends_with('/') {
        format!("{base}{name}")
    } else {
        format!("{base}/{name}")
    }
}

pub fn lexists(path: &str) -> bool {
    sys::lstat(path).is_some()
}

pub fn is_symlink(path: &str) -> bool {
    sys::lstat(path)
        .map(|info| sys::is_link(info.mode))
        .unwrap_or(false)
}

pub fn is_dir(path: &str) -> bool {
    std::fs::metadata(path)
        .map(|meta| meta.is_dir())
        .unwrap_or(false)
}

pub fn lstat_time(path: &str) -> f64 {
    sys::lstat(path).map(|info| info.modified()).unwrap_or(0.0)
}

pub fn list_dir(path: &str) -> Option<Vec<String>> {
    let entries = std::fs::read_dir(path).ok()?;
    Some(
        entries
            .flatten()
            .map(|entry| entry.file_name().to_string_lossy().into_owned())
            .collect(),
    )
}

pub fn list_sorted(path: &str) -> Vec<String> {
    let mut names = list_dir(path).unwrap_or_default();
    names.sort();
    names
}

pub fn glob_sorted(path: &str) -> Vec<String> {
    let mut names = list_sorted(path);
    names.retain(|name| !name.starts_with('.'));
    names
}

pub fn glob_repos(home: &str) -> Vec<String> {
    let mut found = Vec::new();
    let mut stack = vec![home.to_string()];
    while let Some(directory) = stack.pop() {
        if directory != home && is_dir(&join(&directory, ".git")) {
            found.push(directory.clone());
        }
        for name in glob_sorted(&directory) {
            let child = join(&directory, &name);
            if is_dir(&child) && !is_symlink(&child) {
                stack.push(child);
            }
        }
    }
    found.sort();
    found
}

pub fn glob_worktrees(home: &str) -> Vec<String> {
    let mut found = Vec::new();
    let mut stack = vec![home.to_string()];
    while let Some(directory) = stack.pop() {
        let worktrees = join(&directory, ".claude/worktrees");
        if is_dir(&worktrees) {
            found.extend(
                glob_sorted(&worktrees)
                    .into_iter()
                    .map(|name| join(&worktrees, &name)),
            );
        }
        for name in glob_sorted(&directory) {
            let child = join(&directory, &name);
            if is_dir(&child) && !is_symlink(&child) {
                stack.push(child);
            }
        }
    }
    for repo in glob_repos(home) {
        found.extend(linked_worktrees(&repo));
    }
    found.sort();
    found.dedup();
    found
}

pub fn read_link(path: &str) -> Option<String> {
    std::fs::read_link(path)
        .ok()
        .map(|target| target.to_string_lossy().into_owned())
}

pub fn realpath(path: &str) -> String {
    std::fs::canonicalize(path)
        .map(|found| found.to_string_lossy().into_owned())
        .unwrap_or_else(|_| path.to_string())
}

pub fn boot_time() -> i64 {
    std::fs::read_to_string("/proc/stat")
        .ok()
        .and_then(|text| {
            text.lines().find_map(|line| {
                line.strip_prefix("btime ")
                    .and_then(|rest| rest.trim().parse().ok())
            })
        })
        .unwrap_or(0)
}

fn stat_fields(pid: &str) -> Option<(String, Vec<String>)> {
    let text = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let (head, tail) = text.rsplit_once(')')?;
    let name = head.split_once('(')?.1.to_string();
    Some((name, tail.split_whitespace().map(String::from).collect()))
}

pub fn alive(pid: i64, started: Option<&str>) -> bool {
    match stat_fields(&pid.to_string()) {
        Some((_, fields)) => match started {
            None => true,
            Some(value) => fields.get(19).map(String::as_str) == Some(value),
        },
        None => false,
    }
}

pub fn pids() -> Vec<String> {
    list_dir("/proc")
        .unwrap_or_default()
        .into_iter()
        .filter(|name| name.bytes().all(|byte| byte.is_ascii_digit()))
        .collect()
}

#[derive(Clone, Debug)]
pub struct Session {
    pub ids: HashSet<String>,
    pub started: f64,
    pub pid: i64,
    pub cwd: String,
}

pub fn live_sessions(home: &str) -> Vec<Session> {
    let mut found = Vec::new();
    let booted = boot_time() as f64;
    let directory = format!("{home}/.claude/sessions");
    for name in list_sorted(&directory) {
        let Some(stem) = name.strip_suffix(".json") else {
            continue;
        };
        let Ok(text) = std::fs::read_to_string(join(&directory, &name)) else {
            continue;
        };
        let Ok(data) = serde_json::from_str::<Value>(&text) else {
            continue;
        };
        let pid = data
            .get("pid")
            .and_then(Value::as_i64)
            .filter(|pid| *pid != 0)
            .or_else(|| stem.parse().ok());
        let Some(pid) = pid else { continue };
        let start = data.get("procStart").filter(|value| !value.is_null());
        let start_text = start.map(|value| match value {
            Value::String(text) => text.clone(),
            other => other.to_string(),
        });
        if !alive(pid, start_text.as_deref()) {
            continue;
        }
        let mut ids: HashSet<String> = HashSet::new();
        if let Some(id) = data.get("sessionId").and_then(Value::as_str) {
            ids.insert(id.to_string());
        }
        if let Some(former) = data.get("formerNames").and_then(Value::as_array) {
            ids.extend(
                former
                    .iter()
                    .filter_map(|entry| entry.get("sessionId").and_then(Value::as_str))
                    .map(String::from),
            );
        }
        ids.retain(|id| !id.is_empty());
        let ticks = start_text
            .as_deref()
            .and_then(|text| text.parse::<f64>().ok())
            .unwrap_or(0.0);
        let cwd = data
            .get("cwd")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        found.push(Session {
            ids,
            started: booted + ticks / sys::clock_ticks(),
            pid,
            cwd,
        });
    }
    found
}

pub fn owner_pid(name: &str) -> Option<i64> {
    pid_temp()
        .captures(name)
        .and_then(|found| found[1].parse().ok())
        .filter(|pid| alive(*pid, None))
}

pub fn holders(root: &str) -> Vec<(String, i64)> {
    let prefix = format!("{root}/");
    let mut found = Vec::new();
    for pid in pids() {
        let Ok(number) = pid.parse::<i64>() else {
            continue;
        };
        let proc = format!("/proc/{pid}");
        let mut targets: Vec<String> = read_link(&join(&proc, "cwd")).into_iter().collect();
        if let Some(fds) = list_dir(&join(&proc, "fd")) {
            targets.extend(
                fds.iter()
                    .filter_map(|fd| read_link(&format!("{proc}/fd/{fd}"))),
            );
        }
        if let Ok(maps) = std::fs::read_to_string(join(&proc, "maps")) {
            targets.extend(
                maps.lines()
                    .filter_map(|line| line.find(&prefix).map(|at| line[at..].to_string())),
            );
        }
        if let Ok(environ) = std::fs::read(join(&proc, "environ")) {
            targets.extend(
                environ
                    .split(|byte| *byte == 0)
                    .filter_map(|entry| entry.strip_prefix(&b"TMPDIR="[..]))
                    .map(|value| String::from_utf8_lossy(value).into_owned()),
            );
        }
        found.extend(
            targets
                .into_iter()
                .filter(|target| target.starts_with(&prefix))
                .map(|target| (target, number)),
        );
    }
    found
}

pub fn busy_paths() -> HashSet<String> {
    let mut found: HashSet<String> = HashSet::new();
    for pid in pids() {
        let proc = format!("/proc/{pid}");
        for link in ["cwd", "root"] {
            if let Some(target) = read_link(&join(&proc, link)) {
                found.insert(target);
            }
        }
        if let Some(fds) = list_dir(&join(&proc, "fd")) {
            for fd in fds {
                if let Some(target) = read_link(&format!("{proc}/fd/{fd}")) {
                    if target.starts_with('/') {
                        found.insert(
                            target
                                .strip_suffix(" (deleted)")
                                .unwrap_or(&target)
                                .to_string(),
                        );
                    }
                }
            }
        }
        if let Ok(environ) = std::fs::read(join(&proc, "environ")) {
            for entry in environ.split(|byte| *byte == 0) {
                for prefix in [&b"TMPDIR="[..], &b"NIX_BUILD_TOP="[..]] {
                    if let Some(value) = entry.strip_prefix(prefix) {
                        found.insert(String::from_utf8_lossy(value).into_owned());
                    }
                }
            }
        }
    }
    found.extend(bound_sockets());
    let mut ancestors: HashSet<String> = HashSet::new();
    for path in found {
        let mut current = path.as_str();
        while !ancestors.contains(current) && current != "/" && !current.is_empty() {
            ancestors.insert(current.to_string());
            current = dirname(current);
        }
    }
    ancestors
}

pub fn bound_sockets() -> Vec<String> {
    std::fs::read_to_string("/proc/net/unix")
        .unwrap_or_default()
        .lines()
        .skip(1)
        .filter_map(|line| line.split_whitespace().nth(7))
        .filter(|path| path.starts_with('/'))
        .map(str::to_string)
        .collect()
}

pub fn process_starts() -> HashMap<String, Vec<f64>> {
    let booted = boot_time() as f64;
    let ticks = sys::clock_ticks();
    let mut starts: HashMap<String, Vec<f64>> = HashMap::new();
    for pid in pids() {
        let Some((name, fields)) = stat_fields(&pid) else {
            continue;
        };
        let Some(started) = fields.get(19).and_then(|value| value.parse::<f64>().ok()) else {
            continue;
        };
        let started = booted + started / ticks;
        if ["python", ".python", "pytest", ".pytest"]
            .iter()
            .any(|prefix| name.starts_with(prefix))
        {
            if let Ok(cmdline) = std::fs::read(format!("/proc/{pid}/cmdline")) {
                if cmdline.windows(6).any(|window| window == b"pytest") {
                    starts.entry("pytest".into()).or_default().push(started);
                }
            }
        }
        starts.entry(name).or_default().push(started);
    }
    starts
}

fn git_repository(path: &str) -> bool {
    Path::new(&join(path, "HEAD")).is_file() && is_dir(&join(path, "objects"))
}

fn nix_running() -> Option<String> {
    pids().into_iter().find_map(|pid| {
        let name = std::fs::read_to_string(format!("/proc/{pid}/comm")).ok()?;
        let name = name.trim();
        (name == "nix" || (name.starts_with("nix-") && name != "nix-daemon"))
            .then(|| format!("{name} is running"))
    })
}

pub fn cache_known(path: &str) -> bool {
    basename(path) != "nix-gcroots"
}

pub fn user_ids(user: &str) -> Option<(u32, u32)> {
    let name = sys::cstr(user);
    let entry = unsafe { libc::getpwnam(name.as_ptr()) };
    if entry.is_null() {
        return None;
    }
    Some(unsafe { ((*entry).pw_uid, (*entry).pw_gid) })
}

pub fn user_name(uid: u32) -> Option<String> {
    static NAMES: std::sync::Mutex<Option<HashMap<u32, Option<String>>>> =
        std::sync::Mutex::new(None);
    let mut names = NAMES
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    names
        .get_or_insert_with(HashMap::new)
        .entry(uid)
        .or_insert_with(|| {
            let entry = unsafe { libc::getpwuid(uid) };
            if entry.is_null() {
                return None;
            }
            Some(sys::c_to_string(unsafe {
                std::ffi::CStr::from_ptr((*entry).pw_name)
            }))
        })
        .clone()
}

pub fn uid_of(user: &str) -> u32 {
    user_ids(user).map(|ids| ids.0).unwrap_or(0)
}

pub fn run_as(user: &str, command: &[&str], input: Option<&str>) -> Output {
    let mut words: Vec<String> = command.iter().map(|word| word.to_string()).collect();
    if unsafe { libc::geteuid() } == 0 && user != "root" {
        if let Some((uid, gid)) = user_ids(user) {
            let mut wrapped = vec![
                "setpriv".to_string(),
                format!("--reuid={uid}"),
                format!("--regid={gid}"),
                "--init-groups".into(),
                "--".into(),
            ];
            wrapped.extend(words);
            words = wrapped;
        }
    }
    let mut child = Command::new(&words[0]);
    child
        .args(&words[1..])
        .env("GIT_OPTIONAL_LOCKS", "0")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    child.stdin(if input.is_some() {
        Stdio::piped()
    } else {
        Stdio::null()
    });
    let Ok(mut running) = child.spawn() else {
        return Output {
            status: std::os::unix::process::ExitStatusExt::from_raw(127 << 8),
            stdout: Vec::new(),
            stderr: Vec::new(),
        };
    };
    let feeder = match (input, running.stdin.take()) {
        (Some(text), Some(mut stdin)) => {
            let text = text.to_string();
            Some(std::thread::spawn(move || {
                use std::io::Write;
                let _ = stdin.write_all(text.as_bytes());
            }))
        }
        _ => None,
    };
    let output = running.wait_with_output();
    if let Some(feeder) = feeder {
        let _ = feeder.join();
    }
    output.unwrap_or_else(|_| Output {
        status: std::os::unix::process::ExitStatusExt::from_raw(127 << 8),
        stdout: Vec::new(),
        stderr: Vec::new(),
    })
}

pub fn stdout(output: &Output) -> String {
    String::from_utf8_lossy(&output.stdout).into_owned()
}

const START_SLACK: f64 = 600.0;

pub fn temp_activity(
    path: &str,
    used: f64,
    starts: &HashMap<String, Vec<f64>>,
) -> Option<&'static str> {
    let name = basename(path);
    if let Some(found) = pid_temp().captures(name) {
        if found[1]
            .parse()
            .map(|pid| alive(pid, None))
            .unwrap_or(false)
        {
            return Some("owner process alive");
        }
    }
    if chromium_temp().is_match(name) {
        let running = ["chromium", "chrome", ".chromium-wrapp"]
            .iter()
            .flat_map(|key| starts.get(*key).into_iter().flatten())
            .copied()
            .reduce(f64::min);
        if let Some(first) = running {
            if used >= first - START_SLACK {
                return Some("chromium running");
            }
        }
    }
    if name.starts_with("pytest-of-")
        && starts
            .get("pytest")
            .map(|list| !list.is_empty())
            .unwrap_or(false)
    {
        return Some("pytest running");
    }
    None
}

pub fn profile_generations(
    directory: &str,
) -> Vec<(String, std::collections::BTreeMap<i64, String>, Option<i64>)> {
    let Some(names) = list_dir(directory) else {
        return Vec::new();
    };
    let mut profiles: Vec<(String, std::collections::BTreeMap<i64, String>)> = Vec::new();
    for name in names {
        if let Some(found) = generation_name().captures(&name) {
            let profile = found[1].to_string();
            let number: i64 = found[2].parse().unwrap_or(0);
            let link = join(directory, &name);
            match profiles.iter_mut().find(|(known, _)| *known == profile) {
                Some((_, links)) => {
                    links.insert(number, link);
                }
                None => profiles.push((profile, [(number, link)].into_iter().collect())),
            }
        }
    }
    profiles
        .into_iter()
        .map(|(profile, links)| {
            let current = read_link(&join(directory, &profile)).and_then(|target| {
                generation_name()
                    .captures(&target)
                    .and_then(|found| found[2].parse().ok())
            });
            (profile, links, current)
        })
        .collect()
}

pub fn default_branch(repo: &str, user: &str) -> Option<String> {
    let head = stdout(&run_as(
        user,
        &[
            "git",
            "-C",
            repo,
            "symbolic-ref",
            "--short",
            "refs/remotes/origin/HEAD",
        ],
        None,
    ))
    .trim()
    .to_string();
    for branch in [head.as_str(), "main", "master"] {
        if !branch.is_empty()
            && run_as(
                user,
                &[
                    "git",
                    "-C",
                    repo,
                    "rev-parse",
                    "--verify",
                    "--quiet",
                    branch,
                ],
                None,
            )
            .status
            .success()
        {
            return Some(branch.to_string());
        }
    }
    None
}

#[derive(Clone)]
pub struct WorktreeState {
    pub dirty: usize,
    pub merged: bool,
    pub into: Option<String>,
    pub tracked: u64,
}

fn absolute(base: &str, path: &str) -> String {
    if path.starts_with('/') {
        path.to_string()
    } else {
        join(base, path)
    }
}

pub fn worktree_admin(worktree: &str) -> Option<String> {
    let link = join(worktree, ".git");
    if is_symlink(&link) || is_dir(&link) {
        return None;
    }
    let text = std::fs::read_to_string(&link).ok()?;
    let admin = absolute(worktree, text.trim().strip_prefix("gitdir: ")?);
    lexists(&join(&admin, "commondir")).then_some(admin)
}

pub fn worktree_repo(worktree: &str) -> Option<String> {
    let admin = worktree_admin(worktree)?;
    let common = std::fs::read_to_string(join(&admin, "commondir")).ok()?;
    let common = std::fs::canonicalize(absolute(&admin, common.trim())).ok()?;
    common.to_str()?.strip_suffix("/.git").map(String::from)
}

pub fn linked_worktrees(repo: &str) -> Vec<String> {
    let admin = join(repo, ".git/worktrees");
    list_sorted(&admin)
        .into_iter()
        .filter_map(|name| {
            let text = std::fs::read_to_string(join(&join(&admin, &name), "gitdir")).ok()?;
            let worktree = dirname(text.trim()).to_string();
            (is_dir(&worktree) && worktree_repo(&worktree).as_deref() == Some(repo))
                .then_some(worktree)
        })
        .collect()
}

pub fn worktree_shrunk(worktree: &str) -> bool {
    worktree_admin(worktree).is_some_and(|admin| lexists(&join(&admin, "ledger")))
}

fn tracked_files(worktree: &str, user: &str) -> Option<Vec<String>> {
    let listed = run_as(user, &["git", "-C", worktree, "ls-files", "-z"], None);
    listed.status.success().then(|| {
        stdout(&listed)
            .split('\0')
            .filter(|path| !path.is_empty())
            .map(String::from)
            .collect()
    })
}

pub fn worktree_state(repo: &str, worktree: &str, user: &str) -> Option<WorktreeState> {
    let dirty = run_as(
        user,
        &["git", "-C", worktree, "status", "--porcelain"],
        None,
    );
    if !dirty.status.success() {
        return None;
    }
    let branch = default_branch(repo, user);
    let merged = branch
        .as_deref()
        .map(|branch| {
            run_as(
                user,
                &[
                    "git",
                    "-C",
                    worktree,
                    "merge-base",
                    "--is-ancestor",
                    "HEAD",
                    branch,
                ],
                None,
            )
            .status
            .success()
        })
        .unwrap_or(false);
    let dirty = stdout(&dirty).lines().count();
    let tracked = if merged || dirty != 0 {
        0
    } else {
        tracked_files(worktree, user)?
            .iter()
            .filter_map(|path| sys::lstat(&join(worktree, path)))
            .filter(|info| sys::is_reg(info.mode) && info.nlink == 1)
            .map(|info| info.blocks * 512)
            .sum()
    };
    Some(WorktreeState {
        dirty,
        merged,
        into: branch,
        tracked,
    })
}

pub fn ignored(root: &str, lines: &[String], user: &str) -> Vec<String> {
    if lines.is_empty() {
        return Vec::new();
    }
    let input = lines.join("\0") + "\0";
    let result = run_as(
        user,
        &[
            "git",
            "-C",
            root,
            "check-ignore",
            "--no-index",
            "-z",
            "--stdin",
        ],
        Some(&input),
    );
    stdout(&result)
        .split('\0')
        .filter(|line| !line.is_empty())
        .map(String::from)
        .collect()
}

fn guards_source_only(path: &str, reason: &str) -> bool {
    reason.starts_with("git clone: ")
        || reason == "uncommitted changes"
        || (reason == "in use by a process" && lexists(&join(path, ".git")))
}

pub fn project_for(root: &str) -> Option<String> {
    if let Some((project, _)) = root.split_once("/.direnv/") {
        return Some(project.to_string());
    }
    if result_name().is_match(basename(root)) {
        return Some(dirname(root).to_string());
    }
    let mut parent = Path::new(root).parent();
    while let Some(directory) = parent {
        if [".git", ".envrc", "flake.nix"]
            .iter()
            .any(|marker| directory.join(marker).exists())
        {
            return Some(directory.to_string_lossy().into_owned());
        }
        parent = directory.parent();
    }
    None
}

pub fn walk_size(path: &str) -> u64 {
    let Some(info) = sys::lstat(path) else {
        return 0;
    };
    let mut seen: HashSet<u64> = HashSet::new();
    seen.insert(info.ino);
    let mut total = info.blocks;
    if sys::is_dir(info.mode) {
        sys::walk_tree(path, |entry| {
            if seen.insert(entry.ino) {
                total += entry.blocks;
            }
        });
    }
    total
}

pub fn walk_used(path: &str) -> f64 {
    let mut newest = lstat_time(path);
    if is_dir(path) && !is_symlink(path) {
        sys::walk_tree(path, |entry| newest = newest.max(entry.modified()));
    }
    newest
}

pub struct BuildTimes {
    root: String,
    store: Option<String>,
    shards: HashMap<String, i128>,
    seconds: HashMap<String, i64>,
    pub measured: HashMap<String, i64>,
    opened: HashMap<String, f64>,
    watches: HashMap<i32, String>,
    pub fd: Option<i32>,
    buffer: Vec<u8>,
}

impl BuildTimes {
    pub fn new(store: Option<String>) -> BuildTimes {
        let measured = store
            .as_ref()
            .and_then(|path| std::fs::read_to_string(path).ok())
            .and_then(|text| serde_json::from_str::<HashMap<String, f64>>(&text).ok())
            .map(|map| {
                map.into_iter()
                    .map(|(key, value)| (key, value as i64))
                    .collect()
            })
            .unwrap_or_default();
        BuildTimes {
            root: BUILD_LOGS.into(),
            store,
            shards: HashMap::new(),
            seconds: HashMap::new(),
            measured,
            opened: HashMap::new(),
            watches: HashMap::new(),
            fd: None,
            buffer: vec![0u8; 65536],
        }
    }

    fn span(path: &str) -> i64 {
        let Some(info) = sys::statx(path) else {
            return 0;
        };
        if info.mask & libc::STATX_BTIME == 0 || info.size <= EMPTY_LOG {
            return 0;
        }
        let span = info.mtime - info.btime;
        if (0..TRUSTED_SPAN).contains(&span) {
            span
        } else {
            0
        }
    }

    pub fn watch(&mut self) {
        let Some(fd) = sys::inotify() else { return };
        self.fd = Some(fd);
        let root = self.root.clone();
        self.add(&root, "", libc::IN_CREATE);
        for shard in list_dir(&root).unwrap_or_default() {
            self.add(
                &join(&root, &shard),
                &shard,
                libc::IN_OPEN | libc::IN_CLOSE_WRITE | libc::IN_CLOSE_NOWRITE,
            );
        }
    }

    fn add(&mut self, path: &str, shard: &str, mask: u32) {
        if let Some(wd) = self.fd.and_then(|fd| sys::inotify_watch(fd, path, mask)) {
            self.watches.insert(wd, shard.to_string());
        }
    }

    pub fn drain(&mut self) {
        let Some(fd) = self.fd else { return };
        let now = sys::now();
        let mut changed = false;
        while let Some(count) = sys::read_nonblocking(fd, &mut self.buffer) {
            let data = self.buffer[..count].to_vec();
            let mut offset = 0;
            while offset + 16 <= data.len() {
                let wd = sys::i32_at(&data, offset);
                let mask = sys::u32_at(&data, offset + 4);
                let length = sys::u32_at(&data, offset + 12) as usize;
                let raw = &data[offset + 16..offset + 16 + length];
                let name = String::from_utf8_lossy(
                    raw.split(|byte| *byte == 0).next().unwrap_or_default(),
                )
                .into_owned();
                offset += 16 + length;
                let Some(shard) = self.watches.get(&wd).cloned() else {
                    continue;
                };
                if shard.is_empty() {
                    if mask & libc::IN_CREATE != 0 && mask & libc::IN_ISDIR != 0 {
                        let root = self.root.clone();
                        self.add(
                            &join(&root, &name),
                            &name,
                            libc::IN_OPEN | libc::IN_CLOSE_WRITE | libc::IN_CLOSE_NOWRITE,
                        );
                    }
                    continue;
                }
                if mask & libc::IN_ISDIR != 0 || name.is_empty() {
                    continue;
                }
                let drv = format!("{shard}{}", name.strip_suffix(".bz2").unwrap_or(&name));
                if mask & libc::IN_OPEN != 0 {
                    self.opened.entry(drv).or_insert(now);
                } else if mask & libc::IN_CLOSE_WRITE != 0 {
                    if let Some(opened) = self.opened.remove(&drv) {
                        self.measured.insert(drv, (now - opened).round() as i64);
                        changed = true;
                    }
                } else if mask & libc::IN_CLOSE_NOWRITE != 0 {
                    self.opened.remove(&drv);
                }
            }
        }
        if changed {
            if let Some(store) = &self.store {
                let temporary = format!("{store}.tmp");
                if std::fs::write(
                    &temporary,
                    serde_json::to_string(&self.measured).unwrap_or_default(),
                )
                .is_ok()
                {
                    let _ = std::fs::rename(&temporary, store);
                }
            }
        }
    }

    pub fn refresh(&mut self) {
        let Some(shards) = list_dir(&self.root) else {
            return;
        };
        for shard in shards {
            let directory = join(&self.root, &shard);
            let Ok(meta) = std::fs::metadata(&directory) else {
                continue;
            };
            use std::os::unix::fs::MetadataExt;
            let stamp = meta.mtime() as i128 * 1_000_000_000 + meta.mtime_nsec() as i128;
            if self.shards.get(&shard) == Some(&stamp) {
                continue;
            }
            self.shards.insert(shard.clone(), stamp);
            for name in list_dir(&directory).unwrap_or_default() {
                let key = format!("{shard}{}", name.strip_suffix(".bz2").unwrap_or(&name));
                self.seconds
                    .insert(key, BuildTimes::span(&join(&directory, &name)));
            }
        }
    }

    pub fn of(&self, drv: &str, inputs_ready: Option<i64>) -> i64 {
        let name = basename(drv);
        if let Some(value) = self.measured.get(name) {
            return *value;
        }
        let span = self.seconds.get(name).copied().unwrap_or(0);
        match inputs_ready {
            Some(ready) if span != 0 => span.min(ready),
            _ => span,
        }
    }
}

pub trait Files {
    fn size(&self, path: &str) -> u64;
    fn used(&self, path: &str) -> f64;
}

pub struct Walked;

impl Files for Walked {
    fn size(&self, path: &str) -> u64 {
        walk_size(path)
    }

    fn used(&self, path: &str) -> f64 {
        walk_used(path)
    }
}

#[derive(Clone)]
pub struct Scope {
    pub home: String,
    pub user: String,
    pub uid: u32,
    pub tmp: String,
    pub offload: Option<String>,
    pub measured: i64,
}

impl Scope {
    pub fn refusal(
        &self,
        entry: &Work,
        busy: &HashSet<String>,
        sessions: &[Session],
        starts: &HashMap<String, Vec<f64>>,
    ) -> Option<String> {
        for link in &entry.links {
            if lexists(link) && !is_symlink(link) {
                return Some(format!("not a link: {link}"));
            }
        }
        for path in &entry.files {
            if !lexists(path) {
                continue;
            }
            if busy.contains(path) {
                return Some("in use by a process".into());
            }
            if sys::lstat(path).is_some_and(|info| info.ctime > self.measured) {
                return Some("changed since measured".into());
            }
            let parent = dirname(path);
            let name = basename(path);
            match entry.kind {
                Kind::Cache => {
                    let caches: Vec<String> = CACHES
                        .iter()
                        .map(|relative| join(&self.home, relative))
                        .collect();
                    let home_cache = format!("{}/.cache", self.home);
                    let top = [home_cache.as_str(), "/root/.cache"]
                        .iter()
                        .find_map(|base| {
                            path.strip_prefix(&format!("{base}/"))
                                .map(|rest| join(base, rest.split('/').next().unwrap_or("")))
                        });
                    let within =
                        |root: &String| path == root || path.starts_with(&format!("{root}/"));
                    if !(top.is_some_and(|top| cache_known(&top)) || caches.iter().any(within))
                        || path.split('/').any(|part| part == "..")
                    {
                        return Some("not a known cache".into());
                    }
                    if path.contains("/.cache/nix/") || path.ends_with("/.cache/nix") {
                        if let Some(running) = nix_running() {
                            return Some(running);
                        }
                    }
                }
                Kind::Temp if EMACS_TEMP.iter().any(|dir| parent == join(&self.home, dir)) => {
                    if name == ".." || is_symlink(path) {
                        return Some("not a temp entry".into());
                    }
                }
                Kind::Temp => {
                    if parent != self.tmp || runtime_temp().is_match(name) {
                        return Some("not a temp entry".into());
                    }
                    let used = walk_used(path).max(lstat_time(path));
                    if let Some(reason) = temp_activity(path, used, starts) {
                        return Some(reason.into());
                    }
                }
                Kind::Agent
                    if entry.detail.contains_key("session") && truthy(&entry.detail["session"]) =>
                {
                    let ids: HashSet<&String> = sessions
                        .iter()
                        .flat_map(|session| session.ids.iter())
                        .collect();
                    let unknown = sessions
                        .iter()
                        .filter(|session| session.ids.is_empty())
                        .map(|session| session.started)
                        .reduce(f64::min);
                    let prefix = format!("{}/claude-{}/", self.tmp, self.uid);
                    if !(session_name().is_match(name) && path.starts_with(&prefix))
                        || ids.contains(&name.to_string())
                        || unknown
                            .map(|oldest| walk_used(path) >= oldest)
                            .unwrap_or(false)
                    {
                        return Some("live agent session".into());
                    }
                }
                Kind::Agent if entry.detail.get("worktree").map(truthy).unwrap_or(false) => {
                    let repo = entry
                        .detail
                        .get("repo")
                        .and_then(Value::as_str)
                        .unwrap_or("");
                    if worktree_repo(path).as_deref() != Some(repo) || worktree_shrunk(path) {
                        return Some("not a worktree".into());
                    }
                    let compress = entry.detail.get("compress").map(truthy).unwrap_or(false);
                    match worktree_state(repo, path, &self.user) {
                        Some(state) if state.dirty == 0 && (compress || state.merged) => {}
                        Some(state) if state.dirty == 0 => {
                            return Some("no longer merged".into());
                        }
                        _ => return Some("uncommitted changes".into()),
                    }
                }
                Kind::StaleShell => {
                    let live = name
                        .parse::<i64>()
                        .map(|pid| alive(pid, None))
                        .unwrap_or(true);
                    if !(shell_roots_dir().is_match(parent)
                        && !name.is_empty()
                        && name.bytes().all(|byte| byte.is_ascii_digit()))
                        || live
                    {
                        return Some("live shell".into());
                    }
                }
                Kind::Build => {
                    let offload = entry.detail.get("offload").map(truthy).unwrap_or(false)
                        && self.offload.as_deref() == Some(parent)
                        && Path::new(&join(path, ".dev-build-last-used")).exists();
                    if !(offload || derivable_output().is_match(name)) || is_symlink(path) {
                        return Some("not a build output".into());
                    }
                }
                Kind::Game => {
                    let launcher = entry
                        .detail
                        .get("store")
                        .and_then(Value::as_str)
                        .unwrap_or("");
                    if let Some(running) = launcher_running(launcher) {
                        return Some(format!("{running} is running"));
                    }
                    if !games(&self.home, &entry.path)
                        .iter()
                        .any(|game| game.files.contains(path))
                    {
                        return Some("not an installed game".into());
                    }
                }
                Kind::Repo => {
                    if !clone_candidate(&self.home, &entry.path)
                        || path != &join(&entry.path, ".git/objects")
                        || busy.contains(&entry.path)
                    {
                        return Some("not a shrinkable clone".into());
                    }
                    let worktrees = entry.detail.get("worktrees").and_then(Value::as_array);
                    if worktrees
                        .into_iter()
                        .flatten()
                        .filter_map(Value::as_str)
                        .any(|tree| busy.contains(tree))
                    {
                        return Some("a linked worktree is in use".into());
                    }
                }
                Kind::Trash => {
                    let trash = join(&self.home, ".local/share/Trash");
                    let record = parent == join(&trash, "info") && name.ends_with(".trashinfo");
                    if !(record || parent == join(&trash, "files")) || name == ".." {
                        return Some("not in the recycle bin".into());
                    }
                }
                Kind::Download => {
                    if parent != join(&self.home, "Downloads") || name == ".." {
                        return Some("not in Downloads".into());
                    }
                }
                other => return Some(format!("{} owns no files", other.name())),
            }
        }
        None
    }
}

pub struct Claim {
    pub class: &'static str,
    pub link: String,
    pub found: Vec<u32>,
    pub bytes: u64,
}

pub struct Model {
    pub home: String,
    pub user: String,
    pub uid: u32,
    pub tmp: String,
    pub offload: Option<String>,
    worktrees: HashMap<String, ((f64, f64), Option<WorktreeState>)>,
    pub clones: Clones,
    clone_worker: std::sync::Arc<std::sync::atomic::AtomicBool>,
    ignored: HashMap<String, ((f64, f64), Vec<String>)>,
    pub items: Vec<Item>,
    pub file_items: Vec<usize>,
    pub merged: Vec<usize>,
    pub protected: HashMap<String, String>,
    pub claims: Vec<Claim>,
    pub live: Vec<bool>,
    pub now: i64,
    pub laps: Vec<(&'static str, f64)>,
    pub builds: BuildTimes,
}

pub type Explicit = HashMap<String, usize>;

impl Model {
    pub fn new(home: &str, user: &str, offload: Option<String>, builds: BuildTimes) -> Model {
        Model {
            home: home.trim_end_matches('/').to_string(),
            user: user.into(),
            uid: uid_of(user),
            tmp: "/tmp".into(),
            offload,
            worktrees: HashMap::new(),
            clones: Clones::default(),
            clone_worker: Default::default(),
            ignored: HashMap::new(),
            items: Vec::new(),
            file_items: Vec::new(),
            merged: Vec::new(),
            protected: HashMap::new(),
            claims: Vec::new(),
            live: Vec::new(),
            now: 0,
            laps: Vec::new(),
            builds,
        }
    }

    pub fn holds(&self, slot: u32) -> bool {
        self.live.get(slot as usize).copied().unwrap_or(false)
    }

    pub fn scope(&self) -> Scope {
        Scope {
            home: self.home.clone(),
            user: self.user.clone(),
            uid: self.uid,
            tmp: self.tmp.clone(),
            offload: self.offload.clone(),
            measured: self.now,
        }
    }

    fn protect(&mut self, path: &str, reason: &str) {
        self.protected.insert(path.to_string(), reason.to_string());
    }

    fn generation_items(&mut self, items: &mut Vec<Item>, explicit: &mut Explicit) {
        let mut directories = vec![
            "/nix/var/nix/profiles".to_string(),
            format!("{}/.local/state/nix/profiles", self.home),
        ];
        directories.extend(
            glob_sorted("/nix/var/nix/profiles/per-user")
                .into_iter()
                .map(|name| join("/nix/var/nix/profiles/per-user", &name)),
        );
        let running: Vec<(String, &str)> = [
            ("/run/booted-system", "booted generation"),
            ("/run/current-system", "current generation"),
        ]
        .iter()
        .map(|(path, reason)| (realpath(path), *reason))
        .collect();
        let running_reason = |target: &str| {
            running
                .iter()
                .rev()
                .find(|(path, _)| path == target)
                .map(|(_, reason)| *reason)
        };
        for directory in directories {
            for (profile, links, current) in profile_generations(&directory) {
                let numbers: Vec<i64> = links.keys().copied().collect();
                let stray = !KNOWN_PROFILES.contains(&profile.as_str());
                let mut keep: Vec<i64> = if stray {
                    Vec::new()
                } else {
                    numbers
                        .iter()
                        .copied()
                        .filter(|number| current.map(|current| *number <= current).unwrap_or(false))
                        .collect()
                };
                keep.sort();
                let keep: HashSet<i64> = keep.iter().rev().take(2).copied().collect();
                for (position, number) in numbers.iter().enumerate() {
                    let link = &links[number];
                    if keep.contains(number) {
                        self.protect(
                            link,
                            if Some(*number) == current {
                                "current generation"
                            } else {
                                "previous generation"
                            },
                        );
                        continue;
                    }
                    if let Some(reason) = running_reason(&realpath(link)) {
                        self.protect(link, reason);
                        continue;
                    }
                    let used = match numbers.get(position + 1) {
                        Some(successor) => lstat_time(&links[successor]),
                        None => lstat_time(link),
                    };
                    let kind = if stray { Kind::Stray } else { Kind::Generation };
                    let item = Item::new(kind, link.clone(), used).with_links(vec![link.clone()]).with_detail(json!({"profile": join(&directory, &profile), "number": number, "current": Some(*number) == current}));
                    explicit.insert(link.clone(), items.len());
                    items.push(item);
                }
            }
        }
    }

    fn shell_items(&mut self, items: &mut Vec<Item>, explicit: &mut Explicit) {
        for user in glob_sorted("/run/user") {
            let base = format!("/run/user/{user}/nix-shell-roots");
            for pid in glob_sorted(&base) {
                let directory = join(&base, &pid);
                let links: Vec<String> = glob_sorted(&directory)
                    .into_iter()
                    .map(|name| join(&directory, &name))
                    .collect();
                let number: Option<i64> =
                    if pid.bytes().all(|byte| byte.is_ascii_digit()) && !pid.is_empty() {
                        pid.parse().ok()
                    } else {
                        None
                    };
                if number.map(|number| alive(number, None)).unwrap_or(true) {
                    for link in &links {
                        self.protect(link, &format!("live shell {pid}"));
                    }
                    continue;
                }
                let item = Item::new(Kind::StaleShell, directory.clone(), lstat_time(&directory))
                    .with_links(links.clone())
                    .with_files(vec![directory.clone()])
                    .with_detail(json!({"pid": number}));
                for link in links {
                    explicit.insert(link, items.len());
                }
                items.push(item);
            }
        }
    }

    fn deploy_items(&mut self, items: &mut Vec<Item>, explicit: &mut Explicit) {
        let roots = format!("{}/.local/state/rebuild/roots", self.home);
        let mut links: Vec<String> = glob_sorted(&roots)
            .into_iter()
            .map(|name| join(&roots, &name))
            .collect();
        links.extend(
            list_sorted("/var/lib/flake-sync")
                .into_iter()
                .filter(|name| name.starts_with("result"))
                .map(|name| join("/var/lib/flake-sync", &name)),
        );
        let pinned = format!("{}/.cache/nix-gcroots", self.home);
        links.extend(
            list_sorted(&pinned)
                .into_iter()
                .map(|name| join(&pinned, &name))
                .filter(|link| {
                    std::fs::symlink_metadata(link).is_ok_and(|info| info.file_type().is_symlink())
                }),
        );
        for link in links {
            explicit.insert(link.clone(), items.len());
            items.push(
                Item::new(Kind::Deploy, link.clone(), lstat_time(&link)).with_links(vec![link]),
            );
        }
    }

    fn container_items(
        &mut self,
        items: &mut Vec<Item>,
        busy: &HashSet<String>,
        sessions: &[Session],
        files: &dyn Files,
        worktrees: &[String],
        repos: &[String],
    ) -> HashMap<String, usize> {
        let mut found: Vec<Item> = Vec::new();
        for (base, owner) in [
            (format!("{}/.cache", self.home), self.user.clone()),
            ("/root/.cache".to_string(), "root".to_string()),
        ] {
            for name in list_sorted(&base) {
                let child = join(&base, &name);
                if !cache_known(&child) {
                    self.protect(&child, "deploy roots");
                    continue;
                }
                found.push(
                    Item::new(Kind::Cache, child.clone(), files.used(&child))
                        .with_files(vec![child])
                        .with_detail(json!({"owner": owner})),
                );
            }
        }
        for relative in CACHES {
            let path = join(&self.home, relative);
            if Path::new(&path).exists() {
                found.push(
                    Item::new(Kind::Cache, path.clone(), files.used(&path))
                        .with_files(vec![path])
                        .with_detail(json!({"owner": self.user})),
                );
            }
        }
        found.extend(self.tmp_items(sessions, busy, files));
        found.extend(self.agent_worktrees(files, worktrees));
        found.extend(self.clone_items(files, repos));
        found.extend(self.game_items());
        found.extend(self.trash_items());
        found.extend(self.download_items(files));
        found.extend(self.emacs_items(files));
        found.extend(self.build_items(files));
        let mut containers = HashMap::new();
        for item in found {
            if busy.contains(&item.path) {
                if item.kind == Kind::Cache {
                    let owner = item.detail.get("owner").cloned().unwrap_or(Value::Null);
                    for part in self.split_held(&item.path, busy, 4) {
                        containers.insert(part.clone(), items.len());
                        items.push(
                            Item::new(Kind::Cache, part.clone(), files.used(&part))
                                .with_files(vec![part])
                                .with_detail(json!({"owner": owner, "within": item.path})),
                        );
                    }
                } else {
                    self.protect(&item.path, "in use by a process");
                }
                continue;
            }
            if !(matches!(item.kind, Kind::Repo | Kind::Game) || item.flag("compress")) {
                containers.insert(item.path.clone(), items.len());
            }
            items.push(item);
        }
        containers
    }

    fn split_held(&mut self, path: &str, busy: &HashSet<String>, depth: u32) -> Vec<String> {
        let children = match list_dir(path) {
            Some(children)
                if depth > 0
                    && children.len() <= 64
                    && Path::new(path).is_dir()
                    && !git_repository(path) =>
            {
                children
            }
            _ => {
                self.protect(path, "in use by a process");
                return Vec::new();
            }
        };
        let stem = |name: &str| {
            ["-journal", "-wal", "-shm"]
                .iter()
                .find_map(|suffix| name.strip_suffix(suffix))
                .unwrap_or(name)
                .to_string()
        };
        let held: HashSet<String> = children
            .iter()
            .filter(|name| busy.contains(&join(path, name)))
            .map(|name| stem(name))
            .collect();
        let mut free = Vec::new();
        for name in children {
            let child = join(path, &name);
            if busy.contains(&child) || (held.contains(&stem(&name)) && !Path::new(&child).is_dir())
            {
                if !busy.contains(&child) {
                    self.protect(&child, "in use by a process");
                    continue;
                }
                free.extend(self.split_held(&child, busy, depth - 1));
            } else {
                free.push(child);
            }
        }
        free
    }

    pub fn tmp_items(
        &mut self,
        sessions: &[Session],
        busy: &HashSet<String>,
        files: &dyn Files,
    ) -> Vec<Item> {
        let session_ids: HashSet<&String> = sessions
            .iter()
            .flat_map(|session| session.ids.iter())
            .collect();
        let oldest = sessions
            .iter()
            .filter(|session| session.ids.is_empty())
            .map(|session| session.started)
            .reduce(f64::min);
        let starts = process_starts();
        let mut out = Vec::new();
        let tmp = self.tmp.clone();
        if sys::lstat(&tmp)
            .zip(sys::lstat("/"))
            .is_none_or(|(tmp, root)| tmp.dev != root.dev)
        {
            return out;
        }
        for name in list_sorted(&tmp) {
            let path = join(&tmp, &name);
            let Some(info) = sys::lstat(&path) else {
                continue;
            };
            if runtime_temp().is_match(&name) || !(sys::is_dir(info.mode) || sys::is_reg(info.mode))
            {
                continue;
            }
            let owner = if info.uid == 0 || info.uid == self.uid {
                user_name(info.uid)
            } else {
                None
            };
            let Some(owner) = owner else { continue };
            if busy.contains(&path) {
                continue;
            }
            let used = files.used(&path).max(info.modified());
            if let Some(reason) = temp_activity(&path, used, &starts) {
                self.protect(&path, reason);
                continue;
            }
            let known = derivable_temp().is_match(&name);
            let mut item = Item::new(Kind::Temp, path.clone(), used)
                .with_files(vec![path])
                .with_detail(json!({"owner": owner, "pattern": known}));
            item.factor = if known { 1.0 } else { UNKNOWN_TEMP_FACTOR };
            out.push(item);
        }
        let scratch = format!("{tmp}/claude-{}", self.uid);
        for project in glob_sorted(&scratch) {
            let directory = join(&scratch, &project);
            for name in glob_sorted(&directory) {
                if !session_name().is_match(&name) {
                    continue;
                }
                let session_dir = join(&directory, &name);
                let used = files.used(&session_dir);
                if session_ids.contains(&name)
                    || oldest.map(|oldest| used >= oldest).unwrap_or(false)
                {
                    self.protect(&session_dir, "live agent session");
                    continue;
                }
                let mut item = Item::new(Kind::Agent, session_dir.clone(), used)
                    .with_files(vec![session_dir])
                    .with_detail(json!({"owner": self.user, "session": name}));
                item.factor = UNMERGED_AGENT_FACTOR;
                out.push(item);
            }
        }
        out
    }

    fn agent_worktrees(&mut self, files: &dyn Files, worktrees: &[String]) -> Vec<Item> {
        let mut out = Vec::new();
        let present: Vec<(&String, String, (f64, f64))> = worktrees
            .iter()
            .filter(|worktree| is_dir(worktree) && !worktree_shrunk(worktree))
            .filter_map(|worktree| {
                Some((
                    worktree,
                    worktree_repo(worktree)?,
                    (lstat_time(&join(worktree, ".git")), files.used(worktree)),
                ))
            })
            .collect();
        let stale: Vec<&(&String, String, (f64, f64))> = present
            .iter()
            .filter(|(worktree, _, key)| {
                self.worktrees
                    .get(*worktree)
                    .map(|(known, _)| known != key)
                    .unwrap_or(true)
            })
            .collect();
        let user = &self.user;
        let states: Vec<Option<WorktreeState>> = std::thread::scope(|scope| {
            let running: Vec<_> = stale
                .iter()
                .map(|(worktree, repo, _)| {
                    scope.spawn(move || worktree_state(repo, worktree, user))
                })
                .collect();
            running
                .into_iter()
                .map(|worker| worker.join().ok().flatten())
                .collect()
        });
        for ((worktree, _, key), state) in stale.into_iter().zip(states) {
            self.worktrees.insert((*worktree).clone(), (*key, state));
        }
        for (worktree, repo, _) in &present {
            let (worktree, repo) = (*worktree, repo.clone());
            let Some(state) = self.worktrees[worktree].1.clone() else {
                continue;
            };
            if state.dirty != 0 {
                self.protect(worktree, "uncommitted changes");
                continue;
            }
            let detail = json!({"owner": self.user, "repo": repo, "dirty": state.dirty, "merged": state.merged, "into": state.into, "worktree": true, "agent": worktree.contains("/.claude/worktrees/"), "compress": !state.merged, "tracked_bytes": state.tracked});
            let mut item = Item::new(Kind::Agent, worktree.clone(), files.used(worktree))
                .with_files(vec![worktree.clone()])
                .with_detail(detail);
            item.factor = if state.merged {
                1.0
            } else {
                UNMERGED_AGENT_FACTOR
            };
            out.push(item);
        }
        out
    }

    pub fn clones_pending(&self) -> bool {
        self.clone_worker.load(std::sync::atomic::Ordering::SeqCst)
    }

    fn clone_items(&mut self, files: &dyn Files, repos: &[String]) -> Vec<Item> {
        let now = sys::now();
        let repos: Vec<(String, f64)> = repos
            .iter()
            .filter(|repo| clone_candidate(&self.home, repo))
            .map(|repo| (repo.clone(), files.used(repo)))
            .collect();
        let stale: Vec<(String, f64)> = {
            let known = self
                .clones
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            repos
                .iter()
                .filter(|(repo, used)| match known.get(repo) {
                    Some(check) => {
                        now - check.at > CLONE_RECHECK_SECONDS
                            || (check.used != *used && now - check.at > CLONE_RETRY_SECONDS)
                    }
                    None => true,
                })
                .cloned()
                .collect()
        };
        if !stale.is_empty()
            && !self
                .clone_worker
                .swap(true, std::sync::atomic::Ordering::SeqCst)
        {
            let (clones, worker, user) = (
                self.clones.clone(),
                self.clone_worker.clone(),
                self.user.clone(),
            );
            std::thread::spawn(move || {
                for (repo, used) in stale {
                    let state = clone_state(&repo, &user);
                    clones
                        .lock()
                        .unwrap_or_else(|poisoned| poisoned.into_inner())
                        .insert(
                            repo,
                            CloneCheck {
                                used,
                                at: sys::now(),
                                state,
                            },
                        );
                }
                worker.store(false, std::sync::atomic::Ordering::SeqCst);
            });
        }
        let known = self.clones.clone();
        let known = known
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let mut out = Vec::new();
        for (repo, used) in repos {
            match known.get(&repo).map(|check| &check.state) {
                Some(Ok(state)) => {
                    let worktrees = state
                        .partial
                        .as_ref()
                        .map(|partial| partial.worktrees.clone());
                    let detail = json!({"owner": self.user, "clone": true, "dirty": state.dirty, "head": state.head, "remote": state.remote, "tracked_bytes": state.bytes, "clean_files": state.clean.len(), "unpushed": state.unpushed, "partial": state.partial.is_some(), "worktrees": worktrees.unwrap_or_default(), "submodules": state.submodules.len()});
                    let files = std::iter::once(join(&repo, ".git/objects"))
                        .chain(
                            state
                                .submodules
                                .iter()
                                .map(|(_, sub)| join(&sub.git_dir, "objects")),
                        )
                        .collect();
                    let mut item = Item::new(Kind::Repo, repo.clone(), used)
                        .with_files(files)
                        .with_detail(detail);
                    item.factor = if state.dirty == 0 {
                        1.0
                    } else {
                        DIRTY_CLONE_FACTOR
                    };
                    out.push(item);
                }
                Some(Err(reason)) if reason == "shrunk" || reason == "not a clone" => {}
                Some(Err(reason)) => self.protect(&repo, &format!("git clone: {reason}")),
                None => self.protect(&repo, "git clone: checking the remote"),
            }
        }
        out
    }

    fn build_items(&mut self, files: &dyn Files) -> Vec<Item> {
        let mut out = Vec::new();
        let state = format!("{}/.local/state/dev-build", self.home);
        let mut projects: Vec<(String, String, (f64, f64))> = Vec::new();
        for project in list_sorted(&state) {
            let record = format!("{state}/{project}/artefacts");
            if !Path::new(&record).exists() {
                continue;
            }
            let Ok(root) = std::fs::read_to_string(format!("{state}/{project}/root")) else {
                continue;
            };
            let root = root.trim().to_string();
            if !is_dir(&root) {
                continue;
            }
            let key = (lstat_time(&record), lstat_time(&join(&root, ".gitignore")));
            projects.push((record, root, key));
        }
        let stale: Vec<&(String, String, (f64, f64))> = projects
            .iter()
            .filter(|(record, _, key)| {
                self.ignored
                    .get(record)
                    .map(|(known, _)| known != key)
                    .unwrap_or(true)
            })
            .collect();
        let user = &self.user;
        let found: Vec<Vec<String>> = std::thread::scope(|scope| {
            let running: Vec<_> = stale
                .iter()
                .map(|(record, root, _)| {
                    scope.spawn(move || {
                        let lines: Vec<String> = std::fs::read_to_string(record)
                            .unwrap_or_default()
                            .lines()
                            .filter(|line| !line.is_empty() && !line.starts_with(".dev-build-"))
                            .map(String::from)
                            .collect();
                        ignored(root, &lines, user)
                    })
                })
                .collect();
            running
                .into_iter()
                .map(|worker| worker.join().unwrap_or_default())
                .collect()
        });
        for ((record, _, key), lines) in stale.into_iter().zip(found) {
            self.ignored.insert(record.clone(), (*key, lines));
        }
        for (record, root, _) in &projects {
            for line in self.ignored[record].1.clone() {
                let target = join(&root, line.trim_end_matches('/'));
                if derivable_output().is_match(basename(&target))
                    && Path::new(&target).exists()
                    && !is_symlink(&target)
                {
                    out.push(
                        Item::new(Kind::Build, target.clone(), files.used(&target))
                            .with_files(vec![target])
                            .with_detail(
                                json!({"owner": self.user, "project": root, "artefact": true}),
                            ),
                    );
                }
            }
        }
        if let Some(offload) = self.offload.clone() {
            if is_dir(&offload) {
                for name in list_sorted(&offload) {
                    let path = join(&offload, &name);
                    let marker = join(&path, ".dev-build-last-used");
                    if is_dir(&path) && !is_symlink(&path) && Path::new(&marker).exists() {
                        out.push(
                            Item::new(Kind::Build, path.clone(), lstat_time(&marker))
                                .with_files(vec![path])
                                .with_detail(json!({"owner": self.user, "offload": true})),
                        );
                    }
                }
            }
        }
        out
    }

    fn owner_of(
        &mut self,
        link: &str,
        explicit: &Explicit,
        containers: &HashMap<String, usize>,
        projects: &mut Vec<Item>,
        project_index: &mut HashMap<String, usize>,
    ) -> Option<Owner> {
        if let Some(index) = explicit.get(link) {
            return Some(Owner::Item(*index));
        }
        if self.protected.contains_key(link) {
            return None;
        }
        let mut path = link;
        while path != "/" && !path.is_empty() {
            if let Some(index) = containers.get(path) {
                return Some(Owner::Item(*index));
            }
            if self
                .protected
                .get(path)
                .is_some_and(|reason| !guards_source_only(path, reason))
            {
                return None;
            }
            path = dirname(path);
        }
        if [
            "/proc/",
            "{",
            "/run/current-system",
            "/run/booted-system",
            "/nix/var/nix/",
        ]
        .iter()
        .any(|prefix| link.starts_with(prefix))
            || !link.starts_with("/home/")
        {
            return None;
        }
        let key = project_for(link)?;
        let position = *project_index.entry(key.clone()).or_insert_with(|| {
            projects.push(
                Item::new(Kind::Project, format!("{key} roots"), 0.0)
                    .with_detail(json!({"roots": []})),
            );
            projects.len() - 1
        });
        let item = &mut projects[position];
        item.links.push(link.to_string());
        if let Some(Value::Array(roots)) = item.detail.get_mut("roots") {
            roots.push(Value::String(link.to_string()));
        }
        item.last_used = item.last_used.max(lstat_time(link) as i64);
        Some(Owner::Project(position))
    }

    pub fn refresh(
        &mut self,
        store: &mut Store,
        files: &dyn Files,
        worktrees: &[String],
        repos: &[String],
        now: i64,
    ) {
        let mut at = crate::tree::clock();
        let mut laps: Vec<(&'static str, f64)> = Vec::new();
        let mut lap = |name: &'static str| {
            let now = crate::tree::clock();
            laps.push((name, now - at));
            at = now;
        };
        self.protected.clear();
        let mut items: Vec<Item> = Vec::new();
        let mut explicit: Explicit = HashMap::new();
        let sessions = live_sessions(&self.home);
        let busy = busy_paths();
        lap("proc");
        self.generation_items(&mut items, &mut explicit);
        self.shell_items(&mut items, &mut explicit);
        self.deploy_items(&mut items, &mut explicit);
        lap("profiles");
        let containers =
            self.container_items(&mut items, &busy, &sessions, files, worktrees, repos);
        lap("containers");
        let mut projects: Vec<Item> = Vec::new();
        let mut project_index: HashMap<String, usize> = HashMap::new();
        let mut link_target: HashMap<String, Vec<u32>> = HashMap::new();
        for (path, links) in &store.root_links {
            if let Some(slot) = store.slot(path) {
                for link in links {
                    let entry = link_target.entry(link.clone()).or_default();
                    if !entry.contains(&slot) {
                        entry.push(slot);
                    }
                }
            } else {
                for link in links {
                    link_target.entry(link.clone()).or_default();
                }
            }
        }
        let mut links: Vec<(&String, &Vec<u32>)> = link_target.iter().collect();
        links.sort_by(|a, b| a.0.cmp(b.0));
        let mut protected_links: Vec<(String, Vec<u32>)> = Vec::new();
        let mut project_targets: Vec<(usize, Vec<u32>)> = Vec::new();
        for (link, targets) in links {
            match self.owner_of(
                link,
                &explicit,
                &containers,
                &mut projects,
                &mut project_index,
            ) {
                None => {
                    protected_links.push((link.clone(), targets.clone()));
                    self.protected
                        .entry(link.clone())
                        .or_insert_with(|| "root".into());
                }
                Some(Owner::Item(index)) => items[index].targets.extend(targets.iter().copied()),
                Some(Owner::Project(index)) => project_targets.push((index, targets.clone())),
            }
        }
        for (index, targets) in project_targets {
            projects[index].targets.extend(targets);
        }
        items.extend(projects);
        for item in items.iter_mut() {
            item.targets.sort_unstable();
            item.targets.dedup();
        }
        for slot in &store.dead {
            let entry = store.get(*slot);
            let used = store
                .effective
                .get(slot)
                .copied()
                .unwrap_or(entry.used.unwrap_or(0));
            let mut item = Item::new(Kind::Dead, entry.path.clone(), used as f64);
            item.targets = vec![*slot];
            items.push(item);
        }
        let mut protected_live: Vec<bool> = vec![false; store.paths.len()];
        let order = |name: &str| {
            PROTECTED_CLASSES
                .iter()
                .position(|class| *class == name)
                .unwrap_or(PROTECTED_CLASSES.len())
        };
        let mut classed: Vec<(&'static str, String, Vec<u32>)> = protected_links
            .into_iter()
            .map(|(link, targets)| {
                (
                    protected_class(
                        &link,
                        self.protected
                            .get(&link)
                            .map(String::as_str)
                            .unwrap_or("root"),
                    ),
                    link,
                    targets,
                )
            })
            .collect();
        classed.sort_by(|a, b| (order(a.0), &a.1).cmp(&(order(b.0), &b.1)));
        lap("links");
        self.claims.clear();
        store.unrank();
        for (class, link, targets) in classed {
            let found = claim(store, &targets, &mut protected_live);
            store.rank(&found, self.claims.len() as u32);
            self.claims.push(Claim {
                class,
                link,
                found,
                bytes: 0,
            });
        }
        lap("claims");
        self.builds.refresh();
        lap("builds");
        let mut live: Vec<bool> = Vec::new();
        items.shrink_to_fit();
        for _ in 0..2 {
            let scores: Vec<f64> = items.iter().map(|item| item.score(now)).collect();
            let mut order: Vec<usize> = (0..items.len()).collect();
            order.sort_unstable_by(|a, b| {
                scores[*b]
                    .total_cmp(&scores[*a])
                    .then_with(|| items[*a].path.cmp(&items[*b].path))
            });
            permute(&mut items, order);
            for (rank, item) in items.iter_mut().enumerate() {
                item.rank = rank;
            }
            live = protected_live.clone();
            for item in items.iter_mut().rev() {
                item.store = if item.kind == Kind::Dead {
                    claim_targets(store, &item.targets, &mut live)
                } else {
                    claim(store, &item.targets, &mut live)
                };
            }
            let mut owner = vec![u32::MAX; live.len()];
            for item in items.iter() {
                for slot in &item.store {
                    owner[*slot as usize] = item.rank as u32;
                }
            }
            for item in items.iter_mut() {
                let missing = missing_closure(store, &item.store, &owner, item.rank as u32);
                item.build = self.build_seconds(store, &missing);
            }
        }
        let mut taken = vec![false; store.paths.len()];
        for item in items.iter_mut() {
            let starts = if item.kind == Kind::Dead {
                item.targets.clone()
            } else {
                std::mem::take(&mut item.store)
            };
            item.store = removed_with(store, &starts, &mut taken);
        }
        for item in items.iter() {
            store.rank(
                &item.store,
                UNRANKED + 1 + (items.len() - 1 - item.rank) as u32,
            );
        }
        for item in items.iter_mut() {
            item.store_bytes = item.store.iter().map(|slot| store.size(*slot)).sum();
        }
        for claim in self.claims.iter_mut() {
            claim.bytes = claim.found.iter().map(|slot| store.size(*slot)).sum();
        }
        lap("rank");
        self.live = live;
        self.items = items;
        self.file_items = self
            .items
            .iter()
            .enumerate()
            .filter(|(_, item)| !item.files.is_empty())
            .map(|(index, _)| index)
            .collect();
        self.merged = self
            .file_items
            .iter()
            .copied()
            .filter(|index| {
                let item = &self.items[*index];
                item.flag("worktree") && item.flag("merged") && !item.flag("dirty")
            })
            .collect();
        self.measure_files(files);
        lap("files");
        self.laps = laps;
        self.now = now;
    }

    fn build_seconds(&self, store: &Store, paths: &[u32]) -> i64 {
        let mut seconds: HashMap<&str, i64> = HashMap::new();
        for slot in paths {
            let entry = store.get(*slot);
            let Some(drv) = entry.deriver.as_deref() else {
                continue;
            };
            let end = entry.registered;
            let ready = entry
                .refs
                .iter()
                .filter(|other| **other != *slot)
                .map(|other| store.get(*other).registered)
                .filter(|registered| *registered <= end)
                .max()
                .unwrap_or(0);
            let estimate = self
                .builds
                .of(drv, if ready != 0 { Some(end - ready) } else { None });
            let known = seconds.entry(drv).or_insert(0);
            *known = (*known).max(estimate);
        }
        seconds.values().sum()
    }

    pub fn measure_files(&mut self, files: &dyn Files) {
        let mut claimed: HashSet<&str> = HashSet::new();
        let mut ordered: std::collections::BTreeSet<&str> = std::collections::BTreeSet::new();
        let mut totals: Vec<(usize, u64)> = Vec::with_capacity(self.file_items.len());
        let ancestors = |path: &str| {
            path.match_indices('/')
                .map(|(at, _)| at)
                .filter(|at| *at > 0)
                .collect::<Vec<usize>>()
        };
        for index in &self.file_items {
            let mut total = 0u64;
            for path in &self.items[*index].files {
                let path = path.as_str();
                if claimed.contains(path)
                    || path
                        .match_indices('/')
                        .any(|(at, _)| at > 0 && claimed.contains(&path[..at]))
                {
                    continue;
                }
                let mut covered = 0i64;
                let lower = format!("{path}/");
                let inside: Vec<&str> = ordered
                    .range::<str, _>((
                        std::ops::Bound::Included(lower.as_str()),
                        std::ops::Bound::Unbounded,
                    ))
                    .take_while(|done| done.starts_with(&lower))
                    .copied()
                    .collect();
                if !inside.is_empty() {
                    let within: HashSet<&str> = inside.iter().copied().collect();
                    covered = inside
                        .iter()
                        .filter(|done| {
                            !ancestors(done)
                                .into_iter()
                                .any(|at| at > path.len() && within.contains(&done[..at]))
                        })
                        .map(|done| files.size(done) as i64)
                        .sum();
                }
                total += (files.size(path) as i64 - covered).max(0) as u64;
                claimed.insert(path);
                ordered.insert(path);
            }
            totals.push((*index, total));
        }
        for (index, total) in totals {
            let item = &mut self.items[index];
            item.file_bytes = if item.kind == Kind::Repo {
                let estimate = item
                    .detail
                    .get("tracked_bytes")
                    .and_then(Value::as_u64)
                    .unwrap_or(0);
                if truthy(item.detail.get("partial").unwrap_or(&Value::Null)) {
                    estimate.min(total)
                } else {
                    estimate.max(total)
                }
            } else if item.flag("compress") {
                item.detail
                    .get("tracked_bytes")
                    .and_then(Value::as_u64)
                    .unwrap_or(0)
                    .min(total)
            } else {
                total
            };
        }
    }
}

enum Owner {
    Item(usize),
    Project(usize),
}

pub fn missing_closure(store: &Store, freed: &[u32], owner: &[u32], rank: u32) -> Vec<u32> {
    let mut seen: HashSet<u32> = freed.iter().copied().collect();
    let mut stack: Vec<u32> = freed.to_vec();
    while let Some(slot) = stack.pop() {
        for other in &store.get(slot).refs {
            if owner.get(*other as usize).is_some_and(|by| *by <= rank) && seen.insert(*other) {
                stack.push(*other);
            }
        }
    }
    seen.into_iter().collect()
}

pub fn removed_with(store: &Store, starts: &[u32], taken: &mut [bool]) -> Vec<u32> {
    let mut found = Vec::new();
    let mut stack: Vec<u32> = starts.to_vec();
    while let Some(slot) = stack.pop() {
        if !store.get(slot).alive || std::mem::replace(&mut taken[slot as usize], true) {
            continue;
        }
        found.push(slot);
        stack.extend(
            store
                .get(slot)
                .referrers
                .iter()
                .filter(|up| !taken[**up as usize]),
        );
    }
    found
}

fn claim_targets(store: &Store, targets: &[u32], live: &mut [bool]) -> Vec<u32> {
    targets
        .iter()
        .copied()
        .filter(|slot| store.get(*slot).alive && !std::mem::replace(&mut live[*slot as usize], true))
        .collect()
}

pub fn claim(store: &Store, starts: &[u32], live: &mut [bool]) -> Vec<u32> {
    let mut found = Vec::new();
    let mut stack: Vec<u32> = starts
        .iter()
        .copied()
        .filter(|slot| store.get(*slot).alive && !live[*slot as usize])
        .collect();
    while let Some(slot) = stack.pop() {
        if std::mem::replace(&mut live[slot as usize], true) {
            continue;
        }
        found.push(slot);
        stack.extend(
            store
                .get(slot)
                .refs
                .iter()
                .filter(|other| !live[**other as usize]),
        );
    }
    found
}

#[derive(Clone)]
pub struct Work {
    pub kind: Kind,
    pub path: String,
    pub links: Vec<String>,
    pub files: Vec<String>,
    pub freed: u64,
    pub last_used: i64,
    pub detail: Map<String, Value>,
    pub store: Vec<String>,
}

impl Work {
    pub fn of(item: &Item) -> Work {
        Work {
            kind: item.kind,
            path: item.path.clone(),
            links: item.links.clone(),
            files: item.files.clone(),
            freed: item.freed(),
            last_used: item.last_used,
            detail: item.detail.clone(),
            store: Vec::new(),
        }
    }
}

#[cfg(test)]
mod tests;

pub const SHRUNK: &str = ".git/ledger";
const IN_PROGRESS: [&str; 7] = [
    "MERGE_HEAD",
    "CHERRY_PICK_HEAD",
    "REVERT_HEAD",
    "BISECT_LOG",
    "rebase-merge",
    "rebase-apply",
    "sequencer",
];
pub const CLONE_RETRY_SECONDS: f64 = 600.0;
pub const CLONE_RECHECK_SECONDS: f64 = 6.0 * 3600.0;

#[derive(Clone)]
pub struct CloneState {
    pub head: String,
    pub dirty: usize,
    pub clean: Vec<String>,
    pub bytes: u64,
    pub remote: String,
    pub unpushed: usize,
    pub bundle: String,
    pub partial: Option<Partial>,
    pub git_dir: String,
    pub submodules: Vec<(String, CloneState)>,
}

impl CloneState {
    pub fn shrunk_paths(&self, repo: &str) -> Vec<String> {
        let mut out = vec![join(&self.git_dir, "objects")];
        out.extend(self.clean.iter().map(|path| join(repo, path)));
        for (path, sub) in &self.submodules {
            out.extend(sub.shrunk_paths(path));
        }
        out
    }
}

#[derive(Clone)]
pub struct Partial {
    pub remote: String,
    pub worktrees: Vec<String>,
    pub heads: Vec<String>,
    pub present: Vec<String>,
}

pub struct CloneCheck {
    pub used: f64,
    pub at: f64,
    pub state: Result<CloneState, String>,
}

pub type Clones = std::sync::Arc<std::sync::Mutex<HashMap<String, CloneCheck>>>;

fn git(user: &str, repo: &str, args: &[&str], input: Option<&str>) -> Option<String> {
    let mut words = vec!["git", "-C", repo];
    words.extend_from_slice(args);
    let output = run_as(user, &words, input);
    output.status.success().then(|| stdout(&output))
}

pub fn network_url(url: &str) -> bool {
    if let Some((scheme, _)) = url.split_once("://") {
        return scheme != "file";
    }
    url.split_once(':')
        .is_some_and(|(host, _)| !host.is_empty() && !host.contains('/'))
}

pub fn https_form(url: &str) -> Option<String> {
    let (authority, path) = match url.split_once("://") {
        Some(("ssh" | "git+ssh", rest)) => rest.split_once('/')?,
        Some(_) => return None,
        None => url.split_once(':')?,
    };
    let host = authority.rsplit('@').next()?.split(':').next()?;
    Some(format!("https://{host}/{}", path.trim_start_matches('/')))
}

fn advertised(user: &str, repo: &str, url: &str) -> Option<HashSet<String>> {
    for candidate in std::iter::once(url.to_string()).chain(https_form(url)) {
        let output = run_as(
            user,
            &[
                "env",
                "GIT_TERMINAL_PROMPT=0",
                "GIT_SSH_COMMAND=ssh -o BatchMode=yes -o ConnectTimeout=10",
                "timeout",
                "60",
                "git",
                "-C",
                repo,
                "ls-remote",
                "--",
                &candidate,
            ],
            None,
        );
        if output.status.success() {
            return Some(
                stdout(&output)
                    .lines()
                    .filter_map(|line| line.split('\t').next())
                    .map(String::from)
                    .collect(),
            );
        }
    }
    None
}

pub fn clone_candidate(home: &str, repo: &str) -> bool {
    repo.strip_prefix(home)
        .and_then(|rest| rest.strip_prefix('/'))
        .is_some_and(|rest| {
            !rest.is_empty()
                && rest
                    .split('/')
                    .all(|part| !part.starts_with('.') && !part.is_empty())
        })
}

pub fn clone_state(repo: &str, user: &str) -> Result<CloneState, String> {
    let dot = join(repo, ".git");
    if lexists(&join(repo, SHRUNK)) {
        return Err("shrunk".into());
    }
    if !is_dir(&dot) || is_symlink(&dot) {
        return Err("not a clone".into());
    }
    let mut state = repo_state(repo, &dot, user)?;
    for path in submodules(repo, user)? {
        let name = path
            .strip_prefix(repo)
            .unwrap_or(&path)
            .trim_start_matches('/')
            .to_string();
        let sub_dot = submodule_git_dir(&path).ok_or(format!("submodule {name}: no git dir"))?;
        if lexists(&join(&sub_dot, "ledger")) {
            continue;
        }
        let found = repo_state(&path, &sub_dot, user)
            .map_err(|reason| format!("submodule {name}: {reason}"))?;
        if found.partial.is_some() {
            return Err(format!("submodule {name}: stash or linked worktrees"));
        }
        state.bytes += found.bytes;
        state.unpushed += found.unpushed;
        state.submodules.push((path, found));
    }
    Ok(state)
}

fn submodules(repo: &str, user: &str) -> Result<Vec<String>, String> {
    if !lexists(&join(repo, ".gitmodules")) {
        return Ok(Vec::new());
    }
    let listing = git(
        user,
        repo,
        &[
            "submodule",
            "--quiet",
            "foreach",
            "--recursive",
            "printf '%s\\0' \"$toplevel/$sm_path\"",
        ],
        None,
    )
    .ok_or("unreadable submodules")?;
    Ok(listing
        .split('\0')
        .filter(|path| !path.is_empty())
        .map(str::to_string)
        .collect())
}

fn submodule_git_dir(path: &str) -> Option<String> {
    let dot = join(path, ".git");
    if is_symlink(&dot) {
        return None;
    }
    if is_dir(&dot) {
        return Some(dot);
    }
    let text = std::fs::read_to_string(&dot).ok()?;
    let target = text.strip_prefix("gitdir: ")?.trim();
    let resolved = if target.starts_with('/') {
        target.to_string()
    } else {
        join(path, target)
    };
    is_dir(&resolved).then_some(resolved)
}

fn repo_state(repo: &str, dot: &str, user: &str) -> Result<CloneState, String> {
    if let Some(marker) = IN_PROGRESS
        .iter()
        .find(|marker| lexists(&join(&dot, marker)))
    {
        return Err(format!("{marker} in progress"));
    }
    let linked = !list_dir(&join(dot, "worktrees"))
        .unwrap_or_default()
        .is_empty();
    for (name, reason) in [("shallow", "shallow clone"), ("lfs", "has lfs objects")] {
        if lexists(&join(dot, name)) {
            return Err(reason.into());
        }
    }
    let config = git(user, repo, &["config", "--list", "-z"], None).ok_or("unreadable config")?;
    let mut remotes: Vec<(String, String)> = Vec::new();
    for entry in config.split('\0') {
        let (original, value) = entry.split_once('\n').unwrap_or((entry, ""));
        let key = original.to_ascii_lowercase();
        if (key == "core.sparsecheckout" || key == "core.bare") && value == "true" {
            return Err(format!("{key} set"));
        }
        if key.ends_with(".promisor") || key == "extensions.partialclone" {
            return Err("partial clone".into());
        }
        if key.starts_with("remote.") && key.ends_with(".url") && network_url(value) {
            let name = &original["remote.".len()..original.len() - ".url".len()];
            remotes.push((name.to_string(), value.to_string()));
        }
    }
    if remotes.is_empty() {
        return Err("no online remote".into());
    }
    let stashed = git(
        user,
        repo,
        &["rev-parse", "--verify", "--quiet", "refs/stash"],
        None,
    )
    .is_some();
    let partial = linked || stashed;
    if partial && lexists(&join(repo, "flake.nix")) {
        return Err("flake repo: nix rejects extensions.partialclone".into());
    }
    let head = git(user, repo, &["rev-parse", "--verify", "HEAD"], None)
        .ok_or("no commits")?
        .trim()
        .to_string();
    let listing = git(user, repo, &["ls-files", "-v", "-z"], None).ok_or("unreadable index")?;
    let mut tracked: Vec<&str> = Vec::new();
    for entry in listing.split('\0').filter(|entry| entry.len() > 2) {
        let tag = entry.as_bytes()[0];
        if !partial && (tag == b'S' || tag.is_ascii_lowercase()) {
            return Err("skip-worktree or assume-unchanged files".into());
        }
        if !partial && tag == b'M' {
            return Err("unmerged files".into());
        }
        tracked.push(&entry[2..]);
    }
    let status = git(
        user,
        repo,
        &[
            "status",
            "--porcelain=v1",
            "-z",
            "--untracked-files=all",
            "--ignored=no",
        ],
        None,
    )
    .ok_or("status failed")?;
    let mut changed: HashSet<&str> = HashSet::new();
    let mut dirty = 0;
    let mut records = status.split('\0').filter(|entry| !entry.is_empty());
    while let Some(record) = records.next() {
        dirty += 1;
        changed.insert(record.get(3..).unwrap_or(""));
        if matches!(record.as_bytes().first(), Some(b'R' | b'C')) {
            changed.extend(records.next());
        }
    }
    let mut shas: HashSet<String> = HashSet::new();
    let mut reached: Option<&(String, String)> = None;
    for named in &remotes {
        if let Some(found) = advertised(user, repo, &named.1) {
            reached = reached.or(Some(named));
            shas.extend(found);
        }
    }
    let (remote_name, remote) = reached.ok_or("remote unreachable")?.clone();
    let mut worktrees: Vec<String> = Vec::new();
    let mut heads: Vec<String> = Vec::new();
    if linked {
        let listing = git(user, repo, &["worktree", "list", "--porcelain", "-z"], None)
            .ok_or("unreadable worktrees")?;
        for field in listing.split('\0') {
            if let Some(path) = field.strip_prefix("worktree ") {
                if path != repo {
                    worktrees.push(path.to_string());
                }
            } else if let Some(sha) = field.strip_prefix("HEAD ") {
                heads.push(sha.to_string());
            }
        }
    }
    let refs = git(
        user,
        repo,
        &[
            "for-each-ref",
            "--format=%(objectname) %(objecttype)",
            "refs/heads",
            "refs/tags",
        ],
        None,
    )
    .ok_or("unreadable refs")?;
    let mut tips: Vec<String> = vec![head.clone()];
    tips.extend(heads.iter().cloned());
    for line in refs.lines() {
        tips.push(
            line.split_once(' ')
                .map(|(sha, _)| sha)
                .unwrap_or(line)
                .to_string(),
        );
    }
    let wanted: String = shas.iter().map(|sha| format!("{sha}\n")).collect();
    let checked =
        git(user, repo, &["cat-file", "--batch-check"], Some(&wanted)).ok_or("cat-file failed")?;
    let present: Vec<&str> = checked
        .lines()
        .filter(|line| !line.ends_with(" missing"))
        .filter_map(|line| line.split(' ').next())
        .collect();
    let input: String = tips
        .iter()
        .map(|tip| format!("{tip}\n"))
        .chain(present.iter().map(|sha| format!("^{sha}\n")))
        .collect();
    let everything: &[&str] = if partial {
        &["--all", "--reflog", "--indexed-objects"]
    } else {
        &[]
    };
    let counted = [&["rev-list", "--count", "--stdin"][..], everything].concat();
    let unpushed: usize = git(user, repo, &counted, Some(&input))
        .ok_or("rev-list failed")?
        .trim()
        .parse()
        .unwrap_or(usize::MAX);
    if unpushed != 0 && present.is_empty() {
        return Err(format!(
            "{unpushed} unpushed commits and nothing on the remote"
        ));
    }
    let bundle: String = ["HEAD\n", "--branches\n", "--tags\n"].concat()
        + &present
            .iter()
            .map(|sha| format!("^{sha}\n"))
            .collect::<String>();
    let usage = |args: &[&str], input: &str| -> Result<u64, String> {
        let words = [
            &["rev-list", "--objects", "--disk-usage", "--stdin"][..],
            args,
        ]
        .concat();
        Ok(git(user, repo, &words, Some(input))
            .ok_or("rev-list failed")?
            .trim()
            .parse()
            .unwrap_or(u64::MAX))
    };
    let kept: u64 = if unpushed == 0 && !partial {
        0
    } else {
        usage(everything, &input)?
    };
    if partial {
        let positive: String = tips.iter().map(|tip| format!("{tip}\n")).collect();
        let structure = usage(&["--all", "--reflog", "--filter=blob:none"], &positive)?;
        let bytes = walk_size(&join(&dot, "objects"))
            .saturating_sub(kept)
            .saturating_sub(structure);
        return Ok(CloneState {
            head,
            dirty,
            clean: Vec::new(),
            bytes,
            remote,
            unpushed,
            bundle: String::new(),
            partial: Some(Partial {
                remote: remote_name,
                worktrees,
                heads: tips,
                present: present.iter().map(|sha| sha.to_string()).collect(),
            }),
            git_dir: dot.to_string(),
            submodules: Vec::new(),
        });
    }
    let mut clean = Vec::new();
    let mut bytes = walk_size(&join(&dot, "objects")).saturating_sub(kept);
    for path in tracked {
        if changed.contains(path) || path.contains('\u{FFFD}') {
            continue;
        }
        let Some(info) = sys::lstat(&join(repo, path)) else {
            continue;
        };
        if sys::is_dir(info.mode) {
            continue;
        }
        if info.nlink == 1 {
            bytes += info.blocks;
        }
        clean.push(path.to_string());
    }
    Ok(CloneState {
        head,
        dirty,
        clean,
        bytes,
        remote,
        unpushed,
        bundle,
        partial: None,
        git_dir: dot.to_string(),
        submodules: Vec::new(),
    })
}

const RESTORE: &str = r#"#!/usr/bin/env bash
set -euo pipefail
gitdir=$(cd "$(dirname "$0")/.." && pwd)
worktree=$(git --git-dir="$gitdir" config core.worktree || true)
if [ -n "$worktree" ]; then
  top=$(cd "$gitdir" && cd "$worktree" && pwd)
else
  top=$(cd "$gitdir/.." && pwd)
fi
cd "$top"
state="$gitdir/ledger"
for remote in $(git remote); do
  git fetch --tags "$remote" || true
done
if [ -s "$state/unpushed.bundle" ]; then
  sed -n '2,/^$/p' "$state/unpushed.bundle" | sed -n 's/^-\([0-9a-f]*\).*/\1/p' | while read -r sha; do
    git cat-file -e "$sha" 2>/dev/null && continue
    for remote in $(git remote); do
      git fetch "$remote" "$sha" && break || true
    done
  done
  git bundle unbundle "$state/unpushed.bundle" > /dev/null
fi
while read -r sha ref; do
  git cat-file -e "$sha" 2>/dev/null && continue
  for remote in $(git remote); do
    git fetch "$remote" "$sha" && break || true
  done
done < "$state/refs"
while read -r sha ref; do
  case "$ref" in
    refs/remotes/*) git update-ref "$ref" "$sha" 2>/dev/null || true ;;
    *) git update-ref "$ref" "$sha" ;;
  esac
done < "$state/refs"
cp "$state/HEAD" "$gitdir/HEAD"
git read-tree HEAD
while IFS= read -r -d '' path; do
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    git checkout HEAD -- "$path"
  fi
done < "$state/deleted"
if [ -s "$state/staged.patch" ]; then
  git apply --cached "$state/staged.patch"
fi
mv "$state" "$gitdir/ledger-restored-$(date +%s)"
if [ -d "$gitdir/modules" ]; then
  mapfile -t nested < <(find "$gitdir/modules" -path '*/ledger/restore' -type f | sort)
  for script in "${nested[@]}"; do
    if [ -f "$script" ]; then
      bash "$script" > /dev/null
    fi
  done
fi
git status --short | head -20
"#;

const README: &str = "The disk ledger shrank this clone: objects, refs and unmodified tracked files were deleted; config, hooks, untracked, ignored and modified files were kept. Unpushed commits are kept in unpushed.bundle on top of commits the remote has. Run .git/ledger/restore to fetch it back from the remote.\n";

fn write_as(user: &str, path: &str, content: &str) -> bool {
    run_as(
        user,
        &["sh", "-c", "cat > \"$1\"", "sh", path],
        Some(content),
    )
    .status
    .success()
}

const WORKTREE_RESTORE: &str = r#"#!/usr/bin/env bash
set -euo pipefail
admin=$(cd "$(dirname "$0")/.." && pwd)
top=$(dirname "$(cat "$admin/gitdir")")
cd "$top"
git checkout -- .
mv "$admin/ledger" "$admin/ledger-restored-$(date +%s)"
git status --short | head -20
"#;

const WORKTREE_README: &str = "The disk ledger shrank this worktree: unmodified tracked files were deleted; untracked and ignored files were kept. Its commits stay in the main repository. Run ledger/restore here to check the files out again.\n";

pub fn shrink_worktree(worktree: &str, user: &str, uid: u32, gid: u32) -> Result<u64, String> {
    let started = sys::now();
    let admin = worktree_admin(worktree).ok_or("not a worktree")?;
    let keep = join(&admin, "ledger");
    if lexists(&keep) {
        return Err("shrunk".into());
    }
    let status = run_as(
        user,
        &["git", "-C", worktree, "status", "--porcelain"],
        None,
    );
    if !status.status.success() || !stdout(&status).trim().is_empty() {
        return Err("uncommitted changes".into());
    }
    let tracked = tracked_files(worktree, user).ok_or("unreadable index")?;
    let restore = join(&keep, "restore");
    let written = run_as(user, &["mkdir", "-p", &keep], None).status.success()
        && write_as(user, &restore, WORKTREE_RESTORE)
        && write_as(user, &join(&keep, "README"), WORKTREE_README)
        && run_as(user, &["chmod", "+x", &restore], None)
            .status
            .success();
    if !written {
        return Err("could not write the restore state".into());
    }
    let mut freed = 0;
    let mut targets = Vec::new();
    let mut parents = HashSet::new();
    for path in &tracked {
        let full = join(worktree, path);
        let Some(info) = sys::lstat(&full) else {
            continue;
        };
        if (info.ctime as f64) >= started - 2.0 {
            continue;
        }
        if sys::is_reg(info.mode) && info.nlink == 1 {
            freed += info.blocks * 512;
        }
        let mut parent = dirname(path);
        while !parent.is_empty() && parents.insert(parent.to_string()) {
            parent = dirname(parent);
        }
        targets.push(full);
    }
    let outcome = crate::remove::remove_as(uid, gid, targets);
    if let Some((path, code)) = outcome.failed.first() {
        return Err(format!("remove failed: {path}: {code}"));
    }
    let mut emptied: Vec<String> = parents.into_iter().collect();
    emptied.sort_by_key(|parent| std::cmp::Reverse(parent.len()));
    for parent in emptied {
        let _ = std::fs::remove_dir(join(worktree, &parent));
    }
    Ok(freed)
}

pub fn shrink_clone(repo: &str, user: &str, uid: u32, gid: u32) -> Result<u64, String> {
    let started = sys::now();
    let state = clone_state(repo, user)?;
    shrink_repo(repo, &state, user, uid, gid, started)?;
    for (path, sub) in &state.submodules {
        let name = path
            .strip_prefix(repo)
            .unwrap_or(path)
            .trim_start_matches('/');
        shrink_repo(path, sub, user, uid, gid, started)
            .map_err(|reason| format!("submodule {name}: {reason}"))?;
    }
    Ok(state.bytes)
}

fn shrink_repo(
    repo: &str,
    state: &CloneState,
    user: &str,
    uid: u32,
    gid: u32,
    started: f64,
) -> Result<(), String> {
    use std::os::unix::fs::MetadataExt;
    if let Some(partial) = &state.partial {
        return partial_shrink(repo, user, uid, gid, partial);
    }
    let dot = state.git_dir.clone();
    let keep = join(&dot, "ledger");
    let staged = join(&keep, "staged.patch");
    let uncommitted = join(&keep, "uncommitted.patch");
    let refs = git(
        user,
        repo,
        &["for-each-ref", "--format=%(objectname) %(refname)"],
        None,
    )
    .ok_or("unreadable refs")?;
    let head_file = std::fs::read_to_string(join(&dot, "HEAD")).map_err(|_| "unreadable HEAD")?;
    let branch = head_file
        .strip_prefix("ref: ")
        .map(|name| name.trim().to_string())
        .unwrap_or_else(|| "refs/heads/main".into());
    let fresh: Vec<&String> = state
        .clean
        .iter()
        .filter(|path| {
            std::fs::symlink_metadata(join(repo, path))
                .is_ok_and(|meta| (meta.ctime() as f64) < started - 2.0)
        })
        .collect();
    let deleted: String = fresh.iter().map(|path| format!("{path}\0")).collect();
    let mut ok = run_as(user, &["mkdir", "-p", &keep], None).status.success();
    ok = ok && run_as(user, &["sh", "-c", "git -C \"$1\" diff --binary HEAD > \"$2\" && git -C \"$1\" diff --cached --binary > \"$3\"", "sh", repo, &uncommitted, &staged], None).status.success();
    ok = ok
        && write_as(user, &join(&keep, "refs"), &refs)
        && write_as(user, &join(&keep, "HEAD"), &head_file)
        && write_as(user, &join(&keep, "deleted"), &deleted);
    ok =
        ok && write_as(
            user,
            &join(&keep, "remote"),
            &format!("{}\n{}\n", state.remote, state.head),
        ) && write_as(user, &join(&keep, "README"), README);
    if ok && state.unpushed > 0 {
        let bundle = join(&keep, "unpushed.bundle");
        ok = git(
            user,
            repo,
            &["bundle", "create", "--quiet", &bundle, "--stdin"],
            Some(&state.bundle),
        )
        .is_some()
            && git(user, repo, &["bundle", "verify", "--quiet", &bundle], None).is_some();
    }
    ok = ok
        && write_as(user, &join(&keep, "restore"), RESTORE)
        && run_as(user, &["chmod", "+x", &join(&keep, "restore")], None)
            .status
            .success();
    if !ok {
        return Err("could not write the restore state".into());
    }
    if !run_as(
        user,
        &["git", "-C", repo, "symbolic-ref", "HEAD", &branch],
        None,
    )
    .status
    .success()
    {
        return Err("could not park HEAD".into());
    }
    let mut targets: Vec<String> = fresh.iter().map(|path| join(repo, path)).collect();
    targets.extend(
        [
            "objects",
            "refs",
            "packed-refs",
            "logs",
            "index",
            "FETCH_HEAD",
            "ORIG_HEAD",
        ]
        .iter()
        .map(|name| join(&dot, name))
        .filter(|path| lexists(path)),
    );
    let outcome = crate::remove::remove_as(uid, gid, targets);
    let rebuilt = run_as(
        user,
        &[
            "mkdir",
            "-p",
            &join(&dot, "objects/info"),
            &join(&dot, "objects/pack"),
            &join(&dot, "refs/heads"),
            &join(&dot, "refs/tags"),
        ],
        None,
    )
    .status
    .success();
    let mut parents: Vec<String> = fresh
        .iter()
        .flat_map(|path| {
            path.match_indices('/')
                .map(|(at, _)| join(repo, &path[..at]))
                .collect::<Vec<_>>()
        })
        .collect::<HashSet<_>>()
        .into_iter()
        .collect();
    parents.sort_by_key(|path| std::cmp::Reverse(path.matches('/').count()));
    for chunk in parents.chunks(500) {
        let mut words = vec!["rmdir", "--ignore-fail-on-non-empty", "--"];
        words.extend(chunk.iter().map(String::as_str));
        run_as(user, &words, None);
    }
    if let Some((path, code)) = outcome.failed.first() {
        return Err(format!(
            "remove failed at {path}: {}",
            std::io::Error::from_raw_os_error(*code)
        ));
    }
    if !rebuilt {
        return Err("could not recreate the empty object store".into());
    }
    Ok(())
}

const LOCAL_PACK: &str = "local";
const STRUCTURE_PACK: &str = "structure";

fn partial_shrink(
    repo: &str,
    user: &str,
    uid: u32,
    gid: u32,
    partial: &Partial,
) -> Result<(), String> {
    let dot = join(repo, ".git");
    let objects = join(&dot, "objects");
    let pack_dir = join(&objects, "pack");
    let stage = join(&dot, "ledger-partial");
    let old = join(&stage, "old");
    if lexists(&stage) {
        return Err("a partial shrink was interrupted".into());
    }
    if !run_as(user, &["mkdir", "-p", &old], None).status.success() {
        return Err("could not create the staging directory".into());
    }
    for tree in std::iter::once(repo).chain(partial.worktrees.iter().map(String::as_str)) {
        if is_dir(tree) {
            run_as(
                user,
                &["git", "-C", tree, "update-index", "-q", "--refresh"],
                None,
            );
        }
    }
    let heads: String = partial.heads.iter().map(|sha| format!("{sha}\n")).collect();
    let negated: String = partial
        .present
        .iter()
        .map(|sha| format!("^{sha}\n"))
        .collect();
    let pack = |name: &str, args: &[&str], input: &str| -> Option<String> {
        let base = join(&stage, name);
        let words = [
            &["pack-objects", "-q", "--all", "--reflog"][..],
            args,
            &[base.as_str()],
        ]
        .concat();
        git(user, repo, &words, Some(input)).map(|hash| format!("{name}-{}", hash.trim()))
    };
    let built = pack(
        LOCAL_PACK,
        &["--indexed-objects"],
        &(heads.clone() + &negated),
    )
    .and_then(|local| {
        pack(STRUCTURE_PACK, &["--filter=blob:none"], &heads).map(|structure| (local, structure))
    });
    let Some((local, structure)) = built else {
        crate::remove::remove_as(uid, gid, vec![stage]);
        return Err("pack-objects failed".into());
    };
    let marked = [
        (&local, "keep"),
        (&local, "promisor"),
        (&structure, "promisor"),
    ]
    .iter()
    .all(|(name, suffix)| write_as(user, &join(&stage, &format!("{name}.{suffix}")), ""));
    let config = [
        ("core.repositoryformatversion", "1".to_string()),
        ("extensions.partialClone", partial.remote.clone()),
        (
            &format!("remote.{}.promisor", partial.remote),
            "true".into(),
        ),
        (
            &format!("remote.{}.partialclonefilter", partial.remote),
            "blob:none".into(),
        ),
    ];
    let configured = marked
        && config
            .iter()
            .all(|(key, value)| git(user, repo, &["config", key, value], None).is_some());
    let unconfigure = || {
        for (key, _) in &config[1..] {
            git(user, repo, &["config", "--unset", key], None);
        }
    };
    if !configured {
        unconfigure();
        crate::remove::remove_as(uid, gid, vec![stage]);
        return Err("could not mark the repository as a partial clone".into());
    }
    let mut moved: Vec<(String, String)> = Vec::new();
    let mut fresh: Vec<String> = Vec::new();
    let mut failed = false;
    for name in [&local, &structure] {
        for suffix in ["keep", "promisor", "pack", "rev", "idx"] {
            let from = join(&stage, &format!("{name}.{suffix}"));
            if !lexists(&from) {
                continue;
            }
            let to = join(&pack_dir, &format!("pack-{name}.{suffix}"));
            failed |= std::fs::rename(&from, &to).is_err();
            fresh.push(to);
        }
    }
    if !failed {
        for entry in list_dir(&pack_dir).unwrap_or_default() {
            let path = join(&pack_dir, &entry);
            if fresh.contains(&path) {
                continue;
            }
            let to = join(&old, &format!("pack.{entry}"));
            failed |= std::fs::rename(&path, &to).is_err();
            moved.push((path, to));
        }
        for entry in list_dir(&objects).unwrap_or_default() {
            if entry.len() == 2 && entry.bytes().all(|b| b.is_ascii_hexdigit()) {
                let path = join(&objects, &entry);
                let to = join(&old, &entry);
                failed |= std::fs::rename(&path, &to).is_err();
                moved.push((path, to));
            }
        }
    }
    let missing = |args: &[&str], input: &str| -> bool {
        let words = [
            &[
                "env",
                "GIT_NO_LAZY_FETCH=1",
                "git",
                "-C",
                repo,
                "rev-list",
                "--objects",
                "--missing=print",
                "--stdin",
            ][..],
            args,
        ]
        .concat();
        let output = run_as(user, &words, Some(input));
        !output.status.success() || stdout(&output).lines().any(|line| line.starts_with('?'))
    };
    let broken = failed
        || missing(
            &["--all", "--reflog", "--indexed-objects"],
            &(heads.clone() + &negated),
        )
        || missing(&["--all", "--reflog", "--filter=blob:none"], &heads);
    if broken {
        for (from, to) in moved.iter().rev() {
            let _ = std::fs::rename(to, from);
        }
        for path in &fresh {
            let _ = std::fs::remove_file(path);
        }
        unconfigure();
        crate::remove::remove_as(uid, gid, vec![stage]);
        return Err("the partial clone failed verification and was rolled back".into());
    }
    let outcome = crate::remove::remove_as(uid, gid, vec![stage]);
    if let Some((path, code)) = outcome.failed.first() {
        return Err(format!(
            "remove failed at {path}: {}",
            std::io::Error::from_raw_os_error(*code)
        ));
    }
    Ok(())
}

pub struct Game {
    pub store: &'static str,
    pub id: String,
    pub title: String,
    pub root: String,
    pub files: Vec<String>,
    pub played: i64,
    pub installed: i64,
    pub tool: bool,
}

const STEAM_TOOLS: [&str; 5] = [
    "Proton",
    "Steam Linux Runtime",
    "Steamworks Common",
    "SteamVR",
    "Steam.dll",
];
const STEAM_REDOWNLOADED: [&str; 2] = ["Proton", "Steam Linux Runtime"];

fn prefix_runs(apps: &str, played: &HashMap<String, i64>) -> Vec<(String, i64)> {
    list_sorted(&join(apps, "compatdata"))
        .into_iter()
        .filter_map(|id| {
            let prefix = join(apps, &format!("compatdata/{id}"));
            let tool = std::fs::read_to_string(join(&prefix, "config_info"))
                .ok()?
                .lines()
                .nth(1)?
                .to_string();
            let ran = match played.get(&id) {
                Some(at) => *at,
                None if played.is_empty() => sys::statx(&join(&prefix, "pfx/user.reg"))
                    .map(|info| info.mtime)
                    .unwrap_or(0),
                None => 0,
            };
            Some((tool, ran))
        })
        .collect()
}

fn steam_played(steam: &str) -> HashMap<String, i64> {
    let mut out: HashMap<String, i64> = HashMap::new();
    for user in list_sorted(&join(steam, "userdata")) {
        let Ok(text) = std::fs::read_to_string(join(
            steam,
            &format!("userdata/{user}/config/localconfig.vdf"),
        )) else {
            continue;
        };
        let mut app = String::new();
        for line in text.lines() {
            let trimmed = line.trim();
            if let Some(key) = trimmed
                .strip_prefix('"')
                .and_then(|rest| rest.strip_suffix('"'))
                .filter(|key| !key.contains('"'))
            {
                if !key.is_empty() && key.bytes().all(|byte| byte.is_ascii_digit()) {
                    app = key.to_string();
                }
                continue;
            }
            if let Some((_, value)) = vdf_pairs(line)
                .into_iter()
                .find(|(key, _)| key == "LastPlayed")
            {
                let at: i64 = value.parse().unwrap_or(0);
                if !app.is_empty() && at > 0 {
                    let entry = out.entry(app.clone()).or_insert(0);
                    *entry = (*entry).max(at);
                }
            }
        }
    }
    out
}

fn vdf_pairs(text: &str) -> Vec<(String, String)> {
    text.lines()
        .filter_map(|line| {
            let parts: Vec<&str> = line.split('"').collect();
            (parts.len() >= 5 && parts[2].trim().is_empty())
                .then(|| (parts[1].to_string(), parts[3].replace("\\\\", "\\")))
        })
        .collect()
}

fn iso_seconds(text: &str) -> i64 {
    let digits: Vec<i64> = text
        .split(|c: char| !c.is_ascii_digit())
        .filter(|part| !part.is_empty())
        .take(6)
        .filter_map(|part| part.parse().ok())
        .collect();
    let [year, month, day, hour, minute, second] = digits[..] else {
        return 0;
    };
    let (y, m) = if month <= 2 {
        (year - 1, month + 9)
    } else {
        (year, month - 3)
    };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * m + 2) / 5 + day - 1;
    let days = era * 146097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719468;
    days * 86400 + hour * 3600 + minute * 60 + second
}

pub fn launcher_running(store: &str) -> Option<&'static str> {
    let names = process_starts();
    match store {
        "steam" => names
            .keys()
            .any(|name| name == "steam" || name == "steamwebhelper")
            .then_some("Steam"),
        _ => names
            .keys()
            .any(|name| name.contains("heroic") || name == "legendary" || name == "gogdl")
            .then_some("Heroic"),
    }
}

pub fn born(path: &str) -> i64 {
    sys::statx(path)
        .filter(|info| info.mask & libc::STATX_BTIME != 0)
        .map(|info| info.btime)
        .unwrap_or(0)
}

pub fn games(home: &str, only: &str) -> Vec<Game> {
    let mut out = Vec::new();
    let steam = join(&home, ".local/share/Steam");
    let mut libraries = vec![steam.clone()];
    if let Ok(text) = std::fs::read_to_string(join(&steam, "steamapps/libraryfolders.vdf")) {
        libraries.extend(
            vdf_pairs(&text)
                .into_iter()
                .filter(|(key, _)| key == "path")
                .map(|(_, value)| value),
        );
    }
    libraries.sort();
    libraries.dedup();
    let steam_played = steam_played(&steam);
    for library in libraries {
        let apps = join(&library, "steamapps");
        let runs = prefix_runs(&apps, &steam_played);
        let mut tools: Vec<Game> = Vec::new();
        let mut latest = 0i64;
        for name in list_sorted(&apps) {
            let Some(id) = name
                .strip_prefix("appmanifest_")
                .and_then(|rest| rest.strip_suffix(".acf"))
            else {
                continue;
            };
            let manifest = join(&apps, &name);
            let Ok(text) = std::fs::read_to_string(&manifest) else {
                continue;
            };
            let fields: HashMap<String, String> = vdf_pairs(&text).into_iter().collect();
            let field = |key: &str| fields.get(key).cloned().unwrap_or_default();
            let (title, folder) = (field("name"), field("installdir"));
            let state: i64 = field("StateFlags").parse().unwrap_or(0);
            let tool = STEAM_TOOLS.iter().any(|tool| title.starts_with(tool));
            if folder.is_empty()
                || folder.contains('/')
                || folder == ".."
                || state & 4 == 0
                || (tool
                    && !STEAM_REDOWNLOADED
                        .iter()
                        .any(|kept| title.starts_with(kept)))
            {
                continue;
            }
            let root = join(&apps, &format!("common/{folder}"));
            if !is_dir(&root) || is_symlink(&root) || (!only.is_empty() && only != root) {
                continue;
            }
            let mut files = vec![root.clone(), manifest.clone()];
            files.extend(
                [
                    join(&apps, &format!("shadercache/{id}")),
                    join(&apps, &format!("downloading/{id}")),
                ]
                .into_iter()
                .filter(|path| lexists(path)),
            );
            let installed = [born(&root), born(&manifest)]
                .into_iter()
                .filter(|time| *time > 0)
                .min()
                .unwrap_or_else(|| field("LastUpdated").parse().unwrap_or(0));
            let played: i64 = field("LastPlayed")
                .parse::<i64>()
                .unwrap_or(0)
                .max(steam_played.get(id).copied().unwrap_or(0));
            let game = Game {
                store: "steam",
                id: id.to_string(),
                title,
                files,
                played,
                installed,
                tool,
                root,
            };
            if tool {
                tools.push(game);
            } else {
                latest = latest.max(played);
                out.push(game);
            }
        }
        latest = runs.iter().map(|(_, ran)| *ran).fold(latest, i64::max);
        for mut tool in tools {
            let within = format!("{}/", tool.root);
            let used = runs
                .iter()
                .filter(|(path, _)| path.starts_with(&within))
                .map(|(_, ran)| *ran)
                .max()
                .unwrap_or(0);
            tool.played = if tool.title.starts_with("Steam Linux Runtime") {
                latest
            } else {
                used
            };
            out.push(tool);
        }
    }
    let heroic = join(&home, ".config/heroic");
    let played: HashMap<String, i64> =
        std::fs::read_to_string(join(&heroic, "store/timestamp.json"))
            .ok()
            .and_then(|text| serde_json::from_str::<Map<String, Value>>(&text).ok())
            .map(|map| {
                map.into_iter()
                    .map(|(id, entry)| {
                        (
                            id,
                            entry
                                .get("lastPlayed")
                                .and_then(Value::as_str)
                                .map(iso_seconds)
                                .unwrap_or(0),
                        )
                    })
                    .collect()
            })
            .unwrap_or_default();
    let mut installs: Vec<(String, String, String)> = Vec::new();
    if let Some(map) =
        std::fs::read_to_string(join(&heroic, "legendaryConfig/legendary/installed.json"))
            .ok()
            .and_then(|text| serde_json::from_str::<Map<String, Value>>(&text).ok())
    {
        for (id, entry) in map {
            let text = |key: &str| {
                entry
                    .get(key)
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string()
            };
            installs.push((id, text("title"), text("install_path")));
        }
    }
    for store in ["gog_store", "nile_store"] {
        if let Some(list) =
            std::fs::read_to_string(join(&heroic, &format!("{store}/installed.json")))
                .ok()
                .and_then(|text| serde_json::from_str::<Value>(&text).ok())
                .and_then(|value| value.get("installed").and_then(Value::as_array).cloned())
        {
            for entry in list {
                let text = |key: &str| {
                    entry
                        .get(key)
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string()
                };
                installs.push((text("appName"), text("title"), text("install_path")));
            }
        }
    }
    let library = join(&home, "Games/Heroic");
    for (id, title, root) in installs {
        if id.is_empty()
            || !root.starts_with(&format!("{library}/"))
            || root.contains("/../")
            || root.starts_with(&format!("{library}/Prefixes"))
            || !is_dir(&root)
            || is_symlink(&root)
            || (!only.is_empty() && only != root)
        {
            continue;
        }
        let installed = born(&root);
        out.push(Game {
            store: "heroic",
            tool: false,
            played: played.get(&id).copied().unwrap_or(0),
            id,
            title: if title.is_empty() {
                basename(&root).to_string()
            } else {
                title
            },
            files: vec![root.clone()],
            root,
            installed,
        });
    }
    out
}

impl Model {
    fn trash_items(&self) -> Vec<Item> {
        let trash = join(&self.home, ".local/share/Trash");
        let bin = join(&trash, "files");
        list_sorted(&bin)
            .into_iter()
            .map(|name| {
                let path = join(&bin, &name);
                let record = join(&trash, &format!("info/{name}.trashinfo"));
                let deleted = if lexists(&record) {
                    lstat_time(&record)
                } else {
                    lstat_time(&path)
                };
                let origin = std::fs::read_to_string(&record)
                    .ok()
                    .and_then(|text| {
                        text.lines()
                            .find_map(|line| line.strip_prefix("Path=").map(percent_decoded))
                    })
                    .unwrap_or_default();
                Item::new(Kind::Trash, path.clone(), deleted)
                    .with_files(vec![path, record])
                    .with_detail(json!({"owner": self.user, "origin": origin}))
            })
            .collect()
    }

    fn emacs_items(&self, files: &dyn Files) -> Vec<Item> {
        EMACS_TEMP
            .iter()
            .map(|dir| join(&self.home, dir))
            .flat_map(|dir| {
                list_sorted(&dir)
                    .into_iter()
                    .map(move |name| join(&dir, &name))
            })
            .filter(|path| !is_symlink(path))
            .map(|path| {
                let used = files.used(&path).max(lstat_time(&path));
                Item::new(Kind::Temp, path.clone(), used)
                    .with_files(vec![path])
                    .with_detail(json!({"owner": self.user, "emacs": true}))
            })
            .collect()
    }

    fn download_items(&self, files: &dyn Files) -> Vec<Item> {
        let downloads = join(&self.home, "Downloads");
        list_sorted(&downloads)
            .into_iter()
            .map(|name| {
                let path = join(&downloads, &name);
                Item::new(Kind::Download, path.clone(), files.used(&path))
                    .with_files(vec![path])
                    .with_detail(json!({"owner": self.user}))
            })
            .collect()
    }

    fn game_items(&mut self) -> Vec<Item> {
        games(&self.home, "").into_iter().map(|game| {
            let used = (game.played.max(game.installed) as f64).max(0.0);
            Item::new(Kind::Game, game.root.clone(), used).with_files(game.files.clone()).with_detail(json!({"owner": self.user, "store": game.store, "id": game.id, "title": game.title, "played": game.played, "installed": game.installed, "tool": game.tool}))
        }).collect()
    }
}

fn percent_decoded(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        let escaped = (bytes[index] == b'%')
            .then(|| text.get(index + 1..index + 3))
            .flatten()
            .and_then(|hex| u8::from_str_radix(hex, 16).ok());
        match escaped {
            Some(byte) => {
                out.push(byte);
                index += 3;
            }
            None => {
                out.push(bytes[index]);
                index += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

pub fn forget_heroic(home: &str, id: &str, user: &str) -> Result<(), String> {
    let heroic = join(home, ".config/heroic");
    let legendary = join(&heroic, "legendaryConfig/legendary/installed.json");
    if let Some(mut map) = std::fs::read_to_string(&legendary)
        .ok()
        .and_then(|text| serde_json::from_str::<Map<String, Value>>(&text).ok())
    {
        if map.remove(id).is_some() {
            if !write_as(
                user,
                &legendary,
                &serde_json::to_string_pretty(&map).map_err(|error| error.to_string())?,
            ) {
                return Err("could not update legendary installed.json".into());
            }
        }
    }
    for store in ["gog_store", "nile_store"] {
        let path = join(&heroic, &format!("{store}/installed.json"));
        let Some(mut value) = std::fs::read_to_string(&path)
            .ok()
            .and_then(|text| serde_json::from_str::<Value>(&text).ok())
        else {
            continue;
        };
        let Some(list) = value.get_mut("installed").and_then(Value::as_array_mut) else {
            continue;
        };
        let before = list.len();
        list.retain(|entry| entry.get("appName").and_then(Value::as_str) != Some(id));
        if list.len() != before {
            if !write_as(
                user,
                &path,
                &serde_json::to_string_pretty(&value).map_err(|error| error.to_string())?,
            ) {
                return Err(format!("could not update {store}/installed.json"));
            }
        }
    }
    Ok(())
}
