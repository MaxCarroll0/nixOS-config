# Stage B evaluation on the pi's real LUKS-on-HDD stack, by fill level: NILFS2 history, stock NILFS2 + cleanerd, or ext4.

import json
import os
import re
import subprocess
import sys
import time

NAS_AT, TOOLS, IMG = sys.argv[1], sys.argv[2], sys.argv[3]
MODE = os.environ.get("STAGEB_MODE", "history")
GIB = int(os.environ.get("STAGEB_GIB", "40"))
SNAPSHOTS = int(os.environ.get("STAGEB_SNAPSHOTS", "10000"))
LEVELS = [float(x) for x in os.environ.get("STAGEB_LEVELS", "0.5 0.9 0.95 0.97").split()]
RUN = "/run/stageb"
STATE = "/var/lib/nas-stageb"
DB = f"{STATE}/index.db"
B = "/mnt/stageb/sb1"
POOL = "/mnt/stageb/pool"
VIEW = "/mnt/stageb/view"
DM = "stageb"
DEV = f"/dev/mapper/{DM}"
AT = f"{RUN}/nas-at"
PREP = f"NAS_RECLAIM_FREE=0 {AT}"
SMB = "smbclient //127.0.0.1/sb1 -p 4445 -N"
PROD_SUSPEND = "/run/nas-promote-suspended"
RESULTS = os.environ.get("STAGEB_RESULTS", "/home/max/stageb/results.json")
FILES = 10000
SEG_BLOCKS = 2048
MB = 1 << 20
ENV = {**os.environ, "PATH": f"{TOOLS}:/run/wrappers/bin:/run/current-system/sw/bin:/run/current-system/sw/sbin"}
R = {"mode": MODE, "started": time.strftime("%Y-%m-%d %H:%M:%S"), "gib": GIB}
marks = []


def log(msg):
    print(f"{time.strftime('%H:%M:%S')} {msg}", flush=True)


def execute(cmd):
    p = subprocess.run(["bash", "-c", cmd], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=ENV)
    return p.returncode, p.stdout


def sh(cmd):
    code, out = execute(cmd)
    if code:
        raise RuntimeError(f"{cmd}: exit {code}\n{out[-3000:]}")
    return out


def wait_until(cmd, timeout):
    deadline = time.time() + timeout
    while execute(cmd)[0]:
        if time.time() > deadline:
            raise RuntimeError(f"timed out: {cmd}")
        time.sleep(1)


def timed(cmd):
    start = time.time()
    out = sh(cmd)
    return time.time() - start, out


def save():
    with open(RESULTS + ".tmp", "w") as f:
        json.dump(R, f, indent=1)
    os.replace(RESULTS + ".tmp", RESULTS)


def mark(what):
    marks.append([time.strftime("%H:%M:%S"), what])
    R["marks"] = marks


def df():
    size, used, avail = map(int, sh(f"df -B1 --output=size,used,avail {B} | tail -1").split())
    return size, used, avail


def fill():
    _, used, avail = df()
    return used / (used + avail)


def avail_mb():
    return df()[2] // MB


bulk = [0]


def set_fill(target, make_room):
    for _ in range(3):
        files = sh(f"ls -t {B}/.cache/bulk 2>/dev/null || true").split()
        _, used, avail = df()
        excess = used - target * (used + avail)
        if excess <= 0 or not files:
            break
        doomed = files[: max(1, int(excess // (256 * MB)) + 1)]
        sh(f"cd {B}/.cache/bulk && rm -f {' '.join(doomed)}")
        make_room()
    sh(f"mkdir -p {B}/.cache/bulk")
    while True:
        _, used, avail = df()
        if used + 256 * MB > target * (used + avail):
            break
        bulk[0] += 1
        if execute(f"dd if=/dev/zero of={B}/.cache/bulk/b{bulk[0]} bs=1M count=256 conv=fsync status=none")[0]:
            break
    return fill()


def fio_json(out):
    if "{" not in out:
        return {"jobs": [{"error": out.strip()[-200:] or "no output", "write": {"bw": 0, "iops": 0, "clat_ns": {}}}]}
    return json.loads(out[out.index("{"):])


def pct(d, key):
    return (d.get("percentile") or {}).get(key, 0) / 1e6


def fio(args):
    code, out = execute(f"mkdir -p {B}/.cache/fio && fio {args} --ioengine=psync --output-format=json 2>/dev/null")
    job = fio_json(out)["jobs"][0]
    error = job.get("error") or code
    return job, ({"error": error} if error else {})


def fio_seq(mb):
    job, err = fio(f"--name=seq --directory={B}/.cache/fio --rw=write --bs=1M --size={mb}M --end_fsync=1")
    w = job["write"]
    return {
        "mb": mb,
        "MBps": round(w["bw"] / 1024, 1),
        "clat_p50_ms": round(pct(w["clat_ns"], "50.000000"), 2),
        "clat_p99_ms": round(pct(w["clat_ns"], "99.000000"), 2),
        "clat_p999_ms": round(pct(w["clat_ns"], "99.900000"), 2),
        "clat_max_ms": round(w["clat_ns"].get("max", 0) / 1e6, 2),
        **err,
    }


def fio_rand(mb):
    job, err = fio(f"--name=rand --filename={B}/.cache/fio/r --rw=randwrite --bs=4k --size={mb}M --io_size={2 * mb}M --fsync=32 --runtime=120")
    w, s = job["write"], job.get("sync", {}).get("lat_ns", {})
    return {
        "mb": mb,
        "iops": round(w["iops"]),
        "MBps": round(w["bw"] / 1024, 1),
        "clat_p99_ms": round(pct(w["clat_ns"], "99.000000"), 2),
        "fsync_p50_ms": round(pct(s, "50.000000"), 2),
        "fsync_p99_ms": round(pct(s, "99.000000"), 2),
        "fsync_p999_ms": round(pct(s, "99.900000"), 2),
        "fsync_max_ms": round(s.get("max", 0) / 1e6, 2),
        **err,
    }


def workloads():
    _, _, avail = df()
    seq_mb = max(64, min(2048, int(avail * 0.3) // MB))
    rand_mb = max(16, min(256, int(avail * 0.1) // MB))
    before = dev_stat()
    result = {"fill": round(fill(), 3), "seq": fio_seq(seq_mb), "rand": fio_rand(rand_mb)}
    after = dev_stat()
    result["device_written_mb"] = round((after[1] - before[1]) * 512 / MB, 1)
    result["device_read_mb"] = round((after[0] - before[0]) * 512 / MB, 1)
    sh(f"rm -rf {B}/.cache/fio")
    return result


def run_unit(unit, cmd, env=""):
    sh(f"systemd-run --unit={unit} -p RemainAfterExit=yes --setenv=PATH={ENV['PATH']} {env} {cmd}")


def stop(unit):
    execute(f"systemctl stop {unit}; systemctl reset-failed {unit} 2>/dev/null")


def finished(unit):
    wait_until(f"systemctl show -p SubState --value {unit} | grep -qxE 'exited|failed'", 3600)


def dev_stat():
    dm = sh(f"basename $(readlink -f {DEV})").strip()
    fields = sh(f"cat /sys/block/{dm}/stat").split()
    return int(fields[2]), int(fields[6])


def drop_caches():
    mark("drop_caches")
    sh("sync && echo 3 > /proc/sys/vm/drop_caches")


def settle():
    sh(f"sync && sleep 11 && {PREP} pass")


def reclaim():
    out = sh(f"sync && sleep 11 && {PREP} pass && {PREP} reclaim")
    log(out.strip().splitlines()[-1] if out.strip() else "reclaim: nothing")
    return out


def start(unit, cmd, auto=False):
    run_unit(unit, cmd, "" if auto else "--setenv=NAS_RECLAIM_FREE=0")


def start_loop(unit, auto=False, every=2):
    start(unit, f"/bin/sh -c 'while [ ! -e {RUN}/{unit}.stop ]; do {AT} pass; sleep {every}; done'", auto)


def stop_loop(unit):
    sh(f"touch {RUN}/{unit}.stop")
    finished(unit)
    stop(unit)


def churn(tag, versions=4, mb=256):
    path = f"churn/{tag}/c"
    for _ in range(versions):
        sh(f"mkdir -p {B}/churn/{tag} && dd if=/dev/urandom of={B}/{path} bs=1M count={mb} conv=fsync status=none")
        settle()
    log(sh(f"{PREP} keep {B}/churn/{tag} --none").strip())
    return (versions - 1) * mb


def view_mounts():
    return int(sh(f"awk '$2 ~ \"^{RUN}/at/\"' /proc/mounts | wc -l").strip())


def read_cmd(name, path):
    if name == "smb":
        return f"{SMB} -c 'get {path} /dev/null' > /dev/null 2>&1"
    return f"cat {path} > /dev/null"


def read_paths(at, rel):
    return {"branch": f"{B}/{rel}", "mergerfs": f"{POOL}/{rel}", "view": f"{VIEW}/@{at}/{rel}", "smb": rel}


def stat_walk(root):
    drop_caches()
    cold, _ = timed(f"find {root}/many -type f -exec stat -c %s {{}} + > /dev/null")
    warm, _ = timed(f"find {root}/many -type f -exec stat -c %s {{}} + > /dev/null")
    return {"stat_cold_ms_per_file": round(cold * 1000 / FILES, 3), "stat_warm_ms_per_file": round(warm * 1000 / FILES, 3)}


def seq_read(name, path, mb):
    drop_caches()
    read, _ = timed(read_cmd(name, path))
    return round(mb / read, 1)


def concurrent_reads(paths, mb):
    drop_caches()
    jobs = " ".join(f"( s=$(date +%s.%N); {read_cmd(name, path)}; echo {name} $s $(date +%s.%N) ) &" for name, path in paths.items())
    spans = {n: (float(a), float(b)) for n, a, b in (line.split() for line in sh(f"{jobs} wait").splitlines())}
    whole = max(b for _, b in spans.values()) - min(a for a, _ in spans.values())
    return {n: round(mb / (b - a), 1) for n, (a, b) in spans.items()}, round(mb * len(spans) / whole, 1)


def quiet(seconds):
    before = dev_stat()
    time.sleep(seconds)
    after = dev_stat()
    return {"seconds": seconds, "fill": round(fill(), 3), "sectors_read": after[0] - before[0], "sectors_written": after[1] - before[1]}


def quiet_window(tag, seconds=300):
    settle()
    sh(f"sleep 11 && {AT} pass")
    start_loop(f"quiet-{tag}", auto=True, every=10)
    row = quiet(seconds)
    stop_loop(f"quiet-{tag}")
    return {"pass_every_s": 10, **row}


def gc_since(since):
    count, segs, freed = sh(
        f"sqlite3 -separator ' ' {DB} \"SELECT COUNT(*), COALESCE(SUM(segs), 0), COALESCE(SUM(freed), 0) FROM gc_runs WHERE at >= {since}\""
    ).split()
    return {"runs": int(count), "segments": int(segs), "freed_mb": round(int(freed) / MB, 1)}


def run_tmp_churn(tag, count, mb, rate):
    out = f"{RUN}/churn-{tag}.log"
    script = f"{RUN}/churn.sh"
    before = dev_stat()
    run_unit(f"stageb-churn-{tag}", f"bash {script} {count} {mb} {rate} {out}")
    finished(f"stageb-churn-{tag}")
    after = dev_stat()
    stop(f"stageb-churn-{tag}")
    rows = [line.split() for line in sh(f"cat {out}").splitlines()]
    ok = [r for r in rows if r[1] == "1"]
    took = [float(r[3]) - float(r[2]) for r in ok]
    wall = float(rows[-1][3]) - float(rows[0][2])
    return {
        "rate_MBps": rate or "unthrottled",
        "churned_mb": len(rows) * mb,
        "written_mb": len(ok) * mb,
        "failed_files": len(rows) - len(ok),
        "wall_s": round(wall, 1),
        "MBps": round(len(ok) * mb / wall, 1),
        "file_p50_s": round(sorted(took)[len(took) // 2], 2) if took else None,
        "file_max_s": round(max(took), 2) if took else None,
        "min_avail_mb": min(int(r[4]) for r in rows),
        "read_mb": round((after[0] - before[0]) * 512 / MB, 1),
        "written_device_mb": round((after[1] - before[1]) * 512 / MB, 1),
    }


def tmp_churn(tag, count, mb, rate, every):
    sh(f"rm -rf {B}/tmp")
    reclaim()
    set_fill(0.75, reclaim)
    since = time.time()
    avail = avail_mb()
    start_loop(f"passloop-{tag}", auto=True, every=every)
    row = run_tmp_churn(tag, count, mb, rate)
    stop_loop(f"passloop-{tag}")
    return {"pass_every_s": every, "avail_before_mb": avail, **row, "gc": gc_since(since)}


def flood(mb):
    code, out = execute(f"dd if=/dev/zero of={B}/.cache/flood bs=1M count={mb} conv=fsync status=none 2>&1")
    sh(f"rm -f {B}/.cache/flood")
    return code == 0, out.strip()[-200:]


def wait_for_avail(mb, timeout):
    began = time.time()
    code, _ = execute(f"timeout {timeout} sh -c 'until [ $(df -B1M --output=avail {B} | tail -1) -ge {mb} ]; do sleep 1; done'")
    return code == 0, round(time.time() - began, 1)


def processes():
    return sh("ps -eo comm,rss,time --sort=-rss | grep -E 'kcryptd|segctord|nilfs|smbd|mergerfs|python|fio' | head -20 || true")


SMB_CONF = f"""[global]
server role = standalone server
map to guest = Bad User
server min protocol = SMB2
smb ports = 4445
interfaces = lo
bind interfaces only = yes
pid directory = {RUN}/smb
lock directory = {RUN}/smb
state directory = {RUN}/smb
cache directory = {RUN}/smb
private dir = {RUN}/smb
ncalrpc dir = {RUN}/smb/ncalrpc
binddns dir = {RUN}/smb
log file = {RUN}/smb/log
load printers = no
disable spoolss = yes
[sb1]
path = {B}
guest ok = yes
read only = yes
"""
SHADOW = """vfs objects = shadow_copy2
shadow:mountpoint = {B}
shadow:snapdir = {VIEW}
shadow:format = @GMT-%Y.%m.%d-%H.%M.%S
shadow:localtime = no
shadow:sort = desc
"""

CHURN = f"""count=$1 mb=$2 rate=$3 log=$4
mkdir -p {B}/tmp
: > "$log"
for i in $(seq 0 $((count - 1))); do
  f={B}/tmp/f$((i % 4))
  rm -f "$f"
  t0=$(date +%s.%N)
  if dd if=/dev/zero of="$f" bs=1M count="$mb" conv=fsync status=none 2>/dev/null; then ok=1; else ok=0; fi
  t1=$(date +%s.%N)
  echo "$i $ok $t0 $t1 $(df -B1M --output=avail {B} | tail -1)" >> "$log"
  if [ "$ok" = 0 ]; then
    sleep 1
  elif [ "$rate" -gt 0 ]; then
    sleep "$(awk -v a="$t0" -v b="$t1" -v mb="$mb" -v r="$rate" 'BEGIN {{ p = mb / r - (b - a); print (p > 0 ? p : 0) }}')"
  fi
done
"""


def setup():
    sh(f"mkdir -p {RUN}/smb/ncalrpc {STATE}/events {B} {POOL} {VIEW} $(dirname {RESULTS})")
    with open(AT, "w") as f:
        f.write(
            "#!/bin/sh\n"
            f'exec {NAS_AT} --branch {B} --index {DB} --pool {POOL} --view {VIEW} --mount-dir {RUN}/at '
            f"--lock {RUN}/write.lock --history-lock {RUN}/history.lock --suspend {RUN}/suspended "
            f'--metrics {STATE}/nas.prom --gap-default 5 --historyless tmp --historyless .cache '
            '--reclaim-free "${NAS_RECLAIM_FREE:-0.15}" "$@"\n'
        )
    os.chmod(AT, 0o755)
    with open(f"{RUN}/churn.sh", "w") as f:
        f.write(CHURN)
    with open(f"{RUN}/smb.conf", "w") as f:
        f.write(SMB_CONF + (SHADOW.format(B=B, VIEW=VIEW) if MODE == "history" else ""))
    R["dmesg_lines_before"] = int(sh("dmesg | wc -l"))
    sh(f"test -e {PROD_SUSPEND} || {{ touch {PROD_SUSPEND} && touch {RUN}/owns-suspend; }}")
    sh(f"test ! -e {IMG} && touch {IMG} && chattr +C {IMG} && fallocate -l {GIB}G {IMG}")
    loop = sh(f"losetup -f --show --direct-io=on {IMG}").strip()
    with open(f"{RUN}/loop", "w") as f:
        f.write(loop)
    sh(f"head -c 64 /dev/urandom > {RUN}/key && chmod 600 {RUN}/key")
    sh(f"cryptsetup luksFormat -q --type luks2 --cipher aes-xts-plain64 --key-size 512 --sector-size 4096 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --key-file {RUN}/key {loop}")
    sh(f"cryptsetup open --key-file {RUN}/key {loop} {DM}")
    if MODE == "ext4":
        sh(f"mkfs.ext4 -q -E lazy_itable_init=0,lazy_journal_init=0 {DEV}")
        sh(f"mount -o noatime {DEV} {B}")
    else:
        sh(f"mkfs.nilfs2 -f -B {SEG_BLOCKS} -m 5 {DEV}")
        sh(f"mount -t nilfs2 -o nogc,noatime {DEV} {B}")
    sh(
        f"mergerfs -o cache.files=partial,category.create=eppfrd,func.mkdir=mspmfs,category.search=ff,dropcacheonclose=true,"
        f"inodecalc=hybrid-hash,moveonenospc=pfrd,fsname=stageb,allow_other,use_ino {B} {POOL}"
    )
    if MODE == "history":
        run_unit("stageb-watch", f"-p WorkingDirectory={B} fatrace -c -j -f W+D<> -t -t -o {STATE}/events/sb1.jsonl")
        wait_until(f"test -e {STATE}/events/sb1.jsonl", 60)
        sh(f"{AT} pass")
        run_unit("stageb-view", f"{AT} serve")
        wait_until(f"mountpoint -q {VIEW}", 60)
    if MODE == "nilfs":
        conf = sh("readlink -f $(command -v nilfs_cleanerd) | sed 's|/bin/nilfs_cleanerd$|/etc/nilfs_cleanerd.conf|'").strip()
        sh(f"sed -E 's/^protection_period[[:space:]].*/protection_period\t60/' {conf} > {RUN}/cleanerd.conf")
        run_unit("stageb-cleanerd", f"nilfs_cleanerd -c {RUN}/cleanerd.conf {DEV} {B}")
        wait_until(f"nilfs-clean -l {DEV}", 60)
    smbd = sh("systemctl show -p ExecStart --value samba-smbd | grep -o '/nix/store/[^ ;]*/sbin/smbd' | head -1").strip()
    run_unit("stageb-smbd", f"{smbd} --foreground --no-process-group -s {RUN}/smb.conf")
    wait_until(f"{SMB} -c 'ls' > /dev/null 2>&1", 60)


def teardown():
    for unit in ["stageb-smbd", "stageb-view", "stageb-watch", "stageb-cleanerd"]:
        stop(unit)
    execute(f"for u in $(systemctl list-units --plain --no-legend 'passloop-*' 'quiet-*' 'reclaim-*' 'stageb-churn-*' | awk '{{print $1}}'); do systemctl stop $u; systemctl reset-failed $u; done")
    execute(f"for m in $(awk '$2 ~ \"^{RUN}/at/\" {{print $2}}' /proc/mounts); do umount $m; done")
    execute(f"mountpoint -q {VIEW} && fusermount3 -u {VIEW}")
    execute(f"mountpoint -q {POOL} && umount {POOL}")
    execute(f"mountpoint -q {B} && umount {B}")
    execute(f"cryptsetup close {DM}")
    execute(f"test -s {RUN}/loop && losetup -d $(cat {RUN}/loop)")
    execute(f"rm -f {IMG}")
    execute(f"test -e {RUN}/owns-suspend && rm -f {PROD_SUSPEND}")
    execute(f"rm -rf {RUN} {STATE} /mnt/stageb")


def main():
    setup()
    mark("setup done")
    save()

    elapsed, _ = timed(f"for i in $(seq {SNAPSHOTS}); do mkcp -s {DEV}; done")
    R["snapshots"] = {"n": int(sh(f"lscp -s {DEV} | tail -n +2 | wc -l")), "seconds": round(elapsed, 1)}
    settle()
    mark("snapshots done")
    save()

    sh(f"mkdir -p {B}/many && cd {B}/many && for i in $(seq {FILES}); do head -c 1024 /dev/urandom > f$i; done")
    sh(f"mkdir -p {B}/big && dd if=/dev/urandom of={B}/big/seq bs=1M count=1024 conv=fsync status=none")
    sh(f"for n in branch mergerfs view smb; do dd if=/dev/urandom of={B}/big/r-$n bs=1M count=512 conv=fsync status=none; done")
    settle()
    at = sh(f"sqlite3 {DB} \"SELECT MAX(epoch) FROM checkpoints WHERE branch='{B}'\"").strip()
    walk = {"branch": stat_walk(B), "mergerfs": stat_walk(POOL), "view": stat_walk(f"{VIEW}/@{at}")}
    for name, path in read_paths(at, "big/seq").items():
        walk.setdefault(name, {})["seq_read_MBps"] = seq_read(name, path, 1024)
    rates, walk["concurrent_total_MBps"] = concurrent_reads({n: read_paths(at, f"big/r-{n}")[n] for n in ["branch", "mergerfs", "view", "smb"]}, 512)
    for name, rate in rates.items():
        walk[name]["concurrent_read_MBps"] = rate
    walk["view_mounts"] = view_mounts()
    R["view"] = walk
    mark("view done")
    save()

    settle()
    sh(f"sleep 11 && {AT} pass && sleep 11")
    before = dev_stat()
    elapsed, _ = timed(f"{AT} pass")
    after = dev_stat()
    R["idle_pass"] = {"seconds": round(elapsed, 3), "sectors_read": after[0] - before[0], "sectors_written": after[1] - before[1]}
    sh(f"dd if=/dev/urandom of={B}/big/burst bs=1M count=1024 conv=fsync status=none && sync && sleep 11")
    drop_caches()
    before = dev_stat()
    elapsed, _ = timed(f"{AT} pass")
    after = dev_stat()
    R["burst_pass"] = {"written_mb": 1024, "seconds": round(elapsed, 2), "read_mb": round((after[0] - before[0]) * 512 / MB, 2)}
    R["quiet"] = quiet_window("low")
    mark("pass checks done")
    save()

    R["levels"] = {}
    for level in LEVELS:
        tag = f"l{int(level * 100)}"
        log(f"level {tag}")
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
        log(dry.strip())
        m = re.search(r"would free \S+ \((\d+) blocks\)", dry)
        began = time.time()
        start(f"reclaim-{tag}", f"{AT} reclaim")
        row["reclaim"] = workloads()
        row["reclaim"]["processes"] = processes()
        finished(f"reclaim-{tag}")
        took = time.time() - began
        out = sh(f"journalctl -u reclaim-{tag} -o cat")
        log(out.strip())
        g = re.search(r"(\d+) segments cleaned, \S+ freed \((\d+) blocks\)", out)
        if g:
            segs, freed = int(g.group(1)), int(g.group(2))
            row["reclaim"]["gc"] = {
                "segments": segs,
                "freed_mb": round(freed * 4096 / MB, 1),
                "dry_run_blocks": int(m.group(1)) if m else None,
                "freed_blocks": freed,
                "copied_per_freed": round((segs * SEG_BLOCKS - freed) / max(freed, 1), 2),
                "seconds": round(took, 1),
                "dropped_mb": dropped,
            }
        else:
            row["reclaim"]["gc"] = {"output": out.strip()[-300:], "dry_run": dry.strip()[-300:]}
        stop(f"reclaim-{tag}")

        if level >= 0.95:
            reclaim()
            set_fill(max(0.3, level - 0.15), reclaim)
            dropped = churn(f"{tag}e")
            set_fill(level, reclaim)
            avail = avail_mb()
            want = avail + dropped // 2
            start_loop(f"passloop-{tag}e", auto=True)
            freed, waited = wait_for_avail(want, 600)
            ok, out = flood(want)
            stop_loop(f"passloop-{tag}e")
            row["enospc"] = {"wrote_mb": want, "avail_mb": avail, "reclaimable_mb": dropped, "auto_reclaimed": freed, "auto_reclaim_s": waited, "ok": ok, "dd": out}
            reclaim()
        if level == LEVELS[-1]:
            set_fill(level, reclaim)
            row["quiet"] = quiet_window(tag)
        R["levels"][f"{int(level * 100)}%"] = row
        mark(f"level {tag} done")
        save()

    R["tmp_churn"] = {
        "burst": tmp_churn("burst", 24, 256, 0, 2),
        "gigabit": tmp_churn("gigabit", 24, 256, 110, 2),
        "gigabit_pass_30s": tmp_churn("gigabit30", 24, 256, 110, 30),
    }
    sh(f"rm -rf {B}/tmp")
    reclaim()
    mark("tmp churn done")
    save()

    cli = {}
    for name, cmd in [
        ("log", f"{AT} log {B}/many/f1"),
        ("top", f"{AT} top"),
        ("top_ratio", f"{AT} top --by ratio"),
        ("keep_dry_run", f"{AT} keep {B} --quantum 3600 --dry-run"),
        ("keep_target_ratio", f"{AT} keep {B} --target-ratio 0.5 --dry-run"),
        ("keep_target", f"{AT} keep {B} --target 1G --dry-run"),
    ]:
        elapsed, _ = timed(cmd)
        cli[name] = round(elapsed, 3)
    R["cli"] = cli
    R["db_bytes"] = os.path.getsize(DB)

    sh(f"rm -rf {B}/.cache/bulk {B}/churn {B}/tmp")
    reclaim()
    sh(f"touch {B}/still-writable && sync")


def sweep():
    if MODE == "ext4":
        sh("sync")
        return
    sh(f"sync && sleep 11 && nilfs-clean -p 0 {DEV}")
    last = avail_mb()
    for _ in range(90):
        time.sleep(10)
        now = avail_mb()
        if now - last < 16:
            break
        last = now


def plain_churn(tag, versions=4, mb=256):
    for _ in range(versions):
        sh(f"mkdir -p {B}/churn/{tag} && dd if=/dev/urandom of={B}/churn/{tag}/c bs=1M count={mb} conv=fsync status=none && sync")
    time.sleep(11)
    return (versions - 1) * mb


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


def baseline_main():
    setup()
    mark("setup done")
    save()

    sh(f"mkdir -p {B}/many && cd {B}/many && for i in $(seq {FILES}); do head -c 1024 /dev/urandom > f$i; done")
    sh(f"mkdir -p {B}/big && dd if=/dev/urandom of={B}/big/seq bs=1M count=1024 conv=fsync status=none")
    sh(f"for n in branch mergerfs smb; do dd if=/dev/urandom of={B}/big/r-$n bs=1M count=512 conv=fsync status=none; done")
    sh("sync && sleep 11")
    walk = {"branch": stat_walk(B), "mergerfs": stat_walk(POOL)}
    for name, path in [("branch", f"{B}/big/seq"), ("mergerfs", f"{POOL}/big/seq"), ("smb", "big/seq")]:
        walk.setdefault(name, {})["seq_read_MBps"] = seq_read(name, path, 1024)
    rates, walk["concurrent_total_MBps"] = concurrent_reads(
        {"branch": f"{B}/big/r-branch", "mergerfs": f"{POOL}/big/r-mergerfs", "smb": "big/r-smb"}, 512)
    for name, rate in rates.items():
        walk[name]["concurrent_read_MBps"] = rate
    R["view"] = walk
    mark("reads done")
    save()

    sh("sync && sleep 11")
    R["quiet"] = quiet(300)
    mark("quiet done")
    save()

    R["levels"] = {}
    for level in LEVELS:
        tag = f"l{int(level * 100)}"
        log(f"level {tag}")
        row = {}
        set_fill(level, sweep)
        row["stock"] = workloads()
        sweep()
        if MODE == "nilfs":
            set_fill(max(0.3, level - 0.15), sweep)
            dropped = plain_churn(tag)
            set_fill(level, sweep)
            began = time.time()
            row["gc_active"] = workloads()
            row["gc_active"]["processes"] = processes()
            row["gc"] = gc_watch(dropped, 600)
            row["gc"]["since_churn_s"] = round(time.time() - began, 1)
            sweep()
        if level >= 0.95:
            set_fill(max(0.3, level - 0.15), sweep)
            dropped = plain_churn(f"{tag}e")
            set_fill(level, sweep)
            avail = avail_mb()
            want = avail + dropped // 2 if MODE == "nilfs" else avail - 256
            if MODE == "nilfs":
                freed, waited = wait_for_avail(want, 600)
            else:
                freed, waited = True, 0
            ok, out = flood(want)
            row["enospc"] = {"wrote_mb": want, "avail_mb": avail, "reclaimable_mb": dropped, "auto_reclaimed": freed, "auto_reclaim_s": waited, "ok": ok, "dd": out}
            sweep()
        if level == LEVELS[-1]:
            set_fill(level, sweep)
            sh("sync && sleep 11")
            row["quiet"] = quiet(300)
        R["levels"][f"{int(level * 100)}%"] = row
        mark(f"level {tag} done")
        save()

    R["tmp_churn"] = {}
    for tag, rate in [("burst", 0), ("gigabit", 110)]:
        sh(f"rm -rf {B}/tmp")
        sweep()
        set_fill(0.75, sweep)
        R["tmp_churn"][tag] = {"avail_before_mb": avail_mb(), **run_tmp_churn(tag, 24, 256, rate)}
        save()
    sh(f"rm -rf {B}/.cache/bulk {B}/churn {B}/tmp")
    sweep()
    sh(f"touch {B}/still-writable && sync")
    mark("done")


try:
    main() if MODE == "history" else baseline_main()
except Exception as e:
    R["error"] = str(e)[-3000:]
    log(f"FAILED: {e}")
finally:
    new = sh("dmesg").splitlines()[R.get("dmesg_lines_before", 0):]
    R["dmesg_new"] = [line for line in new if re.search(r"WARNING|NILFS|read-only|Oops|I/O error|BUG", line)][-40:]
    R["finished"] = time.strftime("%Y-%m-%d %H:%M:%S")
    save()
    teardown()
    log("NAS-EVAL-PI " + json.dumps(R))
