// RPC
const RPC_URL = "http://10.10.10.201:5163";
const RPC_USER = "zero";
const RPC_PASS = "zero.zero";

const express = require("express");
const fs = require("fs");
const path = require("path");

const app = express();
const PORT = 3000;

const BASE = "/zero/ckpool/logs";
const POOL_FILE = `${BASE}/pool/pool.status`;
const USERS_DIR = `${BASE}/users`;

app.use(express.static("public"));

// ---------------- JSON ----------------
function readJSON(file) {
    try {
        return JSON.parse(fs.readFileSync(file, "utf-8"));
    } catch {
        return null;
    }
}

// ---------------- POOL ----------------
function getPoolStats() {
    const lines = fs.readFileSync(POOL_FILE, "utf-8").trim().split("\n");

    return {
        summary: JSON.parse(lines[0]),
        hashrate: JSON.parse(lines[1]),
        shares: JSON.parse(lines[2])
    };
}

// ---------------- USERS ----------------
function getUsers() {
    return fs.readdirSync(USERS_DIR);
}

function getUser(addr) {
    return readJSON(`${USERS_DIR}/${addr}`);
}

// ---------------- RPC ----------------
async function rpcCall(method, params = []) {
    try {
        const res = await fetch(RPC_URL, {
            method: "POST",
            headers: {
                "Content-Type": "application/json",
                "Authorization":
                    "Basic " +
                    Buffer.from(`${RPC_USER}:${RPC_PASS}`).toString("base64")
            },
            body: JSON.stringify({
                jsonrpc: "1.0",
                id: "ckpool",
                method,
                params
            })
        });

        const json = await res.json();
        return json.result;
    } catch {
        return null;
    }
}

// ---------------- BLOCK CACHE ----------------
let BLOCK_CACHE = [];

async function scanBlocks() {
    const candidates = [];

    function walk(dir) {
        const files = fs.readdirSync(dir);

        for (const file of files) {
            const full = path.join(dir, file);

            if (fs.statSync(full).isDirectory()) {
                walk(full);
                continue;
            }

            if (!file.endsWith(".sharelog")) continue;

            const lines = fs.readFileSync(full, "utf-8").split("\n");

            for (const line of lines) {
                if (!line.trim()) continue;

                try {
                    const obj = JSON.parse(line);

                    if (obj.result !== true) continue;
                    if (obj.sdiff < 1000000) continue;

                    const fullWorker = obj.workername || "unknown";
                    const shortWorker = fullWorker.includes(".")
                        ? fullWorker.split(".").pop()
                        : fullWorker;

                    candidates.push({
                        workerFull: fullWorker,
                        worker: shortWorker,
                        user: obj.username || "unknown",
                        hash: obj.hash
                    });

                } catch {}
            }
        }
    }

    walk(BASE);

    const real = [];

    for (const c of candidates.reverse()) {
        const block = await rpcCall("getblock", [c.hash]);
        if (!block) continue;

        real.push({
            workerFull: c.workerFull,
            worker: c.worker,
            user: c.user,
            hash: c.hash,
            height: block.height,
            reward: block.reward || block.coinbasevalue || "-",
            time: block.time
        });
    }

    BLOCK_CACHE = real;
    console.log("Blocks updated:", BLOCK_CACHE.length);
}

setInterval(scanBlocks, 30000);
scanBlocks();

// ---------------- NEW: NETWORK DIFFICULTY FIX ----------------
async function getNetworkDifficulty() {
    const res = await rpcCall("getmininginfo");
    if (!res) return 0;
    return res.difficulty || 0;
}

// ---------------- API ----------------
app.get("/api/pool", async (req, res) => {
    const pool = getPoolStats();

    // FIXED: real difficulty from node RPC
    const difficulty = await getNetworkDifficulty();
    pool.summary.difficulty = difficulty;

    pool.blocksFound = BLOCK_CACHE.length;
    pool.blocks = BLOCK_CACHE;

    res.json(pool);
});

app.get("/api/users", (req, res) => {
    res.json(getUsers());
});

app.get("/api/user/:addr", (req, res) => {
    const data = getUser(req.params.addr);
    if (!data) return res.json(null);

    const userBlocks = BLOCK_CACHE.filter(b => b.user === req.params.addr);
    data.blocksFound = userBlocks.length;

    const workerMap = {};
    for (const b of userBlocks) {
        workerMap[b.worker] = (workerMap[b.worker] || 0) + 1;
    }

    data.worker = data.worker.map(w => {
        const short = w.workername.includes(".")
            ? w.workername.split(".").pop()
            : w.workername;

        return {
            ...w,
            blocksFound: workerMap[short] || 0
        };
    });

    res.json(data);
});

app.listen(PORT, () => {
    console.log(`Dashboard running: http://localhost:${PORT}`);
});
