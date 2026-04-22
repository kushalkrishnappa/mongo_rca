# MongoDB SERVER-56274 — Root Cause Analysis

**TTL deletes ~3.4× slower on descending indexes than ascending (MongoDB 4.4.0 regression)**

---

## Report

→ **[RCA-MongoDB-SERVER-56274-KushalKrishnappa.md](RCA-MongoDB-SERVER-56274-KushalKrishnappa.md)**

---

## Repository Layout

```
scripts/
  01_setup_env.sh            # Download MongoDB 4.4.0 tarball, install libssl1.1 compat
  02_start_mongod.sh         # Start mongod (replSet rs, ttlMonitorSleepSecs=1)
  03_init_replset.js         # rs.initiate() + wait for PRIMARY
  04_ttl_repro.js            # Reproduce the ASC vs DESC timing difference
  05_install_profiling.sh    # Install linux-perf, clone FlameGraph repo
  06_profile_ttl.sh          # perf record both runs → perf_*_report.txt
  07_generate_flamegraphs.sh # Convert perf data to SVG flamegraphs

flamegraph_asc.svg           # Flamegraph: ASC run (fast) — restoreState is a thin tower
flamegraph_desc.svg          # Flamegraph: DESC run (slow) — restoreState dominates - wide tower
perf_asc_report.txt          # perf call-stack report: ASC run
perf_desc_report.txt         # perf call-stack report: DESC run (contains the bug signature)
```

---

## Quick Reproduction

Requires: Ubuntu 24.04 x86_64, ~500MB free disk, internet access.

```bash
bash scripts/01_setup_env.sh          # ~30s — downloads MongoDB 4.4.0
bash scripts/02_start_mongod.sh       # starts mongod in background
./mongodb-4.4.0/bin/mongo scripts/03_init_replset.js
./mongodb-4.4.0/bin/mongo scripts/04_ttl_repro.js
```

Expected output:
```
TTL with ascending index:  ~2050ms   ← fast
TTL with descending index: ~7070ms   ← ~3.4× slower — bug reproduced
```

Same 10,000 documents, same expiry logic, only the index direction differs.

---

## Profiling

```bash
bash scripts/05_install_profiling.sh      # installs linux-perf, clones FlameGraph
bash scripts/06_profile_ttl.sh            # → perf_asc_report.txt, perf_desc_report.txt
bash scripts/07_generate_flamegraphs.sh   # → flamegraph_asc.svg, flamegraph_desc.svg
```

Open the SVGs check for `restoreState` function:
- **ASC flamegraph**: thin tower — cursor repositioning is negligible
- **DESC flamegraph**: wide tower dominating the graph — cursor repositioning is the bottleneck

In `perf_desc_report.txt`, `__wt_btcur_search_near` shows **both** `__wt_btcur_next` and
`__wt_btcur_prev` as significant children. That is the O(n²) signature of the bug.

---

## Instrumented Source Build

Adds `fprintf` probes directly into WiredTiger's `__wt_btcur_search_near` to print each
tombstone traversal, making the O(n²) growth visible in log output.

```bash
TODO - Build failing on Ubuntu24.04
```

---

## References

- [MongoDB Jira SERVER-56274](https://jira.mongodb.org/browse/SERVER-56274) — original bug report
- [SERVER-65528](https://jira.mongodb.org/browse/SERVER-65528) — fix: range-bounded cursor restoration
- Ren et al., *Relational Debugging*, USENIX OSDI 2023 — methodology background (SERVER-57221)
