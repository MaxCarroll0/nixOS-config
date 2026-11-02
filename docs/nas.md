# Pi NAS: design and architecture

Design-of-record for turning `pi` into a shared, encrypted, observable family NAS while
keeping it the always-on Grafana and Wake-on-LAN node it already is.

**Status: stages 1-6 built; the array holds live data and is versioned.** Storage, checkpoints,
per-file history control (4.6), parity, SMB, the browse index, prefetch and the Attic cache are deployed and
exercised against the real disks. What remains is onboarding anyone other than Max (stage 3's
enrolment and Tailscale sharing, gated on real per-request identity), the application-tier choice
(stage 7) and the offsite follow-ons (stage 8). Section 15 carries the per-stage detail, and
section 19 records the time autoUpgrade silently uninstalled the lot. Every later stage updates
this document as decisions are settled by measurement rather than assumption.

Decisions revised during design, so the original write-up is not the current one: placement
became user-affinity (`mspmfs`) with automatic overflow rather than proportional spread
(4.3); the browse index became a required bespoke component rather than something inherited
from the application tier (4.5.1); and section 13 was superseded by what was actually
deployed.

## NAS history references

Per-file history control (4.6, TODO list in [`nas-history-todo.md`](nas-history-todo.md)) builds on:

- D. S. Santry, M. J. Feeley, N. C. Hutchinson, A. C. Veitch, R. W. Carton, J. Ofir, "Deciding when
  to forget in the Elephant file system", SOSP '99, doi:10.1145/319151.319159. Source for
  landmarks, pins, discontinuities and the undecided age-graded resolution.
- A. Rohner, NILFS2 garbage-collection policies, diploma thesis, TU Wien 2018,
  <https://repositum.tuwien.at/handle/20.500.12708/3045>, and his cost-benefit GC series on
  linux-nilfs, <https://www.mail-archive.com/linux-nilfs@vger.kernel.org/msg02663.html>.
- nilfs-utils `lib/gc.c`, `nilfs_vdesc_is_live`: the liveness rule the history patch extends.
- btrbk retention policy and macOS Time Machine thinning: the age-based schemes the TODO compares
  against.

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

Five disks, four of them on SATA. Device letters have shifted since this table was first written,
so the **serial** is the identity that matters; `local.nas.storage.dataDisks` addresses them by
LUKS UUID for the same reason.

| Device | Serial | Size | Model | Power-on | Realloc / Pending / Uncorrectable | UDMA CRC | Load cycles | Role |
|---|---|---|---|---|---|---|---|---|
| `sda` | `PBEHHBB250409022817` | 120 GB | Patriot Burst Elite (USB SSD) | n/a | n/a | n/a | n/a | root, Attic, write tier, read cache |
| `sdb` | `S1G2G7X4` | 1 TB | ST1000VM002-1CT162 (CMR, 5900 rpm) | 17,864 h | 0 / 0 / 0 | 1 | 11,342 | `disk3` (see below) |
| `sdc` | `WFN0CDAX` | 4 TB | ST4000DM004 (**SMR**, 5425 rpm) | 10,939 h | 0 / 0 / 0 | **329** | 13,796 | parity (interim) |
| `sdd` | `S5100F1Q` | 1 TB | ST1000VM002-1ET162 (CMR, 5900 rpm) | 723 h | 0 / 0 / 0 | 0 | 213 | `disk2` |
| `sde` | `Z4Z9WYDV` | 2 TB | ST2000DM006 (CMR, 7200 rpm) | 12,217 h | 0 / 0 / 0 | 0 | 49,054 | `disk1` |

All four HDDs report `PASSED` at 29-35 °C, and none has a reallocated, pending or
offline-uncorrectable sector. No drive warrants a retirement plan on health grounds, including the
SMR one. The three-column `Realloc / Pending / Uncorrectable` summary above is **not** a complete
health statement, though: it misses lifetime counters like `184 End-to-End_Error` and
`187 Reported_Uncorrect`, which is how `sdb` was first recorded here as clean when it is not.
See "`sdb`'s SMART history" below. Re-read from the metrics store rather than waking a disk:

```bash
curl -s --get --data-urlencode 'match[]=drive:health_ok{instance="pi"}' \
  --data-urlencode 'start=-1h' http://127.0.0.1:9090/api/v1/export
```

Use `export`, not an instant query: these series are on a 5-minute cadence and instant-query
lookback will miss them inside the gap.

**`sdc`'s 329 CRC errors are a link fault, not the drive, and they have stopped accruing.** Its
media is pristine, and UDMA CRC counts link-layer failures between controller and drive, so the
cable or connector is the suspect. The count was **also exactly 329 at 10,295 power-on hours**,
644 hours earlier: a historic fault, not a live one. The normalised value has recovered from a
worst of 107 back to 200, which agrees. Still replace the SATA cable before trusting this disk
with parity long-term, then confirm the counter stays flat rather than assuming the swap fixed
anything.

`sde`'s 49,054 load cycles are worth watching but not alarming: the ST2000DM006 is rated in the
hundreds of thousands, and the spindown work already stopped exporters from waking the disks. This
is the figure previously recorded against `sdd`; it is the same physical drive, relettered.

Ignore the raw `Seek_Error_Rate` figures. Seagate packs two counters into that field; the
normalised values are the meaningful ones and are healthy.

**`sdb`'s SMART history: one historic bad sector, not a cable and not a dying disk.** `sdb` trips
`184 End-to-End_Error` as `FAILING_NOW` (value 097, threshold 099, raw 3) and reports
`187 Reported_Uncorrect 12`. Neither is a live fault, and the distinction took real evidence:

| evidence | reading |
|---|---|
| ATA error log: 8 `UNC`, 0 `ICRC`/`ABRT` | media, not the link. A bad cable produces `ICRC` aborts |
| `199 UDMA_CRC_Error_Count` = 1 | the link is fine. Compare `sdc`'s 329 |
| all retained errors at **10,188 h**, drive now at **17,864 h** | the event is 7,676 hours (320 days) old |
| all five entries at the **same LBA 1790168** | one sector retried, not twelve separate faults |
| Extended offline self-test `Completed without error` at 17,343 h and 17,355 h | the full surface read clean *after* the event |
| `197`/`198` both 0 | nothing pending, the sector was recovered |
| 787 GB read off it at 56 MB/s over four hours on 2026-10-06 | `ATA Error Count` still 12, all stamped 10,188 h: zero new errors |

So the disk currently reads its entire surface without error. `184` and `187` are **lifetime
counters that never fall once tripped**, which matters operationally: a guard keyed on them
latches for the remaining life of the drive and reports nothing about its current state.

`sdc`'s cable is still the one worth replacing: 329 CRC errors on the disk holding parity.

Controller: JMicron JMB585, 5 SATA ports, **4 used, 1 free**. The SSD is on USB and therefore
costs no SATA port. Kernel has `BCACHE`, `DM_CACHE`, `DM_WRITECACHE`, `BTRFS_FS` and
`FUSE_FS` available as modules.

Usable capacity: **4 TB** (`disk1` 2 TB, `disk2` 1 TB, `disk3` 1 TB) against the same 4 TB parity,
which the pool reports as 3.7 TiB. SnapRAID needs parity to be at least as large as the largest
data disk, which 4 TB against 2 TB satisfies with room for one more upgrade.

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
  - Version identity comes from the log itself (`nilfs-lives`, 4.5.2), not from event times, so a
    missed event loses a path rename at worst, never a version.

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
| Version counts | retained edits per path, read from the history index (4.5.2) | O(changes) |
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

### 4.5.2 The history index, as built

`nas-at` keeps everything history needs in one SQLite file on the SSD,
`/var/lib/nas-checkpoints/index.db` (WAL, directory `0750 root:grafana` so Grafana can read it):

```
checkpoints(branch, cno, epoch, ss)                 every checkpoint, appended from lscp
lives(branch, ino, vblk, n, s, e, seg, off, dead)   block runs with their exact DAT lifetime [s, e)
paths(branch, ino, inc, path, dir, lo, hi, since)   which name an inode held over which cnos
policy(id, paths, rule, params, lo, hi, created, undone)   one row per user action
drops(rule, branch, ino, lo, hi)                    rendered: "no snapshot in [lo, hi) counts for ino"
rendered, gc_runs, scan, meta                       bookkeeping
```

**Everything is keyed by branch.** Inode and checkpoint numbers are per filesystem, and the first
two-branch test of the old index listed one disk2 path with versions from disk1's checkpoint space.
Restoring one would have mounted an unrelated checkpoint of the right number, silently.

**Where each table comes from.**

- `lives` is read from the log itself by `nilfs-lives` (C, in `nilfs-utils.nix`, linked against
  libnilfs). `follow` walks the segment chain from the last position recorded in `scan` to the
  sysfs head (`segctor/last_seg_sequence`, `segctor/last_pseg_block`), emitting each file's block
  runs with their `GET_VINFO` lifetimes. The summary's `ss_next` is the next segment's first
  *block*, not its number (`dumpseg` divides it for display); the first `follow` compared it as a
  segment number and reported a broken chain on the first segment boundary. `probe` re-reads the lifetime of runs that may have ended.
  A run is keyed by `(branch, vblk, s)`, so blocks moved by GC upsert onto the same row with their
  new `seg`. Inode reuse needs no special case: a reused number gets new vblocks with later `s`.
- `paths` comes from `nas-history-watch-<branch>`, one `fatrace -c -j -f 'W+D<>' -t -t` per NILFS2
  branch. Writes give the file and inode; creates, deletes and both halves of a rename give the
  directory, which the pass then re-lists. A nightly `nas-history-walk` re-lists the whole branch
  inside the SnapRAID window as the backstop for a watcher outage.
- `checkpoints` is `lscp -a -i <last+1>`, so each pass costs only the new checkpoints.

**Why `nilfs-lives` and not `dumpseg`.** `dumpseg` carries the same data, but measured on disk1 it
prints 120 KB and 2,047 lines per segment at 74 ms, so the 53,000-segment migration is ~6.4 GB of
text and ~65 minutes of pi CPU. It is also a debugging tool with no stable format. `nilfs-lives`
reads the same summaries through libnilfs and emits one line per run.

**The pass** (`nas-at pass`, `nas-checkpoint-promote.timer`, every 15 minutes, idle I/O class) does,
per branch:

1. **Nothing**, unless the sysfs log head moved or the event file grew. An idle pass reads no disk.
2. Promote new checkpoints to snapshots, follow the log, re-list touched directories, probe
   touched inodes.
3. Render the rules (4.6) for the touched paths into `drops`, and mark runs whose blocks no
   retained instant needs as `dead`.
4. Reclaim when the branch is under 15% free: `nilfs-reclaim` over segments at least 25% dead,
   oldest first, recorded in `gc_runs`.
5. Write the textfile metrics.

The first pass on a branch with no `scan` row backfills it from every dirty segment, about an hour
on disk1 at idle priority. `nas-at backfill` repeats that by hand if the log chain is ever found
broken (the pass then says so instead of guessing).

**fatrace output rotation.** It opens `-o` with `O_CREAT|O_EXCL` and no `O_APPEND`, so a stale file
stops it starting (the unit removes it in `ExecStartPre`) and the file cannot be truncated under it.
The pass reads forward from a stored byte offset and restarts the watcher once the file passes
`rotateBytes` (64 MB).

**Timers use `OnActiveSec`, not `OnBootSec`.** On a host already past `OnBootSec`, the timer fires
the moment activation installs it, and a failing `oneshot` makes `switch-to-configuration` exit 4,
which rolls the deploy back. The first versions deploy failed exactly this way. Every history unit
also sets `restartIfChanged = false`, so a running backfill never blocks an activation.

### 4.5.3 Reading the past

- **One file.** `nas-at log <path>` lists every retained and dropped edit of a path across inodes
  and branches, with bytes, the rules that apply, pins and a `moved` tag for mover copies. No
  mounts. `nas-at revert <path> (-n N | --at T)` copies that version back in as a new edit.
- **A directory.** `nas-at revert <dir> --at T` snaps T back to the latest instant every rule in
  scope retained, prints it, copies the tree from it and removes files created since (they stay in
  history). The restored tree is therefore a state that actually existed.
- **By time, any path.** `/srv/nas-at/<ISO time>/<path>` is a read-only FUSE view (`nas-at-view`)
  of the pool at that instant: `ls '/srv/nas-at/2026-11-01T14:03:27.250/max'`. `nas-at resolve
  <path> '<time>'` prints the view path, or says the path did not exist then. Writes fail with
  `EROFS`. The view root also lists the last 24 quarter-hour `@GMT-…` names that Samba shows as
  Previous Versions (4.6).

The view is **not** a globally atomic cut: each path resolves on its own branch. User-affinity
placement keeps an account on one branch, so this does not show in practice.

**The view is the only thing that mounts a checkpoint, and it never opens a dropped version.**
This is a kernel constraint, found in the Phase 0 prototype (4.6). A `cp=` mount shares the live
branch's super block. Once GC has freed a dropped version's blocks, reading it turns a DAT
`-ENOENT` into `-EINVAL`, which reaches `__nilfs_error` and remounts the **live** branch read-only.
After the DAT entry is reused it can instead return another file's bytes. So the resolver serves
an inode at time T from the latest retained edit at or before T, hides forgotten inodes, mounts
with a non-blocking `flock` on the write lock (a `snapraid sync` holds it for hours; the version
then shows as unavailable), and refuses while the suspend marker exists. The reclaim pass bumps a
policy generation that the view re-reads on every lookup, and it refuses to run while any other
`cp=` mount of the branch exists or the view has files open.

### 4.6 Versions: NILFS2 checkpoints

**The data branches are NILFS2, not btrfs.** NILFS2 is log-structured and creates a checkpoint
**continuously as segments are written**, so every change is captured without a timer deciding
the granularity. btrfs snapshots are point-in-time: whatever happens between two of them is
unrecoverable, and a file created and deleted inside that window leaves no trace. That gap is
the reason for the change.

Checkpoints live **outside the filesystem namespace**. They are listed with `lscp`, promoted to
snapshots with `chcp ss` (which protects them from garbage collection) and read by mounting:
`mount -t nilfs2 -o cp=<n>,ro`.

Two consequences are worth stating because they contradict the earlier btrfs design:

1. **Checkpoints are not files, so parity never sees them.** The old SMB window mounted 24 of them
   inside each branch at `snapshots/@GMT-…`, which needed a SnapRAID exclude (and the dotted btrfs
   `.snapshots/` name did not match it). The time view now mounts under `/run/nas-at`, outside every
   branch, so nothing history-related is inside a branch at all.
2. **Every checkpoint is promoted, and history is thinned per file instead.** `nilfs_cleanerd`'s
   protection period is time-bounded and whole-filesystem, so it can neither keep forever nor keep
   one file's history while dropping another's. Every branch mounts `nogc`, `nas-at pass` runs
   `chcp ss` over every new checkpoint, and space comes back only through the per-file rules below
   and `nilfs-reclaim`. A full NILFS2 stops accepting writes, so `nas_branch_used_ratio`,
   `nas_history_bytes` and the `nas-branch-filling` alerts stay; they now point at `nas-at top`.

**Measured checkpoint rate.** Writing 1000 MB to disk1 in 21 seconds produced 4 checkpoints:

```
1000 MB in 21s   ->   checkpoints 4 -> 8
```

So roughly **one checkpoint per 250 MB written, about one every 5 seconds under sustained write**,
and near-zero when idle (two checkpoints five minutes apart on a quiet filesystem). Count tracks
*activity*, not elapsed time, which is what makes "retain everything" affordable here where a
fixed timer would not be.

**Bulk ingest no longer needs promotion suspended for space.** A 427 GB migration creates ~1,700
checkpoints of partial transfer states, and measurement showed they cost about 7 GB (0.4%), because
a fresh bulk copy is almost all live data. If they matter, `nas-at keep <dir> --quantum inf --from
<start> --until <end>` drops them afterwards. The suspend marker remains for its other purpose:
holding every mount and pass off the array while something else needs it to itself.

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
seeks and, critically, never touches a spun-down HDD. Reclaim runs only from the history pass,
and only on a branch under its free-space threshold.

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

#### Per-file history control

References for this subsection are at the top of this document ([NAS history
references](#nas-history-references)); open work is in [`nas-history-todo.md`](nas-history-todo.md).

No per-file GC exists for NILFS2. Rohner's cost-benefit series and thesis cover only which segments
to clean, and were never merged. The design here adds **one liveness hook and one rule kind**, and
lets NILFS2 do the rest.

**The hook.** nilfs-utils decides block liveness in userspace (`lib/gc.c`, `nilfs_vdesc_is_live`):
a block lives while some snapshot cno lies in its DAT lifetime `[start, end)`. `nilfs-history.patch`
adds a callback to libnilfsgc that, after the stock protection test, removes the inode's **drop
ranges** from that interval before the stock snapshot search runs on what is left. `nilfs-reclaim
--policy F --protcno N [--dry-run] DEVICE SEGNUM...` (`nilfs-reclaim.c`) runs
`nilfs_reclaim_segment` with that callback over explicit segments and prints `freed_vblks`, so a
dry run is the real computation. There is no resident `nilfs_cleanerd` at all: no oldest-first
sweep over ~53,000 fully live migration segments, no cpfile re-read, no unattended disk wake-ups.

**The rule kind.** The policy file holds `ino lo hi` lines meaning "no snapshot in `[lo, hi)` counts
for this inode". Ranges intersect for free (a cno counts only if no range drops it). They are always
closed and bounded by the inode's lifetime under that number, because NILFS2 reuses inode numbers.
Snapshots themselves are never deleted and stay the global time index, with one exception below.

**Retained instants.** A rule acts on a **scope**, the paths it was given and everything under
them. It picks a set R of checkpoints on the scope's merged edit timeline, and every file in scope
keeps the version that was current at each instant in R, plus its live version; `nas-at` writes the
gaps between consecutive instants as drop ranges. So **every instant in R is an exact snapshot of
the whole scope**, and a directory revert to one is consistent. Interleaved edits to several files
in one scope therefore save less than per-file thinning would; that is the price of consistency.

| `nas-at keep <paths> …` | R is |
|---|---|
| `--quantum Q` | the last edit in each clock-aligned bucket of Q (`10m`, `1h`, `1d`, `inf`), plus landmarks |
| `--pairs [-x N]` | every second intermediate edit dropped between landmarks, repeated N times |
| `--continuous` | every edit (no drops) |
| `--none` | nothing but pins: historyless |
| `--target 5G` / `--target-ratio 0.6` | the first quantum in 1 s, 5 s, 10 s, 30 s, 1 m, 5 m, 10 m, 30 m, 1 h, 1 d, inf that frees that much |

`--from T --until T` bounds the range; `--from now` sets a resolution for future edits and closes
the previous future rule on the same scope. `--dry-run` prints what would be freed. Savings come
from `lives`, the exact VINFO lifetimes, not an estimate.

**Landmarks** are instants every stitch keeps, so the scope is consistent there too (after Elephant's
"keep landmarks": edits arrive in bursts, and the last version of a burst is the one worth keeping).

- **Session end**: the last edit before the scope sits idle for at least `--gap` (default 10 m,
  `checkpoints.landmarkGap`). A Minecraft world's session ends when the server drains.
- **Large removal**: the instant before an edit that shrinks a path by at least 25% and 64 KiB,
  summed across its inodes so atomic saves count.
- **Pins**: `nas-at pin <path> [-n N | --at T]` marks a version; only `forget` drops it.

A quantum bucket containing a landmark is split at it, pairs runs separately inside each piece, and
`--quantum inf` keeps exactly the landmarks. `--no-landmarks` stops adding session and removal
landmarks (pins still apply), for a single file or any scope, while R is still chosen on the scope's
merged timeline, so what remains is still consistent. **Future rules only stitch sessions that have
ended**; the open session is kept whole until the next one starts, the safe direction.

**Defaults.** `checkpoints.historyless` (`tmp`, `.cache`, `*/.cache`) is the built-in rule #0: a
historyless future rule over those globs, shown by `nas-at rules`.

**Other commands.**

- `nas-at top [dir] [--by size|history|ratio] [-n N]`: the largest files and the ones whose history
  dwarfs them.
- `nas-at forget <paths> --yes`: recursive `rm` plus a drop over each inode's whole lifetime. The
  content is freed; the name is tagged deleted and hidden from every view, though old directory
  blocks still hold it. Refuses the whole pool; lists the pins it drops.
- `nas-at rules [--all]`, `nas-at undo <id>`: undo is refused once a reclaim has freed blocks under
  that rule, since the old versions no longer exist.
- `nas-at reclaim [--dry-run]`: reclaim now instead of waiting for the 15% free threshold.

**Drops never shrink once enforced.** After a reclaim, a range that later stopped being dropped would
make the view believe a freed version is readable, which is the Phase 0 hazard (4.5.3). So a
re-rendered rule unions its previous drops once any reclaim has run since it was created.

**Whole-pool stitching demotes snapshots.** Inode-table and directory blocks belong to no user file,
so per-file drops cannot reclaim them. `nas-at keep / …` (and only a rule over the whole pool) also
runs `chcp cp` on every snapshot not in R, recorded in the rule so `undo` can re-promote them while
that is still possible.

**Stated limits.** Precision is one log (one sync). Truncating a tiny file held in a direct bmap is
not seen until the inode is touched again. A rewrite in place that keeps the size is not a large
removal (TODO). Per-file rules cannot reclaim metadata.

#### Phase 0: the prototype that set the constraints

`tests/nas-history.{nix,py}`, a throwaway VM on a 256-block-segment NILFS2, before anything touched
the pi:

- A drop range on one inode across 100 snapshots: the dry run predicted 1,854 freed blocks and the
  real reclaim freed 1,857 (0.16%). A second pass found nothing. Every other file was byte-identical
  at every checkpoint, and an inode number reused mid-history kept its new file intact.
- Reading a dropped version after its blocks were freed **remounted the live branch read-only**.
  Mounting the live branch `errors=continue` kept it writable, but the read still failed, and after
  the DAT entry was reused it could return foreign data, so `errors=continue` was declined in
  favour of never opening a dropped version (4.5.3).
- 1,000 checkpoint mount and unmount cycles under a concurrent writer produced no Oops or warning.

#### End-to-end VM test

`tests/nas-at.{nix,py}` (`checks.x86_64-linux.nas-at`) drives the real `nas-at`, fatrace watcher
and view on a 256-block-segment NILFS2: two editing sessions over interleaved files, a pinned
file, a large removal, a `.cache/` file, then every command in turn.

| Check | Result |
|---|---|
| View before any rule | every edit of `proj/` byte-identical through `/srv/nas-at/@EPOCH` |
| `.cache/` | one current version, every older one dropped by rule #0 |
| `--quantum inf` | keeps exactly session end, pin, large removal and range end; the view at every edit shows the latest kept state |
| `--no-landmarks` | keeps only the range end; the first edit's view is empty, not stale |
| `--pairs` on interleaved files | every directory revert lands on a real state, snapped back where a drop covers it |
| `forget` | gone from the branch and every view time, `log` shows `tagged: deleted` |
| `reclaim` | dry run 532 blocks, real 532 blocks (2.1 MiB, 5 segments); retained views unchanged after; branch still writable, no NILFS error |
| Metrics | `nas_history_bytes` reports current, retained, reclaimable and freed > 0 |

It found three bugs the unit-level prototype could not:

- `ss_next` is a block number (4.5.2), so the first segment boundary looked like a broken log.
- A command that scanned new segments (`pin`, `log`, `keep`) advanced the cursor without
  re-rendering the rules those segments touched, so `.cache/` edits scanned by a `pin` were never
  dropped. Every scan now renders what it consumed.
- The history lock lived under the view's mount directory, so reclaim's own lock looked like an
  open view file and every real reclaim was postponed. It is `/run/nas-history.lock` now.
- `forget`'s `rm` was still unsynced when the dry run read `protcno`, so reclaim predicted 456
  blocks and freed 532. `forget` and `reclaim` now `sync` first.
- A path that vanished before its deletion was scanned was closed at the newest indexed
  checkpoint, whose `hi` is exclusive, so `forget` left the file visible in exactly that
  checkpoint's view. An unscanned deletion now closes the path one checkpoint later; a scanned
  death still tightens it.
- A file written and deleted between two passes was never in `paths`, so its blocks matched no
  rule and stayed live. The pass now adopts an inode it first meets in the event log at the path it
  was written under, so a brief `.cache/` file is dropped like any other.
- Re-rendering an open rule after its drops were enforced mixed ranges read back as lists with new
  tuples, and sorting them raised `TypeError`, so the pass crashed on the next `.cache/` write.

#### On the pi

| Measure | Result |
|---|---|
| First pass (backfill, disk1 alone has 158,333 segments) | 2h17m wall, 25m52s CPU, 2.4 TB read, 2.1 GB written; peak 812.5 MB RSS + 503 MB swap. The plan's 65 min assumed summary-only reads; the disks' 8 MiB read-ahead turned every summary read into a whole-segment read (fixed, see [Speed](#speed-stitching-top-and-gc)) |
| Idle pass, as deployed | 4.9 s, 226.5 MB read: `metrics` rescanned `lives` every run |
| Pass on idle disks, with `history_days` | 10.9-28.6 s, 0.8-1.2 GB read: never actually idle (below), and the recount scanned `lives` once per branch |
| Idle pass, minor checkpoints left alone | 0.34-0.36 s, 4.7-6.6 MB read (interpreter, from the SSD), 4 KB written; no new checkpoint on any branch, HDD write counters flat. The first pass after the deploy (0.68 s, 53 MB) left the old code's last minor checkpoint unpromoted |
| History, disk1 | current 1.306 TB, retained 3.03 GB, reclaimable 1.40 GB, metadata 17.7 GB; 4,398 checkpoints, 4,299 snapshots |
| History, disk2 / disk3 | current 80 MB / 105 MB, retained 3.06 GB / 2.5 GB |
| Write-day panel | 12.7 s through Grafana when it grouped `lives` live; under a millisecond from `history_days` |

`history_days` holds bytes per branch, write day and state. A pass rebuilds it only for branches it
scanned, so an idle pass reads nothing from `lives`, and both the Prometheus totals and the Grafana
panel read the small table. frser-sqlite-datasource 4.0.2 has no `$__unixEpochFrom()` macro (only
`$__unixEpochGroupSeconds`); the panel bounds the range with Grafana's `$__from / 1000` instead.

**Promotion fed itself.** `chcp ss` dirties the cpfile, so segctor writes a segment and records a
*minor* checkpoint (`lscp -a` flag `i`: no file changed). The next pass saw the branch move,
promoted that one, and so on: every branch, idle or not, gained one snapshot and one segment write
per 15-minute pass, at the pass's own timestamp, and was never quiet long enough to park. The
promoter has done this since it first listed with `lscp -a`; disk2's 260 checkpoints are mostly
these. Minor checkpoints are now indexed but never promoted: they hold no file change, so the
snapshot before them already shows the same tree. A recount now happens only when a pass touched
an inode or reclaimed a segment, in one scan for every branch that needs it.

#### Evaluation

`tests/nas-eval.{nix,py}` (`checks.x86_64-linux.nas-eval`) is Stage A of the plan: a 3 GB NILFS2
with production-sized segments (2048 blocks, 8 MiB) on LUKS over `dm-delay` (4 ms per request),
2,001 snapshots in the cpfile, measured at four fill levels. At each level fio runs a 1 MiB
sequential write and a 4 KiB random overwrite with an fsync every 32 writes, three times: stock
(no pass), with the pass looping every 2 s, and with `nas-at reclaim` running. Before the reclaim
run a 48 MiB file is rewritten four times and stitched `--none`, leaving 144 MiB reclaimable.

Stage B (a scratch NILFS2 on the pi's real LUKS and bcache stack) was not run: no experiments
happen on the pi. Also scaled down: 2,001 snapshots instead of 500k (`mkcp -s` takes 15 ms each,
so 500k is two hours of setup), and the disk is small enough that each fio write shrinks with free
space (256 MiB sequential at 50%, 40 MiB at 97%).

| Fill | Stock seq MB/s, fsync p99 | Pass idle | Reclaim active | GC |
|---|---|---|---|---|
| 50% | 384, 13.7 ms | 403, 13.8 ms | 485, 11.3 ms (max 31 ms) | 18 segs, 138.1 MiB in 14.0 s, 0.04 B copied/B freed |
| 90% | 383, 19.3 ms | 178, 10.9 ms | 476, 11.5 ms (max 50 ms) | 19 segs, 144.8 MiB in 7.6 s, 0.05 |
| 95% | 350, 10.8 ms | 286, 11.1 ms | 471, 12.4 ms (max 50 ms) | 20 segs, 147.6 MiB in 4.2 s, 0.08 |
| 97% | 317, 10.9 ms | 308, 11.6 ms | 494, 11.1 ms (max 13 ms) | 18 segs, 142.1 MiB in 3.7 s, 0.01 |

| Check | Pass if | Result |
|---|---|---|
| Pass idle vs stock | throughput within 5%, p99 within 10% | **pass on p99** (+1%, -43%, +2%, +6%). **Throughput fails at 90% and 95%** (-53%, -18%); the previous run of the same code was 0% to +41% at every level, and these writes are 62-93 MiB, so a single slow flush dominates. Not separable from VM noise without Stage B |
| Reclaim active | ≥ 70% throughput, fsync p99 ≤ 2× stock, max ≤ 2 s, ≤ 4 B copied per B freed | **pass**: 124-156% throughput, p99 ≤ 1.15×, max 50 ms, 0.01-0.08 B copied per B freed |
| 95% full | no ENOSPC while reclaimable space exists, fsync p99 ≤ 1 s | **pass**: 232 MiB written into 160 MiB free; auto reclaim freed the churn in 2.1 s. p99 12.4 ms |
| 97% full | reported; no ENOSPC, no kernel warnings | **pass**: 184 MiB into 112 MiB free, auto reclaim in 2.1 s; 0 dmesg warnings; 0 sectors read or written over 180 s idle with the pass every 10 s |
| View | warm getattr p50 < 1 ms, p99 < 20 ms; seq read ≥ 50% of branch | **pass**: stat 0.128 ms/file warm, 0.61 ms cold (branch 0.008 / 0.047; mean, not percentiles); read 341 vs 436 MB/s (78%). Four concurrent readers: branch 392, mergerfs 320, view 272, SMB 198 MB/s, 794 total |
| Previous Versions | listing < 2 s cold, < 300 ms warm; no mounts beyond those shown | **pass**: 24 versions in 15-minute buckets; `smbclient allinfo` 1.30 s cold, 0.09 s warm, 24 mounts (one per version shown); `get` of the oldest and newest returns what was written, with no further mount. Laptop run; under builder contention the cold listing took 5.1 s |
| History pass | 0 bytes read when idle, < 1 s | **pass**: 0 sectors read or written, 0.24 s. After a 256 MiB write: 1.9 s, 3.4 MB read (254 MB before `MADV_RANDOM`) |
| CLI (VM db) | `log` < 0.5 s, `top` < 1 s, `keep --dry-run` < 5 s, `--target` < 10 s | **pass**: `log` 0.25, `top` 0.26, `top --by ratio` 0.26, `keep --quantum 3600 --dry-run` 0.53, `--target-ratio 0.5` 0.54, `--target 100M` 0.56 s |
| CLI (pi db) | as above | **pass**: `top` 0.024 s and `keep --target` 0.26 s against a copy of disk1's `index.db` (were 4.9 s and 339-618 s on the pi) |
| SnapRAID | `diff` after reclaim shows nothing updated or removed | **pass**: after `sync`, a reclaim of 142.2 MiB, then `diff`: 10,006 equal, 0 added, removed, updated or moved; `check` reports `Everything OK` |
| Space | freed matches dry run within 2% | **pass**: within one block at every level (35,343/35,344, 37,059/37,059, 37,779/37,780, 36,371/36,371) |
| Disk parking over 2 h, db growth per day | diskstats flat for ≥ 2 h with everything enabled; growth recorded | **pass after a fix**, on the pi. The first window (16:31-18:34) failed: every pass read disk2 about 24 times, because reading `checkpoints/checkpoints_number` walks the cpfile through metadata the page cache had dropped since the last pass, and that reset the 60-minute park deadline indefinitely. An idle branch now reuses the counts it last published (VM, after `drop_caches`: 0 reads, 4 without the fix). After the fix: 19:08-21:10 flat on disk2, disk3 and parity (0 reads, 0 writes) across 9 passes, and disk2 and disk3 parked at 20:08, 60 min after their last access. disk1 carried the Minecraft stream throughout. db: +3.3 MB in 2 h 03 min with the stream pushing every minute, about 39 MB a day, see [Speed](#speed-stitching-top-and-gc) |

"Fill" is `used / (used + avail)`. NILFS2 reserves 5% of segments for GC (`mkfs.nilfs2 -m`), so
`df` never shows more than about 94.5% of the raw device in use; 97% here means 97% of what can
actually be written.

**Fresh segments are held back from GC.** `nilfs-reclaim` passes the superblock's `ss_prot_seq` as
`protseq`, and libnilfsgc refuses every segment written since then, because roll-forward recovery
after a crash still needs them. `ss_prot_seq` is the log cursor of the *older* of the two
superblock copies. The kernel writes a superblock only when the log has entered a new segment,
at most every 10 s (`NILFS_SB_FREQ`) or on `sync`, alternating copies, so the protected window
spans at least the last two superblock writes. A file deleted straight after it was written shows
`would free 336K` until a little more is written. Reclaim prints `N segments newer than the
superblock's log cursor held back` when this happens; the space is freed by a later pass.

**A full disk of fresh garbage deadlocks.** Ordinary writes fail with `ENOSPC` once clean segments
fall to the GC reserve, so nothing moves the log, the cursor never advances, and everything
deletable sits in held-back segments. The tmp churn test hit exactly this: after 3 GB of churn at
110 MB/s, `rm -rf tmp` left 66 segments held back and the disk at `ENOSPC`. GC writes may use the
reserve. So when at least 4 segments are held back and free space is under `--reclaim-free`
(at least 5%), reclaim moves the live blocks out of the fullest dirty segment, which carries the
log into new segments, `sync`s so a superblock is written, and retries, up to six times. It prints
`moved N segments to advance that cursor`. In the last run that churn ended with `98 segments
cleaned, 761.7M freed; moved 1 segments to advance that cursor`, and the fill-level setup needed it
three more times.

The evaluation found three more bugs:

- Settle ran reclaim automatically whenever free space was below 15%, so at 90% fill the setup's
  own passes reclaimed the churn before the measured reclaim started. The pass's threshold is
  `--reclaim-free`, and the test turns it off during setup.
- **The kernel frees whole DAT entry blocks.** Since Linux 4.4 (`nilfs_palloc_freev`), GC deletes
  a DAT entry block once every entry in it is free, and `GET_VINFO` on any virtual block number in
  it then fails the whole batch with `ENOENT`. Probing the runs left in just-cleaned segments hit
  this and crashed `nas-at reclaim`. `nilfs-lives` now retries such a batch entry by entry and
  reports the missing ones as freed.
- **`findmnt PATH` also matches a mount whose source is PATH.** A mergerfs pool with a single
  branch has that branch as its source, so the branch resolved to the pool, looked unmounted,
  and every pass silently did nothing. The lookup is `findmnt -M` now. The pi's pool has three
  branches, so its source never equals one of them.

#### Reclaim under churn in `tmp/`

`tmp/` is historyless. The churn writes 48 files of 64 MiB in turn over four names, 3 GiB in all,
with about 740 MiB free and the pass looping. A file whose write fails with `ENOSPC` is retried
after 1 s.

| Run | Written of 3,072 MiB | Failed files | MB/s | Min free | Device read | GC |
|---|---|---|---|---|---|---|
| unthrottled, pass every 2 s | 2,368 | 11 | 121 | 0 MiB | 72 MB | 4 runs, 261 segs, 1,971 MiB |
| 110 MB/s, pass every 2 s | 2,752 | 5 | 83 | 8 MiB | 74 MB | 8 runs, 330 segs, 2,498 MiB |
| 110 MB/s, pass every 30 s | 1,408 | 26 | 34 | 8 MiB | 0.7 MB | 1 run, 98 segs, 764 MiB |

Reclaim keeps up with most of a gigabit link but not all of it. The held-back window is up to two
superblock writes, 10 s apart, which at 110 MB/s is more than the free space, so a replaced file's
segments are often still protected when the next write needs them. The pass's 2 s loop is only
for the test; the pi's pass runs every 15 minutes, so a branch this full under sustained writes
relies on mergerfs `moveonenospc` moving the file to another branch rather than on reclaim.

#### Against stock NILFS2

`tests/nas-eval-stock.py` (`checks.x86_64-linux.nas-eval-stock`) runs the same disk, fill levels
and churn with no history patch in use: plain checkpoints and `nilfs_cleanerd` with its shipped
config (protection period 3600 s, `min_clean_segments` 10%). It ran before the `MADV_RANDOM`
change, which affects only the history tools.

| | Stock NILFS2 + cleanerd | History + `nas-at reclaim` |
|---|---|---|
| Garbage younger than 1 h | never freed (0 MB at every level) | freed on the next pass, minus the held-back window |
| Garbage aged 2 h (clock moved) | 136 of 144 MiB in 51 s, 26 s, 17 s at 90/95/97%; nothing at 50%, where clean segments exceed 10% | 138-148 MiB in 14.0, 7.6, 4.2, 3.7 s at 50/90/95/97% |
| GC cost | 2.2-5.1 B written to the device per B freed | 0.01-0.08 B copied per B freed |
| Write during GC, 97% | 309 MB/s, fsync p99 223 ms | 494 MB/s, fsync p99 11.1 ms |
| Write beyond free space, 144 MiB reclaimable | `ENOSPC` at 95% and 97%, not recovered within 300 s even after aging | written at both levels, auto reclaim 2.1 s |
| 3 GiB churn in `tmp/`, ~750 MiB free | 37 of 48 files failed in both runs, 704 MiB written, 16-17 MB/s | 11 / 5 failed, 2,368 / 2,752 MiB written |
| Idle disk, 180 s | 0 sectors | 0 sectors |

The two GC cost figures are not the same quantity. Stock's is device bytes written while
cleanerd ran, which counts the segments it rewrites wholesale; the history side counts the live
blocks in the segments `nilfs-reclaim` cleaned (segment blocks minus blocks freed). Both say the same thing: cleanerd picks
segments by age and copies whatever is live in them, while reclaim picks only segments whose dead
fraction is at least 25%.

Without history, the protection period is what keeps recent versions, so cleanerd cannot free
recent garbage by design; the history system keeps versions by rule instead and frees garbage
as soon as the log allows.

#### Speed: stitching, `top` and GC

All times below were measured against a copy of the pi's `index.db` on the laptop, before and
after the change:

| Operation | Before | After | Change |
|---|---|---|---|
| Stitch sweep over the 11 quanta (`keep --target`, `--target-ratio`) | 146.7 s (pi: 339-618 s) | 0.26 s | timelines and per-run liveness framed once, every quantum reuses them |
| `keep --pairs` on `max/` | 12.95 s | 0.14 s | same frame |
| `top` | 0.91 s (pi: 4.9 s) | 0.024 s | reads `tallies`, not `lives` |
| Recount after a pass | 4.45 s | 0.03 s | from `tallies` |
| Reclaim candidate query | 0.37 s | 0.018 s | partial indexes on dead and closed runs |
| `lssu` before and after reclaim | about 31 s | about 30 ms | lists only the windows around candidate segments (`-a -i LO -n N`), not all 158k |

- **`tallies`.** This table holds one row of counters per (branch, inode, birth checkpoint): blocks,
  data blocks, current blocks, retained blocks and reclaimable blocks. Triggers on `lives` keep it
  up to date. Raw ingest gets about 1.75× slower, but the pass ingests a few thousand rows a day.
  The first pass after the upgrade builds the table once, which took 4.1 s on the pi's db.
- **`lssu -n` counts printed lines.** It skips clean segments unless `-a` is given. So the scoped
  windows always pass `-a`, and windows less than 64 segments apart are merged.
- **libnilfs read whole segments.** `nilfs_get_segment` `pread`s the full 8 MiB unless
  `nilfs_opt_set_mmap` is set, and even when mapped it reads the summary's `ss_seq` before
  returning. The pi's HDDs run `read_ahead_kb` 8192, so that first page fault reads around 8 MiB,
  and a scan of summaries read every byte of the log: after a 256 MiB write the VM's pass read
  254 MB, and the backfill read 2.4 TB. The patch calls `madvise(MADV_RANDOM)` straight after the
  `mmap` (an `madvise` from the caller is too late, the first fault has already happened), and
  `nilfs-lives` and `nilfs-reclaim` turn mmap on. On a loop device at 8 MiB read-ahead, 34 freshly
  written segments now cost `nilfs-lives` 3.4 MB instead of 256 MB and a reclaim dry run 3.2 MB
  instead of 260 MB, with identical output. libnilfsgc reads only summaries in userspace (the
  kernel moves the live blocks), so reclaim gains the same.
- **db growth.** A `lives` row is about 158 B, but the file grows by about 1.4 KB per row once its
  indexes, `tallies`, `paths` and `checkpoints` are counted. Measured on the pi over 2 h 03 min
  with the Minecraft stream pushing every minute: 2,437 rows and 3.3 MB (451.4 to 454.8 MB), so
  about 28,000 rows and 39 MB a day while a stream is active. A day without one adds 1,000-3,500
  rows, 1.4-5 MB.

#### Previous Versions over SMB

Each share runs `shadow_copy2` against the time view instead of mounts inside the branches:

```
vfs objects = shadow_copy2       shadow:mountpoint = /srv/nas
shadow:snapdir = /srv/nas-at     shadow:format = @GMT-%Y.%m.%d-%H.%M.%S
shadow:localtime = no            shadow:sort = desc
```

The view root lists the newest 24 quarter-hour `@GMT-` names, each resolving like any other time, so
Windows' right-click Previous Versions needs no client software and no per-generation mounts; the
view mounts a checkpoint only when a version is actually opened, and unmounts it after 10 idle
minutes. `@GMT-` names are UTC: convert through the epoch, never `date -u -d` on a local timestamp,
which silently parses it as UTC and leaves every name an hour off in BST.

The Samba recycle bin is gone: history already holds every deleted file, so it was a second
mechanism covering the same ground. Existing `.recycle/` contents are forgotten once with
`nas-at forget /srv/nas/*/.recycle --yes`.

**A plain checkpoint cannot be mounted. Only a snapshot can.** `mount -t nilfs2 -o cp=1365,ro`
fails with `Invalid argument` until `chcp ss`. This is why promotion is load-bearing: the view and
`revert` both mount.

**nilfs-utils is pinned past 2.2.12, where promotion is a silent no-op.** 2.2.12 inverts the
`[DEVICE]`/`CNO` test in `bin/chcp.c`, so every `chcp ss "$device" N` failed behind `|| true` and
the snapshot count sat at 0. Fixed upstream in `27bfa50c4` (2.3.0); the overlay is on 2.3.1 with
the history patch. Write-up in `docs/nilfs-chcp-bug.md`.

**The history pass and new view mounts are suspended by a marker file, not by stopping a timer.**
`systemctl mask` fails on a NixOS unit whose `/etc/systemd/system` entry is a store symlink, and a
stopped timer is restarted by the next activation. `touch /run/nas-promote-suspended`; the units
carry `ConditionPathExists=!` on it, so a skip is not a failure.

**Every nilfs tool takes the device, never the mountpoint.** `lscp /mnt/disks/disk1` fails with
`No such device or address`; `lscp /dev/mapper/nas-disk1` works.

**Beware `nilfs-clean -s`: that is `--suspend`, not status.** Nothing here runs `nilfs-clean` any
more, but the trap is worth keeping in mind on any NILFS2 host.

### 4.7 Namespace and protection tiers

```
/srv/nas/data/users/<name>/           <name>:<name>, mode 0700
/srv/nas/data/shared/<group>/         root:nas-<group>, mode 2770
/srv/nas-at/<time>/...                read-only time view; @GMT-... names for Previous Versions
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

**There is no recycle bin.** History already contains every deleted file, so `vfs_recycle` was a
second mechanism covering the same ground; it was dropped and existing `.recycle/` contents were
forgotten once. The one thing it caught that history does not is a file created and deleted inside
one log, a window of one sync.

- **Restore a file**: `nas-at log <path>` lists its versions; `nas-at revert <path> -n N` or
  `--at T` copies one back in as a new edit. Recent times are also in Windows Explorer's Previous
  Versions (4.6).
- **Rewind a folder**: `nas-at revert <dir> --at T` restores the tree as it was at the latest
  consistent instant at or before T (4.5.3), or browse `/srv/nas-at/<time>/…` read-only.
- **Permanent delete**: `nas-at forget <path> --yes` removes it and drops every version of every
  inode it held; the pass reclaims the blocks. Unrelated history in the same checkpoints is
  untouched, which `rmcp` could never do.
- **Opting out**: `nas-at keep <dir> --none --from now`, or the `checkpoints.historyless` globs
  (`tmp`, `.cache`, `*/.cache` by default).

`shred` and `wipe` are **ineffective in this stack** and must not be relied upon: a log-structured
filesystem never overwrites in place, and the SSD's flash translation layer relocates writes
regardless. Even `forget` frees blocks for reuse rather than erasing them. Disposing of a drive is
covered by LUKS, not by file deletion.

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

**Half closed as of 2026-10-05.** Grafana now listens on `127.0.0.1:3000` only, anonymous access
is off, and an auth proxy accepts `Tailscale-User-Login` from loopback. nginx publishes port 80 on
the pi's tailnet address alone and **overwrites** any client-supplied identity header, so a header
from the network is never trusted.

**What is still open:** the header nginx writes is hardcoded to the owner's login and
`auto_assign_org_role` is `Admin`, so every visitor authenticates as Max-as-admin. Real
per-request identity needs `tailscale serve`, which needs HTTPS enabled for the tailnet. This
remains a gate on Stage 3 onboarding, not a later polish item.

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
- **SnapRAID sync hardening: built and proven.** `nas-snapraid-sync` now runs `snapraid diff`
  between `touch` and `sync`, parses the `removed` and `updated` counts, and refuses when either
  exceeds `maxRemoved` (500) or `maxUpdated` (5000). It also refuses when any array device is not
  reporting SMART `PASSED`. It **fails the unit** rather than exiting 0, so a refusal is visible in
  `systemctl --failed` instead of looking like a quiet success.

  Verified on the live array: 600 files were created and synced in (allowed, `Everything OK`), the
  parity file's mtime and size were recorded, all 600 were deleted, and the sync then refused:

  ```
  diff: removed=600 updated=0
  refusing to sync: removed=600 (max 500), updated=0 (max 5000).
  Parity still reflects the previous state.
  ```

  Parity's mtime and size were byte-for-byte unchanged across the destructive step. Clearing a
  refusal is deliberate: run `snapraid sync` by hand once the change is confirmed to be intended.
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
| 2 | Storage. Image and repartition the SSD offline; `modules/nixos/nas/storage.nix` with LUKS, Clevis/Tang, unlock units, bcache, btrfs, mergerfs, mover, snapshot timer, SnapRAID and the degraded-mode guard. Execute the migration. | **migration done**, mergerfs pool + SnapRAID sync/scrub timers live; LUKS by manual passphrase. Clevis/Tang, bcache and the mover were never built, and the SSD write tier does not exist |
| 3 | Accounts and access. `accounts.nix` and `samba.nix`, `nas-user`, Tailscale device sharing, ACL reference. | **modules written and enabled**, SMB bound to `tailscale0` only; `nas-user.py` exists but is packaged by nothing, and the Tailscale sharing runbook is still unwritten. No account but Max's has ever been minted |
| 4 | Prefetch, browse index and metrics. `nas-prefetch`; `nas-index` (SQLite store, `find-new` reconciler, snapshot-diff version counter, thumbnailer); the metadata warmer; the new collectors; per-user dashboards; Grafana authentication. | **done bar two things.** `nas-index`, `nas-prefetch` and the `nas-usage` dashboard are built and enabled; Grafana no longer allows anonymous access. The metadata warmer is written but **not enabled on the pi**, and the dashboard is fleet-wide rather than per-user |
| 5 | Attic on `/srv/cache`, nginx vhost, `attic watch-store` on laptop and desktop, substituter for Max's hosts only. | **done** — `attic.nix` server on the pi, `attic-client.nix` on the pi, laptop and desktop; reachable on `tailscale0` only |
| 6 | Monitoring trim. | **done** — see `docs/monitoring.md`; ~800 MB freed, `MemAvailable` median 500 MB to 747 MB |
| 7 | Application-tier bake-off and adoption. |
| 8 | Follow-ons: offsite backup, 3-node mirror, bidirectional sync, the 2 x 8 TB purchase, the SSD upgrade with LVM. |

### Build progress

| disk | role | state |
|---|---|---|
| `sdb` | `disk2` | LUKS2 + **NILFS2**, mounted `/mnt/disks/disk2`, empty and available |
| `sdc` | parity | LUKS2 + btrfs, mounted `/mnt/parity`, synced over the final layout |
| `sdd` | `disk1` | LUKS2 + **NILFS2**, mounted `/mnt/disks/disk1`, holds the 434 GB live tree |

**Stage 2 is complete and retention is live.** Phase 1 validated NILFS2 on `disk1`; Phase 2 copied
the data back onto it (`rsync -aHAXn` reported zero differences), `disk2` was reformatted as
NILFS2, and `snapraid sync --force-empty` rebuilt parity to `Everything OK`. The suspend marker is
gone, so `nas-checkpoint-promote` runs every 15 minutes and every checkpoint is retained.

Verified end to end on the deployed system: four writes produced four versions with distinct UTC
timestamps, all four restored byte-identical by `sha256sum`, every referenced checkpoint was
retained, `nas-at` returned the correct historical content and refused writes, a file deleted along
with its parent directory still listed and restored its full history, and the `@GMT-` window
appeared on both branches with names correctly one hour behind local BST.

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

`local.nas.enable` is **true** on the pi. Every `config` block still sits behind `mkIf`, so the
tree is inert on every other host, but on the pi it contributes `nas-snapraid-sync`,
`nas-snapraid-scrub`, `nas-index`, `nas-checkpoint-promote` (the history pass), `nas-history-walk`,
`nas-at-view`, one `nas-history-watch-<branch>` and one `nas-prefetch-<branch>` per data disk, `atticd`, their timers and
the cifs automount.

| file | provides | on the pi |
|---|---|---|
| `accounts.nix` | `local.nas.accounts`, explicit uids 3000-3999, homes 0700, uid-uniqueness assertion, and `/etc/nas/identity-map` from each account's `tailscaleLogin` | enabled, two accounts |
| `samba.nix` | one private share per account, `valid users` scoped to the owner, SMB3 + required encryption, `shadow_copy2` over the time view | enabled, `tailscale0` only |
| `storage.nix` | mergerfs pool with the placement policy from section 4, SnapRAID config, sync and scrub timers that no-op unless every branch is mounted | enabled |
| `index.nix` + `nas-index.py` | SQLite browse index, `find-new` incremental scan, version counts from the history index, thumbnailer, per-user usage and file-age metrics | enabled |
| `checkpoints.nix` + `nas-at.py` | the history index and pass (promote, scan, rules, reclaim, metrics), the `fatrace` watchers, the `/srv/nas-at` time view with its `@GMT-` names, `nas-at log/top/revert/keep/forget/pin` | enabled |
| `nilfs-utils.nix` + `nilfs-history.patch`, `nilfs-reclaim.c`, `nilfs-lives.c` | nilfs-utils 2.3.1 with the per-inode liveness callback, the explicit-segment reclaimer and the log reader | enabled |
| `streams.nix` | tailnet rsync daemon modules; each completed transfer becomes one NILFS2 snapshot | enabled, `minecraft` on `disk1` |
| `prefetch.nix` | `nas-prefetch`: `fatrace -c -f O -j` driving a read-ahead loop with per-directory cooldown, file and byte budgets, a bulk-reader ignore list and textfile counters | enabled, one unit per branch |
| `unlock.nix` | `nas-unlock-local`/`nas-lock-local` plus `nas.target` on the server; `nas-unlock`/`nas-lock` on the client | server on the pi, client on the laptop |
| `attic.nix` | atticd on `/srv/cache`, nginx vhost and TLS, 7-day GC | enabled, `tailscale0` only |
| `attic-client.nix` | netrc and config, substituter and trusted key, `attic watch-store` hook | enabled on the pi, laptop and desktop |
| `client.nix` | cifs automount of `//127.0.0.1/<share>` through `peerTransport`, SMB3.1.1 `seal`, 10-minute idle timeout, `nas-set-password` | enabled on the pi, laptop and desktop |
| `cache.nix` | metadata warmer, run inside the SnapRAID window while disks already spin | **written, not enabled** |
| `web.nix` + `nas-web-dispatch.py` | identity-mapped browser: one `copyparty` worker per account, as that account, in `nas-web.slice` | **written, not imported** |
| `enroll.nix` + `nas-enroll-web.py` | one-time enrolment tokens so an owner sets their own Unix and SMB passwords | **written, not imported** |
| `nas-user.py` | proposes an account (random uid in 3000-3999, the Nix block, the sops and `smbpasswd` steps) and applies nothing | **packaged by nothing, on no PATH** |

Metrics exported for dashboards, all read from the index rather than the array so no exporter
ever wakes a disk: `nas_user_bytes`, `nas_user_files`, `nas_user_directories`, `nas_age_bytes`,
`nas_age_files`, `nas_oldest_file_seconds`, `nas_metadata_warm_entries`,
`nas_metadata_warm_seconds`, `nas_metadata_warm_timestamp_seconds`, `nas_branch_size_bytes`,
`nas_branch_used_ratio`, `nas_checkpoints`, `nas_checkpoint_snapshots`, `nas_history_bytes{state}`,
`nas_history_metadata_bytes`, `nas_history_rules`,
`nas_metrics_timestamp_seconds` and `nas_prefetch_{files,bytes,skipped}_total`. The `NAS usage`
dashboard (uid `nas-usage`, in the metrics folder) charts totals, per-account usage, file age and
warm-pass age, plus history bytes by state and, through a SQLite datasource on the history
index, history by write day. Alerts live in `modules/nixos/monitoring/rules.nix`: `nas-branch-filling`,
`nas-branch-nearly-full`, `nas-array-unmounted` and `nas-metrics-stale`.

Two gaps in that list. The warm-pass age panel reads permanently stale because `cache.nix` is not
enabled, and the `nas_prefetch_*` counters have no panel and no alert despite prefetch running.

**Grafana is no longer anonymous, but it is not per-user either.** Anonymous access is off and an
auth proxy accepts `Tailscale-User-Login` from loopback only. What nginx hands it is **hardcoded**
to the owner's login, and `auto_assign_org_role` is `Admin`, so this is one passwordless admin
identity rather than real per-request identity. Section 1's requirement that each person sees only
their own usage plus an aggregate of everyone else needs `tailscale serve` supplying the real
header, which needs HTTPS enabled for the tailnet. Until that lands, treat these panels as an
operator view and do not share the Grafana URL with NAS account holders.

Built and inert is **not** the same as working. What has now been exercised against the live array
is storage, checkpoints, versions and parity (section 15's build progress); what has not is every
module still marked "not enabled" or "not imported" above.

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

## 18. Power: three hard resets in one night

On 2026-08-19/20 the pi hard-reset three times: 20:49, 00:38 and 02:54. Each was abrupt, with the
journal ending mid-activity and no shutdown sequence.

**It is not software.** `below` samples every 5s and shows the machine healthy in the sample before
each death: ~300 MB free, zero swap, zero blocked processes, 2-4 running. A watchdog timeout would
have left a trail of degraded samples over its 60s window; there is none. `throttled=0x0` and
EXT5V reads 5.04 V at idle, which does not rule out a transient sag under load.

**Correction, 2026-10-06: "it is not software" was never safe to conclude.** Every always-on host
ran with `oops=panic` and `panic=10` (`modules/nixos/power.nix`), so a kernel Oops rebooted the box
ten seconds later, before journald could flush the backtrace. A software crash and a power fault
therefore produced *identical* evidence: a journal ending mid-activity with no shutdown sequence.
The absence of a trail is explained by the reboot policy, not by the absence of a bug. `below`
samples prove only that the machine was healthy ~5s earlier, which a NULL-pointer dereference does
not contradict.

This is no longer hypothetical. On 2026-10-06 at 19:58:30 the pi died the same way, and the
surviving journal shows the cause outright:

```
Unable to handle kernel NULL pointer dereference at virtual address 0000000000000028
FSC = 0x05: level 1 translation fault
Internal error: Oops: 0000000096000005 [#1]  SMP
```

The journal stops there: the backtrace itself never reached disk, which is exactly the evidence
`oops=panic` destroys. So at least one of these "hard resets" was a kernel bug, and the three
August events cannot be attributed to power on the strength of the missing trail alone. The scrub
correlation stands on its own, but it is weaker than section 18 originally claimed, because a scrub
is also the heaviest *software* path (SnapRAID plus NILFS2 plus mergerfs plus the fanotify
watchers), not only the heaviest electrical load.

`local.power.oopsPanic` now exists for exactly this. It defaults to `true`, keeping the
reboot-on-Oops behaviour an unattended server wants, and is set `false` on the pi while the crash
is under investigation, which drops `oops=panic` and sets `kernel.panic_on_oops = 0` so the next
Oops is survived and fully logged. The journal is persistent, so the trace lives across a reset.
Re-enable it once the bug is identified.


**The third reset happened while the full scrub was reading all three disks**, which is the
heaviest current draw this hardware ever sees: a Pi 5 plus three HDDs through a SATA HAT. That
correlation is the strongest evidence available and points at power delivery.

Consequences observed, all recovered cleanly:

- The array stays locked after a reset, by design, so nothing mounts unattended and nothing was
  damaged. 435 GB intact each time.
- A reset mid-deploy leaves deploy-rs stuck at `Activating profile`; the generation still advances.
- A scrub interrupted by the reset reports `Result=success` having scrubbed nothing, because the
  array vanished underneath it. `snapraid status` reporting all content files "on the same disk" is
  the tell that the branches are unmounted.

`modules/nixos/unclean-boot.nix` now records this without help: a marker written on clean shutdown,
absent after a hard reset. It caught the 02:54 event unaided and exported
`node_boot_unclean_total 4` with a journal warning, surfaced on the System dashboard and alerting
at `for: 0s`.

**Do not re-run a full scrub until the power question is settled**; it is the most demanding
workload available and has now been adjacent to a reset twice.

## 19. autoUpgrade uninstalled the NAS

On 2026-09-30 at 23:58 the pi's `nixos-upgrade` ran for the first time, four weeks after
`7cab804` enabled it, and switched the machine to a configuration from 2026-08-08. Generation 134
had **no `nas-*` units at all**, no `nas-unlock` on `PATH`, and no nginx or Grafana. It stayed
that way for five days.

`system.autoUpgrade.flake` in `modules/nixos/common.nix` points at `${flakePath}#${hostName}`,
where `flakePath` is `/home/max/.config/nix` on the host being upgraded. The pi's clone sat at
`6f843fe`, 328 commits behind `main`, and dirty. So the upgrade dutifully built *that* and
activated it.

Nothing failed. The build succeeded, the switch succeeded, the generation advanced. The only
trace was a `warning: Git tree '/home/max/.config/nix' is dirty` in the upgrade's own journal.

**Nothing was lost.** The disks stayed LUKS, every UUID in `hosts/pi/default.nix` still resolved,
and the array simply stayed locked, which is what section 6 specifies after an unattended boot.
The NAS was uninstalled, not damaged.

Two things make this worse than section 18's hard resets. First, it is silent: a reset leaves a
truncated journal and now trips `node_boot_unclean_total`, whereas this looks like a successful
deploy. Second, it is self-inflicted by a safety feature, and it can recur on any host whose
clone lags — the hazard the multi-host warning in `CLAUDE.md` already described.

`system.autoUpgrade.enable = false` on the pi closes it there. The laptop and the desktop still
have it on: the laptop's clone is current by construction because that is where the work happens,
the desktop's is not guaranteed. The structural fix, not taken, is to point the flake at
`github:MaxCarroll0/nixOS-config#<host>` so an upgrade is incapable of deploying something older
than what is running.

### Runbook: restore the pi after a configuration regression

1. Confirm the regression rather than assuming it: `systemctl list-unit-files | grep -c nas-`
   returns `0`, and `findmnt | grep -E 'disks|parity|srv/nas'` is empty.
2. Confirm the data is untouched: `lsblk -o NAME,SIZE,SERIAL,FSTYPE,UUID` must still show
   `crypto_LUKS` on every array device, and each UUID in `hosts/pi/default.nix` must resolve under
   `/dev/disk/by-uuid/`.
3. Commit and push the intended configuration from the laptop, then deploy it.
4. An **agent-authorized** `deploy-request` cannot do step 3 if the stranded generation predates
   `modules/nixos/pam-ssh-agent-sudo.nix`: activation dies at `sudo: a password is required` after
   a full successful build and copy. Break that loop with one interactive terminal
   `rebuild --host pi switch`, which prompts for the pi's sudo password on a tty.
5. `nas-unlock` from the laptop, then `sudo bash docs/nas-verify.sh` on the pi.
6. `git -C /home/max/.config/nix pull --ff-only` on the pi, so its own clone can no longer
   activate the old configuration.

Both blockers in step 4 come from the same shape of problem: the stranded generation predates the
mechanism its own replacement needs.

- No `pam_ssh_agent_auth` in `/etc/pam.d/sudo`, so an agent-authorized deploy dies at
  `sudo: a password is required` after a full successful build and copy.
- No `activate-detached` on `PATH`, while `flake.nix` sets `sudo = "sudo activate-detached"`.
  deploy-rs prefixes that string verbatim and appends the activation user, so activation would run
  `sudo activate-detached root …` and fail with command not found.

One command clears both, from a real terminal rather than an agent:

```bash
NIX_OBSERVER_PLAIN=1 rebuild --host pi switch --sudo "sudo -u"
```

`rebuild` forwards trailing arguments to deploy-rs and leaves `--interactive-sudo` at the node
default, so this prompts for the pi's sudo password; a genuine tty is required, since without
`/dev/tty` deploy-rs sends an empty password and never prompts.

Dropping `activate-detached` for that one hop is safe here only because the restart that would
otherwise kill the session cannot happen: `tailscaled.restartIfChanged = false`, and
`tailscaled-autoconnect` is forced off the activation path onto a timer. The deploy arrives over
Tailscale SSH, which lives inside `tailscaled`. Magic rollback still applies. Do not generalise
this to a deploy that *does* restart a connectivity service.

## 20. Parity silently stopped syncing for six weeks

Found on 2026-10-06 while verifying the restore. `snapraid status` reported the newest block
scrubbed **44 days ago**, even though `nas-snapraid-sync.timer` had been active throughout the
15-30 September window when the NAS was deployed and running.

`nas-unlock-local` mounted every data branch and the mergerfs pool, and then started
`nas.target` — which is an empty target with `wantedBy = [ ]`. **Nothing ever mounted
`/mnt/parity`.** Both `nas-snapraid-sync` and `nas-snapraid-scrub` open with

```bash
for m in <data mounts> /mnt/parity; do mountpoint -q "$m" || exit 0; done
```

so with parity unmounted they exited **0** on every run: a silent no-op that systemd records as
success, with no failed unit and no alert. The array's entire recovery guarantee was off while
every indicator said it was on.

Nothing was lost. `snapraid diff` reported `No differences` across 1453 files, because the array
is `noauto` and spent that period locked, so there were no writes to protect. The bug was latent,
not destructive — but it would have bitten the first time a file changed.

Two fixes, both in `modules/nixos/nas/unlock.nix`:

- the unlock mounts `/mnt/parity` alongside the data branches, from one `mountTargets` list shared
  by the mount loop and the count, so the two cannot drift apart again
- the unlock reports `mounted=N/M` and **fails** unless every target mounted. It used to return
  success on `mounted > 0`, so a partially mounted array looked fine; `nas-unlock` on the client
  now surfaces that as a failed notification

The deeper lesson is the `|| exit 0` guard itself: it was written so the timers would not fail on
a locked array, and the cost is that a *misconfigured* array is indistinguishable from a
deliberately locked one. `docs/nas-verify.sh` now checks `/mnt/parity` explicitly, which is what
caught it.

### Runbook: adding a data disk

`modules/nixos/nas/{storage,unlock,checkpoints,versions,prefetch}.nix` are all generic over
`local.nas.storage.dataDisks`, so a new branch needs **no module changes** — only the host, plus
the on-disk setup. SnapRAID requires parity to be at least as large as the largest data disk;
confirm that before promoting anything.

1. **Prove the disk is disposable.** Mount every partition read-only and look, before any wipe.
   Use `-o ro,noload`, because a plain `-o ro` still replays the ext3/ext4 journal and writes to
   the disk you are trying to preserve. `du -xh --max-depth=1` is worth the wait: the 1 TB disk
   added as `disk3` looked like a spare and held 787 GB of Humax PVR recordings.

2. **Whole-disk LUKS2, no partition table**, matching the existing members, and the **same
   passphrase from `secrets/nas.yaml`** — `nas-unlock-local` pipes one key to every device, so a
   different passphrase silently breaks unlock for that branch alone. Clear the old signatures,
   `luksFormat --type luks2`, `luksOpen` it as `nas-disk3`, make a NILFS2 filesystem on the
   mapper device, then record the **LUKS** UUID from `lsblk -o NAME,SERIAL,UUID` (not the
   filesystem's).

3. **Declare it by UUID** in `local.nas.storage.dataDisks`, never as `/dev/sdX`: device letters
   shift when disks are added, and they already have on this host.

4. **Deploy with the pool unmounted.** The mergerfs device string *is* the branch list, so adding
   a branch changes it, and a busy FUSE mount cannot be reloaded in place:

   ```bash
   nas-lock && deploy-request --host pi switch && nas-lock && nas-unlock
   ```

   The second `nas-lock` is not a typo: the deploy restarts `srv-nas.mount` while the array is
   locked, leaving mergerfs mounted over empty branch directories, so the pool has to come down
   again before the real unlock. Expect the first `nas-lock` to need a retry (section 23).

5. **Suspend checkpoint promotion first**, with `/run/nas-promote-suspended`. Mounting a NILFS2
   checkpoint while the array is under heavy write load Oopses the kernel (section 22), and a sync
   is exactly that load. The file lives in `/run`, so a reboot silently re-enables promotion:
   re-create it after any restart that happens mid-job.

6. **Sync parity, and do not reach for `--force-empty`.** A brand-new data name has no recorded
   files, so the guard does not fire; if it does fire, something is wrong with the *existing*
   branches and the override would overwrite parity with their absence. Confirm with
   `snapraid status` (new disk listed and empty) and `snapraid diff` (`removed=0`) before starting
   `nas-snapraid-sync.service`. Read the SMART attributes of the new disk in full rather than only
   reallocated/pending/uncorrectable: a tripped lifetime counter will stop the sync, and section 23
   explains when that is worth respecting.

7. **Check parity actually mounted** (`findmnt /mnt/parity`). Section 20 exists because it was
   not, and sync then exits 0 while doing nothing.

Run step 6 attended and check `node_boot_unclean_total` afterwards: a sync reads every disk at
once, the heaviest load this hardware sees, and section 18's power question is unsettled.

## 21. The lock said "locked" while the array was still open

Found on 2026-10-06, immediately after section 20's fix, while locking the array to protect it
during a crash investigation. `nas-lock-local` printed nothing and exited 0, and the array was
still mounted and still unlocked. Three distinct faults stacked:

1. **It stopped the wrong thing.** `systemctl stop nas.target` tears down nothing: `nas.target`
   has `wantedBy = [ ]` and no unit is `PartOf` it, so it is an empty handle (the same property
   that hid section 20's bug).
2. **It did not verify.** Every step ended in `|| true`, and there was no check afterwards, so a
   complete failure to unmount was reported as success. Same shape as section 20: the happy path
   and the total-failure path produce identical output.
3. **A bare `umount` cannot release the branches.** This is the real mechanism, and it is not
   obvious. `nas-history-watch-disk{1,2}` (then `nas-versions-watch`) and `nas-prefetch-disk{1,2}` are four `fatrace`
   processes whose `WorkingDirectory` is inside the branch, and they are correctly declared
   `partOf = [ mountUnit ]`. But **`PartOf=` propagates only a unit stop.** `umount` takes the
   mount down behind systemd's back, the `.mount` unit is never stopped, the watchers are never
   signalled, and their open descriptors keep the branch busy:

   ```
   umount.nilfs2: /mnt/disks/disk2: target is busy
   ```

The fix is to go through the mount units in both directions, so systemd's own dependencies do the
work:

```bash
systemctl stop "$(systemd-escape -p --suffix=mount "$m")" || true
mountpoint -q "$m" && umount "$m" || true     # fallback for mounts systemd does not own
```

Verified live: stopping `mnt-disks-disk{1,2}.mount` took all four watcher units to inactive and
both NILFS2 branches unmounted with no "target is busy", after which `luksClose` succeeded and
the lock reported `locked` truthfully. The unlock path now uses `systemctl start` for the same
reason, so `wantedBy = [ mountUnit ]` pulls the watchers back up instead of relying on systemd
noticing an external mount.

The lock also now counts what is still mounted and still open and fails loudly:

```
not locked: 2 still mounted, 2 still open
```

**Operational note:** `cryptsetup` is not in the pi's system PATH. Only `nas-lock-local` and
`nas-unlock-local` carry it inside their own closures, so an ad-hoc `sudo cryptsetup luksClose`
fails with `command not found`. Use the wrappers, not the raw tool.

Three "reports success while doing nothing" bugs were found in this module tree in one day
(sections 20, 21, and the attic queue). The common cause is `|| true` / `|| exit 0` on a step
whose failure is indistinguishable from a legitimate skip. Any such guard in this tree should be
paired with a count-and-verify afterwards, which is what both fixes now do.

A fourth instance was in `docs/nas-verify.sh` itself, which is the tool trusted to catch the other
three. It judged three oneshots by `systemctl show -p Result --value`, and **systemd prints
`success` for a unit that does not exist at all**, so the check could not distinguish "ran and
succeeded" from "was never built". All three units it names are in fact missing:

| unit | state |
|---|---|
| `nas-smb-passwords` | exists in no `.nix` file; the samba passdb holds `max` and `nastest`, set by hand, so SMB auth is not declarative and an empty passdb would be silent |
| `flight-recorder` | `modules/nixos/flight-recorder.nix` is imported by no host |
| `tailscale-identity` | exists nowhere in the repo |

The script now checks existence with `systemctl cat` before reading `Result`, so a missing unit
fails. The three gaps above are real and still open; the verification was simply never reporting
them. `smb-password-max` is the related secret: it is referenced only by the verify script, exists
in no sops file, and is why the SMB authentication path has never actually been exercised.

## 22. The reset was a NILFS2 bug, caught in the act

On 2026-10-06 at 21:20:32, with `local.power.oopsPanic = false` in force and the journal
persistent, the pi finally produced a complete trace of the crash section 18 attributed to power:

```
CPU: 2 PID: 148176 Comm: mount.nilfs2   (kernel 6.18.34, aarch64)
Unable to handle kernel NULL pointer dereference at virtual address 0000000000000028
pc : nilfs_ifile_get_inode_block+0x18/0xb8 [nilfs2]      x0 = 0000000000000000
Call trace:
 nilfs_ifile_get_inode_block
 nilfs_iget
 nilfs_get_root_dentry
 nilfs_get_tree
 vfs_get_tree
 __arm64_sys_fsconfig
```

The faulting process is `mount.nilfs2`, and the path is a **mount of a NILFS2 checkpoint**, not
anything in the write path. The call is this one, in `modules/nixos/nas/checkpoints.nix`:

```bash
mount -t nilfs2 -o "cp=$cno,ro" "$device" "$snapdir/$name"
```

which is how checkpoints become the `@GMT-*` generations SMB serves as Previous Versions.
`nas-checkpoint-promote.timer` runs it every 15 minutes (`local.nas.checkpoints.interval`).
**The timer fired at 21:20:29 and the Oops was at 21:20:32.**

This retires the power hypothesis as the primary explanation:

- the death at 19:58:30 the same evening has a byte-identical signature, and the 15-minute promote
  cadence lands exactly on 19:43 and 19:58
- the bursts of `nas-prefetch` `/proc` churn either side of that crash, which looked like a
  fanotify storm, were this machinery walking and mounting, not read-ahead
- the three August resets were all judged "not software" on the strength of a missing trace, which
  `oops=panic` guaranteed would be missing

The scrub correlation in section 18 also reads differently now. A scrub is write- and
mount-adjacent, and it runs on the same array the promote timer keeps mounting, so "the heaviest
electrical load" and "the moment most checkpoints exist to be mounted" are the same window.

**Mitigation, which the design already shipped and we failed to use.**
`local.nas.checkpoints.suspendFile` defaults to `/run/nas-promote-suspended` and its description
reads "use it during bulk ingest". `nas-checkpoint-promote` carries
`unitConfig.ConditionPathExists = "!${suspendFile}"`, so the promotion is skipped cleanly (not
failed) while the file exists. Create that file before any bulk write or a `snapraid sync`, and
delete it afterwards.

It lives in `/run`, so a reboot re-enables promotion by itself: suspension cannot be left on by
accident across a restart, and equally cannot be relied on to persist.

**Open, and not fixed here.** The underlying fault looks like an upstream NILFS2 bug: a NULL
`ifile` when mounting a checkpoint while the filesystem is under heavy write load. Nothing in this
repo can fix that. What this repo can do is stop mounting checkpoints during bulk writes, which is
what the suspend file is for. Until the bug is understood upstream, treat the Previous Versions
window as unsafe to refresh concurrently with a large ingest, restore or sync. Keep
`oopsPanic = false` on the pi while this is open, because with the default the next occurrence is
once again an unexplained reboot rather than a trace.

## 23. The sync guard latched on a counter that can never fall

Adding `disk3` on 2026-10-07 was blocked by `nas-snapraid-sync`:

```
refusing to sync: /dev/disk/by-uuid/b1a560af-... is not reporting SMART PASSED
```

The message was wrong on its face: that disk *does* report `PASSED`. The guard was

```bash
if ! smartctl -H "$dev" | grep -q "PASSED"; then
```

and `writeShellApplication` sets `pipefail`, so the pipeline fails whenever **`smartctl`** exits
non-zero even though `grep` matched. `sdb` exits **32**, which is bit 5: a *usage* (`Old_age`)
attribute at or below threshold. Not bit 3 (DISK FAILING) and not bit 4 (a pre-fail attribute),
either of which would be a real reason to stop.

The attribute was `184 End-to-End_Error`, and the key property is that **a lifetime counter never
falls once tripped**. So the guard had latched permanently: every nightly sync would fail for the
remaining life of the drive, parity would never advance, and the array would sit unprotected. That
is section 20's outcome reached by the opposite route, and the only mercy is that this version
fails loudly instead of exiting 0.

The guard now distinguishes what is actionable from what is merely historic:

- overall health must say `PASSED`
- refuse on `smartctl` exit bit 3 (DISK FAILING) or bit 4 (pre-fail attribute past threshold)
- refuse on any non-zero `197 Current_Pending_Sector` or `198 Offline_Uncorrectable`, the sectors
  that are unresolved *right now*
- a bit 5 usage counter prints a `note:` and does not stop the sync

Verified in both directions before deploying, which is the only way this kind of change is worth
anything: `Current_Pending_Sector=5` refuses, `Offline_Uncorrectable=2` refuses, a pre-fail
attribute refuses, `FAILED!` refuses, and `sdb`'s historic-only profile is allowed with a note,
while `sdc`/`sdd`/`sde` pass clean. The first attempt at that test used hand-written rows with
eight fields instead of `smartctl -A`'s ten, so `$10` was empty and every case wrongly "passed" —
worth remembering that a guard test can fail open just as silently as the guard itself.

### `nas-lock` can need a second attempt

With the Previous Versions window populated, the first `nas-lock` after heavy use reports

```
umount.nilfs2: /mnt/disks/disk1: target is busy
not locked: 2 still mounted, 1 still open
```

and a plain retry succeeds. The cause is the ~50 `@GMT-*` checkpoint submounts: stopping
`srv-nas.mount` races their teardown, so the pool is briefly still busy. Nothing holds it open
afterwards (`lsof` on both the pool and the branch is empty), so **retry before investigating**.
A tempting wrong answer here is the mount namespaces of sandboxed services (`ProtectSystem=strict`
and friends), which do each hold a copy of these mounts; they are `shared` propagation, so an
unmount propagates to them and they are not the cause.

### Deploying a branch change leaves the pool over empty directories

A `switch` that changes the mergerfs device string restarts `srv-nas.mount`. If the array is locked
at that moment the unit starts anyway and mergerfs mounts over the bare, empty branch
*directories*. The pool then looks healthy and is empty. Always finish a branch change with a full
`nas-lock` and `nas-unlock` cycle so the branches are mounted before the pool is built on them;
`nas-unlock` orders that correctly, a deploy does not.

## 24. The browse index made one disk structurally unparkable

The array ran for 23 hours after the `disk3` sync with disk1 never spinning down once, while the
other three disks parked normally. The question "why are the disks still spinning" had an answer
that none of the obvious suspects covered.

Spin-down is **entirely userspace**, which is the first thing to know and supersedes the
`hdparm -S` note in section 14. A udev rule applies `hdparm -B <apm> -S 0`, *disabling* the
drive's own firmware timer, and `enforce-disk-idle.timer` (every 60 s,
`modules/nixos/storage.nix`) does the parking. It parks a disk only when **both** gates are clear:

- `now - idle_since >= 3600`, where `idle_since` resets on any change to `$6 + $10` of
  `/proc/diskstats` (sectors read plus sectors written)
- `now - last_standby >= 3600`

State lives in `/var/lib/disk-spindown/<dev>` as three numbers: `io idle_since last_standby`.

The waker was `nas-index.service`, whose timer was `OnUnitActiveSec = 15m`. It walks the whole
mergerfs pool to refresh the browse cache, thumbnails and per-user usage metrics. The effect was
asymmetric because the data is:

| branch | files | last parked |
|---|---|---|
| disk1 (`sde`) | 2827 | never, 39 h |
| disk2 (`sdd`) | 1 | 46 min ago |
| disk3 (`sdb`) | 1 | 26 min ago |
| parity (`sdc`) | n/a | 18 min ago |

A walk over 2827 files is real block I/O on disk1 and essentially nothing on the near-empty
branches. So disk1's `idle_since` reset four times an hour and the 3600 s gate was **unreachable
by construction** — not bad luck, but arithmetically impossible for as long as that timer ran.
The branches with nothing to walk parked on schedule, which is exactly what made the fault look
mysterious rather than systemic.

The fix is `local.nas.index.interval = "6h"` (now the module default). A disk parks ~3660 s after
each walk and stays parked for the rest of the cycle, so disk1 goes from 0% parked to ~83%.
Staleness costs nothing that matters: `nas-history-watch-*` sees every change live through
fatrace, so history is unaffected and only the browse cache, thumbnails and the usage panel
lag. A better design would trigger the index from the watcher instead of a timer, at which point
the interval stops mattering at all.

### Two wrong turns worth recording

**Measuring writes, not reads.** The first hypothesis was NILFS2 `segctord` superblock writes. Write
sectors were static across 140 s on all four disks, which disproved it, but the measurement never
looked at *read* sectors and so missed the actual activity.

**A four-minute window proves nothing against a fifteen-minute period.** A correlation run watching
read sectors at 5 s granularity emitted no deltas at all and was briefly taken as "nothing is
reading them". It had simply landed between two index runs. Any window used to rule out a periodic
waker must exceed the longest candidate period.

**The ATA blind spot is real but was not the cause.** `drive-selftest.timer` (5 m),
`textfile-smart-health.timer` and `textfile-hwmon-drive-temperatures.timer` issue commands that
can spin a disk up without registering in `/proc/diskstats`, so `enforce-disk-idle` cannot see
them as activity. That was floated as the explanation, and the evidence contradicts it: `sdc`
stayed parked across several selftest ticks. `modules/nixos/monitoring/smart.nix` is why: both
collectors gate on the same `$6 + $10` diskstats comparison and serve a cached reading for a drive
that has not moved, and the health probe additionally passes `smartctl -n standby`, which returns
without spinning the motor up.

### The interval alone leaves a floor, so the walk follows history instead

Raising the interval was confirmed working: `sde` entered standby 17 minutes after becoming
eligible, its first park in 39 hours, and all four disks were parked together for the first time
since the `disk3` addition. But a 6 h timer still wakes the fullest disk four times a day whether
or not anything changed, which is a floor of pointless spin-ups on an array that is idle for weeks
at a time.

The first fix was an `ExecCondition` that skipped the walk unless
`/var/lib/nas-checkpoints/events/<branch>.jsonl` had grown since the last index. It stopped
working the day the Minecraft rsync stream arrived: `backups/streams/minecraft` writes to disk1
every few minutes, so the events file always grew, the gate always passed, and every 6 h run
walked the whole pool. mergerfs with `category.search=ff` probes every branch on `readdir` and
`getattr`, so the walk woke disk2 and disk3 too, for a write that only ever touched disk1.

A second fault made each wake last over an hour. `history_counts` joins the history db's `paths`
to `lives` (2.95 M rows on the pi). Once `lives` grew past `paths`, SQLite's planner flipped to
`SCAN lives` with a per-row lookup into `paths`, and a run took 66 minutes of CPU, keeping its
branch's `idle_since` fresh for the whole time. `CROSS JOIN` pins `paths` as the outer loop and
the same query takes 9 s.

**The index is now incremental, driven by the history db.** A NILFS2 checkpoint cno is a free,
monotone change counter, and the history pass already records which paths changed at which cno:

- `paths.since` is the cno a row was inserted at, `paths.hi` the cno it closed at, and
  `lives.s` the cno a block was born at. A path changed after cno `c` exactly when one of those
  exceeds `c`.
- `history_marks(branch, seen, settled)` in the index db carries a one-run lag.
  `index_branch` commits the new checkpoints mid-pass, before the `lives` scan for them has
  finished, so the head cno read during a run can be ahead of the rows. Each run queries rows
  newer than `settled`, then shifts `seen` into `settled` and the current head into `seen`. A
  path is therefore picked up at most one run late, never missed, and re-recording it is
  idempotent.
- Each changed path is stat'ed on the branch that holds its open row, never through the pool,
  so no other branch is touched. A path with no open row is deleted from the index along with
  everything under it. The hidden flag comes from rows already in the index db. A changed
  `.nashidden` falls back to a full walk of that owner only.
- With nothing changed, a run reads two SQLite files on the SSD and exits before writing metrics.

The timer runs at the checkpoint interval. `nas-index-full.timer` walks everything with `--full`
once a day in the checkpoint walk window, when the disks are awake for the reconcile walk anyway,
which also catches anything the watcher missed. The `ExecCondition`, its stamps and the 24 h
escape hatch are gone.

`checks.nas-at` covers it: a rewrite, a removal and a rename are all reflected on three
consecutive runs, a change under another owner is indexed without walking the first, an idle run
leaves the disk's read counter unchanged after `drop_caches`, rows deleted from the index db come
back only with `--full`, and `--full` reproduces the incremental rows exactly. A file written while
the watcher is stopped is not a gap: the next watched event in its parent makes the pass rescan
that directory, so history and the index both pick it up.

## 25. Continuous streams and the time view

**Requirement.** Pick any file or directory and any instant, and see it as it was, to the
millisecond, wherever the rules (4.6) retained it. The Minecraft server in `damien-fedora` on desktopnew
is the first stream, captured every 60 s.

**Any instant is already on disk.** NILFS2 writes a log per sync, and every log is a checkpoint;
there is no on-disk state between two logs. Every branch mounts `nogc`, the pass snapshots every
checkpoint, and nothing is collected except what a rule drops.

**The index** is the history index of 4.5.2: checkpoints are appended with `lscp -a -i <last+1>`,
and metrics come from `/sys/fs/nilfs2/<dev>/checkpoints/*_number` in O(1).

**How a time maps to a file.** For an ordinary path at time T the view takes the latest retained
edit of that inode at or before T, from `lives` rather than from ctime guesses, and serves it from
an already-mounted checkpoint when no edit lies between the two. Two writes inside one log cannot be
told apart: that is the real precision limit, set by how often the writer syncs. Stream paths
resolve by **capture** time instead, to the newest point captured at or before T, however late it
was applied.

**The Minecraft stream.**

```
guest damien-fedora: minecraft-backup.timer (1 min)          pi
flock -s /run/keep-running.lock
console save-off; save-all flush
rsync --inplace --block-size=4096 ---------------------> rsyncd module (under the write lock)
console save-on (ExecStopPost)                           post-xfer: mkcp -s, points(captured -> cno)
```

- NILFS2 stores every block written, identical or not, so the copy must write only changed
  blocks. `rsync --inplace --no-whole-file` compares and skips matching 4 KiB blocks; Minecraft
  rewrites only changed sectors, so each point costs what actually changed.
- The world is consistent only between `save-all flush` and `save-on`; the rsync runs inside that
  window (a few seconds; the game keeps running, only disk writes pause).
- The guest owns the service: `/etc/systemd/system/minecraft-backup.{service,timer}` and
  `/usr/local/libexec/minecraft-backup`. The timer is `WantedBy=` and `PartOf=minecraft.service`,
  and the shared lock keeps idle shutdown from stopping the VM mid-pass.
- The guest pushes to `192.168.122.1:8020`; `vm-isolation` DNATs that to pi:8020 over `tailscale0`
  and libvirt masquerades it to desktopnew's tailnet address. Nothing else leaves the VPN and
  nothing can connect back in. The module is write-only and accepts only desktopnew.
- The guest never addresses the pi directly: it runs its own Tailscale (a different tailnet),
  whose route table claims 100.64/10 and whose `ts-input` drops CGNAT-sourced replies arriving
  on `enp1s0`.
- No buffering: if the pi is down or the array locked, that minute is a gap and the next pass
  catches up. A failed transfer takes no snapshot, so only complete points are listed in `points`.
- Each point writes `/var/lib/nas-streams/<stream>.last` on the pi, and the Satisfactory restic
  store stamps `/var/lib/satisfactory-backup/last`; the panel reads both, so last-backup times
  show while the desktop sleeps.
- Measured pi cost (synthetic 1 GB tree): about 0.1 CPU-s per idle minute, 1.3 CPU-s for a minute
  rewriting 30 region files; the larger load is reading changed files on the branch.
- Commands go to the guest's console FIFO (`/run/systemd/minecraft.stdin`); `enable-rcon=false`.
- Transfers hold `/run/nas-nilfs-write.lock`, like every checkpoint mount (section 22) and parity
  sync. Parity protects the latest state only; NILFS2 history lives on `disk1` alone.
