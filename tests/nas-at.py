import re
import time

DEV = "/dev/vdb"
B = "/mnt/disks/disk1"
DB = "/var/lib/nas-checkpoints/index.db"
VIEW = "/srv/nas-at"
ROW = re.compile(r"^\s+(\S+)\s+\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\s+(\d+)\s+(\S+)\s+(\S+)\s+(.+)$")


def sh(cmd):
    return machine.succeed(cmd)


def last_cno():
    return int(sh(f"lscp {DEV} | tail -1").split()[0])


def edit(path, kib):
    sh(f"mkdir -p $(dirname {B}/{path}) && dd if=/dev/urandom of={B}/{path} bs={kib}K count=1 status=none && sync")
    cno = last_cno()
    time.sleep(1.5)
    return cno


def tree(root):
    out = sh(f"if [ -d {root} ]; then cd {root} && find . -type f -print0 | sort -z | xargs -0r sha256sum; fi")
    return {line.split()[1]: line.split()[0] for line in out.splitlines()}


def epoch(cno):
    return int(sh(f"sqlite3 {DB} \"SELECT epoch FROM checkpoints WHERE branch='{B}' AND cno={cno}\"").strip())


def view(rel, cno):
    return tree(f"{VIEW}/@{epoch(cno)}/{rel}")


def found(pattern, text):
    m = re.search(pattern, text)
    assert m is not None, f"{pattern!r} not in {text!r}"
    return m.group(1)


def log_states(rel):
    rows = [ROW.match(line) for line in sh(f"nas-at log {B}/{rel}").splitlines()]
    return [m.group(5) for m in rows if m is not None]


def blocks(out):
    return int(found(r"\((\d+) blocks\)", out))


def diag(like):
    inos = f"(SELECT ino FROM paths WHERE path LIKE '{like}%')"
    for q in [
        f"SELECT rowid, ino, inc, path, lo, hi, since FROM paths WHERE ino IN {inos}",
        f"SELECT ino, s, e, seg, dead, SUM(n), COUNT(*) FROM lives WHERE ino IN {inos} GROUP BY 1, 2, 3, 4, 5",
        f"SELECT * FROM drops WHERE ino IN {inos}",
        "SELECT * FROM scan",
        "SELECT * FROM meta",
        "SELECT cno, ss FROM checkpoints ORDER BY cno DESC LIMIT 8",
        "SELECT dead, seg IS NULL, COUNT(*), SUM(n) FROM lives GROUP BY 1, 2",
    ]:
        machine.log(q + "\n" + sh(f"sqlite3 -header {DB} \"{q}\""))
    machine.log(sh(f"lscp -a {DEV} | tail -8; lssu {DEV} | tail -12"))


machine.wait_for_unit("multi-user.target")
sh("dmesg -C")
sh(f"mkfs.nilfs2 -f -B 256 {DEV}")
sh(f"mkdir -p {B} && mount -t nilfs2 -o nogc,noatime {DEV} {B}")
sh("systemctl start nas-history-watch-disk1")
machine.wait_until_succeeds("test -e /var/lib/nas-checkpoints/events/disk1.jsonl")
sh("nas-at pass")
sh("systemctl start nas-at-view")
machine.wait_until_succeeds(f"mountpoint -q {VIEW}")

with subtest("sysfs attributes the pass reads"):
    sysfs = "/sys/fs/nilfs2/" + sh(f"basename $(realpath {DEV})").strip()
    for attr in [
        "segctor/last_seg_sequence",
        "segctor/last_pseg_block",
        "segments/blocks_per_segment",
        "checkpoints/checkpoints_number",
        "checkpoints/snapshots_number",
    ]:
        sh(f"test -r {sysfs}/{attr}")

proj = []
land = []
land2 = []
cache = []
for i, name in enumerate(["f1", "f1", "f1", "f2", "f2", "f2"]):
    proj.append((edit(f"proj/{name}", 256), tree(f"{B}/proj")))
    if i % 2 == 0:
        cache.append(edit(".cache/x", 64))
for _ in range(3):
    land.append((edit("land/g", 256), tree(f"{B}/land")))
for _ in range(2):
    land2.append((edit("land2/h", 256), tree(f"{B}/land2")))
time.sleep(8)
for name in ["f1", "f2", "f1", "f2", "f1", "f2"]:
    proj.append((edit(f"proj/{name}", 256), tree(f"{B}/proj")))
for _ in range(2):
    land.append((edit("land/g", 256), tree(f"{B}/land")))
pin = sh(f"nas-at pin {B}/land/g")
machine.log(pin)
land.append((edit("land/g", 256), tree(f"{B}/land")))
land.append((edit("land/g", 16), tree(f"{B}/land")))
land.append((edit("land/g", 16), tree(f"{B}/land")))
land2.append((edit("land2/h", 256), tree(f"{B}/land2")))
time.sleep(7)
sh("nas-at pass")

with subtest("log, top and the view before any rule"):
    states = log_states("proj/f1")
    machine.log(sh(f"nas-at log {B}/proj/f1"))
    assert len(states) >= 6 and not any(s.startswith("compressed") for s in states), states
    top = sh("nas-at top")
    machine.log(top)
    assert "proj/f1" in top and "land/g" in top, top
    for cno, state in proj:
        got = view("proj", cno)
        assert got == state, f"view of proj at checkpoint {cno}: {got} != {state}"

with subtest(".cache stays historyless"):
    states = log_states(".cache/x")
    machine.log(sh(f"nas-at log {B}/.cache/x"))
    assert len([s for s in states if not s.startswith("compressed")]) == 1, states
    assert len(states) >= len(cache), states

with subtest("quantum inf keeps landmarks: session end, pin, large removal, range end"):
    out = sh(f"nas-at keep {B}/land --quantum inf")
    machine.log(out)
    retained = {2, 4, 5, 7}
    for i, (cno, _) in enumerate(land):
        kept = [j for j in retained if j <= i]
        expected = land[max(kept)][1] if kept else {}
        got = view("land", cno)
        assert got == expected, f"land at edit {i + 1}: {got} != {expected}"
    states = log_states("land/g")
    machine.log(sh(f"nas-at log {B}/land/g"))
    assert len([s for s in states if not s.startswith("compressed")]) == len(retained), states

with subtest("--no-landmarks keeps only the range end, still consistent"):
    out = sh(f"nas-at keep {B}/land2 --quantum inf --no-landmarks")
    machine.log(out)
    states = log_states("land2/h")
    machine.log(sh(f"nas-at log {B}/land2/h"))
    assert len([s for s in states if not s.startswith("compressed")]) == 1, states
    assert view("land2", land2[-1][0]) == land2[-1][1]
    assert view("land2", land2[0][0]) == {}

snapped_to = {}
with subtest("pairs on interleaved files: every directory revert is a real state"):
    dry = sh(f"nas-at keep {B}/proj --pairs --dry-run")
    machine.log(dry)
    assert "frees 0B" not in dry, dry
    machine.log(sh(f"nas-at keep {B}/proj --pairs"))
    moved = 0
    for cno, _ in proj:
        out = sh(f"nas-at revert {B}/proj --at @{epoch(cno)}")
        machine.log(out)
        c = int(found(r"as of checkpoint (\d+)", out))
        expected = max((r for r in proj if r[0] <= c), key=lambda r: r[0])[1]
        got = tree(f"{B}/proj")
        assert got == expected, f"revert to {cno} (snapped to {c}): {got} != {expected}"
        snapped_to[cno] = (c, expected)
        moved += c < cno
    assert moved > 0, "no revert was snapped, so pairs dropped nothing"
    assert any(s.startswith("compressed") for s in log_states("proj/f1"))

with subtest("forget hides the path everywhere"):
    sh("sync")
    newest = last_cno()
    machine.log(sh(f"nas-at forget {B}/land2 --yes"))
    sh(f"test ! -e {B}/land2")
    for cno in [c for c, _ in land2] + [newest]:
        sh(f"test ! -e {VIEW}/@{epoch(cno)}/land2/h")
    assert "tagged: deleted" in sh(f"nas-at log {B}/land2/h")

with subtest("a reused inode number does not inherit the untracked previous owner's history"):
    sh("systemctl stop nas-history-watch-disk1")
    for _ in range(3):
        old_cno = edit("reuse/old", 1024)
    old_tree = tree(f"{B}/reuse")
    old_ino = sh(f"stat -c %i {B}/reuse/old").strip()
    sh(f"rm {B}/reuse/old && sync && sleep 2")
    edit("reuse/new", 4)
    assert sh(f"stat -c %i {B}/reuse/new").strip() == old_ino, "nilfs2 did not reuse the inode number"
    sh("systemctl start nas-history-watch-disk1")
    machine.wait_until_succeeds("test -e /var/lib/nas-checkpoints/events/disk1.jsonl")
    sh("nas-at pass --walk")
    machine.log(sh(f"nas-at log {B}/reuse/new"))
    assert len(log_states("reuse/new")) == 1, log_states("reuse/new")
    top = sh(f"nas-at top {B}/reuse")
    machine.log(top)
    assert found(r"(\S+)\s+\S+\s+disk1\s+reuse/new", top) == "0B", top
    machine.log(sh(f"nas-at forget {B}/reuse/new --yes"))
    assert view("reuse", old_cno) == old_tree

with subtest("reclaim frees what the dry run predicted, and history survives it"):
    dry = sh("nas-at reclaim --dry-run")
    machine.log(dry)
    real = sh("nas-at reclaim")
    machine.log(real)
    predicted, freed = blocks(dry), blocks(real)
    assert freed > 0, real
    assert abs(predicted - freed) <= 0.02 * predicted, f"predicted {predicted}, freed {freed}"
    for cno, (c, expected) in snapped_to.items():
        assert view("proj", c) == expected, f"view of proj at {c} after reclaim"
    for i in (2, 4, 5, 7):
        assert view("land", land[i][0]) == land[i][1], f"land at edit {i + 1} after reclaim"
    assert any(s == "compressed, freed" for s in log_states("land/g"))
    assert view("reuse", old_cno) == old_tree, "reclaim freed the reused inode's previous owner"
    sh(f"touch {B}/still-writable && sync")
    dmesg = sh("dmesg")
    assert "read-only" not in dmesg and "NILFS error" not in dmesg, dmesg

with subtest("an open rule re-renders after its drops were enforced"):
    edit(".cache/x", 64)
    sh("sync && sleep 6 && nas-at pass")

with subtest("a historyless file written and deleted between passes is reclaimable"):
    sh(f"mkdir -p {B}/.cache/brief && dd if=/dev/urandom of={B}/.cache/brief/f bs=1M count=4 conv=fsync status=none")
    sh(f"sync && sleep 6 && rm {B}/.cache/brief/f && sync && sleep 6 && nas-at pass")
    for i in range(8):
        dry = sh("nas-at reclaim --dry-run")
        machine.log(dry)
        if blocks(dry) >= 1024:
            break
        sh(f"head -c 2097152 /dev/urandom > {B}/tick-{i} && sync && sleep 6")
    diag(".cache/brief")
    assert blocks(dry) >= 1024, dry

with subtest("metrics parse"):
    metrics = sh("cat /var/lib/nas-checkpoints/nas.prom")
    values = {}
    for line in metrics.splitlines():
        if line.startswith("nas_history_bytes{"):
            labels, value = line.rsplit(" ", 1)
            values[found(r'state="(\w+)"', labels)] = float(value)
    assert {"current", "retained", "reclaimable", "freed"} <= set(values), metrics
    assert values["freed"] > 0, metrics
    days = sh(f"sqlite3 {DB} 'SELECT SUM(current), SUM(retained), SUM(reclaimable) FROM history_days'").strip()
    assert [float(x) for x in days.split("|")] == [values["current"], values["retained"], values["reclaimable"]], days

with subtest("an idle pass leaves the write-day table alone"):
    sh("sync && nas-at pass")
    sh(f"sqlite3 {DB} 'UPDATE history_days SET current = -1'")
    sh("nas-at pass")
    assert sh(f"sqlite3 {DB} 'SELECT DISTINCT current FROM history_days'").strip() == "-1"
    sh(f"touch {B}/idle-probe && sync && sleep 2")
    sh("nas-at pass")
    assert "-1" not in sh(f"sqlite3 {DB} 'SELECT current FROM history_days'").split()

with subtest("a pass on a quiet branch creates no checkpoint"):
    sh("nas-at pass && sleep 8 && nas-at pass && sleep 8")
    newest = sh(f"lscp -a {DEV} | tail -1")
    sh("nas-at pass && sleep 8 && nas-at pass && sleep 8")
    assert sh(f"lscp -a {DEV} | tail -1") == newest, newest

with subtest("tallies match a fresh aggregate of lives"):
    o = "9223372036854775807"
    fresh = (
        f"SELECT branch, ino, s, SUM(n), SUM(n * (off >= 0)), SUM(n * (e = {o})), SUM(n * (e = {o} AND off >= 0)), "
        f"SUM(n * (e < {o} AND dead = 0 AND seg IS NOT NULL)), SUM(n * (dead = 1 AND seg IS NOT NULL)) FROM lives GROUP BY 1, 2, 3"
    )
    kept = "SELECT branch, ino, s, blocks, born, cur, data, ret, rec FROM tallies WHERE blocks > 0"
    rows = sh(f"sqlite3 {DB} 'SELECT COUNT(*) FROM lives'").strip()
    differ = sh(f"sqlite3 {DB} 'SELECT COUNT(*) FROM ({fresh} EXCEPT {kept}) UNION ALL SELECT COUNT(*) FROM ({kept} EXCEPT {fresh})'")
    assert int(rows) > 0 and differ.split() == ["0", "0"], differ
