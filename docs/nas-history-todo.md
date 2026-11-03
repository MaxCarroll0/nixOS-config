# NAS history TODO

References: see [NAS history references](nas.md#nas-history-references).

- [x] Draft implementation (Phase 0 prototype, then components 1-5)
- [ ] Age-graded resolution, design undecided. It must never merge two sessions. Refs: Santry et al.,
      "Deciding when to forget in the Elephant file system", SOSP '99 §2.3 (age-dependent
      indistinguishability); btrbk retention policy; Time Machine thinning
- [ ] Content-diff large-delta landmarks (the net-shrink proxy misses rewrites in place)
- [x] `keep --target`: the 11-quantum sweep on the pi's db went from 146.7 s to 0.26 s by framing the timelines once
- [x] `top`: 0.91 s to 0.024 s on the pi's db, from the `tallies` table the pass maintains
- [x] Stage B evaluation on the pi's disks, against stock NILFS2 + cleanerd and ext4: all checks pass
      except the pass looping every 10 s, which costs 7-19% throughput. Stock cleanerd failed in all
      three runs (read-only twice)
- [ ] Find out why stock GC sees an `invalid range [0, 0)` period, and whether `nilfs-reclaim` can
- [x] Summary-only log reads: `nilfs-lives` read whole segments under the disks' 8 MiB read-ahead
      (2.4 TB backfill); `MADV_RANDOM` on the segment mapping cut a 256 MiB scan to 3.4 MB
- [ ] Upstream the libnilfsgc liveness callback and the `MADV_RANDOM` segment mapping to nilfs-utils
