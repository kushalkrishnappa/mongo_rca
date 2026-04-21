#!/usr/bin/env bash
# Profile the TTL monitor during ASC and DESC runs, then produce
# perf report text files that form the call-stack evidence in the RCA.
#
# Prerequisites:
#   - mongod running (bash scripts/02_start_mongod.sh + 03_init_replset.js)
#   - bash scripts/05_install_profiling.sh completed
#
# Run from the repo root: bash scripts/06_profile_ttl.sh
set -euo pipefail

WORK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MONGO_BIN="${WORK_DIR}/mongodb-4.4.0/bin"
FLAMEGRAPH_DIR="${WORK_DIR}/FlameGraph"

# ── sanity checks ──────────────────────────────────────────────────────────────
if ! pgrep -x mongod >/dev/null 2>&1; then
    echo "ERROR: mongod is not running. Run bash scripts/02_start_mongod.sh first."
    exit 1
fi

if ! command -v perf >/dev/null 2>&1; then
    echo "ERROR: perf not found. Run bash scripts/05_install_profiling.sh first."
    exit 1
fi

MONGOD_PID=$(pgrep -x mongod | head -1)
echo "=== TTL Profiling (mongod PID: ${MONGOD_PID}) ==="

# Helper: run the repro for one scenario while capturing perf data.
# Args: $1=mode (asc|desc)  $2=output-stem (perf_asc | perf_desc)
profile_run() {
    local mode="$1"
    local stem="$2"
    local data_file="${WORK_DIR}/${stem}.data"
    local report_file="${WORK_DIR}/${stem}_report.txt"

    echo ""
    echo "--- Profiling ${mode^^} run ---"
    echo "    perf data  : ${data_file}"
    echo "    text report: ${report_file}"

    # Start perf in the background, sampling at 99 Hz with call-graph unwind.
    # -g           : enable call-graph recording (frame-pointer based)
    # -F 99        : 99 samples/second (avoid aliasing with 100 Hz kernel timers)
    # --call-graph fp : explicitly use frame-pointer unwinding
    #   If this produces incomplete stacks, switch to: --call-graph dwarf,65536
    perf record \
        -g \
        -F 99 \
        --call-graph fp \
        -p "${MONGOD_PID}" \
        -o "${data_file}" \
        -- sleep 60 &
    PERF_PID=$!

    # Give perf a moment to attach before the workload starts.
    sleep 1

    # Run the repro for this mode only; it will finish in ~2-15 s.
    "${MONGO_BIN}/mongo" \
        --quiet \
        --eval "var testMode='${mode}'" \
        scripts/04_ttl_repro.js

    # Allow a couple extra seconds after the repro finishes, then stop perf.
    sleep 2
    kill -INT "${PERF_PID}" 2>/dev/null || true
    wait "${PERF_PID}" 2>/dev/null || true

    echo "    perf record complete."

    # Produce a human-readable call-stack report sorted by self-time.
    # --stdio       : text output (not TUI)
    # --no-children : show self-time only, not accumulated children
    # -n            : show sample counts next to percentages
    # -G            : show call graphs
    echo "    Generating text report..."
    perf report \
        -n \
        --stdio \
        --no-children \
        -G \
        -i "${data_file}" \
        > "${report_file}" 2>&1 || true

    echo "    Report saved: ${report_file}"
    echo ""
    echo "    Top 20 hottest functions:"
    echo "    ---"
    grep -A 1 "^#" "${report_file}" | grep -v "^#" | head -20 || \
        head -40 "${report_file}"
    echo "    ---"
}

profile_run "asc"  "perf_asc"
profile_run "desc" "perf_desc"

echo ""
echo "=== Profiling complete ==="
echo ""
echo "Files generated:"
echo "  ${WORK_DIR}/perf_asc.data       — raw perf samples (ASC run)"
echo "  ${WORK_DIR}/perf_asc_report.txt — call-stack report (paste into RCA)"
echo "  ${WORK_DIR}/perf_desc.data      — raw perf samples (DESC run)"
echo "  ${WORK_DIR}/perf_desc_report.txt— call-stack report (paste into RCA)"
echo ""
echo "Key things to compare between perf_asc_report.txt and perf_desc_report.txt:"
echo "  ASC : PlanStage::restoreState should be a MINOR fraction of total time"
echo "  DESC: PlanStage::restoreState should DOMINATE (>70% of CPU time)"
echo "        __wt_btcur_search_near should show both next_prefix AND prev_prefix"
echo ""
echo "Next: bash scripts/07_generate_flamegraphs.sh"
