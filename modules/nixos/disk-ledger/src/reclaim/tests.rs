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
fn only_known_caches_are_reclaimable() {
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
    let scope = model.scope();
    let mut failures = Vec::new();
    for (name, known) in [
        ("mesa_shader_cache", true),
        ("zoom", true),
        ("khelpcenter", false),
        ("wake-peer", false),
        ("rofi-entry-history.txt", false),
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
        ("wake-peer/x", false),
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
