// The ledger daemon: every used byte of the root filesystem in one segment, served live, reclaimed in one ranked order.

use crate::gc;
use crate::probe::{self, family, short, Held};
use crate::reclaim::{self, basename, dirname, Files, Item, Kind, Model, Work};
use crate::store::{self, Store};
use crate::sweep;
use crate::sys;
use crate::tree::clock;
use crate::tree::{self, Opens, Resolver, Tree};
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet, VecDeque};
use std::hash::{Hash, Hasher};
use std::io::{Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::io::AsRawFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, RwLock};
use std::time::Duration;

const GIB: i64 = 1 << 30;
const MIB: i64 = 1 << 20;
const DAY: i64 = 86400;
const PROBE_SECONDS: f64 = 10.0;
const MARGIN: i64 = 512 * MIB;
const RAMP: i64 = 4 * GIB;
const HISTORY_SECONDS: i64 = 900;
const HISTORY_LATE_SECONDS: i64 = 120;
const HISTORY_DAYS: i64 = 30;
const HISTORY_POINTS: usize = 288;
const HISTORY_ITEMS: usize = 40;
const PUSH_SECONDS: f64 = 0.1;
const FILE_SECONDS: f64 = 5.0;
const DB_SECONDS: f64 = 0.1;
const FRAME: f64 = 0.016;
const LOOKAHEAD: usize = 32;
const ROOTS_SECONDS: f64 = 300.0;
const MODEL_SECONDS: f64 = 300.0;
const MODEL_FLOOR: f64 = 1.0;
const SUMS_FLOOR: f64 = 0.5;
const FILES_FLOOR: f64 = 1.0;
const STORE_SETTLE: f64 = 1.0;
const LINKS_FLOOR: f64 = 5.0;
const HELD_SECONDS: f64 = 600.0;
const HELD_FLOOR: f64 = 5.0;
const INTERNALS_SECONDS: f64 = 3600.0;
const VERIFY_SECONDS: f64 = 0.001;
const IDLE_SETTLE: f64 = 30.0;
const IDLE_PUSH: f64 = 30.0;
const IDLE_FILES: f64 = 60.0;
const VERIFY_PERIOD: f64 = 10.0;
const LAGGING_SECONDS: f64 = 600.0;
const RENDER_SECONDS: f64 = 5.0;
const IDLE_WRITE: f64 = 60.0;
const TARGET_SECONDS: f64 = 60.0;
const CATCH_UP: f64 = 0.25;
const COST_FACTOR: f64 = 20.0;
const SKIP_SECONDS: f64 = 600.0;
const PLAN_SECONDS: f64 = 5.0;
const SLOW_STEP: f64 = 0.01;
const DRAIN_PAUSE: f64 = 0.02;
const ROWS: usize = 400;
const EVENTS: usize = 10000;
const EVENTS_DUMPED: usize = 40;
const EVENTS_READ: usize = 4000;
const WATCHES: usize = 16;
const SWEPT: usize = 40;

pub const SEGMENTS: [(&str, &str, &str, bool); 22] = [
    ("running_system", "running system", "live", false),
    ("home_profile", "profiles", "live", false),
    ("processes", "in use", "live", false),
    ("recent", "registered, roots pending", "live", false),
    ("building", "being built", "nix", false),
    ("metadata", "nix metadata", "nix", false),
    ("dead", "dead store paths", "reclaim", true),
    ("cache", "caches", "reclaim", true),
    ("temp", "temp files", "reclaim", true),
    ("stale_shell", "stale shells", "reclaim", true),
    ("stray", "other gc roots", "reclaim", true),
    ("build", "build outputs", "reclaim", true),
    ("project", "project closures", "reclaim", true),
    ("generation", "generations", "reclaim", true),
    ("agent", "agent work", "reclaim", true),
    ("trash", "recycle bin", "reclaim", true),
    ("home_files", "home files", "files", true),
    ("system_files", "system files", "files", false),
    ("swap", "swapfile", "system", false),
    ("held", "deleted, still open", "system", false),
    ("filesystem", "filesystem internals", "system", false),
    ("reserved", "ext4 root reserve", "system", false),
];

const OLD_KEYS: [(&str, &str); 13] = [
    ("system", "running_system"),
    ("home", "home_profile"),
    ("system_generations", "generation"),
    ("home_generations", "generation"),
    ("project_tier1", "project"),
    ("project_tier2", "project"),
    ("fetched", "project"),
    ("deployed", "stray"),
    ("shells", "processes"),
    ("other", "stray"),
    ("garbage", "dead"),
    ("building", "building"),
    ("metadata", "metadata"),
];

fn class_text(class: &str) -> Option<&'static str> {
    Some(match class {
        "running_system" => "running system",
        "home_profile" => "home profile",
        "profiles" => "current profile",
        "previous" => "kept for rollback",
        "shells" => "live shell",
        "processes" => "in use",
        "tmp_roots" => "temp gc root",
        "roots" => "gc root",
        _ => return None,
    })
}

fn folded(key: &str) -> Vec<&str> {
    match key {
        "stray" => vec!["stray", "deploy"],
        "home_files" => vec!["repo", "game"],
        _ => vec![key],
    }
}

fn internal_text(label: &str) -> &'static str {
    match label {
        "orphan file" => "ext4 orphan_file inode: preallocated list of deleted but still open files, replayed after a crash",
        "user quota" | "group quota" => "ext4 quota inode",
        "resize index" => "ext4 resize inode beyond the reserved GDT blocks",
        "journal index" => "ext4 journal inode blocks beyond the journal itself",
        _ => "ext4 internal inode",
    }
}

fn seq_of(event: &Value) -> u64 {
    event.get("seq").and_then(Value::as_u64).unwrap_or(0)
}

fn summary(mut event: Map<String, Value>, seq: u64) -> Value {
    let taken = event.remove("taken");
    let mut top: Vec<(String, i64)> = taken
        .as_ref()
        .and_then(Value::as_object)
        .into_iter()
        .flatten()
        .map(|(path, size)| (path.clone(), number(Some(size))))
        .collect();
    top.sort_by(|a, b| b.1.cmp(&a.1));
    top.truncate(3);
    event.remove("refusals");
    event.insert("seq".into(), json!(seq));
    event.insert("top".into(), json!(top));
    Value::Object(event)
}

fn old_stage(stage: &str) -> Option<&'static str> {
    Some(match stage {
        "scratch" => "cache",
        "projects" => "project",
        "store" => "dead",
        _ => return None,
    })
}

fn env(name: &str) -> String {
    std::env::var(name).unwrap_or_default()
}

fn plain(value: Option<&Value>) -> String {
    match value {
        None | Some(Value::Null) => "None".into(),
        Some(Value::String(text)) => text.clone(),
        Some(other) => other.to_string(),
    }
}

pub fn rebuild_text(seconds: i64) -> String {
    if seconds < 60 {
        return String::new();
    }
    if seconds < 3600 {
        return format!(
            ", rebuild est. ~{} min",
            (seconds as f64 / 60.0).round_ties_even() as i64
        );
    }
    format!(", rebuild est. ~{:.1} h", seconds as f64 / 3600.0)
}

fn downsample(points: &[Value]) -> Vec<Value> {
    if points.len() <= HISTORY_POINTS {
        return points.to_vec();
    }
    let step = points.len() as f64 / HISTORY_POINTS as f64;
    let mut out: Vec<Value> = (0..HISTORY_POINTS)
        .map(|index| points[(index as f64 * step) as usize].clone())
        .collect();
    out.push(points[points.len() - 1].clone());
    out
}

fn number(value: Option<&Value>) -> i64 {
    match value {
        Some(Value::Number(found)) => found
            .as_i64()
            .unwrap_or_else(|| found.as_f64().unwrap_or(0.0) as i64),
        _ => 0,
    }
}

fn migrate(point: Value, total: i64) -> Option<Value> {
    if point.get("v").and_then(Value::as_i64) == Some(2) {
        let mut point = point;
        if let Some(segments) = point.get_mut("segments").and_then(Value::as_object_mut) {
            if let Some(live) = segments.remove("tmp_files") {
                let current = number(segments.get("temp"));
                segments.insert("temp".into(), json!(current + number(Some(&live))));
            }
            if let Some(kept) = segments.remove("previous") {
                let current = number(segments.get("generation"));
                segments.insert("generation".into(), json!(current + number(Some(&kept))));
            }
            for (old, new) in [
                ("profiles", "home_profile"),
                ("shells", "processes"),
                ("agent_files", "agent"),
                ("deploy", "stray"),
                ("roots", "stray"),
                ("repo", "home_files"),
                ("game", "home_files"),
            ] {
                if let Some(moved) = segments.remove(old) {
                    let current = number(segments.get(new));
                    segments.insert(new.into(), json!(current + number(Some(&moved))));
                }
            }
            if let Some(loose) = segments.remove("changing") {
                let current = number(segments.get("filesystem"));
                segments.insert("filesystem".into(), json!(current + number(Some(&loose))));
            }
        }
        return Some(point);
    }
    let empty = Map::new();
    let pick = |key: &str| {
        point
            .get(key)
            .and_then(Value::as_object)
            .filter(|map| !map.is_empty())
    };
    let stored = pick("store_disk")
        .or_else(|| pick("store"))
        .unwrap_or(&empty);
    let mut segments: Map<String, Value> = Map::new();
    let add = |segments: &mut Map<String, Value>, key: &str, value: i64| {
        let current = segments.get(key).and_then(Value::as_i64).unwrap_or(0);
        segments.insert(key.to_string(), json!(current + value));
    };
    for (key, value) in stored {
        if let Some((_, target)) = OLD_KEYS.iter().find(|(old, _)| old == key) {
            add(&mut segments, target, number(Some(value)));
        }
    }
    let loose = number(stored.get("rescan"))
        + number(point.get("measuring")).max(0)
        + number(point.get("unaccounted"));
    if loose.abs() >= 64 * MIB || point.get("swap").is_none() || point.get("reserved").is_none() {
        return None;
    }
    add(&mut segments, "filesystem", loose.max(0));
    if let Some(files) = point.get("files").and_then(Value::as_object) {
        add(&mut segments, "home_files", number(files.get("home")));
        add(&mut segments, "cache", number(files.get("caches")));
    }
    for (key, source) in [
        ("swap", "swap"),
        ("system_files", "system"),
        ("held", "held"),
        ("reserved", "reserved"),
    ] {
        add(&mut segments, key, number(point.get(source)));
    }
    let free = number(point.get("free"));
    let closes: i64 = segments
        .values()
        .map(|value| value.as_i64().unwrap_or(0))
        .sum::<i64>()
        + free;
    if (closes - total).abs() > 64 * MIB {
        return None;
    }
    Some(
        json!({"v": 2, "at": point.get("at").cloned().unwrap_or(json!(0)), "segments": segments, "free": free, "total": total, "migrated": true}),
    )
}

fn digest(text: &str) -> u64 {
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    text.hash(&mut hasher);
    hasher.finish()
}

fn row(
    id: String,
    label: String,
    path: String,
    size: i64,
    last_used: i64,
    kind: String,
    reclaimable: bool,
    scheduled: bool,
    delvable: bool,
    openable: bool,
) -> Map<String, Value> {
    probe::object(
        json!({"id": id, "label": label, "path": path, "size": size, "last_used": last_used, "kind": kind, "reclaimable": reclaimable, "scheduled": scheduled, "delvable": delvable, "openable": openable}),
    )
}

fn missing() -> Vec<Map<String, Value>> {
    vec![probe::object(json!({"missing": true}))]
}

struct TreeFiles<'a>(&'a Tree);

impl Files for TreeFiles<'_> {
    fn size(&self, path: &str) -> u64 {
        self.0.size(path)
    }

    fn used(&self, path: &str) -> f64 {
        self.0.newest(path) as f64
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
enum Owner {
    Claim(u32),
    Item(u32),
}

#[derive(Clone, PartialEq)]
struct Watch {
    id: String,
    slots: usize,
    total: i64,
}

impl Watch {
    fn parse(entry: &Value) -> Watch {
        match entry {
            Value::String(id) => Watch {
                id: id.clone(),
                slots: 0,
                total: 0,
            },
            Value::Object(fields) => Watch {
                id: fields
                    .get("id")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string(),
                slots: fields
                    .get("slots")
                    .and_then(Value::as_u64)
                    .unwrap_or(0)
                    .min(4096) as usize,
                total: fields.get("total").and_then(Value::as_f64).unwrap_or(0.0) as i64,
            },
            other => Watch {
                id: other.to_string(),
                slots: 0,
                total: 0,
            },
        }
    }

    fn key(&self) -> String {
        if self.slots == 0 {
            self.id.clone()
        } else {
            format!("{}#{}#{}", self.id, self.slots, self.total)
        }
    }
}

struct Client {
    stream: UnixStream,
    buffer: Vec<u8>,
    watches: Vec<Watch>,
    sent: HashMap<String, u64>,
    events_upto: Option<u64>,
}

struct Statfs {
    total: i64,
    used: i64,
    free: i64,
    reserved: i64,
}

fn statfs() -> Statfs {
    let info = sys::statvfs("/");
    Statfs {
        total: info.total as i64,
        used: info.used as i64,
        free: info.free as i64,
        reserved: info.reserved as i64,
    }
}

pub struct Ledger {
    state: PathBuf,
    home: String,
    owner: u32,
    runtime: PathBuf,
    textfile: PathBuf,
    server: UnixListener,
    floor: i64,
    target_file: String,
    emergency: i64,
    collecting: bool,
    planning: bool,
    skipped: HashMap<String, f64>,
    planned_at: f64,
    store: Store,
    registered: Arc<RwLock<HashSet<String>>>,
    handover: Vec<(String, bool)>,
    tree: Tree,
    resolver: Option<Resolver>,
    opens: Option<Opens>,
    device: u64,
    source: String,
    model: Model,
    model_version: u64,
    scheduled_cache: Option<(u64, i64, HashMap<&'static str, i64>, i64)>,
    spans_cache: std::cell::RefCell<Option<(f64, u64, Value)>>,
    settled: std::cell::RefCell<HashMap<String, i64>>,
    agent_titles: HashMap<String, (u64, String, String)>,
    file_cache: Option<(u64, HashMap<&'static str, i64>, HashMap<String, i64>)>,
    model_cost: f64,
    by_path: HashMap<String, usize>,
    kind_items: HashMap<&'static str, Vec<usize>>,
    claim_of: HashMap<u32, Owner>,
    claim_sets: HashMap<Owner, Rc<HashSet<u32>>>,
    startup_seconds: f64,
    laps: Vec<(&'static str, f64)>,
    slow: VecDeque<(i64, &'static str, f64, f64)>,
    latencies: VecDeque<f64>,
    drained_at: f64,
    clients: HashMap<i32, Client>,
    wake_read: i32,
    exits: HashMap<i32, i32>,
    commands: Sender<sweep::Command>,
    sweep_events: Receiver<sweep::Event>,
    swept: VecDeque<Value>,
    handed: Vec<String>,
    session_open: bool,
    close_sent: bool,
    cursor: (u64, usize),
    ranking: u64,
    cut_at: f64,
    unlabelled: bool,
    level: f64,
    status: Map<String, Value>,
    last_event: Value,
    lagging: HashMap<String, (f64, u64)>,
    batch: u64,
    store_dirty: HashMap<String, f64>,
    links_dirty: Option<f64>,
    scanning: Option<std::thread::JoinHandle<gc::LinkScan>>,
    links_file: String,
    links_cost: f64,
    db_checked: f64,
    roots_at: f64,
    roots_due: Option<f64>,
    roots_cost: f64,
    model_at: f64,
    model_dirty: bool,
    sums_dirty: bool,
    sums_at: f64,
    sums_cost: f64,
    sums: HashMap<&'static str, i64>,
    files_at: f64,
    files_cost: f64,
    files_total: Option<u64>,
    verified_at: f64,
    held: Vec<Held>,
    held_at: f64,
    held_residual: i64,
    dirty_target: &'static str,
    settled_residual: i64,
    internals: Vec<(String, u64)>,
    internals_at: f64,
    xattr: HashMap<String, u64>,
    xattr_dirs: Option<Vec<String>>,
    xattr_at: f64,
    mounts: Vec<String>,
    probed: f64,
    swap: i64,
    overview: Value,
    overview_text: String,
    rendered: HashMap<String, (f64, [u64; 6], Rc<(String, u64)>)>,
    recorded: u64,
    collected_at: f64,
    cut_rank: i64,
    next_rank: i64,
    planned: Vec<bool>,
    deleting: HashSet<String>,
    pushed: f64,
    frame_due: bool,
    pushed_revision: u64,
    written_at: f64,
    history_path: PathBuf,
    points: Vec<Value>,
    history_items: Value,
    history_paths: HashSet<String>,
    history_text: Option<String>,
    events: Vec<Value>,
    event_offsets: Vec<u64>,
    next_seq: u64,
    events_text: Option<String>,
    target_mtime: Option<i128>,
    target_bytes: i64,
    target_at: f64,
    viewed: std::cell::Cell<bool>,
}

struct Laps {
    at: f64,
    list: Vec<(&'static str, f64)>,
}

impl Laps {
    fn lap(&mut self, name: &'static str) {
        let now = clock();
        self.list.push((name, now - self.at));
        self.at = now;
    }
}

fn timed(function: impl FnOnce()) -> f64 {
    let started = clock();
    function();
    clock() - started
}

impl Ledger {
    pub fn new() -> std::io::Result<Ledger> {
        unsafe { tzset() };
        let state = PathBuf::from(env("LEDGER_STATE_DIR"));
        std::fs::create_dir_all(&state)?;
        let home = env("LEDGER_HOME");
        let user = env("LEDGER_USER");
        let owner: u32 = env("LEDGER_UID").parse().unwrap_or(1000);
        let runtime = PathBuf::from(env("LEDGER_RUNTIME_DIR"));
        let server = listen(&runtime, owner)?;
        let started = clock();
        let mut laps = Laps {
            at: started,
            list: Vec::new(),
        };
        let cache = std::env::var("STORE_INDEX_CACHE").unwrap_or_else(|_| {
            state
                .join("store-index.sqlite")
                .to_string_lossy()
                .into_owned()
        });
        let registered: Arc<RwLock<HashSet<String>>> = Arc::new(RwLock::new(HashSet::new()));
        let known = Arc::new(AtomicBool::new(false));
        let (seen, ready) = (registered.clone(), known.clone());
        let skip: tree::Skip = Arc::new(move |parent: &str, name: &str| {
            parent == "/nix/store"
                && (name == ".links"
                    || !ready.load(Ordering::Acquire)
                    || seen
                        .read()
                        .unwrap_or_else(|poisoned| poisoned.into_inner())
                        .contains(name))
        });
        let links_file = state.join("links.idx").to_string_lossy().into_owned();
        let scanning = scan_links(links_file.clone());
        let (tree, mut index, walked) = std::thread::scope(|scope| {
            let walker = scope.spawn(move || {
                let started = clock();
                Tree::new("/", skip).map(|tree| (tree, clock() - started))
            });
            let mut index = Store::new(&cache);
            index.load();
            laps.lap("store_load");
            index.refresh_roots();
            laps.lap("roots");
            index.walk_pending(std::time::Instant::now() + Duration::from_secs(1 << 30));
            laps.lap("store_walk");
            let walked = walker
                .join()
                .unwrap_or_else(|_| Err(std::io::Error::other("tree walk panicked")));
            laps.lap("tree_wait");
            walked.map(|(tree, seconds)| (tree, index, seconds))
        })?;
        laps.list.push(("tree_walk", walked));
        let mut tree = tree;
        *registered
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = index
            .alive_slots()
            .map(|slot| index.get(slot).path["/nix/store/".len()..].to_string())
            .collect();
        known.store(true, Ordering::Release);
        index.journal.clear();
        if let Some(id) = tree.find("/nix/store") {
            let new = tree.scan(id);
            tree.walk(new);
        }
        laps.lap("store_dir");
        let resolver = Resolver::new("/");
        let opens = Opens::new("/nix/store", 600.0).ok();
        let device = sys::lstat("/").map(|info| info.dev).unwrap_or(0);
        let source = probe::root_source("/");
        let offload = Some(env("LEDGER_OFFLOAD_DIR")).filter(|dir| !dir.is_empty());
        let mut builds = reclaim::BuildTimes::new(Some(
            state
                .join("build-times.json")
                .to_string_lossy()
                .into_owned(),
        ));
        builds.watch();
        let model = Model::new(&home, &user, offload, builds);
        let mut pipe = [0i32; 2];
        unsafe { libc::pipe2(pipe.as_mut_ptr(), libc::O_NONBLOCK | libc::O_CLOEXEC) };
        let (commands, orders) = channel();
        let (reporter, sweep_events) = channel();
        let wake = pipe[1];
        std::thread::spawn(move || sweep::run(orders, reporter, wake));
        let floor = env("LEDGER_TARGET_BYTES").parse().unwrap_or(20 * GIB);
        let internals = probe::hidden_inodes(&source);
        laps.lap("probes");
        let mut ledger = Ledger {
            history_path: state.join("history.jsonl"),
            state,
            home,
            owner,
            runtime,
            textfile: PathBuf::from(env("LEDGER_TEXTFILE")),
            server,
            floor,
            target_file: env("LEDGER_TARGET_FILE"),
            emergency: env("LEDGER_EMERGENCY_BYTES").parse().unwrap_or(5 * GIB),
            collecting: env("LEDGER_COLLECT") == "1",
            planning: env("LEDGER_COLLECT") == "plan",
            skipped: HashMap::new(),
            planned_at: 0.0,
            store: index,
            registered,
            handover: Vec::new(),
            tree,
            resolver,
            opens,
            device,
            source,
            model,
            model_version: 0,
            scheduled_cache: None,
            spans_cache: std::cell::RefCell::new(None),
            settled: std::cell::RefCell::new(HashMap::new()),
            agent_titles: HashMap::new(),
            file_cache: None,
            model_cost: 0.0,
            by_path: HashMap::new(),
            kind_items: HashMap::new(),
            claim_of: HashMap::new(),
            claim_sets: HashMap::new(),
            startup_seconds: 0.0,
            laps: Vec::new(),
            slow: VecDeque::new(),
            latencies: VecDeque::new(),
            drained_at: 0.0,
            clients: HashMap::new(),
            wake_read: pipe[0],
            exits: HashMap::new(),
            commands,
            sweep_events,
            swept: VecDeque::new(),
            handed: Vec::new(),
            session_open: false,
            close_sent: false,
            cursor: (0, 0),
            ranking: 0,
            cut_at: f64::NEG_INFINITY,
            unlabelled: false,
            level: 0.0,
            status: probe::object(json!({"state": "idle"})),
            last_event: Value::Null,
            lagging: HashMap::new(),
            batch: 0,
            store_dirty: HashMap::new(),
            links_dirty: None,
            scanning: Some(scanning),
            links_file,
            links_cost: 0.0,
            db_checked: 0.0,
            roots_at: clock(),
            roots_due: None,
            roots_cost: 0.0,
            model_at: clock(),
            model_dirty: false,
            sums_dirty: true,
            sums_at: 0.0,
            sums_cost: 0.0,
            sums: HashMap::new(),
            files_at: 0.0,
            files_cost: 0.0,
            files_total: None,
            verified_at: 0.0,
            held: Vec::new(),
            held_at: -HELD_SECONDS,
            held_residual: 0,
            dirty_target: "system_files",
            settled_residual: 0,
            internals,
            internals_at: clock(),
            xattr: HashMap::new(),
            xattr_dirs: None,
            xattr_at: -INTERNALS_SECONDS,
            mounts: Vec::new(),
            probed: f64::NEG_INFINITY,
            swap: 0,
            overview: Value::Null,
            overview_text: String::new(),
            rendered: HashMap::new(),
            recorded: 0,
            collected_at: f64::NEG_INFINITY,
            cut_rank: -1,
            next_rank: -1,
            planned: Vec::new(),
            deleting: HashSet::new(),
            pushed: 0.0,
            frame_due: false,
            pushed_revision: 0,
            written_at: 0.0,
            points: Vec::new(),
            history_items: json!({}),
            history_paths: HashSet::new(),
            history_text: None,
            events: Vec::new(),
            event_offsets: Vec::new(),
            next_seq: 0,
            events_text: None,
            target_mtime: None,
            target_bytes: floor,
            target_at: f64::NEG_INFINITY,
            viewed: std::cell::Cell::new(false),
        };
        ledger.tree.compact();
        ledger.store.compact();
        laps.lap("compact");
        ledger.refresh_model();
        laps.lap("model");
        ledger.startup_seconds = clock() - started;
        eprintln!(
            "startup {:.3}s {}",
            ledger.startup_seconds,
            laps.list
                .iter()
                .map(|(name, seconds)| format!("{name} {seconds:.3}"))
                .collect::<Vec<_>>()
                .join(", ")
        );
        ledger.laps = laps.list;
        ledger.points = ledger.load_history();
        ledger.load_events();
        Ok(ledger)
    }

    fn worktrees(&self) -> Vec<String> {
        let mut found = Vec::new();
        for id in &self.tree.named {
            let node = self.tree.node(*id);
            if !node.attached {
                continue;
            }
            if &*node.name != ".claude" {
                continue;
            }
            if let Some(holder) = self.tree.child(*id, "worktrees") {
                found.extend(
                    self.tree
                        .node(holder)
                        .children
                        .iter()
                        .map(|child| self.tree.path(*child)),
                );
            }
        }
        found.sort();
        found
    }

    fn repos(&self) -> Vec<String> {
        let mut found: Vec<String> = self
            .tree
            .named
            .iter()
            .map(|id| self.tree.node(*id))
            .filter(|node| node.attached && &*node.name == ".git")
            .map(|node| self.tree.path(node.parent))
            .filter(|repo| reclaim::clone_candidate(&self.home, repo))
            .collect();
        found.sort();
        found
    }

    fn refresh_model(&mut self) {
        let worktrees = self.worktrees();
        let repos = self.repos();
        let now = sys::now() as i64;
        let started = clock();
        self.model.refresh(
            &mut self.store,
            &TreeFiles(&self.tree),
            &worktrees,
            &repos,
            now,
        );
        self.model_cost = clock() - started;
        self.index_items();
        unsafe { libc::malloc_trim(0) };
    }

    fn index_items(&mut self) {
        self.by_path.clear();
        self.kind_items.clear();
        self.claim_of.clear();
        for (index, item) in self.model.items.iter().enumerate() {
            self.by_path.insert(item.path.clone(), index);
            self.kind_items
                .entry(item.kind.key())
                .or_default()
                .push(index);
        }
        for (index, claim) in self.model.claims.iter().enumerate() {
            for slot in &claim.found {
                self.claim_of.insert(*slot, Owner::Claim(index as u32));
            }
        }
        for (index, item) in self.model.items.iter().enumerate() {
            for slot in &item.store {
                self.claim_of.insert(*slot, Owner::Item(index as u32));
            }
        }
        self.by_path.shrink_to_fit();
        let now = clock();
        let by_path = &self.by_path;
        self.lagging.retain(|path, (since, _)| {
            by_path.contains_key(path) && now - *since < LAGGING_SECONDS
        });
        self.claim_of.shrink_to_fit();
        self.claim_sets.clear();
        self.sums_dirty = true;
        self.model_version += 1;
        self.ranking += 1;
    }

    fn target(&mut self) -> i64 {
        if !self.target_file.is_empty() && clock() - self.target_at >= TARGET_SECONDS {
            self.target_at = clock();
            match std::fs::metadata(&self.target_file) {
                Ok(info) => {
                    use std::os::unix::fs::MetadataExt;
                    let mtime = info.mtime() as i128 * 1_000_000_000 + info.mtime_nsec() as i128;
                    if Some(mtime) != self.target_mtime {
                        self.target_mtime = Some(mtime);
                        match std::fs::read_to_string(&self.target_file)
                            .ok()
                            .and_then(|text| text.trim().parse::<f64>().ok())
                        {
                            Some(value) => self.target_bytes = (value * GIB as f64) as i64,
                            None => self.target_bytes = self.floor,
                        }
                    }
                }
                Err(_) => self.target_bytes = self.floor,
            }
        }
        self.target_bytes
    }

    fn load_history(&self) -> Vec<Value> {
        let total = statfs().total;
        let now = sys::now();
        let mut points = Vec::new();
        let mut changed = false;
        if let Ok(text) = std::fs::read_to_string(&self.history_path) {
            for line in text.lines() {
                let Ok(point) = serde_json::from_str::<Value>(line) else {
                    changed = true;
                    continue;
                };
                if (number(point.get("at")) as f64) < now - (HISTORY_DAYS * DAY) as f64 {
                    changed = true;
                    continue;
                }
                let current = point.get("v").and_then(Value::as_i64) == Some(2);
                if !current {
                    changed = true;
                }
                if let Some(migrated) = migrate(point, total) {
                    points.push(migrated);
                }
            }
        }
        if changed {
            self.save_history(&points);
        }
        points
    }

    fn save_history(&self, points: &[Value]) {
        let text: String = points.iter().map(|point| format!("{}\n", point)).collect();
        let _ = probe::write_file(&self.history_path, &text, None);
    }

    fn load_events(&mut self) {
        let Ok(bytes) = std::fs::read(self.state.join("events.jsonl")) else {
            return;
        };
        let mut lines = Vec::new();
        let mut offset = 0u64;
        for line in bytes.split(|byte| *byte == b'\n') {
            if !line.is_empty() {
                lines.push((offset, line));
            }
            offset += line.len() as u64 + 1;
        }
        let skip = lines.len().saturating_sub(EVENTS);
        for (seq, (offset, line)) in lines.into_iter().enumerate().skip(skip) {
            let Ok(Value::Object(mut event)) = serde_json::from_slice::<Value>(line) else {
                continue;
            };
            if !event.contains_key("segment") {
                let stage = event.get("stage").and_then(Value::as_str).unwrap_or("");
                let segment = old_stage(stage)
                    .or_else(|| {
                        Kind::from_name(stage)
                            .filter(|kind| kind.name() == stage)
                            .map(Kind::key)
                    })
                    .unwrap_or("dead");
                event.insert("segment".into(), json!(segment));
            }
            self.events.push(summary(event, seq as u64));
            self.event_offsets.push(offset);
            self.next_seq = seq as u64 + 1;
        }
    }

    fn record(&mut self, event: Value) {
        let path = self.state.join("events.jsonl");
        if let Ok(mut handle) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
        {
            let offset = handle.metadata().map(|meta| meta.len()).unwrap_or(0);
            if writeln!(handle, "{}", event).is_ok() {
                if let Value::Object(fields) = event.clone() {
                    self.events.push(summary(fields, self.next_seq));
                    self.event_offsets.push(offset);
                    self.next_seq += 1;
                }
            }
        }
        let excess = self.events.len().saturating_sub(EVENTS);
        self.events.drain(..excess);
        self.event_offsets.drain(..excess);
        self.events_text = None;
        self.recorded += 1;
        self.last_event = event;
    }

    fn event_lines(
        &self,
        from: u64,
        to: u64,
        needle: Option<&str>,
    ) -> Vec<(u64, Map<String, Value>)> {
        let start = self.events.partition_point(|event| seq_of(event) < from);
        let end = self
            .events
            .partition_point(|event| seq_of(event) <= to)
            .min(start + EVENTS_READ);
        let Ok(mut file) = std::fs::File::open(self.state.join("events.jsonl")) else {
            return Vec::new();
        };
        let mut out = Vec::new();
        let mut buffer = Vec::new();
        for index in start..end {
            let offset = self.event_offsets[index];
            let next = self.event_offsets.get(index + 1).copied();
            if std::io::Seek::seek(&mut file, std::io::SeekFrom::Start(offset)).is_err() {
                break;
            }
            buffer.clear();
            let read = match next {
                Some(next) if next > offset => {
                    (&mut file).take(next - offset).read_to_end(&mut buffer)
                }
                _ => std::io::BufRead::read_until(
                    &mut std::io::BufReader::new(&mut file),
                    b'\n',
                    &mut buffer,
                ),
            };
            if read.is_err() {
                break;
            }
            if needle.is_some_and(|needle| {
                !buffer
                    .windows(needle.len())
                    .any(|window| window == needle.as_bytes())
            }) {
                continue;
            }
            if let Ok(Value::Object(event)) =
                serde_json::from_slice::<Value>(buffer.trim_ascii_end())
            {
                out.push((seq_of(&self.events[index]), event));
            }
        }
        out
    }

    fn taken_rows(&self, rest: &str) -> Value {
        let mut parts = rest.splitn(2, ':');
        let from: u64 = parts.next().and_then(|text| text.parse().ok()).unwrap_or(0);
        let to: u64 = parts
            .next()
            .and_then(|text| text.parse().ok())
            .unwrap_or(from);
        Value::Array(self.event_lines(from, to, None).into_iter().map(|(seq, event)| {
            let field = |key: &str| event.get(key).cloned().unwrap_or(Value::Null);
            json!({"seq": seq, "taken": event.get("taken").cloned().unwrap_or(json!({})), "refusals": event.get("refusals").cloned().unwrap_or(json!([])), "kinds": field("kinds"), "claimed": field("claimed"), "collector": field("collector"), "status": field("status")})
        }).collect())
    }

    fn rate_rows(&self, rest: &str) -> Value {
        let (from, path) = rest.split_once(':').unwrap_or(("0", rest));
        let from: u64 = from.parse().unwrap_or(0);
        if path.is_empty() {
            return json!([]);
        }
        let quoted = serde_json::to_string(path).unwrap_or_default();
        let needle = &quoted[1..quoted.len().saturating_sub(1)];
        let prefix = format!("{path}/");
        let rows = self
            .event_lines(from, u64::MAX, Some(needle))
            .into_iter()
            .filter_map(|(seq, event)| {
                let taken = event.get("taken")?.as_object()?;
                let amount: i64 = taken
                    .iter()
                    .filter(|(key, _)| *key == path || key.starts_with(&prefix))
                    .map(|(_, size)| number(Some(size)))
                    .sum();
                (amount > 0).then(|| json!([seq, amount]))
            });
        Value::Array(rows.collect())
    }

    fn store_sums(&mut self) {
        let mut sums: HashMap<&'static str, i64> = HashMap::new();
        for claim in &self.model.claims {
            let bytes: u64 = claim.found.iter().map(|slot| self.store.size(*slot)).sum();
            *sums.entry(claim.class).or_insert(0) += bytes as i64;
        }
        for item in self.model.items.iter_mut() {
            item.store_bytes = item.store.iter().map(|slot| self.store.size(*slot)).sum();
            *sums.entry(item.kind.key()).or_insert(0) += item.store_bytes as i64;
        }
        let slots: Vec<u32> = self
            .store
            .alive_slots()
            .filter(|slot| !self.model.holds(*slot))
            .collect();
        sums.insert(
            "recent",
            slots.iter().map(|slot| self.store.size(*slot) as i64).sum(),
        );
        *sums.entry("dead").or_insert(0) += self.store.orphan_bytes as i64;
        self.sums = sums;
        self.model_version += 1;
    }

    fn node_total(&self, path: &str) -> i64 {
        self.tree
            .find(path)
            .map(|id| self.tree.node(id).total as i64)
            .unwrap_or(0)
    }

    fn file_parts(&mut self) -> (HashMap<&'static str, i64>, HashMap<&'static str, i64>) {
        if clock() - self.probed >= PROBE_SECONDS {
            self.probed = clock();
            self.swap = probe::blocks("/swapfile") as i64;
            self.mounts = probe::covered_mountpoints("/");
        }
        let swap = self.swap;
        if self
            .file_cache
            .as_ref()
            .is_none_or(|cache| cache.0 != self.model_version)
        {
            let mut kinds: HashMap<&'static str, i64> = HashMap::new();
            let mut under: HashMap<String, i64> = HashMap::new();
            for index in &self.model.file_items {
                let item = &self.model.items[*index];
                if item.file_bytes == 0 {
                    continue;
                }
                *kinds.entry(item.kind.key()).or_insert(0) += item.file_bytes as i64;
                let top = format!("/{}", item.path.split('/').nth(1).unwrap_or(""));
                *under.entry(top).or_insert(0) += item.file_bytes as i64;
            }
            self.file_cache = Some((self.model_version, kinds, under));
        }
        let (_, kinds, under) = self.file_cache.as_ref().expect("file cache filled above");
        let extra: i64 = self.xattr.values().map(|value| *value as i64).sum();
        let extra_home: i64 = self
            .xattr
            .iter()
            .filter(|(path, _)| path.starts_with("/home/"))
            .map(|(_, value)| *value as i64)
            .sum();
        let extra_tmp: i64 = self
            .xattr
            .iter()
            .filter(|(path, _)| path.starts_with("/tmp/"))
            .map(|(_, value)| *value as i64)
            .sum();
        let scratch = self.scratch_root();
        let scratch_prefix = format!("{scratch}/");
        let extra_scratch: i64 = self
            .xattr
            .iter()
            .filter(|(path, _)| path.starts_with(&scratch_prefix))
            .map(|(_, value)| *value as i64)
            .sum();
        let claimed_scratch: i64 = self
            .model
            .file_items
            .iter()
            .map(|index| &self.model.items[*index])
            .filter(|item| item.path.starts_with(&scratch_prefix))
            .map(|item| item.file_bytes as i64)
            .sum();
        let agent_files = (self.node_total(&scratch) - claimed_scratch - extra_scratch).max(0);
        let home = self.node_total("/home");
        let tmp = self.node_total("/tmp");
        let nix = self.node_total("/nix");
        let root = self.tree.node(self.tree.root).total as i64;
        let (store_total, store_dirs) = self
            .tree
            .find("/nix/store")
            .map(|id| {
                (
                    self.tree.node(id).total as i64,
                    self.tree.node(id).dir_blocks as i64,
                )
            })
            .unwrap_or((0, 0));
        let elsewhere: i64 = under
            .iter()
            .filter(|(key, _)| *key != "/home" && *key != "/tmp")
            .map(|(_, value)| *value)
            .sum();
        let mut parts = HashMap::new();
        parts.insert(
            "home_files",
            home - under.get("/home").copied().unwrap_or(0) - extra_home,
        );
        parts.insert(
            "tmp_files",
            tmp - under.get("/tmp").copied().unwrap_or(0) - extra_tmp - agent_files,
        );
        parts.insert("agent_files", agent_files);
        parts.insert(
            "system_files",
            root - nix - home - tmp - swap - elsewhere - (extra - extra_home - extra_tmp),
        );
        parts.insert("swap", swap);
        parts.insert("building", store_total - store_dirs);
        parts.insert(
            "metadata",
            nix - store_total + store_dirs + self.store.links_blocks as i64,
        );
        parts.insert(
            "filesystem",
            self.internals
                .iter()
                .map(|(_, value)| *value as i64)
                .sum::<i64>()
                + 4096 * self.mounts.len() as i64,
        );
        (parts, kinds.clone())
    }

    fn compose(&mut self) -> (Statfs, HashMap<&'static str, i64>, i64) {
        let disk = statfs();
        let (parts, file_kinds) = self.file_parts();
        let mut segments: HashMap<&'static str, i64> = HashMap::new();
        for (key, value) in self
            .sums
            .iter()
            .chain(file_kinds.iter())
            .chain(parts.iter())
        {
            *segments.entry(key).or_insert(0) += value;
        }
        segments.insert("held", self.held.iter().map(|row| row.size as i64).sum());
        let mut residual = disk.used - segments.values().sum::<i64>();
        if self.tree.dirty.is_empty() {
            self.settled_residual = residual;
        } else if residual != self.settled_residual {
            let target = self.dirty_segment();
            let current = segments.get(target).copied().unwrap_or(0);
            let moved = (residual - self.settled_residual).max(-current);
            segments.insert(target, current + moved);
            residual -= moved;
        }
        let mut rest = residual;
        for key in ["held", "system_files"] {
            let current = segments.get(key).copied().unwrap_or(0);
            let moved = rest.max(-current);
            segments.insert(key, current + moved);
            rest -= moved;
        }
        segments.insert("reserved", disk.reserved);
        (disk, segments, residual)
    }

    fn dirty_segment(&mut self) -> &'static str {
        let areas: Vec<(&'static str, f64)> = self
            .tree
            .dirty
            .iter()
            .map(|(id, since)| (Self::area(&self.tree.path(*id)), *since))
            .collect();
        if !areas.iter().any(|(area, _)| *area == self.dirty_target) {
            self.dirty_target = areas
                .iter()
                .min_by(|a, b| a.1.total_cmp(&b.1))
                .map(|(area, _)| *area)
                .unwrap_or(self.dirty_target);
        }
        self.dirty_target
    }

    fn area(path: &str) -> &'static str {
        if path.starts_with("/home/") {
            "home_files"
        } else if path.starts_with("/tmp/") {
            "tmp_files"
        } else if path.starts_with("/nix/store") {
            "building"
        } else if path.starts_with("/nix/") {
            "metadata"
        } else {
            "system_files"
        }
    }

    fn cut(&self, deficit: i64) -> (i64, Vec<bool>) {
        let mut planned = vec![false; self.model.items.len()];
        let (mut last, mut cumulative) = (-1i64, 0i64);
        for (index, item) in self.model.items.iter().enumerate() {
            if cumulative >= deficit {
                break;
            }
            if item.freed() == 0
                || self.lagging.contains_key(&item.path)
                || !(self.deleting.contains(&item.path)
                    || self.handed.contains(&item.path)
                    || self.available(item))
            {
                continue;
            }
            planned[index] = true;
            cumulative += item.freed() as i64;
            last = index as i64;
        }
        (last, planned)
    }

    fn is_planned(&self, index: usize) -> bool {
        self.planned.get(index).copied().unwrap_or(false)
    }

    fn is_doomed(&self, path: &str) -> bool {
        self.deleting.contains(path)
    }

    fn is_lagging(&self, path: &str) -> bool {
        self.lagging.contains_key(path) && !self.is_doomed(path)
    }

    fn is_next(&self, index: usize) -> bool {
        self.next_rank == index as i64
    }

    fn settle(&self, path: &str, last_used: i64) -> i64 {
        let mut settled = self.settled.borrow_mut();
        let held = settled.entry(path.to_string()).or_insert(last_used);
        if (last_used - *held).abs() > 60 {
            *held = last_used;
        }
        *held
    }

    fn build_overview(&mut self) -> Value {
        let (disk, segments, residual) = self.compose();
        let target = self.target();
        let deficit = (target + MARGIN - disk.free).max(0);
        if clock() - self.cut_at >= 1.0 || self.planned.len() != self.model.items.len() {
            let (cut, planned) = self.cut(deficit);
            self.cut_rank = cut;
            self.planned = planned;
            self.cut_at = clock();
        }
        let (cut, planned) = (self.cut_rank, std::mem::take(&mut self.planned));
        self.next_rank = self.arrow();
        let planned_key = planned.iter().filter(|flag| **flag).count() as i64 * 1_000_003 + cut;
        self.planned = planned;
        if self
            .scheduled_cache
            .as_ref()
            .is_none_or(|cache| cache.0 != self.model_version || cache.1 != planned_key)
        {
            let mut scheduled: HashMap<&'static str, i64> = HashMap::new();
            let mut reclaimable = 0i64;
            for (index, item) in self.model.items.iter().enumerate() {
                reclaimable += item.freed() as i64;
                if self.is_planned(index) {
                    *scheduled.entry(item.kind.key()).or_insert(0) += item.freed() as i64;
                }
            }
            self.scheduled_cache = Some((self.model_version, planned_key, scheduled, reclaimable));
        }
        let (_, _, scheduled, reclaimable) = self.scheduled_cache.clone().unwrap_or_default();
        let mut lagging: HashMap<&'static str, i64> = HashMap::new();
        let mut deleting: HashMap<&'static str, i64> = HashMap::new();
        for path in self.deleting.iter().chain(self.lagging.keys()) {
            if let Some(item) = self
                .by_path
                .get(path)
                .and_then(|index| self.model.items.get(*index))
            {
                let into = if self.is_doomed(path) {
                    &mut deleting
                } else {
                    &mut lagging
                };
                *into.entry(item.kind.key()).or_insert(0) += item.freed() as i64;
            }
        }
        let home = self.home_spans();
        let generation = self.row_spans("generation");
        let temp = self.row_spans("temp");
        let head_item = usize::try_from(self.next_rank)
            .ok()
            .and_then(|index| self.model.items.get(index));
        let live_temp = segments.get("tmp_files").copied().unwrap_or(0)
            + segments.get("tmp_roots").copied().unwrap_or(0);
        let rows: Vec<Value> = SEGMENTS.iter().map(|(key, label, group, can)| json!({"key": key, "label": label, "group": group, "reclaimable": can, "bytes": segments.get(key).copied().unwrap_or(0) + match *key { "temp" => live_temp, "generation" => segments.get("previous").copied().unwrap_or(0), "home_profile" => segments.get("profiles").copied().unwrap_or(0), "processes" => segments.get("shells").copied().unwrap_or(0), "agent" => segments.get("agent_files").copied().unwrap_or(0), "stray" => segments.get("deploy").copied().unwrap_or(0) + segments.get("roots").copied().unwrap_or(0), "home_files" => segments.get("repo").copied().unwrap_or(0) + segments.get("game").copied().unwrap_or(0), _ => 0 }, "weight": Kind::from_name(key).filter(|kind| kind.key() == *key).map(Kind::weight), "reclaim_bytes": if *can { folded(key).iter().map(|part| segments.get(part).copied().unwrap_or(0)).sum::<i64>() } else { 0 }, "scheduled": folded(key).iter().map(|part| scheduled.get(part).copied().unwrap_or(0)).sum::<i64>(), "deleting": folded(key).iter().map(|part| deleting.get(part).copied().unwrap_or(0)).sum::<i64>(), "lagging": folded(key).iter().map(|part| lagging.get(part).copied().unwrap_or(0)).sum::<i64>(), "deleting_spans": match *key { "home_files" => home["deleting"].clone(), "generation" => generation["deleting"].clone(), "temp" => temp["deleting"].clone(), _ => Value::Null }, "lagging_spans": match *key { "home_files" => home["lagging"].clone(), "generation" => generation["lagging"].clone(), "temp" => temp["lagging"].clone(), _ => Value::Null }, "items": if *can { folded(key).iter().map(|part| self.kind_items.get(*part).map(Vec::len).unwrap_or(0)).sum::<usize>() } else { 0 }, "reclaim_spans": match *key { "home_files" => home["reclaim"].clone(), "generation" => generation["reclaim"].clone(), "temp" => temp["reclaim"].clone(), _ => Value::Null }, "scheduled_spans": match *key { "home_files" => home["scheduled"].clone(), "generation" => generation["scheduled"].clone(), "temp" => temp["scheduled"].clone(), _ => Value::Null }, "next_span": if *key == "home_files" { home["next"].get(0).cloned().unwrap_or(Value::Null) } else if *key == "generation" { generation["next"].get(0).cloned().unwrap_or(Value::Null) } else if *key == "temp" { temp["next"].get(0).cloned().unwrap_or(Value::Null) } else { head_item.filter(|item| folded(key).contains(&item.kind.key())).map(|item| json!([0, item.freed()])).unwrap_or(Value::Null) }})).collect();
        self.cut_rank = cut;
        let head = usize::try_from(self.next_rank).ok().and_then(|index| self.model.items.get(index)).map(|item| json!({"path": item.path, "label": short(&item.path, &self.home), "kind": item.kind.key(), "size": item.freed(), "last_used": item.last_used, "rank": self.next_rank, "ranking": self.ranking}));
        json!({
            "next": head,
            "disk": {"total": disk.total, "used": disk.used, "free": disk.free, "reserved": disk.reserved},
            "free": disk.free,
            "target": target,
            "deficit": deficit,
            "cut": cut,
            "reclaimable": reclaimable,
            "segments": rows,
            "residual": residual,
            "gc": Value::Object(self.status.clone()),
        })
    }

    fn tracker(&self) -> Value {
        let round =
            |value: f64, places: i32| (value * 10f64.powi(places)).round() / 10f64.powi(places);
        json!({
            "at": sys::now() as i64,
            "dirty": self.tree.dirty.len(),
            "directories": self.tree.keys.len(),
            "events": self.tree.events,
            "opens": self.opens.as_ref().map(|opens| opens.events).unwrap_or(0),
            "exit_watches": self.exits.len(),
            "store_paths": self.store.count(),
            "stale_links": self.store.stale_links,
            "walked": self.store.paths.iter().filter(|path| path.alive && path.own.is_some()).count(),
            "items": self.model.items.len(),
            "model_seconds": round(self.model_cost, 3),
            "roots_seconds": round(self.roots_cost, 3),
            "sums_seconds": round(self.sums_cost, 3),
            "files_seconds": round(self.files_cost, 4),
            "startup_seconds": round(self.startup_seconds, 3),
            "model": self.model.laps.iter().map(|(name, seconds)| (name.to_string(), json!(round(*seconds, 4)))).collect::<Map<String, Value>>(),
            "startup": self.laps.iter().map(|(name, seconds)| (name.to_string(), json!(round(*seconds, 3)))).collect::<Map<String, Value>>(),
            "walk_seconds": round(self.tree.walk_seconds, 1),
            "verify_pass_seconds": round(self.tree.pass_seconds, 1),
            "rss": rss(),
            "push_latency_ms": {
                "median": round(percentile(&self.latencies, 0.5) * 1000.0, 1),
                "p90": round(percentile(&self.latencies, 0.9) * 1000.0, 1),
                "max": round(percentile(&self.latencies, 1.0) * 1000.0, 1),
                "samples": self.latencies.len(),
            },
            "swept": self.swept,
            "slow_steps": self.slow.iter().map(|(at, phase, seconds, total)| json!({"at": at, "phase": phase, "phase_ms": round(seconds * 1000.0, 1), "total_ms": round(total * 1000.0, 1)})).collect::<Vec<_>>(),
        })
    }

    fn item_kind_text(&self, item: &Item) -> String {
        let detail = &item.detail;
        match item.kind {
            Kind::Generation | Kind::Stray => format!(
                "{} generation {}, replaced {}",
                basename(item.text("profile")),
                plain(detail.get("number")),
                probe::local("%Y-%m-%d %H:%M", item.last_used)
            ),
            Kind::Agent if item.flag("worktree") => {
                let state = if item.flag("merged") {
                    "merged"
                } else {
                    "unmerged"
                };
                let dirty = if item.flag("dirty") {
                    format!(", {} uncommitted", plain(detail.get("dirty")))
                } else {
                    String::new()
                };
                format!("agent worktree, {state}{dirty}")
            }
            Kind::Build => {
                if item.flag("project") {
                    format!(
                        "build output of {}",
                        short(item.text("project"), &self.home)
                    )
                } else {
                    "offloaded build output".into()
                }
            }
            Kind::Agent if item.flag("session") => "scratch of an ended agent session".into(),
            Kind::Project => format!(
                "project roots: {}",
                detail
                    .get("roots")
                    .and_then(Value::as_array)
                    .map(Vec::len)
                    .unwrap_or(0)
            ),
            Kind::StaleShell => format!("shell roots of exited pid {}", plain(detail.get("pid"))),
            Kind::Game => {
                let played = detail.get("played").and_then(Value::as_i64).unwrap_or(0);
                let store = if item.text("store") == "steam" {
                    "Steam"
                } else {
                    "Heroic"
                };
                let when = if played > 0 {
                    format!("last played {}", probe::local("%Y-%m-%d", played))
                } else {
                    "never played".into()
                };
                if item.flag("tool") {
                    let when = if played > 0 {
                        format!("last used {}", probe::local("%Y-%m-%d", played))
                    } else {
                        "unused by any prefix".into()
                    };
                    format!(
                        "Steam tool {}, {when}; Steam downloads it again when a game needs it",
                        item.text("title")
                    )
                } else {
                    format!("{store} game {}, {when}; saves and prefixes are kept, reinstall from {store}", item.text("title"))
                }
            }
            Kind::Trash => {
                let origin = item.text("origin");
                let from = if origin.is_empty() {
                    String::new()
                } else {
                    format!(" from {}", short(origin, &self.home))
                };
                format!(
                    "in the recycle bin since {}{from}",
                    probe::local("%Y-%m-%d %H:%M", item.last_used)
                )
            }
            Kind::Repo => {
                let dirty = if item.flag("dirty") {
                    format!(", keeps {} uncommitted", plain(detail.get("dirty")))
                } else {
                    String::new()
                };
                {
                    let unpushed = detail.get("unpushed").and_then(Value::as_u64).unwrap_or(0);
                    let pushed = if unpushed > 0 {
                        format!("{unpushed} unpushed commits kept as a bundle")
                    } else {
                        "all pushed".into()
                    };
                    format!("clone of {}, {pushed}{dirty}; shrinks to config, refs and a restore script", item.text("remote"))
                }
            }
            other => other.name().into(),
        }
    }

    fn item_row(&self, item: &Item) -> Map<String, Value> {
        probe::object(json!({
            "id": format!("item:{}", item.path),
            "label": short(&item.path, &self.home),
            "path": item.path,
            "size": item.freed(),
            "weight": item.weight(),
            "store": item.store_bytes,
            "files": item.file_bytes,
            "last_used": item.last_used,
            "kind": self.item_kind_text(item) + &rebuild_text(item.build),
            "build": item.build,
            "reclaimable": true,
            "rank": item.rank,
            "scheduled": self.is_planned(item.rank),
            "next": self.is_next(item.rank),
            "deleting": self.is_doomed(&item.path),
            "lagging": self.is_lagging(&item.path),
            "delvable": !item.store.is_empty() || !item.files.is_empty(),
            "openable": !item.files.is_empty() && !item.path.starts_with("/nix/store/"),
            "roots": item.links.iter().take(6).collect::<Vec<_>>(),
        }))
    }

    fn store_row(&mut self, slot: u32, reclaimable: bool, scheduled: bool) -> Map<String, Value> {
        let size = self.store.size(slot) as i64;
        let entry = self.store.get(slot);
        row(
            format!("store:{}", entry.path),
            short(&entry.path, &self.home),
            entry.path.clone(),
            size,
            entry.used.unwrap_or(0),
            "store path".into(),
            reclaimable,
            scheduled,
            !entry.refs.is_empty(),
            false,
        )
    }

    fn path_rows(
        &mut self,
        paths: &[u32],
        owner_id: &str,
        reclaimable: bool,
        scheduled: bool,
    ) -> Vec<Map<String, Value>> {
        let mut order: Vec<String> = Vec::new();
        let mut families: HashMap<String, Vec<u32>> = HashMap::new();
        for slot in paths {
            let name = family(&short(&self.store.get(*slot).path, &self.home));
            families
                .entry(name.clone())
                .or_insert_with(|| {
                    order.push(name);
                    Vec::new()
                })
                .push(*slot);
        }
        let mut rows = Vec::new();
        for name in order {
            let members = families.remove(&name).unwrap_or_default();
            if members.len() >= 3 {
                let size: i64 = members
                    .iter()
                    .map(|slot| self.store.size(*slot) as i64)
                    .sum();
                let used = members
                    .iter()
                    .map(|slot| self.store.get(*slot).used.unwrap_or(0))
                    .max()
                    .unwrap_or(0);
                if size == 0 {
                    continue;
                }
                rows.push(row(
                    format!("family:{owner_id}:{name}"),
                    format!("{name} ×{}", members.len()),
                    String::new(),
                    size,
                    used,
                    format!("{} store paths", members.len()),
                    reclaimable,
                    scheduled,
                    true,
                    false,
                ));
            } else {
                for slot in members {
                    if self.store.size(slot) != 0 {
                        rows.push(self.store_row(slot, reclaimable, scheduled));
                    }
                }
            }
        }
        rows
    }

    fn claim_members(&self, key: &str) -> Vec<u32> {
        let prefix = format!("{key}/");
        let mut found: BTreeSet<u32> = BTreeSet::new();
        for claim in &self.model.claims {
            if claim.link == key || claim.link.starts_with(&prefix) {
                found.extend(claim.found.iter().copied());
            }
        }
        found.into_iter().collect()
    }

    fn claim_set(&mut self, owner: &Owner) -> Rc<HashSet<u32>> {
        if let Some(found) = self.claim_sets.get(owner) {
            return found.clone();
        }
        let found: HashSet<u32> = match owner {
            Owner::Claim(index) => {
                let key = self.model.claims[*index as usize].link.clone();
                self.claim_members(&key).into_iter().collect()
            }
            Owner::Item(index) => self.model.items[*index as usize]
                .store
                .iter()
                .copied()
                .collect(),
        };
        let found = Rc::new(found);
        self.claim_sets.insert(*owner, found.clone());
        found
    }

    fn members(&self, owner_id: &str) -> Vec<u32> {
        if let Some(key) = owner_id.strip_prefix("claim:") {
            return self.claim_members(key);
        }
        if let Some(path) = owner_id.strip_prefix("item:") {
            return self
                .by_path
                .get(path)
                .map(|index| self.model.items[*index].store.clone())
                .unwrap_or_default();
        }
        if owner_id == "segment:recent" {
            return self
                .store
                .alive_slots()
                .filter(|slot| !self.model.holds(*slot))
                .collect();
        }
        Vec::new()
    }

    fn scheduled_item(&self, path: &str) -> bool {
        self.by_path
            .get(path)
            .map(|index| self.is_planned(*index))
            .unwrap_or(false)
    }

    fn dir_rows(&self, path: &str, context: &str) -> Vec<Map<String, Value>> {
        let Some(id) = self.tree.find(path) else {
            return Vec::new();
        };
        let node = self.tree.node(id);
        if !node.attached {
            return Vec::new();
        }
        let in_place = |item: &&Item| matches!(item.kind, Kind::Repo | Kind::Game);
        let file_items: Vec<&Item> = if context == "files" {
            self.model
                .file_items
                .iter()
                .map(|index| &self.model.items[*index])
                .filter(|item| item.file_bytes != 0)
                .collect()
        } else {
            Vec::new()
        };
        let claimed: Vec<&String> = file_items
            .iter()
            .filter(|item| !in_place(item))
            .flat_map(|item| item.files.iter())
            .collect();
        let kept: Vec<&Item> = file_items
            .into_iter()
            .filter(|item| in_place(&item))
            .collect();
        let base = path.trim_end_matches('/');
        let prefix = format!("{base}/");
        let mut buckets: HashMap<&str, HashSet<&str>> = HashMap::new();
        for file in &claimed {
            if let Some(rest) = file.strip_prefix(&prefix) {
                buckets
                    .entry(rest.split('/').next().unwrap_or(""))
                    .or_default()
                    .insert(file.as_str());
            }
        }
        let store_node = self.tree.find("/nix/store");
        let mut rows = Vec::new();
        for child in node.children.iter() {
            let name = &self.tree.node(*child).name;
            let child_path = format!("{prefix}{name}");
            if Some(*child) == store_node && context == "files" {
                continue;
            }
            let empty = HashSet::new();
            let inside = buckets.get(&**name).unwrap_or(&empty);
            if inside.contains(child_path.as_str()) {
                continue;
            }
            let top = inside.iter().filter(|file| {
                !probe::parents_within(file, &child_path)
                    .iter()
                    .any(|ancestor| inside.contains(ancestor.as_str()))
            });
            let size = self.tree.node(*child).total as i64
                - top.map(|file| self.tree.size(file) as i64).sum::<i64>();
            if size <= 0 {
                continue;
            }
            let mut entry = row(
                format!("dir:{context}:{child_path}"),
                name.to_string(),
                child_path.clone(),
                size,
                self.tree.node(*child).newest,
                "directory".into(),
                context == "item",
                false,
                true,
                true,
            );
            if let Some(item) = kept.iter().find(|item| item.path == child_path) {
                let mut own = self.item_row(item);
                own.insert("id".into(), entry["id"].clone());
                own.insert("openable".into(), json!(true));
                own.insert("label".into(), json!(name.to_string()));
                own.insert("size".into(), json!(size));
                own.insert("reclaimBytes".into(), json!(item.freed()));
                own.insert(
                    "reclaimSpans".into(),
                    json!([[0, (item.freed() as i64).min(size)]]),
                );
                own.insert(
                    "scheduledSpans".into(),
                    json!(if self.is_planned(item.rank) {
                        vec![[0, (item.freed() as i64).min(size)]]
                    } else {
                        Vec::new()
                    }),
                );
                own.insert(
                    "nextSpans".into(),
                    json!(if self.is_next(item.rank) {
                        vec![[0, (item.freed() as i64).min(size)]]
                    } else {
                        Vec::new()
                    }),
                );
                own.insert(
                    "deletingSpans".into(),
                    json!(if self.is_doomed(&item.path) {
                        vec![[0, (item.freed() as i64).min(size)]]
                    } else {
                        Vec::new()
                    }),
                );
                own.insert(
                    "laggingSpans".into(),
                    json!(if self.is_lagging(&item.path) {
                        vec![[0, (item.freed() as i64).min(size)]]
                    } else {
                        Vec::new()
                    }),
                );
                own.insert("delvable".into(), json!(true));
                entry = own;
            } else {
                let inside: Vec<&&Item> = kept
                    .iter()
                    .filter(|item| item.path.starts_with(&format!("{child_path}/")))
                    .collect();
                if !inside.is_empty() {
                    entry.insert("reclaimable".into(), json!(true));
                    let [spans, planned, next, doomed, lagging] = self.reclaim_spans(&child_path);
                    entry.insert(
                        "reclaimBytes".into(),
                        json!(spans.iter().map(|span| span[1]).sum::<i64>().min(size)),
                    );
                    entry.insert("reclaimSpans".into(), json!(spans));
                    entry.insert(
                        "scheduledBytes".into(),
                        json!(planned.iter().map(|span| span[1]).sum::<i64>().min(size)),
                    );
                    entry.insert("scheduledSpans".into(), json!(planned));
                    entry.insert("nextSpans".into(), json!(next));
                    entry.insert("deletingSpans".into(), json!(doomed));
                    entry.insert("laggingSpans".into(), json!(lagging));
                    entry.insert(
                        "scheduled".into(),
                        json!(inside.iter().any(|item| self.is_planned(item.rank))),
                    );
                    entry.insert(
                        "deletingBytes".into(),
                        json!(inside
                            .iter()
                            .filter(|item| self.is_doomed(&item.path))
                            .map(|item| item.freed() as i64)
                            .sum::<i64>()
                            .min(size)),
                    );
                }
            }
            let settled = self.settle(&child_path, number(entry.get("last_used")));
            entry.insert("last_used".into(), json!(settled));
            rows.push(entry);
        }
        let mut loose = node.own as i64
            - if path == "/" { self.swap } else { 0 }
            - if context == "store" {
                node.dir_blocks as i64
            } else {
                0
            };
        loose -= claimed
            .iter()
            .filter(|file| dirname(file) == base && self.tree.find(file).is_none())
            .map(|file| self.tree.size(file) as i64)
            .sum::<i64>();
        if loose > 0 {
            let count = std::fs::read_dir(if base.is_empty() { "/" } else { base })
                .map(|entries| {
                    entries
                        .flatten()
                        .filter(|entry| entry.file_type().is_ok_and(|kind| !kind.is_dir()))
                        .count()
                })
                .unwrap_or(0);
            let place = if base.is_empty() {
                "/".to_string()
            } else {
                short(base, &self.home)
            };
            let label = format!(
                "{count} file{} in {place}",
                if count == 1 { "" } else { "s" }
            );
            rows.push(row(
                format!("loose:{context}:{base}"),
                label,
                format!("{base}/*"),
                loose,
                node.own_newest,
                "files".into(),
                context == "item",
                false,
                true,
                false,
            ));
        }
        let cache = format!("{}/.cache", self.home);
        if context == "files" && (base == "/tmp" || base.starts_with("/tmp/")) {
            self.annotate_holders(&mut rows, "/tmp");
        } else if context == "files" && (base == cache || base.starts_with(&format!("{cache}/"))) {
            self.annotate_holders(&mut rows, &cache);
        }
        rows
    }

    fn loose_rows(&self, base: &str, context: &str) -> Vec<Map<String, Value>> {
        use std::os::unix::fs::MetadataExt;
        let claimed: HashSet<&str> = if context == "files" {
            self.model
                .file_items
                .iter()
                .map(|index| &self.model.items[*index])
                .filter(|item| !matches!(item.kind, Kind::Repo | Kind::Game))
                .flat_map(|item| item.files.iter().map(String::as_str))
                .collect()
        } else {
            HashSet::new()
        };
        let directory = if base.is_empty() { "/" } else { base };
        let mut rows: Vec<Map<String, Value>> = std::fs::read_dir(directory)
            .map(|entries| {
                entries
                    .flatten()
                    .filter_map(|entry| {
                        let info = entry.metadata().ok()?;
                        if info.is_dir() {
                            return None;
                        }
                        let path = format!("{base}/{}", entry.file_name().to_string_lossy());
                        if claimed.contains(path.as_str())
                            || (base.is_empty() && path == "/swapfile")
                        {
                            return None;
                        }
                        let size = (info.blocks() * 512) as i64;
                        let label = entry.file_name().to_string_lossy().into_owned();
                        Some(row(
                            format!("file:{path}"),
                            label,
                            path,
                            size,
                            info.mtime(),
                            "file".into(),
                            context == "item",
                            false,
                            false,
                            true,
                        ))
                    })
                    .collect()
            })
            .unwrap_or_default();
        rows.sort_by_key(|row| -number(row.get("size")));
        rows
    }

    fn reclaim_spans(&self, path: &str) -> [Vec<[i64; 2]>; 5] {
        let rows = self.dir_rows(path, "files");
        let timed = !rows.is_empty() && rows.iter().all(|row| number(row.get("last_used")) > 0);
        let mut list: Vec<&Map<String, Value>> = rows
            .iter()
            .filter(|row| number(row.get("size")) > 0)
            .collect();
        list.sort_by_key(|row| {
            (
                if timed {
                    number(row.get("last_used"))
                } else {
                    -number(row.get("size"))
                },
                row.get("id")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string(),
            )
        });
        let mut out: [Vec<[i64; 2]>; 5] = Default::default();
        let mut offset = 0i64;
        for row in list {
            for (key, spans) in [
                "reclaimSpans",
                "scheduledSpans",
                "nextSpans",
                "deletingSpans",
                "laggingSpans",
            ]
            .iter()
            .zip(out.iter_mut())
            {
                for span in row
                    .get(*key)
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                {
                    let (start, length) = (offset + number(span.get(0)), number(span.get(1)));
                    match spans.last_mut() {
                        Some(last) if last[0] + last[1] == start => last[1] += length,
                        _ => spans.push([start, length]),
                    }
                }
            }
            offset += number(row.get("size"));
        }
        out
    }

    fn clone_store(&self) -> Vec<&Item> {
        ["repo", "game"]
            .iter()
            .flat_map(|kind| self.kind_items.get(*kind).into_iter().flatten())
            .map(|index| &self.model.items[*index])
            .filter(|item| item.store_bytes > 0)
            .collect()
    }

    fn clone_store_row(&self) -> Option<Map<String, Value>> {
        let items = self.clone_store();
        let size: i64 = items.iter().map(|item| item.store_bytes as i64).sum();
        if size == 0 {
            return None;
        }
        let newest = items.iter().map(|item| item.last_used).max().unwrap_or(0);
        let scheduled = items.iter().any(|item| self.is_planned(item.rank));
        let mut entry = row(
            "meta:clone-store".into(),
            "nix store kept by clones and games".into(),
            String::new(),
            size,
            newest,
            format!(
                "store paths rooted inside {} git clones and game dirs, outside /home",
                items.len()
            ),
            true,
            scheduled,
            false,
            false,
        );
        entry.insert(
            "next".into(),
            json!(items.iter().any(|item| self.is_next(item.rank))),
        );
        entry.insert(
            "deleting".into(),
            json!(items.iter().any(|item| self.is_doomed(&item.path))),
        );
        entry.insert(
            "lagging".into(),
            json!(items.iter().any(|item| self.is_lagging(&item.path))),
        );
        Some(entry)
    }

    fn row_spans(&mut self, key: &str) -> Value {
        self.unlabelled = true;
        let mut rows = self.segment_rows(key);
        self.unlabelled = false;
        let field = |entry: &Map<String, Value>, name: &str| {
            entry.get(name).and_then(Value::as_i64).unwrap_or(0)
        };
        let flag = |entry: &Map<String, Value>, name: &str| {
            entry.get(name).and_then(Value::as_bool).unwrap_or(false)
        };
        let timed = !rows.is_empty() && rows.iter().all(|entry| field(entry, "last_used") > 0);
        rows.sort_by(|a, b| {
            let primary = if timed {
                field(a, "last_used").cmp(&field(b, "last_used"))
            } else {
                field(b, "size").cmp(&field(a, "size"))
            };
            primary.then_with(|| {
                a.get("id")
                    .and_then(Value::as_str)
                    .cmp(&b.get("id").and_then(Value::as_str))
            })
        });
        let (mut reclaim, mut planned, mut next, mut doomed, mut lagging) =
            (Vec::new(), Vec::new(), Vec::new(), Vec::new(), Vec::new());
        let mut offset = 0;
        for entry in rows.iter().filter(|entry| field(entry, "size") > 0) {
            let span = [offset, field(entry, "size")];
            if flag(entry, "reclaimable") {
                reclaim.push(span);
            }
            if flag(entry, "scheduled") {
                planned.push(span);
            }
            if flag(entry, "next") {
                next.push(span);
            }
            if flag(entry, "deleting") {
                doomed.push(span);
            }
            if flag(entry, "lagging") {
                lagging.push(span);
            }
            offset += span[1];
        }
        json!({"reclaim": reclaim, "scheduled": planned, "next": next, "deleting": doomed, "lagging": lagging})
    }

    fn home_spans(&self) -> Value {
        let key = self.model_version
            ^ (self.planned.iter().filter(|planned| **planned).count() as u64) << 32
            ^ (self.deleting.len() as u64) << 52
            ^ (self.lagging.len() as u64) << 44
            ^ self.batch << 8
            ^ (self.next_rank as u64) << 12;
        let mut cache = self.spans_cache.borrow_mut();
        if let Some((at, version, spans)) = cache.as_ref() {
            if *version == key && clock() - at < 10.0 {
                return spans.clone();
            }
        }
        let [mut reclaim, mut planned, mut next, mut doomed, mut lagging] =
            self.reclaim_spans("/home");
        let items = self.clone_store();
        let mut offset = self.node_total("/home");
        for item in items {
            let span = [offset, item.store_bytes as i64];
            reclaim.push(span);
            if self.is_planned(item.rank) {
                planned.push(span);
            }
            if self.is_next(item.rank) {
                next.push(span);
            }
            if self.is_doomed(&item.path) {
                doomed.push(span);
            }
            if self.is_lagging(&item.path) {
                lagging.push(span);
            }
            offset += item.store_bytes as i64;
        }
        let spans = json!({"reclaim": reclaim, "scheduled": planned, "next": next, "deleting": doomed, "lagging": lagging});
        *cache = Some((clock(), key, spans.clone()));
        spans
    }

    fn annotate_holders(&self, rows: &mut [Map<String, Value>], root: &str) {
        if self.unlabelled {
            return;
        }
        let sessions = reclaim::live_sessions(&self.home);
        let holders = reclaim::holders(root);
        let clients = probe::hypr_clients();
        for entry in rows.iter_mut() {
            let path = entry
                .get("path")
                .and_then(Value::as_str)
                .unwrap_or("")
                .trim_end_matches("/*")
                .to_string();
            if !path.starts_with(&format!("{root}/")) {
                continue;
            }
            let reason = std::iter::successors(Some(path.as_str()), |current| {
                Some(dirname(current)).filter(|parent| parent.len() > 4)
            })
            .find_map(|current| self.model.protected.get(current))
            .cloned();
            let within = |target: &str| {
                target == path
                    || target.starts_with(&format!("{path}/"))
                    || path.starts_with(&format!("{target}/"))
            };
            let session = sessions.iter().find(|session| {
                session
                    .ids
                    .iter()
                    .any(|id| path.split('/').any(|part| part == id))
            });
            let (label, pid) = if let Some(session) = session {
                (
                    format!("Claude session in {}", short(&session.cwd, &self.home)),
                    Some(session.pid),
                )
            } else if path.starts_with("/tmp/claude-") && path.matches('/').count() <= 3 {
                let count = sessions.len();
                (
                    format!(
                        "{count} live Claude session{}",
                        if count == 1 { "" } else { "s" }
                    ),
                    None,
                )
            } else if let Some(pid) = reclaim::owner_pid(basename(&path)).or_else(|| {
                holders
                    .iter()
                    .find(|(target, _)| within(target))
                    .map(|(_, pid)| *pid)
            }) {
                let (command, cwd, _) = probe::describe_shell(pid, &self.home, &clients);
                (
                    if cwd.is_empty() {
                        command
                    } else {
                        format!("{command} in {cwd}")
                    },
                    Some(pid),
                )
            } else {
                continue;
            };
            let why = reason.unwrap_or_else(|| "in use".into());
            entry.insert("kind".into(), json!(why));
            entry.insert("holder".into(), json!(label));
            if let Some(pid) = pid {
                let (_, _, window) = probe::describe_shell(pid, &self.home, &clients);
                if let Some(window) = window {
                    entry.insert(
                        "pid".into(),
                        window.get("pid").cloned().unwrap_or(Value::Null),
                    );
                }
            }
        }
    }

    fn scratch_root(&self) -> String {
        format!("/tmp/claude-{}", self.owner)
    }

    fn agent_title(&mut self, project: &str, session: &str) -> (String, String) {
        let transcript = format!("{}/.claude/projects/{project}/{session}.jsonl", self.home);
        let size = std::fs::metadata(&transcript)
            .map(|meta| meta.len())
            .unwrap_or(0);
        if let Some((known, title, cwd)) = self.agent_titles.get(&transcript) {
            if *known == size {
                return (title.clone(), cwd.clone());
            }
        }
        let text = std::fs::read(&transcript).unwrap_or_default();
        let text = String::from_utf8_lossy(&text);
        let field = |name: &str| {
            text.rmatch_indices(&format!("\"{name}\":\""))
                .next()
                .and_then(|(at, found)| text[at + found.len()..].split('"').next())
                .map(String::from)
        };
        let title = field("aiTitle")
            .or_else(|| field("customTitle"))
            .or_else(|| field("summary"))
            .unwrap_or_default();
        let cwd = field("cwd")
            .map(|cwd| short(&cwd, &self.home))
            .unwrap_or_default();
        self.agent_titles
            .insert(transcript, (size, title.clone(), cwd.clone()));
        (title, cwd)
    }

    fn agent_rows(&mut self) -> Vec<Map<String, Value>> {
        let scratch = self.scratch_root();
        let sessions = reclaim::live_sessions(&self.home);
        let items = self.kind_items.get("agent").cloned().unwrap_or_default();
        let mut rows = Vec::new();
        let mut claimed = 0i64;
        for index in &items {
            let item = self.model.items[*index].clone();
            let mut entry = self.item_row(&item);
            if let Some(rest) = item.path.strip_prefix(&format!("{scratch}/")) {
                let (project, session) = rest.split_once('/').unwrap_or((rest, ""));
                let (title, cwd) = self.agent_title(project, session);
                let name = if title.is_empty() {
                    format!("agent {}", &session[..session.len().min(8)])
                } else {
                    title
                };
                entry.insert(
                    "label".into(),
                    json!(if cwd.is_empty() {
                        name
                    } else {
                        format!("{name} ({cwd})")
                    }),
                );
                claimed += item.file_bytes as i64;
            } else if let Some((repo, name)) = item.path.split_once("/.claude/worktrees/") {
                entry.insert(
                    "label".into(),
                    json!(format!("worktree {name} in {}", short(repo, &self.home))),
                );
            }
            rows.push(entry);
        }
        let mut live = 0i64;
        for project in reclaim::list_sorted(&scratch) {
            let directory = format!("{scratch}/{project}");
            if !project.starts_with('-') {
                let size = self.node_total(&directory);
                if size <= 0 || self.by_path.contains_key(&directory) {
                    continue;
                }
                let label = match project.as_str() {
                    "bash-edit-diff" => "Claude Code edit snapshots".to_string(),
                    "bundled-skills" => "Claude Code bundled skills".to_string(),
                    _ => format!("Claude Code {project}"),
                };
                let newest = self
                    .tree
                    .find(&directory)
                    .map(|id| self.tree.node(id).newest)
                    .unwrap_or(0);
                rows.push(row(
                    format!("dir:files:{directory}"),
                    label,
                    directory.clone(),
                    size,
                    newest,
                    "shared by every agent session".into(),
                    false,
                    false,
                    true,
                    true,
                ));
                live += size;
                continue;
            }
            for session in reclaim::list_sorted(&directory) {
                let path = format!("{directory}/{session}");
                if self.by_path.contains_key(&path) || !std::path::Path::new(&path).is_dir() {
                    continue;
                }
                let size = self.node_total(&path);
                if size <= 0 {
                    continue;
                }
                let (title, cwd) = self.agent_title(&project, &session);
                let holder = sessions.iter().find(|found| found.ids.contains(&session));
                let name = if title.is_empty() {
                    format!("agent {}", &session[..session.len().min(8)])
                } else {
                    title
                };
                let label = if cwd.is_empty() {
                    name
                } else {
                    format!("{name} ({cwd})")
                };
                let newest = self
                    .tree
                    .find(&path)
                    .map(|id| self.tree.node(id).newest)
                    .unwrap_or(0);
                let mut entry = row(
                    format!("dir:files:{path}"),
                    label,
                    path.clone(),
                    size,
                    newest,
                    if holder.is_some() {
                        "live agent session".into()
                    } else {
                        "agent session, still in use".into()
                    },
                    false,
                    false,
                    true,
                    true,
                );
                if let Some(holder) = holder {
                    entry.insert("pid".into(), json!(holder.pid));
                    entry.insert(
                        "holder".into(),
                        json!(format!(
                            "Claude session in {}",
                            short(&holder.cwd, &self.home)
                        )),
                    );
                }
                live += size;
                rows.push(entry);
            }
        }
        let rest = self.node_total(&scratch) - claimed - live;
        if rest > 0 {
            rows.push(row(
                format!("dir:files:{scratch}"),
                "shared agent files".into(),
                scratch.clone(),
                rest,
                0,
                "skills, diffs and logs outside any one session".into(),
                false,
                false,
                true,
                true,
            ));
        }
        rows
    }

    fn temp_rows(&mut self, only: Option<&str>) -> Vec<Map<String, Value>> {
        let items = self.kind_items.get("temp").cloned().unwrap_or_default();
        let mut entries: Vec<Map<String, Value>> = items
            .iter()
            .map(|index| self.item_row(&self.model.items[*index]))
            .collect();
        let scratch = self.scratch_root();
        entries.extend(
            self.dir_rows("/tmp", "files").into_iter().filter(|entry| {
                entry.get("path").and_then(Value::as_str) != Some(scratch.as_str())
            }),
        );
        let mut roots = self.segment_rows("tmp_roots");
        self.annotate_holders(&mut roots, "/tmp");
        entries.extend(roots);
        let mut order: Vec<String> = Vec::new();
        let mut families: HashMap<String, Vec<Map<String, Value>>> = HashMap::new();
        let mut clients = None;
        for mut entry in entries {
            let path = entry
                .get("path")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            let top = path
                .strip_prefix("/tmp/")
                .unwrap_or(&path)
                .split('/')
                .next()
                .unwrap_or("")
                .to_string();
            if let Some(text) = probe::tmp_text(
                &top,
                &self.home,
                clients.get_or_insert_with(probe::hypr_clients),
            )
            .filter(|_| !top.is_empty() && path == format!("/tmp/{top}"))
            {
                entry.insert("label".into(), json!(text));
            }
            let name = probe::tmp_family(&top);
            if only.is_some_and(|only| only != name) {
                continue;
            }
            families
                .entry(name.clone())
                .or_insert_with(|| {
                    order.push(name);
                    Vec::new()
                })
                .push(entry);
        }
        let size =
            |entry: &Map<String, Value>| entry.get("size").and_then(Value::as_i64).unwrap_or(0);
        let flag = |entry: &Map<String, Value>, name: &str| {
            entry.get(name).and_then(Value::as_bool).unwrap_or(false)
        };
        if let Some(name) = only {
            let mut members = families.remove(name).unwrap_or_default();
            if members.len() > ROWS {
                members.sort_by_key(|entry| -size(entry));
                let rest = members.split_off(ROWS);
                let reclaim: i64 = rest
                    .iter()
                    .filter(|entry| flag(entry, "reclaimable"))
                    .map(size)
                    .sum();
                let mut entry = row(
                    format!("rest:{name}"),
                    format!("{} smaller entries", rest.len()),
                    String::new(),
                    rest.iter().map(size).sum(),
                    rest.iter()
                        .filter_map(|entry| entry.get("last_used").and_then(Value::as_i64))
                        .max()
                        .unwrap_or(0),
                    "not listed".into(),
                    reclaim > 0,
                    false,
                    false,
                    false,
                );
                entry.insert("reclaimBytes".into(), json!(reclaim));
                members.push(entry);
            }
            return members;
        }
        let mut rows = Vec::new();
        for name in order {
            let members = families.remove(&name).unwrap_or_default();
            if members.len() < 3 {
                rows.extend(members);
                continue;
            }
            let count = members.len();
            let live = members
                .iter()
                .filter(|entry| !flag(entry, "reclaimable"))
                .count();
            let reclaim: i64 = members
                .iter()
                .filter(|entry| flag(entry, "reclaimable"))
                .map(size)
                .sum();
            let scheduled: i64 = members
                .iter()
                .filter(|entry| flag(entry, "scheduled"))
                .map(size)
                .sum();
            let kind = match live {
                0 => format!("{count} entries, all reclaimable"),
                _ if live == count => format!("{count} entries, all in use"),
                _ => format!("{count} entries, {live} in use"),
            };
            let used = members
                .iter()
                .filter_map(|entry| entry.get("last_used").and_then(Value::as_i64))
                .max()
                .unwrap_or(0);
            let mut entry = row(
                format!("tmpfamily:{name}"),
                format!("{name} ×{count}"),
                String::new(),
                members.iter().map(size).sum(),
                used,
                kind,
                reclaim > 0,
                scheduled > 0 && scheduled == reclaim,
                true,
                false,
            );
            entry.insert("reclaimBytes".into(), json!(reclaim));
            entry.insert("scheduledBytes".into(), json!(scheduled));
            rows.push(entry);
        }
        rows
    }

    fn segment_rows(&mut self, key: &str) -> Vec<Map<String, Value>> {
        let merged: &[&str] = match key {
            "home_profile" => &["home_profile", "profiles"],
            "stray" => &["stray", "deploy", "roots"],
            "processes" => &["shells", "processes"],
            _ => &[],
        };
        if !merged.is_empty() {
            let mut rows: Vec<Map<String, Value>> = merged
                .iter()
                .flat_map(|class| self.class_rows(class))
                .collect();
            rows.sort_by_key(|entry| -entry.get("size").and_then(Value::as_i64).unwrap_or(0));
            return rows;
        }
        self.class_rows(key)
    }

    fn class_rows(&mut self, key: &str) -> Vec<Map<String, Value>> {
        if key == "shells" {
            let mut order: Vec<String> = Vec::new();
            let mut groups: HashMap<String, BTreeSet<u32>> = HashMap::new();
            for claim in &self.model.claims {
                if claim.class == key {
                    let directory = dirname(&claim.link).to_string();
                    groups
                        .entry(directory.clone())
                        .or_insert_with(|| {
                            order.push(directory);
                            BTreeSet::new()
                        })
                        .extend(claim.found.iter().copied());
                }
            }
            let clients = probe::hypr_clients();
            let mut rows = Vec::new();
            for directory in order {
                let size: i64 = groups[&directory]
                    .iter()
                    .map(|slot| self.store.size(*slot) as i64)
                    .sum();
                if size == 0 {
                    continue;
                }
                let name = basename(&directory);
                let pid: i64 = if !name.is_empty() && name.bytes().all(|byte| byte.is_ascii_digit())
                {
                    name.parse().unwrap_or(0)
                } else {
                    0
                };
                let (command, cwd, window) = probe::describe_shell(pid, &self.home, &clients);
                let place = match &window {
                    Some(window) => format!(
                        "{}: {}",
                        plain(window.get("class")),
                        plain(window.get("title"))
                    ),
                    None => "no window".into(),
                };
                let label = if cwd.is_empty() {
                    command
                } else {
                    format!("{command} in {cwd}")
                };
                let mut entry = row(
                    format!("claim:{directory}"),
                    label.clone(),
                    directory.clone(),
                    size,
                    reclaim::lstat_time(&directory) as i64,
                    format!("live shell {pid}, {place}"),
                    false,
                    false,
                    true,
                    false,
                );
                entry.insert("holder".into(), json!(label));
                entry.insert(
                    "roots".into(),
                    json!(reclaim::glob_sorted(&directory)
                        .iter()
                        .map(|name| reclaim::join(&directory, name))
                        .collect::<Vec<_>>()),
                );
                if let Some(window) = window {
                    entry.insert(
                        "pid".into(),
                        window.get("pid").cloned().unwrap_or(Value::Null),
                    );
                }
                rows.push(entry);
            }
            return rows;
        }
        if let Some(text) = class_text(key) {
            let claims: Vec<(String, Vec<u32>)> = self
                .model
                .claims
                .iter()
                .filter(|claim| claim.class == key)
                .map(|claim| (claim.link.clone(), claim.found.clone()))
                .collect();
            let mut rows = Vec::new();
            let mut clients = None;
            for (link, found) in claims {
                let size: i64 = found.iter().map(|slot| self.store.size(*slot) as i64).sum();
                if size == 0 {
                    continue;
                }
                let used = if link.starts_with('/') && !link.starts_with("/proc/") {
                    reclaim::lstat_time(&link) as i64
                } else {
                    0
                };
                let why = self
                    .model
                    .protected
                    .get(&link)
                    .cloned()
                    .unwrap_or_else(|| "root".into());
                let process = if key == "processes" {
                    probe::link_pid(&link)
                } else {
                    None
                };
                let (label, kind, window) = match process {
                    Some(pid) => {
                        let clients = clients.get_or_insert_with(probe::hypr_clients);
                        let (command, cwd, window) =
                            probe::describe_shell(pid, &self.home, clients);
                        let label = if command.is_empty() {
                            format!("pid {pid} (exited)")
                        } else if cwd.is_empty() {
                            format!("{command} (pid {pid})")
                        } else {
                            format!("{command} in {cwd} (pid {pid})")
                        };
                        (label, probe::hold_text(&link).to_string(), window)
                    }
                    None => (short(&link, &self.home), format!("{text}: {why}"), None),
                };
                let mut entry = row(
                    format!("claim:{link}"),
                    label.clone(),
                    link.clone(),
                    size,
                    used,
                    kind,
                    false,
                    false,
                    true,
                    false,
                );
                if process.is_some() {
                    entry.insert("holder".into(), json!(label));
                } else {
                    entry.insert("roots".into(), json!([link]));
                }
                if let Some(window) = window {
                    entry.insert(
                        "pid".into(),
                        window.get("pid").cloned().unwrap_or(Value::Null),
                    );
                }
                rows.push(entry);
            }
            return rows;
        }
        match key {
            "recent" => {
                let members = self.members("segment:recent");
                self.path_rows(&members, "segment:recent", false, false)
            }
            "building" => self.dir_rows("/nix/store", "store"),
            "metadata" => {
                let mut rows = self.dir_rows("/nix", "files");
                rows.push(row(
                    "meta:links".into(),
                    "link table directory".into(),
                    "/nix/store/.links".into(),
                    self.store.links_blocks as i64,
                    0,
                    format!(
                        "directory entries for {} shared files",
                        self.store.shared_files()
                    ),
                    false,
                    false,
                    false,
                    false,
                ));
                let dirs = self
                    .tree
                    .find("/nix/store")
                    .map(|id| self.tree.node(id).dir_blocks as i64)
                    .unwrap_or(0);
                rows.push(row(
                    "meta:store".into(),
                    "store directory".into(),
                    "/nix/store".into(),
                    dirs,
                    0,
                    format!("directory entries for {} paths", self.store.count()),
                    false,
                    false,
                    false,
                    false,
                ));
                rows
            }
            "home_files" => {
                let mut rows = self.dir_rows("/home", "files");
                rows.extend(self.clone_store_row());
                rows
            }
            "system_files" => self
                .dir_rows("/", "files")
                .into_iter()
                .filter(|row| {
                    !matches!(
                        row.get("path").and_then(Value::as_str),
                        Some("/nix" | "/home" | "/tmp")
                    )
                })
                .collect(),
            "swap" => vec![row(
                "swap".into(),
                "/swapfile".into(),
                "/swapfile".into(),
                self.swap,
                0,
                "swap".into(),
                false,
                false,
                false,
                false,
            )],
            "held" => self
                .held
                .iter()
                .map(|held| {
                    row(
                        format!("held:{}", held.path),
                        short(&held.path, &self.home),
                        held.path.clone(),
                        held.size as i64,
                        if held.last_used > 1 {
                            held.last_used
                        } else {
                            0
                        },
                        format!("deleted, still {} by {}", held.how, held.holders.join(", ")),
                        false,
                        false,
                        false,
                        false,
                    )
                })
                .collect(),
            "filesystem" => {
                let mut rows: Vec<Map<String, Value>> = self
                    .internals
                    .iter()
                    .map(|(label, value)| {
                        row(
                            format!("fs:{label}"),
                            label.clone(),
                            String::new(),
                            *value as i64,
                            0,
                            internal_text(label).into(),
                            false,
                            false,
                            false,
                            false,
                        )
                    })
                    .collect();
                rows.push(row(
                    "fs:mounts".into(),
                    "mountpoints".into(),
                    String::new(),
                    4096 * self.mounts.len() as i64,
                    0,
                    format!("directories under {} mounts", self.mounts.len()),
                    false,
                    false,
                    false,
                    false,
                ));
                rows
            }
            "temp" => self.temp_rows(None),
            "agent" => self.agent_rows(),
            _ if Kind::from_name(key).map(Kind::key) == Some(key) => {
                let items = self.kind_items.get(key).cloned().unwrap_or_default();
                let mut rows = Vec::new();
                if key == "dead" && self.store.orphan_bytes != 0 {
                    rows.push(row(
                        "meta:orphans".into(),
                        "unused link table entries".into(),
                        "/nix/store/.links".into(),
                        self.store.orphan_bytes as i64,
                        0,
                        format!(
                            "{} files freed with the next deletion",
                            self.store.orphan_count
                        ),
                        true,
                        self.cut_rank >= 0,
                        false,
                        false,
                    ));
                }
                rows.extend(
                    items
                        .iter()
                        .map(|index| self.item_row(&self.model.items[*index])),
                );
                if key == "generation" {
                    let mut kept = self.segment_rows("previous");
                    for entry in kept.iter_mut() {
                        let boot = entry
                            .get("path")
                            .and_then(Value::as_str)
                            .is_some_and(|path| path.ends_with("/previous-successful-boot"));
                        entry.insert(
                            "kind".into(),
                            json!(if boot {
                                "previous successful boot"
                            } else {
                                "last generation"
                            }),
                        );
                    }
                    rows.extend(kept);
                }
                rows
            }
            _ => Vec::new(),
        }
    }

    fn closure_rows(&mut self, path: &str) -> Vec<Map<String, Value>> {
        let Some(slot) = self.store.slot(path) else {
            return Vec::new();
        };
        let owner = self.claim_of.get(&slot).copied();
        let scope: Rc<HashSet<u32>> = match &owner {
            Some(owner) => self.claim_set(owner),
            None => Rc::new([slot].into_iter().collect()),
        };
        let reclaimable = matches!(owner, Some(Owner::Item(_)));
        let scheduled = match &owner {
            Some(Owner::Item(index)) => self.is_planned(*index as usize),
            _ => false,
        };
        let mut assigned: HashSet<u32> = [slot].into_iter().collect();
        let mut itself = self.store_row(slot, reclaimable, scheduled);
        itself.insert("id".into(), json!(format!("self:{path}")));
        itself.insert(
            "label".into(),
            json!(format!("{} itself", short(path, &self.home))),
        );
        itself.insert("delvable".into(), json!(false));
        let mut rows = vec![itself];
        let mut references: Vec<u32> = self.store.get(slot).refs.clone();
        references.sort_by(|a, b| self.store.get(*a).path.cmp(&self.store.get(*b).path));
        for reference in references {
            if !scope.contains(&reference) || assigned.contains(&reference) {
                continue;
            }
            let mut stack = vec![reference];
            let mut group = Vec::new();
            while let Some(current) = stack.pop() {
                if assigned.contains(&current) || !scope.contains(&current) {
                    continue;
                }
                assigned.insert(current);
                group.push(current);
                stack.extend(self.store.get(current).refs.iter().copied());
            }
            let mut entry = self.store_row(reference, reclaimable, scheduled);
            entry.insert(
                "size".into(),
                json!(group
                    .iter()
                    .map(|member| self.store.size(*member) as i64)
                    .sum::<i64>()),
            );
            entry.insert(
                "kind".into(),
                json!(if group.len() > 1 {
                    format!("{} paths only reachable through it", group.len())
                } else {
                    "store path".into()
                }),
            );
            rows.push(entry);
        }
        rows
    }

    fn rows(&mut self, node_id: &str) -> Vec<Map<String, Value>> {
        let (kind, rest) = node_id.split_once(':').unwrap_or((node_id, ""));
        match kind {
            "segment" => self.segment_rows(rest),
            "item" => {
                let Some(index) = self.by_path.get(rest).copied() else {
                    return missing();
                };
                let scheduled = self.is_planned(index);
                let store = self.model.items[index].store.clone();
                let mut rows = self.path_rows(&store, node_id, true, scheduled);
                for path in self.model.items[index].files.clone() {
                    if self.tree.find(&path).is_some() {
                        rows.extend(self.dir_rows(&path, "item").into_iter().map(|mut row| {
                            row.insert("scheduled".into(), json!(scheduled));
                            row
                        }));
                    } else {
                        rows.push(row(
                            format!("file:{path}"),
                            short(&path, &self.home),
                            path.clone(),
                            self.tree.size(&path) as i64,
                            self.tree.newest(&path),
                            "file".into(),
                            true,
                            scheduled,
                            false,
                            true,
                        ));
                    }
                }
                rows
            }
            "claim" => {
                let members = self.members(node_id);
                self.path_rows(&members, node_id, false, false)
            }
            "family" => {
                let (owner_id, name) = rest.rsplit_once(':').unwrap_or(("", rest));
                let members: Vec<u32> = self
                    .members(owner_id)
                    .into_iter()
                    .filter(|slot| family(&short(&self.store.get(*slot).path, &self.home)) == name)
                    .collect();
                let reclaimable = owner_id.starts_with("item:");
                let scheduled = reclaimable && self.scheduled_item(&owner_id[5..]);
                members
                    .into_iter()
                    .map(|slot| self.store_row(slot, reclaimable, scheduled))
                    .collect()
            }
            "tmpfamily" => self.temp_rows(Some(rest)),
            "store" => self.closure_rows(rest),
            "dir" => {
                let (context, path) = rest.split_once(':').unwrap_or((rest, ""));
                self.dir_rows(path, context)
            }
            "loose" => {
                let (context, path) = rest.split_once(':').unwrap_or((rest, ""));
                self.loose_rows(path, context)
            }
            _ => missing(),
        }
    }

    fn history_payload(&mut self) -> String {
        if self.history_text.is_none() {
            let data = json!({"points": downsample(&self.points), "items": self.history_items});
            self.history_text = Some(json!({"id": "history", "data": data}).to_string());
        }
        self.history_text.clone().unwrap()
    }

    fn message(&mut self, watch: &Watch) -> String {
        let node_id = watch.id.as_str();
        match node_id {
            "overview" => self.overview_text.clone(),
            "history" => self.history_payload(),
            "events" => {
                if self.events_text.is_none() {
                    self.events_text =
                        Some(json!({"id": "events", "data": self.events}).to_string());
                }
                self.events_text.clone().unwrap()
            }
            "tracker" => json!({"id": node_id, "data": self.tracker()}).to_string(),
            _ if node_id.starts_with("taken:") => {
                json!({"id": node_id, "data": self.taken_rows(&node_id[6..])}).to_string()
            }
            _ if node_id.starts_with("rate:") => {
                json!({"id": node_id, "data": self.rate_rows(&node_id[5..])}).to_string()
            }
            _ => {
                let rows = self.ordered_rows(node_id);
                let count = rows.len();
                let data = if watch.slots == 0 {
                    rows
                } else {
                    self.bucket(rows, watch.slots, watch.total, node_id)
                };
                json!({"id": node_id, "count": count, "data": data}).to_string()
            }
        }
    }

    fn ordered_rows(&mut self, node_id: &str) -> Vec<Map<String, Value>> {
        if let Some(rest) = node_id.strip_prefix("slice:") {
            let mut parts = rest.splitn(3, ':');
            let from: usize = parts.next().and_then(|text| text.parse().ok()).unwrap_or(0);
            let to: usize = parts.next().and_then(|text| text.parse().ok()).unwrap_or(0);
            let inner = parts.next().unwrap_or("");
            let rows = self.ordered_rows(inner);
            if rows.first().is_some_and(|row| row.contains_key("missing")) {
                return rows;
            }
            return rows
                .into_iter()
                .skip(from)
                .take(to.saturating_sub(from))
                .collect();
        }
        let size = |row: &Map<String, Value>| row.get("size").and_then(Value::as_i64).unwrap_or(0);
        let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| self.rows(node_id)));
        match outcome {
            Ok(rows) => {
                let (mut rows, absent): (Vec<_>, Vec<_>) = rows
                    .into_iter()
                    .partition(|row| !row.contains_key("missing"));
                if !absent.is_empty() && rows.is_empty() {
                    return absent;
                }
                rows.retain(|row| size(row) > 0);
                rows.sort_by(|a, b| size(b).cmp(&size(a)));
                let used = |row: &Map<String, Value>| {
                    row.get("last_used").and_then(Value::as_f64).unwrap_or(0.0)
                };
                if !rows.is_empty() && rows.iter().all(|row| used(row) > 0.0) {
                    rows.sort_by(|a, b| used(a).total_cmp(&used(b)));
                }
                rows
            }
            Err(error) => {
                let text = error
                    .downcast_ref::<String>()
                    .cloned()
                    .or_else(|| error.downcast_ref::<&str>().map(|text| text.to_string()))
                    .unwrap_or_default();
                vec![probe::object(json!({"missing": true, "error": text}))]
            }
        }
    }

    fn bucket(
        &self,
        rows: Vec<Map<String, Value>>,
        slots: usize,
        total: i64,
        node_id: &str,
    ) -> Vec<Map<String, Value>> {
        if rows.first().is_some_and(|row| row.contains_key("missing")) {
            return rows;
        }
        let size = |row: &Map<String, Value>| row.get("size").and_then(Value::as_i64).unwrap_or(0);
        let used: i64 = rows.iter().map(size).sum();
        let whole = used.max(total).max(1) as f64;
        let floor = whole / slots as f64;
        let mut out = Vec::new();
        let mut pending: Vec<(usize, Map<String, Value>)> = Vec::new();
        let flush = |pending: &mut Vec<(usize, Map<String, Value>)>,
                     out: &mut Vec<Map<String, Value>>| {
            if pending.len() == 1 {
                let (at, mut row) = pending.pop().unwrap();
                row.insert("at".into(), json!(at));
                out.push(row);
            } else if pending.len() > 1 {
                out.push(self.group(std::mem::take(pending), node_id));
            }
        };
        for (at, mut row) in rows.into_iter().enumerate() {
            if size(&row) as f64 >= floor {
                flush(&mut pending, &mut out);
                row.insert("at".into(), json!(at));
                out.push(row);
            } else {
                pending.push((at, row));
            }
        }
        flush(&mut pending, &mut out);
        out
    }

    fn group(
        &self,
        members: Vec<(usize, Map<String, Value>)>,
        node_id: &str,
    ) -> Map<String, Value> {
        let flag = |row: &Map<String, Value>, key: &str| {
            row.get(key).and_then(Value::as_bool).unwrap_or(false)
        };
        let from = members[0].0;
        let to = members[members.len() - 1].0 + 1;
        let count = members.len();
        let size: i64 = members
            .iter()
            .map(|(_, row)| row.get("size").and_then(Value::as_i64).unwrap_or(0))
            .sum();
        let paths: Vec<&str> = members
            .iter()
            .filter_map(|(_, row)| row.get("path").and_then(Value::as_str))
            .filter(|path| self.history_paths.contains(*path))
            .collect();
        let mut out = row(
            format!("slice:{from}:{to}:{node_id}"),
            format!("{count} small items"),
            String::new(),
            size,
            members[0]
                .1
                .get("last_used")
                .and_then(Value::as_i64)
                .unwrap_or(0),
            format!("{count} items, each too small to draw"),
            members.iter().all(|(_, row)| flag(row, "reclaimable")),
            members.iter().all(|(_, row)| flag(row, "scheduled")),
            true,
            false,
        );
        out.insert("from".into(), json!(from));
        out.insert("to".into(), json!(to));
        out.insert("count".into(), json!(count));
        out.insert("paths".into(), json!(paths));
        out
    }

    fn accept(&mut self) {
        while let Ok((stream, _)) = self.server.accept() {
            let _ = stream.set_nonblocking(false);
            let _ = stream.set_write_timeout(Some(Duration::from_millis(500)));
            self.clients.insert(
                stream.as_raw_fd(),
                Client {
                    stream,
                    buffer: Vec::new(),
                    watches: Vec::new(),
                    sent: HashMap::new(),
                    events_upto: None,
                },
            );
        }
    }

    fn receive(&mut self, fd: i32) {
        let Some(client) = self.clients.get_mut(&fd) else {
            return;
        };
        let mut data = [0u8; 65536];
        let count = client.stream.read(&mut data).unwrap_or(0);
        if count == 0 {
            self.clients.remove(&fd);
            return;
        }
        client.buffer.extend_from_slice(&data[..count]);
        let mut subscribed = false;
        let mut retarget = None;
        let viewed = self.viewed.get();
        while let Some(end) = client.buffer.iter().position(|byte| *byte == b'\n') {
            let line: Vec<u8> = client.buffer.drain(..=end).collect();
            let line = &line[..line.len() - 1];
            let request: Value = serde_json::from_slice(line)
                .unwrap_or_else(|_| json!({"watch": [String::from_utf8_lossy(line).trim()]}));
            if let Some(gib) = request.get("target").and_then(Value::as_f64) {
                retarget = Some(gib);
            }
            if let Some(list) = request.get("watch").and_then(Value::as_array) {
                client.watches = list.iter().take(WATCHES).map(Watch::parse).collect();
                let keys: HashSet<String> = client.watches.iter().map(Watch::key).collect();
                client.sent.retain(|key, _| keys.contains(key));
                if !keys.contains("events") {
                    client.events_upto = None;
                }
                subscribed = true;
            }
        }
        if let Some(gib) = retarget {
            self.target_bytes = (gib * GIB as f64) as i64;
            self.target_at = clock();
            self.collected_at = 0.0;
        }
        if subscribed {
            if !viewed && self.viewed() {
                self.catch_up();
            }
            self.push(fd);
        }
    }

    fn set_overview(&mut self, overview: Value) -> bool {
        let text = json!({"id": "overview", "data": overview}).to_string();
        self.overview = overview;
        if text == self.overview_text {
            return false;
        }
        self.overview_text = text;
        true
    }

    fn stamp(&self) -> [u64; 6] {
        [
            self.tree.revision,
            self.model_version,
            self.cut_rank as u64
                ^ (self.next_rank as u64) << 52
                ^ (self.planned.iter().filter(|flag| **flag).count() as u64) << 20
                ^ (self.deleting.len() as u64) << 40
                ^ (self.lagging.len() as u64) << 32
                ^ self.batch << 8,
            self.files_at.to_bits(),
            self.held_at.to_bits(),
            self.recorded,
        ]
    }

    fn render(&mut self, watch: &Watch) -> Rc<(String, u64)> {
        let key = watch.key();
        let fixed = matches!(
            watch.id.as_str(),
            "overview" | "history" | "events" | "tracker"
        );
        let stamp = self.stamp();
        if let Some((at, seen, entry)) = self.rendered.get(&key) {
            if !fixed && *seen == stamp && clock() - at < RENDER_SECONDS {
                return entry.clone();
            }
        }
        let text = self.message(watch);
        let hash = digest(&text);
        let entry = Rc::new((text, hash));
        if !fixed {
            self.rendered.insert(key, (clock(), stamp, entry.clone()));
        }
        entry
    }

    fn push(&mut self, fd: i32) -> bool {
        let watches = match self.clients.get(&fd) {
            Some(client) => client.watches.clone(),
            None => return false,
        };
        for watch in watches {
            if watch.id == "events" {
                if !self.push_events(fd) {
                    return false;
                }
                continue;
            }
            let node_id = watch.key();
            let entry = self.render(&watch);
            let Some(client) = self.clients.get_mut(&fd) else {
                return false;
            };
            if client.sent.get(&node_id) == Some(&entry.1) {
                continue;
            }
            let mut line = entry.0.clone().into_bytes();
            line.push(b'\n');
            if client.stream.write_all(&line).is_err() {
                self.clients.remove(&fd);
                return false;
            }
            client.sent.insert(node_id, entry.1);
        }
        true
    }

    fn push_events(&mut self, fd: i32) -> bool {
        let first = self.events.first().map(seq_of).unwrap_or(self.next_seq);
        let upto = match self.clients.get(&fd) {
            Some(client) => client.events_upto,
            None => return false,
        };
        let line = match upto {
            Some(upto) if upto == self.next_seq => return true,
            Some(upto) if upto >= first => {
                let start = self.events.partition_point(|event| seq_of(event) < upto);
                json!({"id": "events", "append": &self.events[start..]}).to_string()
            }
            _ => {
                if self.events_text.is_none() {
                    self.events_text =
                        Some(json!({"id": "events", "data": self.events}).to_string());
                }
                self.events_text.clone().unwrap()
            }
        };
        let next = self.next_seq;
        let Some(client) = self.clients.get_mut(&fd) else {
            return false;
        };
        let mut bytes = line.into_bytes();
        bytes.push(b'\n');
        if client.stream.write_all(&bytes).is_err() {
            self.clients.remove(&fd);
            return false;
        }
        client.events_upto = Some(next);
        true
    }

    fn push_changes(&mut self) {
        self.push_all();
        if let Some(from) = self.tree.settled_from.take() {
            self.latencies.push_back(clock() - from);
            if self.latencies.len() > 64 {
                self.latencies.pop_front();
            }
        }
    }

    fn push_all(&mut self) {
        let watched: HashSet<String> = self
            .clients
            .values()
            .flat_map(|client| client.watches.iter().map(Watch::key))
            .collect();
        self.rendered.retain(|key, _| watched.contains(key));
        let fds: Vec<i32> = self.clients.keys().copied().collect();
        for fd in fds {
            self.push(fd);
        }
    }

    fn history_tick(&mut self, overview: &Value) {
        let now = sys::now() as i64;
        let last = self
            .points
            .last()
            .map(|point| number(point.get("at")))
            .unwrap_or(0);
        if now - last < HISTORY_SECONDS {
            return;
        }
        if number(overview.get("residual")) != 0
            && now - last < HISTORY_SECONDS + HISTORY_LATE_SECONDS
        {
            return;
        }
        let mut segments = Map::new();
        for row in overview["segments"].as_array().into_iter().flatten() {
            let bytes = number(row.get("bytes"));
            if bytes != 0 {
                segments.insert(row["key"].as_str().unwrap_or("").to_string(), json!(bytes));
            }
        }
        let free = number(overview.get("free"));
        let total = number(overview["disk"].get("total"));
        if segments
            .values()
            .map(|value| value.as_i64().unwrap_or(0))
            .sum::<i64>()
            + free
            != total
        {
            return;
        }
        self.points
            .push(json!({"v": 2, "at": now, "segments": segments, "free": free, "total": total}));
        self.points
            .retain(|point| number(point.get("at")) >= now - HISTORY_DAYS * DAY);
        self.save_history(&self.points);
        let mut items = Map::new();
        for key in [
            "dead",
            "cache",
            "temp",
            "stray",
            "build",
            "project",
            "generation",
            "agent",
            "trash",
            "home_files",
        ] {
            let mut members: Vec<&Item> = folded(key)
                .into_iter()
                .flat_map(|part| self.kind_items.get(part).into_iter().flatten())
                .map(|index| &self.model.items[*index])
                .collect();
            members.sort_by(|a, b| b.freed().cmp(&a.freed()));
            if !members.is_empty() {
                items.insert(
                    key.into(),
                    Value::Object(
                        members
                            .iter()
                            .take(HISTORY_ITEMS)
                            .map(|item| (item.path.clone(), json!(item.freed())))
                            .collect(),
                    ),
                );
            }
        }
        if let Ok(mut handle) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.state.join("history-items.jsonl"))
        {
            let _ = writeln!(handle, "{}", json!({"at": now, "items": items}));
        }
        self.load_history_items();
    }

    fn load_history_items(&mut self) {
        let sampled: HashSet<i64> = downsample(&self.points)
            .iter()
            .map(|point| number(point.get("at")))
            .collect();
        let mut items = Map::new();
        if let Ok(text) = std::fs::read_to_string(self.state.join("history-items.jsonl")) {
            for line in text.lines() {
                let Ok(entry) = serde_json::from_str::<Value>(line) else {
                    continue;
                };
                let at = number(entry.get("at"));
                if sampled.contains(&at) {
                    items.insert(
                        at.to_string(),
                        entry.get("items").cloned().unwrap_or(Value::Null),
                    );
                }
            }
        }
        self.history_paths = items
            .values()
            .filter_map(Value::as_object)
            .flat_map(|point| point.values())
            .filter_map(Value::as_object)
            .flat_map(|segment| segment.keys().cloned())
            .collect();
        self.history_items = Value::Object(items);
        self.history_text = None;
    }

    fn write_outputs(&self, overview: &Value) {
        if self.clients.is_empty() {
            let mut ledger = overview.as_object().cloned().unwrap_or_default();
            ledger.extend(probe::object(self.tracker()));
            ledger.insert("history".into(), json!(downsample(&self.points)));
            ledger.insert(
                "events".into(),
                json!(self.events[self.events.len().saturating_sub(EVENTS_DUMPED)..]),
            );
            let _ = probe::write_file(
                &self.runtime.join("disk-ledger.json"),
                &format!("{}\n", Value::Object(ledger)),
                Some(self.owner),
            );
        }
        if self
            .textfile
            .parent()
            .map(|parent| parent.is_dir())
            .unwrap_or(false)
        {
            let mut lines = vec!["# TYPE node_disk_ledger_bytes gauge".to_string()];
            for row in overview["segments"].as_array().into_iter().flatten() {
                lines.push(format!(
                    "node_disk_ledger_bytes{{segment=\"{}\",group=\"{}\"}} {}",
                    plain(row.get("key")),
                    plain(row.get("group")),
                    number(row.get("bytes"))
                ));
            }
            for key in ["free", "target", "reclaimable"] {
                lines.push(format!(
                    "node_disk_ledger_bytes{{segment=\"{key}\",group=\"disk\"}} {}",
                    number(overview.get(key))
                ));
            }
            let _ = probe::write_file(&self.textfile, &(lines.join("\n") + "\n"), None);
        }
    }

    fn urgency(&self, deficit: i64, free: i64) -> f64 {
        if free < self.emergency {
            return 1.0;
        }
        (deficit as f64 / RAMP as f64).min(1.0)
    }

    fn set_status(&mut self, status: Map<String, Value>) {
        if stripped(&status) != stripped(&self.status) {
            let mut status = status;
            status.insert("last".into(), self.last_event.clone());
            self.status = status;
        }
    }

    fn available(&self, item: &reclaim::Item) -> bool {
        if self.skipped.contains_key(&item.path) {
            return false;
        }
        let slots = if item.kind == Kind::Dead {
            &item.targets
        } else {
            &item.store
        };
        if slots.iter().any(|slot| self.store.is_held(*slot)) {
            return false;
        }
        if item.kind == Kind::Dead {
            item.targets.iter().any(|slot| self.store.get(*slot).alive)
        } else {
            reclaim::lexists(&item.path)
        }
    }

    fn handled(&self, path: &str) -> bool {
        self.lagging.contains_key(path)
            || self.deleting.contains(path)
            || self.handed.iter().any(|handed| handed == path)
    }

    fn eligible(&self, index: usize) -> bool {
        let item = &self.model.items[index];
        item.freed() > 0 && !self.handled(&item.path) && self.available(item)
    }

    fn next_item(&mut self) -> Option<usize> {
        if self.cursor.0 != self.ranking {
            self.cursor = (self.ranking, 0);
        }
        while self.cursor.1 < self.model.items.len() {
            if self.eligible(self.cursor.1) {
                return Some(self.cursor.1);
            }
            self.cursor.1 += 1;
        }
        None
    }

    fn arrow(&mut self) -> i64 {
        let waiting = self
            .handed
            .iter()
            .find(|path| !self.deleting.contains(*path))
            .and_then(|path| self.by_path.get(path).copied());
        waiting
            .or_else(|| self.next_item())
            .map_or(-1, |index| index as i64)
    }

    fn handed_bytes(&self) -> i64 {
        self.handed
            .iter()
            .filter_map(|path| self.by_path.get(path))
            .map(|index| self.model.items[*index].freed() as i64)
            .sum()
    }

    fn task(&self, index: usize, level: f64) -> sweep::Task {
        let item = &self.model.items[index];
        let slots: Vec<u32> = if item.kind == Kind::Dead {
            &item.targets
        } else {
            &item.store
        }
        .iter()
        .copied()
        .filter(|slot| self.store.get(*slot).alive)
        .collect();
        let (ordered, references) = if slots.is_empty() {
            (Vec::new(), HashMap::new())
        } else {
            self.store.deletion_plan(&slots)
        };
        let name = |slot: &u32| self.store.get(*slot).path.clone();
        let mut work = Work::of(item);
        work.store = slots.iter().map(name).collect();
        sweep::Task {
            work,
            ordered: ordered.iter().map(name).collect(),
            references: references
                .iter()
                .map(|(slot, refs)| (name(slot), refs.iter().map(name).collect()))
                .collect(),
            orphans: if self.session_open {
                Vec::new()
            } else {
                self.store.orphans.clone()
            },
            scope: self.model.scope(),
            level,
        }
    }

    fn hand(&mut self, index: usize, level: f64) {
        let task = self.task(index, level);
        let path = task.work.path.clone();
        if self
            .commands
            .send(sweep::Command::Item(Box::new(task)))
            .is_ok()
        {
            self.handed.push(path);
            self.session_open = true;
            self.close_sent = false;
        }
    }

    fn collect(&mut self, now: f64) {
        let free = statfs().free;
        let target = self.target() + MARGIN;
        let deficit = target - free;
        let base = probe::object(
            json!({"at": sys::now() as i64, "target": target, "free": free, "deficit": deficit.max(0), "collecting": self.collecting}),
        );
        let with = |extra: Value| -> Map<String, Value> {
            let mut status = base.clone();
            status.extend(probe::object(extra));
            status
        };
        if !self.collecting {
            if self.planning && now - self.planned_at >= PLAN_SECONDS {
                self.planned_at = now;
                let planned = self.planned.iter().filter(|flag| **flag).count();
                self.set_status(with(json!({"state": "planned", "items": planned, "cut": self.cut_rank, "next": self.next_rank})));
            } else if !self.planning {
                self.set_status(with(json!({"state": "observing"})));
            }
            return;
        }
        self.skipped.retain(|_, until| *until > now);
        while self.handed.len() < LOOKAHEAD {
            let merged = self.model.merged.iter().copied().find(|index| {
                let item = &self.model.items[*index];
                self.by_path.contains_key(&item.path)
                    && !self.handled(&item.path)
                    && !self.skipped.contains_key(&item.path)
                    && reclaim::is_dir(&item.path)
            });
            if let Some(index) = merged {
                self.hand(index, 0.0);
                continue;
            }
            if deficit - self.handed_bytes() <= 0 {
                break;
            }
            let Some(index) = self.next_item() else {
                break;
            };
            self.level = self.urgency(deficit, free);
            self.hand(index, self.level);
        }
        if !self.handed.is_empty() {
            let head: Vec<&String> = self.handed.iter().collect();
            self.set_status(with(json!({"state": "collecting", "urgency": self.level, "handed": head, "deleting": self.deleting.iter().next()})));
        } else if deficit > 0 {
            self.set_status(with(json!({"state": "exhausted"})));
        } else {
            if self.session_open && !self.close_sent {
                self.close_sent = self.commands.send(sweep::Command::Close).is_ok();
            }
            if !self.session_open {
                gc::idle();
            }
            self.set_status(with(json!({"state": "idle"})));
        }
    }

    fn tombstone(&mut self, index: usize) {
        let item = &mut self.model.items[index];
        self.by_path.remove(&item.path);
        if let Some(list) = self.kind_items.get_mut(item.kind.key()) {
            if let Ok(position) = list.binary_search(&index) {
                list.remove(position);
            }
        }
        for slot in item.store.drain(..) {
            if self.claim_of.get(&slot) == Some(&Owner::Item(index as u32)) {
                self.claim_of.remove(&slot);
            }
        }
        item.targets.clear();
        item.files.clear();
        item.links.clear();
        item.store_bytes = 0;
        item.file_bytes = 0;
        if let Some(flag) = self.planned.get_mut(index) {
            *flag = false;
        }
        self.claim_sets.clear();
        self.model_version += 1;
        self.sums_dirty = true;
    }

    fn gone(&self, item: &Item) -> bool {
        let slots = if item.kind == Kind::Dead {
            &item.targets
        } else {
            &item.store
        };
        slots.iter().all(|slot| !self.store.get(*slot).alive)
            && item.files.iter().all(|path| !reclaim::lexists(path))
            && (item.kind != Kind::Dead || item.links.iter().all(|link| !reclaim::lexists(link)))
    }

    fn settle_lagging(&mut self) {
        if self.lagging.is_empty() {
            return;
        }
        let now = clock();
        let mut settled: Vec<(String, Option<usize>)> = Vec::new();
        for (path, (since, _)) in &self.lagging {
            match self.by_path.get(path).copied() {
                None => settled.push((path.clone(), None)),
                Some(index) if self.gone(&self.model.items[index]) => {
                    settled.push((path.clone(), Some(index)))
                }
                Some(_) if now - since >= LAGGING_SECONDS => settled.push((path.clone(), None)),
                Some(_) => {}
            }
        }
        for (path, index) in settled {
            self.lagging.remove(&path);
            if let Some(index) = index {
                self.tombstone(index);
            }
        }
    }

    fn note(&mut self, mut detail: Value) {
        detail["at"] = json!(sys::now());
        if let Some(index) = detail["path"]
            .as_str()
            .and_then(|path| self.by_path.get(path))
        {
            detail["rank"] = json!(index);
            detail["ranking"] = json!(self.ranking);
        }
        self.swept.push_back(detail);
        if self.swept.len() > SWEPT {
            self.swept.pop_front();
        }
    }

    fn drain_sweep(&mut self) {
        let mut buffer = [0u8; 64];
        unsafe {
            libc::read(
                self.wake_read,
                buffer.as_mut_ptr() as *mut libc::c_void,
                buffer.len(),
            )
        };
        while let Ok(event) = self.sweep_events.try_recv() {
            self.batch += 1;
            match event {
                sweep::Event::Begun(path) => {
                    self.deleting.insert(path);
                }
                sweep::Event::Done(path, detail) => {
                    self.note(detail);
                    self.deleting.remove(&path);
                    self.handed.retain(|other| *other != path);
                    self.lagging.insert(path, (clock(), self.batch));
                }
                sweep::Event::Refused(path, reason) => {
                    self.note(json!({"path": path, "refused": reason}));
                    self.deleting.remove(&path);
                    self.handed.retain(|other| *other != path);
                    self.skipped.insert(path, clock() + SKIP_SECONDS);
                }
                sweep::Event::Closed(summary) => {
                    self.session_open = false;
                    self.close_sent = false;
                    self.record(summary);
                }
            }
        }
        self.settle_lagging();
    }

    fn watch_exits(&mut self) {
        let wanted: HashSet<i32> = self.store.runtime_pids.iter().copied().collect();
        self.exits.retain(|pid, fd| {
            let keep = wanted.contains(pid);
            if !keep {
                sys::close(*fd);
            }
            keep
        });
        for pid in wanted {
            if let std::collections::hash_map::Entry::Vacant(slot) = self.exits.entry(pid) {
                let fd = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) };
                if fd >= 0 {
                    slot.insert(fd as i32);
                }
            }
        }
    }

    fn viewed(&self) -> bool {
        let viewed = self
            .clients
            .values()
            .any(|client| !client.watches.is_empty());
        self.viewed.set(viewed);
        viewed
    }

    fn catch_up(&mut self) {
        self.drain_tree();
        self.tree.floor = tree::SETTLE;
        self.tree.settle(clock() + CATCH_UP, true);
        self.model.measure_files(&TreeFiles(&self.tree));
        self.files_total = Some(self.tree.node(self.tree.root).total);
        self.files_at = clock();
        let mut overview = self.build_overview();
        if number(overview.get("residual")) != 0 && self.tree.dirty.is_empty() {
            self.held = probe::held_open(self.device);
            self.held_at = clock();
            overview = self.build_overview();
            self.held_residual = number(overview.get("residual"));
        }
        self.set_overview(overview);
        self.pushed = clock();
    }

    fn busy(&self) -> bool {
        !self.store.pending.is_empty()
            || !self.tree.dirty.is_empty()
            || !self.store_dirty.is_empty()
            || self.links_dirty.is_some()
            || self.scanning.is_some()
            || self.model_dirty
            || self.sums_dirty
            || self.roots_due.is_some()
    }

    fn drain_tree(&mut self) {
        let resolver = &mut self.resolver;
        let store = &self.store;
        let store_dirty = &mut self.store_dirty;
        let links_dirty = &mut self.links_dirty;
        self.tree.drain(|key| {
            let Some(path) = resolver.as_mut().and_then(|resolver| resolver.path(key)) else {
                return;
            };
            if path.starts_with("/nix/store/.links") {
                if links_dirty.is_none() {
                    *links_dirty = Some(clock());
                }
                return;
            }
            if let Some(found) = tree::store_path(&path) {
                if store
                    .slot(&found)
                    .map(|slot| store.get(slot).alive)
                    .unwrap_or(false)
                    && !store_dirty.contains_key(&found)
                {
                    store_dirty.insert(found, clock());
                }
            }
        });
        let root_dirs: Vec<u32> = [
            "/nix/var/nix/gcroots",
            "/nix/var/nix/profiles",
            store::TEMP_ROOTS,
        ]
        .iter()
        .filter_map(|path| self.tree.find(path))
        .collect();
        let under_roots = |mut id: u32| loop {
            if root_dirs.contains(&id) {
                return true;
            }
            if id == tree::NONE {
                return false;
            }
            id = self.tree.nodes[id as usize].parent;
        };
        if self.tree.dirty.keys().any(|id| under_roots(*id)) {
            self.store.hold_temp_roots();
            for target in store::directory_roots("/nix/var/nix").keys() {
                self.store.hold(target);
            }
            self.roots_due = self.roots_due.or(Some(clock()));
        }
    }

    fn sync_registered(&mut self) {
        self.handover.extend(self.store.journal.drain(..));
        let store = &self.store;
        let settled = |(path, alive): &(String, bool)| {
            if *alive {
                store
                    .slot(path)
                    .is_none_or(|slot| !store.pending.contains(&slot))
            } else {
                !Path::new(path).exists()
            }
        };
        let (ready, waiting): (Vec<(String, bool)>, Vec<(String, bool)>) =
            self.handover.drain(..).partition(settled);
        self.handover = waiting;
        if ready.is_empty() {
            return;
        }
        let mut registered = self
            .registered
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        for (path, alive) in ready {
            let Some(name) = path.strip_prefix("/nix/store/").map(String::from) else {
                continue;
            };
            if alive {
                registered.insert(name);
            } else {
                registered.remove(&name);
            }
        }
        drop(registered);
        if let Some(id) = self.tree.find("/nix/store") {
            self.tree.mark(id);
        }
    }

    fn step(&mut self) {
        let now = clock();
        let viewed = self.viewed();
        self.tree.floor = if viewed { tree::SETTLE } else { IDLE_SETTLE };
        let mut laps = Laps {
            at: now,
            list: Vec::new(),
        };
        if now - self.db_checked >= DB_SECONDS {
            self.db_checked = now;
            let (changed, added) = self.store.load();
            if added {
                self.roots_due = self.roots_due.or(Some(now));
            }
            self.sums_dirty |= changed;
            if changed {
                self.settle_lagging();
            }
        }
        laps.lap("load");
        if !self.store.pending.is_empty()
            && self
                .store
                .walk_pending(std::time::Instant::now() + Duration::from_millis(50))
                > 0
        {
            self.sums_dirty = true;
        }
        laps.lap("walk");
        if !self.store.journal.is_empty() || !self.handover.is_empty() {
            self.sync_registered();
        }
        laps.lap("db");
        let ready: Vec<String> = self
            .store_dirty
            .iter()
            .filter(|(_, since)| now - **since >= STORE_SETTLE)
            .map(|(path, _)| path.clone())
            .collect();
        if !ready.is_empty() {
            self.store.begin();
            for path in ready.iter().take(200) {
                self.store_dirty.remove(path);
                if let Some(slot) = self.store.slot(path) {
                    if self.store.get(slot).alive && self.store.measure(slot) {
                        self.sums_dirty = true;
                    }
                }
            }
            self.store.commit();
        }
        laps.lap("store");
        if self
            .scanning
            .as_ref()
            .is_some_and(|scanning| scanning.is_finished())
        {
            if let Some(Ok(scan)) = self.scanning.take().map(|scanning| scanning.join()) {
                let store = &mut self.store;
                self.links_cost = timed(|| store.apply_links(&scan));
                self.sums_dirty = true;
            }
        }
        if let (Some(since), None) = (self.links_dirty, &self.scanning) {
            if now - since >= LINKS_FLOOR.max(COST_FACTOR * self.links_cost) {
                self.links_dirty = None;
                self.scanning = Some(scan_links(self.links_file.clone()));
            }
        }
        laps.lap("links");
        self.tree.settle(now + 0.05, false);
        laps.lap("settle");
        if now - self.verified_at >= VERIFY_PERIOD {
            self.verified_at = now;
            self.tree.verify(clock() + VERIFY_SECONDS);
        }
        laps.lap("verify");
        if self
            .roots_due
            .map(|due| now - due >= MODEL_FLOOR.max(COST_FACTOR * self.roots_cost))
            .unwrap_or(false)
            || now - self.roots_at >= ROOTS_SECONDS
        {
            let store = &mut self.store;
            self.roots_cost = timed(|| store.refresh_roots());
            self.roots_at = clock();
            self.roots_due = None;
            self.model_dirty = true;
            self.watch_exits();
        }
        laps.lap("roots");
        if (self.model_dirty
            && now - self.model_at >= MODEL_FLOOR.max(COST_FACTOR * self.model_cost))
            || now - self.model_at >= MODEL_SECONDS
        {
            self.refresh_model();
            self.model_at = clock();
            self.model_dirty = false;
        }
        laps.lap("model");
        if self.sums_dirty && now - self.sums_at >= SUMS_FLOOR.max(COST_FACTOR * self.sums_cost) {
            let started = clock();
            self.store_sums();
            self.sums_cost = clock() - started;
            self.sums_at = clock();
            self.sums_dirty = false;
        }
        laps.lap("sums");
        let total = self.tree.node(self.tree.root).total;
        if Some(total) != self.files_total
            && now - self.files_at
                >= (if viewed { FILES_FLOOR } else { IDLE_FILES })
                    .max(COST_FACTOR * self.files_cost)
        {
            let started = clock();
            self.model.measure_files(&TreeFiles(&self.tree));
            self.files_cost = clock() - started;
            self.files_at = clock();
            self.files_total = Some(total);
        }
        laps.lap("files");
        if now - self.internals_at >= INTERNALS_SECONDS {
            self.internals = probe::hidden_inodes(&self.source);
            self.internals_at = now;
        }
        if now - self.xattr_at >= INTERNALS_SECONDS {
            let acl = self.tree.acl_dirs();
            self.xattr = probe::shared_xattr_blocks(&acl, &self.source, sys::statvfs("/").block);
            self.xattr_dirs = Some(acl);
            self.xattr_at = now;
        }
        laps.lap("probes");
        self.collect(now);
        laps.lap("collect");
        if self.opens.is_some() && self.store.touched_count() >= 1000 {
            self.store.flush_used();
        }
        if now - self.pushed >= if viewed { PUSH_SECONDS } else { IDLE_PUSH } {
            let mut overview = self.build_overview();
            if number(overview.get("residual")) != 0 && self.tree.dirty.is_empty() {
                self.drain_tree();
                if !self.tree.dirty.is_empty() {
                    overview = self.build_overview();
                }
            }
            let residual = number(overview.get("residual"));
            if (residual != 0
                && residual != self.held_residual
                && self.tree.dirty.is_empty()
                && now - self.held_at >= HELD_FLOOR)
                || now - self.held_at >= HELD_SECONDS
            {
                self.held = probe::held_open(self.device);
                self.held_at = clock();
                overview = self.build_overview();
                self.held_residual = number(overview.get("residual"));
            }
            let changed =
                self.set_overview(overview) | (self.tree.revision != self.pushed_revision);
            self.pushed_revision = self.tree.revision;
            self.pushed = clock();
            if changed {
                self.push_changes();
            }
            let overview = std::mem::take(&mut self.overview);
            self.history_tick(&overview);
            if now - self.written_at >= if viewed { FILE_SECONDS } else { IDLE_WRITE } && changed {
                self.write_outputs(&overview);
                self.written_at = now;
                if self.store.touched_count() > 0 {
                    self.store.flush_used();
                }
            }
            self.overview = overview;
        } else if viewed && self.tree.revision != self.pushed_revision {
            self.pushed_revision = self.tree.revision;
            self.push_changes();
        }
        laps.lap("push");
        let total = laps.list.iter().map(|(_, seconds)| seconds).sum::<f64>();
        if total >= SLOW_STEP {
            let (phase, seconds) = laps
                .list
                .iter()
                .copied()
                .max_by(|a, b| a.1.total_cmp(&b.1))
                .unwrap_or(("", 0.0));
            self.slow
                .push_back((sys::now() as i64, phase, seconds, total));
            if self.slow.len() > 32 {
                self.slow.pop_front();
            }
        }
    }

    pub fn run(&mut self) {
        self.load_history_items();
        self.watch_exits();
        self.cut_rank = -1;
        let overview = self.build_overview();
        self.write_outputs(&overview);
        self.set_overview(overview);
        eprintln!("first overview at {:.3}s", clock() - 1.0);
        loop {
            let viewed = self.viewed();
            let mut fds = vec![self.server.as_raw_fd(), self.wake_read];
            fds.extend(self.clients.keys().copied());
            fds.extend(self.exits.values().copied());
            if viewed && clock() - self.drained_at >= DRAIN_PAUSE {
                fds.push(self.tree.fd);
                fds.extend(self.model.builds.fd);
            }
            let timeout = match (viewed, self.tree.next_due()) {
                (true, Some(due)) => ((due - clock()) * 1000.0).ceil().clamp(0.0, 50.0) as i32,
                (true, None) if self.busy() => 50,
                _ => 1000,
            };
            let paused = DRAIN_PAUSE - (clock() - self.drained_at);
            let timeout = if viewed && paused > 0.0 {
                timeout.min((paused * 1000.0).ceil() as i32)
            } else {
                timeout
            };
            let timeout = if self.frame_due {
                timeout.min(((FRAME - (clock() - self.pushed)) * 1000.0).ceil().max(0.0) as i32)
            } else {
                timeout
            };
            let readable: HashSet<i32> = sys::poll(&fds, timeout).into_iter().collect();
            if readable.contains(&self.tree.fd)
                || !viewed
                || clock() - self.drained_at >= DRAIN_PAUSE
            {
                self.drain_tree();
                self.drained_at = clock();
            }
            let store = &mut self.store;
            let mut opened_dead = false;
            let mut execs: HashSet<i32> = HashSet::new();
            if let Some(opens) = self.opens.as_mut() {
                opens.drain(|path, when, pid, exec| {
                    opened_dead |= store.slot(path).is_some_and(|slot| !store.is_live(slot));
                    store.hold(path);
                    if exec {
                        execs.insert(pid);
                    }
                    store.touch(path, when)
                });
            }
            for pid in execs {
                store.hold_pid(pid);
            }
            let exited: Vec<i32> = self
                .exits
                .iter()
                .filter(|(_, fd)| readable.contains(fd))
                .map(|(pid, _)| *pid)
                .collect();
            for pid in &exited {
                if let Some(fd) = self.exits.remove(pid) {
                    sys::close(fd);
                }
            }
            if opened_dead || !exited.is_empty() {
                self.roots_due = self.roots_due.or(Some(clock()));
            }
            self.model.builds.drain();
            if readable.contains(&self.server.as_raw_fd()) {
                self.accept();
            }
            let ready: Vec<i32> = readable
                .iter()
                .copied()
                .filter(|fd| self.clients.contains_key(fd))
                .collect();
            for fd in ready {
                self.receive(fd);
            }
            if readable.contains(&self.wake_read) {
                self.drain_sweep();
                self.collect(clock());
                self.frame_due |= self.viewed();
            }
            if self.frame_due && clock() - self.pushed >= FRAME {
                self.frame_due = false;
                let overview = self.build_overview();
                if self.set_overview(overview) {
                    self.push_changes();
                }
                self.pushed = clock();
            }
            self.step();
        }
    }
}

extern "C" {
    fn tzset();
}

fn scan_links(file: String) -> std::thread::JoinHandle<gc::LinkScan> {
    std::thread::spawn(move || {
        let scan = gc::scan_links(store::LINKS);
        if scan.complete {
            let _ = gc::publish(&file, &scan.entries);
        }
        scan
    })
}

fn stripped(map: &Map<String, Value>) -> BTreeMap<&String, &Value> {
    map.iter()
        .filter(|(key, _)| *key != "at" && *key != "last")
        .collect()
}

fn percentile(values: &VecDeque<f64>, fraction: f64) -> f64 {
    let mut sorted: Vec<f64> = values.iter().copied().collect();
    sorted.sort_by(f64::total_cmp);
    sorted
        .get(((sorted.len() as f64 - 1.0) * fraction).round() as usize)
        .copied()
        .unwrap_or(0.0)
}

fn rss() -> u64 {
    std::fs::read_to_string("/proc/self/statm")
        .ok()
        .and_then(|text| {
            text.split_whitespace()
                .nth(1)
                .and_then(|pages| pages.parse::<u64>().ok())
        })
        .map(|pages| pages * 4096)
        .unwrap_or(0)
}

fn listen(runtime: &std::path::Path, owner: u32) -> std::io::Result<UnixListener> {
    let path = runtime.join("disk-tree.sock");
    let _ = std::fs::remove_file(&path);
    let server = UnixListener::bind(&path)?;
    let _ = std::os::unix::fs::chown(&path, Some(owner), None);
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
    server.set_nonblocking(true)?;
    Ok(server)
}

fn rebuild_command(link: &str, project: &str, rev: &str) -> String {
    let name = basename(link);
    let source = if rev.is_empty() {
        project.to_string()
    } else {
        format!("git+file://{project}?rev={rev}")
    };
    if name == ".pre-commit-config.yaml" || link.contains("/.direnv/") {
        return format!("cd {project} && nix develop {source} -c true");
    }
    let attr = name.strip_prefix("result-").unwrap_or("default");
    format!("nix build {source}#{attr} -o {link}")
}

pub(crate) fn record_root(link: &str, user: &str) {
    let Ok(target) = std::fs::read_link(link) else {
        return;
    };
    let project = reclaim::project_for(link).unwrap_or_else(|| dirname(link).to_string());
    let rev = reclaim::stdout(&reclaim::run_as(
        user,
        &["git", "-C", &project, "rev-parse", "HEAD"],
        None,
    ))
    .trim()
    .to_string();
    let dirty = !reclaim::stdout(&reclaim::run_as(
        user,
        &[
            "git",
            "-C",
            &project,
            "status",
            "--porcelain",
            "--untracked-files=no",
        ],
        None,
    ))
    .trim()
    .is_empty();
    let line = json!({"at": sys::now() as i64, "link": link, "target": target.to_string_lossy(), "project": project, "rev": rev, "dirty": dirty, "rebuild": rebuild_command(link, &project, if dirty { "" } else { &rev })});
    if let Ok(mut handle) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(PathBuf::from(env("LEDGER_STATE_DIR")).join("roots.jsonl"))
    {
        let _ = writeln!(handle, "{line}");
    }
}

pub fn restore(prefix: &str) -> i32 {
    let text = std::fs::read_to_string(PathBuf::from(env("LEDGER_STATE_DIR")).join("roots.jsonl"))
        .unwrap_or_default();
    let mut latest: BTreeMap<String, Value> = BTreeMap::new();
    for line in text.lines() {
        if let Ok(record) = serde_json::from_str::<Value>(line) {
            let link = record["link"].as_str().unwrap_or("").to_string();
            if link.starts_with(prefix) && !reclaim::lexists(&link) {
                latest.insert(link, record);
            }
        }
    }
    for (link, record) in &latest {
        println!(
            "# {link} was {} ({}{})",
            record["target"].as_str().unwrap_or(""),
            probe::local("%Y-%m-%d %H:%M", number(record.get("at"))),
            if record["dirty"].as_bool() == Some(true) {
                ", tree was dirty"
            } else {
                ""
            }
        );
        println!("{}", record["rebuild"].as_str().unwrap_or(""));
    }
    0
}
