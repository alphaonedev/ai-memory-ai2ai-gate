#!/usr/bin/env bash
# Copyright 2026 AlphaOne LLC
# SPDX-License-Identifier: Apache-2.0
#
# Provision a single a2a-gate node.
#
# Every node in the 4-node VPC runs `ai-memory serve` in federation-
# mesh mode. W=2 of N=4 quorum: every write must ack on the leader
# plus one other peer before returning 201, with the remaining peers
# catching up via the post-quorum fanout that PR #309 fixed.
#
# Nodes 1, 2, 3 ADDITIONALLY layer an agent framework (OpenClaw or
# Hermes) on top and configure its MCP client to talk to the LOCAL
# ai-memory serve. Node 4 is memory-only (no agent) — it participates
# in quorum but doesn't host an agent; it's the "aggregator" query
# target for scenarios that want to inspect the cross-cluster state
# without going through an agent.
#
# Required env:
#   NODE_INDEX    — 1, 2, 3, or 4
#   PEER_URLS     — comma-separated http://<private-ip>:9077 for the
#                   other 3 peers (W=2 of N=4)
#   ROLE          — "agent" or "memory-only"
#
# Agent-only env (when ROLE=agent):
#   AGENT_TYPE    — "openclaw" or "hermes"
#   AGENT_ID      — "ai:alice" / "ai:bob" / "ai:charlie"
#
# Optional env:
#   AI_MEMORY_VERSION       — default 0.6.0
#   OPENCLAW_INSTALL_CMD    — operator-supplied install one-liner
#   HERMES_INSTALL_CMD      — operator-supplied install one-liner

set -euo pipefail

: "${NODE_INDEX:?}"
: "${PEER_URLS:?}"
: "${ROLE:?}"
: "${AI_MEMORY_VERSION:=0.6.0}"

log() { printf '[setup-node-%s] %s\n' "$NODE_INDEX" "$*" >&2; }

# ---- Base packages -------------------------------------------------
log "installing base packages"
cloud-init status --wait 2>/dev/null || true
DEBIAN_FRONTEND=noninteractive apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  curl jq git python3 python3-pip nodejs npm sqlite3

# OS-tier firewall off (ship-gate lesson from r21/r23 hangs).
if command -v ufw >/dev/null 2>&1; then
  ufw --force disable || true
fi

# Dead-man switch: every droplet self-destructs at 8h regardless.
shutdown -P +480 "ai-memory a2a-gate dead-man switch" & disown

# ---- ai-memory install + serve with federation --------------------
log "installing ai-memory v${AI_MEMORY_VERSION}"
cd /tmp
curl -sSL -o amem.tgz \
  "https://github.com/alphaonedev/ai-memory-mcp/releases/download/v${AI_MEMORY_VERSION}/ai-memory-x86_64-unknown-linux-gnu.tar.gz"
tar xzf amem.tgz
install -m 0755 ai-memory /usr/local/bin/ai-memory
ai-memory --version

mkdir -p /var/lib/ai-memory /etc/ai-memory-a2a

# Federation config: W=2 of N=4. Peer URLs passed as comma-separated.
log "starting ai-memory serve with federation peers: $PEER_URLS"
nohup ai-memory serve \
  --host 0.0.0.0 --port 9077 \
  --db /var/lib/ai-memory/a2a.db \
  --quorum-writes 2 \
  --quorum-peers "$PEER_URLS" \
  > /var/log/ai-memory-serve.log 2>&1 &
disown

# Health-check the local serve.
for attempt in $(seq 1 30); do
  if curl -sSf http://127.0.0.1:9077/api/v1/health 2>/dev/null | grep -q '"ok"'; then
    log "ai-memory serve ready on :9077"
    break
  fi
  sleep 1
done
curl -sSf http://127.0.0.1:9077/api/v1/health | grep -q '"ok"' || {
  log "ai-memory serve FAILED to come up — see /var/log/ai-memory-serve.log"
  tail -n 40 /var/log/ai-memory-serve.log >&2
  exit 1
}

# ---- If memory-only, stop here ------------------------------------
if [ "$ROLE" = "memory-only" ]; then
  log "node $NODE_INDEX is memory-only — no agent framework installed"
  cat > /etc/ai-memory-a2a/env <<EOF
NODE_INDEX=$NODE_INDEX
ROLE=memory-only
LOCAL_MEMORY_URL=http://127.0.0.1:9077
EOF
  exit 0
fi

# ---- Agent role: MCP-configure the agent with LOCAL ai-memory -----
: "${AGENT_TYPE:?}"
: "${AGENT_ID:?}"

log "this node is an agent droplet: type=$AGENT_TYPE agent_id=$AGENT_ID"

# MCP config directory — used by both OpenClaw and Hermes per their
# MCP-compatible config conventions. Shape matches Claude Desktop /
# other MCP clients: top-level "mcpServers" map, entries point at
# command + args that start an MCP stdio server.
#
# For our case, the MCP server is the ai-memory binary in `mcp` mode,
# which speaks stdio JSON-RPC 2.0. Agents invoke `ai-memory mcp`
# which in turn talks to the local HTTP API on 127.0.0.1:9077 via
# MCP tool dispatchers.
#
# By pointing each agent at its LOCAL ai-memory, writes go through
# the federation quorum (because serve has --quorum-peers configured
# on this node), so a write from agent alice on node-1 lands on
# node-1 + one quorum peer synchronously + the other two nodes via
# post-quorum fanout. Reads on any node see the cluster state.
mkdir -p /etc/ai-memory-a2a/mcp-config
cat > /etc/ai-memory-a2a/mcp-config/config.json <<EOF
{
  "mcpServers": {
    "memory": {
      "command": "ai-memory",
      "args": ["--db", "/var/lib/ai-memory/a2a.db", "mcp"],
      "env": {
        "AI_MEMORY_AGENT_ID": "$AGENT_ID"
      }
    }
  }
}
EOF
log "MCP config written: /etc/ai-memory-a2a/mcp-config/config.json"

# ---- Agent framework install --------------------------------------
# Both OpenClaw and Hermes groups use the same underlying runtime:
# the `grok` CLI (alphaonedev/grok-cli, published binary) backed by
# xAI Grok. They differ only by agent_id and the symlink name the
# scenario driver invokes, so framework-independence is tested via
# distinct driver paths + distinct identities rather than two
# fully separate frameworks (matches how OpenClaw on the operator
# workstation is set up: grok-CLI + xAI key + ai-memory MCP).

: "${XAI_API_KEY:?XAI_API_KEY required on agent nodes}"

log "installing grok CLI (grok-dev@1.6.0)"
curl -fsSL -o /usr/local/bin/grok \
  "https://github.com/alphaonedev/grok-cli/releases/download/grok-dev%401.6.0/grok-linux-x64"
chmod +x /usr/local/bin/grok
/usr/local/bin/grok --version || { log "grok --version failed"; exit 1; }

# Driver-name symlinks: drive_agent.sh checks `command -v openclaw`
# or `command -v hermes` to pick the path. Both point at the same
# grok binary — the distinction is agent_id + campaign_id.
ln -sf /usr/local/bin/grok "/usr/local/bin/${AGENT_TYPE}"
log "symlinked /usr/local/bin/${AGENT_TYPE} -> grok"

# Grok user settings: xAI key + ai-memory as the sole MCP server,
# stamped with AGENT_ID via env so every memory_store/memory_recall
# carries the writer's identity (Task 1.2 immutability contract).
mkdir -p /root/.grok
cat > /root/.grok/user-settings.json <<EOF
{
  "apiKey": "${XAI_API_KEY}",
  "baseURL": "https://api.x.ai/v1",
  "defaultModel": "grok-4-fast-non-reasoning",
  "settingsVersion": 2,
  "mcp": {
    "servers": [
      {
        "id": "ai-memory",
        "label": "AI Memory",
        "enabled": true,
        "transport": "stdio",
        "command": "ai-memory",
        "args": ["--db", "/var/lib/ai-memory/a2a.db", "mcp"],
        "env": {
          "AI_MEMORY_AGENT_ID": "${AGENT_ID}"
        }
      }
    ]
  }
}
EOF
chmod 600 /root/.grok/user-settings.json
log "grok configured with xAI key + ai-memory MCP (stdio, agent_id=${AGENT_ID})"

# ---- Drop the per-scenario environment file -----------------------
cat > /etc/ai-memory-a2a/env <<EOF
NODE_INDEX=$NODE_INDEX
ROLE=agent
AGENT_TYPE=$AGENT_TYPE
AGENT_ID=$AGENT_ID
LOCAL_MEMORY_URL=http://127.0.0.1:9077
MCP_CONFIG=/etc/ai-memory-a2a/mcp-config/config.json
AI_MEMORY_AGENT_ID=$AGENT_ID
EOF

chmod 0644 /etc/ai-memory-a2a/env
log "agent $AGENT_ID provisioned with MCP config pointing at local ai-memory federation peer"
