#!/usr/bin/env bash
# Phase 1 — Download and prepare MongoDB 4.4.0 for Ubuntu 24.04.
# Run once from the repo root: bash scripts/01_setup_env.sh
set -euo pipefail

MONGO_VERSION="4.4.0"
MONGO_TARBALL="mongodb-linux-x86_64-ubuntu2004-${MONGO_VERSION}.tgz"
MONGO_URL="https://fastdl.mongodb.org/linux/${MONGO_TARBALL}"
INSTALL_DIR="$(cd "$(dirname "$0")/.." && pwd)/mongodb-${MONGO_VERSION}"

echo "=== MongoDB ${MONGO_VERSION} Environment Setup ==="
echo "Target directory: ${INSTALL_DIR}"

# ── Step 1: install runtime dependencies ──────────────────────────────────────
echo ""
echo "[1/4] Installing runtime dependencies..."
sudo apt-get update -qq
sudo apt-get install -y -qq wget libcurl4 libgssapi-krb5-2

# MongoDB 4.4.0 was built against libssl1.1. Ubuntu 24.04 ships libssl3.
# We need to install the older library from the Ubuntu 20.04 (Focal) archive.
if ! ldconfig -p | grep -q libssl.so.1.1; then
    echo "      libssl1.1 not found — installing from Ubuntu 20.04 archive..."
    TMP_DEB=$(mktemp --suffix=.deb)
    wget -q -O "$TMP_DEB" \
        "http://archive.ubuntu.com/ubuntu/pool/main/o/openssl/libssl1.1_1.1.1f-1ubuntu2_amd64.deb"
    sudo dpkg -i "$TMP_DEB"
    rm -f "$TMP_DEB"
    echo "      libssl1.1 installed."
else
    echo "      libssl1.1 already present."
fi

# ── Step 2: download tarball ───────────────────────────────────────────────────
echo ""
echo "[2/4] Downloading MongoDB ${MONGO_VERSION}..."
WORK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$WORK_DIR"

if [ -f "${MONGO_TARBALL}" ]; then
    echo "      Tarball already exists — skipping download."
else
    wget -q --show-progress "${MONGO_URL}" -O "${MONGO_TARBALL}"
fi

# ── Step 3: extract ────────────────────────────────────────────────────────────
echo ""
echo "[3/4] Extracting to ${INSTALL_DIR}..."
if [ -d "${INSTALL_DIR}" ]; then
    echo "      Directory already exists — skipping extraction."
else
    tar -xzf "${MONGO_TARBALL}"
    # The tarball extracts to mongodb-linux-x86_64-ubuntu2004-4.4.0/
    mv "mongodb-linux-x86_64-ubuntu2004-${MONGO_VERSION}" "${INSTALL_DIR}"
fi

# ── Step 4: verify linkage ─────────────────────────────────────────────────────
echo ""
echo "[4/4] Verifying binary linkage..."
if ldd "${INSTALL_DIR}/bin/mongod" 2>&1 | grep -q "not found"; then
    echo "ERROR: mongod has unresolved shared library dependencies:"
    ldd "${INSTALL_DIR}/bin/mongod" | grep "not found"
    echo ""
    echo "On Ubuntu 24.04, the most common fix is 'sudo apt install libssl1.1'."
    echo "The script above should have handled this; try running it again or"
    echo "manually install: wget ... libssl1.1_1.1.1f-1ubuntu2_amd64.deb && sudo dpkg -i ..."
    exit 1
fi
echo "      All libraries resolved — mongod is ready."

echo ""
echo "=== MongoDB ${MONGO_VERSION} ready ==="
echo "Binary: ${INSTALL_DIR}/bin/mongod"
echo ""
echo "Next: bash scripts/02_start_mongod.sh"
