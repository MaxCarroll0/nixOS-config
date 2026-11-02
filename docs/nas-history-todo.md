# NAS history TODO

References: see [NAS history references](nas.md#nas-history-references).

- [ ] Draft implementation (Phase 0 prototype, then components 1-5)
- [ ] Age-graded resolution, design undecided. It must never merge two sessions. Refs: Santry et al.,
      "Deciding when to forget in the Elephant file system", SOSP '99 §2.3 (age-dependent
      indistinguishability); btrbk retention policy; Time Machine thinning
- [ ] Content-diff large-delta landmarks (the net-shrink proxy misses rewrites in place)
- [ ] Day×level savings histogram, if `keep --target` misses its 10 s budget
- [ ] In-tree summary reader instead of parsing `dumpseg`, if scan/backfill cost shows up
- [ ] Upstream the libnilfsgc liveness callback to nilfs-utils
