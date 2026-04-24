#!/usr/bin/env bash
# Copyright 2026 AlphaOne LLC
# SPDX-License-Identifier: Apache-2.0
#
# Container startup — mirrors the role/config plumbing that
# scripts/setup_node.sh does for DO droplets, minus the OS-level
# firewall / swap / MiniLM pre-download (those are host concerns
# inappropriate inside a container).
#
# Required env:
#   NODE_INDEX    — 1, 2, 3, or 4
#   ROLE          — "agent" or "memory-only"
#   PEER_URLS     — comma-separated http://node-<i>:9077 for the other 3 peers
#
# Agent-only env (when ROLE=agent):
#   AGENT_TYPE    — "openclaw" or (future) "ironclaw" / "hermes"
#   AGENT_ID      — "ai:alice" / "ai:bob" / "ai:charlie"
#   XAI_API_KEY   — required when AGENT_TYPE=openclaw
#
# Optional:
#   TLS_MODE              — off | tls | mtls (default off)
#   A2A_GATE_LLM_MODEL    — xAI Grok SKU (default grok-4-0709)
set -euo pipefail

: "${NODE_INDEX:?NODE_INDEX required}"
: "${ROLE:?ROLE required}"
: "${PEER_URLS:?PEER_URLS required}"
TLS_MODE="${TLS_MODE:-off}"
A2A_GATE_LLM_MODEL="${A2A_GATE_LLM_MODEL:-grok-4-0709}"

log() { printf '[node-%s %s] %s\n' "$NODE_INDEX" "$(date -u +%H:%M:%S)" "$*" >&2; }

log "container starting: role=$ROLE tls_mode=$TLS_MODE peers=$PEER_URLS"

# When TLS is enabled the federation mesh speaks https, not http.
# Rewrite the peer URL scheme here so a single compose file serves
# all three tls modes by only changing the TLS_MODE env.
if [ "$TLS_MODE" != "off" ] && [ -n "${PEER_URLS:-}" ]; then
  PEER_URLS=$(printf '%s' "$PEER_URLS" | sed 's|http://|https://|g')
  export PEER_URLS
  log "PEER_URLS rewritten for $TLS_MODE: $PEER_URLS"
fi

# Assemble ai-memory serve args. TLS_MODE off/tls/mtls all supported;
# TLS material for non-off modes is expected at /etc/ai-memory-a2a/tls/
# via bind-mount from docker/tls/node-$NODE_INDEX/ (produced by
# docker/gen-tls.sh). Matches setup_node.sh line-for-line.
SERVE_ARGS=(
  --host 0.0.0.0 --port 9077
  --db /var/lib/ai-memory/a2a.db
  --quorum-writes 2
  --quorum-peers "$PEER_URLS"
)

SERVE_SCHEME="http"
LOCAL_CURL_FLAGS=()
if [ "$TLS_MODE" != "off" ]; then
  SERVE_SCHEME="https"
  TLS_CERT=/etc/ai-memory-a2a/tls/server.pem
  TLS_KEY=/etc/ai-memory-a2a/tls/server.key
  TLS_CA=/etc/ai-memory-a2a/tls/ca.pem
  TLS_ALLOWLIST=/etc/ai-memory-a2a/tls/allowlist.txt
  TLS_CLIENT_CERT=/etc/ai-memory-a2a/tls/client.pem
  TLS_CLIENT_KEY=/etc/ai-memory-a2a/tls/client.key
  for required in "$TLS_CERT" "$TLS_KEY" "$TLS_CA"; do
    [ -f "$required" ] || { log "FATAL: TLS_MODE=$TLS_MODE but $required missing (bind-mount docker/tls/node-$NODE_INDEX)"; exit 1; }
  done
  SERVE_ARGS+=(--tls-cert "$TLS_CERT" --tls-key "$TLS_KEY"
               --quorum-client-cert "$TLS_CERT" --quorum-client-key "$TLS_KEY"
               --quorum-ca-cert "$TLS_CA")
  LOCAL_CURL_FLAGS=(--cacert "$TLS_CA" --resolve "localhost:9077:127.0.0.1")
  if [ "$TLS_MODE" = "mtls" ]; then
    [ -f "$TLS_ALLOWLIST" ] || { log "FATAL: TLS_MODE=mtls but $TLS_ALLOWLIST missing"; exit 1; }
    SERVE_ARGS+=(--mtls-allowlist "$TLS_ALLOWLIST")
    LOCAL_CURL_FLAGS+=(--cert "$TLS_CLIENT_CERT" --key "$TLS_CLIENT_KEY")
  fi
  log "TLS staged: cert=$TLS_CERT ca=$TLS_CA mtls=$([ "$TLS_MODE" = mtls ] && echo yes || echo no)"
fi

# Start ai-memory serve in the background. The container's PID 1 is
# the agent framework (or a sleep loop for memory-only nodes); the
# memory daemon runs as a child so its logs land in the container's
# stdout via the tee below.
log "starting ai-memory serve on :9077 scheme=$SERVE_SCHEME"
ai-memory serve "${SERVE_ARGS[@]}" > /var/log/ai-memory-serve.log 2>&1 &
SERVE_PID=$!

# Health wait — match setup_node.sh's 60-attempt / 1s pattern.
LOCAL_HEALTH_URL="${SERVE_SCHEME}://127.0.0.1:9077/api/v1/health"
[ "$TLS_MODE" != "off" ] && LOCAL_HEALTH_URL="${SERVE_SCHEME}://localhost:9077/api/v1/health"
for attempt in $(seq 1 60); do
  if curl -sSf "${LOCAL_CURL_FLAGS[@]}" "$LOCAL_HEALTH_URL" 2>/dev/null | grep -q '"ok"'; then
    log "ai-memory serve ready on :9077 (scheme=$SERVE_SCHEME attempt=$attempt)"
    break
  fi
  if ! kill -0 "$SERVE_PID" 2>/dev/null; then
    log "FATAL: ai-memory serve died before health check passed"
    tail -n 50 /var/log/ai-memory-serve.log >&2
    exit 1
  fi
  sleep 1
done
curl -sSf "${LOCAL_CURL_FLAGS[@]}" "$LOCAL_HEALTH_URL" 2>/dev/null | grep -q '"ok"' || {
  log "FATAL: ai-memory serve never came up (scheme=$SERVE_SCHEME)"
  tail -n 50 /var/log/ai-memory-serve.log >&2
  exit 1
}

tail -n +1 -F /var/log/ai-memory-serve.log &

if [ "$ROLE" = "memory-only" ]; then
  log "memory-only node — no agent framework; waiting on serve PID=$SERVE_PID"
  wait "$SERVE_PID"
  exit $?
fi

: "${AGENT_TYPE:?AGENT_TYPE required for ROLE=agent}"
: "${AGENT_ID:?AGENT_ID required for ROLE=agent}"

# MCP config — same shape as setup_node.sh:330-342 (Claude Desktop /
# MCP-compatible client contract). agent_id is baked into env so every
# write from this node's agent is attributable.
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
log "MCP config written"

# /etc/ai-memory-a2a/env — consumed by drive_agent.sh (and the S1 MCP
# path) on the agent node. Matches the DO setup_node.sh contract so the
# forked harness can run drive_agent-based scenarios unmodified.
# LOCAL_MEMORY_URL + TLS material paths vary by TLS_MODE. drive_agent.sh
# reads both and constructs the right curl invocation via its
# fallback_driver. Keep the paths canonical (matches setup_node.sh).
if [ "$TLS_MODE" = "off" ]; then
  LOCAL_MEMORY_URL="http://127.0.0.1:9077"
else
  LOCAL_MEMORY_URL="https://localhost:9077"
fi
cat > /etc/ai-memory-a2a/env <<EOF
NODE_INDEX=$NODE_INDEX
ROLE=$ROLE
AGENT_TYPE=${AGENT_TYPE:-}
AGENT_ID=${AGENT_ID:-}
TLS_MODE=$TLS_MODE
PEER_URLS=$PEER_URLS
LOCAL_MEMORY_URL=$LOCAL_MEMORY_URL
TLS_CA=/etc/ai-memory-a2a/tls/ca.pem
TLS_CLIENT_CERT=/etc/ai-memory-a2a/tls/client.pem
TLS_CLIENT_KEY=/etc/ai-memory-a2a/tls/client.key
MCP_CONFIG=/etc/ai-memory-a2a/mcp-config/config.json
A2A_GATE_LLM_MODEL=${A2A_GATE_LLM_MODEL}
XAI_API_KEY=${XAI_API_KEY:-}
EOF
log "/etc/ai-memory-a2a/env written"

case "$AGENT_TYPE" in
  openclaw)
    : "${XAI_API_KEY:?XAI_API_KEY required for openclaw agents}"
    mkdir -p /root/.openclaw
    # Same thesis-integrity config as DO — every A2A channel off
    # except ai-memory-via-MCP.
    cat > /root/.openclaw/openclaw.json <<EOF
{
  "providers": {
    "xai": {
      "type": "openai-compatible",
      "api_key": "${XAI_API_KEY}",
      "base_url": "https://api.x.ai/v1",
      "default_model": "${A2A_GATE_LLM_MODEL}"
    }
  },
  "defaultProvider": "xai",
  "mcpServers": {
    "memory": {
      "command": "ai-memory",
      "args": ["--db", "/var/lib/ai-memory/a2a.db", "mcp", "--tier", "semantic"],
      "env": {
        "AI_MEMORY_AGENT_ID": "${AGENT_ID}"
      }
    }
  },
  "agentToAgent": false,
  "toolAllowlist": [
    "memory_store", "memory_recall", "memory_list", "memory_get",
    "memory_share", "memory_link", "memory_update",
    "memory_detect_contradiction", "memory_consolidate"
  ],
  "channels": {
    "telegram": { "enabled": false },
    "discord":  { "enabled": false },
    "slack":    { "enabled": false },
    "moltbook": { "enabled": false }
  },
  "gateway": { "mode": "local" },
  "nodeHosts": [],
  "remoteMode": { "enabled": false },
  "subAgent": { "enabled": false },
  "agentTeams": { "enabled": false },
  "sharedServices": {
    "postgres": { "enabled": false },
    "redis":    { "enabled": false },
    "supabase": { "enabled": false }
  },
  "a2aGateProfile": "shared-memory-only",
  "a2aGateProfileVersion": "1.0.0"
}
EOF
    chmod 600 /root/.openclaw/openclaw.json
    openclaw mcp set memory "$(jq -c '.mcpServers.memory' /root/.openclaw/openclaw.json)" 2>/dev/null || \
      log "openclaw mcp set returned non-zero (likely already registered via config file)"
    log "openclaw configured with agent_id=$AGENT_ID"
    ;;
  *)
    log "FATAL: AGENT_TYPE=$AGENT_TYPE not yet supported in local-docker topology"
    exit 2
    ;;
esac

# Stay up with ai-memory serve as the long-lived process. Agent
# framework commands are driven via `docker exec` by the harness.
log "agent node ready — idling on ai-memory serve PID=$SERVE_PID"
wait "$SERVE_PID"
