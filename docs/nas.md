# Pi NAS: design and architecture

Design-of-record for turning `pi` into a shared, encrypted, observable family NAS while
keeping it the always-on Grafana and Wake-on-LAN node it already is.

**Status: Stage 0 (design). No NAS storage exists yet.** The monitoring trim of section 13 is
a prerequisite and is partly built and measured; everything about the array itself is still
design. Every later stage updates this document as decisions are settled by measurement
rather than assumption.

Decisions revised during design, so the original write-up is not the current one: placement
became user-affinity (`mspmfs`) with automatic overflow rather than proportional spread
(4.3); the browse index became a required bespoke component rather than something inherited
from the application tier (4.5.1); and section 13 was superseded by what was actually
deployed.

## 1. Requirements

1. Encrypted at rest, redundant, snapshotted. A 90 day recoverable-delete window,
   self-service Previous Versions covering same-day changes, and an on-demand permanent
   delete.
2. Multiple accounts that strictly cannot reach each other's files. Creating an account is a
   manual, reviewed act by Max. Adding a *device* to an existing account requires nothing
   from Max at all.
3. Reachable only over Tailscale, in two tiers: NAS users reach only the pi, Max's devices
   reach everything.
4. Must extend to automated phone photo backup and automated PC folder backup across iOS,
   Android, Windows and macOS. This is a hard gate on every application-tier candidate.
5. Grafana shows each user their own disk and network usage with a folder breakdown, plus
   the *total* used by everyone else, but never a per-user breakdown of others.
6. Doubles as a Nix binary cache for Max's tailnet only, on separate unencrypted,
   non-redundant storage, receiving builds pushed from laptop and desktop.
7. Extensible to at most 3 mirrored nodes later. Designed for now, not built now.

## 2. The binding constraint

The Pi 5 has **2 GB of soldered RAM and will never have more**. Measured baseline before any
NAS work:

| Service | RSS |
|---|---|
| grafana | 181 MB |
| prometheus (3 tiers) | 263 MB |
| loki | 115 MB |
| alloy | 76 MB |
| tempo | 39 MB |
| tailscaled | 60 MB |

That is roughly 750 MB resident, leaving about 886 MB. Every decision in this document is
downstream of that number.

**Update: the monitoring trim is complete and measured.** Removing Loki, Tempo and Alloy returned
a verified **+150 MB** to `MemAvailable` (median 573.6 to 723.8 MB, non-overlapping
distributions), series pruning cut the hires tier's heap from 144 MB to 79 MB, and the
VictoriaMetrics migration replaced three Prometheus tiers with **272 MB** where they had used
940 MB. Grafana is capped at 224 MiB soft. Roughly **800 MB** was returned in total and
`MemAvailable` moved from a median of 500.5 MB to ~750 MB.

See `docs/monitoring.md` for method and figures. The 886 MB above is the pre-trim baseline, not
current headroom; with the NAS running, headroom is roughly 300-400 MB.

**This NAS is not a backup.** Parity and mirroring cover hardware failure. They do not cover
fire, theft, or ransomware. Offsite replication is a later stage.

## 3. Hardware

| Device | Size | Model | Power-on | Realloc / Pending / Uncorrectable | UDMA CRC | Load cycles | Role |
|---|---|---|---|---|---|---|---|
| `sda` | 120 GB | Patriot Burst Elite (USB) | 65 h | n/a | n/a | n/a | root, Attic, write tier, read cache |
| `sdb` | 1 TB | ST1000VM002 (CMR, 5900 rpm) | 74 h | 0 / 0 / 0 | 0 | 195 | data disk 2 |
| `sdc` | 4 TB | ST4000DM004 (**SMR**, 5425 rpm) | 10,295 h | 0 / 0 / 0 | **329** | 13,754 | parity (interim) |
| `sdd` | 2 TB | ST2000DM006 (CMR, 7200 rpm) | 11,571 h | 0 / 0 / 0 | 0 | 49,038 | data disk 1, holds data to preserve |

All four report `health_ok = 1` at 32-35 °C. Re-read from the metrics store, no disk woken:

```bash
curl -s --get --data-urlencode 'match[]=drive:health_ok{instance="pi"}' \
  --data-urlencode 'start=-1h' http://127.0.0.1:9090/api/v1/export
```

Use `export`, not an instant query: these series are on a 5-minute cadence and instant-query
lookback will miss them inside the gap.

**`sdc`'s 329 CRC errors are a link fault, not the drive.** Its media is pristine — zero
reallocated, pending and uncorrectable — and UDMA CRC counts link-layer failures between
controller and drive, so the cable or connector is the suspect. The count was **also 329 twenty
power-on hours earlier**, so it is not accruing: the fault is historic, or intermittent enough
not to have recurred. Replace the SATA cable before trusting this disk with parity, then confirm
the counter stays flat rather than assuming the swap fixed anything.

`sdd`'s 49,038 load cycles are worth watching but not alarming: the ST2000DM006 is rated in the
hundreds of thousands, and the spindown work already stopped exporters from waking the disks.

Controller: JMicron JMB585, 5 SATA ports, 3 used, 2 free. The SSD is on USB and therefore
costs no SATA port. Kernel has `BCACHE`, `DM_CACHE`, `DM_WRITECACHE`, `BTRFS_FS` and
`FUSE_FS` available as modules.

Notes from the SMART survey:

- All three drives report `PASSED` with **zero media degradation**: no reallocated, pending
  or offline-uncorrectable sectors anywhere. No drive warrants a retirement plan on health
  grounds, including the SMR one.
- `sdc`'s 329 UDMA CRC errors are SATA **link** errors (cable, connector or power), not
  platter faults. The normalised value has recovered from a worst of 107 back to 200, which
  suggests they accumulated earlier and stopped. Because `sdc` is the interim parity disk,
  and parity is the most write-heavy role in the array, its cable is replaced and the counter
  re-checked before any data is committed.
- Ignore the raw `Seek_Error_Rate` figures. Seagate packs two counters into that field; the
  normalised values are the meaningful ones and are healthy.

Interim usable capacity: **3 TB** (data 2 TB plus 1 TB, parity 4 TB).

All required packages exist in the pinned nixpkgs for aarch64: `mergerfs-2.41.1`,
`mergerfs-tools`, `snapraid-14.4`, `bcache-tools`, `clevis-22`, `tang-15`, `samba-4.23.8`,
`sftpgo-2.7.1`, `attic`.

## 4. Architecture

### 4.1 Block stack

```
sda4 -> LUKS -> nilfs2 -> /mnt/ssd           write tier, a mergerfs branch (file level)
                                             NILFS2: this is where edits are versioned
sda5 -> LUKS -> bcache cache (writearound)   read cache for the HDDs (block level)

sdd (2 TB) -> LUKS -> bcache backing \  -> nilfs2 -> /mnt/disk1
sdb (1 TB) -> LUKS -> bcache backing /  -> nilfs2 -> /mnt/disk2
    each branch holds  data/  and  snapshots/  (snapshots/ = checkpoint mounts)
sdc (4 TB) -> LUKS -> btrfs -> /mnt/parity   (uncached: bulk parity writes would thrash it)
                                             stays btrfs: one parity file, no versioning wanted

mergerfs(/mnt/ssd, /mnt/disk1, /mnt/disk2) -> /srv/nas
SnapRAID: parity=/mnt/parity, data=/mnt/disk{1,2}, content files on both plus root
```

Why this shape:

- **SnapRAID** for redundancy. It costs one disk of parity regardless of array size, accepts
  any disk size at any time, spins up only the disk holding the file, and if you exceed your
  parity you lose only the failed disks' files while every survivor remains a directly
  readable filesystem. This is the Unraid model without Unraid, which is x86-only, a whole
  operating system that would replace this NixOS configuration entirely, and paid.
- **btrfs per disk** because SnapRAID requires independent filesystems, and btrfs supplies
  snapshots and checksums on each. It is also the prerequisite for future `send`/`receive`
  mirroring.
- **mergerfs** to present one `/srv/nas` namespace with no per-user disk ceiling, and to make
  folders the unit of placement, policy and (later) replication.
- **SSD as a write tier** rather than a write cache. New files land on the SSD and never
  touch a HDD, so the disks stay asleep through uploads, and SnapRAID only ever ingests data
  that has already settled for 24 hours. That matters: SnapRAID's own manual says it suits
  data that rarely changes, and this arrangement guarantees it never sees live data.
- **bcache in `writearound`** for reads. Writes bypass the cache entirely and go straight to
  the backing device, so **no dirty data ever exists on the SSD cache**. A failed cache device
  is a detach-and-continue event, not an array loss.

The mover relocates files off the SSD tier: opportunistically whenever a target HDD is
already spinning (so a move never itself causes a spin-up), forced under SSD space pressure,
with a 24 hour backstop. `snapraid sync` runs after the mover.

**Operational rule:** bcache requires its superblock at the start of the device and cannot be
retrofitted onto a populated disk without a full copy. *Every new data disk gets
`make-bcache -B` at creation*, even if it is not attached to the cache set immediately.

### 4.2 SSD partition layout

The SSD is USB, so it is unplugged and resized from the laptop rather than touched remotely.
ext4 cannot shrink online, and shrinking the boot disk of a headless remote host is a
reliable way to strand it. Free space lands after root, so no partition needs to move. Image
the SSD first, and back up the SSH host key, because sops decryption depends on it.

| Partition | Label | Size | Contents |
|---|---|---|---|
| p1 | FIRMWARE | 1 GB | unchanged |
| p2 | NIXOS_SD | ~45 GB | root, shrunk from 110.8 GB (32 GB used today) |
| p3 | nix-cache | ~14 GB | Attic, unencrypted |
| p4 | nas-tier | ~35 GB | write tier, a mergerfs branch, LUKS (holds user data) |
| p5 | nas-rcache | ~25 GB | bcache `writearound` read cache, LUKS |

Both NAS partitions widen at the planned SSD upgrade, which is also when LVM replaces fixed
partitioning so the split can be re-cut online.

### 4.3 Placement: keep a user together, overflow when full

```
func.mkdir      = mspmfs   minfreespace = 20G     cache.files      = partial
func.create     = eppfrd   moveonenospc = pfrd    dropcacheonclose = true
category.search = ff       inodecalc    = hybrid-hash
```

The goal is **affinity, not balance**: a user's data should sit on one drive, and spill onto
another only when that drive is genuinely full.

`func.mkdir = mspmfs` ("most shared path, most free space") delivers exactly that. It ranks
branches by how much of the path being created **already exists** on them, so a new folder
under `users/alice/` lands on whichever disk already holds Alice's data, and only breaks the
tie by free space. Unlike a path-preserving `ep*` policy, `msp*` **cannot fail**: when no
branch holds the path it falls back to the deepest existing ancestor, so overflow is
automatic rather than an error.

Overflow is driven by `minfreespace`: once Alice's disk drops below 20 GB it stops being
eligible, the next folder goes elsewhere, and from then on she spans two disks. Nothing has
to be reconfigured for that to happen. `moveonenospc` catches the narrower case of a single
file outgrowing the disk mid-write.

`func.create = eppfrd` stays path-preserving, so a new *file* only considers branches where
its immediate parent folder already exists, which is exactly one. Folders therefore stay
intact on a single disk even once a user spans several.

Net effect: one user is normally one drive, so browsing their data spins one disk and a disk
loss costs whole folders belonging to few users rather than fragments belonging to all. There
is still no per-user ceiling, because overflow is automatic. The cost is that disks fill
unevenly by design; capacity is balanced by `minfreespace` at the margin rather than
proportionally from the start.

*Caveats: loose files at a directory's root follow that directory, and the mover decides
final placement for anything written to the SSD tier first. `mergerfs.consolidate` can pull a
user's scattered folders back onto one disk after an overflow, but it is a bulk copy that
spins every drive, so it belongs in a maintenance window.*

### 4.4 Read caching and prefetch

`sequential_cutoff=0` so reads populate the cache, and `congested_read_threshold_us=0` so a
spun-down disk is not mistaken for congestion and bypassed (the default 2000 microseconds
would actively defeat the spin-down goal, since a sleeping HDD looks like extreme
congestion).

`nas-prefetch` is a small daemon watching `FAN_OPEN` via fanotify across `/mnt/disk*`, the
branch mounts, because real opens land on the underlying filesystems rather than the FUSE
mount. On an open it reads the file's **non-recursive** siblings so they warm the cache. It
needs caps (maximum files, maximum bytes, per-folder cooldown) and self-I/O exclusion to
avoid feedback loops. Being protocol-agnostic, it serves SMB, SFTP and the web tier equally.

This composes with folder-granular placement: the disk has to spin up for the first file
anyway, so warming the rest of the folder is nearly free. Because the mover's writes bypass
the cache under `writearound`, only genuine user reads populate it, so the cache holds what
people actually open rather than what the mover last wrote.

At roughly 25 GB against 3 TB the cache will churn. This becomes considerably more effective
after the SSD upgrade. Hit ratio and bypass counters are exported so the caps can be tuned
from evidence rather than guesswork.

### 4.5 Metadata residency

**Stated limitation, up front: truly pinning metadata to the SSD is not achievable in this
stack.** No Linux block cache (bcache, dm-cache, dm-writecache) can pin data or prioritise
metadata; all are LRU with no notion of what a block contains. btrfs has no supported way to
place metadata on a chosen device, as the preferred-metadata patchset appears never to have
been merged upstream (**verify before relying on this**). bcachefs's `metadata_target` does
exactly what would be wanted here, but it is externally maintained rather than mainline,
SnapRAID's per-disk filesystem requirement means one SSD cannot be the metadata target for
several independent filesystems, and adopting it would discard the validated snapshot and
`shadow_copy2` design.

For SMB and SFTP the only available lever keeps **btrfs as the source of truth**: btrfs
metadata for a few million files is a couple of GB against a ~25 GB cache, so it fits
comfortably, and the only real risk is a bulk read evicting it. A **metadata warmer** walks
the branch trees during the nightly mover and `snapraid sync` window, when the disks are
already spinning, so keeping it resident costs essentially nothing. The honest
characterisation is *effectively always resident*, not *guaranteed resident*. Exported cache
statistics make it measurable, and widening the read cache at the SSD upgrade is the lever if
it proves insufficient.

### 4.5.1 The browse index (required, not optional)

Responsive real-world browsing needs three things permanently resident: the **file tree**,
**thumbnails**, and **version-history counts**. Only the first is filesystem metadata at all,
so a block cache cannot deliver the other two under any tuning:

- **Thumbnails** are derived data. They do not exist on disk until something generates them.
- **Version counts** cannot be *queried* cheaply: asking "how many versions does this file
  have" by stat-ing the path in every snapshot generation on every branch is ~46 FUSE stat
  calls per file and spins every disk. There is no cache-tuning answer, because the answer is
  not stored anywhere to be cached.

  But it can be **tracked incrementally as versions appear**, which avoids the query entirely.

  **This is where the move to NILFS2 costs the most, and the earlier design must be inverted.**
  The btrfs plan was to diff generations with `btrfs send --no-data -p <prev> <cur> | btrfs
  receive --dump`, or the lighter `btrfs subvolume find-new`. Both read the filesystem's own
  metadata, so they were *authoritative*: cost O(changes), and the missed-event drift class did
  not exist. **NILFS2 has no equivalent.** `lscp` reports blocks changed per checkpoint, not
  paths, and diffing two checkpoints means mounting both and walking them — O(files), not
  O(changes).

  So the mechanism inverts: **fanotify becomes the primary source of truth, not an optimisation**,
  with a periodic full walk as the correctness backstop. That reintroduces exactly the
  missed-event drift the btrfs design avoided: if the watcher dies or drops events, the index is
  wrong until the next reconciliation walk.

  Mitigations, none of which fully restore the old guarantee:

  - The reconciliation walk runs in the **nightly window** when disks are already spinning for
    `snapraid sync`, so it costs no extra spin-up.
  - The watcher records a monotonic event sequence, so a gap is detectable rather than silent.
  - Checkpoint numbers from `lscp` are recorded alongside each observed change, which is what
    lets `nas-versions` mount exactly one checkpoint instead of searching.

  Because the array is built fresh, counts begin at zero and no backfill is required.

  *Semantics to document:* version count is per path. A rename starts a new path at one,
  while the old path's history remains in older snapshots until they expire.

**Decision: the browse index is built as a bespoke component (`nas-index`), not inherited from
whichever application tier wins.** That keeps the lightweight app tier viable and leaves the
RAM budget intact.

It is a SQLite database on the SSD holding one row per path: parent, name, size, mtime, uid,
gid, branch, thumbnail key and version count, indexed on parent so a directory listing is a
single indexed lookup.

**Correctness now rests on fanotify plus a periodic walk.** On btrfs it rested on generation
numbers and fanotify was mere latency reduction; NILFS2 offers no such metadata, so the
dependency is reversed and the component is correspondingly less robust:

| Input | Mechanism | Cost |
|---|---|---|
| Tree changes, immediate | fanotify events into single-row upserts | O(1) per event |
| Tree changes, reconciliation | full walk in the nightly spin-up window | O(files) |
| Version identity | checkpoint number from `lscp` recorded with each observed change | O(1) |
| Thumbnails | generated at ingest while the file is still on the SSD tier | zero HDD I/O |

The reconciliation walk is the only thing that can repair drift, and it is O(files) rather than
O(changes). **There is no scan
anywhere in the design**, neither at bootstrap (the array is built empty) nor at repair.

Efficiency requirements, since this runs on a 2 GB box: SQLite in WAL mode with a bounded
page cache (single-digit MB), no in-memory tree, batched transactions per pass, and the
snapshot diff parsed as a stream rather than buffered. Target steady-state footprint is tens
of MB, and it is exported to Prometheus so the claim is checked rather than assumed.

Drift is contained by construction: the index is a **browsing cache only and never
authoritative**. Every actual read, write and permission check goes to the real filesystem, so
a stale entry can produce a stale listing but never data loss or a wrong access decision.

Scope depends on **which process implements the protocol**, not on the protocol itself:

- **OpenSSH `internal-sftp`** issues `readdir` and `stat` syscalls as the logged-in user, so
  it cannot consult the index without patching OpenSSH.
- **SFTPGo implements SFTP, WebDAV and its web UI itself, over a filesystem abstraction**
  (the same one behind its S3 and sftpfs backends). It can serve listings from the index on
  all three, so choosing it extends indexed browsing well beyond the web tier.
- **Samba** can reach the index through a **VFS module** serving `readdir`, the same
  extension mechanism `shadow_copy2` and `vfs_recycle` use. Possible, but bespoke C, and not
  planned for now.

Two constraints govern where the index may actually be used:

1. **Isolation.** SFTP via `sshd` is kernel-enforced, because the process runs as the real
   user. Serving SFTP from SFTPGo instead makes it app-enforced, like the web tier. That is
   trading a real guarantee for browsing speed, and is a decision for Stage 7, not a free win.
2. **Humans versus machines.** A stale listing is harmless to a person and hazardous to a
   sync client, which may re-upload or skip files. Since SFTP and WebDAV are exactly what the
   phone and PC backup clients use, **machine-driven access resolves through the filesystem
   authoritatively**, and the index serves interactive browsing only.

For SMB, and for any path left authoritative, browsing performance remains the best-effort
block-cache behaviour described above.

A full application tier would have inherited all of this: OpenCloud's PosixFS maintains its
own metadata index with an external-change watcher, ships a thumbnails service, and has
built-in versioning. That is no longer the deciding factor, since `nas-index` supplies the
same capability to whichever server is chosen. If OpenCloud does win, its native index makes
`nas-index` redundant for the web tier, though it would still serve any SFTPGo or Samba path.

*Item to resolve:* a full application tier brings **its own** file versioning, which would
store versions in its state directory separately from the btrfs snapshots of section 4.6.
Whether to disable one, accept the duplication, or reconcile them is decided at Stage 7.

### 4.5.2 The version index, as built

Separate from the browse index, and much smaller: `modules/nixos/nas/versions.nix` maintains the
mapping from a file to every checkpoint that contains a change to it. Two integer tables in one
SQLite file on the SSD:

```
versions(branch, ino, cno, created) PRIMARY KEY (branch, ino, cno)
inodes  (branch, path, ino, seen)   PRIMARY KEY (branch, path)
```

**`versions` must be keyed by branch, not by inode alone.** Inode numbers are per-filesystem, so
with two branches disk1 and disk2 both allocate low numbers and unrelated files collide. The first
two-branch test showed one disk2 path listing four versions, two from disk2's checkpoint space and
two from disk1's, out of chronological order. The listing is the visible symptom; the dangerous one
is `restore --version N` picking a cno that belongs to the other branch and mounting that number on
this device, where it is often a valid but unrelated checkpoint, so the wrong contents come back
silently. This was invisible for as long as there was one branch.

**Lookups resolve the inode from the live file, not from the recorded path.** Applications
routinely write to a temporary name and rename into place, and NILFS2 keeps the inode across the
rename while `fatrace -f W+D` never sees the move. SnapRAID is a live example: its history was
recorded against `.snapraid.content.tmp`, so a query for `.snapraid.content` returned nothing.
`stat`-ing the live path gives the authoritative inode and the history follows the rename; the
recorded path is the fallback, used for files that no longer exist.

A million versions is roughly 24 MB. Nothing is resident between runs: SQLite is a library, not
a server, and the ingest is a `oneshot` timer.

**Why an index is required at all.** "Show me every version of this file and when" cannot be
answered by scanning checkpoints, because nothing is ever collected: there will eventually be
tens of thousands, and mounting each to `stat` one path is O(checkpoints) per query.

**Why not `dumpseg`.** It does carry the mapping — `ino` and `cno` per log entry — but measured
on disk1 it emits 120 KB and 2047 lines per segment at 74 ms, of which **one line** is useful.
Extrapolated to the 427 GB migration (~53,000 segments) that is ~6.4 GB of text and ~65 minutes
of Pi CPU to recover a few thousand rows. It is also documented as a debugging tool, so its
format is not a stable interface. It stays as the **offline audit path** for checking the index
against the log, which is what a debugging tool is for. `lssu` reports segment usage only, with
no inode detail, so it does not help.

**Collection is `fatrace`**, the packaged C fanotify tool — one instance per NILFS2 branch,
`-c` scoping it to that mount:

```
fatrace -c -j -f W+D -t -t -o <events>.jsonl
```

`-j` gives JSONL carrying `inode`, `path` and an epoch `timestamp`, so no path-to-inode
resolution is needed afterwards. Writing the consumer in Python was rejected: the stdlib has no
fanotify, so it would mean hand-written `ctypes` syscall wrappers plus an interpreter's RSS —
C-in-Python with the drawbacks of both. The ingest is shell (`jq`, `sqlite3`, `lscp`).

**Time to checkpoint.** A write lands in the first checkpoint at or after it, so each event
resolves to `MIN(cno) WHERE cp.epoch >= event.ts`. This must be a per-row scalar subquery; an
earlier `JOIN ... ON c.cno = (subquery)` silently dropped versions and was caught only by a test
that expected three checkpoints and got one.

**Checkpoint times are whole seconds, so the tie must break towards the later checkpoint.**
`lscp` reports to the second while several checkpoints can share one, and a checkpoint created in
the same second as a write may still predate it. Taking the *first* qualifying checkpoint recorded
a version that could never be restored: the test wrote a file at `T`, checkpoints 1 and 2 both
reported `T`, the index chose cp1, and mounting cp1 found no file. Ordering by
`epoch, cno DESC` takes the last checkpoint in that second instead, which does contain the write.

**Rotation, forced by `fatrace`'s output handling.** It opens `-o` with `O_CREAT|O_WRONLY|O_EXCL`
and no `O_APPEND`, which has two consequences: a stale file makes the watcher fail to start (so
the unit removes it in `ExecStartPre`), and the file cannot be renamed or truncated out from
under it. Ingest therefore reads forward from a stored byte offset, and rotates only by deleting
the file and restarting the watcher once it passes `rotateBytes` (64 MB).

**The known weakness is missed events while the watcher is down, and it is currently unmitigated.**
The intended backstop is a periodic pass comparing each file's mtime against its newest recorded
version, which detects *that* a file changed but not that it changed three times. **That pass is
not built yet** — `versions.nix` defines only the per-branch watchers and the ingest timer, so a
watcher outage silently loses those versions with nothing to repair the gap.

Version *number* is the ordinal of a checkpoint within that inode's history, so "currently on
version 12" is a `COUNT(*)` and the full timestamped list is one indexed range scan.

### 4.5.3 Reading a previous version, and time travel

Two access paths, deliberately separate:

**Per file, on demand.** `nas-versions list <path>` is an index query with no mounts at all.
`nas-versions restore <path> --version N` mounts that one checkpoint read-only in a temporary
directory, copies the file out and unmounts. Mounting is the only way to read from a checkpoint —
NILFS2 exposes no API to read a path from a checkpoint without one — so this is a single
transient mount, not a whole-array operation.

**By time, whole array.** `nas-at '<time>'` resolves the newest checkpoint at or before that
time **per branch** and mounts each read-only under `snapshots/@AT-<ts>`, which mergerfs unions
into one rewound view of the pool. `nas-at --list` shows what is mounted, `nas-at --release
<name>` tears it down. `ro,cp=N` means writes fail by construction rather than by policy.

It is **not** a globally atomic cut: each branch resolves its own nearest checkpoint. That is
acceptable because user-affinity placement keeps an account on one branch.

### 4.6 Versions: NILFS2 checkpoints

**The data branches are NILFS2, not btrfs.** NILFS2 is log-structured and creates a checkpoint
**continuously as segments are written**, so every change is captured without a timer deciding
the granularity. btrfs snapshots are point-in-time: whatever happens between two of them is
unrecoverable, and a file created and deleted inside that window leaves no trace. That gap is
the reason for the change.

Checkpoints live **outside the filesystem namespace**. They are listed with `lscp`, promoted to
permanent snapshots with `chcp ss` (which protects them from garbage collection), removed with
`rmcp`, and read by mounting: `mount -t nilfs2 -o cp=<n>,ro`.

Two consequences are worth stating because they contradict the earlier btrfs design:

1. **SnapRAID still needs the snapshot exclusion, for a different reason.** Checkpoints are not
   files, so parity does not see them — but the SMB window *mounts* up to 24 of them inside each
   branch at `snapshots/@GMT-…`, and each mount is a complete view of that branch. Without
   `exclude snapshots/`, `snapraid sync` walks every one and computes parity over roughly 24x the
   array. The inherited config excluded btrfs's dotted `.snapshots/`, which does not match the
   NILFS2 window directory; that mismatch was live and only harmless because promotion happened
   to be suspended, leaving the directory empty.
2. **Promotion is retention, and everything is promoted.** `nilfs_cleanerd`'s protection period
   is time-bounded and cannot express "keep forever", so `nas-checkpoint-promote` runs `chcp ss`
   over every checkpoint it finds. A promoted checkpoint is immune to collection, which means the
   collector has nothing to reclaim and **is not run on a timer at all**.

   **The cost, stated plainly: space grows monotonically with churn and is never returned.** That
   is the requirement, not a flaw, but it needs an honest failure mode — a full NILFS2 filesystem
   stops accepting writes — so `nas_branch_used_ratio` and `nas_checkpoint_snapshots` are exported
   and alertable. Also unmeasured: whether NILFS2 stays healthy at very large snapshot counts. At
   one checkpoint per 250 MB written, a terabyte of writes is ~4,000 snapshots.

**Measured checkpoint rate.** Writing 1000 MB to disk1 in 21 seconds produced 4 checkpoints:

```
1000 MB in 21s   ->   checkpoints 4 -> 8
```

So roughly **one checkpoint per 250 MB written, about one every 5 seconds under sustained write**,
and near-zero when idle (two checkpoints five minutes apart on a quiet filesystem). Count tracks
*activity*, not elapsed time, which is what makes "retain everything" affordable here where a
fixed timer would not be.

**The trap this exposes: do not blindly promote during bulk ingest.** A 427 GB migration generates
roughly 1,700 checkpoints, almost all of which capture *partial file-transfer states* of no value.
Promoting them pins that garbage permanently. `nas-checkpoint-promote` promotes everything it
finds by design, so the operational rule is to **stop its timer before a migration and start it
afterwards**; unpromoted checkpoints are then collectable.

#### Future opportunity: btrfs with btrbk

The btrfs path is **not discarded, it is parked**. Branch `btrfs-btrbk` is cut from `745ae71`,
the last commit before this change, and carries a minimal `modules/nixos/nas/btrbk.nix` —
package plus basic parameters (hourly, `snapshot_preserve = 48h 30d 12m`, one subvolume per
branch). Nothing is wired into a host; it exists so the alternative can be explored later
without reconstructing the pre-NILFS state.

It is worth revisiting because btrfs keeps four things NILFS2 gives up, and btrbk addresses the
weakest of them:

- **`send`/`receive`** for the section 10 node mirror, which is O(changes) rather than rsync's
  O(files), and which also replicates *history* rather than only the live tree.
- **Checksums on read**, so corruption is caught at access rather than at the next scrub.
- **Reflink**, which makes restructuring and deduplication nearly free.
- **Fine-grained purge**: a btrfs snapshot can be flipped read-write to strip a single path,
  which is exactly what NILFS2's whole-checkpoint `rmcp` cannot do.

What it would still cost is the reason for the change in the first place: btrbk snapshots are
point-in-time on a timer, so anything created and deleted between two runs leaves no trace.

#### The write tier must be NILFS2 too

**This is where versions are actually created.** Writes land on the SSD tier and only reach the
HDDs when the mover runs, so if the SSD branch were btrfs while the HDD branches were NILFS2,
every intermediate edit would be discarded before it ever touched a checkpointed filesystem. The
HDDs would record only the post-mover state, and continuous versioning would apply to precisely
the data that changes least.

So `sda4` (the write tier, section 4.1) is NILFS2 as well. This suits it: a log-structured
filesystem writes sequentially, which is what flash prefers, and its garbage collection costs no
seeks and — critically — never touches a spun-down HDD. The nightly GC window applies to the HDD
branches; the SSD can be collected freely.

`sda5`, the bcache read cache, is unaffected. It is block-level and below the filesystem, so it
has no bearing on versioning.

**The consequence, stated plainly: fine-grained history is bounded by the SSD.** Edit-by-edit
history lives on the write tier while the file is still there. Once the mover promotes a file to
a HDD, the HDD captures it as of that moment, and the intermediate versions survive only as long
as the SSD's checkpoints are retained. On a 120 GB SSD that is a real limit.

So "retain everything forever" holds for the HDD branches at mover granularity, and holds for
fine-grained edits only within the SSD's retention. Anyone relying on recovering a specific
intermediate save of an actively-edited file needs to know that window is finite. Whether the
mover should promote a file's *history* as well as its current contents is unresolved, and there
is no cheap mechanism for it: checkpoints cannot be transplanted between filesystems.

#### Exposing versions to SMB

Samba's `shadow_copy2` needs generations visible as directories, which NILFS2 does not provide
natively. Mounting each branch's checkpoint **inside that branch**, at
`/mnt/disks/<branch>/snapshots/@GMT-<ts>/`, makes the **single existing mergerfs** union them by
name — the same by-name union the btrfs design relied on.

```
shadow:mountpoint = /srv/nas        shadow:snapdir = /srv/nas/snapshots
shadow:basedir    = /srv/nas/data   shadow:format  = @GMT-%Y.%m.%d-%H.%M.%S
```

**`@GMT-` names are UTC, and `date -u -d` alone does not produce them.** `-u` sets `TZ=UTC` for
the whole process, so it parses `lscp`'s local timestamp *as* UTC and returns it unchanged — a
silent no-op that leaves every generation an hour off in BST. Convert through the epoch instead,
which also picks the right offset for the checkpoint's own date rather than today's:

```bash
epoch=$(date -d "$cpdate $cptime" +%s)
name=$(date -u -d "@$epoch" +@GMT-%Y.%m.%d-%H.%M.%S)
```

Verified on the pi: a August checkpoint at 14:29:32 local yields `13.29.32`, while a January one
at the same clock time yields `14.29.32`, since GMT has no offset.

Cost per exposed generation is **two kernel mounts**, a few KB — not a mergerfs process each. An
earlier estimate of 7.5 MB per generation was wrong: it assumed one mergerfs per generation to
union the branches, which mounting inside the branches avoids.

Only a **bounded rolling window** is exposed this way (default 24). That is what gives Windows
its native right-click Previous Versions with no client software, while keeping the mount count
predictable. Everything older is reached through the web tier, which mounts on demand.

**Verified end to end on the live array**, with real NILFS2 checkpoints on disk1:

```
/dev/mapper/nas-disk1 /mnt/disks/disk1/snapshots/@GMT-2026.08.19-03.16.09 nilfs2 ro,cp=2
/dev/mapper/nas-disk1 /mnt/disks/disk1/snapshots/@GMT-2026.08.19-03.11.02 nilfs2 ro,cp=1

ls /srv/nas/snapshots/   ->   @GMT-2026.08.19-03.11.02  @GMT-2026.08.19-03.16.09
```

Checkpoints mount read-only inside the branch under the exact name `shadow_copy2` expects, and
mergerfs surfaces them at pool level. `ro,cp=N` means a rewound view is unwritable by
construction rather than by policy.

**A plain checkpoint cannot be mounted. Only a snapshot can.**

```
mount -t nilfs2 -o cp=1365,ro /dev/mapper/nas-disk1 ...
  ->  Error while mounting: Invalid argument
```

`cp=N` succeeds only once that checkpoint has been promoted with `chcp ss`. This makes promotion
load-bearing rather than merely a retention policy: the SMB window, `nas-versions restore` and
`nas-at` all mount, so **none of them can reach a checkpoint that was never promoted**. It is also
why the migration's unpromoted checkpoints are unreachable as well as collectable, which is the
intended outcome there.

**nilfs-utils is pinned to 2.3.0, and on nixpkgs' 2.2.12 promotion is a silent no-op.** 2.2.12
inverts the `[DEVICE]`/`CNO` test in `bin/chcp.c`, so `nas-checkpoint-promote`'s
`xargs -n1 chcp ss "$device"` failed on **every** invocation, swallowed by `|| true`. The snapshot
count sat at 0 while the unit reported success — and since an unpromoted checkpoint is also
unmountable, nothing was retained *and* nothing was readable. Full write-up and reproduction in
`docs/nilfs-chcp-bug.md`.

Fixed upstream in `27bfa50c4`, released in 2.3.0; the overlay in `storage.nix` bumps to it.

**Promotion is suspended by a marker file, not by stopping the timer.** `systemctl mask` cannot be
used on a NixOS unit whose `/etc/systemd/system` entry is a store symlink, and a stopped timer is
restarted by the next activation — which is how a deploy mid-migration nearly pinned ~1,300
bulk-ingest checkpoints permanently. `nas-checkpoint-promote` therefore carries
`ConditionPathExists=!/run/nas-promote-suspended`; `touch` that file for a bulk copy and remove it
afterwards. A failed condition marks the unit skipped rather than failed, so it cannot break an
activation either.

**Timers must use `OnActiveSec`, not `OnBootSec`.** On a host whose uptime already exceeds
`OnBootSec`, the timer fires the instant activation installs it, so a `oneshot` that fails takes
`switch-to-configuration` to exit 4 and deploy-rs rolls the whole generation back. That is exactly
how the first `versions.nix` deploy failed.

**Operational note: every nilfs tool takes the device, never the mountpoint.** `lscp
/mnt/disks/disk1` fails with `cannot open NILFS ... No such device or address`, while `lscp
/dev/mapper/nas-disk1` works. This silently produced "promoted 0" until it was found.

**`nilfs_cleanerd` must actually be running or nothing is ever reclaimed.** Deleting checkpoints
frees no space by itself — `nilfs-clean` only signals a running collector, and reported
`No cleaner found` because none had been started. Under the retain-everything policy that is the
correct steady state — every checkpoint is a snapshot, so there is nothing to reclaim and no
collector runs. It matters only during a bulk migration, when the timer is stopped deliberately
and the unpromoted checkpoints do need collecting; start `nilfs_cleanerd` by hand for that
window, so collection never touches a spun-down disk unattended.

**Suspend promotion during bulk ingest.** At the measured rate, copying 427 GB creates ~1,700
checkpoints, almost all of them partial file-transfer states. Promoting those pins them
permanently. Stop `nas-checkpoint-promote.timer` before a migration and restart it afterwards;
unpromoted checkpoints are then reclaimed by the collector.

The earlier proof, before any disk was reformatted — two tmpfs mounts inside separate branches
unioned by name through the existing mergerfs mount:

```
mount -t tmpfs tmpfs /mnt/disks/disk1/snapshots/probe   # contains a.txt
mount -t tmpfs tmpfs /mnt/disks/disk2/snapshots/probe   # contains b.txt
ls /srv/nas/snapshots/probe/                            # -> a.txt  b.txt
```

mergerfs traverses submounts inside its branches, so checkpoint mounts placed there appear as
unified generations. This was tested before any disk was reformatted, because the whole
native-SMB half of the design depends on it.

### 4.7 Namespace and protection tiers

```
/srv/nas/data/users/<name>/           <name>:<name>, mode 0700
/srv/nas/data/users/<name>/.recycle/  Samba recycle bin, purged at 90 days
/srv/nas/data/shared/<group>/         root:nas-<group>, mode 2770
/srv/nas/snapshots/@GMT-.../          union of per-branch snapshots
/srv/cache                            Attic (p3)
```

Folders carry a **protection tier**, which is what generalises cleanly to multiple nodes:

- **Tier A**: snapshots, local parity, and (later) mirrored to another node.
- **Tier B**: snapshots and local parity, not mirrored.
- **Tier C**: none, disposable. Attic, thumbnails and scratch live here.

Every NAS unit carries `RequiresMountsFor=/srv/nas`. Until the array is unlocked, and if a
disk is absent or fails to unlock, nothing NAS-related starts and monitoring is untouched:
the pi remains a healthy Grafana and WoL node. **That is the normal state after every boot.**

## 5. Access and identity

### 5.1 Isolation

Isolation is layered, and the strongest layer is the kernel:

- **SMB and SFTP are kernel-enforced.** `smbd` forks per connection and `setuid()`s to the
  authenticated Unix user; `sshd`'s SFTP subsystem runs as the logged-in user. With homes
  owned `<name>:<name>` at mode 0700, the kernel denies cross-user access even if a share
  were misconfigured to point at the wrong directory. This cannot be bypassed by an
  application bug.
- **The web tier is kernel-enforced too, via per-user worker processes.** The obvious design —
  one service account that can read everybody's files, with the application checking paths —
  is rejected: a single path-traversal bug would then expose every account. Instead a small
  privileged dispatcher resolves `Tailscale-User-Login` through `/etc/nas/identity-map` and
  proxies the request to a **worker running as that Unix user**, a templated
  `nas-web@<account>.service` with `User=%i`, socket-activated on a per-user socket.

  The worker holds no privilege of its own, so a traversal bug in it changes nothing: the
  kernel refuses the open, exactly as it does for SMB. What stays trusted is only the
  dispatcher's header-to-user mapping — a few lines that never touch file contents — rather
  than an entire file browser, thumbnailer and upload path.

  Consequences, stated plainly: one process per *active* user costs memory on a 2 GB host, so
  workers must be socket-activated and exit when idle rather than run permanently. And the
  dispatcher must bind to loopback only, because `Tailscale-User-Login` is trustworthy solely
  as long as `tailscaled` is the only thing that can set it.

### 5.1.1 Isolation, as verified

Tested on the live array with two accounts, `maxnas` (uid 3001) and `nastest` (uid 3000):

| attempt | result |
|---|---|
| `maxnas` lists and reads its own home | works, 134 files |
| `nastest` lists `/srv/nas/maxnas` | `Permission denied` |
| `nastest` reads a file inside it | `Permission denied` |
| `nastest` traverses into a subdirectory | `Permission denied` |

**mergerfs runs as root**, so this deserved checking rather than assuming: with `allow_other`
and no `default_permissions`, FUSE leaves the decision to the filesystem, and a root-owned
daemon opening a branch file succeeds whatever the caller's uid. Measurement showed mergerfs
enforcing correctly, and `default_permissions` is now set as well so the **kernel** enforces
it regardless of mergerfs behaviour.

A real leak was found and closed this way. The migrated data initially sat at the **pool root**
owned `max:users` mode 0755, where every NAS account could read all 134 files. It now lives in
`/srv/nas/maxnas` at 0700. The lesson generalises: files arriving from elsewhere keep their
original ownership, so a migration must end with an explicit `chown` into an account home, and
nothing should ever be left at the pool root.

The pool root remains listable, so account *names* are visible. That is deliberate and
harmless — it is the same information the share list exposes — but no home is traversable.

Still to enforce, and **not** yet done: the web tier must scope every request to
`Tailscale-User-Login` and refuse paths outside that account's home. Unlike SMB and SFTP this
is application-enforced, so it is the one layer where a bug means real cross-user exposure.

Accounts are **declarative NixOS Unix users with explicit uids and gids**. Because
`users.mutableUsers = false` already, creating an account necessarily requires a git commit
and a `rebuild`, which is the approval gate, achieved with no portal and no extra
authentication system. `nas-user` proposes the Nix and sops edit for review; it does not
apply anything.

Explicit uids are **mandatory**, not stylistic: cross-node replication only preserves
ownership if uids match on every node, and retrofitting that later would be painful.

### 5.2.1 Minting an account

`nas-user <name> [--full-name ...] [--uid N]` picks the next free uid, refuses duplicates and
out-of-range uids, and **writes the account into `hosts/pi/default.nix`**. The declaration is
the persistent record: accounts live in git, not in a runtime database, so they survive
rebuilds and are reviewable in a diff.

uids are chosen **at random** from the free part of the range rather than sequentially, so an
account number reveals nothing about when it was created or how many exist.

The account is minted **locked**: Max never sets, sees or transports anyone's password.

1. Review, commit, `rebuild --host pi switch` — the commit **is** the approval gate.
2. `nas-enroll-issue <name>` prints a one-time token, stored only as a SHA-256 hash with an
   expiry (48 h by default).
3. The owner opens `http://enroll/` on the tailnet, enters the token and chooses their own
   password. That single action sets **both** the Unix password and the Samba one, which are
   otherwise separate databases and a common way to end up half-enrolled.
4. `tailscale share pi --email <their-account>` — a share, never an invite and never a tag, so
   the recipient reaches this machine and nothing else.
5. Grafana user at Viewer scope, **once authentication exists**.

The form refuses expired and mismatched tokens, enforces a minimum length, sleeps briefly on
every POST, and returns one generic message for a wrong token, an unknown account and a
malformed name alike, so it cannot be used to enumerate who has an account. The token is
consumed on success and deleted on expiry.

### 5.2.2 Hiding folders

Dropping a `.nashidden` file in any folder marks that folder and everything beneath it
`hidden` in the browse index. The web tier and shared dashboards filter on that column; **SMB
and SFTP are unaffected**, so the owner still sees their own files normally.

It is a marker file rather than a config option on purpose: the owner can hide or unhide a
folder over SMB without a rebuild, an approval, or any access to the Nix configuration. The
flag is recomputed on every index pass, including the incremental one, so removing the marker
unhides on the next run.

This hides from *browsing*, not from *storage accounting*: hidden folders still count toward
the owner's usage, since pretending otherwise would make quotas and capacity planning lie.

### 5.3 Tailscale

Access is granted by **sharing the pi** to each person's own Tailscale account, not by
inviting them to the tailnet and not by tagging their devices.

Confirmed from Tailscale's documentation:

- Share recipients **do not increase the tailnet's user count**, and no cap on the number of
  recipients is documented. The free Personal plan currently allows 6 users and has dropped
  its 100 device cap, but shares sidestep that limit regardless.
- Recipients reach "the shared machine, and nothing else". The two-tier requirement is
  therefore **structural**, enforced by Tailscale, rather than an ACL policy that has to be
  written correctly.
- Recipients use their own free account on their own tailnet, so Max never manages their
  devices and adding a device needs nothing from Max.
- Shared machines are quarantined by default: they answer incoming connections but cannot
  initiate into the recipient's tailnet. Harmless here, since SMB, SFTP and HTTP are all
  client-initiated.
- Revocation is revoking the share, which removes access for all of that person's devices at
  once.

Tags are used **only for the pi itself**. Using tags for end-user devices is explicitly
against Tailscale's guidance ("Do not use tags to authenticate end-user devices") and strips
the device of user identity, which breaks both revocation and auditability.

**Resolved: `tailscale serve` does inject identity.** Measured against a header-echo behind
`tailscale serve --http=8088`, a request from another tailnet device arrived with:

```
Tailscale-User-Login: MaxCarroll0@github
Tailscale-User-Name: MaxCarroll0
Tailscale-User-Profile-Pic: https://avatars.githubusercontent.com/...
X-Forwarded-For: 100.112.109.20
```

Plain HTTP works and needs no certificate; the HTTPS form blocks on cert provisioning unless
HTTPS is enabled for the tailnet. Requests by raw IP return 404, because the proxy keys on the
MagicDNS host, so anything in front of it must preserve the `Host` header.

This makes **Tailscale the identity provider**, and the account model follows from it:

- The web tier needs no passwords and no login form. `Tailscale-User-Login` is the identity,
  authenticated by the tailnet before the request arrives.
- Grafana uses `auth.proxy` against the same header, so per-user dashboard scoping comes free
  rather than needing its own accounts.
- **Sharing the device is the enrolment.** A share recipient reaching the web tier presents an
  identity that has never been seen before, so the account can be provisioned from that first
  request rather than minted in advance.
- Only **SMB** still needs a password of its own, because the protocol cannot use a header.
  That password is set by the owner on a page already authenticated by their Tailscale
  identity, so no enrolment token, no out-of-band secret and nothing for Max to transport.

Two things this rests on and which must be verified before relying on it: that the headers are
present for **shared** users and not only tailnet members (untested — it needs a second
account), and that nothing else can reach the listener, since the headers are trustworthy only
because `tailscaled` sets them. Bind the backend to loopback and never expose it on another
interface, or the headers become forgeable by anyone who can reach the port.

## 6. Unlocking

The array **never unlocks at boot**. `nas-unlock` on the **laptop** is the entire interface:
it calls the pi over Tailscale SSH to start `nas-unlock.service`, which runs
`clevis luks unlock` for each disk against the laptop's `services.tang` (bound to the
tailscale interface only), assembles bcache, mounts the branches and starts `nas.target`. It
reports back whether the array actually mounted. `nas-lock` is the reverse.

This defeats whole-machine theft: a stolen pi is inert unless the thief is also on the
tailnet with the laptop running. Manual triggering also removes Tang's usual fragility,
because if you are running the unlock then you are at your laptop, so the Tang server is up
by construction. A passphrase keyslot stored in sops is the fallback for when the laptop is
genuinely unavailable. There is deliberately **no automatic keyfile**, which would unlock the
array at boot and render Tang decorative.

Privilege follows the pattern `modules/nixos/storage.nix` already uses for `luksVaults`: a
`security.sudo` NOPASSWD rule on the pi scoped to exactly that unit and nothing broader. On
the laptop it is wired to a desktop entry and a Hyprland keybind, so it is one button. A
Grafana alert fires while the array is locked, so the state is never silently wrong.

**Cost, stated plainly:** after every power cut the shares are down until Max presses the
button.

## 7. Deletion and recovery

**There is no recycle bin.** It was removed: a checkpoint taken before a deletion still contains
the file, so continuous versioning *is* deletion recovery, and `vfs_recycle` plus a 90-day purge
timer was a second mechanism covering the same ground. One mechanism, not two.

The one thing recycle caught that checkpoints do not is a file created and deleted between two
checkpoints. With NILFS2 that window is the segment write interval rather than a timer, so it is
far narrower than it would be with periodic snapshots — but it is not zero.

- **Restore a version**: `nas-versions list <path>` reads the index; `nas-versions restore` mounts
  exactly one checkpoint read-only, copies the file out, unmounts. Recent history is also visible
  natively in Windows Explorer via Previous Versions (section 4.6).
- **Rewind a folder**: the web tier presents a whole directory as of a chosen point. Writes to it
  are impossible rather than forbidden — the checkpoint is mounted `ro` and an unpromoted
  checkpoint cannot be mounted writable at all. Restoring is an explicit copy forward into the
  live tree, so the live tree stays the only writable surface.
- **Permanent delete**: see the limitation below.

**Permanent delete is coarser on NILFS2 than it would be on btrfs.** `rmcp` removes a whole
checkpoint; there is no way to strip one path from one checkpoint, whereas a btrfs snapshot can be
flipped read-write and edited. So purging a file from history means deleting every checkpoint that
contains it, which discards unrelated history in that window. **Unresolved:** whether that is
acceptable, or whether purge should be defined as live-tree-only with history expiring naturally.

Note that `shred` and `wipe` are **ineffective in this stack** and must not be relied upon: a
log-structured filesystem never overwrites in place, and the SSD's flash translation layer
relocates writes regardless. Disposing of a drive is covered by LUKS, not by file deletion.

### 7.1 Ideas the version index makes possible

Both are unbuilt. They are recorded because the index changes what is feasible, not because they
are scheduled.

**Opting a file out of versioning.** NILFS2 checkpoints are whole-filesystem, so a file cannot be
excluded from one. The mechanism therefore has to be placement, not policy: keep a branch that is
**not** NILFS2 — plain ext4 or xfs — in the mergerfs pool, and move opted-out files there. mergerfs
unions by name, so the file stays at the same path in `/srv/nas` while nothing about it is
versioned and its blocks are freed on delete like any ordinary filesystem. Good candidates are
caches, transcodes, downloads that can be re-fetched, and anything large and derived.

**Retroactively reclaiming a deleted file's history.** Today purging one file from history means
deleting every checkpoint containing it, which discards unrelated history in the same window. The
index makes this *decidable* rather than all-or-nothing: it knows exactly which checkpoints hold
versions of a given inode, so it can identify checkpoints whose only content is that inode. Those
can be removed with `rmcp -f` with no collateral loss, and the collector then reclaims the space.

This is common in practice: a large file written on its own occupies whole checkpoints by itself.
Deleting a 40 GB video and reclaiming its history would work cleanly, while a file edited alongside
others in the same checkpoint would not — and the index can say which case applies before anything
is removed, rather than after.

Both need a way to answer "which inodes does checkpoint N contain", which `dumpseg` provides
offline. That is the right use for a debugging tool: an occasional, deliberate audit rather than a
routine path.

Note that `shred` and `wipe` are **ineffective in this stack** and must not be relied upon:
btrfs is copy-on-write so overwriting a file writes to new blocks and leaves the originals
intact, and the SSD's flash translation layer relocates writes so overwrite-in-place is
meaningless. Disposing of a drive is covered by LUKS, not by file deletion.

## 8. Failure envelope

Not all failures are equal, and the differences are worth internalising.

| What fails | Data lost | Notes |
|---|---|---|
| Parity disk | **None** | No user data lives on it. Replace and re-sync. Unprotected during the rebuild. The best disk to lose, and conveniently it is the SMR one. |
| One data disk | Files written since the last sync | `snapraid fix` reconstructs the rest from parity. |
| Data disk plus parity | That data disk's contents | Parity cannot help once it is gone. |
| Two data disks, single parity | Both disks' contents | Survivors remain intact and directly readable. |
| SSD read cache (p5) | **None** | `writearound` means no dirty data. Detach and continue. |
| SSD write tier (p4) | Files not yet moved to the array | Bounded by the mover's 24 hour backstop. |
| Root partition (p2) | None (rebuildable from the flake) | The SSH host key must be backed up, since sops decryption depends on it. |
| Attic (p3) | None that matters | Disposable by design. |

Asymmetries worth noting:

- **A bigger data disk loses more**, roughly in proportion to used space.
- **Folders are never split across disks**, so a loss reads as "that folder is gone" rather
  than every file being partially corrupt. That is a far better recovery position and is a
  direct consequence of the placement policy.
- **User affinity concentrates the blast radius.** Because `mspmfs` keeps a user on one
  drive, losing a disk tends to cost most of *one* person's data rather than a slice of
  everyone's. That is the deliberate trade for one-user-one-disk browsing and spin-down; the
  alternative spreads the pain thinner but touches every account.
- SnapRAID parity reflects the **last sync**, not the current state. Files created since are
  unprotected. This is materially blunted because the NAS is a backup *target*: a photo not
  yet synced here still exists on the phone that uploaded it.
- SnapRAID's **content files** must exist on at least two devices or reconstruction is
  impossible. Three copies are kept, on both data disks and root.
- **LUKS header backups** for every disk (`cryptsetup luksHeaderBackup`) are stored in sops. A
  corrupted header is total, unrecoverable loss of that disk.

## 9. Growth policy

For single parity, `usable = sum(all disks) - largest disk`.

| Purchase | Disks (TB) | Parity | Usable | Efficiency |
|---|---|---|---|---|
| nothing (today) | 1, 2, 4 | 4 | 3 TB | 43 % |
| **2 x 8 TB** | 1, 2, 4, 8, 8 | 8 | **15 TB** | 65 % |
| 1 x 8 TB only | 1, 2, 4, 8 | 8 | 7 TB | 47 % |
| 1 x 16 TB instead | 1, 2, 4, 16 | 16 | 7 TB | 30 % |
| 2 x 12 TB | 1, 2, 4, 12, 12 | 12 | 19 TB | 61 % |

- **2 x 8 TB CMR is the correct next purchase**: 15 TB usable, tolerates one disk failure,
  fills all five SATA ports, and moves parity onto a CMR drive. That demotes the SMR 4 TB to
  a data disk, which is where it belongs, since data disks see far lighter write loads than
  parity.
- **Buy in matched pairs, never one large drive.** A single 16 TB costs about the same as two
  8 TB and yields less than half the usable space, because the whole 16 TB is consumed by
  parity. This is the most valuable rule here.
- **Split parity is rejected.** Parity must be at least as large as the largest data disk,
  and 4 + 2 + 1 = 7 TB is less than 8 TB, so the existing drives cannot jointly cover an 8 TB
  data disk.
- **Committed policy: stay single-parity. Revisit dual parity only at 6 or more disks.**
- **No retirement plan for the 4 TB.** Its SMART is clean; SMR is a write-performance
  characteristic, not a reliability one, and as a data disk it is in an appropriate role. The
  only future reason to evict it is SATA port pressure.
- **No spare parity-disk space for Attic.** That only exists if the parity disk exceeds the
  largest data disk, which costs far more usable space than the scrap is worth.

Adding a data disk later is genuinely trivial: format it, add one `data` line, add it as a
mergerfs branch, run `snapraid sync`. No rebalance, no downtime, no data movement. Because
`pfrd` weights placement by free space, a new empty disk naturally attracts new folders and
the array self-balances over time.

## 10. Multi-node target (designed for, not built)

Cross-node redundancy **cannot** come from SnapRAID, because parity is node-local and a whole
node loss is exactly the correlated failure local parity cannot cover. It must be a
replication layer.

The chosen model is **whole-node mirroring** over the tailnet: one node mirrors another, and on
unequal nodes the larger node's excess capacity becomes Tier C (Attic, scratch, un-mirrored bulk).

**The transport must be block-level, not file-level.** This is the key correction: a file-level
copy (rsync) walks the live tree and therefore replicates *current state only*, losing every
version. A **block-level** copy of the device carries the log itself, so checkpoints cross the
wire with it.

| failure | mechanism | preserves history |
|---|---|---|
| single local disk | SnapRAID parity | **no** — parity is computed over files, so checkpoints are invisible to it |
| whole node | block-level replication | **yes** |

Candidates are `bdsync` or `blocksync`, which compare block hashes and send only what changed, so
replication stays incremental without needing filesystem support. NILFS2 suits this unusually
well: being log-structured, a crash-consistent block image is exactly what it is designed to
recover from, so a copy taken without quiescing should still mount.

Two consequences worth stating:

- **SnapRAID does not protect version history.** A single disk failure rebuilds the live tree onto
  a fresh filesystem and every checkpoint on that disk is gone. Local parity and history
  preservation are separate problems with separate mechanisms.
- Block-level replication needs a target device at least as large as the source, and replicates
  free space and garbage alike, so it is less efficient than `send`/`receive` would have been.

This is unbuilt, but the mechanism is now identified rather than an open question.

The current design already satisfies the prerequisites. The invariants to preserve from now
on are:

1. Explicit, stable uids and gids on every node.
2. Timestamp-synchronised, immutable snapshot names across branches.
3. Folder-granular placement, with folders never migrating between disks.
4. Share definitions derived from one declarative account and folder table, so either
   topology can be generated from the same source.

## 11. Observability

- **Per-user disk usage**: a nightly `du` at depth 2 per home across branches, excluding
  `snapshots/`. Nightly because a sweep spins every disk.
- **Per-user network usage**: nftables byte counters keyed on tailnet source address,
  extending the existing `tailscaleMetrics` collector in
  `modules/nixos/monitoring/textfile.nix` rather than adding a new mechanism.
- **New panels**: bcache hit ratio and bypass counters, SnapRAID sync age and scrub results,
  per-drive SMART including `sdc`'s CRC counter, and array-locked state.
- **Grafana scoping**: anonymous access is disabled. Max is admin; NAS users are **Viewers**,
  which in Grafana OSS cannot edit dashboards or use Explore. The existing Overview, Metrics
  and Archive folders are granted View to all, so they remain visible but not editable. Each
  account additionally gets a `NAS / <name>` folder holding one provisioned dashboard whose
  queries have that user's label baked in, with folder permissions restricted to them, set as
  their home dashboard. The others-total is
  `sum(nas_user_bytes) - nas_user_bytes{user="<name>"}`, which yields the aggregate and never
  the per-user breakdown.

### 11.0 Grafana must be fixed before anyone is shared in

**Current state, measured:** Grafana listens on `0.0.0.0:3000`, port 3000 is open on
`tailscale0`, and `auth.anonymous` grants `Admin`. Any tailnet device gets full admin,
including every dashboard and the ability to edit alerting. That is fine while the tailnet is
only Max's own machines and **unacceptable the moment the pi is shared with anyone**. Treat it
as a gate on Stage 3 onboarding, not a later polish item.

The fix, using the identity headers proven above:

1. `http_addr = "127.0.0.1"` and drop 3000 from the `tailscale0` firewall.
2. Disable `auth.anonymous`; enable `auth.proxy` with `header_name = Tailscale-User-Login`,
   `auto_sign_up = true`, and a default role of `Viewer`.
3. Front it with `tailscale serve`, which terminates on the tailnet and sets the header.

**The trap:** `auth.proxy` trusts the header absolutely. If *anything* other than
`tailscaled` can reach the listener, a user simply sends `Tailscale-User-Login: someone-else`
and becomes them. So the reverse proxy must be loopback-only, and if nginx stays in the path it
must explicitly clear any client-supplied `Tailscale-*` headers rather than forwarding them.
Binding to `0.0.0.0` with `auth.proxy` enabled would be strictly worse than the anonymous
access it replaces, because it would look authenticated while being trivially forgeable.

Per-user scoping then follows from the same header, and the "users see only their own usage
plus others' aggregate" requirement in section 1 becomes a dashboard-variable question rather
than an authentication one.

### 11.1 How the application tier plugs in

The per-user worker pattern is **application-agnostic on purpose**, because the app itself is
still undecided (section 12). `local.nas.web.workerCommand` is the seam:

```nix
local.nas.web.workerCommand = "${pkgs.filebrowser}/bin/filebrowser -r %h";
```

`%h` expands to that account's home. The requirement on any candidate is narrow: accept a
socket-activated listener and serve one directory tree. It needs **no** notion of users,
logins, permissions or multi-tenancy, because it only ever runs as one account and only ever
sees one home.

That is the point of the design. Whatever app is chosen, its authentication and access-control
code becomes irrelevant, and its bugs cannot cross an account boundary — the kernel refuses.
Selecting an application therefore stops being a security decision and becomes a usability one,
which is a much easier bake-off to run.

The bundled `nas-web-worker.py` is a placeholder, not a candidate: enough to prove the pattern
and browse files, to be replaced by the real application.

## 12. Application tier: undecided by design

The application tier is **deferred to a measured bake-off** rather than chosen up front, run
on the real pi behind `MemoryMax` with synthetic load (bulk photo upload, many small files,
concurrent clients) and RSS, CPU and latency recorded into the existing Prometheus.

Hard gate for every candidate: **automated phone photo backup and automated PC folder
backup.**

Browsing performance is **no longer a differentiator**, because `nas-index` (section 4.5.1)
is built regardless and supplies the tree, thumbnails and version counts to whichever server
is chosen. That removes the pressure toward a heavyweight candidate and returns the decision
to RAM and backup-client support, which favours the lighter options.

Note that SMB has no server-side thumbnail protocol at all, so Windows and macOS build
previews by reading whole files regardless; thumbnails only pay off inside a web tier that
serves them. Whichever application wins, its thumbnail cache points at `thumbs/` on the SSD
partition, a sibling of `data/` and `snapshots/` and therefore invisible to users, as Tier C
excluded from parity and snapshots since it is regenerable. At roughly 15 KB per 256 px WebP,
100k photos is about 1.5 GB.

| Candidate | Approx RSS | Notes |
|---|---|---|
| SFTPGo plus PhotoSync / FolderSync clients | ~80 MB | Implements SFTP, WebDAV and its web UI over a filesystem abstraction, so `nas-index` can back all three. SFTP is offset-based so uploads resume. Cheapest on RAM by a wide margin. |
| OpenCloud (`services.opencloud`, 3.7.0 on 26.05) | ~300-450 MB | Official iOS, Android and desktop apps; native chunked upload; PosixFS keeps files plain on disk so Samba serves the same tree. Its native index would make `nas-index` redundant for the web tier. Best feature fit, RAM is the question. |
| Seafile | ~300-500 MB | Chunked dedup is its data model, but the opaque block store breaks SMB co-access and folder metrics, and it is not in nixpkgs. |
| Syncthing | ~80-150 MB | Tiny, plain files, device pairing matches the enrolment model. Strong for Android and PCs, weak for iPhone (needs paid Möbius Sync). No UI to serve an index to. |

## 13. Monitoring trim

**Superseded by what was actually done. See `docs/monitoring.md` for the record.** This
section originally proposed moving Tempo to the desktop and tuning Loki; both were deleted
instead, because Tempo had received zero traces in its entire life and Alloy existed only to
feed the two of them.

Done and measured:

- Loki, Tempo and Alloy removed: **+150 MB** verified against `MemAvailable`, with
  non-overlapping distributions. Logging is now local-only, explored over ssh.
- Series pruned and scrape cadence split into live (1 s), slow (60 s) and inventory (1 h)
  classes: hires heap **144 MB to 79 MB**. Memory and network stayed at 1 s because that is
  what thrashing analysis needs; filesystem dropped to inventory.
- `below` retention cut from 30 days to 1, freeing ~16 GB of root.

Outstanding: the VictoriaMetrics migration (est. ~380 MB) and a Grafana trim.

## 14. Items to resolve during implementation

- **SnapRAID sync memory, now measured: 545 MB peak, not the ~200 MB estimated.** The full
  post-migration sync of the 2.9 TB array (434 GB of data) took 1h 10m wall for 45m of CPU,
  reading 864 GB and writing 850 GB, and peaked at **545.2 MB with 68.7 MB of swap**. On a 2 GB
  box that is a quarter of RAM, so the `MemoryMax` this item calls for is more necessary than the
  original estimate suggested, and 81% of the wait time was parity I/O rather than hashing.
- **SnapRAID sync hardening**: the sync unit must run a pre-sync `snapraid diff`, abort when
  deletion or modification counts exceed a threshold, refuse to sync when a disk is missing
  or SMART-degraded, and scrub only against a synced array. SnapRAID itself offers only the
  binary `--force-empty` and no configurable threshold, so the threshold logic is ours to
  implement.
- **Spin-down versus drive temperature**: `modules/nixos/storage.nix` warns that
  node_exporter's hwmon collector reads `drivetemp` on every scrape and resets the spin-down
  timer, and offers `local.monitoring.exporter.hwmonChipExclude`. Excluding the NAS drives
  costs their temperature metric. The pi's fan control is currently disabled (3-pin fan) so
  nothing consumes those temperatures today, but this is a trade to make explicitly rather
  than by accident. The same applies to smartd, which needs `-n standby`.
- **Verify** the btrfs preferred-metadata claim in section 4.5 and the Tailscale plan limits
  in section 5.3 before relying on either.
- **`nas-index` implementation language and footprint.** It must hold to tens of MB resident
  on a 2 GB box. The `find-new` and `send --dump` outputs are line-oriented text, so parsing
  is trivial in any language; the constraint is runtime overhead, not parsing difficulty.
- **Whether SFTP moves from `sshd` to SFTPGo.** Doing so lets `nas-index` back SFTP browsing,
  but downgrades SFTP isolation from kernel-enforced to app-enforced. Decided at Stage 7.

## 15. Implementation stages

| Stage | Content | Status |
|---|---|---|
| 0 | **This document.** Written before any measurement or code, and updated by every later stage. | **done** |
| 1 | Measure and prepare. Confirm the `sdd` passphrase, unlock read-only, measure fill, record a checksum manifest. Replace `sdc`'s SATA cable, run `smartctl -t long` on all three, re-read the CRC counter. *Gate: the `sdd` fill number decides the migration path.* | **done bar the cable** — passphrase confirmed, unlocked read-only, 425 GB measured, gate resolved to the simple path; SMART baseline in section 3; checksum manifest still to record |
| 2 | Storage. Image and repartition the SSD offline; `modules/nixos/nas/storage.nix` with LUKS, Clevis/Tang, unlock units, bcache, btrfs, mergerfs, mover, snapshot timer, SnapRAID and the degraded-mode guard. Execute the migration. | **module written**, mergerfs pool + SnapRAID sync/scrub timers; LUKS/Tang/bcache/mover and the **migration** still to do |
| 3 | Accounts and access. `accounts.nix` and `samba.nix`, `nas-user`, Tailscale device sharing, ACL reference. | **modules written**; `nas-user` and the Tailscale sharing runbook outstanding |
| 4 | Prefetch, browse index and metrics. `nas-prefetch`; `nas-index` (SQLite store, `find-new` reconciler, snapshot-diff version counter, thumbnailer); the metadata warmer; the new collectors; per-user dashboards; Grafana authentication. | `nas-index` and the metadata warmer **written and exercised**; `nas-prefetch`, dashboards and Grafana auth outstanding |
| 5 | Attic on `/srv/cache`, nginx vhost, `attic watch-store` on laptop and desktop, substituter for Max's hosts only. | blocked on Stage 2 storage |
| 6 | Monitoring trim. | **done** — see `docs/monitoring.md`; ~800 MB freed, `MemAvailable` median 500 MB to 747 MB |
| 7 | Application-tier bake-off and adoption. |
| 8 | Follow-ons: offsite backup, 3-node mirror, bidirectional sync, the 2 x 8 TB purchase, the SSD upgrade with LVM. |

### Build progress

| disk | role | state |
|---|---|---|
| `sdb` | `disk2` | LUKS2 + btrfs, mounted `/mnt/disks/disk2`, holds the verified 427 GB copy |
| `sdc` | parity | LUKS2 + btrfs, mounted `/mnt/parity`, parity built and verified |
| `sdd` | `disk1` | LUKS2 + **NILFS2**, mounted `/mnt/disks/disk1`, receiving the copy back from `disk2` |

Phase 1 verified NILFS2 on `disk1`: checkpoints appear continuously, `chcp ss` retains them,
and a deleted `loadtest/` tree was recovered from three checkpoints seconds apart. Phase 2 is
the copy back from `disk2` onto NILFS2, running as `nas-phase2.service`, with
`nas-checkpoint-promote.timer` **stopped** so its bulk-ingest checkpoints stay collectable.

Remaining for Stage 2: finish the copy, reformat `disk2` as NILFS2 and set its `fsType`, then
re-run `snapraid sync` and start the promote timer.

Every disk uses one passphrase, held only in `secrets/nas.yaml`, which is encrypted to the
primary and laptop age keys and **deliberately not the pi's**. A stolen NAS host therefore
cannot decrypt its own disks, which is what makes the manual unlock in section 6 meaningful
rather than decorative.

### Deploying storage changes

**Changing the mergerfs mount options requires the pool to be unmounted first.** NixOS reloads
a mount unit whose options changed, and a busy FUSE mount cannot be reloaded in place, so
activation fails with `Failed to reload srv-nas.mount` and rolls back. Adding
`default_permissions` hit exactly this.

```bash
sudo umount /srv/nas     # or nas-lock
deploy-request --host pi switch
sudo mount /srv/nas      # or nas-unlock
```

This costs nothing operationally, since the array is `noauto` and manually unlocked anyway:
lock, deploy, unlock is already the intended sequence.

**Emptying a data disk needs a one-off `--force-empty`, and it must stay one-off.** After disk2
was reformatted, `snapraid sync` refused to run:

```
WARNING! All the files previously present in disk 'disk2' ... are now missing or have been rewritten!
This could occur when some disks are not mounted in the expected directory.
If you want to 'sync' anyway, use 'snapraid --force-empty sync'.
```

That guard is the one thing standing between an accidentally unmounted disk and parity being
overwritten with the absence of its data. Run the override by hand for the migration:

```bash
systemd-run --unit=nas-sync-once --collect --nice=15 --property=IOSchedulingClass=idle \
  snapraid -c <conf> --force-empty sync
```

**Do not add `--force-empty` to `nas-snapraid-sync.service`.** Baking it in disables the check
permanently, so a later unmounted branch would silently destroy its own recovery path.

**Never move files while `snapraid sync` is running.** It aborts with
`Missing file ... WARNING! You cannot modify files while running` and the parity pass is
wasted — 25 minutes and 341 GB of writes, in the case that taught us this. Let the sync finish,
or stop it, before reorganising the tree.

### Module status

`modules/nixos/nas/` is imported by `hosts/pi/default.nix` and builds, contributing **zero
systemd units** because `local.nas.enable` defaults false. Every `config` block sits behind
`mkIf`, so nothing changes on the pi until storage exists.

| file | provides |
|---|---|
| `accounts.nix` | `local.nas.accounts`, explicit uids 3000-3999, homes 0700, uid-uniqueness assertion |
| `samba.nix` | one private share per account, `valid users` scoped to the owner, SMB3 + required encryption, bound to `tailscale0`, `vfs_recycle` |
| `storage.nix` | mergerfs pool with the placement policy from section 4, SnapRAID config, sync and scrub timers that no-op unless every branch is mounted |
| `index.nix` + `nas-index.py` | SQLite browse index, `find-new` incremental scan, version counter, thumbnailer, per-user usage metrics |
| `cache.nix` | metadata warmer, run inside the SnapRAID window while disks already spin |
| `nas-user.py` | proposes an account (random uid in 3000-3999, the Nix block, the sops and `smbpasswd` steps) and applies nothing |
| `checkpoints.nix` | `nas-checkpoint-promote` (retention), the `@GMT-` window for Samba, `nas-at` time travel, checkpoint metrics |
| `versions.nix` | one `fatrace` watcher per NILFS2 branch, the ingest timer, `nas-versions list`/`restore` |

Metrics exported for dashboards, all read from the index rather than the array so no exporter
ever wakes a disk: `nas_user_bytes`, `nas_user_files`, `nas_user_directories`,
`nas_metadata_warm_entries`, `nas_metadata_warm_seconds`,
`nas_metadata_warm_timestamp_seconds`. The `NAS usage` dashboard (uid `nas-usage`, in the
metrics folder) charts totals, per-account usage and warm-pass age.

**The dashboard is fleet-wide, not per-user.** Section 1's requirement that each person sees
only their own usage plus an aggregate of everyone else needs Grafana authentication and
per-user scoping, which is not built: today's Grafana is anonymous-admin on the tailnet. Until
that lands, treat these panels as an operator view only, and do not share the Grafana URL with
NAS account holders.

Built and inert is **not** the same as working: enabling these against real disks will exercise
the mergerfs option string, the SnapRAID layout and the Samba share syntax for the first time.
`nas-index` is the exception — its scan, version counter and metric output were exercised
against a scratch tree.

`nas-prefetch` is deliberately unwritten. It needs fanotify `FAN_OPEN` via raw `ctypes`
syscalls and `CAP_SYS_ADMIN`, so it cannot be tested without root and real branch mounts, and
an untested privileged daemon with feedback-exclusion logic is a poor trade. It is a cache
optimisation only: the NAS is correct without it, merely colder on first access.

### Migration, preserving `sdd`

`sdc` and `sdb` are wipeable. `sdd` holds the data to keep and is also wanted as a data disk.
The source is never written until its copy is verified, so the data always exists in two
places:

1. Replace `sdc`'s SATA cable. Build parity on `sdc` and data disk 2 on `sdb`.
2. Unlock the existing `sdd` LUKS with its current passphrase, mount read-only, copy into
   `/mnt/disk2/data`, and verify against a checksum manifest.
3. Only then wipe `sdd` and bring it up as data disk 1.

**Gate:** if `sdd` holds more than about 950 GB it will not fit on `sdb` alone. The fallback
stages the copy onto `sdc` as a plain filesystem, rebuilds `sdd` and `sdb` as the data disks,
copies back, then wipes `sdc` into parity. Two copies, works up to about 3 TB.

**Gate resolved: the simple path applies.** `sdd1` is LUKS over **ext4**, 1.8 TB, holding
**425 GB (25% full)**. That fits `sdb` (931 GB) with room to spare, so no staging through `sdc`
is needed.

| directory | size |
|---|---|
| `v` | 195 G |
| `yt-batch-downloads` | 168 G |
| `downloads` | 62 G |
| `.Trash-1000` | 1.1 G |
| `yt-batch` | 436 K |

Measured by unlocking read-only, which is safe to repeat:

```bash
cryptsetup luksOpen --readonly --key-file=<key> /dev/sdd1 sdd_ro
mount -o ro,noload /dev/mapper/sdd_ro /mnt/sdd_ro
```

`noload` matters: a plain `-o ro` mount still replays the ext4 journal, which writes to the
disk whose data must be preserved. `cryptsetup` is not in the pi's system PATH (nothing uses
LUKS yet), so it has to be called by store path until `storage.nix` is enabled.

Note `.Trash-1000` is 1.1 GB of already-deleted files and `yt-batch-downloads` is largely
re-obtainable, so the volume that genuinely must survive the migration is closer to 260 GB.

## 16. Runbooks

To be filled in as each stage lands: adding an account, sharing the pi to a new person,
unlocking and locking, recovery order (freeze remote access and scheduled sync/scrub *first*,
per the SnapRAID manual), replacing a failed drive, promoting a new drive to parity, and
decommissioning a drive with `cryptsetup luksErase`.

## 17. Summary of accepted limitations

Stated plainly so none of them is a surprise later:

1. Files on the SSD write tier are unprotected until the mover and the nightly sync run.
2. Deletion is logical only; snapshots retain purged files until retention expires.
3. `nas-index` backs interactive browsing on any server that implements its own filesystem
   abstraction (SFTPGo's web, WebDAV and SFTP). Samba would need a bespoke VFS module, not
   planned, so SMB browsing relies on the block cache, where metadata residency is
   effectively but not provably permanent. Machine-driven sync access stays authoritative
   against the filesystem regardless, since a stale listing can make a sync client re-upload
   or skip files.
4. After a power cut the shares stay down until the unlock button is pressed.
5. The web tier's isolation depends on the application, not the kernel. SMB and SFTP do not.
6. This NAS is not a backup, and has no offsite copy until Stage 8.
7. Losing the whole pi loses the data's confidentiality protection only against drive-level
   theft, not against an attacker who also has the laptop and tailnet access.
