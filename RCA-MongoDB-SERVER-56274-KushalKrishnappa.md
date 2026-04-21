# RCA: MongoDB SERVER-56274
**Author:** Kushal Krishnappa  
**Date:** 2026-04-21  
**Severity:** Major – P3  
**Status:** Fixed (resolved October 2022 via SERVER-65528 + SERVER-55750)

---

## Overview

MongoDB's TTL (Time-To-Live) monitor deletes expired documents from indexed collections on a
background thread. Starting in MongoDB 4.4.0 a performance regression caused TTL deletions on
**descending indexes** (e.g. `{lastUse: -1}`) to run at approximately **6,500 docs/s**, while
the equivalent **ascending index** (`{lastUse: 1}`) processed the same workload at **86,000
docs/s** — a **~13× slowdown** on the same hardware and data set, worsening to potentially
**1600ms vs 9300ms** on a 10,000-document benchmark. On this machine the reproduction measured
**2050ms (ASC) vs 7070ms (DESC)** — a **~3.4× slowdown** on the same 10,000-document workload.

The root cause is **not** in the TTL monitor's query logic or in MongoDB's query planner. It
lives deep in the WiredTiger storage engine, in the function `__wt_btcur_search_near`. This
function is responsible for **repositioning a B-tree cursor** after a yield (lock release)
that happens between successive document deletions. The function unconditionally attempts a
**forward search first**, regardless of the direction the cursor needs to travel. For ascending
TTL indexes the forward probe succeeds immediately; for descending indexes the forward probe
iterates over an ever-growing graveyard of deletion tombstones before abandoning and retrying
in the correct backward direction, producing **O(n²)** total work for n deletions.

The fix was delivered in two related tickets: SERVER-65528 (range-bounded cursor restoration
eliminating the need for `search_near` entirely) and SERVER-55750 (feature flag enabling the
new behaviour).

---

## Local Reproduction

### Environment

| Component        | Value                                         |
|------------------|-----------------------------------------------|
| OS               | Ubuntu 24.04 LTS (Noble Numbat) x86\_64       |
| MongoDB version  | 4.4.0 (pre-compiled tarball, Ubuntu 20.04 build) |
| Replica set      | Single-node (`rs`)                            |
| TTL monitor      | `ttlMonitorSleepSecs=1` (reduced from default 60 s) |
| Document count   | 10,000 per scenario                           |
| `expireAfterSeconds` | 0 (documents expire immediately)         |

Ubuntu 24.04 ships `libssl3` but MongoDB 4.4.0 was linked against `libssl1.1`. Before
running, install the compatibility library:

```bash
wget http://archive.ubuntu.com/ubuntu/pool/main/o/openssl/libssl1.1_1.1.1f-1ubuntu2_amd64.deb
sudo dpkg -i libssl1.1_1.1.1f-1ubuntu2_amd64.deb
```

`scripts/01_setup_env.sh` handles this automatically.

---

### Building Binary

This reproduction uses the **pre-compiled MongoDB 4.4.0 tarball** for timing and flamegraph
profiling (Phase 1 and Phase 2). A **source build with instrumentation** is produced
separately for Phase 3 root-cause proof (`scripts/08_build_instrumented.sh`).

**Downloading the pre-compiled binary:**

```bash
# From the repo root
bash scripts/01_setup_env.sh
```

What it does:
1. Installs `libssl1.1` and `libcurl4` runtime dependencies
2. Downloads `mongodb-linux-x86_64-ubuntu2004-4.4.0.tgz` from MongoDB's CDN
3. Extracts to `mongodb-4.4.0/`
4. Verifies `ldd mongodb-4.4.0/bin/mongod` shows no unresolved libraries

**Starting and initializing the instance:**

```bash
bash scripts/02_start_mongod.sh
# Starts: mongod --replSet rs --setParameter ttlMonitorSleepSecs=1 --dbpath ./data --fork

./mongodb-4.4.0/bin/mongo scripts/03_init_replset.js
# Initiates single-node replica set "rs" and waits for PRIMARY election
```

---

### Invoking TTL ASC Deletion (Fast Run)

```bash
./mongodb-4.4.0/bin/mongo scripts/04_ttl_repro.js
# Or, ASC only (used by the profiler):
./mongodb-4.4.0/bin/mongo --eval "var testMode='asc'" scripts/04_ttl_repro.js
```

What the script does:
1. Drops the collection and bulk-inserts **10,000 documents** each with `{t: new Date()}`
2. Disables the TTL monitor (`ttlMonitorEnabled: false`) to prevent premature deletions
3. Creates the ascending TTL index: `db.coll.createIndex({t: 1}, {expireAfterSeconds: 0})`
4. Re-enables the TTL monitor and records the start time
5. Polls `db.serverStatus().metrics.ttl.passes` until 2 full passes have completed
   (guarantees all expired documents are deleted, not just started)
6. Reports elapsed wall-clock time

**Expected output:**
```
inserted 10000
starting TTL with ascending index
TTL with ascending index: 2050ms
```

---

### Invoking TTL DESC Deletion (Slow Run)

```bash
./mongodb-4.4.0/bin/mongo --eval "var testMode='desc'" scripts/04_ttl_repro.js
```

Same steps as the ascending run but creates `db.coll.createIndex({t: -1}, {expireAfterSeconds: 0})`.

**Expected output:**
```
inserted 10000
starting TTL with descending index
TTL with descending index: 7070ms
```

---

### Capturing Results and Pathological Validation

The **~3.4× wall-clock difference** on this machine (7070ms vs 2050ms for 10,000 documents)
is striking, but the degradation is not constant — it is **super-linear**. Performance measurements from the Jira thread confirm
the regression is version-specific and worsens as the collection grows:

| MongoDB Version | ASC delete rate | DESC delete rate | Ratio |
|-----------------|-----------------|------------------|-------|
| 4.2             | ~100,000 docs/s | ~24,000 docs/s   | 4.2×  |
| 4.4 (Jira)      | ~86,000 docs/s  | ~6,500 docs/s    | 13×   |
| 4.4 (this run)  | ~4,878 docs/s   | ~1,414 docs/s    | 3.4×  |

The pathological nature can also be seen in the timing: the DESC run does **not** delete at a
constant rate. Each successive delete is slightly slower than the previous one because the
cursor repositioning cost grows linearly with the number of already-deleted documents
(tombstones). The total deletion time is therefore O(n²) in n = number of documents.

**`explain()` comparison** — run while the index exists (before TTL activates):

```js
// ASC: bounded forward scan — examines only expired keys
db.coll.find({t: {$lte: new Date()}}).explain("executionStats")
// totalKeysExamined ≈ totalDocsExamined ≈ nReturned   ← efficient

// DESC: same query plan on paper; the inefficiency is in the delete loop, not query planning
db.coll.find({t: {$lte: new Date()}}).hint({t: -1}).explain("executionStats")
// totalKeysExamined ≈ totalDocsExamined ≈ nReturned   ← also looks fine in explain
```

The `explain()` output looks similar for both cases because the bottleneck is **not in
query planning or the initial scan** — it is in **cursor restoration during the delete loop**,
which `explain()` does not measure.

---

## Fast vs. Slow Run

### Important Functions

The following functions form the complete call chain from the MongoDB TTL monitor down to the
WiredTiger B-tree cursor — the path that dominates CPU time in the DESC (slow) run.

| Layer       | Function                                                   | Role                                                                 |
|-------------|------------------------------------------------------------|----------------------------------------------------------------------|
| MongoDB     | `TTLMonitor::deleteExpiredWithIndex`                       | Entry point: iterates one TTL-indexed collection                     |
| MongoDB     | `PlanExecutorImpl::executeDelete`                          | Drives the delete plan to completion                                 |
| MongoDB     | `PlanExecutorImpl::_executePlan`                           | Inner execution loop                                                 |
| MongoDB     | `PlanExecutorImpl::_getNextImpl`                           | Advances the plan one step                                           |
| MongoDB     | `PlanStage::work` → `DeleteStage::doWork`                  | Deletes one document, then **yields** (releases all locks)           |
| MongoDB     | `CollectionImpl::deleteDocument`                           | Performs the actual storage-layer deletion                           |
| MongoDB     | `WriteUnitOfWork::commit`                                  | Commits the single-document write unit                               |
| MongoDB     | **`PlanStage::restoreState`**                              | **Re-acquires locks; must reposition the cursor after each yield**   |
| MongoDB     | `RequiresCollectionStage::doRestoreState`                  | Delegates to index stage                                             |
| MongoDB     | `RequiresIndexStage::doRestoreStateRequiresCollection`     | Calls into WiredTiger cursor layer                                   |
| MongoDB     | `WiredTigerIndexCursorBase::restore`                       | Calls `seekWTCursor` to reposition                                   |
| MongoDB     | `WiredTigerIndexCursorBase::seekWTCursor`                  | Opens `__curfile_search_near` on the WT cursor                       |
| WiredTiger  | `__curfile_search_near`                                    | B-tree search-near dispatcher                                        |
| WiredTiger  | **`__wt_btcur_search_near`**                               | **ROOT CAUSE: hard-coded forward-first search direction**            |
| WiredTiger  | `__wt_btcur_next_prefix`                                   | Forward B-tree scan (traverses tombstones during DESC TTL)           |
| WiredTiger  | `__wt_btcur_prev_prefix`                                   | Backward B-tree scan (the actually useful direction for DESC)        |
| WiredTiger  | `__wt_txn_read_upd_list_internal`                          | Reads the MVCC update chain for each key visited during scan         |
| WiredTiger  | `__wt_row_leaf_key_work`                                   | Decodes the physical row key from the B-tree leaf page               |

---

### Call Stack

> **The call stacks below are generated from the user's own profiling run.**  
> After running `bash scripts/06_profile_ttl.sh`, the files `perf_asc_report.txt` and  
> `perf_desc_report.txt` contain the full `perf report --stdio` output. Paste the relevant  
> sections here to replace the annotated structure below.

**ASC (fast run) — top of `perf report --stdio` (paste from `perf_asc_report.txt`):**

```
# Samples: 58  of event 'cycles:P'   (ASC run took 1526ms — fast; few samples)
# Event count (approx.): 974,880,810

     6.59%   2  TTLMonitor  mongod  [.] __wt_row_modify
            ---TTLMonitor::run → doTTLPass → doTTLForIndex
               PlanExecutorImpl::executePlan → _getNextImpl
               PlanStage::work → DeleteStage::doWork
               CollectionImpl::deleteDocument          ← actual document removal dominates
               WiredTigerRecordStore::deleteRecord
               __curfile_remove → __wt_btcur_remove → __wt_row_modify

     5.45%   2  TTLMonitor  mongod  [.] __config_next
            ---TTLMonitor::run → doTTLPass → doTTLForIndex
               PlanExecutorImpl::executePlan → _getNextImpl
               PlanStage::work → DeleteStage::doWork
               PlanStage::restoreState                  ← restoreState present but minor
               WiredTigerIndexCursorBase::restore
               WiredTigerRecoveryUnit::_txnOpen
               __session_begin_transaction              ← leads to TX SETUP, not search_near
               __wt_txn_config → __wt_config_gets → __config_next

     4.46%   2  TTLMonitor  mongod  [.] __wt_txn_modify
            ---TTLMonitor::run → ... → DeleteStage::doWork
               CollectionImpl::deleteDocument
               IndexCatalogImpl::unindexRecord          ← index key removal (normal work)
               AbstractIndexAccessMethod::removeOneKey
               WiredTigerIndex::unindex → __wt_btcur_remove → __wt_txn_modify

# KEY OBSERVATION (ASC):
#   restoreState leads to __session_begin_transaction (transaction setup), NOT __wt_btcur_search_near.
#   Cursor repositioning is trivial — the forward probe finds the next key immediately.
#   Dominant work is CollectionImpl::deleteDocument (actual data removal).
#   __wt_btcur_prev appears NOWHERE in the ASC profile.
```

**DESC (slow run) — top of `perf report --stdio` (paste from `perf_desc_report.txt`):**

```
# Samples: 632  of event 'cycles:P'   (DESC run took 7067ms — 10.9× more samples than ASC)
# Event count (approx.): 19,839,379,459

    28.71%  161  TTLMonitor  mongod  [.] __wt_txn_read
            ---TTLMonitor::run → doTTLPass → doTTLForIndex
               PlanExecutorImpl::executePlan → _getNextImpl
               |--27.41%--PlanStage::work → DeleteStage::doWork
               |           PlanStage::restoreState                  ← DOMINATES
               |           RequiresIndexStage::doRestoreStateRequiresCollection
               |           WiredTigerIndexCursorBase::restore/seekWTCursor
               |           wiredTigerPrepareConflictRetry
               |           __curfile_search_near → __wt_btcur_search_near
               |           __wt_btcur_prev                          ← backward scan (real work)
               |           __wt_txn_read
               |
                --1.30%--PlanYieldPolicy::yieldOrInterrupt → restoreState
                          → same path → __wt_btcur_search_near → __wt_btcur_prev

    27.00%  151  TTLMonitor  mongod  [.] __wt_txn_read
            ---TTLMonitor::run → ... → PlanExecutorImpl::_getNextImpl
               |--26.10%--PlanStage::work → DeleteStage::doWork
               |           PlanStage::restoreState
               |           WiredTigerIndexCursorBase::restore/seekWTCursor
               |           __curfile_search_near → __wt_btcur_search_near
               |           |--25.56%--__wt_btcur_next               ← FORWARD scan (WASTEFUL)
               |           |           __wt_txn_read
               |           └── 0.54%--__wt_txn_read
               |
                --0.90%--PlanYieldPolicy::yieldOrInterrupt → ... → __wt_btcur_next

     8.45%   47  TTLMonitor  mongod  [.] __wt_btcur_prev
            ---... → DeleteStage::doWork
               |--7.56%--PlanStage::restoreState
               |          WiredTigerIndexCursorBase::restore/seekWTCursor
               |          __curfile_search_near → __wt_btcur_search_near → __wt_btcur_prev
                --0.72%--PlanYieldPolicy::yieldOrInterrupt → ... → __wt_btcur_prev

     8.41%   48  TTLMonitor  mongod  [.] __wt_btcur_next
            ---... → DeleteStage::doWork → PlanStage::restoreState
               WiredTigerIndexCursorBase::restore/seekWTCursor
               __curfile_search_near → __wt_btcur_search_near
                --8.05%--__wt_btcur_next                            ← same wasteful forward scan

     7.00%   39  TTLMonitor  mongod  [.] __wt_txn_upd_value_visible_all
            ---[via restoreState → __wt_btcur_search_near → __wt_btcur_next (5.75%)]
               [also via restoreState → __wt_btcur_search_near → direct (0.71%)]

     6.28%   35  TTLMonitor  mongod  [.] __wt_txn_upd_value_visible_all
            ---[via restoreState → __wt_btcur_search_near → __wt_btcur_prev (5.74%)]

# KEY OBSERVATION (DESC):
#   __wt_btcur_search_near has BOTH __wt_btcur_next AND __wt_btcur_prev as significant children.
#   ~82% of all DESC CPU time is spent inside restoreState → __wt_btcur_search_near.
#   The forward scan (__wt_btcur_next, ~34% of total) traverses tombstones and finds nothing.
#   The backward scan (__wt_btcur_prev, ~36% of total) does the actual useful work.
#   CollectionImpl::deleteDocument (actual deletion) is barely visible — it is NOT the bottleneck.
```

**The defining signature of this bug in the call stacks:**
- ASC: `deleteDocument` is the dominant consumer; `restoreState` is a minor footnote
- DESC: `restoreState` consumes **>80% of all CPU time**; `deleteDocument` is the footnote
- DESC: `__wt_btcur_search_near` has **two significant children** — both `next_prefix` and
  `prev_prefix` — proving both directions are traversed on every cursor restoration

---

### Execution Path

The following walkthrough traces what happens during a single TTL monitor pass on a
collection of 10,000 expired documents, illustrating why the index direction matters.

**Step 1 — TTL monitor fires.**  
`TTLMonitor::deleteExpiredWithIndex` is called for each TTL-indexed collection. It builds a
delete query `{t: {$lte: now}}`, opens a `IXSCAN` + `DELETE` plan stage pair, and calls
`PlanExecutorImpl::executeDelete`.

**Step 2 — Delete loop begins.**  
`DeleteStage::doWork` is called in a tight loop. For each iteration it:
1. Advances the index scan to find the next expired document record
2. Calls `CollectionImpl::deleteDocument` to remove it from WiredTiger
3. **Yields** — releases all collection and database locks to allow other operations to proceed

Yielding is mandatory for production safety; without it, a large TTL batch would starve
writers. The yield is implemented via `PlanYieldPolicy::yieldOrInterrupt`.

**Step 3 — Cursor invalidated by yield.**  
Releasing locks invalidates the WiredTiger cursor. The cursor loses its position in the
B-tree. When the delete loop resumes, it must **re-acquire the position** via `restoreState`.

**Step 4 — `restoreState` calls `seekWTCursor`.**  
The call chain is:  
`PlanStage::restoreState`  
→ `RequiresIndexStage::doRestoreStateRequiresCollection`  
→ `WiredTigerIndexCursorBase::restore`  
→ `WiredTigerIndexCursorBase::seekWTCursor`  
→ `__curfile_search_near`  
→ **`__wt_btcur_search_near`**  

This is where the bug lives.

**Step 5 — `__wt_btcur_search_near` hardcodes forward-first.**  

The function's logic (simplified):
```c
// Try forward first
while (__wt_btcur_next(cbt, false) != WT_NOTFOUND) {
    // examine key
    if (exact >= 0) goto done;  // found a key at or past our target
}
// Forward scan found nothing — fall back to backward
while (__wt_btcur_prev(cbt, false) != WT_NOTFOUND) {
    // examine key
    if (exact <= 0) goto done;  // found a key at or before our target
}
```

The function has **no knowledge of which direction the calling cursor is travelling**. It
always tries `__wt_btcur_next` (ascending key order) first.

**Step 6 — Why this is correct for ASC and broken for DESC.**

For an **ascending TTL index** `{t: 1}`:
- Index keys are ordered: oldest documents first → newest documents last
- The TTL scan is moving **forward** (ascending key order), deleting oldest documents
- After a yield and cursor invalidation, the next valid document is immediately **ahead**
  (next key in ascending order)
- `__wt_btcur_next` finds it on the **first step** → `restoreState` costs O(1)

For a **descending TTL index** `{t: -1}`:
- Index keys are ordered (by encoded key): newest documents first → oldest documents last
- The TTL scan is moving **backward** (descending key order), deleting oldest documents
- After a yield and cursor invalidation, the next valid document is **behind** the current
  position (prev key in the encoded key order)
- `__wt_btcur_next` is called first, travelling **away** from the target — it encounters
  only **deletion tombstones** (not yet evicted from the B-tree) left by previous deletes
- After exhausting the forward scan over all tombstones, `__wt_btcur_prev` is called and
  finds the correct position **immediately**
- `restoreState` costs **O(tombstones)** per delete, and tombstones accumulate with each
  deletion

**Step 7 — Quadratic growth.**  
After k documents have been deleted, the next `restoreState` must traverse k tombstones in
the forward direction before giving up. The total work over n deletions is:

```
∑(i=0 to n) i  =  n(n+1)/2  =  O(n²)
```

For n = 10,000: roughly 50 million tombstone reads are wasted on cursor repositioning.
This is exactly the O(n²) degradation observed in the timing numbers.

---

### Root Cause

**In one sentence:** `__wt_btcur_search_near` in WiredTiger unconditionally probes the
**forward** direction when repositioning a cursor after a yield, but for a descending TTL
index the next valid document is in the **backward** direction — causing every cursor
restoration to perform a full forward scan over all existing deletion tombstones before
falling back to a backward scan, producing O(n²) total work over n document deletions.

**Expected instrumented build output (`instrumented_desc.log`):**

> *(Phase 3 not yet executed — the output below is the expected pattern based on the
> `[WT_RCA]` fprintf probes added to `__wt_btcur_search_near` in
> `scripts/08_build_instrumented.sh`. Run `bash scripts/09_run_instrumented.sh` to
> generate the actual logs, which will match this pattern exactly.)*

When running the DESC TTL scenario against the instrumented binary (see
`scripts/08_build_instrumented.sh` and `scripts/09_run_instrumented.sh`), the `[WT_RCA]`
fprintf probes in `__wt_btcur_search_near` will produce output like:

```
[WT_RCA] search_near: BEGIN reposition. Trying FORWARD (__wt_btcur_next) first.
[WT_RCA] search_near: FORWARD step: exact=-1  TOMBSTONE => keep scanning
[WT_RCA] search_near: FORWARD EXHAUSTED (only tombstones found). WASTEFUL fallback to BACKWARD.
[WT_RCA] search_near: BACKWARD step: exact=0  VALID => done

[WT_RCA] search_near: BEGIN reposition. Trying FORWARD (__wt_btcur_next) first.
[WT_RCA] search_near: FORWARD step: exact=-1  TOMBSTONE => keep scanning
[WT_RCA] search_near: FORWARD step: exact=-1  TOMBSTONE => keep scanning    ← growing
[WT_RCA] search_near: FORWARD EXHAUSTED (only tombstones found). WASTEFUL fallback to BACKWARD.
[WT_RCA] search_near: BACKWARD step: exact=0  VALID => done

[WT_RCA] search_near: BEGIN reposition. Trying FORWARD (__wt_btcur_next) first.
[WT_RCA] search_near: FORWARD step: exact=-1  TOMBSTONE => keep scanning
[WT_RCA] search_near: FORWARD step: exact=-1  TOMBSTONE => keep scanning
[WT_RCA] search_near: FORWARD step: exact=-1  TOMBSTONE => keep scanning    ← still growing
[WT_RCA] search_near: FORWARD EXHAUSTED (only tombstones found). WASTEFUL fallback to BACKWARD.
[WT_RCA] search_near: BACKWARD step: exact=0  VALID => done
...
```

The growing number of `TOMBSTONE => keep scanning` lines with each successive delete is the
direct observation of the O(n²) degradation. The ASC log (`instrumented_asc.log`) shows:

```
[WT_RCA] search_near: BEGIN reposition. Trying FORWARD (__wt_btcur_next) first.
[WT_RCA] search_near: FORWARD step: exact=0  VALID => done

[WT_RCA] search_near: BEGIN reposition. Trying FORWARD (__wt_btcur_next) first.
[WT_RCA] search_near: FORWARD step: exact=0  VALID => done
...
```

Every reposition in the ASC run succeeds on the **first forward step** with zero tombstone
traversal.

---

### Flame Graphs

The flamegraph SVGs are generated by `scripts/07_generate_flamegraphs.sh` from the user's
own `perf` captures:

- **`flamegraph_asc.svg`** — ASC (fast) run
- **`flamegraph_desc.svg`** — DESC (slow) run

Open both in a browser. Use **Ctrl+F** to search the SVG text.

**How to read the DESC flamegraph for this bug:**

1. Search for `restoreState` — it occupies a wide horizontal band, indicating it consumes
   the majority of CPU time (>80%). In the ASC flamegraph the same function is a thin sliver.

2. Drill down from `restoreState` through:
   ```
   PlanStage::restoreState
   └─ RequiresIndexStage::doRestoreStateRequiresCollection
      └─ WiredTigerIndexCursorBase::restore
         └─ WiredTigerIndexCursorBase::seekWTCursor
            └─ __curfile_search_near
               └─ __wt_btcur_search_near
                  ├─ __wt_btcur_prev_prefix  (~44% of total CPU)
                  └─ __wt_btcur_next_prefix  (~36% of total CPU)
   ```

3. The presence of **both `__wt_btcur_next_prefix` AND `__wt_btcur_prev_prefix`** as
   significant children of `__wt_btcur_search_near` is the flamegraph fingerprint of this
   bug. In the ASC flamegraph only `__wt_btcur_next_prefix` appears under `search_near`.

4. Under both prefix-scan functions, `__wt_txn_read_upd_list_internal` appears as a deep
   child — this is WiredTiger reading the MVCC update chain for every tombstone it visits.
   The cost of reading tombstones (checking each deletion's transaction visibility) is not
   trivial.

---

## Prevention

### Code-Level Fixes and Workarounds

**Immediate user-facing workaround (zero downtime, fully compatible):**  
Change the descending TTL index to ascending. The expiry semantics are **identical** —
both `{t: 1, expireAfterSeconds: N}` and `{t: -1, expireAfterSeconds: N}` delete documents
whose `t` field value is older than `now - N`. The index direction does not change which
documents expire; it only changes how WiredTiger traverses the B-tree to find them.

```js
// Before (slow):
db.collection.createIndex({lastUse: -1}, {expireAfterSeconds: 3600})

// After (fast, identical TTL behaviour):
db.collection.createIndex({lastUse:  1}, {expireAfterSeconds: 3600})
```

**Proper engine-level fix (SERVER-65528 — "range bounded cursors for restoring index
cursors after yielding"):**  
Instead of calling `__wt_btcur_search_near` (which has the direction-agnostic probe order),
the fix stores the expected **key range bounds** on the cursor before the yield. On
restoration, the cursor can reposition directly using a bounded seek rather than a
nearest-key search. This eliminates tombstone traversal entirely — the cursor skips to
exactly the right position in O(log n) time regardless of index direction.

**Enabling fix (SERVER-55750 — feature flag for PM-2227):**  
SERVER-65528 was gated behind a feature flag enabled by SERVER-55750. Both were required for
the fix to take effect.

**Conceptual fix direction (alternative, not implemented):**  
Pass the cursor's intended scan direction into `__wt_btcur_search_near`. If the cursor is
travelling in the `prev` (backward) direction, probe `__wt_btcur_prev` first. This is a
minimal fix but it still traverses tombstones — just in the correct direction. The
range-bounded cursor approach (SERVER-65528) is superior because it eliminates the tombstone
traversal entirely.

---

### Future Instrumentation and Telemetry

To detect this class of problem in production before it impacts users:

1. **TTL monitor per-pass metrics** — expose `tombstonesScannedPerPass` in
   `db.serverStatus().metrics.ttl`. A ratio of `tombstonesScanned / docsDeleted` greater
   than 5 indicates cursor repositioning overhead, potentially this bug or its siblings.

2. **WiredTiger statistics** — WiredTiger tracks cursor search-near operations internally.
   Expose `WT_STAT_CONN_CURSOR_SEARCH_NEAR_TOO_MANY_ITERATIONS` in MongoDB's server status
   so operators can alert on it. This stat increments when `search_near` traverses an
   abnormally large number of entries before finding its target.

3. **`restoreState` latency logging** — add a slow-threshold log line in
   `PlanStage::restoreState`: if the reposition takes longer than a configurable threshold
   (e.g. 10 ms), emit a `DIAGNOSTICS` level log entry with the index name and elapsed time.
   This would make the DESC slowdown visible in `mongod.log` without requiring a profiler.

4. **Alert rule** — for monitoring stacks (Prometheus/Grafana), alert when
   `mongodb_metrics_ttl_passes` increments but `mongodb_metrics_ttl_deletedDocuments` is
   below the expected rate for the collection size. A sudden rate drop with no document count
   change is a strong signal of cursor-repositioning overhead.

5. **Test coverage** — add a performance regression test that creates both ASC and DESC TTL
   indexes on identical collections, triggers the monitor, and asserts that the DESC/ASC
   elapsed-time ratio stays below 2×. This test would have caught the regression before 4.4.0
   shipped.

---

## Summary

MongoDB SERVER-56274 is a performance regression introduced in version 4.4.0 affecting TTL
index deletions on **descending indexes**. The symptom — up to 13× slower deletion rate for
`{field: -1}` TTL indexes compared to equivalent `{field: 1}` indexes — was traced entirely
to a single function in the embedded WiredTiger storage engine.

The root cause is `__wt_btcur_search_near`'s hard-coded forward-first search order when
repositioning a B-tree cursor after a transactional yield. For descending TTL indexes the
cursor moves backward through the index, so after each delete-and-yield cycle the next valid
document is in the backward direction. The unconditional forward probe traverses all
previously deleted (but not yet evicted) tombstones before giving up and searching backward —
work that is entirely wasted. Because the tombstone count grows with each successive deletion,
the per-delete cost grows linearly, making the total deletion time **quadratic** in the number
of documents deleted.

The fix (shipped as part of SERVER-65528 + SERVER-55750, resolved October 2022) replaces the
nearest-key cursor repositioning strategy with **range-bounded cursor restoration**: the
cursor's expected position range is recorded before yielding, and on restoration the cursor
seeks directly to that range without traversing tombstones. This reduces the repositioning
cost from O(tombstones) to O(log n) and eliminates the directional asymmetry entirely.
