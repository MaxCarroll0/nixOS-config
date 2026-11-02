import re

DEV = "/dev/vdb"
VERSIONS = 100
BLOCKS_PER_VERSION = 16


def sh(cmd):
    return machine.succeed(cmd)


def last_cno():
    return int(sh("lscp | tail -1").split()[0])


def snapshot():
    sh("sync && mkcp -s")
    return last_cno()


def promote_all():
    for cno in [int(l.split()[0]) for l in sh("lscp").splitlines()[1:] if " cp " in l]:
        sh(f"chcp ss {DEV} {cno} || true")


def reclaimable_segments():
    segs = []
    for line in sh(f"lssu {DEV}").splitlines()[1:]:
        segnum, _, _, stat, _ = line.split()
        if "d" in stat and "a" not in stat and "e" not in stat:
            segs.append(segnum)
    return segs


def reclaim(policy, dry_run):
    machine.succeed(f"cat > /root/policy <<'EOF'\n{policy}EOF")
    flag = "--dry-run " if dry_run else ""
    out = sh(f"nilfs-reclaim {flag}--policy /root/policy --protcno {last_cno()} {DEV} {' '.join(reclaimable_segments())}")
    return dict(kv.split("=") for kv in out.split())


def sha(path):
    return sh(f"sha256sum {path}").split()[0]


def at_checkpoint(cno, paths):
    sh(f"mkdir -p /cp && mount -t nilfs2 -o ro,nogc,cp={cno} {DEV} /cp")
    try:
        return {p: sha(f"/cp/{p}") for p in paths}
    finally:
        sh("umount /cp")


machine.wait_for_unit("multi-user.target")
sh("dmesg -C")
sh(f"mkfs.nilfs2 -f -B 256 {DEV}")
sh(f"mkdir -p /b && mount -t nilfs2 -o nogc {DEV} /b")

sh("head -c 1048576 /dev/urandom > /b/b")
sh("head -c 65536 /dev/urandom > /b/d")
ino_a = None
before = {}
history = {}
for v in range(1, VERSIONS + 1):
    before[v] = last_cno()
    sh(f"head -c {BLOCKS_PER_VERSION * 4096} /dev/urandom > /b/a")
    sh("head -c 4096 /dev/urandom >> /b/c")
    if v == 50:
        ino_d = int(sh("stat -c %i /b/d"))
        d_lo = 1
        sh("rm /b/d && sync")
        d_hi = last_cno() + 1
        sh("head -c 65536 /dev/urandom > /b/e")
        assert int(sh("stat -c %i /b/e")) == ino_d, "inode was not reused"
    cno = snapshot()
    paths = ["a", "b", "c"] + (["e"] if v >= 50 else [])
    history[cno] = (v, {p: sha(f"/b/{p}") for p in paths})
ino_a = int(sh("stat -c %i /b/a"))
promote_all()

lo, hi = before[2] + 1, before[VERSIONS - 1] + 1
policy = f"{ino_a} {lo} {hi}\n{ino_d} {d_lo} {d_hi}\n"

base = reclaim("", dry_run=True)
predicted = reclaim(policy, dry_run=True)
gained = int(predicted["freed_vblks"]) - int(base["freed_vblks"])
dropped_versions = VERSIONS - 3
machine.log(f"baseline {base}; with policy {predicted}; gained {gained}")
assert (dropped_versions + 1) * BLOCKS_PER_VERSION <= gained <= (dropped_versions + 1) * (BLOCKS_PER_VERSION + 2) + 32, gained

freed = reclaim(policy, dry_run=False)
machine.log(f"reclaimed {freed}")
assert 0 <= int(freed["freed_vblks"]) - int(predicted["freed_vblks"]) <= max(16, int(predicted["freed_vblks"]) // 50), (freed, predicted)
again = reclaim(policy, dry_run=True)
machine.log(f"second pass {again}")
assert int(again["freed_vblks"]) <= 64, again

for p, h in history[max(history)][1].items():
    assert sha(f"/b/{p}") == h, p

kept_versions = {1, VERSIONS - 1, VERSIONS}
for cno, (v, hashes) in sorted(history.items()):
    paths = [p for p in hashes if p != "a" or v in kept_versions]
    got = at_checkpoint(cno, paths)
    for p in paths:
        assert got[p] == hashes[p], f"cno {cno} version {v} {p}"

dump = sh(f"dumpseg {DEV} {reclaimable_segments()[0]}")
assert re.search(r"vblocknr = \d+, blkoff = \d+", dump), "no data vblocknr in dumpseg"
assert re.search(r"vblocknr = \d+, blocknr = \d+", dump), "no node vblocknr in dumpseg"
machine.log("\n".join(dump.splitlines()[:40]))

dropped_cno = next(c for c, (v, _) in history.items() if v == 50)
dropped_sha = history[dropped_cno][1]["a"]


def read_dropped():
    sh(f"mount -t nilfs2 -o ro,nogc,cp={dropped_cno} {DEV} /cp")
    status, out = machine.execute("sha256sum /cp/a")
    sh("umount /cp")
    live_rw = machine.execute("touch /b/probe && rm /b/probe")[0] == 0
    return status, out.split()[0] if status == 0 else out, live_rw


def remount_live(options):
    sh(f"umount /b && mount -t nilfs2 -o {options} {DEV} /b")


status, got, live_rw = read_dropped()
machine.log(f"dropped read, errors=remount-ro: status {status} {got} live_rw {live_rw}")
assert status != 0 and not live_rw, "expected the dropped read to remount the live branch read-only"
remount_live("nogc,errors=continue")
status, got, live_rw = read_dropped()
machine.log(f"dropped read, live errors=continue: status {status} {got} live_rw {live_rw}")
sh("dmesg -C")

sh("systemd-run --unit writer --setenv=PATH sh -c 'while :; do head -c 65536 /dev/urandom > /b/w; sync; sleep 0.05; done'")
cnos = sorted(history)
cno_before_load = last_cno()
for i in range(1000):
    sh(f"mount -t nilfs2 -o ro,nogc,cp={cnos[i % len(cnos)]} {DEV} /cp && cat /cp/b > /dev/null && umount /cp")
sh("systemctl is-active writer")
sh("systemctl stop writer")
assert last_cno() - cno_before_load >= 100, "writer produced no load"
oops = machine.execute("dmesg | grep -iE 'oops|bug:|warning:|nilfs.*error'")[1]
assert oops.strip() == "", oops


for i in range(40):
    sh(f"head -c 4194304 /dev/urandom > /b/fill{i} && sync")
status, got, live_rw = read_dropped()
machine.log(f"dropped read after DAT reuse: status {status} live_rw {live_rw} "
            f"{'original bytes' if got == dropped_sha else 'foreign bytes' if status == 0 else got}")
machine.log(machine.execute("dmesg | tail -10")[1])
