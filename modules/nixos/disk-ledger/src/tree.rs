// Per-directory size tree of one filesystem kept current from fanotify events, and last-open times of store paths.

use crate::sys;
use hashbrown::HashTable;
use std::collections::{HashMap, HashSet, VecDeque};
use std::hash::{BuildHasher, RandomState};
use std::time::Instant;

pub const SETTLE: f64 = 0.02;
const DRAIN_READS: usize = 16;
pub const COST_FACTOR: f64 = 20.0;
const NAMED: [&str; 2] = [".claude", ".git"];
pub const STORE: &str = "/nix/store/";
pub const NONE: u32 = u32::MAX;
const WATCHED: u64 = sys::FAN_MODIFY
    | sys::FAN_MOVED_FROM
    | sys::FAN_MOVED_TO
    | sys::FAN_CREATE
    | sys::FAN_DELETE
    | sys::FAN_ONDIR;

pub fn clock() -> f64 {
    static START: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();
    START.get_or_init(Instant::now).elapsed().as_secs_f64() + 1.0
}

#[derive(Default)]
pub struct Node {
    pub parent: u32,
    pub name: Box<str>,
    pub ino: u64,
    pub children: Box<[u32]>,
    pub key: Option<sys::Key>,
    pub dir_blocks: u64,
    pub files: u64,
    pub shared: u64,
    pub multi: Option<Box<[(u64, u64)]>>,
    pub own: u64,
    pub total: u64,
    pub own_newest: i64,
    pub newest: i64,
    pub scanned: f64,
    pub cost: f32,
    pub attached: bool,
    pub acl: bool,
    pub generation: u32,
}

pub type Skip = std::sync::Arc<dyn Fn(&str, &str) -> bool + Send + Sync>;

fn unescape_mount(field: &str) -> String {
    let bytes = field.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut at = 0;
    while at < bytes.len() {
        let octal = bytes.get(at + 1..at + 4).and_then(|digits| {
            std::str::from_utf8(digits)
                .ok()
                .and_then(|digits| u8::from_str_radix(digits, 8).ok())
        });
        match (bytes[at], octal) {
            (b'\\', Some(byte)) => {
                out.push(byte);
                at += 4;
            }
            (byte, _) => {
                out.push(byte);
                at += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

pub struct Mount {
    pub id: u32,
    pub parent: u32,
    pub dev: u64,
    pub root: String,
    pub point: String,
}

pub fn mounts(mountinfo: &str) -> Vec<Mount> {
    mountinfo
        .lines()
        .filter_map(|line| {
            let mut fields = line.split(' ');
            let id = fields.next()?.parse().ok()?;
            let parent = fields.next()?.parse().ok()?;
            let (major, minor) = fields.next()?.split_once(':')?;
            let root = fields.next()?;
            let point = fields.next()?;
            Some(Mount {
                id,
                parent,
                dev: libc::makedev(major.parse().ok()?, minor.parse().ok()?),
                root: unescape_mount(root),
                point: unescape_mount(point),
            })
        })
        .collect()
}

pub fn foreign_mounts(mountinfo: &str, device: u64) -> HashSet<String> {
    mounts(mountinfo)
        .into_iter()
        .filter(|mount| mount.dev != device || mount.root != mount.point)
        .map(|mount| mount.point)
        .collect()
}

pub fn under_any(path: &str, points: &HashSet<String>) -> bool {
    let mut at = path;
    loop {
        if points.contains(at) {
            return true;
        }
        match at.rfind('/') {
            Some(0) if at.len() > 1 => at = "/",
            Some(0) | None => return false,
            Some(cut) => at = &at[..cut],
        }
    }
}

pub fn within_device(device: u64, skip: Skip) -> Skip {
    let read = move || {
        foreign_mounts(
            &std::fs::read_to_string("/proc/self/mountinfo").unwrap_or_default(),
            device,
        )
    };
    let mounts = std::sync::RwLock::new((clock(), read()));
    std::sync::Arc::new(move |parent: &str, name: &str| {
        if skip(parent, name) {
            return true;
        }
        let stale = mounts
            .read()
            .map(|guard| clock() - guard.0 > 1.0)
            .unwrap_or(true);
        if stale {
            let fresh = read();
            if let Ok(mut guard) = mounts.write() {
                *guard = (clock(), fresh);
            }
        }
        mounts
            .read()
            .map(|guard| guard.1.contains(&join(parent, name)))
            .unwrap_or(false)
    })
}

const SERIAL: usize = 64;

pub struct Raw {
    blocks: u64,
    newest: i64,
    files: u64,
    multi: Vec<(u64, u64)>,
    dirs: Vec<(Box<str>, u64)>,
    key: Option<Vec<u8>>,
    acl: Option<bool>,
    cost: f64,
}

fn join(parent: &str, name: &str) -> String {
    if parent.ends_with('/') {
        format!("{parent}{name}")
    } else {
        format!("{parent}/{name}")
    }
}

fn read(
    path: &str,
    device: u64,
    skip: &(dyn Fn(&str, &str) -> bool + Send + Sync),
    fresh: bool,
) -> Option<Raw> {
    let started = clock();
    let info = sys::lstat(path)?;
    let fd = sys::open_walk(libc::AT_FDCWD, &sys::cstr(path))?;
    let (key, acl) = if fresh {
        (
            sys::handle_key(path, 0),
            Some(sys::listxattr_has(path, "system.posix_acl_default")),
        )
    } else {
        (None, None)
    };
    let mut raw = Raw {
        blocks: info.blocks,
        newest: info.mtime,
        files: 0,
        multi: Vec::new(),
        dirs: Vec::new(),
        key,
        acl,
        cost: 0.0,
    };
    let keep = |name: &[u8]| match std::str::from_utf8(name) {
        Ok(name) => !skip(path, name),
        Err(_) => !skip(path, &String::from_utf8_lossy(name)),
    };
    sys::read_dir_where(fd, keep, |entry| {
        raw.newest = raw.newest.max(entry.mtime);
        if sys::is_dir(entry.mode) {
            if entry.dev == device {
                raw.dirs
                    .push((String::from_utf8_lossy(&entry.name).into(), entry.ino));
            }
        } else if entry.nlink > 1 {
            raw.multi.push((entry.ino, entry.blocks));
        } else {
            raw.files += entry.blocks;
        }
    });
    sys::close(fd);
    raw.dirs.sort_unstable_by(|a, b| a.0.cmp(&b.0));
    raw.cost = clock() - started;
    Some(raw)
}

fn gather(device: u64, skip: &Skip, seeds: Vec<String>) -> HashMap<String, Raw> {
    let mut found = HashMap::new();
    let mut frontier = seeds;
    while found.len() < SERIAL {
        let Some(path) = frontier.pop() else {
            return found;
        };
        if let Some(raw) = read(&path, device, &**skip, true) {
            frontier.extend(raw.dirs.iter().map(|(name, _)| join(&path, name)));
            found.insert(path, raw);
        }
    }
    if frontier.is_empty() {
        return found;
    }
    struct Queue {
        work: Vec<String>,
        active: usize,
    }
    let queue = std::sync::Mutex::new(Queue {
        work: frontier,
        active: 0,
    });
    let ready = std::sync::Condvar::new();
    let threads = std::thread::available_parallelism()
        .map(|count| count.get())
        .unwrap_or(4)
        .clamp(2, 8);
    let parts: Vec<Vec<(String, Raw)>> = std::thread::scope(|scope| {
        let workers: Vec<_> = (0..threads)
            .map(|_| {
                scope.spawn(|| {
                    let mut out = Vec::new();
                    loop {
                        let next = {
                            let mut state = queue
                                .lock()
                                .unwrap_or_else(|poisoned| poisoned.into_inner());
                            loop {
                                if let Some(path) = state.work.pop() {
                                    state.active += 1;
                                    break Some(path);
                                }
                                if state.active == 0 {
                                    break None;
                                }
                                state = ready
                                    .wait(state)
                                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                            }
                        };
                        let Some(path) = next else {
                            ready.notify_all();
                            return out;
                        };
                        let raw = read(&path, device, &**skip, true);
                        let mut state = queue
                            .lock()
                            .unwrap_or_else(|poisoned| poisoned.into_inner());
                        let added = raw.as_ref().map(|raw| raw.dirs.len()).unwrap_or(0);
                        if let Some(raw) = &raw {
                            state
                                .work
                                .extend(raw.dirs.iter().map(|(name, _)| join(&path, name)));
                        }
                        state.active -= 1;
                        let finished = state.active == 0 && state.work.is_empty();
                        drop(state);
                        if finished || added > 1 {
                            ready.notify_all();
                        } else if added == 1 {
                            ready.notify_one();
                        }
                        if let Some(raw) = raw {
                            out.push((path, raw));
                        }
                    }
                })
            })
            .collect();
        workers
            .into_iter()
            .map(|worker| worker.join().unwrap_or_default())
            .collect()
    });
    found.extend(parts.into_iter().flatten());
    found
}

pub struct Tree {
    skip: Skip,
    pub device: u64,
    pub nodes: Vec<Node>,
    free: Vec<u32>,
    pub keys: HashTable<u32>,
    key_hash: RandomState,
    holders: HashMap<u64, Vec<u32>>,
    pub dirty: HashMap<u32, f64>,
    ring: VecDeque<(u32, u32)>,
    overflowed: bool,
    pub named: HashSet<u32>,
    pub last_event: f64,
    pub events: u64,
    pub scans: u64,
    verified: usize,
    pass_started: f64,
    pub pass_seconds: f64,
    pub walk_seconds: f64,
    pub floor: f64,
    pub revision: u64,
    pub settled_from: Option<f64>,
    pub fd: i32,
    pub root: u32,
    buffer: Vec<u8>,
}

impl Tree {
    pub fn new(root: &str, skip: Skip) -> std::io::Result<Tree> {
        let info = sys::lstat(root).ok_or_else(std::io::Error::last_os_error)?;
        let fd = sys::fanotify(
            sys::FAN_UNLIMITED_QUEUE | sys::FAN_REPORT_DFID_NAME | sys::FAN_NONBLOCK,
        )?;
        sys::fanotify_mark(
            fd,
            sys::FAN_MARK_ADD | sys::FAN_MARK_FILESYSTEM,
            WATCHED,
            libc::AT_FDCWD,
            Some(root),
        )?;
        let mut tree = Tree::detached(root, info.ino, info.dev, within_device(info.dev, skip));
        tree.fd = fd;
        let started = clock();
        tree.ring.push_back((tree.root, 0));
        tree.walk(vec![tree.root]);
        tree.walk_seconds = clock() - started;
        Ok(tree)
    }

    pub fn detached(root: &str, ino: u64, device: u64, skip: Skip) -> Tree {
        let node = Node {
            parent: NONE,
            name: root.into(),
            ino,
            attached: true,
            ..Default::default()
        };
        Tree {
            skip,
            device,
            nodes: vec![node],
            free: Vec::new(),
            keys: HashTable::new(),
            key_hash: RandomState::new(),
            holders: HashMap::new(),
            dirty: HashMap::new(),
            ring: VecDeque::new(),
            overflowed: false,
            named: HashSet::new(),
            last_event: 0.0,
            events: 0,
            scans: 0,
            verified: 0,
            pass_started: clock(),
            pass_seconds: 0.0,
            walk_seconds: 0.0,
            floor: SETTLE,
            revision: 0,
            settled_from: None,
            fd: -1,
            root: 0,
            buffer: Vec::new(),
        }
    }

    pub fn node(&self, id: u32) -> &Node {
        &self.nodes[id as usize]
    }

    pub fn path(&self, mut id: u32) -> String {
        let mut parts = Vec::new();
        while self.nodes[id as usize].parent != NONE {
            parts.push(&*self.nodes[id as usize].name);
            id = self.nodes[id as usize].parent;
        }
        let mut out = String::from(&*self.nodes[id as usize].name);
        for part in parts.iter().rev() {
            if !out.ends_with('/') {
                out.push('/');
            }
            out.push_str(part);
        }
        out
    }

    pub fn child(&self, id: u32, name: &str) -> Option<u32> {
        let children = &self.nodes[id as usize].children;
        children
            .binary_search_by(|child| (*self.nodes[*child as usize].name).cmp(name))
            .ok()
            .map(|index| children[index])
    }

    pub fn compact(&mut self) {
        self.nodes.shrink_to_fit();
        let (nodes, state) = (&self.nodes, &self.key_hash);
        self.keys
            .shrink_to_fit(|id| state.hash_one(nodes[*id as usize].key.as_deref().unwrap_or(&[])));
        self.holders.shrink_to_fit();
    }

    pub fn find(&self, path: &str) -> Option<u32> {
        let base = &*self.nodes[self.root as usize].name;
        let relative = path.strip_prefix(base)?;
        let relative = relative.trim_start_matches('/');
        let mut id = self.root;
        if relative.is_empty() || relative == "." {
            return Some(id);
        }
        for part in relative.split('/').filter(|part| !part.is_empty()) {
            id = self.child(id, part)?;
        }
        Some(id)
    }

    fn propagate(&mut self, mut id: u32, delta: i64) {
        while id != NONE && delta != 0 {
            let node = &mut self.nodes[id as usize];
            node.total = (node.total as i64 + delta) as u64;
            id = node.parent;
        }
    }

    fn raise_newest(&mut self, mut id: u32, newest: i64) {
        while id != NONE && newest > self.nodes[id as usize].newest {
            self.nodes[id as usize].newest = newest;
            id = self.nodes[id as usize].parent;
        }
    }

    fn set_own(&mut self, id: u32) {
        let node = &mut self.nodes[id as usize];
        let own = node.dir_blocks + node.files + node.shared;
        let delta = own as i64 - node.own as i64;
        node.own = own;
        self.propagate(id, delta);
    }

    fn owned(&self, id: u32) -> u64 {
        match &self.nodes[id as usize].multi {
            Some(multi) => multi
                .iter()
                .filter(|(ino, _)| self.holders.get(ino).and_then(|list| list.first()) == Some(&id))
                .map(|(_, blocks)| *blocks)
                .sum(),
            None => 0,
        }
    }

    fn set_multi(&mut self, id: u32, mut multi: Vec<(u64, u64)>) {
        multi.sort_unstable();
        multi.dedup_by_key(|entry| entry.0);
        let old = self.nodes[id as usize].multi.take().unwrap_or_default();
        let has = |list: &[(u64, u64)], ino: u64| {
            list.binary_search_by_key(&ino, |entry| entry.0).is_ok()
        };
        let mut touched = Vec::new();
        for ino in old
            .iter()
            .map(|entry| &entry.0)
            .filter(|ino| !has(&multi, **ino))
        {
            if let Some(list) = self.holders.get_mut(ino) {
                let first = list.first().copied();
                list.retain(|other| *other != id);
                if list.is_empty() {
                    self.holders.remove(ino);
                } else if first == Some(id) {
                    touched.push(list[0]);
                }
            }
        }
        for ino in multi
            .iter()
            .map(|entry| entry.0)
            .filter(|ino| !has(&old, *ino))
        {
            self.holders.entry(ino).or_default().push(id);
        }
        self.nodes[id as usize].multi = if multi.is_empty() {
            None
        } else {
            Some(multi.into_boxed_slice())
        };
        self.nodes[id as usize].shared = self.owned(id);
        for other in touched {
            if !self.nodes[other as usize].attached {
                continue;
            }
            self.nodes[other as usize].shared = self.owned(other);
            self.set_own(other);
        }
    }

    fn detach(&mut self, id: u32) {
        let parent = self.nodes[id as usize].parent;
        let total = self.nodes[id as usize].total;
        self.propagate(parent, -(total as i64));
        let mut subtree = vec![id];
        let mut index = 0;
        while index < subtree.len() {
            let current = subtree[index];
            self.nodes[current as usize].attached = false;
            subtree.extend(self.nodes[current as usize].children.iter().copied());
            index += 1;
        }
        for current in subtree {
            if let Some(key) = self.nodes[current as usize].key.as_deref() {
                if let Ok(found) = self
                    .keys
                    .find_entry(self.key_hash.hash_one(key), |other| *other == current)
                {
                    found.remove();
                }
            }
            self.nodes[current as usize].key = None;
            if self.nodes[current as usize].multi.is_some() {
                self.set_multi(current, Vec::new());
            }
            self.named.remove(&current);
            self.dirty.remove(&current);
            let node = &mut self.nodes[current as usize];
            node.children = Box::default();
            self.free.push(current);
        }
    }

    fn allocate(&mut self, node: Node) -> u32 {
        match self.free.pop() {
            Some(id) => {
                let generation = self.nodes[id as usize].generation.wrapping_add(1);
                self.nodes[id as usize] = Node { generation, ..node };
                id
            }
            None => {
                self.nodes.push(node);
                (self.nodes.len() - 1) as u32
            }
        }
    }

    fn vanished(&mut self, id: u32) {
        let parent = self.nodes[id as usize].parent;
        if parent != NONE && self.nodes[parent as usize].attached {
            self.dirty.entry(parent).or_insert(0.0);
        }
    }

    pub fn scan(&mut self, id: u32) -> Vec<u32> {
        let path = self.path(id);
        match read(
            &path,
            self.device,
            &*self.skip,
            self.nodes[id as usize].key.is_none(),
        ) {
            Some(raw) => self.apply(id, raw),
            None => {
                self.vanished(id);
                Vec::new()
            }
        }
    }

    fn apply(&mut self, id: u32, raw: Raw) -> Vec<u32> {
        if let Some(acl) = raw.acl {
            self.nodes[id as usize].acl = acl;
        }
        if let Some(key) = raw.key {
            let hash = self.key_hash.hash_one(key.as_slice());
            self.nodes[id as usize].key = sys::Key::of(&key);
            let nodes = &self.nodes;
            let key = nodes[id as usize].key.as_deref();
            match self
                .keys
                .find_mut(hash, |other| nodes[*other as usize].key.as_deref() == key)
            {
                Some(slot) => *slot = id,
                None => {
                    let state = &self.key_hash;
                    self.keys.insert_unique(hash, id, |other| {
                        state.hash_one(nodes[*other as usize].key.as_deref().unwrap_or(&[]))
                    });
                }
            }
        }
        let before = (
            self.nodes[id as usize].total,
            self.nodes[id as usize].newest,
            self.nodes[id as usize].children.len(),
        );
        let old = std::mem::take(&mut self.nodes[id as usize].children);
        let mut used = vec![false; old.len()];
        let mut kept = Vec::with_capacity(raw.dirs.len());
        let mut new = Vec::new();
        for (name, ino) in raw.dirs {
            let found = old
                .binary_search_by(|child| (*self.nodes[*child as usize].name).cmp(&*name))
                .ok();
            match found {
                Some(index) if self.nodes[old[index] as usize].ino == ino => {
                    used[index] = true;
                    kept.push(old[index]);
                }
                _ => {
                    let named = NAMED.contains(&&*name);
                    let created = self.allocate(Node {
                        parent: id,
                        name,
                        ino,
                        attached: true,
                        ..Default::default()
                    });
                    if named {
                        self.named.insert(created);
                    }
                    kept.push(created);
                    new.push(created);
                }
            }
        }
        self.nodes[id as usize].children = kept.into_boxed_slice();
        for (index, child) in old.iter().enumerate() {
            if !used[index] {
                self.detach(*child);
            }
        }
        self.nodes[id as usize].dir_blocks = raw.blocks;
        self.nodes[id as usize].files = raw.files;
        self.set_multi(id, raw.multi);
        self.set_own(id);
        let children_newest = self.nodes[id as usize]
            .children
            .iter()
            .map(|child| self.nodes[*child as usize].newest)
            .max()
            .unwrap_or(0);
        let node = &mut self.nodes[id as usize];
        node.own_newest = raw.newest;
        node.newest = raw.newest.max(children_newest);
        let (parent, value) = (node.parent, node.newest);
        self.raise_newest(parent, value);
        let node = &mut self.nodes[id as usize];
        node.scanned = clock();
        node.cost = raw.cost as f32;
        if before != (node.total, node.newest, node.children.len()) {
            self.revision += 1;
        }
        self.scans += 1;
        for child in &new {
            self.ring
                .push_back((*child, self.nodes[*child as usize].generation));
        }
        new
    }

    pub fn walk(&mut self, ids: Vec<u32>) {
        if ids.is_empty() {
            return;
        }
        let seeds: Vec<String> = ids.iter().map(|id| self.path(*id)).collect();
        let mut raws = gather(self.device, &self.skip, seeds.clone());
        let mut stack: Vec<(u32, String)> = ids.into_iter().zip(seeds).collect();
        while let Some((id, path)) = stack.pop() {
            match raws.remove(&path) {
                Some(raw) => {
                    for child in self.apply(id, raw) {
                        let child_path = join(&path, &self.nodes[child as usize].name);
                        stack.push((child, child_path));
                    }
                }
                None => self.vanished(id),
            }
        }
    }

    pub fn drain(&mut self, mut unknown: impl FnMut(&[u8])) {
        let now = clock();
        let mut buffer = std::mem::take(&mut self.buffer);
        buffer.resize(1 << 20, 0);
        for _ in 0..DRAIN_READS {
            let Some(count) = sys::read_nonblocking(self.fd, &mut buffer) else {
                break;
            };
            let data = &buffer[..count];
            let mut offset = 0;
            while offset + sys::EVENT_SIZE <= data.len() {
                let length = sys::u32_at(data, offset) as usize;
                let header = u16::from_ne_bytes([data[offset + 6], data[offset + 7]]) as usize;
                let mask = sys::u64_at(data, offset + 8);
                if length == 0 {
                    break;
                }
                self.events += 1;
                if mask & sys::FAN_Q_OVERFLOW != 0 {
                    self.overflowed = true;
                }
                let mut cursor = offset + header;
                while cursor + 20 <= offset + length {
                    let size = u16::from_ne_bytes([data[cursor + 2], data[cursor + 3]]) as usize;
                    let handle_bytes = sys::u32_at(data, cursor + 12) as usize;
                    let mut key = Vec::with_capacity(4 + handle_bytes);
                    key.extend_from_slice(&data[cursor + 16..cursor + 20]);
                    key.extend_from_slice(&data[cursor + 20..cursor + 20 + handle_bytes]);
                    let nodes = &self.nodes;
                    match self
                        .keys
                        .find(self.key_hash.hash_one(key.as_slice()), |other| {
                            nodes[*other as usize].key.as_deref() == Some(key.as_slice())
                        }) {
                        Some(id) => {
                            self.dirty.entry(*id).or_insert(now);
                        }
                        None => unknown(&key),
                    }
                    if size == 0 {
                        break;
                    }
                    cursor += size;
                }
                offset += length;
            }
            self.last_event = now;
        }
        self.buffer = buffer;
    }

    pub fn mark(&mut self, id: u32) {
        if self.nodes[id as usize].attached {
            self.dirty.entry(id).or_insert(0.0);
        }
    }

    fn due(&self, id: u32, since: f64) -> f64 {
        let cost = self.nodes[id as usize].cost as f64 * COST_FACTOR;
        (since + cost.max(self.floor)).max(self.nodes[id as usize].scanned + cost)
    }

    pub fn next_due(&self) -> Option<f64> {
        self.dirty
            .iter()
            .map(|(id, since)| self.due(*id, *since))
            .min_by(f64::total_cmp)
    }

    pub fn settle(&mut self, deadline: f64, force: bool) {
        if self.overflowed {
            self.overflowed = false;
            let ring: Vec<(u32, u32)> = self.ring.iter().copied().collect();
            for (id, generation) in ring {
                if self.nodes[id as usize].generation == generation {
                    self.mark(id);
                }
            }
        }
        let now = clock();
        let ready: Vec<u32> = self
            .dirty
            .iter()
            .filter(|(id, since)| force || self.due(**id, **since) <= now)
            .map(|(id, _)| *id)
            .collect();
        for id in ready {
            if clock() > deadline {
                return;
            }
            let Some(since) = self.dirty.remove(&id) else {
                continue;
            };
            if self.nodes[id as usize].attached {
                self.settled_from = Some(self.settled_from.map_or(since, |from| from.min(since)));
                let new = self.scan(id);
                self.walk(new);
            }
        }
    }

    pub fn verify(&mut self, deadline: f64) {
        while clock() < deadline {
            let Some((id, generation)) = self.ring.pop_front() else {
                break;
            };
            if !self.nodes[id as usize].attached || self.nodes[id as usize].generation != generation
            {
                continue;
            }
            let new = self.scan(id);
            self.walk(new);
            self.ring.push_back((id, generation));
            self.verified += 1;
            if self.verified >= self.ring.len() {
                self.pass_seconds = clock() - self.pass_started;
                self.pass_started = clock();
                self.verified = 0;
            }
        }
    }

    pub fn size(&self, path: &str) -> u64 {
        if let Some(id) = self.find(path) {
            if self.nodes[id as usize].attached {
                return self.nodes[id as usize].total;
            }
        }
        match sys::lstat(path) {
            Some(info) if info.dev == self.device && !sys::is_dir(info.mode) => info.blocks,
            _ => 0,
        }
    }

    pub fn newest(&self, path: &str) -> i64 {
        if let Some(id) = self.find(path) {
            if self.nodes[id as usize].attached {
                return self.nodes[id as usize].newest;
            }
        }
        sys::lstat(path).map(|info| info.mtime).unwrap_or(0)
    }

    pub fn acl_dirs(&self) -> Vec<String> {
        let mut found = Vec::new();
        let mut stack = vec![self.root];
        while let Some(id) = stack.pop() {
            if self.nodes[id as usize].acl {
                found.push(self.path(id));
            }
            stack.extend(self.nodes[id as usize].children.iter().copied());
        }
        found
    }
}

pub struct Resolver {
    mount: i32,
    pub cache: HashMap<Vec<u8>, Option<String>>,
}

impl Resolver {
    pub fn new(mount: &str) -> Option<Resolver> {
        Some(Resolver {
            mount: sys::open_dir(mount)?,
            cache: HashMap::new(),
        })
    }

    pub fn open(&self, key: &[u8], flags: i32) -> Option<i32> {
        sys::open_by_handle(self.mount, key, flags)
    }

    pub fn path(&mut self, key: &[u8]) -> Option<String> {
        if let Some(found) = self.cache.get(key) {
            return found.clone();
        }
        if self.cache.len() > 200_000 {
            self.cache.clear();
        }
        let found = self.open(key, libc::O_PATH).and_then(|fd| {
            let path = sys::fd_path(fd);
            sys::close(fd);
            path
        });
        self.cache.insert(key.to_vec(), found.clone());
        found
    }
}

pub fn store_path(path: &str) -> Option<String> {
    let name = path.strip_prefix(STORE)?.split('/').next()?;
    if name.is_empty() || name.starts_with('.') {
        return None;
    }
    Some(format!("{STORE}{name}"))
}

pub struct Opens {
    pub fd: i32,
    mount: String,
    resolver: Resolver,
    root_key: Option<Vec<u8>>,
    flush_seconds: f64,
    flushed: f64,
    ignoring: bool,
    pub events: u64,
    pub ignored: u64,
    pid: i32,
    buffer: Vec<u8>,
}

impl Opens {
    pub fn new(mount: &str, flush_seconds: f64) -> std::io::Result<Opens> {
        let fd = sys::fanotify(sys::FAN_REPORT_DFID_NAME | sys::FAN_NONBLOCK)?;
        sys::fanotify_mark(
            fd,
            sys::FAN_MARK_ADD | sys::FAN_MARK_MOUNT,
            sys::FAN_OPEN | sys::FAN_OPEN_EXEC,
            libc::AT_FDCWD,
            Some(mount),
        )?;
        let resolver = Resolver::new(mount).ok_or_else(std::io::Error::last_os_error)?;
        Ok(Opens {
            fd,
            mount: mount.into(),
            resolver,
            root_key: sys::handle_key(mount, 0),
            flush_seconds,
            flushed: clock(),
            ignoring: true,
            events: 0,
            ignored: 0,
            pid: std::process::id() as i32,
            buffer: vec![0u8; 1 << 20],
        })
    }

    fn ignore(&mut self, key: &[u8]) {
        if !self.ignoring {
            return;
        }
        let Some(fd) = self.resolver.open(key, libc::O_RDONLY | libc::O_DIRECTORY) else {
            return;
        };
        let flags = sys::FAN_MARK_ADD | sys::FAN_MARK_IGNORE | sys::FAN_MARK_IGNORED_SURV_MODIFY;
        if sys::fanotify_mark(
            self.fd,
            flags,
            sys::FAN_OPEN | sys::FAN_OPEN_EXEC | sys::FAN_EVENT_ON_CHILD,
            fd,
            None,
        )
        .is_err()
        {
            self.ignoring = false;
        } else {
            self.ignored += 1;
        }
        sys::close(fd);
    }

    pub fn drain(&mut self, mut touch: impl FnMut(&str, i64, i32, bool)) {
        let now = sys::now() as i64;
        if clock() - self.flushed >= self.flush_seconds {
            let _ = sys::fanotify_mark(
                self.fd,
                sys::FAN_MARK_FLUSH,
                0,
                libc::AT_FDCWD,
                Some(&self.mount),
            );
            self.resolver.cache.clear();
            self.flushed = clock();
            self.ignored = 0;
        }
        let mut buffer = std::mem::take(&mut self.buffer);
        buffer.resize(1 << 20, 0);
        for _ in 0..DRAIN_READS {
            let Some(count) = sys::read_nonblocking(self.fd, &mut buffer) else {
                break;
            };
            let data = &buffer[..count];
            let mut offset = 0;
            while offset + sys::EVENT_SIZE <= data.len() {
                let length = sys::u32_at(data, offset) as usize;
                if length == 0 {
                    break;
                }
                let header = u16::from_ne_bytes([data[offset + 6], data[offset + 7]]) as usize;
                let pid = sys::i32_at(data, offset + 20);
                let exec = sys::u64_at(data, offset + 8) & sys::FAN_OPEN_EXEC != 0;
                self.events += 1;
                let cursor = offset + header;
                if pid != self.pid && cursor + 20 <= offset + length {
                    let handle_bytes = sys::u32_at(data, cursor + 12) as usize;
                    let mut key = Vec::with_capacity(4 + handle_bytes);
                    key.extend_from_slice(&data[cursor + 16..cursor + 20]);
                    key.extend_from_slice(&data[cursor + 20..cursor + 20 + handle_bytes]);
                    if Some(&key) == self.root_key.as_ref() {
                        let raw = &data[cursor + 20 + handle_bytes..offset + length];
                        let name = raw.split(|byte| *byte == 0).next().unwrap_or_default();
                        touch(
                            &format!("{STORE}{}", String::from_utf8_lossy(name)),
                            now,
                            pid,
                            exec,
                        );
                    } else {
                        let known = self.resolver.cache.contains_key(&key);
                        if let Some(found) =
                            self.resolver.path(&key).as_deref().and_then(store_path)
                        {
                            touch(&found, now, pid, exec);
                            if !known {
                                self.ignore(&key);
                            }
                        }
                    }
                }
                offset += length;
            }
        }
        self.buffer = buffer;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn foreign_mounts_are_named_without_stat() {
        let root = libc::makedev(259, 5);
        let mountinfo = "\
26 1 259:5 / / rw,relatime shared:1 - ext4 /dev/nvme0n1p5 rw
27 26 259:5 /nix/store /nix/store ro,relatime shared:2 - ext4 /dev/nvme0n1p5 rw
28 26 0:25 / /proc rw shared:3 - proc proc rw
91 26 0:58 / /mnt/nas\\040share rw shared:40 - cifs //pi/nas rw
92 26 259:5 / /tmp/scratch/root ro,relatime shared:1 - ext4 /dev/nvme0n1p5 rw";
        let mounts = foreign_mounts(mountinfo, root);
        assert_eq!(
            mounts,
            HashSet::from([
                "/proc".to_string(),
                "/mnt/nas share".to_string(),
                "/tmp/scratch/root".to_string()
            ])
        );
        let skip = within_device(root, std::sync::Arc::new(|_: &str, _: &str| false));
        assert!(skip("/", "proc") || !std::path::Path::new("/proc/self").exists());
        assert!(!skip("/", "home"));
        assert!(under_any("/mnt/nas share/a/b", &mounts));
        assert!(under_any("/proc", &mounts));
        assert!(!under_any("/mnt/nas", &mounts));
        assert!(!under_any("/home/x", &mounts));
    }
}
