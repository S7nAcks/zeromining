const fetch = require("node-fetch");
const CONFIG = require("../config.json");

const EXPLORER = CONFIG.EXPLORER.base + CONFIG.EXPLORER.api;

let pendingBlocks = new Map();

function isCandidate(event) {
    // adjust threshold later based on your pool diff
    return event.sdiff && event.sdiff > 5e6;
}

async function verifyBlock(hash) {
    try {
        const res = await fetch(`${EXPLORER}/block/${hash}`);

        if (!res.ok) return null;

        return await res.json();
    } catch (e) {
        return null;
    }
}

function registerEvent(event, broadcast) {

    if (!isCandidate(event)) return;

    const id = event.hash || `${event.user}-${event.time}`;

    pendingBlocks.set(id, {
        event,
        status: "CANDIDATE",
        time: Date.now()
    });

    broadcast({
        type: "BLOCK_CANDIDATE",
        user: event.user,
        worker: event.worker,
        sdiff: event.sdiff
    });

    // async verify
    (async () => {

        const block = await verifyBlock(event.hash);

        if (block) {

            pendingBlocks.set(id, {
                ...pendingBlocks.get(id),
                status: "CONFIRMED",
                block
            });

            broadcast({
                type: "BLOCK_CONFIRMED",
                user: event.user,
                worker: event.worker,
                height: block.height,
                hash: event.hash
            });

        } else {
            pendingBlocks.set(id, {
                ...pendingBlocks.get(id),
                status: "UNCONFIRMED"
            });
        }
    })();
}

function getBlocks() {
    return Array.from(pendingBlocks.values());
}

module.exports = {
    registerEvent,
    getBlocks
};
