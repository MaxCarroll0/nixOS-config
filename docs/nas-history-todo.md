# NAS history TODO

References: see [NAS history references](nas.md#nas-history-references).

- [x] Draft implementation (Phase 0 prototype, then components 1-5)
- [ ] Age-graded resolution, design undecided. It must never merge two sessions. Refs: Santry et al.,
      "Deciding when to forget in the Elephant file system", SOSP '99 §2.3 (age-dependent
      indistinguishability); btrbk retention policy; Time Machine thinning
- [ ] Content-diff large-delta landmarks (the net-shrink proxy misses rewrites in place)
- [ ] Day×level savings histogram: `keep --target 100M` took 22.3 s in the eval, over its 10 s budget
- [ ] `top` takes 4.9 s on disk1 (budget 1 s): a per-path totals table maintained by the pass, like `history_days`
- [ ] Stage B evaluation (scratch NILFS2 on the pi's LUKS and bcache stack), Previous Versions timings, SnapRAID diff after reclaim, 2 h disk parking
- [ ] In-tree summary reader instead of parsing `dumpseg`: the pi's backfill read 2.4 TB (whole
      segments, not summaries) over 2h17m
- [ ] Upstream the libnilfsgc liveness callback to nilfs-utils
