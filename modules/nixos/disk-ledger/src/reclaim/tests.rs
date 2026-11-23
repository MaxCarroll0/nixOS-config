use super::*;
use std::fs;
use std::process::Command;
use std::time::{Duration, SystemTime};

struct Fixture {
    base: String,
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.base);
    }
}

fn fixture(name: &str) -> Fixture {
    let base = std::env::temp_dir()
        .join(format!("ledger-fixture-{name}-{}", std::process::id()))
        .to_string_lossy()
        .into_owned();
    let _ = fs::remove_dir_all(&base);
    fs::create_dir_all(&base).unwrap();
    Fixture { base }
}

fn git(args: &[&str]) {
    let status = Command::new("git")
        .args([
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "-c",
            "init.defaultBranch=main",
        ])
        .args(args)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("HOME", "/nonexistent")
        .output()
        .unwrap();
    assert!(
        status.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&status.stderr)
    );
}

fn make(path: &str, file: bool) {
    if file {
        fs::write(path, "x").unwrap();
    } else {
        fs::create_dir_all(path).unwrap();
        fs::write(format!("{path}/f"), "x").unwrap();
    }
}

fn age(root: &str, skip: &str, when: SystemTime) {
    let times = fs::FileTimes::new().set_accessed(when).set_modified(when);
    let mut stack = vec![root.to_string()];
    let mut all = Vec::new();
    while let Some(dir) = stack.pop() {
        for entry in fs::read_dir(&dir).unwrap() {
            let entry = entry.unwrap();
            let path = entry.path().to_string_lossy().into_owned();
            let kind = entry.file_type().unwrap();
            if kind.is_symlink() {
                continue;
            }
            if kind.is_dir() {
                stack.push(path.clone());
            }
            all.push(path);
        }
    }
    all.sort_by_key(|path| std::cmp::Reverse(path.len()));
    for path in all {
        if !path.starts_with(skip) {
            fs::File::open(&path).unwrap().set_times(times).unwrap();
        }
    }
}

fn me() -> String {
    user_name(unsafe { libc::geteuid() }).expect("current user has a passwd entry")
}

fn temp_work(path: &str, detail: Map<String, Value>) -> Work {
    Work {
        kind: Kind::Temp,
        path: path.into(),
        links: Vec::new(),
        files: vec![path.into()],
        freed: 0,
        last_used: 0,
        detail,
        store: Vec::new(),
    }
}

#[test]
fn tmp_entries_are_classified_and_rechecked() {
    let fx = fixture("tmp");
    let tmp = format!("{}/tmp", fx.base);
    fs::create_dir_all(&tmp).unwrap();
    let own = format!("nix-develop-{}-7", std::process::id());
    let cases: Vec<(&str, &str)> = vec![
        ("nix-shell.AbCd12", "temp"),
        ("nix-999999-1", "temp"),
        (own.as_str(), "owner process alive"),
        ("hazel-thing", "temp?"),
        ("crbuild", "temp?"),
        ("unpushed", "temp?"),
        ("pushed-clean", "temp?"),
        ("held", "busy"),
        ("fresh", "temp?"),
        ("tmp.abcdefghij", "temp"),
        ("babel-xY12zz", "temp"),
        ("foo-0123abcd.log", "temp?"),
    ];
    for (name, _) in &cases {
        make(&format!("{tmp}/{name}"), name.ends_with(".log"));
    }
    git(&["init", "-q", &format!("{tmp}/unpushed/repo")]);
    git(&[
        "-C",
        &format!("{tmp}/unpushed/repo"),
        "commit",
        "-q",
        "--allow-empty",
        "-m",
        "x",
    ]);
    git(&["init", "-q", "--bare", &format!("{}/remote.git", fx.base)]);
    git(&[
        "clone",
        "-q",
        &format!("{}/remote.git", fx.base),
        &format!("{tmp}/pushed-clean/repo"),
    ]);
    git(&[
        "-C",
        &format!("{tmp}/pushed-clean/repo"),
        "commit",
        "-q",
        "--allow-empty",
        "-m",
        "x",
    ]);
    git(&[
        "-C",
        &format!("{tmp}/pushed-clean/repo"),
        "push",
        "-q",
        "origin",
        "HEAD",
    ]);
    age(
        &fx.base,
        &format!("{tmp}/fresh"),
        SystemTime::now() - Duration::from_secs(5 * 86400),
    );
    let held = fs::File::open(format!("{tmp}/held/f")).unwrap();

    let user = me();
    let mut model = Model::new(
        &format!("{}/home", fx.base),
        &user,
        None,
        BuildTimes::new(None),
    );
    model.tmp = tmp.clone();
    let busy = busy_paths();
    let items: HashMap<String, Item> = model
        .tmp_items(&[], &busy, &Walked)
        .into_iter()
        .map(|item| (basename(&item.path).to_string(), item))
        .collect();
    model.now = sys::now() as i64 + 60;
    let scope = model.scope();
    let mut failures = Vec::new();
    for (name, want) in &cases {
        let path = format!("{tmp}/{name}");
        let got = match items.get(*name) {
            Some(item) if item.detail["pattern"] == Value::Bool(true) => "temp".to_string(),
            Some(_) => "temp?".to_string(),
            None if busy.contains(&path) => "busy".to_string(),
            None => model
                .protected
                .get(&path)
                .cloned()
                .unwrap_or_else(|| "skipped".into()),
        };
        if got != *want {
            failures.push(format!("{name}: want {want}, got {got}"));
        }
        if let Some(item) = items.get(*name) {
            if let Some(refusal) = scope.refusal(&Work::of(item), &busy, &[], &process_starts()) {
                failures.push(format!(
                    "{name}: candidate refused by the executor: {refusal}"
                ));
            }
        }
    }
    for name in ["held", own.as_str()] {
        let path = format!("{tmp}/{name}");
        if scope
            .refusal(&temp_work(&path, Map::new()), &busy, &[], &process_starts())
            .is_none()
        {
            failures.push(format!("{name}: executor allowed an active entry"));
        }
    }
    let outside = format!("{}/home/notes", fx.base);
    fs::create_dir_all(&outside).unwrap();
    if scope
        .refusal(
            &temp_work(&outside, Map::new()),
            &busy,
            &[],
            &process_starts(),
        )
        .is_none()
    {
        failures.push("executor allowed a path outside tmp".into());
    }
    drop(held);
    assert!(failures.is_empty(), "{failures:#?}");
}

#[test]
fn everything_in_cache_but_roots_is_reclaimable() {
    let fx = fixture("cache");
    let cache = format!("{}/home/.cache", fx.base);
    for name in [
        "mesa_shader_cache",
        "wake-peer",
        "nix-gcroots",
        "zoom/qmlcache",
        "zoom/qtpipelinecache-x",
        "khelpcenter/qmlcache",
        "khelpcenter/index",
    ] {
        fs::create_dir_all(format!("{cache}/{name}")).unwrap();
    }
    fs::write(format!("{cache}/rofi-entry-history.txt"), "h").unwrap();
    let mut model = Model::new(
        &format!("{}/home", fx.base),
        &me(),
        None,
        BuildTimes::new(None),
    );
    model.tmp = format!("{}/tmp", fx.base);
    model.now = sys::now() as i64 + 60;
    let scope = model.scope();
    let mut failures = Vec::new();
    for (name, known) in [
        ("mesa_shader_cache", true),
        ("zoom", true),
        ("khelpcenter", true),
        ("wake-peer", true),
        ("rofi-entry-history.txt", true),
        ("nix-gcroots", false),
    ] {
        let path = format!("{cache}/{name}");
        if cache_known(&path) != known {
            failures.push(format!("{name}: cache_known should be {known}"));
        }
        let work = Work {
            kind: Kind::Cache,
            path: path.clone(),
            links: Vec::new(),
            files: vec![path],
            freed: 0,
            last_used: 0,
            detail: Map::new(),
            store: Vec::new(),
        };
        if scope
            .refusal(&work, &HashSet::new(), &[], &process_starts())
            .is_some()
            == known
        {
            failures.push(format!(
                "{name}: executor decision disagrees with cache_known"
            ));
        }
    }
    for (name, inside) in [
        ("mesa_shader_cache/deep/x", true),
        ("nix-gcroots/x", false),
        ("wake-peer/x", true),
        ("mesa_shader_cache/../wake-peer", false),
    ] {
        let path = format!("{cache}/{name}");
        fs::create_dir_all(&path).unwrap();
        let work = Work {
            kind: Kind::Cache,
            path: path.clone(),
            links: Vec::new(),
            files: vec![path],
            freed: 0,
            last_used: 0,
            detail: Map::new(),
            store: Vec::new(),
        };
        if scope
            .refusal(&work, &HashSet::new(), &[], &process_starts())
            .is_none()
            != inside
        {
            failures.push(format!("{name}: inside a known cache should be {inside}"));
        }
    }
    assert!(failures.is_empty(), "{failures:#?}");
}

#[test]
fn age_outweighs_kind_weight() {
    let now = 1_000 * 86400;
    let at = |days: f64| now as f64 - days * 86400.0;
    let unknown_temp = |days: f64| {
        let mut item = Item::new(Kind::Temp, "unknown", at(days));
        item.factor = UNKNOWN_TEMP_FACTOR;
        item
    };
    assert!(Item::new(Kind::Dead, "dead", at(1.0)).score(now) > unknown_temp(1.0).score(now));
    assert!(unknown_temp(4.5).score(now) > Item::new(Kind::Cache, "cache", at(1.0)).score(now));
    assert!(
        Item::new(Kind::Project, "old", at(90.0)).score(now)
            > Item::new(Kind::Temp, "young", at(22.0)).score(now)
    );
    assert!(Item::new(Kind::Cache, "cache", at(30.0)).score(now) > unknown_temp(60.0).score(now));
    assert!(unknown_temp(365.0).score(now) > Item::new(Kind::Cache, "cache", at(60.0)).score(now));
}

#[test]
fn clone_shrinks_and_restores() {
    let fixture = fixture("clone");
    let base = &fixture.base;
    let remote = format!("{base}/remote.git");
    let repo = format!("{base}/work");
    let read = |name: &str| fs::read_to_string(format!("{repo}/{name}")).unwrap();
    let user = user_name(unsafe { libc::getuid() }).unwrap();
    git(&["init", "--bare", &remote]);
    git(&["init", &repo]);
    git(&[
        "-C",
        &repo,
        "config",
        &format!("url.{remote}.insteadOf"),
        "https://example.invalid/x.git",
    ]);
    git(&[
        "-C",
        &repo,
        "remote",
        "add",
        "origin",
        "https://example.invalid/x.git",
    ]);
    fs::create_dir_all(format!("{repo}/src/deep")).unwrap();
    fs::write(format!("{repo}/src/deep/a.txt"), "a\n").unwrap();
    fs::write(format!("{repo}/b.txt"), "b\n").unwrap();
    fs::write(format!("{repo}/c.txt"), "c\n").unwrap();
    git(&["-C", &repo, "add", "."]);
    git(&["-C", &repo, "commit", "-m", "one"]);
    assert!(clone_state(&repo, &user)
        .err()
        .unwrap()
        .contains("unpushed"));
    git(&["-C", &repo, "push", "origin", "main"]);
    fs::write(format!("{repo}/src/deep/a.txt"), "a2\n").unwrap();
    git(&["-C", &repo, "commit", "-q", "-am", "two"]);
    git(&["-C", &repo, "tag", "-a", "local", "-m", "t"]);
    fs::write(format!("{repo}/b.txt"), "changed\n").unwrap();
    fs::write(format!("{repo}/c.txt"), "staged\n").unwrap();
    git(&["-C", &repo, "add", "c.txt"]);
    fs::write(format!("{repo}/new.txt"), "untracked\n").unwrap();
    let state = clone_state(&repo, &user).ok().unwrap();
    assert_eq!(state.dirty, 3);
    assert_eq!(state.unpushed, 1);
    assert_eq!(state.clean, vec!["src/deep/a.txt".to_string()]);
    std::thread::sleep(Duration::from_secs(3));
    let (uid, gid) = user_ids(&user).unwrap();
    shrink_clone(&repo, &user, uid, gid).unwrap();
    assert!(!lexists(&format!("{repo}/src")));
    assert!(!lexists(&format!("{repo}/.git/index")));
    assert_eq!(read("b.txt"), "changed\n");
    assert_eq!(read("new.txt"), "untracked\n");
    assert_eq!(clone_state(&repo, &user).err().unwrap(), "shrunk");
    let restored = Command::new("bash")
        .arg(format!("{repo}/.git/ledger/restore"))
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .output()
        .unwrap();
    assert!(
        restored.status.success(),
        "{}",
        String::from_utf8_lossy(&restored.stderr)
    );
    assert_eq!(read("src/deep/a.txt"), "a2\n");
    let log = Command::new("git")
        .args(["-C", &repo, "log", "--format=%s", "local"])
        .output()
        .unwrap();
    assert_eq!(String::from_utf8_lossy(&log.stdout), "two\none\n");
    assert_eq!(read("b.txt"), "changed\n");
    let status = Command::new("git")
        .args(["-C", &repo, "status", "--porcelain"])
        .output()
        .unwrap();
    let status = String::from_utf8_lossy(&status.stdout);
    assert!(
        status.contains(" M b.txt") && status.contains("M  c.txt") && status.contains("?? new.txt"),
        "{status}"
    );
}

#[test]
fn clone_with_submodule_shrinks_and_restores() {
    let fixture = fixture("submodule");
    let base = &fixture.base;
    let user = user_name(unsafe { libc::getuid() }).unwrap();
    let repo = format!("{base}/work");
    let sub = format!("{repo}/lib");
    let source = format!("{base}/lib-src");
    let read = |path: &str| fs::read_to_string(path).unwrap();
    let url = |name: &str| format!("https://example.invalid/{name}.git");
    let alias = |dir: &str, name: &str| {
        git(&[
            "-C",
            dir,
            "config",
            &format!("url.{base}/{name}.git.insteadOf"),
            &url(name),
        ])
    };
    for name in ["lib", "top"] {
        git(&["init", "--bare", &format!("{base}/{name}.git")]);
    }
    git(&["init", &source]);
    fs::write(format!("{source}/lib.txt"), "lib\n").unwrap();
    git(&["-C", &source, "add", "."]);
    git(&["-C", &source, "commit", "-m", "lib"]);
    git(&["-C", &source, "push", &format!("{base}/lib.git"), "main"]);
    git(&["init", &repo]);
    alias(&repo, "top");
    git(&["-C", &repo, "remote", "add", "origin", &url("top")]);
    fs::write(format!("{repo}/top.txt"), "top\n").unwrap();
    git(&[
        "-c",
        &format!("url.{base}/lib.git.insteadOf={}", url("lib")),
        "-c",
        "protocol.file.allow=always",
        "-C",
        &repo,
        "submodule",
        "add",
        &url("lib"),
        "lib",
    ]);
    alias(&sub, "lib");
    git(&["-C", &repo, "add", "."]);
    git(&["-C", &repo, "commit", "-m", "top"]);
    git(&["-C", &repo, "push", "origin", "main"]);
    fs::write(format!("{sub}/lib.txt"), "lib2\n").unwrap();
    git(&["-C", &sub, "commit", "-qam", "lib2"]);
    git(&["-C", &sub, "push", "origin", "main"]);
    fs::write(format!("{sub}/notes.txt"), "untracked\n").unwrap();
    let state = clone_state(&repo, &user).expect("clone state");
    assert_eq!(state.submodules.len(), 1);
    assert_eq!(state.submodules[0].0, sub);
    assert_eq!(state.submodules[0].1.clean, vec!["lib.txt".to_string()]);
    assert_eq!(state.unpushed, 0);
    std::thread::sleep(Duration::from_secs(3));
    let (uid, gid) = user_ids(&user).unwrap();
    shrink_clone(&repo, &user, uid, gid).unwrap();
    assert!(!lexists(&format!("{repo}/top.txt")));
    assert!(!lexists(&format!("{sub}/lib.txt")));
    assert!(lexists(&format!("{repo}/.git/modules/lib/ledger/restore")));
    assert!(!lexists(&format!("{repo}/.git/modules/lib/packed-refs")));
    assert_eq!(read(&format!("{sub}/notes.txt")), "untracked\n");
    assert_eq!(clone_state(&repo, &user).err().unwrap(), "shrunk");
    let restored = Command::new("bash")
        .arg(format!("{repo}/.git/ledger/restore"))
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .output()
        .unwrap();
    assert!(
        restored.status.success(),
        "{}",
        String::from_utf8_lossy(&restored.stderr)
    );
    assert_eq!(read(&format!("{repo}/top.txt")), "top\n");
    assert_eq!(read(&format!("{sub}/lib.txt")), "lib2\n");
    let status = |dir: &str| {
        let output = Command::new("git")
            .args(["-C", dir, "status", "--porcelain"])
            .output()
            .unwrap();
        String::from_utf8_lossy(&output.stdout).into_owned()
    };
    assert_eq!(status(&repo), " M lib\n");
    assert_eq!(status(&sub), "?? notes.txt\n");
    assert!(!lexists(&format!("{repo}/.git/modules/lib/ledger")));
}

#[test]
fn clone_urls() {
    assert!(
        network_url("git@github.com:o/r.git")
            && network_url("https://x/y")
            && !network_url("/srv/r.git")
            && !network_url("file:///r")
            && !network_url("../r")
    );
    assert_eq!(
        https_form("git@github.com:o/r.git").as_deref(),
        Some("https://github.com/o/r.git")
    );
    assert_eq!(
        https_form("ssh://git@host:22/o/r").as_deref(),
        Some("https://host/o/r")
    );
    assert!(
        clone_candidate("/home/u", "/home/u/src/x")
            && !clone_candidate("/home/u", "/home/u/.local/x")
            && !clone_candidate("/home/u", "/home/u")
    );
}

#[test]
fn games_use_last_play_or_install() {
    let fx = fixture("games");
    let home = format!("{}/home", fx.base);
    let apps = format!("{home}/.local/share/Steam/steamapps");
    let manifest = |id: &str, name: &str, dir: &str, played: i64| {
        fs::create_dir_all(format!("{apps}/common/{dir}")).unwrap();
        fs::write(format!("{apps}/appmanifest_{id}.acf"), format!("\"AppState\"\n{{\n\t\"appid\"\t\t\"{id}\"\n\t\"name\"\t\t\"{name}\"\n\t\"StateFlags\"\t\t\"4\"\n\t\"installdir\"\t\t\"{dir}\"\n\t\"LastPlayed\"\t\t\"{played}\"\n}}\n")).unwrap();
    };
    manifest("1", "Played Game", "Played", 4_000_000_000);
    manifest("2", "Fresh Game", "Fresh", 0);
    manifest("3", "Proton 9.0", "Proton 9.0", 0);
    manifest(
        "4",
        "Steamworks Common Redistributables",
        "Steamworks Shared",
        0,
    );
    fs::create_dir_all(format!("{apps}/shadercache/1")).unwrap();
    fs::create_dir_all(format!("{apps}/compatdata/1/pfx")).unwrap();
    fs::write(
        format!("{apps}/compatdata/1/config_info"),
        format!("9.0-203\n{apps}/common/Proton 9.0/files/share/fonts/\n"),
    )
    .unwrap();
    fs::write(format!("{apps}/compatdata/1/pfx/user.reg"), "").unwrap();
    fs::create_dir_all(format!("{home}/.local/share/Steam/userdata/7/config")).unwrap();
    fs::write(format!("{home}/.local/share/Steam/userdata/7/config/localconfig.vdf"), "\"UserLocalConfigStore\"\n{\n\t\"Software\"\n\t{\n\t\t\"apps\"\n\t\t{\n\t\t\t\"1\"\n\t\t\t{\n\t\t\t\t\"cloud\"\n\t\t\t\t{\n\t\t\t\t}\n\t\t\t\t\"LastPlayed\"\t\t\"1500000000\"\n\t\t\t}\n\t\t}\n\t}\n}\n").unwrap();
    let heroic = format!("{home}/.config/heroic");
    fs::create_dir_all(format!("{heroic}/legendaryConfig/legendary")).unwrap();
    fs::create_dir_all(format!("{heroic}/store")).unwrap();
    fs::create_dir_all(format!("{home}/Games/Heroic/Crab")).unwrap();
    fs::write(format!("{heroic}/legendaryConfig/legendary/installed.json"), format!("{{\"Crab\": {{\"title\": \"Crab Game\", \"install_path\": \"{home}/Games/Heroic/Crab\"}}, \"Out\": {{\"title\": \"Escape\", \"install_path\": \"{home}/elsewhere\"}}}}")).unwrap();
    fs::write(
        format!("{heroic}/store/timestamp.json"),
        "{\"Crab\": {\"lastPlayed\": \"2096-10-29T15:32:56.906Z\"}}",
    )
    .unwrap();
    let found = games(&home, "");
    let titles: Vec<&str> = found.iter().map(|game| game.title.as_str()).collect();
    assert_eq!(
        titles,
        ["Played Game", "Fresh Game", "Proton 9.0", "Crab Game"]
    );
    assert!(found[2].tool && !found[0].tool);
    assert_eq!(found[2].played, 1_500_000_000);
    let played = &found[0];
    assert_eq!(played.played, 4_000_000_000);
    assert!(
        played.files.contains(&format!("{apps}/shadercache/1"))
            && !played.files.iter().any(|file| file.contains("compatdata"))
    );
    assert!(found[1].played == 0 && found[1].installed > 0);
    assert_eq!(found[3].played, iso_seconds("2096-10-29T15:32:56Z"));
    assert_eq!(iso_seconds("1970-01-02T00:00:01Z"), 86401);
    let mut model = Model::new(&home, &me(), None, BuildTimes::new(None));
    model.tmp = format!("{}/tmp", fx.base);
    model.now = sys::now() as i64 + 60;
    let scope = model.scope();
    let work = |path: String| Work {
        kind: Kind::Game,
        path: path.clone(),
        links: Vec::new(),
        files: vec![path],
        freed: 0,
        last_used: 0,
        detail: json!({"store": "none"}).as_object().cloned().unwrap(),
        store: Vec::new(),
    };
    if launcher_running("steam").is_none() && launcher_running("").is_none() {
        assert_eq!(
            scope.refusal(
                &work(format!("{apps}/common/Fresh")),
                &HashSet::new(),
                &[],
                &process_starts()
            ),
            None
        );
        assert_eq!(
            scope.refusal(
                &work(format!("{apps}/common/Proton 9.0")),
                &HashSet::new(),
                &[],
                &process_starts()
            ),
            None
        );
        assert!(scope
            .refusal(
                &work(format!("{apps}/common/Steamworks Shared")),
                &HashSet::new(),
                &[],
                &process_starts()
            )
            .is_some());
    }
    forget_heroic(&home, "Crab", &me()).unwrap();
    let left =
        fs::read_to_string(format!("{heroic}/legendaryConfig/legendary/installed.json")).unwrap();
    assert!(!left.contains("Crab") && left.contains("Escape"));
}

#[test]
#[ignore]
fn partial_shrink_of_a_copied_clone() {
    let Ok(repo) = std::env::var("LEDGER_TEST_REPO") else {
        return;
    };
    let user = std::env::var("USER").unwrap();
    let state = clone_state(&repo, &user).expect("clone state");
    assert!(state.partial.is_some());
    let before = walk_size(&join(&repo, ".git/objects"));
    let (uid, gid) = user_ids(&user).unwrap();
    let estimate = shrink_clone(&repo, &user, uid, gid).expect("shrink");
    let after = walk_size(&join(&repo, ".git/objects"));
    eprintln!(
        "before {before} after {after} estimate {estimate} unpushed {}",
        state.unpushed
    );
    assert!(before - after >= estimate / 2);
    assert!(matches!(clone_state(&repo, &user), Err(reason) if reason == "partial clone"));
}

#[test]
fn removal_takes_referrers_once_in_rank_order() {
    let mut store = crate::store::Store::new(":memory:");
    let edges: [(&[u32], &[u32], bool); 4] = [
        (&[1], &[], true),
        (&[], &[0, 2, 3], true),
        (&[1], &[], true),
        (&[1], &[], false),
    ];
    for (index, (refs, referrers, alive)) in edges.iter().enumerate() {
        store.paths.push(crate::store::Path {
            path: format!("/nix/store/{index}"),
            refs: refs.to_vec(),
            referrers: referrers.to_vec(),
            alive: *alive,
            ..Default::default()
        });
    }
    let mut taken = vec![false; 4];
    let mut first = removed_with(&store, &[1], &mut taken);
    first.sort_unstable();
    assert_eq!(first, vec![0, 1, 2]);
    assert!(removed_with(&store, &[0], &mut taken).is_empty());
    assert!(removed_with(&store, &[3], &mut taken).is_empty());
}

#[test]
fn a_dead_item_leaves_its_live_dependencies_to_their_owner() {
    let mut store = crate::store::Store::new(":memory:");
    let edges: [(&[u32], &[u32]); 3] = [(&[1], &[]), (&[], &[0, 2]), (&[1], &[])];
    for (index, (refs, referrers)) in edges.iter().enumerate() {
        store.paths.push(crate::store::Path {
            path: format!("/nix/store/{index}"),
            refs: refs.to_vec(),
            referrers: referrers.to_vec(),
            alive: true,
            ..Default::default()
        });
    }
    let mut live = vec![false; 3];
    assert_eq!(claim_targets(&store, &[0], &mut live), vec![0]);
    let mut generation = claim(&store, &[2], &mut live);
    generation.sort_unstable();
    assert_eq!(generation, vec![1, 2]);
    let mut taken = vec![false; 3];
    let mut removed = removed_with(&store, &[0], &mut taken);
    removed.extend(removed_with(&store, &generation, &mut taken));
    removed.sort_unstable();
    assert_eq!(removed, vec![0, 1, 2]);
}

#[test]
fn refuses_items_changed_since_measured() {
    let fx = fixture("stale");
    let home = format!("{}/home", fx.base);
    let downloads = format!("{home}/Downloads");
    fs::create_dir_all(&downloads).unwrap();
    let path = format!("{downloads}/album.zip");
    fs::write(&path, "z").unwrap();
    let mut model = Model::new(&home, &me(), None, BuildTimes::new(None));
    let work = Work {
        kind: Kind::Download,
        path: path.clone(),
        links: Vec::new(),
        files: vec![path.clone()],
        freed: 1,
        last_used: 0,
        detail: Map::new(),
        store: Vec::new(),
    };
    let refusal = |model: &Model| {
        model
            .scope()
            .refusal(&work, &HashSet::new(), &[], &process_starts())
    };
    model.now = sys::now() as i64 + 1;
    assert_eq!(refusal(&model), None);
    model.now = sys::now() as i64 - 2;
    assert_eq!(refusal(&model).as_deref(), Some("changed since measured"));
    fs::remove_file(&path).unwrap();
    assert_eq!(refusal(&model), None);
}

#[test]
fn linked_worktrees_remove_when_merged_and_shrink_when_not() {
    let fixture = fixture("worktree");
    let base = &fixture.base;
    let repo = format!("{base}/main");
    let merged = format!("{base}/merged");
    let open = format!("{base}/open");
    let user = me();
    git(&["init", &repo]);
    fs::create_dir_all(format!("{repo}/src/deep")).unwrap();
    fs::write(format!("{repo}/src/deep/a.txt"), "a\n").unwrap();
    fs::write(format!("{repo}/.gitignore"), "build/\n").unwrap();
    git(&["-C", &repo, "add", "."]);
    git(&["-C", &repo, "commit", "-qm", "one"]);
    git(&["-C", &repo, "worktree", "add", "-q", "-b", "done", &merged]);
    git(&["-C", &repo, "worktree", "add", "-q", "-b", "wip", &open]);
    fs::write(format!("{open}/src/deep/a.txt"), "wip\n").unwrap();
    git(&["-C", &open, "commit", "-qam", "wip"]);
    fs::create_dir_all(format!("{open}/build")).unwrap();
    fs::write(format!("{open}/build/out"), "derived\n").unwrap();
    assert_eq!(linked_worktrees(&repo), vec![merged.clone(), open.clone()]);
    assert_eq!(worktree_repo(&open).as_deref(), Some(repo.as_str()));
    assert_eq!(worktree_repo(&repo), None);
    let done = worktree_state(&repo, &merged, &user).unwrap();
    assert!(done.merged && done.dirty == 0 && done.tracked == 0);
    let wip = worktree_state(&repo, &open, &user).unwrap();
    assert!(!wip.merged && wip.dirty == 0 && wip.tracked > 0);
    std::thread::sleep(Duration::from_secs(3));
    let (uid, gid) = user_ids(&user).unwrap();
    assert!(shrink_worktree(&open, &user, uid, gid).unwrap() > 0);
    assert!(!lexists(&format!("{open}/src")));
    assert!(!lexists(&format!("{open}/.gitignore")));
    assert_eq!(
        fs::read_to_string(format!("{open}/build/out")).unwrap(),
        "derived\n"
    );
    assert!(worktree_shrunk(&open));
    assert_eq!(
        shrink_worktree(&open, &user, uid, gid).err().unwrap(),
        "shrunk"
    );
    let admin = worktree_admin(&open).unwrap();
    let restored = Command::new("bash")
        .arg(format!("{admin}/ledger/restore"))
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .output()
        .unwrap();
    assert!(
        restored.status.success(),
        "{}",
        String::from_utf8_lossy(&restored.stderr)
    );
    assert_eq!(
        fs::read_to_string(format!("{open}/src/deep/a.txt")).unwrap(),
        "wip\n"
    );
    assert!(!worktree_shrunk(&open));
    let status = Command::new("git")
        .args(["-C", &open, "status", "--porcelain"])
        .output()
        .unwrap();
    assert_eq!(String::from_utf8_lossy(&status.stdout), "");
}

#[test]
fn emacs_backups_are_temp_items() {
    let fixture = fixture("emacs");
    let home = &fixture.base;
    let backups = format!("{home}/.local/state/emacs/backups");
    fs::create_dir_all(&backups).unwrap();
    let file = format!("{backups}/!home!max!notes.org~");
    fs::write(&file, "old\n").unwrap();
    let mut model = Model::new(home, &me(), None, BuildTimes::new(None));
    model.now = sys::now() as i64 + 1;
    let items = model.emacs_items(&Walked);
    assert_eq!(items.len(), 1);
    assert_eq!(items[0].kind, Kind::Temp);
    assert_eq!(items[0].path, file);
    let work = temp_work(&file, items[0].detail.clone());
    assert_eq!(
        model
            .scope()
            .refusal(&work, &HashSet::new(), &[], &process_starts()),
        None
    );
    let stray = format!("{home}/notes.org~");
    fs::write(&stray, "x\n").unwrap();
    assert!(model
        .scope()
        .refusal(
            &temp_work(&stray, Map::new()),
            &HashSet::new(),
            &[],
            &process_starts()
        )
        .is_some());
}

#[test]
fn run_as_streams_input_larger_than_a_pipe() {
    let input = "x".repeat(1 << 20) + "\n";
    let output = run_as("root", &["cat"], Some(&input));
    assert!(output.status.success());
    assert_eq!(output.stdout.len(), input.len());
}

#[test]
fn flake_repos_are_never_made_partial_clones() {
    let fixture = fixture("flake");
    let repo = format!("{}/repo", fixture.base);
    git(&["init", "-q", &repo]);
    fs::write(format!("{repo}/flake.nix"), "{ outputs = _: { }; }\n").unwrap();
    git(&["-C", &repo, "add", "."]);
    git(&["-C", &repo, "commit", "-qm", "one"]);
    git(&["-C", &repo, "remote", "add", "origin", "https://example.invalid/repo.git"]);
    fs::write(format!("{repo}/flake.nix"), "{ outputs = _: { x = 1; }; }\n").unwrap();
    git(&["-C", &repo, "stash", "-q"]);
    assert_eq!(
        clone_state(&repo, &me()).err().as_deref(),
        Some("flake repo: nix rejects extensions.partialclone")
    );
}

#[test]
fn rebuild_penalty_spares_quick_builds() {
    for (seconds, penalty) in [(0.0, 1.0), (30.0, 1.0), (60.0, 1.0), (90.0, 1.125), (120.0, 1.25), (300.0, 2.0), (600.0, 4.0), (1200.0, 8.0)] {
        assert!((rebuild_penalty(seconds) - penalty).abs() < 1e-9, "{seconds}s: {}", rebuild_penalty(seconds));
    }
}

#[test]
fn a_bound_unix_socket_holds_its_temp_dir() {
    let fixture = fixture("s");
    let dir = join(&fixture.base, "org.chromium.Chromium.a");
    fs::create_dir_all(&dir).unwrap();
    let socket = join(&dir, "SingletonSocket");
    let listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
    fs::remove_file(&socket).unwrap();
    assert!(busy_paths().contains(&dir));
    drop(listener);
    assert!(!busy_paths().contains(&dir));
}
