// Store index over the nix database: graph, liveness, exact per-path disk use from shared inodes, deletion.

use crate::{gc, sys};
use hashbrown::HashTable;
use regex::Regex;
use rusqlite::{params, Connection, OpenFlags};
use std::collections::{HashMap, HashSet};
use std::hash::{BuildHasher, RandomState};
use std::process::Command;
use std::sync::OnceLock;

pub const LINKS: &str = "/nix/store/.links";
pub const DELETE_BATCH: usize = 1000;

#[derive(Default)]
pub struct Path {
    pub path: String,
    pub registered: i64,
    pub deriver: Option<String>,
    pub refs: Vec<u32>,
    pub referrers: Vec<u32>,
    pub own: Option<u64>,
    pub links: Vec<u32>,
    pub used: Option<i64>,
    pub alive: bool,
}

#[derive(Clone, Copy)]
#[repr(C, packed(4))]
pub struct Link {
    pub ino: u64,
    pub blocks: u64,
    pub holders: u32,
    pub claimant: u32,
}

const NOBODY: u32 = u32::MAX;
pub const UNRANKED: u32 = 1 << 30;

pub struct Store {
    db: Option<Connection>,
    cache: Option<Connection>,
    cache_path: String,
    version: Option<i64>,
    pub paths: Vec<Path>,
    free_slots: Vec<u32>,
    index: HashTable<u32>,
    by_id: HashMap<i64, u32>,
    links: Vec<Link>,
    link_of: HashTable<u32>,
    link_hash: RandomState,
    free_links: Vec<u32>,
    pub root_links: HashMap<String, Vec<String>>,
    pub roots: HashSet<u32>,
    pub runtime_pids: Vec<i32>,
    pub live: Vec<bool>,
    pub held: Vec<bool>,
    temp_offsets: HashMap<String, u64>,
    pub dead: Vec<u32>,
    pub effective: HashMap<u32, i64>,
    sizes: Vec<u64>,
    sized: bool,
    priority: Vec<u32>,
    pub pending: HashSet<u32>,
    touched: HashSet<u32>,
    pub own_total: u64,
    pub shared_total: u64,
    pub orphan_bytes: u64,
    pub orphan_count: u64,
    pub orphans: Vec<String>,
    pub stale_links: u64,
    stale_requeued: u64,
    pub links_blocks: u64,
    pub walked: u64,
    pub journal: Vec<(String, bool)>,
    settings: HashMap<&'static str, bool>,
}

fn number(value: rusqlite::types::ValueRef) -> i64 {
    match value {
        rusqlite::types::ValueRef::Integer(number) => number,
        rusqlite::types::ValueRef::Real(number) => number as i64,
        _ => 0,
    }
}

const STORE_DIR: &str = "/nix/store/";
const ROOT_DIRS: [&str; 2] = ["/nix/var/nix/gcroots", "/nix/var/nix/profiles"];
pub const TEMP_ROOTS: &str = "/nix/var/nix/temproots";
const KERNEL_ROOTS: [&str; 3] = [
    "/proc/sys/kernel/modprobe",
    "/proc/sys/kernel/fbsplash",
    "/proc/sys/kernel/poweroff_cmd",
];

fn top_store_path(target: &str) -> Option<String> {
    let rest = target.strip_prefix(STORE_DIR)?;
    let name = rest.split('/').next().filter(|name| !name.is_empty())?;
    Some(format!("{STORE_DIR}{name}"))
}

fn absolute(target: &str, base: &str) -> String {
    let joined = if target.starts_with('/') {
        target.to_string()
    } else {
        format!("{base}/{target}")
    };
    let mut parts: Vec<&str> = Vec::new();
    for part in joined.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            other => parts.push(other),
        }
    }
    format!("/{}", parts.join("/"))
}

fn read_link(path: &str) -> Option<String> {
    std::fs::read_link(path)
        .ok()
        .map(|target| target.to_string_lossy().into_owned())
}

fn parent(path: &str) -> &str {
    match path.rfind('/') {
        Some(0) | None => "/",
        Some(index) => &path[..index],
    }
}

fn add_root(roots: &mut HashMap<String, Vec<String>>, store_path: String, link: String) {
    let links = roots.entry(store_path).or_default();
    if !links.contains(&link) {
        links.push(link);
    }
}

fn find_roots(path: &str, roots: &mut HashMap<String, Vec<String>>) {
    let Some(info) = sys::lstat(path) else { return };
    if sys::is_dir(info.mode) {
        let Ok(entries) = std::fs::read_dir(path) else {
            return;
        };
        for entry in entries.flatten() {
            find_roots(
                &format!("{path}/{}", entry.file_name().to_string_lossy()),
                roots,
            );
        }
    } else if sys::is_link(info.mode) {
        let Some(target) = read_link(path) else {
            return;
        };
        let target = absolute(&target, parent(path));
        if let Some(store_path) = top_store_path(&target) {
            add_root(roots, store_path, path.to_string());
        } else if sys::lstat(&target).is_some_and(|other| sys::is_link(other.mode)) {
            if let Some(store_path) = read_link(&target).and_then(|second| top_store_path(&second))
            {
                add_root(roots, store_path, target);
            }
        }
    } else if sys::is_reg(info.mode) {
        let name = path.rsplit('/').next().unwrap_or_default();
        add_root(roots, format!("{STORE_DIR}{name}"), path.to_string());
    }
}

fn mapped_path(line: &str) -> Option<&str> {
    let mut fields = line.split_ascii_whitespace();
    let path = fields.nth(5)?;
    (fields.next().is_none() && path.starts_with('/')).then_some(path)
}

fn process_roots(roots: &mut HashMap<String, Vec<String>>) {
    let mut add = |target: &str, link: String| {
        if let Some(store_path) = top_store_path(target) {
            add_root(roots, store_path, link);
        }
    };
    let Ok(entries) = std::fs::read_dir("/proc") else {
        return;
    };
    for entry in entries.flatten() {
        let pid = entry.file_name().to_string_lossy().into_owned();
        if pid.is_empty() || !pid.bytes().all(|byte| byte.is_ascii_digit()) {
            continue;
        }
        pid_roots(&pid, &mut add);
    }
    for file in KERNEL_ROOTS {
        if let Ok(text) = std::fs::read_to_string(file) {
            add(text.trim(), file.to_string());
        }
    }
}

fn pid_roots(pid: &str, add: &mut dyn FnMut(&str, String)) {
    static MENTION: OnceLock<Regex> = OnceLock::new();
    let mention =
        MENTION.get_or_init(|| Regex::new(r"/nix/store/[0-9a-z]+[0-9a-zA-Z+\-._?=]*").unwrap());
    {
        let proc = format!("/proc/{pid}");
        for name in ["exe", "cwd"] {
            let link = format!("{proc}/{name}");
            if let Some(target) = read_link(&link) {
                add(&target, link);
            }
        }
        if let Ok(fds) = std::fs::read_dir(format!("{proc}/fd")) {
            for fd in fds.flatten() {
                let link = format!("{proc}/fd/{}", fd.file_name().to_string_lossy());
                if let Some(target) = read_link(&link) {
                    add(&target, link);
                }
            }
        }
        if let Ok(maps) = std::fs::read(format!("{proc}/maps")) {
            let link = format!("{proc}/maps");
            for line in String::from_utf8_lossy(&maps).lines() {
                if let Some(path) = mapped_path(line) {
                    add(path, link.clone());
                }
            }
        }
        if let Ok(environ) = std::fs::read(format!("{proc}/environ")) {
            let text = String::from_utf8_lossy(&environ);
            let link = format!("{proc}/environ");
            for found in mention.find_iter(&text) {
                add(found.as_str(), link.clone());
            }
        }
    }
}

fn runtime_roots(roots: &mut HashMap<String, Vec<String>>) {
    process_roots(roots);
    let mut add = |target: &str, link: String| {
        if let Some(store_path) = top_store_path(target) {
            add_root(roots, store_path, link);
        }
    };
    let Ok(files) = std::fs::read_dir(TEMP_ROOTS) else {
        return;
    };
    for file in files.flatten() {
        let pid = file.file_name().to_string_lossy().into_owned();
        if !std::path::Path::new(&format!("/proc/{pid}")).exists() {
            continue;
        }
        let Ok(contents) = std::fs::read(file.path()) else {
            continue;
        };
        let link = format!("{{temp:{pid}}}");
        for path in contents
            .split(|byte| *byte == 0)
            .filter(|path| !path.is_empty())
        {
            add(&String::from_utf8_lossy(path), link.clone());
        }
    }
}

pub fn nix_setting(file: &str, name: &str) -> Option<String> {
    let text = std::fs::read_to_string(file).ok()?;
    let mut found = None;
    for line in text.lines() {
        let line = line.split('#').next().unwrap_or("").trim();
        if let Some(included) = line
            .strip_prefix("!include ")
            .or_else(|| line.strip_prefix("include "))
        {
            let included = absolute(included.trim(), parent(file));
            found = nix_setting(&included, name).or(found);
            continue;
        }
        if let Some((key, value)) = line.split_once('=') {
            if key.trim() == name {
                found = Some(value.trim().to_string());
            }
        }
    }
    found
}

pub fn gc_roots() -> HashMap<String, Vec<String>> {
    let mut roots: HashMap<String, Vec<String>> = HashMap::new();
    for directory in ROOT_DIRS {
        find_roots(directory, &mut roots);
    }
    runtime_roots(&mut roots);
    roots
}

pub fn directory_roots(state: &str) -> HashMap<String, Vec<String>> {
    let mut roots: HashMap<String, Vec<String>> = HashMap::new();
    for directory in ["gcroots", "profiles"] {
        find_roots(&format!("{state}/{directory}"), &mut roots);
    }
    roots
}

pub struct Walked {
    pub own: u64,
    pub shared: Vec<(u64, u64)>,
    pub used: i64,
}

pub fn walk(path: &str) -> Option<Walked> {
    let info = sys::lstat(path)?;
    let mut own = 0u64;
    let mut used = 0i64;
    let mut shared: HashMap<u64, u64> = HashMap::new();
    let mut account = |entry: &sys::Entry| {
        if entry.nlink > 1 && !sys::is_dir(entry.mode) {
            shared.insert(entry.ino, entry.blocks);
        } else {
            own += entry.blocks;
        }
        if sys::is_reg(entry.mode) && entry.atime > used {
            used = entry.atime;
        }
    };
    account(&info);
    if sys::is_dir(info.mode) && !sys::walk_tree(path, &mut account) {
        return None;
    }
    Some(Walked {
        own,
        shared: shared.into_iter().collect(),
        used,
    })
}

impl Store {
    pub fn new(cache_path: &str) -> Store {
        Store {
            db: None,
            cache: None,
            cache_path: cache_path.to_string(),
            version: None,
            paths: Vec::new(),
            free_slots: Vec::new(),
            index: HashTable::new(),
            by_id: HashMap::new(),
            links: Vec::new(),
            link_of: HashTable::new(),
            link_hash: RandomState::new(),
            free_links: Vec::new(),
            root_links: HashMap::new(),
            roots: HashSet::new(),
            runtime_pids: Vec::new(),
            live: Vec::new(),
            held: Vec::new(),
            temp_offsets: HashMap::new(),
            dead: Vec::new(),
            effective: HashMap::new(),
            sizes: Vec::new(),
            sized: false,
            priority: Vec::new(),
            pending: HashSet::new(),
            touched: HashSet::new(),
            own_total: 0,
            shared_total: 0,
            orphan_bytes: 0,
            orphan_count: 0,
            orphans: Vec::new(),
            stale_links: 0,
            stale_requeued: 0,
            links_blocks: 0,
            walked: 0,
            journal: Vec::new(),
            settings: HashMap::new(),
        }
    }

    pub fn open_db(&mut self, uri: &str) -> rusqlite::Result<()> {
        let flags = OpenFlags::SQLITE_OPEN_READ_ONLY
            | OpenFlags::SQLITE_OPEN_URI
            | OpenFlags::SQLITE_OPEN_NO_MUTEX;
        let db = Connection::open_with_flags(uri, flags)?;
        let _ = db.pragma_update(None, "cache_size", -256);
        self.db = Some(db);
        Ok(())
    }

    pub fn slot(&self, path: &str) -> Option<u32> {
        self.index
            .find(self.link_hash.hash_one(path), |slot| {
                self.paths[*slot as usize].path == path
            })
            .copied()
    }

    fn index_insert(&mut self, slot: u32) {
        let (paths, state) = (&self.paths, &self.link_hash);
        self.index.insert_unique(
            state.hash_one(paths[slot as usize].path.as_str()),
            slot,
            |slot| state.hash_one(paths[*slot as usize].path.as_str()),
        );
    }

    fn index_remove(&mut self, slot: u32) {
        let paths = &self.paths;
        let path = paths[slot as usize].path.as_str();
        if let Ok(found) = self
            .index
            .find_entry(self.link_hash.hash_one(path), |other| *other == slot)
        {
            found.remove();
        }
    }

    pub fn get(&self, slot: u32) -> &Path {
        &self.paths[slot as usize]
    }

    pub fn alive_slots(&self) -> impl Iterator<Item = u32> + '_ {
        self.paths
            .iter()
            .enumerate()
            .filter(|(_, path)| path.alive)
            .map(|(slot, _)| slot as u32)
    }

    pub fn count(&self) -> usize {
        self.index.len()
    }

    fn setting(&mut self, name: &'static str) -> bool {
        if let Some(value) = self.settings.get(name) {
            return *value;
        }
        let value = nix_setting("/etc/nix/nix.conf", name)
            .map(|value| value == "true")
            .unwrap_or(name == "keep-derivations");
        self.settings.insert(name, value);
        value
    }

    pub fn load(&mut self) -> bool {
        if self.db.is_none()
            && self
                .open_db("file:/nix/var/nix/db/db.sqlite?mode=ro")
                .is_err()
        {
            return false;
        }
        let version: i64 = self
            .db
            .as_ref()
            .unwrap()
            .query_row("pragma data_version", [], |row| row.get(0))
            .unwrap_or(-1);
        if Some(version) == self.version {
            return false;
        }
        let (gone, new) = self.load_paths();
        self.version = Some(version);
        if self.cache.is_none() {
            self.load_cache();
        }
        for path in gone {
            self.forget(&path);
            self.journal.push((path, false));
        }
        for slot in new {
            self.journal
                .push((self.paths[slot as usize].path.clone(), true));
            if self.paths[slot as usize].own.is_none() {
                self.pending.insert(slot);
            }
        }
        true
    }

    pub fn refresh_roots(&mut self) {
        self.held.clear();
        self.temp_offsets.clear();
        self.root_links = gc_roots();
        self.hold_temp_roots();
        self.liveness();
    }

    pub fn is_held(&self, slot: u32) -> bool {
        self.held.get(slot as usize).copied().unwrap_or(false)
    }

    pub fn hold(&mut self, target: &str) -> bool {
        let Some(slot) = top_store_path(target).and_then(|path| self.slot(&path)) else {
            return false;
        };
        if self.held.len() < self.paths.len() {
            self.held.resize(self.paths.len(), false);
        }
        if self.held[slot as usize] {
            return false;
        }
        let mut stack = vec![slot];
        while let Some(slot) = stack.pop() {
            if self.held[slot as usize] {
                continue;
            }
            self.held[slot as usize] = true;
            let held = &self.held;
            stack.extend(
                self.paths[slot as usize]
                    .refs
                    .iter()
                    .filter(|other| !held[**other as usize]),
            );
        }
        true
    }

    pub fn hold_pid(&mut self, pid: i32) -> bool {
        let mut found = Vec::new();
        pid_roots(&pid.to_string(), &mut |target: &str, _| {
            found.push(target.to_string())
        });
        found
            .iter()
            .fold(false, |changed, target| self.hold(target) | changed)
    }

    pub fn hold_temp_roots(&mut self) -> bool {
        use std::io::{Read, Seek};
        let Ok(files) = std::fs::read_dir(TEMP_ROOTS) else {
            return false;
        };
        let mut found = Vec::new();
        for file in files.flatten() {
            let name = file.file_name().to_string_lossy().into_owned();
            let Ok(mut handle) = std::fs::File::open(file.path()) else {
                continue;
            };
            let offset = self.temp_offsets.get(&name).copied().unwrap_or(0);
            let mut appended = Vec::new();
            if handle.seek(std::io::SeekFrom::Start(offset)).is_err()
                || handle.read_to_end(&mut appended).is_err()
            {
                continue;
            }
            let complete = appended
                .iter()
                .rposition(|byte| *byte == 0)
                .map_or(0, |end| end + 1);
            self.temp_offsets.insert(name, offset + complete as u64);
            found.extend(
                appended[..complete]
                    .split(|byte| *byte == 0)
                    .filter(|path| !path.is_empty())
                    .map(|path| String::from_utf8_lossy(path).into_owned()),
            );
        }
        found
            .iter()
            .fold(false, |changed, target| self.hold(target) | changed)
    }

    pub fn liveness(&mut self) {
        let mut outputs: HashMap<u32, Vec<u32>> = HashMap::new();
        if self.setting("keep-outputs") {
            if let Some(db) = &self.db {
                if let Ok(mut statement) = db.prepare_cached("select v.path, o.path from DerivationOutputs o join ValidPaths v on v.id = o.drv") {
                    let rows = statement.query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)));
                    if let Ok(rows) = rows {
                        for (drv, out) in rows.flatten() {
                            if let (Some(drv), Some(out)) = (self.slot(&drv), self.slot(&out)) {
                                outputs.entry(drv).or_default().push(out);
                            }
                        }
                    }
                }
            }
        }
        let keep_derivations = self.setting("keep-derivations");
        self.roots = self
            .root_links
            .keys()
            .filter_map(|path| self.slot(path))
            .collect();
        let reach = |roots: &mut dyn Iterator<Item = u32>| {
            let mut live = vec![false; self.paths.len()];
            let mut stack: Vec<u32> = roots.collect();
            while let Some(slot) = stack.pop() {
                if live[slot as usize] {
                    continue;
                }
                live[slot as usize] = true;
                let entry = &self.paths[slot as usize];
                stack.extend(entry.refs.iter().filter(|other| !live[**other as usize]));
                if keep_derivations {
                    if let Some(drv) = entry.deriver.as_ref().and_then(|drv| self.slot(drv)) {
                        stack.push(drv);
                    }
                }
                if let Some(outs) = outputs.get(&slot) {
                    stack.extend(outs);
                }
            }
            live
        };
        let live = reach(&mut self.roots.iter().copied());
        let lasting = reach(
            &mut self
                .root_links
                .iter()
                .filter(|(_, links)| links.iter().any(|link| !link.starts_with("/proc/")))
                .filter_map(|(path, _)| self.slot(path)),
        );
        let mut pids: Vec<i32> = self
            .root_links
            .iter()
            .filter(|(path, _)| self.slot(path).is_some_and(|slot| !lasting[slot as usize]))
            .flat_map(|(_, links)| {
                links
                    .iter()
                    .filter_map(|link| link.strip_prefix("/proc/")?.split('/').next()?.parse().ok())
            })
            .collect();
        pids.sort_unstable();
        pids.dedup();
        self.runtime_pids = pids;
        self.dead = self
            .alive_slots()
            .filter(|slot| !live[*slot as usize])
            .collect();
        self.live = live;
        self.effective = self.effective_use(&self.dead.clone());
    }

    pub fn is_live(&self, slot: u32) -> bool {
        self.live.get(slot as usize).copied().unwrap_or(false)
    }

    fn allocate(&mut self, entry: Path) -> u32 {
        if let Some(slot) = self.free_slots.pop() {
            self.paths[slot as usize] = entry;
            slot
        } else {
            self.paths.push(entry);
            (self.paths.len() - 1) as u32
        }
    }

    fn load_paths(&mut self) -> (Vec<String>, Vec<u32>) {
        let db = self.db.as_ref().unwrap();
        let _ = db.execute_batch("begin");
        let ids: HashSet<i64> = db
            .prepare_cached("select id from ValidPaths")
            .and_then(|mut statement| statement.query_map([], |row| row.get(0))?.collect())
            .unwrap_or_default();
        let gone_ids: Vec<i64> = self
            .by_id
            .keys()
            .filter(|id| !ids.contains(id))
            .copied()
            .collect();
        let mut gone = Vec::new();
        for id in gone_ids {
            let slot = self.by_id.remove(&id).unwrap();
            let refs = std::mem::take(&mut self.paths[slot as usize].refs);
            let ups = std::mem::take(&mut self.paths[slot as usize].referrers);
            for other in refs {
                self.paths[other as usize]
                    .referrers
                    .retain(|up| *up != slot);
            }
            for other in ups {
                self.paths[other as usize].refs.retain(|down| *down != slot);
            }
            gone.push(self.paths[slot as usize].path.clone());
        }
        let mut new: Vec<i64> = ids
            .into_iter()
            .filter(|id| !self.by_id.contains_key(id))
            .collect();
        new.sort_unstable();
        let mut fresh = Vec::new();
        let mut rows = Vec::new();
        for chunk in new.chunks(900) {
            let marks = vec!["?"; chunk.len()].join(",");
            let sql = format!("select id, path, registrationTime, narSize, deriver from ValidPaths where id in ({marks})");
            if let Ok(mut statement) = db.prepare(&sql) {
                let found = statement.query_map(rusqlite::params_from_iter(chunk.iter()), |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, Option<i64>>(2)?,
                        row.get::<_, Option<i64>>(3)?,
                        row.get::<_, Option<String>>(4)?,
                    ))
                });
                if let Ok(found) = found {
                    rows.extend(found.flatten());
                }
            }
        }
        let mut edges = Vec::new();
        for chunk in new.chunks(900) {
            let marks = vec!["?"; chunk.len()].join(",");
            let sql = format!("select referrer, reference from Refs where referrer in ({marks})");
            if let Ok(mut statement) = db.prepare(&sql) {
                if let Ok(found) = statement
                    .query_map(rusqlite::params_from_iter(chunk.iter()), |row| {
                        Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?))
                    })
                {
                    edges.extend(found.flatten());
                }
            }
        }
        let _ = db.execute_batch("commit");
        for path in &gone {
            if let Some(slot) = self.slot(path) {
                let still = rows.iter().any(|row| &row.1 == path);
                if !still {
                    continue;
                }
                self.release(slot);
            }
        }
        for (id, path, registered, _, deriver) in rows {
            if let Some(slot) = self.slot(&path) {
                self.release(slot);
            }
            let slot = self.allocate(Path {
                path,
                registered: registered.unwrap_or(0),
                deriver,
                alive: true,
                ..Default::default()
            });
            self.index_insert(slot);
            self.by_id.insert(id, slot);
            fresh.push(slot);
        }
        for (referrer, reference) in edges {
            if referrer == reference {
                continue;
            }
            if let (Some(source), Some(target)) = (
                self.by_id.get(&referrer).copied(),
                self.by_id.get(&reference).copied(),
            ) {
                if !self.paths[source as usize].refs.contains(&target) {
                    self.paths[source as usize].refs.push(target);
                    self.paths[target as usize].referrers.push(source);
                }
            }
        }
        (gone, fresh)
    }

    fn release(&mut self, slot: u32) {
        self.detach(slot);
        let entry = &mut self.paths[slot as usize];
        if !entry.alive {
            return;
        }
        entry.alive = false;
        self.index_remove(slot);
        self.paths[slot as usize].path = String::new();
        self.pending.remove(&slot);
        self.touched.remove(&slot);
        self.free_slots.push(slot);
    }

    fn load_cache(&mut self) {
        if let Some(parent) = std::path::Path::new(&self.cache_path).parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let Ok(cache) = Connection::open(&self.cache_path) else {
            return;
        };
        let _ = cache.busy_timeout(std::time::Duration::from_secs(60));
        let _ = cache.pragma_update(None, "journal_mode", "wal");
        let _ = cache.pragma_update(None, "cache_size", -256);
        let _ = cache.execute_batch("drop table if exists disk; drop table if exists drift; create table if not exists store (path text primary key, own integer, used integer, inodes blob)");
        let mut stale = Vec::new();
        let mut loaded = Vec::new();
        if let Ok(mut statement) = cache.prepare("select path, own, used, inodes from store") {
            if let Ok(rows) = statement.query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    number(row.get_ref(1)?),
                    number(row.get_ref(2)?),
                    row.get::<_, Vec<u8>>(3)?,
                ))
            }) {
                for (path, own, used, blob) in rows.flatten() {
                    match self.slot(&path) {
                        Some(slot) => loaded.push((slot, own as u64, used, blob)),
                        None => stale.push(path),
                    }
                }
            }
        }
        for (slot, own, used, blob) in loaded {
            let pairs: Vec<(u64, u64)> = blob
                .chunks_exact(16)
                .map(|pair| (sys::u64_at(pair, 0), sys::u64_at(pair, 8)))
                .collect();
            self.attach(slot, own, &pairs);
            let registered = self.paths[slot as usize].registered;
            self.paths[slot as usize].used = Some(used.max(registered));
        }
        if !stale.is_empty() {
            let _ = cache.execute_batch("begin");
            for path in stale {
                let _ = cache.execute("delete from store where path = ?", params![path]);
            }
            let _ = cache.execute_batch("commit");
        }
        self.cache = Some(cache);
        self.pending = self
            .alive_slots()
            .filter(|slot| self.paths[*slot as usize].own.is_none())
            .collect();
    }

    fn attach(&mut self, slot: u32, own: u64, pairs: &[(u64, u64)]) {
        self.sized = false;
        self.own_total += own;
        let mut held = Vec::with_capacity(pairs.len());
        for (ino, blocks) in pairs {
            let hash = self.link_hash.hash_one(*ino);
            let link = match self
                .link_of
                .find(hash, |link| self.links[*link as usize].ino == *ino)
            {
                Some(link) => *link,
                None => {
                    let record = Link {
                        ino: *ino,
                        blocks: *blocks,
                        holders: 0,
                        claimant: NOBODY,
                    };
                    let link = match self.free_links.pop() {
                        Some(link) => {
                            self.links[link as usize] = record;
                            link
                        }
                        None => {
                            self.links.push(record);
                            (self.links.len() - 1) as u32
                        }
                    };
                    let (links, state) = (&self.links, &self.link_hash);
                    self.link_of.insert_unique(hash, link, |link| {
                        state.hash_one(links[*link as usize].ino)
                    });
                    self.shared_total += blocks;
                    link
                }
            };
            self.links[link as usize].holders += 1;
            held.push(link);
        }
        let entry = &mut self.paths[slot as usize];
        entry.own = Some(own);
        entry.links = held;
    }

    fn detach(&mut self, slot: u32) {
        self.sized = false;
        let entry = &mut self.paths[slot as usize];
        let Some(own) = entry.own.take() else { return };
        let held = std::mem::take(&mut entry.links);
        self.own_total -= own;
        for link in held {
            let links = &mut self.links;
            let record = &mut links[link as usize];
            if record.claimant == slot {
                record.claimant = NOBODY;
            }
            record.holders -= 1;
            if record.holders == 0 {
                self.shared_total -= record.blocks;
                let ino = record.ino;
                if let Ok(found) = self
                    .link_of
                    .find_entry(self.link_hash.hash_one(ino), |other| {
                        links[*other as usize].ino == ino
                    })
                {
                    found.remove();
                }
                self.free_links.push(link);
            }
        }
    }

    fn forget(&mut self, path: &str) {
        if let Some(slot) = self.slot(path) {
            self.release(slot);
        }
        if let Some(cache) = &self.cache {
            let _ = cache.execute("delete from store where path = ?", params![path]);
        }
    }

    pub fn measure(&mut self, slot: u32) -> bool {
        let path = self.paths[slot as usize].path.clone();
        let Some(walked) = walk(&path) else {
            return false;
        };
        self.detach(slot);
        self.attach(slot, walked.own, &walked.shared);
        let entry = &mut self.paths[slot as usize];
        let used = entry
            .used
            .unwrap_or(0)
            .max(walked.used)
            .max(entry.registered);
        entry.used = Some(used);
        let mut blob = Vec::with_capacity(walked.shared.len() * 16);
        for (ino, blocks) in &walked.shared {
            blob.extend_from_slice(&ino.to_ne_bytes());
            blob.extend_from_slice(&blocks.to_ne_bytes());
        }
        if let Some(cache) = &self.cache {
            let _ = cache.execute(
                "insert or replace into store values (?, ?, ?, ?)",
                params![path, walked.own as i64, used, blob],
            );
        }
        self.walked += 1;
        true
    }

    pub fn walk_pending(&mut self, deadline: std::time::Instant) -> usize {
        let mut done = 0;
        if let Some(cache) = &self.cache {
            let _ = cache.execute_batch("begin");
        }
        while std::time::Instant::now() < deadline {
            let Some(slot) = self.pending.iter().next().copied() else {
                break;
            };
            self.pending.remove(&slot);
            if self.paths[slot as usize].alive && self.measure(slot) {
                done += 1;
            }
        }
        if let Some(cache) = &self.cache {
            let _ = cache.execute_batch("commit");
        }
        done
    }

    pub fn touch(&mut self, path: &str, when: i64) {
        if let Some(slot) = self.slot(path) {
            let entry = &mut self.paths[slot as usize];
            if when > entry.used.unwrap_or(0) {
                entry.used = Some(when);
                self.touched.insert(slot);
            }
        }
    }

    pub fn flush_used(&mut self) {
        if self.touched.is_empty() {
            return;
        }
        if let Some(cache) = &self.cache {
            let _ = cache.execute_batch("begin");
            for slot in &self.touched {
                let entry = &self.paths[*slot as usize];
                if let (true, Some(used)) = (entry.alive, entry.used) {
                    let _ = cache.execute(
                        "update store set used = ? where path = ?",
                        params![used, entry.path],
                    );
                }
            }
            let _ = cache.execute_batch("commit");
        }
        self.touched.clear();
    }

    pub fn scan_links(&mut self) {
        self.apply_links(&gc::scan_links(LINKS));
    }

    pub fn apply_links(&mut self, scan: &gc::LinkScan) {
        let mut orphan_bytes = 0;
        let mut orphans = Vec::new();
        let mut stale = 0;
        self.links_blocks = sys::lstat(LINKS).map(|info| info.blocks).unwrap_or(0);
        if let Some(fd) = sys::open_walk(libc::AT_FDCWD, &sys::cstr(LINKS)) {
            let unknown = |ino: u64| {
                self.link_of
                    .find(self.link_hash.hash_one(ino), |link| {
                        self.links[*link as usize].ino == ino
                    })
                    .is_none()
            };
            let names = scan
                .entries
                .iter()
                .filter(|entry| unknown(entry.0))
                .map(|entry| gc::link_name(&entry.1))
                .chain(
                    scan.strays
                        .iter()
                        .filter(|stray| unknown(stray.1))
                        .map(|stray| stray.0.clone()),
                );
            for name in names {
                match sys::stat_at(fd, name.as_bytes()) {
                    Some(entry) if entry.nlink == 1 => {
                        orphan_bytes += entry.blocks;
                        orphans.push(name);
                    }
                    Some(_) => stale += 1,
                    None => {}
                }
            }
            sys::close(fd);
        }
        self.orphan_bytes = orphan_bytes;
        self.orphan_count = orphans.len() as u64;
        self.orphans = orphans;
        self.stale_links = stale;
        if stale == 0 {
            self.stale_requeued = 0;
        } else if stale != self.stale_requeued {
            self.stale_requeued = stale;
            let all: Vec<u32> = self.alive_slots().collect();
            self.pending.extend(all);
        }
    }

    pub fn begin(&self) {
        if let Some(cache) = &self.cache {
            let _ = cache.execute_batch("begin");
        }
    }

    pub fn commit(&self) {
        if let Some(cache) = &self.cache {
            let _ = cache.execute_batch("commit");
        }
    }

    pub fn compact(&mut self) {
        let (links, state) = (&self.links, &self.link_hash);
        self.link_of
            .shrink_to_fit(|link| state.hash_one(links[*link as usize].ino));
        self.links.shrink_to_fit();
        self.paths.shrink_to_fit();
        let (paths, state) = (&self.paths, &self.link_hash);
        self.index
            .shrink_to_fit(|slot| state.hash_one(paths[*slot as usize].path.as_str()));
        self.by_id.shrink_to_fit();
    }

    pub fn shared_files(&self) -> usize {
        self.link_of.len()
    }

    pub fn touched_count(&self) -> usize {
        self.touched.len()
    }

    pub fn registered_bytes(&self) -> u64 {
        self.own_total + self.shared_total
    }

    pub fn size(&mut self, slot: u32) -> u64 {
        if !self.sized {
            self.attribute();
        }
        self.sizes.get(slot as usize).copied().unwrap_or(0)
    }

    fn rank_of(&self, slot: u32) -> (u32, u32) {
        (
            self.priority
                .get(slot as usize)
                .copied()
                .unwrap_or(UNRANKED),
            slot,
        )
    }

    fn attribute(&mut self) {
        for record in self.links.iter_mut() {
            record.claimant = NOBODY;
        }
        for slot in 0..self.paths.len() as u32 {
            if self.paths[slot as usize].own.is_none() {
                continue;
            }
            let rank = self.rank_of(slot);
            for link in &self.paths[slot as usize].links {
                let holder = self.links[*link as usize].claimant;
                if holder == NOBODY || rank < self.rank_of(holder) {
                    self.links[*link as usize].claimant = slot;
                }
            }
        }
        self.sizes.clear();
        self.sizes.resize(self.paths.len(), 0);
        for (slot, entry) in self.paths.iter().enumerate() {
            let Some(own) = entry.own else { continue };
            self.sizes[slot] = own
                + entry
                    .links
                    .iter()
                    .map(|link| &self.links[*link as usize])
                    .filter(|record| record.claimant == slot as u32)
                    .map(|record| record.blocks)
                    .sum::<u64>();
        }
        self.sized = true;
    }

    pub fn unrank(&mut self) {
        self.priority.clear();
        self.sized = false;
    }

    pub fn rank(&mut self, slots: &[u32], level: u32) {
        if self.priority.len() < self.paths.len() {
            self.priority.resize(self.paths.len(), UNRANKED);
        }
        for slot in slots {
            self.priority[*slot as usize] = level;
        }
        self.sized = false;
    }

    pub fn size_of(&mut self, path: &str) -> u64 {
        match self.slot(path) {
            Some(slot) => self.size(slot),
            None => 0,
        }
    }

    pub fn dependents(&self, starts: impl IntoIterator<Item = u32>) -> HashSet<u32> {
        let mut found = HashSet::new();
        let mut stack: Vec<u32> = starts.into_iter().collect();
        while let Some(slot) = stack.pop() {
            if !found.insert(slot) {
                continue;
            }
            for up in &self.paths[slot as usize].referrers {
                if !found.contains(up)
                    && std::path::Path::new(&self.paths[*up as usize].path).exists()
                {
                    stack.push(*up);
                }
            }
        }
        found
    }

    pub fn effective_use(&self, dead: &[u32]) -> HashMap<u32, i64> {
        let dead_set: HashSet<u32> = dead.iter().copied().collect();
        let mut effective: HashMap<u32, i64> = HashMap::with_capacity(dead.len());
        for start in dead {
            if effective.contains_key(start) {
                continue;
            }
            let mut stack = vec![(*start, false)];
            while let Some((slot, expanded)) = stack.pop() {
                if effective.contains_key(&slot) {
                    continue;
                }
                let entry = &self.paths[slot as usize];
                let above = entry.referrers.iter().filter(|up| dead_set.contains(up));
                if expanded {
                    let base = entry.used.unwrap_or(entry.registered);
                    let value = above
                        .map(|up| effective.get(up).copied().unwrap_or(0))
                        .fold(base, i64::max);
                    effective.insert(slot, value);
                    continue;
                }
                stack.push((slot, true));
                stack.extend(
                    above
                        .filter(|up| !effective.contains_key(up))
                        .map(|up| (*up, false)),
                );
            }
        }
        effective
    }

    pub fn order(&self, chosen: &HashSet<u32>) -> Vec<u32> {
        let mut pending: HashMap<u32, usize> = chosen
            .iter()
            .map(|slot| {
                (
                    *slot,
                    self.paths[*slot as usize]
                        .referrers
                        .iter()
                        .filter(|up| chosen.contains(up))
                        .count(),
                )
            })
            .collect();
        let mut ready: Vec<u32> = pending
            .iter()
            .filter(|(_, count)| **count == 0)
            .map(|(slot, _)| *slot)
            .collect();
        ready.sort_by_key(|slot| (self.effective.get(slot).copied().unwrap_or(0), *slot));
        let mut out = Vec::with_capacity(chosen.len());
        while let Some(slot) = ready.pop() {
            out.push(slot);
            for down in &self.paths[slot as usize].refs {
                if let Some(count) = pending.get_mut(down) {
                    *count -= 1;
                    if *count == 0 {
                        ready.push(*down);
                    }
                }
            }
        }
        out
    }

    pub fn deletion_plan(&self, paths: &[u32]) -> (Vec<u32>, HashMap<u32, Vec<u32>>) {
        let ordered = self.order(&self.dependents(paths.iter().copied()));
        let chosen: HashSet<u32> = ordered.iter().copied().collect();
        let refs = ordered
            .iter()
            .map(|slot| {
                (
                    *slot,
                    self.paths[*slot as usize]
                        .refs
                        .iter()
                        .filter(|down| chosen.contains(down))
                        .copied()
                        .collect(),
                )
            })
            .collect();
        (ordered, refs)
    }
}

pub struct Deleted {
    pub ok: bool,
    pub alive: HashSet<String>,
}

pub fn delete(paths: &[String]) -> Deleted {
    static ALIVE: OnceLock<Regex> = OnceLock::new();
    let alive_pattern =
        ALIVE.get_or_init(|| Regex::new(r"[Cc]annot delete path '([^']+)'").unwrap());
    let Ok(result) = Command::new("nix-store")
        .arg("--delete")
        .args(paths)
        .output()
    else {
        return Deleted {
            ok: false,
            alive: HashSet::new(),
        };
    };
    let output = format!(
        "{}{}",
        String::from_utf8_lossy(&result.stdout),
        String::from_utf8_lossy(&result.stderr)
    );
    Deleted {
        ok: result.status.success(),
        alive: alive_pattern
            .captures_iter(&output)
            .map(|found| found[1].to_string())
            .collect(),
    }
}

pub struct Swept {
    pub refused: HashSet<String>,
    pub report: Option<gc::Report>,
    pub fallback: Option<String>,
}

pub fn delete_ordered(
    ordered: &[String],
    references: &HashMap<String, Vec<String>>,
    orphans: &[String],
    progress: &mut dyn FnMut(usize),
) -> Swept {
    let mut fallback = None;
    if std::env::var("LEDGER_NATIVE_GC").as_deref() != Ok("0") {
        match gc::collect(
            &gc::Layout::system(),
            ordered,
            references,
            orphans,
            progress,
        ) {
            Ok(report) => {
                return Swept {
                    refused: report.refused.clone(),
                    report: Some(report),
                    fallback: None,
                }
            }
            Err(reason) => fallback = Some(reason),
        }
    }
    let mut refused: HashSet<String> = HashSet::new();
    for (place, chunk) in ordered.chunks(DELETE_BATCH).enumerate() {
        progress(place * DELETE_BATCH + chunk.len());
        let mut batch: Vec<String> = chunk
            .iter()
            .filter(|path| !refused.contains(*path))
            .cloned()
            .collect();
        while !batch.is_empty() {
            let result = delete(&batch);
            if result.ok {
                break;
            }
            let mut live: HashSet<String> = HashSet::new();
            let mut stack: Vec<String> = if result.alive.is_empty() {
                batch.clone()
            } else {
                result.alive.into_iter().collect()
            };
            while let Some(path) = stack.pop() {
                if !live.insert(path.clone()) {
                    continue;
                }
                if let Some(refs) = references.get(&path) {
                    stack.extend(refs.iter().cloned());
                }
            }
            batch.retain(|path| !live.contains(path) && std::path::Path::new(path).exists());
            refused.extend(live);
        }
    }
    Swept {
        refused,
        report: None,
        fallback,
    }
}
