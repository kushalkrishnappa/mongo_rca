#!/usr/bin/env bash
# Phase 3 — Clone MongoDB 4.4.0 source, add fprintf probes to the exact
# WiredTiger function identified as the root cause, then build mongod.
#
# The instrumented binary makes the bug self-documenting: every cursor
# restoration during a TTL pass prints which direction it searched, proving
# that the DESC run wastes the forward pass on tombstones before falling back.
#
# IMPORTANT: This build takes 30–90 minutes on a modern laptop.
#            Run from the repo root: bash scripts/08_build_instrumented.sh
set -euo pipefail

WORK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="${WORK_DIR}/mongo_source"

echo "=== Building Instrumented MongoDB 4.4.0 ==="

# ── Step 1: build dependencies ────────────────────────────────────────────────
echo ""
echo "[1/5] Installing build dependencies..."
sudo apt-get update -qq
sudo apt-get install -y -qq \
    build-essential git \
    python3 python3-pip python3-dev python3-venv \
    libcurl4-openssl-dev libssl-dev \
    cmake ninja-build

# MongoDB 4.4 build scripts import `imp`, removed in Python 3.12.
# Use Python < 3.12 for the scons venv.
if python3 -c 'import sys; raise SystemExit(0 if sys.version_info < (3, 12) else 1)'; then
    BUILD_PYTHON="python3"
else
    echo "      System python is >= 3.12; installing python3.11 for MongoDB 4.4 compatibility..."
    sudo apt-get install -y -qq python3.11 python3.11-venv python3.11-dev
    BUILD_PYTHON="python3.11"
fi

# MongoDB 4.4 uses SCons. Install into a venv to comply with PEP 668
# (Ubuntu 24.04+ blocks system-wide pip installs).
# setuptools is required by MongoDB 4.4's SConstruct (pkg_resources import).
VENV_DIR="${WORK_DIR}/.scons_venv"
if [ -d "${VENV_DIR}" ] && ! "${VENV_DIR}/bin/python" -c 'import sys; raise SystemExit(0 if sys.version_info < (3, 12) else 1)'; then
    echo "      Existing .scons_venv uses Python >= 3.12; recreating with ${BUILD_PYTHON}."
    rm -rf "${VENV_DIR}"
fi
[ -d "${VENV_DIR}" ] || "${BUILD_PYTHON}" -m venv "${VENV_DIR}"
VENV_PYTHON="${VENV_DIR}/bin/python"
"${VENV_PYTHON}" -m pip install --quiet --upgrade \
    "pip" "setuptools<81" "wheel" \
    "scons==3.1.2"
export PATH="${VENV_DIR}/bin:${PATH}"

if ! command -v scons >/dev/null 2>&1; then
    echo "ERROR: scons not found after venv install. Check ${VENV_DIR}."
    exit 1
fi

if ! "${VENV_PYTHON}" -c "import pkg_resources" >/dev/null 2>&1; then
    echo "ERROR: pkg_resources is not available in ${VENV_PYTHON}."
    echo "       Recreate ${VENV_DIR} and rerun this script."
    exit 1
fi

echo "      scons: $(scons --version 2>&1 | head -1)"

# ── Step 2: clone source ───────────────────────────────────────────────────────
echo ""
echo "[2/5] Cloning MongoDB r4.4.0 (shallow clone)..."
if [ -d "${SRC_DIR}/.git" ]; then
    echo "      Source directory already exists — skipping clone."
else
    git clone --depth 1 --branch r4.4.0 \
        https://github.com/mongodb/mongo.git "${SRC_DIR}"
fi

# Install MongoDB's own Python requirements when available.
# This avoids chasing missing modules one by one (psutil, pyyaml, etc.).
REQ_FILE="${SRC_DIR}/buildscripts/requirements.txt"
echo ""
echo "      Installing MongoDB Python requirements..."
if [ -f "${REQ_FILE}" ]; then
    if ! "${VENV_PYTHON}" -m pip install --quiet -r "${REQ_FILE}"; then
        echo "      WARNING: requirements install failed; falling back to minimal build deps."
        "${VENV_PYTHON}" -m pip install --quiet "psutil" "pyyaml" "cheetah3"
    fi
else
    echo "      WARNING: ${REQ_FILE} not found; installing minimal build deps."
    "${VENV_PYTHON}" -m pip install --quiet "psutil" "pyyaml" "cheetah3"
fi

if ! "${VENV_PYTHON}" -c "import psutil, yaml" >/dev/null 2>&1; then
    echo "ERROR: Required Python build modules (psutil/yaml) are missing in ${VENV_PYTHON}."
    exit 1
fi

# Modern glibc exposes MINSIGSTKSZ via sysconf(), which is not constexpr.
# MongoDB 4.4 expects a constexpr value and fails to compile on newer distros.
THREAD_HDR="${SRC_DIR}/src/mongo/stdx/thread.h"
if [ -f "${THREAD_HDR}" ] && grep -q "std::size_t{MINSIGSTKSZ}" "${THREAD_HDR}" && ! grep -q "kStackSize()" "${THREAD_HDR}"; then
    echo "      Applying glibc compatibility patch to src/mongo/stdx/thread.h..."
    "${VENV_PYTHON}" - "${THREAD_HDR}" <<'PYEOF'
import sys

path = sys.argv[1]
src = open(path, "r").read()

src = src.replace("ss.ss_size = kStackSize;", "ss.ss_size = kStackSize();")
src = src.replace(
    "static constexpr std::size_t kStackSize =\n"
    "        std::max(kMongoMinSignalStackSize, std::size_t{MINSIGSTKSZ});\n"
    "    std::unique_ptr<std::byte[]> _stackStorage = std::make_unique<std::byte[]>(kStackSize);",
    "static std::size_t kStackSize() {\n"
    "        return std::max(kMongoMinSignalStackSize, std::size_t{MINSIGSTKSZ});\n"
    "    }\n"
    "    std::unique_ptr<std::byte[]> _stackStorage = std::make_unique<std::byte[]>(kStackSize());"
)

open(path, "w").write(src)
PYEOF
fi

# ── Step 3: locate the root-cause function ────────────────────────────────────
echo ""
echo "[3/5] Locating __wt_btcur_search_near in WiredTiger source..."

BT_CURSOR=""
for candidate in \
    "${SRC_DIR}/src/third_party/wiredtiger/src/btree/bt_cursor.c" \
    "${SRC_DIR}/src/third_party/wiredtiger-4.4.0-mongodb-4.4.0/src/btree/bt_cursor.c"
do
    if [ -f "$candidate" ]; then
        BT_CURSOR="$candidate"
        break
    fi
done

if [ -z "${BT_CURSOR}" ]; then
    echo "Searching for bt_cursor.c..."
    BT_CURSOR=$(find "${SRC_DIR}/src/third_party" -name "bt_cursor.c" 2>/dev/null | head -1)
fi

if [ -z "${BT_CURSOR}" ] || ! grep -q "__wt_btcur_search_near" "${BT_CURSOR}"; then
    echo "ERROR: Could not find bt_cursor.c containing __wt_btcur_search_near."
    exit 1
fi
echo "      Found: ${BT_CURSOR}"

# ── Step 4: add fprintf instrumentation probes ────────────────────────────────
echo ""
echo "[4/5] Adding [WT_RCA] fprintf probes to __wt_btcur_search_near..."

if grep -q "WT_RCA" "${BT_CURSOR}"; then
    echo "      Probes already present — skipping patch."
else
    "${VENV_PYTHON}" - "${BT_CURSOR}" <<'PYEOF'
import re, sys

path = sys.argv[1]
with open(path, "r") as f:
    src = f.read()

applied = 0

# ── Probe 1: just before the forward-search while loop.
# This fires at the start of every cursor reposition, making the direction
# bias visible in the log output.
m = re.search(
    r'(while \(\(ret = __wt_btcur_next\(cbt, false\)\) != WT_NOTFOUND\) \{)',
    src
)
if m:
    insert = (
        '\n    /* [WT_RCA] The code ALWAYS tries forward (next) first regardless of index direction. */\n'
        '    fprintf(stderr, "[WT_RCA] search_near: BEGIN reposition. Trying FORWARD (__wt_btcur_next) first.\\n");\n'
        '    '
    )
    src = src[:m.start()] + insert + src[m.start():]
    applied += 1

# ── Probe 2: inside the forward loop, before `if (exact >= 0) goto done;`.
# Logs each key examined during the forward scan: valid key or tombstone.
m = re.search(r'(            if \(exact >= 0\)\n\s*goto done;)', src)
if m:
    insert = (
        '            fprintf(stderr, "[WT_RCA] search_near: FORWARD step: exact=%d  %s\\n",\n'
        '                exact, (exact >= 0) ? "VALID => done" : "TOMBSTONE => keep scanning");\n'
        '            '
    )
    src = src[:m.start()] + insert + src[m.start():]
    applied += 1

# ── Probe 3: just before the backward-search while loop.
# This is the CRITICAL probe: it fires ONLY when the forward scan was fully
# exhausted without finding a valid key (every entry was a tombstone).
# For DESC TTL runs this fires on EVERY single cursor restore — that is the bug.
m = re.search(
    r'(while \(\(ret = __wt_btcur_prev\(cbt, false\)\) != WT_NOTFOUND\) \{)',
    src
)
if m:
    insert = (
        '\n    /* [WT_RCA] Forward scan exhausted — all visited entries were tombstones. */\n'
        '    /* For a DESC TTL index this fires after EVERY delete: O(n) tombstone scan */\n'
        '    /* for each of the n deletions, making total work O(n^2).                  */\n'
        '    fprintf(stderr,'
        ' "[WT_RCA] search_near: FORWARD EXHAUSTED (only tombstones found). '
        'WASTEFUL fallback to BACKWARD. This is the SERVER-56274 bottleneck.\\n");\n'
        '    '
    )
    src = src[:m.start()] + insert + src[m.start():]
    applied += 1

# ── Probe 4: inside the backward loop, before `if (exact <= 0) goto done;`.
m = re.search(r'(            if \(exact <= 0\)\n\s*goto done;)', src)
if m:
    insert = (
        '            fprintf(stderr, "[WT_RCA] search_near: BACKWARD step: exact=%d  %s\\n",\n'
        '                exact, (exact <= 0) ? "VALID => done" : "TOMBSTONE => keep scanning");\n'
        '            '
    )
    src = src[:m.start()] + insert + src[m.start():]
    applied += 1

with open(path, "w") as f:
    f.write(src)

print(f"Applied {applied}/4 probes.")
if applied < 4:
    print("WARNING: Some probes were not applied. The regex patterns may not match")
    print("         this exact version of WiredTiger. Check bt_cursor.c manually.")
PYEOF

fi

echo "      Instrumented lines:"
grep -n "WT_RCA" "${BT_CURSOR}" || echo "      (no WT_RCA lines found — check probe output above)"

# ── Step 5: build ──────────────────────────────────────────────────────────────
echo ""
echo "[5/5] Building mongod (30–90 min depending on CPU — $(nproc) jobs)..."
echo "      Monitor progress: tail -f /tmp/mongo_build.log"

cd "${SRC_DIR}"
"${VENV_PYTHON}" buildscripts/scons.py \
    -j$(nproc) \
    --disable-warnings-as-errors \
    MONGO_VERSION=4.4.0 \
    install-mongod \
    2>&1 | tee /tmp/mongo_build.log

INSTRUMENTED_BIN=$(find "${SRC_DIR}/build" -name "mongod" -type f 2>/dev/null | head -1)

if [ -z "${INSTRUMENTED_BIN}" ]; then
    echo "ERROR: Build output not found. Check /tmp/mongo_build.log"
    exit 1
fi

echo ""
echo "=== Build complete ==="
echo "Instrumented binary: ${INSTRUMENTED_BIN}"
echo ""
echo "Next: bash scripts/09_run_instrumented.sh"
