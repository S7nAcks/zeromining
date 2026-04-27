# Zero Mining — Setup Guide

## Overview

`zeromining-setup` reads `zero.yaml` and `nodes.yaml` to:

1. **Build ckpool** from source and install binaries to `PATH_BASE/ckpool/`
2. **Generate a Dockerfile + docker-compose.yml** for every node whose `init:` is `Pool` or `NodePool`
3. **Set up the ckwebui dashboard** (Node.js + Express) with real-time stats, miners, blocks, and stratum connection info

---

## Prerequisites

| Tool | Install |
|------|---------|
| `yq` v4+ | `snap install yq` or `brew install yq` |
| `docker` | https://docs.docker.com/engine/install/ |
| `git` | `apt install git` |
| `autoconf`, `make`, `gcc`, `libzmq3-dev` | `apt install autoconf automake build-essential libzmq3-dev` |
| `node` ≥ 18 | https://nodejs.org |

---

## Usage

```bash
chmod +x zeromining-setup
./zeromining-setup
```

The script will:
- Detect your Docker host IP automatically
- Build ckpool from https://bitbucket.org/ckolivas/ckpool.git
- Create `/zero/.pools/<NODE>/` directories with:
  - `Dockerfile`
  - `docker-compose.yml`
  - `ckpool.conf`
  - `entrypoint.sh`
- Install ckpool binaries to `/zero/ckpool/`
- Copy the ckwebui site to `/zero/ckwebui/`
- Write `/zero/ckwebui/ckwebui.yaml` with all pool configs

---

## Starting a Pool

```bash
# Example: Bitcoin (BTC)
cd /zero/.pools/BTC
docker compose up -d --build

# Example: Digibyte (DGB)
cd /zero/.pools/DGB
docker compose up -d --build
```

---

## Port Mapping

Ports are calculated as: `base_port + node_id`

| Node | id | Web   | Low   | High  | RPC   | ZMQ   | P2P   |
|------|----|-------|-------|-------|-------|-------|-------|
| BTC  | 11 | 3011  | 3311  | 4411  | 5511  | 5711  | 8011  |
| DGB  | 15 | 3015  | 3315  | 4415  | 5515  | 5715  | 8015  |
| NITO | 16 | 3016  | 3316  | 4416  | 5516  | 5716  | 8016  |

---

## ckwebui Dashboard

The dashboard runs on each pool's `PORT_WEB`.

**Features:**
- **Dashboard tab** — Pool stats, active miners (expandable to workers), blocks found table
- **Connect tab** — Stratum connection strings for both low and high difficulty
- Block-found **chime + toast notification**
- Auto-refresh every **45 seconds**
- WebSocket push for real-time block alerts
- Blocks persisted to `/zero/ckwebui/blocks-<node>.yaml`

**Data sources** (tried in order):
1. ckpool HTTP API (`/api/…`)
2. Node RPC + pool log files (fallback)

---

## Security

- YAML, log, conf, and shell files are blocked from direct browser access
- RPC credentials are kept server-side only and never sent to the browser
- The Node RPC is accessed only from the server process, not from user browsers

---

## File Layout

```
/zero/
├── ckpool/          ← ckpool, ckpmsg, notifier binaries
├── ckwebui/         ← dashboard (server.js, public/, ckwebui.yaml)
│   └── blocks-btc.yaml  (auto-created, persists block history)
├── .pools/
│   ├── .ckwebui/    ← website source (copied to /zero/ckwebui/)
│   ├── BTC/
│   │   ├── Dockerfile
│   │   ├── docker-compose.yml
│   │   ├── ckpool.conf
│   │   └── entrypoint.sh
│   ├── DGB/
│   └── NITO/
└── .nodes/
```
