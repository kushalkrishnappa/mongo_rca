#!/usr/bin/env bash
# Start a local MongoDB 4.4.0 instance configured for TTL reproduction.
# Run from the repo root: bash scripts/02_start_mongod.sh
set -euo pipefail

WORK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MONGO_BIN="${WORK_DIR}/mongodb-4.4.0/bin"
DBPATH="${WORK_DIR}/data"
LOGPATH="${WORK_DIR}/logs/mongod.log"

echo "=== Starting mongod ==="

# Stop any existing instance on port 27017 cleanly.
if pgrep -x mongod >/dev/null 2>&1; then
    echo "Existing mongod detected — stopping it first..."
    pkill -x mongod || true
    sleep 2
fi

mkdir -p "$DBPATH" "$(dirname "$LOGPATH")"

# --replSet rs     : required so that TTL index writes go through the oplog
#                    (same configuration used in the original bug reporter's setup)
# --setParameter ttlMonitorSleepSecs=1
#                  : TTL monitor default sleep is 60 s; reduce to 1 s so we
#                    don't wait a minute between passes during reproduction
# --dbpath         : isolated data directory, won't conflict with any system mongod
# --logpath / --fork : run as a background daemon; logs go to logs/mongod.log
"${MONGO_BIN}/mongod" \
    --replSet rs \
    --setParameter ttlMonitorSleepSecs=1 \
    --dbpath  "$DBPATH" \
    --logpath "$LOGPATH" \
    --port 27017 \
    --fork

echo "mongod started. PID: $(pgrep -x mongod)"
echo "Log: ${LOGPATH}"
echo ""
echo "Next: ${MONGO_BIN}/mongo scripts/03_init_replset.js"
