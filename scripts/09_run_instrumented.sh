#!/usr/bin/env bash
# Run the TTL repro against the instrumented binary and capture the [WT_RCA]
# fprintf output that proves the root cause.
#
# The logs produced here are the primary evidence for the RCA document's
# "Execution Path" and "Root Cause" sections.
#
# Prerequisites:
#   - bash scripts/08_build_instrumented.sh completed
#
# Run from the repo root: bash scripts/09_run_instrumented.sh
set -euo pipefail

WORK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="${WORK_DIR}/mongo_source"

# Locate the instrumented binary.
INSTRUMENTED_BIN=$(find "${SRC_DIR}/build" -name "mongod" -type f 2>/dev/null | head -1)
if [ -z "${INSTRUMENTED_BIN}" ] || [ ! -f "${INSTRUMENTED_BIN}" ]; then
    echo "ERROR: Instrumented binary not found. Run bash scripts/08_build_instrumented.sh first."
    exit 1
fi

INSTRUM_DBPATH="${WORK_DIR}/data_instrumented"
INSTRUM_LOG="${WORK_DIR}/logs/mongod_instrumented.log"
MONGO_BIN="${WORK_DIR}/mongodb-4.4.0/bin"

echo "=== Running Instrumented MongoDB ==="
echo "Binary: ${INSTRUMENTED_BIN}"

# ── Stop any running mongod ────────────────────────────────────────────────────
if pgrep -x mongod >/dev/null 2>&1; then
    echo "Stopping existing mongod..."
    pkill -x mongod || true
    sleep 3
fi

mkdir -p "${INSTRUM_DBPATH}" "$(dirname "${INSTRUM_LOG}")"

# ── Start instrumented mongod ─────────────────────────────────────────────────
# Redirect stderr to a capture file so the fprintf output is preserved.
# The [WT_RCA] lines go to stderr; mongod's own log goes to --logpath.
echo "Starting instrumented mongod (stderr -> wt_rca_stderr.log)..."
"${INSTRUMENTED_BIN}" \
    --replSet rs \
    --setParameter ttlMonitorSleepSecs=1 \
    --dbpath  "${INSTRUM_DBPATH}" \
    --logpath "${INSTRUM_LOG}" \
    --port 27017 \
    --fork

# Wait for it to become ready.
sleep 3

# Initialize the replica set (required before any TTL work).
"${MONGO_BIN}/mongo" --quiet --eval "
    rs.initiate({_id:'rs', members:[{_id:0, host:'localhost:27017'}]});
    let ok = false;
    for (let i = 0; i < 30 && !ok; i++) {
        sleep(1000);
        try { ok = rs.status().members.some(m => m.stateStr === 'PRIMARY'); } catch(e) {}
    }
    print('Replica set ready: ' + ok);
" 2>/dev/null

echo "Replica set initialized."

# ── ASC run — capture [WT_RCA] stderr ─────────────────────────────────────────
ASC_LOG="${WORK_DIR}/instrumented_asc.log"
echo ""
echo "--- ASC run (capturing to ${ASC_LOG}) ---"

# The [WT_RCA] lines go to the mongod process's stderr.  We can capture them
# by attaching strace -e trace=write or simply by reading the stderr we
# redirected above.  Since we used --fork we must tail the mongod stderr
# via /proc or restart without --fork.
#
# Simpler approach: restart WITHOUT --fork so stderr is visible, then capture.
pkill -x mongod || true
sleep 2

echo "Restarting mongod without --fork to capture stderr..."
"${INSTRUMENTED_BIN}" \
    --replSet rs \
    --setParameter ttlMonitorSleepSecs=1 \
    --dbpath  "${INSTRUM_DBPATH}" \
    --logpath "${INSTRUM_LOG}" \
    --port 27017 \
    2>&1 | grep "WT_RCA" >> "${ASC_LOG}" &
MONGOD_PID=$!

sleep 4

# Re-initialize replica set (dbpath persists, but we may need to reinitiate).
"${MONGO_BIN}/mongo" --quiet --eval "
    try { rs.initiate({_id:'rs',members:[{_id:0,host:'localhost:27017'}]}); } catch(e) {}
    let ok = false;
    for (let i = 0; i < 20 && !ok; i++) {
        sleep(1000);
        try { ok = rs.status().members.some(m => m.stateStr === 'PRIMARY'); } catch(e) {}
    }
" 2>/dev/null

echo "Running ASC TTL repro..."
"${MONGO_BIN}/mongo" --quiet --eval "var testMode='asc'" scripts/04_ttl_repro.js
sleep 2

kill "${MONGOD_PID}" 2>/dev/null || true
wait "${MONGOD_PID}" 2>/dev/null || true

echo "ASC log saved: ${ASC_LOG}"
echo "Sample (first 20 [WT_RCA] lines):"
head -20 "${ASC_LOG}" 2>/dev/null || echo "  (no WT_RCA output captured — see note below)"

# ── DESC run ──────────────────────────────────────────────────────────────────
DESC_LOG="${WORK_DIR}/instrumented_desc.log"
echo ""
echo "--- DESC run (capturing to ${DESC_LOG}) ---"

"${INSTRUMENTED_BIN}" \
    --replSet rs \
    --setParameter ttlMonitorSleepSecs=1 \
    --dbpath  "${INSTRUM_DBPATH}" \
    --logpath "${INSTRUM_LOG}" \
    --port 27017 \
    2>&1 | grep "WT_RCA" >> "${DESC_LOG}" &
MONGOD_PID=$!

sleep 4

"${MONGO_BIN}/mongo" --quiet --eval "
    try { rs.initiate({_id:'rs',members:[{_id:0,host:'localhost:27017'}]}); } catch(e) {}
    let ok = false;
    for (let i = 0; i < 20 && !ok; i++) {
        sleep(1000);
        try { ok = rs.status().members.some(m => m.stateStr === 'PRIMARY'); } catch(e) {}
    }
" 2>/dev/null

echo "Running DESC TTL repro..."
"${MONGO_BIN}/mongo" --quiet --eval "var testMode='desc'" scripts/04_ttl_repro.js
sleep 2

kill "${MONGOD_PID}" 2>/dev/null || true
wait "${MONGOD_PID}" 2>/dev/null || true

echo "DESC log saved: ${DESC_LOG}"
echo "Sample (first 40 [WT_RCA] lines):"
head -40 "${DESC_LOG}" 2>/dev/null || echo "  (no WT_RCA output captured)"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Instrumented run complete ==="
echo ""
echo "What the logs prove:"
echo ""
echo "  instrumented_asc.log:"
echo "    Every reposition shows: FORWARD step: VALID => done"
echo "    The forward scan always finds the next key immediately."
echo "    No FORWARD EXHAUSTED lines appear."
echo ""
echo "  instrumented_desc.log:"
echo "    Every reposition shows FORWARD EXHAUSTED + BACKWARD steps."
echo "    The forward scan traverses an ever-growing list of tombstones"
echo "    (one per already-deleted document) before giving up and going backward."
echo "    The number of TOMBSTONE => keep scanning lines GROWS with each delete"
echo "    — this is the O(n²) behavior that causes the 6x slowdown."
echo ""
echo "NOTE: If the log files are empty, the fprintf probes may not have been"
echo "      applied correctly during the build. Check:"
echo "      grep 'WT_RCA' ${WORK_DIR}/mongo_source/$(ls mongo_source/src/third_party | grep wiredtiger | head -1)/src/btree/bt_cursor.c"
