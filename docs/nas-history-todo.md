# NAS history TODO

References: see [NAS history references](nas.md#nas-history-references).

- [x] Draft implementation (Phase 0 prototype, then components 1-5)
- [ ] Age-graded resolution, design undecided. It must never merge two sessions. Refs: Santry et al.,
      "Deciding when to forget in the Elephant file system", SOSP '99 §2.3 (age-dependent
      indistinguishability); btrbk retention policy; Time Machine thinning
- [ ] Content-diff large-delta landmarks (the net-shrink proxy misses rewrites in place)
- [x] `keep --target`: the 11-quantum sweep on the pi's db went from 146.7 s to 0.26 s by framing the timelines once
- [x] `top`: 0.91 s to 0.024 s on the pi's db, from the `tallies` table the pass maintains
- [ ] Stage B evaluation (scratch NILFS2 on the pi's LUKS and bcache stack) and 2 h disk parking;
      Previous Versions (24 versions) and SnapRAID diff after reclaim pass in the VM
- [x] Summary-only log reads: `nilfs-lives` read whole segments under the disks' 8 MiB read-ahead
      (2.4 TB backfill); `MADV_RANDOM` on the segment mapping cut a 256 MiB scan to 3.4 MB
- [ ] Upstream the libnilfsgc liveness callback and the `MADV_RANDOM` segment mapping to nilfs-utils
