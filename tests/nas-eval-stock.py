CONF = "/etc/nilfs_cleanerd.conf"


def cleanerd_start():
    sh(f"nilfs_cleanerd -c {CONF} {DEV} {B}")
    machine.wait_until_succeeds(f"nilfs-clean -l {DEV}")


def sweep():
    sh(f"sync && sleep 6 && nilfs-clean -p 0 {DEV}")
    last = avail_mb()
    for _ in range(60):
        sh("sleep 10")
        now = avail_mb()
        if now - last < 16:
            break
        last = now
    machine.log(sh(f"nilfs-clean -l {DEV}; df -h {B}"))


def churn(tag, versions=4, mb=48):
    for _ in range(versions):
        sh(f"mkdir -p {B}/churn/{tag} && dd if=/dev/urandom of={B}/churn/{tag}/c bs=1M count={mb} conv=fsync status=none && sync")
    sh("sleep 6")
    return (versions - 1) * mb


def age(hours=2):
    sh(f"nilfs-clean -q {DEV}")
    machine.wait_until_fails("pgrep -x nilfs_cleanerd")
    sh(f"date -s '+{hours} hours' > /dev/null")
    cleanerd_start()


def gc_watch(dropped, timeout):
    avail = avail_mb()
    before = dev_stat()
    reached, waited = wait_for_avail(avail + int(dropped * 0.9), timeout)
    after = dev_stat()
    freed = avail_mb() - avail
    written = round((after[1] - before[1]) * 512 / MB, 1)
    return {
        "dropped_mb": dropped,
        "freed_mb": freed,
        "reached_90pct": reached,
        "seconds": waited,
        "read_mb": round((after[0] - before[0]) * 512 / MB, 1),
        "written_mb": written,
        "written_per_freed": round(written / freed, 2) if freed > 0 else None,
    }


def tmp_churn(tag, count, mb, rate):
    sh(f"rm -rf {B}/tmp")
    sweep()
    set_fill(0.75, sweep)
    avail = avail_mb()
    return {"avail_before_mb": avail, **run_tmp_churn(tag, count, mb, rate)}


cleanerd_start()

with subtest("branch: stat walk and sequential read"):
    make_reading_set()
    sh("sync")
    walk = {"branch": stat_walk(B)}
    for name, path in [("branch", f"{B}/big/seq"), ("mergerfs", f"{POOL}/big/seq")]:
        walk.setdefault(name, {})["seq_read_MBps"] = seq_read(name, path)
    rates, walk["concurrent_total_MBps"] = concurrent_reads({"branch": f"{B}/big/r-branch", "mergerfs": f"{POOL}/big/r-mergerfs"})
    for name, rate in rates.items():
        walk[name]["concurrent_read_MBps"] = rate
    R["view"] = walk

with subtest("the device with cleanerd idle at low fill"):
    sh("sync && sleep 10")
    R["quiet"] = quiet(180)

R["levels"] = {}
for level in [0.5, 0.9, 0.95, 0.97]:
    with subtest(f"fill {level:.0%}"):
        tag = f"l{int(level * 100)}"
        row = {}
        set_fill(level, sweep)
        row["cleanerd"] = workloads()

        set_fill(max(0.3, level - 0.15), sweep)
        dropped = churn(tag)
        set_fill(level, sweep)
        row["fresh"] = gc_watch(dropped, 60)
        age()
        row["aged"] = gc_watch(dropped, 300)
        row["aged"]["workloads"] = workloads()
        machine.log(sh(f"nilfs-clean -l {DEV}; lssu {DEV} | awk '$4 ~ /d/' | wc -l"))

        if level >= 0.95:
            sweep()
            set_fill(max(0.3, level - 0.15), sweep)
            dropped = churn(f"{tag}e")
            set_fill(level, sweep)
            avail = avail_mb()
            want = avail + dropped // 2
            fresh_ok, fresh_out = flood(want)
            age()
            freed, waited = wait_for_avail(want, 300)
            ok, out = flood(want)
            row["enospc"] = {
                "wrote_mb": want,
                "avail_mb": avail,
                "reclaimable_mb": dropped,
                "fresh_ok": fresh_ok,
                "fresh_dd": fresh_out,
                "auto_reclaimed": freed,
                "auto_reclaim_s": waited,
                "ok": ok,
                "dd": out,
            }
            sweep()
        if level == 0.97:
            set_fill(level, sweep)
            sh("sync && sleep 10")
            row["quiet"] = quiet(180)
        R["levels"][f"{int(level * 100)}%"] = row
        machine.log("NAS-EVAL-LEVEL " + json.dumps({tag: row}))

with subtest("cleanerd under GBs of churn in tmp/"):
    R["tmp_churn"] = {
        "burst": tmp_churn("burst", 48, 64, 0),
        "gigabit": tmp_churn("gigabit", 48, 64, 110),
    }
    machine.log("NAS-EVAL-CHURN " + json.dumps(R["tmp_churn"]))
    sh(f"rm -rf {B}/tmp")

with subtest("kernel log"):
    sh(f"rm -rf {B}/.cache/bulk {B}/churn {B}/tmp")
    sweep()
    sh(f"touch {B}/still-writable && sync")
    dmesg_warnings()
    machine.log(sh(f"nilfs-clean -l {DEV}; lscp {DEV} | tail -n +2 | wc -l"))
    report()
