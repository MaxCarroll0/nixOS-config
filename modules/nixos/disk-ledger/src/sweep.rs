// The deletion worker: one ranked item at a time, paced by a byte bucket, inside one gc session per sweep.

use crate::gc;
use crate::reclaim::{self, Kind, Scope, Work};
use crate::remove;
use crate::store;
use crate::sys;
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender};
use std::sync::Arc;
use std::time::Duration;

const BUCKET: f64 = (1u64 << 30) as f64;
const RATE: f64 = BUCKET / 1.5;
const IDLE: Duration = Duration::from_secs(2);
const SNAPSHOT_SECONDS: f64 = 5.0;

pub struct Task {
    pub work: Work,
    pub ordered: Vec<String>,
    pub references: HashMap<String, Vec<String>>,
    pub orphans: Vec<String>,
    pub scope: Scope,
    pub level: f64,
    pub round: u64,
}

pub enum Command {
    Item(Box<Task>),
    Close,
}

pub enum Event {
    Begun(String),
    Done(String, Value),
    Refused(String, String),
    Closed(Value),
}

struct Snapshot {
    at: f64,
    busy: HashSet<String>,
    sessions: Vec<reclaim::Session>,
    starts: HashMap<String, Vec<f64>>,
}

impl Snapshot {
    fn take(home: &str) -> Snapshot {
        Snapshot {
            at: sys::now(),
            busy: reclaim::busy_paths(),
            sessions: reclaim::live_sessions(home),
            starts: reclaim::process_starts(),
        }
    }
}

struct Worker {
    events: Sender<Event>,
    round: Arc<AtomicU64>,
    wake: i32,
    session: Option<Result<gc::Session, String>>,
    snapshot: Option<Snapshot>,
    tokens: f64,
    refilled: f64,
    boot: bool,
    started: f64,
    items: u64,
    claimed: u64,
    refusals: Vec<Value>,
    free: i64,
}

fn free() -> i64 {
    sys::statvfs("/").free as i64
}

fn generation(work: &Work) -> bool {
    let profile = work
        .detail
        .get("profile")
        .and_then(Value::as_str)
        .unwrap_or("");
    work.kind == Kind::Generation
        && profile.contains("/profiles/system")
        && profile.ends_with("/system")
}

impl Worker {
    fn send(&self, event: Event) {
        let _ = self.events.send(event);
        unsafe { libc::write(self.wake, b"s".as_ptr() as *const libc::c_void, 1) };
    }

    fn refuse(&mut self, work: &Work, reason: String) {
        self.refusals.push(json!({"at": sys::now() as i64, "path": work.path, "kind": work.kind.name(), "reason": reason}));
        self.send(Event::Refused(work.path.clone(), reason));
    }

    fn stale(&self, task: &Task) -> bool {
        task.round < self.round.load(Ordering::Acquire)
    }

    fn pace(&mut self, bytes: u64, level: f64) {
        let rate = RATE / (1.0 - level).max(0.05);
        let now = sys::now();
        self.tokens = (self.tokens + (now - self.refilled) * rate).min(BUCKET);
        self.refilled = now;
        if self.tokens < 0.0 {
            std::thread::sleep(Duration::from_secs_f64(-self.tokens / rate));
            self.tokens = 0.0;
            self.refilled = sys::now();
        }
        self.tokens -= bytes as f64;
    }

    fn files(&mut self, task: &Task) -> Result<(), String> {
        let work = &task.work;
        if work.files.is_empty() {
            return task
                .scope
                .refusal(work, &HashSet::new(), &[], &HashMap::new())
                .map_or(Ok(()), Err);
        }
        if self
            .snapshot
            .as_ref()
            .is_none_or(|snapshot| sys::now() - snapshot.at >= SNAPSHOT_SECONDS)
        {
            self.snapshot = Some(Snapshot::take(&task.scope.home));
        }
        let snapshot = self.snapshot.as_ref().expect("snapshot was just taken");
        task.scope
            .refusal(work, &snapshot.busy, &snapshot.sessions, &snapshot.starts)
            .map_or(Ok(()), Err)
    }

    fn remove_files(&self, task: &Task) -> Result<Option<u64>, String> {
        let work = &task.work;
        let scope = &task.scope;
        for link in &work.links {
            crate::ledger::record_root(link, &scope.user);
            let _ = std::fs::remove_file(link);
        }
        if work.kind == Kind::Game
            && work.detail.get("store").and_then(Value::as_str) == Some("heroic")
        {
            reclaim::forget_heroic(
                &scope.home,
                work.detail.get("id").and_then(Value::as_str).unwrap_or(""),
                &scope.user,
            )?;
        }
        if work.kind == Kind::Repo {
            return match reclaim::user_ids(&scope.user) {
                Some((uid, gid)) => {
                    reclaim::shrink_clone(&work.path, &scope.user, uid, gid).map(|_| None)
                }
                None => Err("unknown user".into()),
            };
        }
        if reclaim::truthy(work.detail.get("worktree").unwrap_or(&Value::Null)) {
            if let Some(repo) = work.detail.get("repo").and_then(Value::as_str) {
                reclaim::run_as(
                    &scope.user,
                    &[
                        "git", "-C", repo, "worktree", "remove", "--force", &work.path,
                    ],
                    None,
                );
            }
        }
        let owner = work
            .detail
            .get("owner")
            .and_then(Value::as_str)
            .unwrap_or(&scope.user);
        let paths: Vec<String> = work
            .files
            .iter()
            .filter(|path| reclaim::lexists(path))
            .cloned()
            .collect();
        if paths.is_empty() {
            return Ok(Some(0));
        }
        let ids = if owner == "root" {
            Some((0, 0))
        } else {
            reclaim::user_ids(owner)
        };
        let Some((uid, gid)) = ids else {
            return Err(format!("unknown user {owner}"));
        };
        let outcome = remove::remove_as(uid, gid, paths);
        match outcome.failed.first() {
            Some((path, code)) => Err(format!(
                "remove failed: {path}: {}",
                std::io::Error::from_raw_os_error(*code)
            )),
            None => Ok(Some(outcome.released)),
        }
    }

    fn store(&mut self, task: &Task) -> (HashSet<String>, Value) {
        if task.ordered.is_empty() {
            return (HashSet::new(), Value::Null);
        }
        if self.session.is_none() {
            self.session = Some(if std::env::var("LEDGER_NATIVE_GC").as_deref() == Ok("0") {
                Err("disabled".into())
            } else {
                gc::Session::open(&gc::Layout::system(), &task.orphans)
            });
        }
        match self.session.as_mut() {
            Some(Ok(session)) => {
                session.unroot(&task.work.links);
                let outcome = session.delete(&task.ordered, &task.references);
                let round = |seconds: f64| (seconds * 1e4).round() / 10.0;
                let detail = json!({"native": true, "deleted": outcome.deleted, "entries": outcome.entries, "links": outcome.links, "released": outcome.released, "causes": outcome.causes.iter().take(10).map(|(path, cause)| json!({"path": path, "cause": cause})).collect::<Vec<_>>(), "error": outcome.error, "ms": {"database": round(outcome.database), "unlink": round(outcome.unlinking)}});
                (outcome.refused, detail)
            }
            Some(Err(reason)) => {
                let reason = reason.clone();
                let refused = store::delete_fallback(&task.ordered, &task.references);
                (refused, json!({"native": false, "reason": reason}))
            }
            None => (HashSet::new(), Value::Null),
        }
    }

    fn item(&mut self, task: Task) {
        if self.items == 0 && self.refusals.is_empty() {
            self.started = sys::now();
            self.free = free();
        }
        let work = &task.work;
        if self.stale(&task) {
            return;
        }
        self.pace(work.freed, task.level);
        if self.stale(&task) {
            self.tokens += work.freed as f64;
            return;
        }
        if let Err(reason) = self.files(&task) {
            return self.refuse(work, reason);
        }
        self.send(Event::Begun(work.path.clone()));
        let started = sys::now();
        let files = match self.remove_files(&task) {
            Ok(released) => released,
            Err(reason) => return self.refuse(work, reason),
        };
        let (refused, collector) = self.store(&task);
        let released = files.map(|bytes| bytes + collector["released"].as_u64().unwrap_or(0));
        if !work.store.is_empty()
            && work.files.is_empty()
            && work.store.iter().all(|path| refused.contains(path))
        {
            let reason = collector["causes"][0]["cause"]
                .as_str()
                .unwrap_or("refused by the collector")
                .to_string();
            return self.refuse(work, reason);
        }
        self.boot |= generation(work);
        self.items += 1;
        self.claimed += work.freed;
        let round = |value: f64| (value * 1e4).round() / 10.0;
        self.send(Event::Done(
            work.path.clone(),
            json!({"path": work.path, "kind": work.kind.name(), "freed": work.freed, "released": released, "last_used": work.last_used, "refused": refused.len(), "ms": round(sys::now() - started), "collector": collector}),
        ));
    }

    fn close(&mut self) {
        let report = match self.session.take() {
            Some(Ok(session)) => {
                let report = &session.report;
                json!({"native": true, "deleted": report.deleted, "entries": report.entries, "links": report.links, "ms": report.milliseconds()})
            }
            Some(Err(reason)) => json!({"native": false, "reason": reason}),
            None => Value::Null,
        };
        let mut status = 0;
        if std::mem::take(&mut self.boot) {
            status = match std::process::Command::new(
                "/nix/var/nix/profiles/system/bin/switch-to-configuration",
            )
            .arg("boot")
            .output()
            {
                Ok(result) => result.status.code().unwrap_or(-1),
                Err(_) => -1,
            };
        }
        self.snapshot = None;
        if self.items == 0 && self.refusals.is_empty() {
            return;
        }
        let round = |value: f64| (value * 100.0).round() / 100.0;
        let summary = json!({
            "at": self.started as i64,
            "ended": sys::now(),
            "stage": "sweep",
            "status": status,
            "items": self.items,
            "claimed": self.claimed,
            "freed": free() - self.free,
            "refused": self.refusals.len(),
            "refusals": std::mem::take(&mut self.refusals).into_iter().take(50).collect::<Vec<_>>(),
            "seconds": round(sys::now() - self.started),
            "collector": report,
        });
        self.items = 0;
        self.claimed = 0;
        self.send(Event::Closed(summary));
    }
}

pub fn run(commands: Receiver<Command>, events: Sender<Event>, wake: i32, round: Arc<AtomicU64>) {
    let mut worker = Worker {
        events,
        round,
        wake,
        session: None,
        snapshot: None,
        tokens: BUCKET,
        refilled: sys::now(),
        boot: false,
        started: 0.0,
        items: 0,
        claimed: 0,
        refusals: Vec::new(),
        free: 0,
    };
    loop {
        let open = worker.session.is_some() || worker.items > 0 || !worker.refusals.is_empty();
        let command = if open {
            commands.recv_timeout(IDLE)
        } else {
            commands.recv().map_err(|_| RecvTimeoutError::Disconnected)
        };
        match command {
            Ok(Command::Item(task)) => worker.item(*task),
            Ok(Command::Close) | Err(RecvTimeoutError::Timeout) => worker.close(),
            Err(RecvTimeoutError::Disconnected) => return worker.close(),
        }
    }
}
