// Native store collection under nix's own GC protocol: the global lock, the temp-root socket, validity in its database.

use crate::{remove, store, sys};
use regex::bytes::Regex;
use rusqlite::{Connection, ErrorCode, OpenFlags, TransactionBehavior};
use std::collections::{HashMap, HashSet};
use std::ffi::CString;
use std::hash::{Hash, Hasher};
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, MutexGuard, OnceLock};
use std::time::{Duration, Instant};

const LOGICAL: &str = "/nix/store/";
const SCHEMA: &str = "10";
const CHUNK: usize = 256;
const READERS: usize = 16;
const HASH_PART: usize = 32;
const NAME_LENGTH: usize = 52;
const NIX32: &[u8; 32] = b"0123456789abcdfghijklmnpqrsvwxyz";

const RECORD: usize = 40;
const KERNEL_ROOTS: [&str; 3] = [
    "/proc/sys/kernel/modprobe",
    "/proc/sys/kernel/fbsplash",
    "/proc/sys/kernel/poweroff_cmd",
];

type Key = [u8; HASH_PART];

pub struct Layout {
    pub store: String,
    pub state: String,
    pub links_index: Option<String>,
}

impl Layout {
    pub fn system() -> Layout {
        let state =
            std::env::var("LEDGER_STATE_DIR").unwrap_or_else(|_| "/var/lib/disk-ledger".into());
        Layout {
            store: "/nix/store".into(),
            state: "/nix/var/nix".into(),
            links_index: Some(format!("{state}/links.idx")),
        }
    }
}

#[derive(Default)]
pub struct LinkScan {
    pub entries: Vec<(u64, [u8; 32])>,
    pub strays: Vec<(String, u64)>,
    pub complete: bool,
}

pub fn scan_links(path: &str) -> LinkScan {
    let mut scan = LinkScan::default();
    let Some(dir) = sys::open_dir(path) else {
        return scan;
    };
    scan.complete = sys::read_names(dir, |name, ino| match decode(name) {
        Some(hash) => scan.entries.push((ino, hash)),
        None => scan
            .strays
            .push((String::from_utf8_lossy(name).into_owned(), ino)),
    });
    sys::close(dir);
    scan.entries.sort_unstable_by_key(|entry| entry.0);
    scan
}

pub fn publish(file: &str, entries: &[(u64, [u8; 32])]) -> std::io::Result<()> {
    let mut bytes = Vec::with_capacity(entries.len() * RECORD);
    for (ino, hash) in entries {
        bytes.extend_from_slice(&ino.to_le_bytes());
        bytes.extend_from_slice(hash);
    }
    let partial = format!("{file}.partial");
    std::fs::write(&partial, bytes)?;
    std::fs::rename(&partial, file)
}

pub fn link_name(hash: &[u8; 32]) -> String {
    encode(hash).to_string_lossy().into_owned()
}

pub fn idle() {
    if let Ok(mut held) = COLLECTOR.try_lock() {
        if let Some(collector) = held.as_mut() {
            collector.index = Index::default();
            collector.processes = Processes::default();
        }
    }
}

#[derive(Default, Debug)]
pub struct Report {
    pub deleted: u64,
    pub entries: u64,
    pub slowest: (f64, u64, String),
    pub links: u64,
    pub refused: HashSet<String>,
    pub causes: Vec<(String, &'static str)>,
    pub strays: Vec<(String, i32)>,
    pub error: Option<String>,
    pub waited: f64,
    pub roots: f64,
    pub rescanned: bool,
    pub database: f64,
    pub warming: f64,
    pub unlinking: f64,
    pub linking: f64,
    pub indexing: f64,
}

impl Report {
    pub fn milliseconds(&self) -> serde_json::Value {
        let round = |seconds: f64| (seconds * 1e4).round() / 10.0;
        serde_json::json!({"lock": round(self.waited), "roots": round(self.roots), "rescanned": self.rescanned, "database": round(self.database), "prefetch": round(self.warming), "unlink": round(self.unlinking), "index": round(self.indexing), "links": round(self.linking)})
    }
}

#[derive(Default)]
struct Shared {
    temp: HashSet<String>,
    flight: HashSet<String>,
}

struct Client {
    stream: UnixStream,
    buffer: Vec<u8>,
    held: Option<String>,
}

#[derive(Default)]
struct Index {
    entries: Vec<(u64, [u8; 32])>,
    origin: Option<(i64, i64, u64)>,
}

struct Opens {
    fd: i32,
}

impl Drop for Opens {
    fn drop(&mut self) {
        sys::close(self.fd);
    }
}

#[derive(Default)]
struct Processes {
    roots: HashSet<Key>,
    seen: HashMap<i32, (u64, u64)>,
    opens: Option<Opens>,
    valid: bool,
}

struct Collector {
    store: String,
    state: String,
    links_index: Option<String>,
    db: Connection,
    index: Index,
    processes: Processes,
}

static COLLECTOR: Mutex<Option<Collector>> = Mutex::new(None);

fn locked<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

fn failure(what: &str) -> String {
    format!("{what}: {}", std::io::Error::last_os_error())
}

fn key(path: &str) -> Option<Key> {
    hash_part(path)?.as_bytes().try_into().ok()
}

fn mention(bytes: &[u8], roots: &mut HashSet<Key>) {
    static MENTION: OnceLock<Regex> = OnceLock::new();
    let pattern = MENTION.get_or_init(|| Regex::new(r"/nix/store/[0-9a-z]{32}").unwrap());
    for found in pattern.find_iter(bytes) {
        if let Ok(hash) = found.as_bytes()[LOGICAL.len()..].try_into() {
            roots.insert(hash);
        }
    }
}

fn target(link: &str) -> Option<Vec<u8>> {
    std::fs::read_link(link)
        .ok()
        .map(|found| found.as_os_str().as_bytes().to_vec())
}

fn identity(pid: i32) -> Option<(u64, u64)> {
    let exe = target(&format!("/proc/{pid}/exe"))?;
    let stat = std::fs::read(format!("/proc/{pid}/stat")).ok()?;
    let after = stat.iter().rposition(|byte| *byte == b')')?;
    let started = String::from_utf8_lossy(&stat[after + 1..])
        .split_ascii_whitespace()
        .nth(19)?
        .parse()
        .ok()?;
    let mut hasher = std::hash::DefaultHasher::new();
    exe.hash(&mut hasher);
    target(&format!("/proc/{pid}/cwd")).hash(&mut hasher);
    Some((started, hasher.finish()))
}

fn scan_process(pid: i32, roots: &mut HashSet<Key>) {
    for name in ["exe", "cwd"] {
        if let Some(found) = target(&format!("/proc/{pid}/{name}")) {
            mention(&found, roots);
        }
    }
    if let Ok(fds) = std::fs::read_dir(format!("/proc/{pid}/fd")) {
        for fd in fds.flatten() {
            if let Ok(found) = std::fs::read_link(fd.path()) {
                mention(found.as_os_str().as_bytes(), roots);
            }
        }
    }
    for name in ["maps", "environ"] {
        if let Ok(text) = std::fs::read(format!("/proc/{pid}/{name}")) {
            mention(&text, roots);
        }
    }
}

fn processes() -> Vec<i32> {
    let Ok(entries) = std::fs::read_dir("/proc") else {
        return Vec::new();
    };
    entries
        .flatten()
        .filter_map(|entry| entry.file_name().to_str()?.parse().ok())
        .collect()
}

impl Opens {
    fn arm(store: &str) -> Option<Opens> {
        let fd = sys::fanotify(sys::FAN_NONBLOCK).ok()?;
        let opens = Opens { fd };
        sys::fanotify_mark(
            fd,
            sys::FAN_MARK_ADD | sys::FAN_MARK_MOUNT,
            sys::FAN_OPEN | sys::FAN_OPEN_EXEC,
            libc::AT_FDCWD,
            Some(store),
        )
        .ok()?;
        Some(opens)
    }

    fn drain(&self, roots: &mut HashSet<Key>, executed: &mut Vec<i32>) -> bool {
        let own = std::process::id() as i32;
        let mut complete = true;
        let mut buffer = vec![0u8; 1 << 16];
        while let Some(count) = sys::read_nonblocking(self.fd, &mut buffer) {
            let mut offset = 0;
            while offset + sys::EVENT_SIZE <= count {
                let length = sys::u32_at(&buffer, offset) as usize;
                if length < sys::EVENT_SIZE {
                    break;
                }
                let mask = sys::u64_at(&buffer, offset + 8);
                let (fd, pid) = (
                    sys::i32_at(&buffer, offset + 16),
                    sys::i32_at(&buffer, offset + 20),
                );
                if mask & sys::FAN_Q_OVERFLOW != 0 {
                    complete = false;
                }
                if fd >= 0 {
                    if pid != own {
                        if let Some(found) = target(&format!("/proc/self/fd/{fd}")) {
                            mention(&found, roots);
                        }
                        if mask & sys::FAN_OPEN_EXEC != 0 {
                            executed.push(pid);
                        }
                    }
                    sys::close(fd);
                }
                offset += length;
            }
        }
        complete
    }
}

impl Processes {
    fn kernel(&mut self) {
        for file in KERNEL_ROOTS {
            if let Ok(text) = std::fs::read(file) {
                mention(&text, &mut self.roots);
            }
        }
    }

    fn full(&mut self) {
        self.roots.clear();
        self.seen.clear();
        for pid in processes() {
            if let Some(found) = identity(pid) {
                scan_process(pid, &mut self.roots);
                self.seen.insert(pid, found);
            }
        }
        self.kernel();
    }

    fn changed(&mut self, executed: &[i32]) {
        let mut alive = HashSet::new();
        for pid in processes() {
            let Some(found) = identity(pid) else { continue };
            alive.insert(pid);
            if self.seen.get(&pid) != Some(&found) || executed.contains(&pid) {
                scan_process(pid, &mut self.roots);
                self.seen.insert(pid, found);
            }
        }
        self.seen.retain(|pid, _| alive.contains(pid));
        self.kernel();
    }

    fn watch(&mut self) -> Vec<i32> {
        let mut executed = Vec::new();
        if let Some(opens) = &self.opens {
            if !opens.drain(&mut self.roots, &mut executed) {
                self.valid = false;
            }
        }
        executed
    }

    fn refresh(&mut self, store: &str) -> bool {
        let executed = self.watch();
        if self.valid {
            self.changed(&executed);
            return false;
        }
        if self.opens.is_none() {
            self.opens = Opens::arm(store);
        }
        self.full();
        self.valid = self.opens.is_some();
        true
    }
}

fn hash_part(path: &str) -> Option<&str> {
    let name = path.strip_prefix(LOGICAL)?;
    let name = name.split('/').next()?;
    (name.len() > HASH_PART && name.is_char_boundary(HASH_PART)).then(|| &name[..HASH_PART])
}

fn decode(name: &[u8]) -> Option<[u8; 32]> {
    if name.len() != NAME_LENGTH {
        return None;
    }
    let mut hash = [0u8; 32];
    for (place, byte) in name.iter().rev().enumerate() {
        let digit = NIX32.iter().position(|other| other == byte)? as u16;
        let (index, shift) = (place * 5 / 8, place * 5 % 8);
        hash[index] |= (digit << shift) as u8;
        let carry = (digit >> (8 - shift)) as u8;
        if index + 1 < hash.len() {
            hash[index + 1] |= carry;
        } else if carry != 0 {
            return None;
        }
    }
    Some(hash)
}

fn encode(hash: &[u8; 32]) -> CString {
    let mut name = vec![0u8; NAME_LENGTH];
    for place in 0..NAME_LENGTH {
        let (index, shift) = (place * 5 / 8, place * 5 % 8);
        let low = (hash[index] as u16) >> shift;
        let high = if index + 1 < hash.len() {
            (hash[index + 1] as u16) << (8 - shift)
        } else {
            0
        };
        name[NAME_LENGTH - place - 1] = NIX32[((low | high) & 0x1f) as usize];
    }
    CString::new(name).unwrap_or_default()
}

fn stamp(path: &str) -> Option<(i64, i64, u64)> {
    let name = sys::cstr(path);
    let mut info: libc::stat = unsafe { std::mem::zeroed() };
    (unsafe { libc::stat(name.as_ptr(), &mut info) } == 0).then_some((
        info.st_mtime,
        info.st_mtime_nsec,
        info.st_size as u64,
    ))
}

impl Index {
    fn load(&mut self, links: &str, published: Option<&str>) {
        self.origin = None;
        if let Some(file) = published {
            let before = stamp(file);
            if let Ok(bytes) = std::fs::read(file) {
                if bytes.len() % RECORD == 0 {
                    self.entries = bytes
                        .chunks_exact(RECORD)
                        .filter_map(|record| {
                            Some((
                                u64::from_le_bytes(record[..8].try_into().ok()?),
                                record[8..].try_into().ok()?,
                            ))
                        })
                        .collect();
                    self.origin = before;
                    return;
                }
            }
        }
        let before = stamp(links);
        let scan = scan_links(links);
        self.entries = scan.entries;
        if scan.complete {
            self.origin = before;
        }
    }

    fn name(&self, ino: u64) -> Option<CString> {
        let found = self
            .entries
            .binary_search_by_key(&ino, |entry| entry.0)
            .ok()?;
        Some(encode(&self.entries[found].1))
    }
}

fn drop_orphan(dir: i32, name: &CString) -> u64 {
    let mut info: libc::stat = unsafe { std::mem::zeroed() };
    let orphan = unsafe { libc::fstatat(dir, name.as_ptr(), &mut info, libc::AT_SYMLINK_NOFOLLOW) }
        == 0
        && info.st_nlink == 1;
    u64::from(orphan && unsafe { libc::unlinkat(dir, name.as_ptr(), 0) } == 0)
}

fn temp_roots(state: &str) -> Result<Vec<Key>, String> {
    let directory = format!("{state}/temproots");
    let entries = match std::fs::read_dir(&directory) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(format!("{directory}: {error}")),
    };
    let mut found = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|error| format!("{directory}: {error}"))?;
        if entry.file_name().as_encoded_bytes().first() == Some(&b'.') {
            continue;
        }
        let mut file = match std::fs::File::options()
            .read(true)
            .write(true)
            .open(entry.path())
        {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => return Err(format!("{}: {error}", entry.path().display())),
        };
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
            continue;
        }
        let mut contents = Vec::new();
        file.read_to_end(&mut contents)
            .map_err(|error| format!("{}: {error}", entry.path().display()))?;
        for path in contents.split(|byte| *byte == 0) {
            found.extend(key(&String::from_utf8_lossy(path)));
        }
    }
    Ok(found)
}

fn writable(store: &str) -> Result<(), String> {
    let path = sys::cstr(store);
    let mut info: libc::statvfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::statvfs(path.as_ptr(), &mut info) } != 0 {
        return Err(failure(store));
    }
    if info.f_flag & libc::ST_RDONLY == 0 {
        return Ok(());
    }
    if unsafe { libc::unshare(libc::CLONE_NEWNS) } != 0 {
        return Err(failure("unshare"));
    }
    if unsafe {
        libc::mount(
            std::ptr::null(),
            path.as_ptr(),
            c"none".as_ptr(),
            libc::MS_REMOUNT | libc::MS_BIND,
            std::ptr::null(),
        )
    } != 0
    {
        return Err(failure("remount"));
    }
    Ok(())
}

fn refuse(path: &str, references: &HashMap<String, Vec<String>>, refused: &mut HashSet<String>) {
    let mut stack = vec![path.to_string()];
    while let Some(path) = stack.pop() {
        if let Some(below) = references.get(&path) {
            stack.extend(
                below
                    .iter()
                    .filter(|other| !refused.contains(*other))
                    .cloned(),
            );
        }
        refused.insert(path);
    }
}

fn answer(client: &mut Client, shared: &Mutex<Shared>) -> bool {
    while let Some(end) = client.buffer.iter().position(|byte| *byte == b'\n') {
        let line: Vec<u8> = client.buffer.drain(..=end).collect();
        let text = String::from_utf8_lossy(&line[..end]).into_owned();
        if let Some(hash) = hash_part(&text) {
            let mut state = locked(shared);
            state.temp.insert(hash.to_string());
            if state.flight.contains(hash) {
                client.held = Some(hash.to_string());
                return true;
            }
        }
        if client.stream.write_all(b"1").is_err() {
            return false;
        }
    }
    true
}

fn serve(listener: &UnixListener, wake: i32, shared: &Mutex<Shared>, stop: &AtomicBool) {
    let mut clients: Vec<Client> = Vec::new();
    loop {
        let mut fds = vec![
            libc::pollfd {
                fd: wake,
                events: libc::POLLIN,
                revents: 0,
            },
            libc::pollfd {
                fd: listener.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            },
        ];
        fds.extend(clients.iter().map(|client| libc::pollfd {
            fd: client.stream.as_raw_fd(),
            events: if client.held.is_some() {
                0
            } else {
                libc::POLLIN
            },
            revents: 0,
        }));
        if unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, -1) } < 0 {
            if std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            return;
        }
        let mut closed: Vec<usize> = Vec::new();
        if fds[0].revents != 0 {
            let mut drained = [0u8; 64];
            unsafe {
                libc::read(
                    wake,
                    drained.as_mut_ptr() as *mut libc::c_void,
                    drained.len(),
                )
            };
            if stop.load(Ordering::SeqCst) {
                return;
            }
            for (place, client) in clients.iter_mut().enumerate() {
                let Some(hash) = client.held.clone() else {
                    continue;
                };
                if locked(shared).flight.contains(&hash) {
                    continue;
                }
                client.held = None;
                if client.stream.write_all(b"1").is_err() || !answer(client, shared) {
                    closed.push(place);
                }
            }
        }
        for (place, client) in clients.iter_mut().enumerate() {
            let events = fds[place + 2].revents;
            if events == 0 || closed.contains(&place) {
                continue;
            }
            if client.held.is_some() {
                if events & (libc::POLLHUP | libc::POLLERR) != 0 {
                    closed.push(place);
                }
                continue;
            }
            let mut chunk = [0u8; 4096];
            match client.stream.read(&mut chunk) {
                Ok(count) if count > 0 => {
                    client.buffer.extend_from_slice(&chunk[..count]);
                    if !answer(client, shared) {
                        closed.push(place);
                    }
                }
                _ => closed.push(place),
            }
        }
        closed.sort_unstable();
        for place in closed.into_iter().rev() {
            clients.swap_remove(place);
        }
        if fds[1].revents != 0 {
            while let Ok((stream, _)) = listener.accept() {
                if stream.set_nonblocking(false).is_ok() {
                    clients.push(Client {
                        stream,
                        buffer: Vec::new(),
                        held: None,
                    });
                }
            }
        }
    }
}

fn open(layout: &Layout) -> Result<Collector, String> {
    let schema = std::fs::read_to_string(format!("{}/db/schema", layout.state))
        .map_err(|error| format!("schema: {error}"))?;
    if schema.trim() != SCHEMA {
        return Err(format!("nix schema {} is not {SCHEMA}", schema.trim()));
    }
    for name in ["keep-outputs", "keep-derivations"] {
        if store::nix_setting("/etc/nix/nix.conf", name)
            .map(|value| value == "true")
            .unwrap_or(name == "keep-derivations")
        {
            return Err(format!("{name} is set"));
        }
    }
    let wrap = |error: rusqlite::Error| format!("nix database: {error}");
    let db = Connection::open_with_flags(
        format!("{}/db/db.sqlite", layout.state),
        OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(wrap)?;
    db.busy_timeout(Duration::from_secs(60)).map_err(wrap)?;
    db.pragma_update(None, "foreign_keys", 1).map_err(wrap)?;
    if db
        .query_row("pragma foreign_keys", [], |row| row.get::<_, i64>(0))
        .map_err(wrap)?
        != 1
    {
        return Err("foreign keys are not enforced".into());
    }
    if db
        .query_row("pragma journal_mode", [], |row| row.get::<_, String>(0))
        .map_err(wrap)?
        != "wal"
    {
        return Err("nix database is not in wal mode".into());
    }
    db.pragma_update(None, "synchronous", "normal")
        .map_err(wrap)?;
    db.query_row("pragma wal_autocheckpoint = 40000", [], |_| Ok(()))
        .map_err(wrap)?;
    Ok(Collector {
        store: layout.store.clone(),
        state: layout.state.clone(),
        links_index: layout.links_index.clone(),
        db,
        index: Index::default(),
        processes: Processes::default(),
    })
}

impl Collector {
    fn invalidate<'a>(
        &mut self,
        flight: &[&'a String],
        references: &HashMap<String, Vec<String>>,
        refused: &mut HashSet<String>,
        causes: &mut Vec<(String, &'static str)>,
    ) -> rusqlite::Result<Vec<&'a String>> {
        let transaction = self
            .db
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let mut gone = Vec::new();
        {
            let mut statement =
                transaction.prepare_cached("delete from ValidPaths where path = ?")?;
            for path in flight {
                if refused.contains(*path) {
                    continue;
                }
                match statement.execute([path.as_str()]) {
                    Ok(1) => gone.push(*path),
                    Ok(_) => {
                        causes.push(((*path).clone(), "already invalid"));
                        refused.insert((*path).clone());
                    }
                    Err(rusqlite::Error::SqliteFailure(error, _))
                        if error.code == ErrorCode::ConstraintViolation =>
                    {
                        causes.push(((*path).clone(), "referenced by a live path"));
                        refuse(path, references, refused)
                    }
                    Err(error) => return Err(error),
                }
            }
        }
        transaction.commit()?;
        Ok(gone)
    }

    fn sweep(
        &mut self,
        ordered: &[String],
        references: &HashMap<String, Vec<String>>,
        orphans: &[String],
        shared: &Mutex<Shared>,
        wake: i32,
        report: &mut Report,
        progress: &mut dyn FnMut(usize),
    ) -> Result<(), String> {
        let clock = Instant::now();
        let mut live: HashSet<Key> = store::directory_roots(&self.state)
            .keys()
            .filter_map(|path| key(path))
            .collect();
        live.extend(temp_roots(&self.state)?);
        report.rescanned = self.processes.refresh(&self.store);
        if !report.rescanned
            && ordered
                .iter()
                .filter_map(|path| key(path))
                .any(|hash| self.processes.roots.contains(&hash))
        {
            self.processes.valid = false;
            report.rescanned = self.processes.refresh(&self.store);
        }
        report.roots = clock.elapsed().as_secs_f64();
        writable(&self.store)?;
        let mut linked: Vec<u64> = Vec::new();
        for (place, chunk) in ordered.chunks(CHUNK).enumerate() {
            progress(place * CHUNK + chunk.len());
            self.processes.watch();
            let flight: Vec<&String> = {
                let mut state = locked(shared);
                let mut flight = Vec::new();
                for path in chunk {
                    if report.refused.contains(path) {
                        continue;
                    }
                    match key(path) {
                        Some(hash)
                            if !live.contains(&hash)
                                && !self.processes.roots.contains(&hash)
                                && !hash_part(path)
                                    .is_some_and(|text| state.temp.contains(text)) =>
                        {
                            flight.push(path)
                        }
                        Some(hash) => {
                            let cause = if live.contains(&hash) {
                                "gc root"
                            } else if self.processes.roots.contains(&hash) {
                                "held by a process"
                            } else {
                                "temp root of a nix client"
                            };
                            report.causes.push((path.clone(), cause));
                            refuse(path, references, &mut report.refused)
                        }
                        None => {
                            report.causes.push((path.clone(), "not a store path"));
                            refuse(path, references, &mut report.refused)
                        }
                    }
                }
                state.flight = flight
                    .iter()
                    .filter_map(|path| hash_part(path))
                    .map(str::to_string)
                    .collect();
                flight
            };
            let clock = Instant::now();
            let gone =
                self.invalidate(&flight, references, &mut report.refused, &mut report.causes);
            report.database += clock.elapsed().as_secs_f64();
            let clock = Instant::now();
            remove::prefetch(
                gone.iter()
                    .flatten()
                    .map(|path| format!("{}/{}", self.store, &path[LOGICAL.len()..]))
                    .collect(),
                READERS,
            );
            report.warming += clock.elapsed().as_secs_f64();
            let clock = Instant::now();
            for path in gone.iter().flatten() {
                let mut outcome = remove::Outcome::default();
                let single = Instant::now();
                remove::remove_tree_linked(
                    &format!("{}/{}", self.store, &path[LOGICAL.len()..]),
                    &mut outcome,
                    &mut Some(&mut linked),
                );
                let spent = single.elapsed().as_secs_f64();
                report.entries += outcome.removed as u64;
                if spent > report.slowest.0 {
                    report.slowest = (spent, outcome.removed as u64, path.to_string());
                }
                if let Some((_, code)) = outcome.failed.first() {
                    report.strays.push((path.to_string(), *code));
                }
                report.deleted += 1;
            }
            report.unlinking += clock.elapsed().as_secs_f64();
            locked(shared).flight.clear();
            unsafe { libc::write(wake, b"x".as_ptr() as *const libc::c_void, 1) };
            if let Err(error) = gone {
                report.error = Some(format!("nix database: {error}"));
                report
                    .refused
                    .extend(ordered[place * CHUNK..].iter().cloned());
                break;
            }
        }
        self.unlink_orphans(linked, orphans, report);
        Ok(())
    }

    fn unlink_orphans(&mut self, mut linked: Vec<u64>, orphans: &[String], report: &mut Report) {
        if linked.is_empty() && orphans.is_empty() {
            return;
        }
        let path = format!("{}/.links", self.store);
        let Some(dir) = sys::open_dir(&path) else {
            return;
        };
        let clock = Instant::now();
        let published = self
            .links_index
            .as_deref()
            .filter(|file| std::path::Path::new(file).exists());
        if !linked.is_empty()
            && (self.index.origin.is_none()
                || self.index.origin != stamp(published.unwrap_or(&path)))
        {
            self.index.load(&path, published);
        }
        report.indexing = clock.elapsed().as_secs_f64();
        let clock = Instant::now();
        linked.sort_unstable();
        linked.dedup();
        for ino in linked {
            if let Some(name) = self.index.name(ino) {
                report.links += drop_orphan(dir, &name);
            }
        }
        for name in orphans.iter().filter(|name| !name.contains('/')) {
            if let Ok(name) = CString::new(name.as_bytes()) {
                report.links += drop_orphan(dir, &name);
            }
        }
        if self.index.origin.is_some() && published.is_none() {
            self.index.origin = stamp(&path);
        }
        sys::close(dir);
        report.linking = clock.elapsed().as_secs_f64();
    }

    fn run(
        &mut self,
        ordered: &[String],
        references: &HashMap<String, Vec<String>>,
        orphans: &[String],
        progress: &mut dyn FnMut(usize),
    ) -> Result<Report, String> {
        let mut report = Report::default();
        let clock = Instant::now();
        let lock = std::fs::File::options()
            .read(true)
            .write(true)
            .create(true)
            .mode(0o600)
            .open(format!("{}/gc.lock", self.state))
            .map_err(|error| format!("gc.lock: {error}"))?;
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) } != 0 {
            return Err(failure("gc.lock"));
        }
        report.waited = clock.elapsed().as_secs_f64();
        let directory = format!("{}/gc-socket", self.state);
        let wrap = |error: std::io::Error| format!("{directory}: {error}");
        std::fs::create_dir_all(&directory).map_err(wrap)?;
        let anchor = std::fs::File::open(&directory).map_err(wrap)?;
        let socket = format!("/proc/self/fd/{}/socket", anchor.as_raw_fd());
        let _ = std::fs::remove_file(&socket);
        let listener = UnixListener::bind(&socket).map_err(wrap)?;
        std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o666)).map_err(wrap)?;
        listener.set_nonblocking(true).map_err(wrap)?;
        let mut pipe = [0i32; 2];
        if unsafe { libc::pipe2(pipe.as_mut_ptr(), libc::O_CLOEXEC | libc::O_NONBLOCK) } != 0 {
            return Err(failure("pipe"));
        }
        let shared = Mutex::new(Shared::default());
        let stop = AtomicBool::new(false);
        let result = std::thread::scope(|scope| {
            scope.spawn(|| serve(&listener, pipe[0], &shared, &stop));
            let result = self.sweep(
                ordered,
                references,
                orphans,
                &shared,
                pipe[1],
                &mut report,
                progress,
            );
            stop.store(true, Ordering::SeqCst);
            unsafe { libc::write(pipe[1], b"x".as_ptr() as *const libc::c_void, 1) };
            result
        });
        sys::close(pipe[0]);
        sys::close(pipe[1]);
        result.map(|()| report)
    }
}

pub fn collect(
    layout: &Layout,
    ordered: &[String],
    references: &HashMap<String, Vec<String>>,
    orphans: &[String],
    progress: &mut dyn FnMut(usize),
) -> Result<Report, String> {
    let mut held = locked(&COLLECTOR);
    if !held
        .as_ref()
        .is_some_and(|collector| collector.store == layout.store && collector.state == layout.state)
    {
        *held = Some(open(layout)?);
    }
    let Some(collector) = held.as_mut() else {
        return Err("no collector".into());
    };
    collector.run(ordered, references, orphans, progress)
}

pub fn plan(
    layout: &Layout,
    paths: &[String],
) -> Result<(Vec<String>, HashMap<String, Vec<String>>), String> {
    let wrap = |error: rusqlite::Error| format!("nix database: {error}");
    let db = Connection::open_with_flags(
        format!("{}/db/db.sqlite", layout.state),
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(wrap)?;
    let mut above: HashMap<&str, usize> = paths.iter().map(|path| (path.as_str(), 0)).collect();
    let mut references: HashMap<String, Vec<String>> = HashMap::new();
    let mut statement = db.prepare("select r.path from Refs join ValidPaths v on v.id = Refs.referrer join ValidPaths r on r.id = Refs.reference where v.path = ? and r.path != v.path").map_err(wrap)?;
    for path in above.keys().copied().collect::<Vec<&str>>() {
        let below: Vec<String> = statement
            .query_map([path], |row| row.get::<_, String>(0))
            .map_err(wrap)?
            .flatten()
            .filter(|other| above.contains_key(other.as_str()))
            .collect();
        for other in &below {
            if let Some(count) = above.get_mut(other.as_str()) {
                *count += 1;
            }
        }
        references.insert(path.to_string(), below);
    }
    let mut ready: Vec<&str> = above
        .iter()
        .filter(|(_, count)| **count == 0)
        .map(|(path, _)| *path)
        .collect();
    ready.sort_unstable();
    let mut ordered = Vec::with_capacity(above.len());
    while let Some(path) = ready.pop() {
        ordered.push(path.to_string());
        for other in &references[path] {
            if let Some((known, count)) = above
                .get_key_value(other.as_str())
                .map(|(known, count)| (*known, *count))
            {
                above.insert(known, count - 1);
                if count == 1 {
                    ready.push(known);
                }
            }
        }
    }
    Ok((ordered, references))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn link_names_round_trip() {
        let empty = b"0mdqa9w1p6cmli6976v4wi0sw9r4p5prkj7lzfd1877wk11c9c73";
        let hash = decode(empty).unwrap();
        assert_eq!(hash[..4], [0xe3, 0xb0, 0xc4, 0x42]);
        assert_eq!(hash[28..], [0x78, 0x52, 0xb8, 0x55]);
        assert_eq!(encode(&hash).as_bytes(), empty);
        assert!(decode(b"short").is_none());
        assert!(decode(&[b'e'; NAME_LENGTH]).is_none());
        assert!(decode(&[b'z'; NAME_LENGTH]).is_none());
    }

    #[test]
    fn hash_parts() {
        assert_eq!(
            hash_part("/nix/store/0x92zw6ryvg0qn3vmhv1z2kki66yl2az-unit.service/bin/x"),
            Some("0x92zw6ryvg0qn3vmhv1z2kki66yl2az")
        );
        assert_eq!(hash_part("/nix/store/short"), None);
        assert_eq!(
            hash_part("/elsewhere/0x92zw6ryvg0qn3vmhv1z2kki66yl2az-unit"),
            None
        );
    }

    #[test]
    fn refusal_covers_references() {
        let references: HashMap<String, Vec<String>> = [
            ("a", vec!["b"]),
            ("b", vec!["c"]),
            ("c", vec![]),
            ("d", vec![]),
        ]
        .into_iter()
        .map(|(path, below)| {
            (
                path.to_string(),
                below.into_iter().map(str::to_string).collect(),
            )
        })
        .collect();
        let mut refused = HashSet::new();
        refuse("a", &references, &mut refused);
        assert_eq!(
            refused,
            ["a", "b", "c"].into_iter().map(str::to_string).collect()
        );
    }
}
