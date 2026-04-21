#!/usr/bin/env bash
# Install Linux perf and Brendan Gregg's FlameGraph scripts.
# Run from the repo root: bash scripts/05_install_profiling.sh
set -euo pipefail

WORK_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== Installing Profiling Tools ==="

# ── Step 1: Linux perf ────────────────────────────────────────────────────────
echo ""
echo "[1/3] Installing linux-perf..."

# The kernel-specific package must match the running kernel exactly.
KERNEL=$(uname -r)
echo "      Running kernel: ${KERNEL}"

sudo apt-get update -qq
sudo apt-get install -y -qq \
    linux-tools-common \
    linux-tools-generic

# Install the kernel-specific tools if the package exists.
if apt-cache show "linux-tools-${KERNEL}" >/dev/null 2>&1; then
    sudo apt-get install -y -qq "linux-tools-${KERNEL}"
    echo "      linux-tools-${KERNEL} installed."
else
    echo "      WARNING: linux-tools-${KERNEL} not found in apt."
    echo "      'perf' may still work from linux-tools-generic."
    echo "      If 'perf' fails, try: sudo apt install linux-tools-\$(uname -r)"
fi

# Verify
if ! command -v perf >/dev/null 2>&1; then
    echo "ERROR: 'perf' command not found after installation."
    echo "       Try: sudo apt install linux-tools-\$(uname -r)"
    exit 1
fi
echo "      perf version: $(perf --version 2>&1 | head -1)"

# ── Step 2: kernel permission for profiling unprivileged processes ─────────────
echo ""
echo "[2/3] Adjusting perf_event_paranoid..."
CURRENT=$(cat /proc/sys/kernel/perf_event_paranoid)
if [ "$CURRENT" -gt 1 ]; then
    echo "      Current value: ${CURRENT} — setting to 1 (required for CPU profiling)"
    sudo sysctl -w kernel.perf_event_paranoid=1
    # Make persistent across reboots
    echo "kernel.perf_event_paranoid=1" | sudo tee -a /etc/sysctl.d/99-perf.conf >/dev/null
else
    echo "      Already set to ${CURRENT} — no change needed."
fi

# ── Step 3: Brendan Gregg's FlameGraph scripts ─────────────────────────────────
echo ""
echo "[3/3] Cloning FlameGraph repo..."
FLAMEGRAPH_DIR="${WORK_DIR}/FlameGraph"

if [ -d "$FLAMEGRAPH_DIR" ]; then
    echo "      FlameGraph directory already exists — pulling latest..."
    git -C "$FLAMEGRAPH_DIR" pull --quiet
else
    git clone --depth 1 https://github.com/brendangregg/FlameGraph.git "$FLAMEGRAPH_DIR"
fi
echo "      FlameGraph ready at: ${FLAMEGRAPH_DIR}"

echo ""
echo "=== Profiling tools installed ==="
echo ""
echo "MongoDB 4.4.0 release binaries retain their symbol tables (not fully stripped)."
echo "perf will resolve function names like:"
echo "  mongo::TTLMonitor::deleteExpiredWithIndex"
echo "  mongo::PlanStage::restoreState"
echo "  __wt_btcur_search_near"
echo "  __wt_btcur_next_prefix / __wt_btcur_prev_prefix"
echo ""
echo "Next: bash scripts/06_profile_ttl.sh"
