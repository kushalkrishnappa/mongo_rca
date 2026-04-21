/**
 * Initialize a single-node replica set named "rs".
 *
 * Run with:
 *   ./mongodb-4.4.0/bin/mongo scripts/03_init_replset.js
 *
 * Must be run immediately after 02_start_mongod.sh, before any other script.
 * The replica set is required so that TTL index deletes are replicated through
 * the oplog — the same configuration used in the original bug report.
 */

const config = {
    _id: "rs",
    members: [{ _id: 0, host: "localhost:27017" }]
};

print("Initiating replica set 'rs'...");
const res = rs.initiate(config);
if (res.ok !== 1) {
    print("ERROR: rs.initiate() failed: " + tojson(res));
    quit(1);
}

// Wait until this node becomes PRIMARY before handing control back.
print("Waiting for PRIMARY election...");
let attempts = 0;
while (true) {
    const status = rs.status();
    if (status.ok === 1) {
        const primary = status.members.find(m => m.stateStr === "PRIMARY");
        if (primary) {
            print("Replica set ready. Primary: " + primary.name);
            break;
        }
    }
    if (++attempts > 30) {
        print("ERROR: PRIMARY not elected after 30 seconds.");
        quit(1);
    }
    sleep(1000);
    print("  ... still waiting (" + attempts + "s)");
}

print("");
print("Replica set initialized. Ready for TTL reproduction.");
print("Next: ./mongodb-4.4.0/bin/mongo scripts/04_ttl_repro.js");
