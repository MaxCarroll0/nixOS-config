DB = "/var/lib/nas-checkpoints/index.db"
VIEW = "/srv/nas-at"
SMB = "smbclient //localhost/disk1 -N"
AT = "/run/current-system/sw/bin/nas-at"
PREP = f"NAS_RECLAIM_FREE=0 {AT}"


def settle():
    sh(f"sync && sleep 6 && {PREP} pass")


def reclaim():
    out = sh(f"sync && sleep 6 && {PREP} pass && {PREP} reclaim")
    machine.log(out)
    return out


def start(unit, cmd, auto=False):
    run_unit(unit, cmd, "" if auto else "--setenv=NAS_RECLAIM_FREE=0")


def start_loop(unit, auto=False, every=2):
    start(unit, f"/bin/sh -c 'while [ ! -e /run/{unit}.stop ]; do {AT} pass; sleep {every}; done'", auto)


def stop_loop(unit):
    sh(f"touch /run/{unit}.stop")
    finished(unit)
    stop(unit)


def churn(tag, versions=4, mb=48):
    path = f"churn/{tag}/c"
    for _ in range(versions):
        sh(f"mkdir -p {B}/churn/{tag} && dd if=/dev/urandom of={B}/{path} bs=1M count={mb} conv=fsync status=none")
        settle()
    out = sh(f"{PREP} keep {B}/churn/{tag} --none")
    machine.log(out)
    return (versions - 1) * mb


def diag(like):
    inos = f"(SELECT ino FROM paths WHERE path LIKE '{like}%')"
    for q in [
        f"SELECT ino, inc, path, lo, hi, since FROM paths WHERE ino IN {inos}",
        f"SELECT ino, s, e, seg, dead, SUM(n), COUNT(*) FROM lives WHERE ino IN {inos} GROUP BY 1, 2, 3, 4, 5 LIMIT 40",
        f"SELECT * FROM drops WHERE ino IN {inos}",
        "SELECT * FROM scan",
        "SELECT * FROM meta",
        "SELECT cno, ss FROM checkpoints ORDER BY cno DESC LIMIT 6",
        "SELECT dead, seg IS NULL, COUNT(*), SUM(n) FROM lives GROUP BY 1, 2",
        "SELECT seg, SUM(n) FROM lives WHERE dead=1 AND seg IS NOT NULL GROUP BY seg ORDER BY 2 DESC LIMIT 10",
        "SELECT * FROM gc_runs",
    ]:
        machine.log(q + "\n" + sh(f"sqlite3 -header {DB} \"{q}\""))
    machine.log(sh(f"lscp -a {DEV} | tail -6; lssu {DEV} | awk '$4 ~ /d/' | wc -l; lssu {DEV} | tail -8"))


def view_mounts():
    return int(sh("awk '$2 ~ \"^/run/nas-at/\"' /proc/mounts | wc -l").strip())


def read_paths(at, rel):
    return {"branch": f"{B}/{rel}", "mergerfs": f"{POOL}/{rel}", "view": f"{VIEW}/@{at}/{rel}", "smb": rel}


def gc_since(since):
    count, segs, freed = sh(
        f"sqlite3 -separator ' ' {DB} \"SELECT COUNT(*), COALESCE(SUM(segs), 0), COALESCE(SUM(freed), 0) FROM gc_runs WHERE at >= {since}\""
    ).split()
    return {"runs": int(count), "segments": int(segs), "freed_mb": round(int(freed) / MB, 1)}


def tmp_churn(tag, count, mb, rate, every):
    sh(f"rm -rf {B}/tmp")
    reclaim()
    set_fill(0.75, reclaim)
    since = vm_now()
    avail = avail_mb()
    start_loop(f"passloop-{tag}", auto=True, every=every)
    row = run_tmp_churn(tag, count, mb, rate)
    stop_loop(f"passloop-{tag}")
    return {"pass_every_s": every, "avail_before_mb": avail, **row, "gc": gc_since(since)}


def quiet_window(tag):
    settle()
    sh(f"sleep 8 && {AT} pass")
    start_loop(f"quiet-{tag}", auto=True, every=10)
    row = quiet(180)
    stop_loop(f"quiet-{tag}")
    return {"pass_every_s": 10, **row}


sh("systemctl start nas-history-watch-disk1")
machine.wait_until_succeeds("test -e /var/lib/nas-checkpoints/events/disk1.jsonl")
sh(f"{AT} pass")
sh("systemctl start nas-at-view")
machine.wait_until_succeeds(f"mountpoint -q {VIEW}")

with subtest("2000 snapshots in the cpfile"):
    elapsed, _ = timed(f"for i in $(seq 2000); do mkcp -s {DEV}; done")
    R["snapshots"] = {"n": int(sh(f"lscp -s {DEV} | tail -n +2 | wc -l")), "seconds": round(elapsed, 1)}
    settle()

with subtest("view against branch: stat walk and sequential read"):
    make_reading_set()
    settle()
    at = sh(f"sqlite3 {DB} \"SELECT MAX(epoch) FROM checkpoints WHERE branch='{B}'\"").strip()
    walk = {"branch": stat_walk(B), "view": stat_walk(f"{VIEW}/@{at}")}
    for name, path in read_paths(at, "big/seq").items():
        walk.setdefault(name, {})["seq_read_MBps"] = seq_read(name, path)
    rates, walk["concurrent_total_MBps"] = concurrent_reads({n: read_paths(at, f"big/r-{n}")[n] for n in ["branch", "mergerfs", "view", "smb"]})
    for name, rate in rates.items():
        walk[name]["concurrent_read_MBps"] = rate
    R["view"] = walk

with subtest("Previous Versions over SMB"):
    sh("echo 3 > /proc/sys/vm/drop_caches")
    before = view_mounts()
    cold, out = timed(f"{SMB} -c 'allinfo big/seq'")
    warm, _ = timed(f"{SMB} -c 'allinfo big/seq'")
    names = re.findall(r"@GMT-[0-9.-]+", out)
    pv = {"versions": len(names), "list_cold_s": round(cold, 3), "list_warm_s": round(warm, 3), "mounts_listing": view_mounts() - before}
    if names:
        code, got = machine.execute(f"{SMB} -c 'get {names[0]}/big/seq /tmp/pv' 2>&1 && cmp /tmp/pv {B}/big/seq")
        pv["get_ok"] = code == 0
        pv["mounts_after_get"] = view_mounts() - before
        if code:
            pv["get"] = got.strip()[-300:]
        sh("rm -f /tmp/pv")
    else:
        pv["allinfo"] = out.strip()[-500:]
    R["previous_versions"] = pv

with subtest("SnapRAID diff after reclaim"):
    dropped = churn("sr")
    code, out = machine.execute("snapraid -c /etc/snapraid.conf sync 2>&1")
    machine.log(out)
    sr = {"sync_ok": code == 0, "reclaimable_mb": dropped}
    gc = reclaim()
    sr["reclaim"] = gc.strip().splitlines()[-1] if gc.strip() else ""
    code, diff = machine.execute("snapraid -c /etc/snapraid.conf diff 2>&1")
    machine.log(diff)
    sr["diff"] = {k: int(n) for n, k in re.findall(r"^\s*(\d+) (equal|added|removed|updated|moved|copied|restored)\s*$", diff, re.M)}
    code, check = machine.execute("snapraid -c /etc/snapraid.conf check -a 2>&1")
    machine.log(check)
    sr["check_ok"] = code == 0
    sr["check"] = check.strip().splitlines()[-1] if check.strip() else ""
    R["snapraid"] = sr
    assert sr["sync_ok"] and sr["check_ok"], out + diff + check
    assert all(sr["diff"].get(k, 1) == 0 for k in ["removed", "updated", "moved"]), diff

with subtest("an idle pass reads nothing from the device"):
    settle()
    sh(f"sleep 8 && {AT} pass && sleep 8")
    before = dev_stat()
    elapsed, _ = timed(f"{AT} pass")
    after = dev_stat()
    R["idle_pass"] = {"seconds": round(elapsed, 3), "sectors_read": after[0] - before[0], "sectors_written": after[1] - before[1]}

with subtest("a pass after a 256 MiB write reads only log summaries"):
    sh(f"dd if=/dev/urandom of={B}/big/burst bs=1M count=256 conv=fsync status=none && sync && sleep 6")
    sh("echo 3 > /proc/sys/vm/drop_caches")
    before = dev_stat()
    elapsed, _ = timed(f"{AT} pass")
    after = dev_stat()
    R["burst_pass"] = {"written_mb": 256, "seconds": round(elapsed, 2), "read_mb": round((after[0] - before[0]) * 512 / MB, 2)}
    assert R["burst_pass"]["read_mb"] < 32, R["burst_pass"]

with subtest("the device stays quiet with every service running"):
    R["quiet"] = quiet_window("low")

R["levels"] = {}
for level in [0.5, 0.9, 0.95, 0.97]:
    with subtest(f"fill {level:.0%}"):
        tag = f"l{int(level * 100)}"
        row = {}
        set_fill(level, reclaim)
        row["stock"] = workloads()
        reclaim()
        set_fill(level, reclaim)

        start_loop(f"passloop-{tag}")
        row["pass"] = workloads()
        stop_loop(f"passloop-{tag}")
        reclaim()

        set_fill(max(0.3, level - 0.15), reclaim)
        dropped = churn(tag)
        set_fill(level, reclaim)
        dry = sh(f"{PREP} reclaim --dry-run")
        machine.log(dry)
        diag(f"churn/{tag}")
        began = time.time()
        before = dev_stat()
        start(f"reclaim-{tag}", f"{AT} reclaim")
        row["reclaim"] = workloads()
        finished(f"reclaim-{tag}")
        took = time.time() - began
        out = sh(f"journalctl -u reclaim-{tag} -o cat")
        machine.log(out)
        m = re.search(r"(\d+) segments cleaned, \S+ freed \((\d+) blocks\)", out)
        if m:
            segs, freed = int(m.group(1)), int(m.group(2))
            row["reclaim"]["gc"] = {
                "segments": segs,
                "freed_mb": round(freed * 4096 / MB, 1),
                "copied_per_freed": round((segs * SEG_BLOCKS - freed) / max(freed, 1), 2),
                "seconds": round(took, 1),
                "dropped_mb": dropped,
            }
        else:
            row["reclaim"]["gc"] = {"output": out.strip()[-300:]}
        stop(f"reclaim-{tag}")

        if level >= 0.95:
            reclaim()
            set_fill(max(0.3, level - 0.15), reclaim)
            dropped = churn(f"{tag}e")
            set_fill(level, reclaim)
            avail = avail_mb()
            want = avail + dropped // 2
            start_loop(f"passloop-{tag}e", auto=True)
            freed, waited = wait_for_avail(want, 300)
            ok, out = flood(want)
            stop_loop(f"passloop-{tag}e")
            row["enospc"] = {
                "wrote_mb": want,
                "avail_mb": avail,
                "reclaimable_mb": dropped,
                "auto_reclaimed": freed,
                "auto_reclaim_s": waited,
                "ok": ok,
                "dd": out,
            }
            reclaim()
        if level == 0.97:
            set_fill(level, reclaim)
            row["quiet"] = quiet_window(tag)
        R["levels"][f"{int(level * 100)}%"] = row
        machine.log("NAS-EVAL-LEVEL " + json.dumps({tag: row}))

with subtest("reclaim under GBs of churn in a historyless tmp/"):
    R["tmp_churn"] = {
        "burst": tmp_churn("burst", 48, 64, 0, 2),
        "gigabit": tmp_churn("gigabit", 48, 64, 110, 2),
        "gigabit_pass_30s": tmp_churn("gigabit30", 48, 64, 110, 30),
    }
    machine.log("NAS-EVAL-CHURN " + json.dumps(R["tmp_churn"]))
    sh(f"rm -rf {B}/tmp")
    reclaim()

with subtest("CLI timings at the highest fill"):
    cli = {}
    for name, cmd in [
        ("log", f"{AT} log {B}/many/f1"),
        ("top", f"{AT} top"),
        ("top_ratio", f"{AT} top --by ratio"),
        ("keep_dry_run", f"{AT} keep {B} --quantum 3600 --dry-run"),
        ("keep_target_ratio", f"{AT} keep {B} --target-ratio 0.5 --dry-run"),
        ("keep_target", f"{AT} keep {B} --target 100M --dry-run"),
    ]:
        elapsed, _ = timed(cmd)
        cli[name] = round(elapsed, 3)
    R["cli"] = cli

with subtest("no kernel complaints"):
    sh(f"rm -rf {B}/.cache/bulk {B}/churn {B}/tmp")
    reclaim()
    sh(f"touch {B}/still-writable && sync")
    dmesg = dmesg_warnings()
    report()
    assert R["dmesg_warnings"] == 0, dmesg
