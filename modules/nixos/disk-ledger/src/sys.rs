// Thin wrappers over the Linux interfaces the ledger watches: fanotify, inotify, file handles, statx.

use std::ffi::{CStr, CString};
use std::io;

pub const FAN_NONBLOCK: u32 = 0x2;
pub const FAN_UNLIMITED_QUEUE: u32 = 0x10;
pub const FAN_REPORT_DFID_NAME: u32 = 0xC00;
pub const FAN_MARK_ADD: u32 = 0x1;
pub const FAN_MARK_FILESYSTEM: u32 = 0x100;
pub const FAN_MARK_MOUNT: u32 = 0x10;
pub const FAN_MARK_FLUSH: u32 = 0x80;
pub const FAN_MARK_IGNORED_SURV_MODIFY: u32 = 0x40;
pub const FAN_MARK_IGNORE: u32 = 0x400;
pub const FAN_OPEN: u64 = 0x20;
pub const FAN_OPEN_EXEC: u64 = 0x1000;
pub const FAN_EVENT_ON_CHILD: u64 = 0x0800_0000;
pub const FAN_MODIFY: u64 = 0x2;
pub const FAN_MOVED_FROM: u64 = 0x40;
pub const FAN_MOVED_TO: u64 = 0x80;
pub const FAN_CREATE: u64 = 0x100;
pub const FAN_DELETE: u64 = 0x200;
pub const FAN_Q_OVERFLOW: u64 = 0x4000;
pub const FAN_ONDIR: u64 = 0x4000_0000;
pub const EVENT_SIZE: usize = 24;

pub fn cstr(path: &str) -> CString {
    CString::new(path.as_bytes()).unwrap_or_else(|_| CString::new("/").unwrap())
}

pub fn fanotify(flags: u32) -> io::Result<i32> {
    let fd = unsafe {
        libc::fanotify_init(
            flags,
            (libc::O_RDONLY | libc::O_CLOEXEC | libc::O_LARGEFILE) as u32,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(fd)
}

pub fn fanotify_mark(
    fd: i32,
    flags: u32,
    mask: u64,
    dirfd: i32,
    path: Option<&str>,
) -> io::Result<()> {
    let owned = path.map(cstr);
    let pointer = owned
        .as_ref()
        .map_or(std::ptr::null(), |value| value.as_ptr());
    if unsafe { libc::fanotify_mark(fd, flags, mask, dirfd, pointer) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

pub fn read_nonblocking(fd: i32, buffer: &mut [u8]) -> Option<usize> {
    let count = unsafe { libc::read(fd, buffer.as_mut_ptr() as *mut libc::c_void, buffer.len()) };
    if count <= 0 {
        None
    } else {
        Some(count as usize)
    }
}

pub fn u32_at(data: &[u8], offset: usize) -> u32 {
    u32::from_ne_bytes(data[offset..offset + 4].try_into().unwrap())
}

pub fn i32_at(data: &[u8], offset: usize) -> i32 {
    i32::from_ne_bytes(data[offset..offset + 4].try_into().unwrap())
}

pub fn u64_at(data: &[u8], offset: usize) -> u64 {
    u64::from_ne_bytes(data[offset..offset + 8].try_into().unwrap())
}

#[derive(Clone, Copy, Default, PartialEq, Eq)]
pub struct Key {
    len: u8,
    bytes: [u8; 31],
}

impl Key {
    pub fn of(key: &[u8]) -> Option<Key> {
        let mut bytes = [0u8; 31];
        bytes.get_mut(..key.len())?.copy_from_slice(key);
        Some(Key {
            len: key.len() as u8,
            bytes,
        })
    }
}

impl std::ops::Deref for Key {
    type Target = [u8];

    fn deref(&self) -> &[u8] {
        &self.bytes[..self.len as usize]
    }
}

pub fn handle_key(path: &str, flags: i32) -> Option<Vec<u8>> {
    let mut buffer = [0u8; 136];
    buffer[..4].copy_from_slice(&128u32.to_ne_bytes());
    let mut mount: i32 = 0;
    let name = cstr(path);
    let result = unsafe {
        libc::syscall(
            libc::SYS_name_to_handle_at,
            libc::AT_FDCWD,
            name.as_ptr(),
            buffer.as_mut_ptr(),
            &mut mount as *mut i32,
            flags,
        )
    };
    if result < 0 {
        return None;
    }
    let size = u32_at(&buffer, 0) as usize;
    let mut key = Vec::with_capacity(4 + size);
    key.extend_from_slice(&buffer[4..8]);
    key.extend_from_slice(&buffer[8..8 + size]);
    Some(key)
}

pub fn open_by_handle(mount: i32, key: &[u8], flags: i32) -> Option<i32> {
    let raw = &key[4..];
    let mut buffer = vec![0u8; 8 + raw.len()];
    buffer[..4].copy_from_slice(&(raw.len() as u32).to_ne_bytes());
    buffer[4..8].copy_from_slice(&key[..4]);
    buffer[8..].copy_from_slice(raw);
    let fd = unsafe {
        libc::syscall(
            libc::SYS_open_by_handle_at,
            mount,
            buffer.as_mut_ptr(),
            flags | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        None
    } else {
        Some(fd as i32)
    }
}

pub fn fd_path(fd: i32) -> Option<String> {
    std::fs::read_link(format!("/proc/self/fd/{fd}"))
        .ok()
        .map(|path| path.to_string_lossy().into_owned())
}

pub fn close(fd: i32) {
    unsafe {
        libc::close(fd);
    }
}

pub fn open_dir(path: &str) -> Option<i32> {
    let name = cstr(path);
    let fd = unsafe {
        libc::open(
            name.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        None
    } else {
        Some(fd)
    }
}

pub struct Statx {
    pub mask: u32,
    pub size: u64,
    pub btime: i64,
    pub mtime: i64,
}

pub fn statx(path: &str) -> Option<Statx> {
    let name = cstr(path);
    let mut buffer: libc::statx = unsafe { std::mem::zeroed() };
    let mask = libc::STATX_BTIME | libc::STATX_MTIME | libc::STATX_SIZE;
    if unsafe {
        libc::statx(
            libc::AT_FDCWD,
            name.as_ptr(),
            libc::AT_SYMLINK_NOFOLLOW,
            mask,
            &mut buffer,
        )
    } != 0
    {
        return None;
    }
    Some(Statx {
        mask: buffer.stx_mask,
        size: buffer.stx_size,
        btime: buffer.stx_btime.tv_sec,
        mtime: buffer.stx_mtime.tv_sec,
    })
}

pub fn inotify() -> Option<i32> {
    let fd = unsafe { libc::inotify_init1(libc::IN_NONBLOCK | libc::IN_CLOEXEC) };
    if fd < 0 {
        None
    } else {
        Some(fd)
    }
}

pub fn inotify_watch(fd: i32, path: &str, mask: u32) -> Option<i32> {
    let name = cstr(path);
    let wd = unsafe { libc::inotify_add_watch(fd, name.as_ptr(), mask) };
    if wd < 0 {
        None
    } else {
        Some(wd)
    }
}

pub fn listxattr_has(path: &str, wanted: &str) -> bool {
    let name = cstr(path);
    let mut buffer = vec![0u8; 4096];
    let count = unsafe {
        libc::llistxattr(
            name.as_ptr(),
            buffer.as_mut_ptr() as *mut libc::c_char,
            buffer.len(),
        )
    };
    if count <= 0 {
        return false;
    }
    buffer[..count as usize]
        .split(|byte| *byte == 0)
        .any(|entry| entry == wanted.as_bytes())
}

pub struct Statvfs {
    pub total: u64,
    pub used: u64,
    pub free: u64,
    pub reserved: u64,
    pub block: u64,
}

pub fn statvfs(path: &str) -> Statvfs {
    let name = cstr(path);
    let mut info: libc::statvfs = unsafe { std::mem::zeroed() };
    unsafe {
        libc::statvfs(name.as_ptr(), &mut info);
    }
    let frsize = info.f_frsize as u64;
    let total = info.f_blocks as u64 * frsize;
    let free = info.f_bavail as u64 * frsize;
    let used = (info.f_blocks as u64 - info.f_bfree as u64) * frsize;
    Statvfs {
        total,
        used,
        free,
        reserved: total - used - free,
        block: info.f_bsize as u64,
    }
}

pub fn poll(fds: &[i32], timeout_ms: i32) -> Vec<i32> {
    let mut entries: Vec<libc::pollfd> = fds
        .iter()
        .map(|fd| libc::pollfd {
            fd: *fd,
            events: libc::POLLIN,
            revents: 0,
        })
        .collect();
    let count = unsafe {
        libc::poll(
            entries.as_mut_ptr(),
            entries.len() as libc::nfds_t,
            timeout_ms,
        )
    };
    if count <= 0 {
        return Vec::new();
    }
    entries
        .iter()
        .filter(|entry| entry.revents != 0)
        .map(|entry| entry.fd)
        .collect()
}

pub fn clock_ticks() -> f64 {
    unsafe { libc::sysconf(libc::_SC_CLK_TCK) as f64 }
}

pub fn now() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

pub fn c_to_string(raw: &CStr) -> String {
    raw.to_string_lossy().into_owned()
}

pub const O_NOATIME: i32 = 0o1000000;

pub struct Entry {
    pub name: Vec<u8>,
    pub ino: u64,
    pub mode: u32,
    pub nlink: u64,
    pub blocks: u64,
    pub atime: i64,
    pub mtime: i64,
    pub mtime_nsec: i64,
    pub uid: u32,
    pub dev: u64,
}

impl Entry {
    pub fn modified(&self) -> f64 {
        self.mtime as f64 + self.mtime_nsec as f64 / 1e9
    }
}

pub fn is_dir(mode: u32) -> bool {
    mode & libc::S_IFMT == libc::S_IFDIR
}

pub fn is_reg(mode: u32) -> bool {
    mode & libc::S_IFMT == libc::S_IFREG
}

pub fn is_link(mode: u32) -> bool {
    mode & libc::S_IFMT == libc::S_IFLNK
}

fn from_stat(name: Vec<u8>, info: &libc::stat) -> Entry {
    Entry {
        name,
        ino: info.st_ino as u64,
        mode: info.st_mode as u32,
        nlink: info.st_nlink as u64,
        blocks: info.st_blocks as u64 * 512,
        atime: info.st_atime as i64,
        mtime: info.st_mtime as i64,
        mtime_nsec: info.st_mtime_nsec as i64,
        uid: info.st_uid as u32,
        dev: info.st_dev as u64,
    }
}

pub fn lstat(path: &str) -> Option<Entry> {
    let name = cstr(path);
    let mut info: libc::stat = unsafe { std::mem::zeroed() };
    if unsafe { libc::lstat(name.as_ptr(), &mut info) } != 0 {
        return None;
    }
    Some(from_stat(path.as_bytes().to_vec(), &info))
}

static NOATIME: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(true);

pub fn open_walk(dirfd: i32, name: &CStr) -> Option<i32> {
    let base = libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC;
    if NOATIME.load(std::sync::atomic::Ordering::Relaxed) {
        let fd = unsafe { libc::openat(dirfd, name.as_ptr(), base | O_NOATIME) };
        if fd >= 0 {
            return Some(fd);
        }
        if io::Error::last_os_error().raw_os_error() != Some(libc::EPERM) {
            return None;
        }
        NOATIME.store(false, std::sync::atomic::Ordering::Relaxed);
    }
    let fd = unsafe { libc::openat(dirfd, name.as_ptr(), base) };
    if fd < 0 {
        None
    } else {
        Some(fd)
    }
}

pub fn read_dir_fd(fd: i32, visit: impl FnMut(Entry)) -> bool {
    read_dir_where(fd, |_| true, visit)
}

pub fn read_names(fd: i32, mut visit: impl FnMut(&[u8], u64)) -> bool {
    let copy = unsafe { libc::dup(fd) };
    if copy < 0 {
        return false;
    }
    let dir = unsafe { libc::fdopendir(copy) };
    if dir.is_null() {
        close(copy);
        return false;
    }
    loop {
        let entry = unsafe { libc::readdir64(dir) };
        if entry.is_null() {
            break;
        }
        let bytes = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) }.to_bytes();
        if bytes != b"." && bytes != b".." {
            visit(bytes, unsafe { (*entry).d_ino });
        }
    }
    unsafe {
        libc::closedir(dir);
    }
    true
}

pub fn stat_at(fd: i32, name: &[u8]) -> Option<Entry> {
    let raw = CString::new(name).ok()?;
    let mut info: libc::stat = unsafe { std::mem::zeroed() };
    if unsafe { libc::fstatat(fd, raw.as_ptr(), &mut info, libc::AT_SYMLINK_NOFOLLOW) } != 0 {
        return None;
    }
    Some(from_stat(name.to_vec(), &info))
}

pub fn read_dir_where(
    fd: i32,
    mut keep: impl FnMut(&[u8]) -> bool,
    mut visit: impl FnMut(Entry),
) -> bool {
    let copy = unsafe { libc::dup(fd) };
    if copy < 0 {
        return false;
    }
    let dir = unsafe { libc::fdopendir(copy) };
    if dir.is_null() {
        close(copy);
        return false;
    }
    loop {
        let entry = unsafe { libc::readdir64(dir) };
        if entry.is_null() {
            break;
        }
        let raw = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) };
        let bytes = raw.to_bytes();
        if bytes == b"." || bytes == b".." || !keep(bytes) {
            continue;
        }
        let mut info: libc::stat = unsafe { std::mem::zeroed() };
        if unsafe { libc::fstatat(fd, raw.as_ptr(), &mut info, libc::AT_SYMLINK_NOFOLLOW) } != 0 {
            continue;
        }
        visit(from_stat(bytes.to_vec(), &info));
    }
    unsafe {
        libc::closedir(dir);
    }
    true
}

pub fn walk_tree(path: &str, mut visit: impl FnMut(&Entry)) -> bool {
    let Some(root) = open_walk(libc::AT_FDCWD, &cstr(path)) else {
        return false;
    };
    let mut stack = vec![root];
    while let Some(fd) = stack.pop() {
        read_dir_fd(fd, |entry| {
            visit(&entry);
            if is_dir(entry.mode) {
                if let Ok(name) = CString::new(entry.name.clone()) {
                    if let Some(child) = open_walk(fd, &name) {
                        stack.push(child);
                    }
                }
            }
        });
        close(fd);
    }
    true
}
