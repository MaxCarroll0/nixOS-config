import json
import re
import time

B = "/mnt/disks/disk1"
DEV = "/dev/mapper/slow"
POOL = "/mnt/pool"
FILES = 10000
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


bulk = [0]


def set_fill(target, make_room):
    for _ in range(3):
        files = sh(f"ls -t {B}/.cache/bulk 2>/dev/null || true").split()
        _, used, avail = df()
        excess = used - target * (used + avail)
        if excess <= 0 or not files:
            break
        doomed = files[: max(1, int(excess // (64 * MB)) + 1)]
        sh(f"cd {B}/.cache/bulk && rm -f {' '.join(doomed)}")
        make_room()
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


def run_unit(unit, cmd, env=""):
    sh(f"systemd-run --unit={unit} -p RemainAfterExit=yes --setenv=PATH=/run/current-system/sw/bin {env} {cmd}")


def stop(unit):
    sh(f"systemctl stop {unit}; systemctl reset-failed {unit} 2>/dev/null || true")


def finished(unit):
    machine.wait_until_succeeds(f"systemctl show -p SubState --value {unit} | grep -qxE 'exited|failed'", timeout=1800)


def dev_stat():
    dm = sh(f"basename $(readlink -f {DEV})").strip()
    fields = sh(f"cat /sys/block/{dm}/stat").split()
    return int(fields[2]), int(fields[6])


def vm_now():
    return float(sh("date +%s.%N"))


def avail_mb():
    return df()[2] // MB


def read_cmd(name, path):
    if name == "smb":
        return f"smbclient //localhost/disk1 -N -c 'get {path} /dev/null' > /dev/null 2>&1"
    return f"cat {path} > /dev/null"


def drop_caches():
    sh("sync && echo 3 > /proc/sys/vm/drop_caches")


def make_reading_set():
    sh(f"mkdir -p {B}/many && cd {B}/many && for i in $(seq {FILES}); do head -c 1024 /dev/urandom > f$i; done")
    sh(f"mkdir -p {B}/big && dd if=/dev/urandom of={B}/big/seq bs=1M count=256 conv=fsync status=none")
    sh(f"for n in branch mergerfs view smb; do dd if=/dev/urandom of={B}/big/r-$n bs=1M count=128 conv=fsync status=none; done")


def stat_walk(root):
    drop_caches()
    cold, _ = timed(f"find {root}/many -type f -exec stat -c %s {{}} + > /dev/null")
    warm, _ = timed(f"find {root}/many -type f -exec stat -c %s {{}} + > /dev/null")
    return {"stat_cold_ms_per_file": round(cold * 1000 / FILES, 3), "stat_warm_ms_per_file": round(warm * 1000 / FILES, 3)}


def seq_read(name, path):
    drop_caches()
    read, _ = timed(read_cmd(name, path))
    return round(256 / read, 1)


def concurrent_reads(paths):
    drop_caches()
    jobs = " ".join(f"( s=$(date +%s.%N); {read_cmd(name, path)}; echo {name} $s $(date +%s.%N) ) &" for name, path in paths.items())
    spans = {n: (float(a), float(b)) for n, a, b in (line.split() for line in sh(f"{jobs} wait").splitlines())}
    whole = max(b for _, b in spans.values()) - min(a for a, _ in spans.values())
    return {n: round(128 / (b - a), 1) for n, (a, b) in spans.items()}, round(128 * len(spans) / whole, 1)


def quiet(seconds):
    before = dev_stat()
    sh(f"sleep {seconds}")
    after = dev_stat()
    return {"seconds": seconds, "fill": round(fill(), 3), "sectors_read": after[0] - before[0], "sectors_written": after[1] - before[1]}


def run_tmp_churn(tag, count, mb, rate):
    log = f"/run/churn-{tag}.log"
    before = dev_stat()
    run_unit(f"churn-{tag}", f"tmp-churn {count} {mb} {rate} {log}")
    finished(f"churn-{tag}")
    after = dev_stat()
    stop(f"churn-{tag}")
    rows = [line.split() for line in sh(f"cat {log}").splitlines()]
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


def flood(mb):
    code, out = machine.execute(f"dd if=/dev/zero of={B}/.cache/flood bs=1M count={mb} conv=fsync status=none 2>&1")
    sh(f"rm -f {B}/.cache/flood")
    return code == 0, out.strip()[-200:]


def wait_for_avail(mb, timeout):
    began = time.time()
    code, _ = machine.execute(f"timeout {timeout} sh -c 'until [ $(df -B1M --output=avail {B} | tail -1) -ge {mb} ]; do sleep 1; done'")
    return code == 0, round(time.time() - began, 1)


def dmesg_warnings():
    dmesg = sh("dmesg")
    R["dmesg_warnings"] = len(re.findall(r"WARNING|NILFS error|read-only|Oops", dmesg))
    return dmesg


def report():
    machine.log("NAS-EVAL " + json.dumps(R))
    print("NAS-EVAL " + json.dumps(R))


machine.wait_for_unit("multi-user.target")
sh("dmesg -C")
sh("head -c 32 /dev/urandom > /etc/k && cryptsetup luksFormat -q --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --key-file /etc/k /dev/vdb")
sh("cryptsetup open --key-file /etc/k /dev/vdb crypt")
sh("dmsetup create slow --table \"0 $(blockdev --getsz /dev/mapper/crypt) delay /dev/mapper/crypt 0 4\"")
sh(f"mkfs.nilfs2 -f -B {SEG_BLOCKS} {DEV}")
sh(f"mkdir -p {B} && mount -t nilfs2 -o nogc,noatime {DEV} {B}")
sh(f"mkdir -p {POOL} && mergerfs -o cache.files=partial,dropcacheonclose=true,category.create=eppfrd,allow_other {B} {POOL}")
sh("mkfs.ext4 -q /dev/vdc && mkdir -p /parity && mount /dev/vdc /parity")
