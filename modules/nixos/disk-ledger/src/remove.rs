// Native deletion as the owning user: no symlink is ever followed and no mount is crossed.
use std::ffi::{CStr, CString};
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

const RESOLVE_NO_XDEV: u64 = 0x01;
const RESOLVE_NO_SYMLINKS: u64 = 0x04;
const RESOLVE_BENEATH: u64 = 0x08;

#[derive(Default, Debug, PartialEq, Eq)]
pub struct Outcome {
    pub removed: usize,
    pub failed: Vec<(String, i32)>,
}

struct Fd(i32);

impl Drop for Fd {
    fn drop(&mut self) {
        unsafe { libc::close(self.0) };
    }
}

fn errno() -> i32 {
    std::io::Error::last_os_error().raw_os_error().unwrap_or(libc::EIO)
}

fn open2(dir: i32, name: &CStr, flags: i32, resolve: u64) -> Result<Fd, i32> {
    let mut how: libc::open_how = unsafe { std::mem::zeroed() };
    how.flags = (flags | libc::O_CLOEXEC) as u64;
    how.resolve = resolve;
    let fd = unsafe { libc::syscall(libc::SYS_openat2, dir, name.as_ptr(), &how as *const libc::open_how, std::mem::size_of::<libc::open_how>()) };
    if fd < 0 { Err(errno()) } else { Ok(Fd(fd as i32)) }
}

fn stat_at(dir: i32, name: &CStr) -> Result<libc::stat, i32> {
    let mut stat: libc::stat = unsafe { std::mem::zeroed() };
    if unsafe { libc::fstatat(dir, name.as_ptr(), &mut stat, libc::AT_SYMLINK_NOFOLLOW) } < 0 { Err(errno()) } else { Ok(stat) }
}

fn entries(dir: &Fd) -> Result<Vec<(CString, u8)>, i32> {
    let copy = unsafe { libc::dup(dir.0) };
    if copy < 0 {
        return Err(errno());
    }
    let stream = unsafe { libc::fdopendir(copy) };
    if stream.is_null() {
        unsafe { libc::close(copy) };
        return Err(errno());
    }
    unsafe { libc::rewinddir(stream) };
    let mut found = Vec::new();
    loop {
        let entry = unsafe { libc::readdir64(stream) };
        if entry.is_null() {
            break;
        }
        let name = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) };
        if name.to_bytes() != b"." && name.to_bytes() != b".." {
            found.push((name.to_owned(), unsafe { (*entry).d_type }));
        }
    }
    unsafe { libc::closedir(stream) };
    Ok(found)
}

fn writable(dir: &Fd) {
    let mut stat: libc::stat = unsafe { std::mem::zeroed() };
    if unsafe { libc::fstat(dir.0, &mut stat) } == 0 && stat.st_mode & 0o700 != 0o700 {
        unsafe { libc::fchmod(dir.0, (stat.st_mode & 0o7777) | 0o700) };
    }
}

fn clear(dir: &Fd, path: &mut Vec<u8>, outcome: &mut Outcome, linked: &mut Option<&mut Vec<u64>>) {
    writable(dir);
    let listed = match entries(dir) {
        Ok(listed) => listed,
        Err(code) => return outcome.failed.push((String::from_utf8_lossy(path).into_owned(), code)),
    };
    for (name, kind) in listed {
        let mark = path.len();
        path.push(b'/');
        path.extend_from_slice(name.to_bytes());
        remove_entry(dir, &name, kind, path, outcome, linked);
        path.truncate(mark);
    }
}

fn remove_entry(parent: &Fd, name: &CStr, kind: u8, path: &mut Vec<u8>, outcome: &mut Outcome, linked: &mut Option<&mut Vec<u64>>) {
    let directory = if kind == libc::DT_DIR {
        true
    } else if kind == libc::DT_UNKNOWN || linked.is_some() {
        match stat_at(parent.0, name) {
            Ok(stat) => {
                let directory = stat.st_mode & libc::S_IFMT == libc::S_IFDIR;
                if let (false, true, Some(found)) = (directory, stat.st_nlink > 1, linked.as_mut()) {
                    found.push(stat.st_ino);
                }
                directory
            }
            Err(libc::ENOENT) => return,
            Err(code) => return outcome.failed.push((String::from_utf8_lossy(path).into_owned(), code)),
        }
    } else {
        false
    };
    if directory {
        match open2(parent.0, name, libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW, RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS | RESOLVE_NO_XDEV) {
            Ok(child) => clear(&child, path, outcome, linked),
            Err(libc::ENOENT) => return,
            Err(code) => return outcome.failed.push((String::from_utf8_lossy(path).into_owned(), code)),
        }
    }
    let flags = if directory { libc::AT_REMOVEDIR } else { 0 };
    match unsafe { libc::unlinkat(parent.0, name.as_ptr(), flags) } {
        0 => outcome.removed += 1,
        _ => match errno() {
            libc::ENOENT => {}
            code => outcome.failed.push((String::from_utf8_lossy(path).into_owned(), code)),
        },
    }
}

pub fn remove_tree(path: &str, outcome: &mut Outcome) {
    remove_tree_linked(path, outcome, &mut None);
}

pub fn remove_tree_linked(path: &str, outcome: &mut Outcome, linked: &mut Option<&mut Vec<u64>>) {
    let target = Path::new(path);
    let (Some(parent), Some(name)) = (target.parent(), target.file_name()) else {
        return outcome.failed.push((path.to_string(), libc::EINVAL));
    };
    if !target.is_absolute() || name.as_bytes() == b".." {
        return outcome.failed.push((path.to_string(), libc::EINVAL));
    }
    let (Ok(parent), Ok(name)) = (CString::new(parent.as_os_str().as_bytes()), CString::new(name.as_bytes())) else {
        return outcome.failed.push((path.to_string(), libc::EINVAL));
    };
    let parent = match open2(libc::AT_FDCWD, &parent, libc::O_RDONLY | libc::O_DIRECTORY, RESOLVE_NO_SYMLINKS) {
        Ok(parent) => parent,
        Err(libc::ENOENT) => return,
        Err(code) => return outcome.failed.push((path.to_string(), code)),
    };
    remove_entry(&parent, &name, libc::DT_UNKNOWN, &mut path.as_bytes().to_vec(), outcome, linked);
}

pub fn prefetch(roots: Vec<String>, threads: usize) -> usize {
    let roots: Vec<String> = roots.into_iter().filter(|root| std::fs::symlink_metadata(root).is_ok_and(|found| found.is_dir())).collect();
    let queue = std::sync::Mutex::new((roots, 0usize));
    let ready = std::sync::Condvar::new();
    let seen = std::sync::atomic::AtomicUsize::new(0);
    std::thread::scope(|scope| {
        for _ in 0..threads.max(1) {
            scope.spawn(|| loop {
                let directory = {
                    let mut state = queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                    loop {
                        if let Some(directory) = state.0.pop() {
                            state.1 += 1;
                            break directory;
                        }
                        if state.1 == 0 {
                            ready.notify_all();
                            return;
                        }
                        state = ready.wait(state).unwrap_or_else(std::sync::PoisonError::into_inner);
                    }
                };
                let mut below = Vec::new();
                let mut count = 0;
                if let Ok(entries) = std::fs::read_dir(&directory) {
                    for entry in entries.flatten() {
                        count += 1;
                        if entry.metadata().is_ok_and(|found| found.is_dir()) {
                            below.push(entry.path().to_string_lossy().into_owned());
                        }
                    }
                }
                seen.fetch_add(count, std::sync::atomic::Ordering::Relaxed);
                let mut state = queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                state.0.extend(below);
                state.1 -= 1;
                ready.notify_all();
            });
        }
    });
    seen.into_inner()
}

fn become_owner(uid: u32, gid: u32) -> Result<(), i32> {
    if unsafe { libc::geteuid() } != 0 || uid == 0 {
        return Ok(());
    }
    // Raw syscalls change only this thread's credentials; the glibc wrappers would change every thread.
    let steps: [(libc::c_long, [u64; 3]); 3] = [
        (libc::SYS_setgroups, [0, 0, 0]),
        (libc::SYS_setresgid, [gid as u64; 3]),
        (libc::SYS_setresuid, [uid as u64; 3]),
    ];
    for (call, args) in steps {
        if unsafe { libc::syscall(call, args[0], args[1], args[2]) } != 0 {
            return Err(errno());
        }
    }
    Ok(())
}

pub fn remove_as(uid: u32, gid: u32, paths: Vec<String>) -> Outcome {
    std::thread::spawn(move || {
        let mut outcome = Outcome::default();
        if let Err(code) = become_owner(uid, gid) {
            outcome.failed = paths.into_iter().map(|path| (path, code)).collect();
            return outcome;
        }
        for path in &paths {
            remove_tree(path, &mut outcome);
        }
        outcome
    })
    .join()
    .unwrap_or_else(|_| Outcome { removed: 0, failed: vec![(String::new(), libc::EIO)] })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    fn scratch(name: &str) -> std::path::PathBuf {
        let root = std::env::temp_dir().join(format!("remove-test-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        root
    }

    #[test]
    fn removes_nested_tree_and_readonly_dirs() {
        let root = scratch("nested");
        let tree = root.join("tree");
        std::fs::create_dir_all(tree.join("a/b/c")).unwrap();
        std::fs::write(tree.join("a/b/c/file"), b"x").unwrap();
        std::fs::write(tree.join("top"), b"y").unwrap();
        std::fs::set_permissions(tree.join("a/b"), std::os::unix::fs::PermissionsExt::from_mode(0o555)).unwrap();
        let mut outcome = Outcome::default();
        remove_tree(tree.to_str().unwrap(), &mut outcome);
        assert!(outcome.failed.is_empty(), "{:?}", outcome.failed);
        assert_eq!(outcome.removed, 6);
        assert!(!tree.exists());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn never_follows_symlinks() {
        let root = scratch("links");
        let keep = root.join("keep");
        std::fs::create_dir_all(&keep).unwrap();
        std::fs::write(keep.join("precious"), b"z").unwrap();
        let tree = root.join("tree");
        std::fs::create_dir_all(&tree).unwrap();
        symlink(&keep, tree.join("inner")).unwrap();
        symlink(keep.join("precious"), tree.join("file")).unwrap();
        let mut outcome = Outcome::default();
        remove_tree(tree.to_str().unwrap(), &mut outcome);
        assert!(outcome.failed.is_empty(), "{:?}", outcome.failed);
        assert!(!tree.exists());
        assert!(keep.join("precious").exists());

        let via = root.join("via");
        symlink(&keep, &via).unwrap();
        let mut outcome = Outcome::default();
        remove_tree(via.join("precious").to_str().unwrap(), &mut outcome);
        assert_eq!(outcome.failed.len(), 1);
        assert_eq!(outcome.failed[0].1, libc::ELOOP);
        assert!(keep.join("precious").exists());

        let mut outcome = Outcome::default();
        remove_tree(via.to_str().unwrap(), &mut outcome);
        assert!(outcome.failed.is_empty());
        assert!(!via.exists());
        assert!(keep.join("precious").exists());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn missing_is_not_a_failure() {
        let root = scratch("missing");
        let mut outcome = Outcome::default();
        remove_tree(root.join("absent/deeper").to_str().unwrap(), &mut outcome);
        remove_tree(root.join("absent").to_str().unwrap(), &mut outcome);
        assert_eq!(outcome, Outcome::default());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn rejects_relative_and_dotdot() {
        let mut outcome = Outcome::default();
        remove_tree("relative/path", &mut outcome);
        remove_tree("/tmp/..", &mut outcome);
        assert_eq!(outcome.failed.len(), 2);
    }
}
