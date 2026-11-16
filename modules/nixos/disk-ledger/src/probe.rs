// System probes the ledger reads: held deleted files, ext4 internals, mounts, shared xattr blocks, windows, shells.

use crate::reclaim::{basename, dirname, join, list_dir};
use crate::sys;
use regex::Regex;
use serde_json::{Map, Value};
use std::collections::{HashMap, HashSet};
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::process::{Command, Stdio};
use std::sync::OnceLock;
use std::time::Duration;

pub fn blocks(path: &str) -> u64 {
    sys::lstat(path).map(|info| info.blocks).unwrap_or(0)
}

pub fn pressure(kind: &str) -> f64 {
    std::fs::read_to_string(format!("/proc/pressure/{kind}")).ok().and_then(|text| text.lines().next().and_then(|line| line.split("avg10=").nth(1)).and_then(|rest| rest.split_whitespace().next()).and_then(|value| value.parse().ok())).unwrap_or(0.0)
}

pub fn short(path: &str, home: &str) -> String {
    static STORE: OnceLock<Regex> = OnceLock::new();
    if path.starts_with("/nix/store/") {
        return STORE.get_or_init(|| Regex::new(r"^/nix/store/[a-z0-9]{32}-").unwrap()).replace(path, "").into_owned();
    }
    match path.strip_prefix(home).filter(|rest| rest.starts_with('/')) {
        Some(rest) => format!("~{rest}"),
        None => path.to_string(),
    }
}

pub fn family(name: &str) -> String {
    static VERSION: OnceLock<Regex> = OnceLock::new();
    static SUFFIX: OnceLock<Regex> = OnceLock::new();
    let bare = VERSION.get_or_init(|| Regex::new(r"-[0-9][^/]*$").unwrap()).replace_all(name, "");
    let bare = SUFFIX.get_or_init(|| Regex::new(r"\.(drv|patch|tar\.\w+|zip|lock)$").unwrap()).replace_all(&bare, "").into_owned();
    if bare.is_empty() {
        name.to_string()
    } else {
        bare
    }
}

pub fn local(format: &str, seconds: i64) -> String {
    let mut parts: libc::tm = unsafe { std::mem::zeroed() };
    let time = seconds as libc::time_t;
    unsafe {
        libc::localtime_r(&time, &mut parts);
    }
    let pattern = sys::cstr(format);
    let mut buffer = [0u8; 64];
    let length = unsafe { libc::strftime(buffer.as_mut_ptr() as *mut libc::c_char, buffer.len(), pattern.as_ptr(), &parts) };
    String::from_utf8_lossy(&buffer[..length]).into_owned()
}

pub fn hypr_clients() -> HashMap<i64, Value> {
    let mut clients = HashMap::new();
    for user in list_dir("/run/user").unwrap_or_default() {
        let base = format!("/run/user/{user}/hypr");
        for instance in list_dir(&base).unwrap_or_default() {
            let socket = format!("{base}/{instance}/.socket.sock");
            let Ok(mut connection) = UnixStream::connect(&socket) else { continue };
            let _ = connection.set_read_timeout(Some(Duration::from_millis(500)));
            let _ = connection.set_write_timeout(Some(Duration::from_millis(500)));
            if connection.write_all(b"j/clients").is_err() {
                continue;
            }
            let mut data = Vec::new();
            if connection.read_to_end(&mut data).is_err() {
                continue;
            }
            if let Ok(Value::Array(list)) = serde_json::from_slice::<Value>(&data) {
                for client in list {
                    if let Some(pid) = client.get("pid").and_then(Value::as_i64) {
                        clients.insert(pid, client);
                    }
                }
            }
        }
    }
    clients
}

fn parent_pid(pid: i64) -> i64 {
    std::fs::read_to_string(format!("/proc/{pid}/stat")).ok().and_then(|text| text.rsplit_once(')').and_then(|(_, tail)| tail.split_whitespace().nth(1).and_then(|value| value.parse().ok()))).unwrap_or(0)
}

fn shell_command(pid: i64) -> String {
    let Ok(raw) = std::fs::read(format!("/proc/{pid}/cmdline")) else { return String::new() };
    let text = String::from_utf8_lossy(&raw);
    let mut args: Vec<String> = text.split('\0').map(String::from).collect();
    args.pop();
    if let Some(start) = args.iter().position(|arg| arg == "--observed-command") {
        let mut rest: Vec<String> = args.get(start + 2..).map(|slice| slice.to_vec()).unwrap_or_default();
        if rest.first().map(String::as_str) == Some("--observed-real") {
            rest = rest.get(2..).map(|slice| slice.to_vec()).unwrap_or_default();
        }
        let mut joined: Vec<String> = args.get(start + 1).cloned().into_iter().collect();
        joined.extend(rest);
        args = joined;
    }
    args.iter().enumerate().map(|(index, arg)| if index == 0 { basename(arg).to_string() } else { arg.clone() }).collect::<Vec<_>>().join(" ")
}

pub fn build_client(pid: i64) -> Option<i64> {
    let mut current = pid;
    for _ in 0..16 {
        if current <= 1 {
            break;
        }
        let raw = std::fs::read(format!("/proc/{current}/cmdline")).unwrap_or_default();
        let args: Vec<String> = String::from_utf8_lossy(&raw).split('\0').filter(|arg| !arg.is_empty()).map(String::from).collect();
        if args.len() == 2 && basename(&args[0]) == "nix-daemon" {
            return args[1].parse::<i64>().ok().filter(|client| std::path::Path::new(&format!("/proc/{client}")).exists());
        }
        current = parent_pid(current);
    }
    None
}

fn readable(command: &str, home: &str) -> String {
    let words: Vec<&str> = command.split_whitespace().collect();
    let Some(program) = words.first().map(|word| basename(word)) else { return String::new() };
    if !program.starts_with("nix") {
        return brief(command);
    }
    let verb = words.iter().skip(1).find(|word| !word.starts_with('-') && !word.contains('/') && !word.contains('#')).copied().filter(|_| program == "nix");
    let target = words.iter().rev().find(|word| word.contains('#')).map(|word| {
        let (source, attr) = word.split_once('#').unwrap_or((word, ""));
        let path = source.split('?').next().unwrap_or(source).trim_start_matches("git+file://").trim_start_matches("path:");
        let place = if path.starts_with('/') { short(path, home) } else { path.to_string() };
        if place == "." || place.is_empty() { format!("#{attr}") } else { format!("{place}#{attr}") }
    }).or_else(|| words.iter().rev().find(|word| word.ends_with(".drv") || word.ends_with(".nix")).map(|word| basename(word).to_string()));
    let text = [Some(program), verb, target.as_deref()].into_iter().flatten().collect::<Vec<_>>().join(" ");
    if text.chars().count() > 72 { format!("{}…", text.chars().take(71).collect::<String>()) } else { text }
}

pub fn describe_shell(pid: i64, home: &str, clients: &HashMap<i64, Value>) -> (String, String, Option<Value>) {
    let pid = build_client(pid).unwrap_or(pid);
    let cwd = std::fs::read_link(format!("/proc/{pid}/cwd")).map(|path| short(&path.to_string_lossy(), home)).unwrap_or_default();
    let mut window = None;
    let mut current = pid;
    while current > 1 && window.is_none() {
        window = clients.get(&current).cloned();
        current = parent_pid(current);
    }
    let command = shell_command(pid);
    (if command.is_empty() { format!("pid {pid}") } else { readable(&command, home) }, cwd, window)
}

pub fn parents_within(path: &str, stop: &str) -> Vec<String> {
    let mut found = Vec::new();
    let mut current = path.to_string();
    while current.len() > stop.len() {
        current = dirname(&current).to_string();
        found.push(current.clone());
    }
    found
}

const AT_HANDLE_CONNECTABLE: i32 = 0x002;
const FILEID_INO32_GEN: i32 = 1;

fn parent_dir(link: &str, root_fd: i32) -> Option<i32> {
    let mut buffer = [0u8; 136];
    buffer[..4].copy_from_slice(&128u32.to_ne_bytes());
    let mut mount: libc::c_int = 0;
    let name = sys::cstr(link);
    let result = unsafe { libc::syscall(libc::SYS_name_to_handle_at, libc::AT_FDCWD, name.as_ptr(), buffer.as_mut_ptr(), &mut mount, libc::AT_SYMLINK_FOLLOW | AT_HANDLE_CONNECTABLE) };
    if result < 0 {
        return None;
    }
    let size = sys::u32_at(&buffer, 0) as usize;
    if size / 4 < 4 {
        return None;
    }
    let mut handle = [0u8; 16];
    handle[..4].copy_from_slice(&8u32.to_ne_bytes());
    handle[4..8].copy_from_slice(&FILEID_INO32_GEN.to_ne_bytes());
    handle[8..12].copy_from_slice(&buffer[16..20]);
    handle[12..16].copy_from_slice(&buffer[20..24]);
    let fd = unsafe { libc::syscall(libc::SYS_open_by_handle_at, root_fd, handle.as_mut_ptr(), libc::O_RDONLY | libc::O_DIRECTORY) } as i32;
    if fd >= 0 {
        Some(fd)
    } else {
        None
    }
}

fn dead_ancestors(link: &str, root_fd: i32) -> Vec<(String, libc::stat)> {
    let mut found = Vec::new();
    let mut fd = parent_dir(link, root_fd);
    while let Some(current) = fd {
        let mut info: libc::stat = unsafe { std::mem::zeroed() };
        if unsafe { libc::fstat(current, &mut info) } < 0 || info.st_nlink != 0 {
            sys::close(current);
            return found;
        }
        let path = sys::fd_path(current).unwrap_or_default();
        found.push((path.strip_suffix(" (deleted)").unwrap_or(&path).to_string(), info));
        let up = sys::cstr("..");
        let parent = unsafe { libc::openat(current, up.as_ptr(), libc::O_RDONLY | libc::O_DIRECTORY) };
        sys::close(current);
        fd = if parent >= 0 && parent != current { Some(parent) } else { None };
    }
    found
}

#[derive(Clone)]
pub struct Held {
    pub path: String,
    pub size: u64,
    pub last_used: i64,
    pub how: &'static str,
    pub holders: Vec<String>,
}

fn deleted_mappings(pid: &str) -> Vec<String> {
    let Ok(maps) = std::fs::read(format!("/proc/{pid}/maps")) else { return Vec::new() };
    let mut seen: HashSet<String> = HashSet::new();
    let mut ranges = Vec::new();
    for line in String::from_utf8_lossy(&maps).lines() {
        if !line.ends_with(" (deleted)") {
            continue;
        }
        let mut fields = line.split_ascii_whitespace();
        let (Some(range), Some(device), Some(inode)) = (fields.next(), fields.nth(2), fields.next()) else { continue };
        if inode != "0" && seen.insert(format!("{device} {inode}")) {
            ranges.push(range.to_string());
        }
    }
    ranges
}

pub fn held_open(device: u64) -> Vec<Held> {
    let mut owners: Vec<Held> = Vec::new();
    let mut by_ino: HashMap<u64, usize> = HashMap::new();
    let root = sys::open_dir("/").unwrap_or(-1);
    let pids: Vec<String> = list_dir("/proc").unwrap_or_default().into_iter().filter(|name| !name.is_empty() && name.bytes().all(|byte| byte.is_ascii_digit())).collect();
    for (how, kind) in [("open", "fd"), ("mapped", "map_files")] {
        for pid in &pids {
            let directory = format!("/proc/{pid}/{kind}");
            let names = if kind == "fd" { list_dir(&directory).unwrap_or_default() } else { deleted_mappings(pid) };
            for name in names {
                let link = join(&directory, &name);
                let Ok(info) = std::fs::metadata(&link) else { continue };
                use std::os::unix::fs::MetadataExt;
                if info.nlink() != 0 || info.dev() != device || !info.is_file() {
                    continue;
                }
                let Ok(target) = std::fs::read_link(&link) else { continue };
                let target = target.to_string_lossy().into_owned();
                let Some(path) = target.strip_suffix(" (deleted)") else { continue };
                let command = match pid.parse::<i64>().ok().and_then(build_client) {
                    Some(client) => readable(&shell_command(client), &std::env::var("LEDGER_HOME").unwrap_or_default()),
                    None => std::fs::read_to_string(format!("/proc/{pid}/comm")).map(|text| text.trim().to_string()).unwrap_or_else(|_| pid.clone()),
                };
                let position = *by_ino.entry(info.ino()).or_insert_with(|| {
                    owners.push(Held { path: path.to_string(), size: info.blocks() * 512, last_used: info.mtime(), how, holders: Vec::new() });
                    owners.len() - 1
                });
                if !owners[position].holders.contains(&command) {
                    owners[position].holders.push(command.clone());
                }
                for (parent, directory) in dead_ancestors(&link, root) {
                    let position = *by_ino.entry(directory.st_ino).or_insert_with(|| {
                        owners.push(Held { path: parent, size: directory.st_blocks as u64 * 512, last_used: directory.st_mtime, how: "as a parent", holders: Vec::new() });
                        owners.len() - 1
                    });
                    if !owners[position].holders.contains(&command) {
                        owners[position].holders.push(command.clone());
                    }
                }
            }
        }
    }
    if root >= 0 {
        sys::close(root);
    }
    let mut rows: Vec<Held> = owners.into_iter().filter(|row| row.size != 0).collect();
    for row in rows.iter_mut() {
        row.holders.sort();
    }
    rows.sort_by(|a, b| b.size.cmp(&a.size));
    rows
}

fn run(command: &[&str], input: Option<&str>) -> String {
    let mut child = Command::new(command[0]);
    child.args(&command[1..]).stdout(Stdio::piped()).stderr(Stdio::null()).stdin(if input.is_some() { Stdio::piped() } else { Stdio::null() });
    let Ok(mut running) = child.spawn() else { return String::new() };
    if let (Some(text), Some(mut stdin)) = (input, running.stdin.take()) {
        let text = text.to_string();
        std::thread::spawn(move || {
            let _ = stdin.write_all(text.as_bytes());
        });
    }
    running.wait_with_output().map(|output| String::from_utf8_lossy(&output.stdout).into_owned()).unwrap_or_default()
}

fn debugfs_stat(source: &str, inode: u64) -> (u64, String) {
    static COUNT: OnceLock<Regex> = OnceLock::new();
    let out = run(&["debugfs", "-c", "-R", &format!("stat <{inode}>"), source], None);
    let found = COUNT.get_or_init(|| Regex::new(r"Blockcount: (\d+)").unwrap()).captures(&out).and_then(|found| found[1].parse::<u64>().ok()).map(|count| count * 512).unwrap_or(0);
    (found, out)
}

fn backup_groups(groups: u64) -> u64 {
    let mut found: std::collections::HashSet<u64> = [0, 1].into_iter().collect();
    for base in [3u64, 5, 7] {
        let mut power = base;
        while power < groups {
            found.insert(power);
            power *= base;
        }
    }
    found.into_iter().filter(|group| *group < groups).count() as u64
}

pub fn root_source(root: &str) -> String {
    run(&["findmnt", "-no", "SOURCE", root], None).trim().split('[').next().unwrap_or("").to_string()
}

pub fn hidden_inodes(source: &str) -> Vec<(String, u64)> {
    let header = run(&["dumpe2fs", "-h", source], None);
    let field = |name: &str| -> u64 { Regex::new(&format!(r"(?m)^{name}:\s+(\d+)")).ok().and_then(|pattern| pattern.captures(&header).and_then(|found| found[1].parse().ok())).unwrap_or(0) };
    let block = field("Block size");
    let per_group = field("Blocks per group");
    if per_group == 0 {
        return Vec::new();
    }
    let groups = field("Block count").div_ceil(per_group);
    let mut rows = Vec::new();
    for (inode, label) in [(3, "user quota"), (4, "group quota"), (12, "orphan file")] {
        rows.push((label.to_string(), debugfs_stat(source, inode).0));
    }
    let (resize, _) = debugfs_stat(source, 7);
    rows.push(("resize index".into(), resize.saturating_sub(field("Reserved GDT blocks") * backup_groups(groups) * block)));
    let (journal, out) = debugfs_stat(source, 8);
    let size = Regex::new(r"Size: (\d+)").unwrap().captures(&out).and_then(|found| found[1].parse::<u64>().ok());
    rows.push(("journal index".into(), size.map(|size| journal.saturating_sub(size)).unwrap_or(0)));
    rows.into_iter().filter(|row| row.1 != 0).collect()
}

fn unescape(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'\\' && index + 3 < bytes.len() + 0 && bytes[index + 1..index + 4].iter().all(|byte| (b'0'..=b'7').contains(byte)) {
            out.push((bytes[index + 1] - b'0') * 64 + (bytes[index + 2] - b'0') * 8 + (bytes[index + 3] - b'0'));
            index += 4;
        } else {
            out.push(bytes[index]);
            index += 1;
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

pub fn covered_mountpoints(root: &str) -> Vec<String> {
    let Some(device) = sys::lstat(root).map(|info| info.dev) else { return Vec::new() };
    let mut targets: Vec<String> = Vec::new();
    for line in std::fs::read_to_string("/proc/self/mountinfo").unwrap_or_default().lines() {
        let Some(field) = line.split_whitespace().nth(4) else { continue };
        let target = unescape(field);
        if target == root {
            continue;
        }
        let (Some(inner), Some(outer)) = (sys::lstat(&target), sys::lstat(dirname(&target))) else { continue };
        if inner.dev != device && outer.dev == device && !targets.contains(&target) {
            targets.push(target);
        }
    }
    targets.sort();
    targets
}

pub fn shared_xattr_blocks(dirs: &[String], source: &str, block_size: u64) -> HashMap<String, u64> {
    static INODE: OnceLock<Regex> = OnceLock::new();
    let mut order: Vec<u64> = Vec::new();
    let mut candidates: HashMap<u64, String> = HashMap::new();
    for directory in dirs {
        let Some(names) = list_dir(directory) else { continue };
        for name in std::iter::once(".".to_string()).chain(names) {
            let Some(info) = sys::lstat(&join(directory, &name)) else { break };
            if !sys::is_dir(info.mode) || name == "." {
                if candidates.insert(info.ino, directory.clone()).is_none() {
                    order.push(info.ino);
                }
            }
        }
    }
    if candidates.is_empty() {
        return HashMap::new();
    }
    let commands: String = order.iter().map(|inode| format!("stat <{inode}>\n")).collect();
    let out = run(&["debugfs", "-c", "-f", "/dev/stdin", source], Some(&commands));
    let mut sharers: Vec<(String, Vec<u64>)> = Vec::new();
    for found in INODE.get_or_init(|| Regex::new(r"(?ms)^Inode: (\d+).*?File ACL: (\d+)").unwrap()).captures_iter(&out) {
        let block = found[2].to_string();
        let Ok(inode) = found[1].parse::<u64>() else { continue };
        if block == "0" {
            continue;
        }
        match sharers.iter_mut().find(|(known, _)| *known == block) {
            Some((_, inodes)) => inodes.push(inode),
            None => sharers.push((block, vec![inode])),
        }
    }
    let mut extra: HashMap<String, u64> = HashMap::new();
    for (_, inodes) in sharers {
        for inode in inodes.iter().skip(1) {
            if let Some(directory) = candidates.get(inode) {
                *extra.entry(directory.clone()).or_insert(0) += block_size;
            }
        }
    }
    extra
}

pub fn write_file(path: &std::path::Path, text: &str, owner: Option<u32>) -> std::io::Result<()> {
    let temporary = path.with_extension("tmp");
    std::fs::write(&temporary, text)?;
    if let Some(uid) = owner {
        std::os::unix::fs::chown(&temporary, Some(uid), None)?;
    }
    std::fs::rename(&temporary, path)
}

pub fn object(value: Value) -> Map<String, Value> {
    match value {
        Value::Object(map) => map,
        _ => Map::new(),
    }
}

const TMP_PREFIXES: [&str; 18] = ["nix-shell.", "nix-shell-", "nix-develop-", "nix-build-", "nix-", ".org.chromium.Chromium.", "org.chromium.Chromium.", "scoped_dir", "nixwatch-", "pytest-of-", "babel-", "epdfinfo", "tmp.", "tmp", "systemd-private-", "claude-", ".bun-", "hazel-"];

pub fn tmp_family(name: &str) -> String {
    if let Some(prefix) = TMP_PREFIXES.iter().find(|prefix| name.len() > prefix.len() && name.starts_with(**prefix)) {
        return format!("{prefix}*");
    }
    let mut offset = 0;
    for part in name.split(['.', '-', '_']) {
        let cased = part.bytes().any(|byte| byte.is_ascii_uppercase()) && part.bytes().any(|byte| byte.is_ascii_lowercase());
        let random = part.len() == 6 || (cased && part.len() == 10);
        if random || part.bytes().any(|byte| byte.is_ascii_digit()) {
            let keep = if random { 0 } else { part.bytes().take_while(u8::is_ascii_alphabetic).count() };
            let prefix = &name[..offset + keep];
            return if prefix.bytes().any(|byte| byte.is_ascii_alphanumeric()) { format!("{prefix}*") } else { name.to_string() };
        }
        offset += part.len() + 1;
    }
    name.to_string()
}

pub fn hold_text(link: &str) -> &'static str {
    if link.starts_with("{temp:") {
        "nix temp root: a build or evaluation is using it"
    } else if link.ends_with("/environ") {
        "named in its environment"
    } else if link.ends_with("/maps") {
        "mapped into memory"
    } else if link.ends_with("/exe") {
        "its executable"
    } else if link.ends_with("/cwd") {
        "its working directory"
    } else if link.contains("/fd/") {
        "open file"
    } else {
        "kernel root"
    }
}

pub fn link_pid(link: &str) -> Option<i64> {
    link.strip_prefix("/proc/").and_then(|rest| rest.split('/').next()).or_else(|| link.strip_prefix("{temp:").and_then(|rest| rest.strip_suffix('}'))).and_then(|pid| pid.parse().ok())
}

pub fn brief(command: &str) -> String {
    let mut words = command.split_whitespace();
    let program = words.next().map(|word| word.rsplit('/').next().unwrap_or(word)).unwrap_or("");
    let text = std::iter::once(program).chain(words).collect::<Vec<_>>().join(" ");
    if text.chars().count() > 48 { format!("{}…", text.chars().take(47).collect::<String>()) } else { text }
}

pub fn tmp_text(name: &str, home: &str, clients: &HashMap<i64, Value>) -> Option<String> {
    let (what, rest) = [("nix-develop-", "nix develop"), ("nix-shell-", "nix-shell"), ("nix-", "nix")].into_iter().find_map(|(prefix, what)| name.strip_prefix(prefix).map(|rest| (what, rest)))?;
    let (pid, nonce) = rest.split_once('-')?;
    let pid: i64 = pid.parse().ok()?;
    if !nonce.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    let path = format!("/tmp/{name}");
    let started = crate::reclaim::born(&path);
    let process = std::fs::metadata(format!("/proc/{pid}")).ok().and_then(|meta| meta.modified().ok()).and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok()).map(|age| age.as_secs() as i64);
    if process.is_some_and(|since| started <= 0 || since <= started + 5) {
        let (command, cwd, window) = describe_shell(pid, home, clients);
        let place = window.map(|window| format!(", {}", plain_text(window.get("title")))).unwrap_or_default();
        let at = if cwd.is_empty() { String::new() } else { format!(" in {cwd}") };
        return Some(format!("{what}: {command}{at}{place}"));
    }
    let when = if started > 0 { local("%Y-%m-%d %H:%M", started) } else { "unknown time".into() };
    let entries = std::fs::read_dir(&path).map(|dir| dir.count()).unwrap_or(0);
    let left = if entries == 0 { "empty".to_string() } else { format!("{entries} entries") };
    Some(format!("{what} from {when}, exited, {left}"))
}

fn plain_text(value: Option<&Value>) -> String {
    match value {
        Some(Value::String(text)) => text.clone(),
        _ => String::new(),
    }
}
