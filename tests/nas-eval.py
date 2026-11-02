import json
import re
import time

B = "/mnt/disks/disk1"
DB = "/var/lib/nas-checkpoints/index.db"
VIEW = "/srv/nas-at"
AT = "/run/current-system/sw/bin/nas-at"
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
    size, used, _ = df()
    return used / size


def settle():
    sh(f"sync && sleep 6 && {AT} pass")


def reclaim():
    out = sh(f"sync && sleep 6 && {AT} pass && {AT} reclaim")
    machine.log(out)
    return out


bulk = [0]


def set_fill(target):
    size, used, _ = df()
    goal = int(target * size)
    if used > goal:
        files = sh(f"ls -t {B}/.cache/bulk 2>/dev/null || true").split()
        need = used - goal
        doomed = files[: max(1, need // (64 * MB) + 1)]
        sh(f"cd {B}/.cache/bulk && rm -f {' '.join(doomed)}")
        reclaim()
        size, used, _ = df()
    sh(f"mkdir -p {B}/.cache/bulk")
    while used + 64 * MB <= goal:
        bulk[0] += 1
        code, _ = machine.execute(f"dd if=/dev/zero of={B}/.cache/bulk/b{bulk[0]} bs=1M count=64 conv=fsync status=none")
        if code != 0:
            break
        size, used, _ = df()
    return used / size


def fio_json(out):
    return json.loads(out[out.index("{"):])


def pct(d, key):
    return (d.get("percentile") or {}).get(key, 0) / 1e6


def fio_seq(mb):
    out = sh(f"mkdir -p {B}/.cache/fio && fio --name=seq --directory={B}/.cache/fio --rw=write --bs=1M --size={mb}M --ioengine=psync --end_fsync=1 --output-format=json")
    w = fio_json(out)["jobs"][0]["write"]
    return {"mb": mb, "MBps": round(w["bw"] / 1024, 1), "clat_p99_ms": round(pct(w["clat_ns"], "99.000000"), 2)}


def fio_rand(mb):
    out = sh(f"mkdir -p {B}/.cache/fio && fio --name=rand --filename={B}/.cache/fio/r --rw=randwrite --bs=4k --size={mb}M --fsync=32 --runtime=15 --time_based --ioengine=psync --output-format=json")
    job = fio_json(out)["jobs"][0]
    w, s = job["write"], job.get("sync", {}).get("lat_ns", {})
    return {
        "mb": mb,
        "iops": round(w["iops"]),
        "clat_p99_ms": round(pct(w["clat_ns"], "99.000000"), 2),
        "fsync_p50_ms": round(pct(s, "50.000000"), 2),
        "fsync_p99_ms": round(pct(s, "99.000000"), 2),
        "fsync_p999_ms": round(pct(s, "99.900000"), 2),
        "fsync_max_ms": round(s.get("max", 0) / 1e6, 2),
    }


def workloads():
    _, _, avail = df()
    seq_mb = max(16, min(256, int(avail * 0.4) // MB))
    rand_mb = max(8, min(64, int(avail * 0.15) // MB))
    result = {"fill": round(fill(), 3), "seq": fio_seq(seq_mb), "rand": fio_rand(rand_mb)}
    sh(f"rm -rf {B}/.cache/fio")
    return result


def start(unit, cmd):
    sh(f"systemd-run --unit={unit} -p RemainAfterExit=yes {ENV} {cmd}")


def stop(unit):
    sh(f"systemctl stop {unit}; systemctl reset-failed {unit} 2>/dev/null || true")


def finished(unit):
    machine.wait_until_succeeds(f"systemctl show -p SubState --value {unit} | grep -qxE 'exited|failed'", timeout=1800)


def start_loop(unit):
    start(unit, f"/bin/sh -c 'while [ ! -e /run/{unit}.stop ]; do {AT} pass; sleep 2; done'")


def stop_loop(unit):
    sh(f"touch /run/{unit}.stop")
    finished(unit)
    stop(unit)


def churn(tag, versions=4, mb=48):
    path = f"churn/{tag}/c"
    for _ in range(versions):
        sh(f"mkdir -p {B}/churn/{tag} && dd if=/dev/urandom of={B}/{path} bs=1M count={mb} conv=fsync status=none")
        settle()
    out = sh(f"{AT} keep {B}/churn/{tag} --none")
    machine.log(out)
    return (versions - 1) * mb


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
        dry = sh(f"{AT} reclaim --dry-run")
        machine.log(dry)
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
            start_loop(f"passloop-{tag}e")
            code, out = machine.execute(f"dd if=/dev/zero of={B}/.cache/flood bs=1M count={flood} conv=fsync status=none 2>&1")
            stop_loop(f"passloop-{tag}e")
            row["enospc"] = {"wrote_mb": flood, "avail_mb": avail // MB, "reclaimable_mb": dropped, "ok": code == 0, "dd": out.strip()[-200:]}
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
    sh(f"touch {B}/still-writable && sync")
    dmesg = sh("dmesg")
    R["dmesg_warnings"] = len(re.findall(r"WARNING|NILFS error|read-only|Oops", dmesg))
    assert R["dmesg_warnings"] == 0, dmesg

machine.log("NAS-EVAL " + json.dumps(R))
print("NAS-EVAL " + json.dumps(R))
