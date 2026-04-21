/**
 * Reproduces the inconsistent TTL delete performance between ascending and
 * descending indexes (MongoDB SERVER-56274).
 *
 * Run with:
 *   ./mongodb-4.4.0/bin/mongo scripts/04_ttl_repro.js
 *
 * To run only one scenario (used by the profiling script):
 *   ./mongodb-4.4.0/bin/mongo --eval "var testMode='asc'" scripts/04_ttl_repro.js
 *   ./mongodb-4.4.0/bin/mongo --eval "var testMode='desc'" scripts/04_ttl_repro.js
 *
 * Expected output:
 *   inserted 10000
 *   starting TTL with ascending index
 *   TTL with ascending index: ~1600ms
 *   inserted 10000
 *   starting TTL with descending index
 *   TTL with descending index: ~9300ms
 */
(function () {

// Controlled by --eval "var testMode='asc'" or 'desc'. Defaults to 'both'.
const mode = (typeof testMode !== "undefined") ? testMode : "both";

const time = (fn, desc) => {
    print("starting " + desc);
    const start = new Date();
    fn();
    const end = new Date();
    print(desc + ": " + (end - start) + "ms");
};

// Drop the collection, then insert DOCS documents timestamped right now.
// expireAfterSeconds: 0 means "expire immediately" — any document whose
// 't' field value is <= now will be deleted on the next TTL monitor pass.
const bulkLoad = (coll) => {
    coll.drop();
    const DOCS = 10 * 1000;
    for (let i = 0; i < DOCS / 1000; i++) {
        const bulk = coll.initializeUnorderedBulkOp();
        for (let j = 0; j < 1000; j++) {
            bulk.insert({ t: new Date() });
        }
        assert.commandWorked(bulk.execute());
    }
    print("inserted " + DOCS);
};

const stopTTL = () => {
    assert.commandWorked(
        db.adminCommand({ setParameter: 1, ttlMonitorEnabled: false })
    );
};

const startTTL = () => {
    assert.commandWorked(
        db.adminCommand({ setParameter: 1, ttlMonitorEnabled: true })
    );
};

// Poll until the TTL monitor has completed at least 2 full passes since this
// function was called. Two passes guarantees that the monitor has scanned and
// deleted all expired documents, not just started deleting them.
const waitForTTL = () => {
    const baseline = db.serverStatus().metrics.ttl.passes;
    assert.soon(
        () => db.serverStatus().metrics.ttl.passes >= baseline + 2,
        "TTL monitor did not complete 2 passes within the timeout",
        120 * 1000,   // 2-minute hard timeout
        500           // poll every 500 ms
    );
};

// Reduce the TTL monitor sleep so we don't wait 60 s between passes.
assert.commandWorked(
    db.adminCommand({ setParameter: 1, ttlMonitorSleepSecs: 1 })
);

const testColl = db.getSiblingDB("ttl_repro").coll;

const testAscending = () => {
    bulkLoad(testColl);
    stopTTL();
    assert.commandWorked(testColl.createIndex({ t: 1 }, { expireAfterSeconds: 0 }));
    startTTL();
    time(() => { waitForTTL(); }, "TTL with ascending index");
};

const testDescending = () => {
    bulkLoad(testColl);
    stopTTL();
    assert.commandWorked(testColl.createIndex({ t: -1 }, { expireAfterSeconds: 0 }));
    startTTL();
    time(() => { waitForTTL(); }, "TTL with descending index");
};

if (mode === "asc"  || mode === "both") { testAscending(); }
if (mode === "desc" || mode === "both") { testDescending(); }

})();
