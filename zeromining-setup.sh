#!/usr/bin/env bash
# =============================================================================
# zeromining-setup
# Reads zero.yaml and nodes.yaml to create Docker pool environments for each
# eligible node (init: Pool or NodePool).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Dependency check ────────────────────────────────────────────────────────
for cmd in docker git yq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "[ERROR] Required command not found: $cmd"
    echo "        Install with: apt-get install -y $cmd  (or brew install $cmd on macOS)"
    exit 1
  fi
done

# ─── Parse zero.yaml ─────────────────────────────────────────────────────────
ZERO_YAML="${SCRIPT_DIR}/zero.yaml"
NODES_YAML="${SCRIPT_DIR}/nodes.yaml"

if [[ ! -f "$ZERO_YAML" ]]; then
  echo "[ERROR] zero.yaml not found at $ZERO_YAML"; exit 1
fi
if [[ ! -f "$NODES_YAML" ]]; then
  echo "[ERROR] nodes.yaml not found at $NODES_YAML"; exit 1
fi

echo "[INFO] Reading zero.yaml ..."

# Helper: resolve ${VAR} style references within values
resolve() {
  local val="$1"
  val="${val//\$\{PATH_BASE\}/$PATH_BASE}"
  val="${val//\$\{PATH_BUILD\}/$PATH_BUILD}"
  val="${val//\$\{PATH_NODES\}/$PATH_NODES}"
  val="${val//\$\{PATH_POOLS\}/$PATH_POOLS}"
  val="${val//\$\{PATH_CONFS\}/$PATH_CONFS}"
  echo "$val"
}

PATH_BASE=$(yq '.configs.PATH_BASE'     "$ZERO_YAML")
PATH_BUILD=$(resolve "$(yq '.configs.PATH_BUILD'  "$ZERO_YAML")")
PATH_NODES=$(resolve "$(yq '.configs.PATH_NODES'  "$ZERO_YAML")")
PATH_POOLS=$(resolve "$(yq '.configs.PATH_POOLS'  "$ZERO_YAML")")
PATH_CONFS=$(resolve "$(yq '.configs.PATH_CONFS'  "$ZERO_YAML")")
FILE_CONFS=$(yq '.configs.FILE_CONFS'   "$ZERO_YAML")
RPC_USER=$(yq   '.configs.RPC_USER'     "$ZERO_YAML")
RPC_PASS=$(yq   '.configs.RPC_PASS'     "$ZERO_YAML")
NODE_PRUNE=$(yq '.configs.NODE_PRUNE'   "$ZERO_YAML")
POOL_DIFF_LOW=$(yq '.configs.POOL_DIFF_LOW' "$ZERO_YAML")
POLL_DIFF_HGH=$(yq '.configs.POLL_DIFF_HGH' "$ZERO_YAML")

PORT_WEB=$(yq '.ports.web' "$ZERO_YAML")
PORT_LOW=$(yq '.ports.low' "$ZERO_YAML")
PORT_HGH=$(yq '.ports.hgh' "$ZERO_YAML")
PORT_RPC=$(yq '.ports.rpc' "$ZERO_YAML")
PORT_ZMQ=$(yq '.ports.zmq' "$ZERO_YAML")
PORT_P2P=$(yq '.ports.p2p' "$ZERO_YAML")

echo "[INFO] PATH_BASE  = $PATH_BASE"
echo "[INFO] PATH_BUILD = $PATH_BUILD"
echo "[INFO] PATH_POOLS = $PATH_POOLS"

# ─── Get local Docker host IP ─────────────────────────────────────────────────
echo "[INFO] Detecting local Docker host IP ..."
DOCKER_HOST_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')
if [[ -z "$DOCKER_HOST_IP" ]]; then
  DOCKER_HOST_IP=$(hostname -I | awk '{print $1}')
fi
if [[ -z "$DOCKER_HOST_IP" ]]; then
  echo "[WARN] Could not detect host IP automatically; defaulting to 127.0.0.1"
  DOCKER_HOST_IP="127.0.0.1"
fi
echo "[INFO] Docker host IP: $DOCKER_HOST_IP"

# ─── Build ckpool ─────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════"
echo " Building ckpool"
echo "═══════════════════════════════════════════════════"

mkdir -p "$PATH_BUILD"

CKPOOL_BUILD_DIR="${PATH_BUILD}/ckpool"
CKPOOL_DEST="${PATH_BASE}/ckpool"

if [[ -d "$CKPOOL_BUILD_DIR" ]]; then
  echo "[INFO] Removing stale ckpool build dir ..."
  rm -rf "$CKPOOL_BUILD_DIR"
fi

echo "[INFO] Cloning latest ckpool ..."
git clone --depth=1 https://bitbucket.org/ckolivas/ckpool.git "$CKPOOL_BUILD_DIR"

echo "[INFO] Building ckpool ..."
cd "$CKPOOL_BUILD_DIR"
autoreconf -fi
./configure --prefix="$CKPOOL_BUILD_DIR/install"
make -j"$(nproc)"
make install
cd "$SCRIPT_DIR"

echo "[INFO] Installing ckpool binaries to $CKPOOL_DEST ..."
mkdir -p "$CKPOOL_DEST"
for binary in ckpool ckpmsg notifier; do
  BIN_PATH=$(find "$CKPOOL_BUILD_DIR/install" -name "$binary" -type f 2>/dev/null | head -1)
  if [[ -n "$BIN_PATH" ]]; then
    cp -v "$BIN_PATH" "$CKPOOL_DEST/"
    chmod +x "$CKPOOL_DEST/$binary"
  else
    echo "[WARN] Binary not found after build: $binary"
  fi
done

echo "[INFO] Removing ckpool build directory ..."
rm -rf "$CKPOOL_BUILD_DIR"

# ─── Build ckwebui base ───────────────────────────────────────────────────────
CKWEBUI_SRC="${PATH_POOLS}/.ckwebui"
CKWEBUI_DEST="${PATH_BASE}/ckwebui"

echo ""
echo "═══════════════════════════════════════════════════"
echo " Setting up ckwebui"
echo "═══════════════════════════════════════════════════"

mkdir -p "$CKWEBUI_SRC"
mkdir -p "$CKWEBUI_DEST"

# Copy the website base files if they exist
if [[ -d "$CKWEBUI_SRC" ]]; then
  echo "[INFO] Copying ckwebui base files to $CKWEBUI_DEST ..."
  cp -rT "$CKWEBUI_SRC" "$CKWEBUI_DEST"
else
  echo "[WARN] $CKWEBUI_SRC does not exist yet; skipping copy"
fi

# ─── Process each node ───────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════"
echo " Processing nodes"
echo "═══════════════════════════════════════════════════"

NODE_COUNT=$(yq '.nodes | length' "$NODES_YAML")

for (( i=0; i<NODE_COUNT; i++ )); do
  NODE_INIT=$(yq ".nodes[$i].init"   "$NODES_YAML")
  NODE_ID=$(yq   ".nodes[$i].id"     "$NODES_YAML")
  NODE_KEY=$(yq  ".nodes[$i].node"   "$NODES_YAML")   # e.g. BTC
  NODE_NAME=$(yq ".nodes[$i].name"   "$NODES_YAML")   # e.g. Bitcoin
  NODE_ALGO=$(yq ".nodes[$i].algo"   "$NODES_YAML")
  NODE_BASE=$(yq ".nodes[$i].base"   "$NODES_YAML")
  NODE_REPO=$(yq ".nodes[$i].repo"   "$NODES_YAML")
  NODE_SITE=$(yq ".nodes[$i].site"   "$NODES_YAML")
  NODE_DAEMON=$(yq ".nodes[$i].daemon" "$NODES_YAML" 2>/dev/null || echo "")
  NODE_CLI=$(yq   ".nodes[$i].cliexe" "$NODES_YAML" 2>/dev/null || echo "")

  # Skip unless init is Pool or NodePool
  if [[ "$NODE_INIT" != "Pool" && "$NODE_INIT" != "NodePool" ]]; then
    echo "[SKIP] ${NODE_KEY} (init=$NODE_INIT)"
    continue
  fi

  echo ""
  echo "─── Processing: ${NODE_KEY} (${NODE_NAME}) id=${NODE_ID} ───"

  # Naming conventions
  NODE_UPPER="${NODE_KEY^^}"        # BTC
  NODE_LOWER="${NODE_KEY,,}"        # btc
  IMAGE_NODE="node-${NODE_LOWER}"  # node-btc
  IMAGE_POOL="pool-${NODE_LOWER}"  # pool-btc
  POOL_DIR="${PATH_POOLS}/${NODE_UPPER}"  # /zero/.pools/BTC

  mkdir -p "$POOL_DIR"

  # Port offsets: add node ID to each base port
  P_WEB=$(( PORT_WEB + NODE_ID ))
  P_LOW=$(( PORT_LOW + NODE_ID ))
  P_HGH=$(( PORT_HGH + NODE_ID ))
  P_RPC=$(( PORT_RPC + NODE_ID ))
  P_ZMQ=$(( PORT_ZMQ + NODE_ID ))
  P_P2P=$(( PORT_P2P + NODE_ID ))

  echo "[INFO]  Ports -> web:${P_WEB} low:${P_LOW} hgh:${P_HGH} rpc:${P_RPC} zmq:${P_ZMQ} p2p:${P_P2P}"

  # ── Determine daemon / cli names ─────────────────────────────────────────
  if [[ -z "$NODE_DAEMON" || "$NODE_DAEMON" == "null" ]]; then
    NODE_DAEMON="${NODE_BASE}d"
  fi
  if [[ -z "$NODE_CLI" || "$NODE_CLI" == "null" ]]; then
    NODE_CLI="${NODE_BASE}-cli"
  fi

  # ── ckpool config (ckpool.conf) ───────────────────────────────────────────
  CKPOOL_CONF="${POOL_DIR}/ckpool.conf"
  cat > "$CKPOOL_CONF" <<CONF
{
  "btcd" : [
    {
      "url"  : "${DOCKER_HOST_IP}:${P_RPC}",
      "auth" : "${RPC_USER}",
      "pass" : "${RPC_PASS}",
      "notify" : true
    }
  ],
  "zmqblock" : "tcp://${DOCKER_HOST_IP}:${P_ZMQ}",
  "logdir"   : "/ckpool/logs",
  "blockpoll": 500,
  "nonce1length" : 4,
  "nonce2length" : 8,
  "update_interval" : 30,
  "version_mask" : "1fffe000",
  "mindiff"  : ${POOL_DIFF_LOW},
  "startdiff": ${POOL_DIFF_LOW},
  "maxdiff"  : 0,
  "serverurl": [
    "${DOCKER_HOST_IP}:${P_LOW}",
    "${DOCKER_HOST_IP}:${P_HGH}"
  ],
  "pool_address" : "",
  "donation_percent" : 0
}
CONF
  echo "[INFO]  Written: $CKPOOL_CONF"

  # ── ckwebui.yaml ─────────────────────────────────────────────────────────
  CKWEBUI_YAML="${CKWEBUI_DEST}/ckwebui.yaml"
  # Append/overwrite node section
  cat >> "$CKWEBUI_YAML" <<YML

# --- ${NODE_UPPER} ---
- node: "${NODE_UPPER}"
  name: "${NODE_NAME}"
  algo: "${NODE_ALGO}"
  host: "${DOCKER_HOST_IP}"
  port_web: ${P_WEB}
  port_low: ${P_LOW}
  port_hgh: ${P_HGH}
  port_rpc: ${P_RPC}
  diff_low: ${POOL_DIFF_LOW}
  diff_hgh: ${POLL_DIFF_HGH}
  rpc_user: "${RPC_USER}"
  rpc_pass: "${RPC_PASS}"
  image_node: "${IMAGE_NODE}"
  image_pool: "${IMAGE_POOL}"
  blocks_file: "${CKWEBUI_DEST}/blocks-${NODE_LOWER}.yaml"
YML
  echo "[INFO]  Updated: $CKWEBUI_YAML"

  # ── Dockerfile ───────────────────────────────────────────────────────────
  DOCKERFILE="${POOL_DIR}/Dockerfile"
  cat > "$DOCKERFILE" <<DOCKERFILE
# =============================================================================
# Zero Mining - Pool Container: ${IMAGE_POOL}
# Node: ${NODE_UPPER} (${NODE_NAME})  |  Algo: ${NODE_ALGO}
# Generated by zeromining-setup
# =============================================================================

FROM ubuntu:22.04

LABEL maintainer="Zero Mining"
LABEL node="${NODE_UPPER}"
LABEL pool="${IMAGE_POOL}"

ENV DEBIAN_FRONTEND=noninteractive
ENV NODE_KEY="${NODE_UPPER}"
ENV NODE_NAME="${NODE_NAME}"
ENV NODE_ALGO="${NODE_ALGO}"
ENV RPC_HOST="${DOCKER_HOST_IP}"
ENV RPC_PORT="${P_RPC}"
ENV RPC_USER="${RPC_USER}"
ENV RPC_PASS="${RPC_PASS}"
ENV ZMQ_PORT="${P_ZMQ}"
ENV PORT_LOW="${P_LOW}"
ENV PORT_HGH="${P_HGH}"
ENV PORT_WEB="${P_WEB}"
ENV DIFF_LOW="${POOL_DIFF_LOW}"
ENV DIFF_HGH="${POLL_DIFF_HGH}"

# ─── System packages ──────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    libzmq3-dev \
    nodejs \
    npm \
    && rm -rf /var/lib/apt/lists/*

# ─── ckpool binaries ─────────────────────────────────────────────────────────
COPY ckpool/ckpool   /usr/local/bin/ckpool
COPY ckpool/ckpmsg   /usr/local/bin/ckpmsg
COPY ckpool/notifier /usr/local/bin/notifier
RUN chmod +x /usr/local/bin/ckpool /usr/local/bin/ckpmsg /usr/local/bin/notifier

# ─── Pool config ─────────────────────────────────────────────────────────────
RUN mkdir -p /ckpool/logs /ckpool/conf
COPY ${NODE_UPPER}/ckpool.conf /ckpool/conf/ckpool.conf

# ─── Web UI ───────────────────────────────────────────────────────────────────
COPY ckwebui /var/www/ckwebui
WORKDIR /var/www/ckwebui
RUN npm ci --omit=dev

# ─── Entrypoint ───────────────────────────────────────────────────────────────
COPY ${NODE_UPPER}/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE ${P_LOW} ${P_HGH} ${P_WEB}

ENTRYPOINT ["/entrypoint.sh"]
DOCKERFILE
  echo "[INFO]  Written: $DOCKERFILE"

  # ── entrypoint.sh ────────────────────────────────────────────────────────
  ENTRYPOINT_SH="${POOL_DIR}/entrypoint.sh"
  cat > "$ENTRYPOINT_SH" <<'ENTRY'
#!/bin/bash
set -e

echo "[Zero Mining] Starting ckpool for ${NODE_KEY} (${NODE_NAME}) ..."
/usr/local/bin/ckpool -c /ckpool/conf/ckpool.conf -B &

echo "[Zero Mining] Starting ckwebui ..."
cd /var/www/ckwebui
node server.js &

wait
ENTRY
  chmod +x "$ENTRYPOINT_SH"
  echo "[INFO]  Written: $ENTRYPOINT_SH"

  # ── docker-compose fragment ───────────────────────────────────────────────
  COMPOSE_FILE="${POOL_DIR}/docker-compose.yml"
  cat > "$COMPOSE_FILE" <<COMPOSE
# Zero Mining - ${NODE_UPPER} Pool
# Usage: docker compose up -d
version: "3.9"

services:

  ${IMAGE_POOL}:
    image: ${IMAGE_POOL}:latest
    container_name: ${IMAGE_POOL}
    build:
      context: ${PATH_BASE}
      dockerfile: ${POOL_DIR}/Dockerfile
    restart: unless-stopped
    network_mode: host          # shares host network so it can reach node-${NODE_LOWER}
    ports:
      - "${P_LOW}:${P_LOW}"
      - "${P_HGH}:${P_HGH}"
      - "${P_WEB}:${P_WEB}"
    volumes:
      - ${POOL_DIR}/logs:/ckpool/logs
      - ${CKWEBUI_DEST}/blocks-${NODE_LOWER}.yaml:/var/www/ckwebui/blocks-${NODE_LOWER}.yaml
    environment:
      NODE_KEY: "${NODE_UPPER}"
      NODE_NAME: "${NODE_NAME}"
      RPC_HOST: "${DOCKER_HOST_IP}"
      RPC_PORT: "${P_RPC}"
      RPC_USER: "${RPC_USER}"
      RPC_PASS: "${RPC_PASS}"
      ZMQ_PORT: "${P_ZMQ}"
      PORT_LOW: "${P_LOW}"
      PORT_HGH: "${P_HGH}"
      PORT_WEB: "${P_WEB}"
      DIFF_LOW: "${POOL_DIFF_LOW}"
      DIFF_HGH: "${POLL_DIFF_HGH}"
      HOST_IP:  "${DOCKER_HOST_IP}"
COMPOSE
  echo "[INFO]  Written: $COMPOSE_FILE"

  echo "[OK]  ${NODE_UPPER} pool setup complete -> $POOL_DIR"
done

# ─── Final summary ────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════"
echo " Zero Mining Setup Complete"
echo "═══════════════════════════════════════════════════"
echo " ckpool binaries : $CKPOOL_DEST"
echo " ckwebui base    : $CKWEBUI_DEST"
echo " Pool configs    : $PATH_POOLS/<NODE>/"
echo ""
echo " To build & start a pool container (example - BTC):"
echo "   cd ${PATH_POOLS}/BTC && docker compose up -d --build"
echo ""
