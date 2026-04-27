/**
 * Zero Mining - ckwebui backend server
 * Serves the dashboard and proxies ckpool API / log data
 */

'use strict';

const express = require('express');
const path    = require('path');
const fs      = require('fs');
const yaml    = require('js-yaml');
const fetch   = require('node-fetch');
const http    = require('http');
const { WebSocketServer } = require('ws');

// ─── Config ───────────────────────────────────────────────────────────────────
const YAML_PATH   = process.env.CKWEBUI_YAML || path.join(__dirname, 'ckwebui.yaml');
const LOG_DIR     = process.env.CKPOOL_LOG_DIR || '/ckpool/logs';
const PORT_WEB    = parseInt(process.env.PORT_WEB  || process.env.PORT || 3015);

function loadConfig() {
  if (!fs.existsSync(YAML_PATH)) return [];
  try {
    const raw = fs.readFileSync(YAML_PATH, 'utf8');
    return yaml.loadAll(raw).flat().filter(Boolean);
  } catch (e) {
    console.error('[CONFIG] Failed to parse ckwebui.yaml:', e.message);
    return [];
  }
}

// ─── ckpool API helpers ───────────────────────────────────────────────────────
async function ckpoolApi(host, port, endpoint, timeout = 3000) {
  const url = `http://${host}:${port}/api/${endpoint}`;
  const ctrl = new AbortController();
  const tid  = setTimeout(() => ctrl.abort(), timeout);
  try {
    const res  = await fetch(url, { signal: ctrl.signal });
    const data = await res.json();
    return { ok: true, data };
  } catch (_) {
    return { ok: false, data: null };
  } finally {
    clearTimeout(tid);
  }
}

async function rpcCall(host, port, user, pass, method, params = []) {
  const body = JSON.stringify({ jsonrpc: '1.1', id: 1, method, params });
  try {
    const res = await fetch(`http://${user}:${pass}@${host}:${port}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body,
      timeout: 5000
    });
    const json = await res.json();
    return json.result;
  } catch (_) {
    return null;
  }
}

// ─── Log parsers ─────────────────────────────────────────────────────────────
function parsePoolStats(logDir) {
  const file = path.join(logDir, 'pool.log');
  if (!fs.existsSync(file)) return null;
  const lines = fs.readFileSync(file, 'utf8').split('\n').filter(Boolean);
  const stats = {};
  for (const line of lines.reverse()) {
    const m = line.match(/SPS60=([0-9.]+)\s+SPS1440=([0-9.]+)/);
    if (m) { stats.sps60 = parseFloat(m[1]); stats.sps1440 = parseFloat(m[2]); break; }
  }
  return stats;
}

function parseMiners(logDir, cutoffHours = 24) {
  const file = path.join(logDir, 'users.log');
  if (!fs.existsSync(file)) return [];
  const now = Date.now();
  const cutoff = cutoffHours * 3600 * 1000;
  const miners = {};

  const lines = fs.readFileSync(file, 'utf8').split('\n').filter(Boolean);
  for (const line of lines) {
    try {
      const obj = JSON.parse(line);
      if (!obj.username) continue;
      const ts = new Date(obj.lastshare || 0).getTime();
      if (now - ts > cutoff) continue;
      if (!miners[obj.username]) miners[obj.username] = { address: obj.username, workers: {}, blocks: 0, rewards: 0 };
      const m = miners[obj.username];
      m.blocks  = Math.max(m.blocks,  obj.blocks  || 0);
      m.rewards = Math.max(m.rewards, obj.rewards || 0);
      if (obj.workername) {
        m.workers[obj.workername] = {
          worker:      obj.workername,
          hashrate:    obj.hashrate5m || 0,
          blocks:      obj.blocks    || 0,
          shares:      obj.shares    || 0,
          bestshare:   obj.bestshare || 0,
          bestever:    obj.bestever  || 0,
          lastshare:   obj.lastshare || null
        };
      }
    } catch (_) { /* skip malformed */ }
  }
  return Object.values(miners);
}

function parseBlocks(logDir, blocksYaml) {
  // Prefer persisted yaml
  if (fs.existsSync(blocksYaml)) {
    try {
      return yaml.load(fs.readFileSync(blocksYaml, 'utf8')) || [];
    } catch (_) {}
  }
  // Fallback: parse pool.log for block lines
  const file = path.join(logDir, 'pool.log');
  if (!fs.existsSync(file)) return [];
  const blocks = [];
  const lines  = fs.readFileSync(file, 'utf8').split('\n').filter(Boolean);
  for (const line of lines) {
    const m = line.match(/Block found by (.+?) worker (.+?) height (\d+)/);
    if (m) {
      blocks.push({ user: m[1], worker: m[2], height: parseInt(m[3]), time: null, status: 'Pending', reward: 0 });
    }
  }
  return blocks;
}

// ─── Express app ─────────────────────────────────────────────────────────────
const app = express();
app.use(express.json());

// Security: block direct access to yaml / log / config files
app.use((req, res, next) => {
  if (/\.(yaml|yml|log|conf|sh|json)$/i.test(req.path) && !req.path.startsWith('/api/')) {
    return res.status(403).json({ error: 'Forbidden' });
  }
  next();
});

// Static frontend
app.use(express.static(path.join(__dirname, 'public')));

// ─── API Routes ───────────────────────────────────────────────────────────────

// GET /api/config  - return sanitised pool configs (no credentials)
app.get('/api/config', (req, res) => {
  const cfgs = loadConfig().map(c => ({
    node:     c.node,
    name:     c.name,
    algo:     c.algo,
    host:     c.host,
    port_web: c.port_web,
    port_low: c.port_low,
    port_hgh: c.port_hgh,
    diff_low: c.diff_low,
    diff_hgh: c.diff_hgh
  }));
  res.json(cfgs);
});

// GET /api/:node/stats
app.get('/api/:node/stats', async (req, res) => {
  const node = req.params.node.toUpperCase();
  const cfg  = loadConfig().find(c => c.node === node);
  if (!cfg) return res.status(404).json({ error: 'Node not found' });

  // Try ckpool API first
  const api = await ckpoolApi(cfg.host, cfg.port_web, 'pool/stats');
  if (api.ok) {
    return res.json({ source: 'api', ...api.data });
  }

  // Fallback: RPC + log
  const [bchainInfo, netHashps, miningInfo] = await Promise.all([
    rpcCall(cfg.host, cfg.port_rpc, cfg.rpc_user, cfg.rpc_pass, 'getblockchaininfo'),
    rpcCall(cfg.host, cfg.port_rpc, cfg.rpc_user, cfg.rpc_pass, 'getnetworkhashps'),
    rpcCall(cfg.host, cfg.port_rpc, cfg.rpc_user, cfg.rpc_pass, 'getmininginfo')
  ]);

  const logStats = parsePoolStats(LOG_DIR);

  res.json({
    source:          'log+rpc',
    height:          bchainInfo?.blocks          || 0,
    networkDiff:     miningInfo?.difficulty       || 0,
    networkHashrate: netHashps                    || 0,
    poolHashrate:    logStats?.sps60 * 1e9        || 0,  // approx from shares/sec
    miners:          0,
    workers:         0,
    uptime:          0
  });
});

// GET /api/:node/miners
app.get('/api/:node/miners', async (req, res) => {
  const node = req.params.node.toUpperCase();
  const cfg  = loadConfig().find(c => c.node === node);
  if (!cfg) return res.status(404).json({ error: 'Node not found' });

  const api = await ckpoolApi(cfg.host, cfg.port_web, 'users');
  if (api.ok) return res.json({ source: 'api', miners: api.data });

  const miners = parseMiners(LOG_DIR);
  res.json({ source: 'log', miners });
});

// GET /api/:node/blocks
app.get('/api/:node/blocks', async (req, res) => {
  const node = req.params.node.toUpperCase();
  const cfg  = loadConfig().find(c => c.node === node);
  if (!cfg) return res.status(404).json({ error: 'Node not found' });

  const blocksYaml = cfg.blocks_file || path.join(__dirname, `blocks-${node.toLowerCase()}.yaml`);

  const api = await ckpoolApi(cfg.host, cfg.port_web, 'blocks');
  if (api.ok) {
    // Persist to yaml
    try { fs.writeFileSync(blocksYaml, yaml.dump(api.data)); } catch (_) {}
    return res.json({ source: 'api', blocks: api.data });
  }

  const blocks = parseBlocks(LOG_DIR, blocksYaml);
  res.json({ source: 'log', blocks });
});

// Catch-all → serve index.html
app.get('*', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

// ─── HTTP + WebSocket server ──────────────────────────────────────────────────
const server = http.createServer(app);
const wss    = new WebSocketServer({ server, path: '/ws' });

wss.on('connection', (ws) => {
  ws.send(JSON.stringify({ type: 'connected', msg: 'Zero Mining WebSocket ready' }));
});

// Broadcast new-block events every 30 s (real impl would be ZMQ-triggered)
setInterval(async () => {
  const cfgs = loadConfig();
  for (const cfg of cfgs) {
    const blocksYaml = cfg.blocks_file || path.join(__dirname, `blocks-${cfg.node.toLowerCase()}.yaml`);
    const api = await ckpoolApi(cfg.host, cfg.port_web, 'blocks');
    let blocks = api.ok ? api.data : parseBlocks(LOG_DIR, blocksYaml);
    if (api.ok) {
      try { fs.writeFileSync(blocksYaml, yaml.dump(blocks)); } catch (_) {}
    }
    wss.clients.forEach(client => {
      if (client.readyState === 1) {
        client.send(JSON.stringify({ type: 'blocks', node: cfg.node, blocks }));
      }
    });
  }
}, 30_000);

server.listen(PORT_WEB, () => {
  console.log(`[Zero Mining] ckwebui running on port ${PORT_WEB}`);
});
