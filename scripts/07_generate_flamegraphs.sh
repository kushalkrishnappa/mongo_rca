#!/usr/bin/env bash
# Convert perf.data files into interactive SVG flamegraphs.
#
# Prerequisites:
#   - bash scripts/06_profile_ttl.sh completed (perf_asc.data + perf_desc.data exist)
#   - bash scripts/05_install_profiling.sh completed (FlameGraph/ exists)
#
# Run from the repo root: bash scripts/07_generate_flamegraphs.sh
set -euo pipefail

WORK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FLAMEGRAPH_DIR="${WORK_DIR}/FlameGraph"

for f in "${WORK_DIR}/perf_asc.data" "${WORK_DIR}/perf_desc.data"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: ${f} not found. Run bash scripts/06_profile_ttl.sh first."
        exit 1
    fi
done

if [ ! -f "${FLAMEGRAPH_DIR}/flamegraph.pl" ]; then
    echo "ERROR: FlameGraph scripts not found. Run bash scripts/05_install_profiling.sh first."
    exit 1
fi

generate() {
    local data="$1"
    local title="$2"
    local out="$3"

    echo "Generating: ${out}"

    perf script -i "${data}" 2>/dev/null \
        | "${FLAMEGRAPH_DIR}/stackcollapse-perf.pl" \
        | "${FLAMEGRAPH_DIR}/flamegraph.pl" \
            --title "${title}" \
            --width 1600 \
            --colors hot \
        > "${out}"

    echo "  Saved: ${out}"
}

generate \
    "${WORK_DIR}/perf_asc.data" \
    "SERVER-56274: TTL ASC (fast run)" \
    "${WORK_DIR}/flamegraph_asc.svg"

generate \
    "${WORK_DIR}/perf_desc.data" \
    "SERVER-56274: TTL DESC (slow run)" \
    "${WORK_DIR}/flamegraph_desc.svg"

echo ""
echo "=== Flamegraphs generated ==="
echo ""
echo "Open both SVGs in a browser (Ctrl+click to open from terminal):"
echo "  ${WORK_DIR}/flamegraph_asc.svg"
echo "  ${WORK_DIR}/flamegraph_desc.svg"
echo ""
echo "What to look for:"
echo "  1. Use the browser's Ctrl+F search to find 'restoreState'."
echo "     ASC flamegraph : restoreState tower is NARROW (minor fraction of total width)."
echo "     DESC flamegraph: restoreState tower is WIDE (dominates — indicates the bug)."
echo ""
echo "  2. In the DESC flamegraph, expand the restoreState stack down to:"
echo "        PlanStage::restoreState"
echo "        └─ RequiresIndexStage::doRestoreStateRequiresCollection"
echo "           └─ WiredTigerIndexCursorBase::restore"
echo "              └─ WiredTigerIndexCursorBase::seekWTCursor"
echo "                 └─ __curfile_search_near"
echo "                    └─ __wt_btcur_search_near"
echo "                       ├─ __wt_btcur_next_prefix  ← wasteful forward scan"
echo "                       └─ __wt_btcur_prev_prefix  ← actual backward work"
echo ""
echo "  3. Both __wt_btcur_next_prefix AND __wt_btcur_prev_prefix appearing as"
echo "     significant children of __wt_btcur_search_near in the DESC graph is the"
echo "     flamegraph signature of this bug. In the ASC graph, only next_prefix appears."
echo ""
echo "Next: bash scripts/08_build_instrumented.sh  (source build with print probes)"
