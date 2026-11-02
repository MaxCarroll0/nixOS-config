import json
import re
import time

B = "/mnt/disks/disk1"
DB = "/var/lib/nas-checkpoints/index.db"
VIEW = "/srv/nas-at"
AT = "/run/current-system/sw/bin/nas-at"
PREP = f"NAS_RECLAIM_FREE=0 {AT}"
ENV = "--setenv=PATH=/run/current-system/sw/bin"
SEG_BLOCKS = 2048
MB = 1 << 20
R = {}


def sh(cmd):
    return machine.succeed(cmd)


def timed(cmd):
    start = time.time()
    out = sh(cmd)
    return time.time() - start, out


def df():
    size, used, avail = map(int, sh(f"df -B1 --output=size,used,avail {B} | tail -1").split())
    return size, used, avail


def fill():
    _, used, avail = df()
    return used / (used + avail)


def settle():
    sh(f"sync && sleep 6 && {PREP} pass")


def reclaim():
    out = sh(f"sync && sleep 6 && {PREP} pass && {PREP} reclaim")
    machine.log(out)
    return out


bulk = [0]


def set_fill(target):
    for _ in range(3):
        files = sh(f"ls -t {B}/.cache/bulk 2>/dev/null || true").split()
        _, used, avail = df()
        excess = used - target * (used + avail)
        if excess <= 0 or not files:
            break
        doomed = files[: max(1, int(excess // (64 * MB)) + 1)]
        sh(f"cd {B}/.cache/bulk && rm -f {' '.join(doomed)}")
        reclaim()
    sh(f"mkdir -p {B}/.cache/bulk")
    while True:
        _, used, avail = df()
        if used + 64 * MB > target * (used + avail):
            break
        bulk[0] += 1
        code, _ = machine.execute(f"dd if=/dev/zero of={B}/.cache/bulk/b{bulk[0]} bs=1M count=64 conv=fsync status=none")
        if code != 0:
            break
    return fill()


def fio_json(out):
    if "{" not in out:
        return {"jobs": [{"error": out.strip()[-200:] or "no output", "write": {"bw": 0, "iops": 0, "clat_ns": {}}}]}
    return json.loads(out[out.index("{"):])


def pct(d, key):
    return (d.get("percentile") or {}).get(key, 0) / 1e6


def fio(args):
    code, out = machine.execute(f"mkdir -p {B}/.cache/fio && fio {args} --ioengine=psync --output-format=json 2>/dev/null")
    job = fio_json(out)["jobs"][0]
    error = job.get("error") or code
    return job, ({"error": error} if error else {})


def fio_seq(mb):
    job, err = fio(f"--name=seq --directory={B}/.cache/fio --rw=write --bs=1M --size={mb}M --end_fsync=1")
    w = job["write"]
    return {"mb": mb, "MBps": round(w["bw"] / 1024, 1), "clat_p99_ms": round(pct(w["clat_ns"], "99.000000"), 2), **err}


def fio_rand(mb):
    job, err = fio(f"--name=rand --filename={B}/.cache/fio/r --rw=randwrite --bs=4k --size={mb}M --io_size={2 * mb}M --fsync=32")
    w, s = job["write"], job.get("sync", {}).get("lat_ns", {})
    return {
        "mb": mb,
        "iops": round(w["iops"]),
        "clat_p99_ms": round(pct(w["clat_ns"], "99.000000"), 2),
        "fsync_p50_ms": round(pct(s, "50.000000"), 2),
        "fsync_p99_ms": round(pct(s, "99.000000"), 2),
        "fsync_p999_ms": round(pct(s, "99.900000"), 2),
        "fsync_max_ms": round(s.get("max", 0) / 1e6, 2),
        **err,
    }


def workloads():
    _, _, avail = df()
    seq_mb = max(8, min(256, int(avail * 0.3) // MB))
    rand_mb = max(4, min(64, int(avail * 0.1) // MB))
    result = {"fill": round(fill(), 3), "seq": fio_seq(seq_mb), "rand": fio_rand(rand_mb)}
    sh(f"rm -rf {B}/.cache/fio")
    return result


def start(unit, cmd, auto=False):
    env = ENV if auto else f"{ENV} --setenv=NAS_RECLAIM_FREE=0"
    sh(f"systemd-run --unit={unit} -p RemainAfterExit=yes {env} {cmd}")


def stop(unit):
    sh(f"systemctl stop {unit}; systemctl reset-failed {unit} 2>/dev/null || true")


def finished(unit):
    machine.wait_until_succeeds(f"systemctl show -p SubState --value {unit} | grep -qxE 'exited|failed'", timeout=1800)


def start_loop(unit, auto=False):
    start(unit, f"/bin/sh -c 'while [ ! -e /run/{unit}.stop ]; do {AT} pass; sleep 2; done'", auto)


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
    machine.log(sh("lscp -a /dev/mapper/slow | tail -6; lssu /dev/mapper/slow | awk '$4 ~ /d/' | wc -l; lssu /dev/mapper/slow | tail -8"))


def dev_stat():
    dm = sh("basename $(readlink -f /dev/mapper/slow)").strip()
    fields = sh(f"cat /sys/block/{dm}/stat").split()
    return int(fields[2]), int(fields[6])


machine.wait_for_unit("multi-user.target")
sh("dmesg -C")
sh("head -c 32 /dev/urandom > /etc/k && cryptsetup luksFormat -q --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --key-file /etc/k /dev/vdb")
sh("cryptsetup open --key-file /etc/k /dev/vdb crypt")
sh("dmsetup create slow --table \"0 $(blockdev --getsz /dev/mapper/crypt) delay /dev/mapper/crypt 0 4\"")
sh(f"mkfs.nilfs2 -f -B {SEG_BLOCKS} /dev/mapper/slow")
sh(f"mkdir -p {B} && mount -t nilfs2 -o nogc,noatime /dev/mapper/slow {B}")
sh("systemctl start nas-history-watch-disk1")
machine.wait_until_succeeds("test -e /var/lib/nas-checkpoints/events/disk1.jsonl")
sh(f"{AT} pass")
sh("systemctl start nas-at-view")
machine.wait_until_succeeds(f"mountpoint -q {VIEW}")

with subtest("2000 snapshots in the cpfile"):
    elapsed, _ = timed("for i in $(seq 2000); do mkcp -s /dev/mapper/slow; done")
    R["snapshots"] = {"n": int(sh("lscp -s /dev/mapper/slow | tail -n +2 | wc -l")), "seconds": round(elapsed, 1)}
    settle()

with subtest("view against branch: stat walk and sequential read"):
    sh(f"mkdir -p {B}/many && cd {B}/many && for i in $(seq 2000); do head -c 1024 /dev/urandom > f$i; done")
    sh(f"mkdir -p {B}/big && dd if=/dev/urandom of={B}/big/seq bs=1M count=256 conv=fsync status=none")
    settle()
    at = sh(f"sqlite3 {DB} \"SELECT MAX(epoch) FROM checkpoints WHERE branch='{B}'\"").strip()
    walk = {}
    for name, root in [("branch", B), ("view", f"{VIEW}/@{at}")]:
        sh("sync && echo 3 > /proc/sys/vm/drop_caches")
        cold, _ = timed(f"find {root}/many -type f -exec stat -c %s {{}} + > /dev/null")
        warm, _ = timed(f"find {root}/many -type f -exec stat -c %s {{}} + > /dev/null")
        sh("sync && echo 3 > /proc/sys/vm/drop_caches")
        read, _ = timed(f"cat {root}/big/seq > /dev/null")
        walk[name] = {"stat_cold_ms_per_file": round(cold * 1000 / 2000, 3), "stat_warm_ms_per_file": round(warm * 1000 / 2000, 3), "seq_read_MBps": round(256 / read, 1)}
    R["view"] = walk

with subtest("an idle pass reads nothing from the device"):
    settle()
    sh(f"sleep 8 && {AT} pass && sleep 8")
    before = dev_stat()
    elapsed, _ = timed(f"{AT} pass")
    after = dev_stat()
    R["idle_pass"] = {"seconds": round(elapsed, 3), "sectors_read": after[0] - before[0], "sectors_written": after[1] - before[1]}

R["levels"] = {}
for level in [0.5, 0.9, 0.95, 0.97]:
    with subtest(f"fill {level:.0%}"):
        tag = f"l{int(level * 100)}"
        row = {}
        set_fill(level)
        row["stock"] = workloads()
        reclaim()
        set_fill(level)

        start_loop(f"passloop-{tag}")
        row["pass"] = workloads()
        stop_loop(f"passloop-{tag}")
        reclaim()

        set_fill(max(0.3, level - 0.15))
        dropped = churn(tag)
        set_fill(level)
        dry = sh(f"{PREP} reclaim --dry-run")
        machine.log(dry)
        diag(f"churn/{tag}")
        began = time.time()
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
            set_fill(max(0.3, level - 0.15))
            dropped = churn(f"{tag}e")
            set_fill(level)
            _, _, avail = df()
            flood = avail // MB + dropped // 2
            start_loop(f"passloop-{tag}e", auto=True)
            began = time.time()
            freed, _ = machine.execute(
                f"timeout 300 sh -c 'until [ $(df -B1M --output=avail {B} | tail -1) -ge {flood} ]; do sleep 1; done'"
            )
            waited = time.time() - began
            code, out = machine.execute(f"dd if=/dev/zero of={B}/.cache/flood bs=1M count={flood} conv=fsync status=none 2>&1")
            stop_loop(f"passloop-{tag}e")
            row["enospc"] = {
                "wrote_mb": flood,
                "avail_mb": avail // MB,
                "reclaimable_mb": dropped,
                "auto_reclaimed": freed == 0,
                "auto_reclaim_s": round(waited, 1),
                "ok": code == 0,
                "dd": out.strip()[-200:],
            }
            sh(f"rm -f {B}/.cache/flood")
            reclaim()
        R["levels"][f"{int(level * 100)}%"] = row
        machine.log("NAS-EVAL-LEVEL " + json.dumps({tag: row}))

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
    sh(f"rm -rf {B}/.cache/bulk {B}/churn")
    reclaim()
    sh(f"touch {B}/still-writable && sync")
    dmesg = sh("dmesg")
    R["dmesg_warnings"] = len(re.findall(r"WARNING|NILFS error|read-only|Oops", dmesg))
    assert R["dmesg_warnings"] == 0, dmesg

machine.log("NAS-EVAL " + json.dumps(R))
print("NAS-EVAL " + json.dumps(R))
