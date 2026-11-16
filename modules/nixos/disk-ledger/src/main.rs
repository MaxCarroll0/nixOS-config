// disk-ledger: disk accounting, reclaim model and collector daemon.

mod gc;
mod ledger;
mod probe;
mod reclaim;
mod remove;
mod store;
mod sys;
mod tree;

use std::time::{Duration, Instant};

fn store_report(args: &[String]) -> i32 {
    let cache = std::env::var("STORE_INDEX_CACHE")
        .unwrap_or_else(|_| "/var/lib/disk-ledger/store-index.sqlite".into());
    let mut walk = 0.0;
    let mut paths = Vec::new();
    let mut rest = args.iter();
    while let Some(arg) = rest.next() {
        match arg.as_str() {
            "--walk" => {
                walk = rest
                    .next()
                    .and_then(|value| value.parse().ok())
                    .unwrap_or(0.0)
            }
            "--path" => paths.extend(rest.next().cloned()),
            _ => {}
        }
    }
    let started = Instant::now();
    let mut index = store::Store::new(&cache);
    index.load();
    let loaded = started.elapsed();
    index.refresh_roots();
    let rooted = started.elapsed();
    index.scan_links();
    index.walk_pending(Instant::now() + Duration::from_secs_f64(walk));
    index.scan_links();
    for path in &paths {
        println!("{:14} {}", index.size_of(path), path);
    }
    let dead = index.dead.clone();
    let sizing = Instant::now();
    let dead_bytes: u64 = dead.iter().map(|slot| index.size(*slot)).sum();
    let report = serde_json::json!({
        "paths": index.count(),
        "walked": index.paths.iter().filter(|p| p.alive && p.own.is_some()).count(),
        "pending": index.pending.len(),
        "registered_bytes": index.registered_bytes(),
        "orphan_bytes": index.orphan_bytes,
        "orphans": index.orphan_count,
        "stale_links": index.stale_links,
        "links_dir_bytes": index.links_blocks,
        "dead_paths": dead.len(),
        "dead_bytes": dead_bytes,
    });
    println!("{}", serde_json::to_string_pretty(&report).unwrap());
    eprintln!(
        "load {:?} roots {:?} sizes {:?}",
        loaded,
        rooted - loaded,
        sizing.elapsed()
    );
    0
}

fn candidates(args: &[String]) -> i32 {
    let cache = std::env::var("STORE_INDEX_CACHE")
        .unwrap_or_else(|_| "/var/lib/disk-ledger/store-index.sqlite".into());
    let home = std::env::var("LEDGER_HOME")
        .or_else(|_| std::env::var("HOME"))
        .unwrap_or_else(|_| "/home/max".into());
    let user = std::env::var("LEDGER_USER")
        .or_else(|_| std::env::var("USER"))
        .unwrap_or_else(|_| "max".into());
    let mut limit = 60usize;
    let mut kind: Option<reclaim::Kind> = None;
    let mut now = sys::now() as i64;
    let mut dump = false;
    let mut rest = args.iter();
    while let Some(arg) = rest.next() {
        match arg.as_str() {
            "--limit" => {
                limit = rest
                    .next()
                    .and_then(|value| value.parse().ok())
                    .unwrap_or(limit)
            }
            "--kind" => {
                kind = rest
                    .next()
                    .and_then(|value| reclaim::Kind::from_name(value))
            }
            "--now" => {
                now = rest
                    .next()
                    .and_then(|value| value.parse().ok())
                    .unwrap_or(now)
            }
            "--json" => dump = true,
            _ => {}
        }
    }
    let mut index = store::Store::new(&cache);
    index.load();
    index.refresh_roots();
    index.walk_pending(Instant::now() + Duration::from_secs(86400));
    index.scan_links();
    let worktrees = reclaim::glob_worktrees(&home);
    let repos = reclaim::glob_repos(&home);
    let mut model = reclaim::Model::new(&home, &user, None, reclaim::BuildTimes::new(None));
    let started = Instant::now();
    model.refresh(&mut index, &reclaim::Walked, &worktrees, &repos, now);
    while model.clones_pending() {
        std::thread::sleep(Duration::from_millis(200));
    }
    model.refresh(&mut index, &reclaim::Walked, &worktrees, &repos, now);
    let elapsed = started.elapsed();
    if dump {
        let items: Vec<serde_json::Value> = model
            .items
            .iter()
            .map(|item| {
                serde_json::json!([
                    item.rank,
                    item.kind.name(),
                    item.path,
                    item.store_bytes,
                    item.file_bytes,
                    item.build,
                    item.last_used,
                    item.store.len()
                ])
            })
            .collect();
        let protected: serde_json::Map<String, serde_json::Value> = model
            .protected
            .iter()
            .map(|(path, why)| (path.clone(), why.clone().into()))
            .collect();
        let claims: Vec<serde_json::Value> = model
            .claims
            .iter()
            .map(|claim| {
                serde_json::json!([claim.class, claim.link, claim.found.len(), claim.bytes])
            })
            .collect();
        let dead: Vec<&str> = index
            .dead
            .iter()
            .map(|id| index.paths[*id as usize].path.as_str())
            .collect();
        println!(
            "{}",
            serde_json::json!({"items": items, "protected": protected, "claims": claims, "dead": dead})
        );
        eprintln!("refresh {:.3}s", elapsed.as_secs_f64());
        return 0;
    }
    println!("refresh {:.3}s", elapsed.as_secs_f64());
    let shown: Vec<&reclaim::Item> = model
        .items
        .iter()
        .filter(|item| match kind {
            Some(kind) => item.kind == kind,
            None => item.kind != reclaim::Kind::Dead,
        })
        .collect();
    for item in shown.iter().take(limit) {
        println!(
            "{:7} {:13} {:8.3} GiB {:6}s {} {}",
            item.rank,
            item.kind.name(),
            item.freed() as f64 / 1073741824.0,
            item.build,
            item.last_used,
            item.path
        );
    }
    println!("protected:");
    let mut protected: Vec<(&String, &String)> = model
        .protected
        .iter()
        .filter(|(path, _)| !path.starts_with("/proc/"))
        .collect();
    protected.sort();
    for (path, why) in protected {
        println!("  {:22} {}", why, path);
    }
    let dead = model
        .items
        .iter()
        .filter(|item| item.kind == reclaim::Kind::Dead)
        .count();
    let freed: u64 = model.items.iter().map(|item| item.freed()).sum();
    let kept: u64 = model.claims.iter().map(|claim| claim.bytes).sum();
    println!(
        "items {}; dead {}; freed total {:.2} GiB; protected store {:.2} GiB",
        model.items.len(),
        dead,
        freed as f64 / 1073741824.0,
        kept as f64 / 1073741824.0
    );
    0
}

fn main() {
    unsafe { libc::mallopt(libc::M_ARENA_MAX, 1) };
    let args: Vec<String> = std::env::args().collect();
    let code = match args.get(1).map(String::as_str) {
        Some("store") => store_report(&args[2..]),
        Some("candidates") => candidates(&args[2..]),
        Some("restore") => ledger::restore(args.get(2).map(String::as_str).unwrap_or("/")),
        Some("roots") => {
            let mut lines: Vec<String> = store::gc_roots()
                .into_iter()
                .flat_map(|(path, links)| {
                    links
                        .into_iter()
                        .map(move |link| format!("{link} -> {path}"))
                })
                .collect();
            lines.sort();
            println!("{}", lines.join("\n"));
            0
        }
        Some("collect") if args.len() > 3 => {
            let layout = gc::Layout {
                store: args[2].clone(),
                state: args[3].clone(),
                links_index: std::env::var("LEDGER_LINKS_INDEX").ok(),
            };
            let orphans: Vec<String> = std::env::var("LEDGER_ORPHANS")
                .map(|names| {
                    names
                        .split(' ')
                        .filter(|name| !name.is_empty())
                        .map(str::to_string)
                        .collect()
                })
                .unwrap_or_default();
            let mut code = 0;
            let mut paths: Vec<String> = Vec::new();
            let mut lines = std::io::stdin()
                .lines()
                .map_while(Result::ok)
                .chain(std::iter::once("--".to_string()));
            while let Some(line) = lines.next() {
                if line != "--" {
                    paths.push(line);
                    continue;
                }
                if paths.is_empty() {
                    continue;
                }
                match gc::plan(&layout, &paths).and_then(|(ordered, references)| {
                    gc::collect(&layout, &ordered, &references, &orphans, &mut |_| {})
                }) {
                    Ok(report) => {
                        let mut refused: Vec<&String> = report.refused.iter().collect();
                        refused.sort();
                        println!(
                            "{}",
                            serde_json::json!({"deleted": report.deleted, "entries": report.entries, "slowest": [(report.slowest.0 * 1e3).round(), report.slowest.1, report.slowest.2], "links": report.links, "refused": refused, "strays": report.strays, "error": report.error, "ms": report.milliseconds()})
                        );
                        code |= i32::from(report.error.is_some() || !report.strays.is_empty());
                    }
                    Err(reason) => {
                        eprintln!("native collection unavailable: {reason}");
                        code = 2;
                    }
                }
                paths.clear();
            }
            code
        }
        Some("remove") if args.len() > 3 => {
            let (uid, gid) = if args[2] == "root" {
                (0, 0)
            } else {
                reclaim::user_ids(&args[2]).unwrap_or((u32::MAX, u32::MAX))
            };
            let outcome = remove::remove_as(uid, gid, args[3..].to_vec());
            println!("removed {} failed {:?}", outcome.removed, outcome.failed);
            i32::from(!outcome.failed.is_empty())
        }
        Some("serve") => match ledger::Ledger::new() {
            Ok(mut daemon) => {
                daemon.run();
                0
            }
            Err(error) => {
                eprintln!("disk-ledger: {error}");
                1
            }
        },
        _ => {
            eprintln!("usage: disk-ledger store|serve|dump|candidates|restore|bench");
            2
        }
    };
    std::process::exit(code);
}
