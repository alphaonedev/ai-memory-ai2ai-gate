#!/usr/bin/env bash
# Copyright 2026 AlphaOne LLC
# SPDX-License-Identifier: Apache-2.0
#
# Provision node-4: the authoritative ai-memory serve instance that
# all three agents talk to. Single-node serve, no federation — the
# a2a-gate's first-campaign shape is a central store, not a mesh.
# (Scenario 4 spins up a per-agent local replica for the federation-
# aware test; that's handled inside the scenario script.)

set -euo pipefail

: "${AI_MEMORY_VERSION:=0.6.0}"

log() { printf '[setup] %s\n' "$*" >&2; }

log "installing base packages"
cloud-init status --wait 2>/dev/null || true
DEBIAN_FRONTEND=noninteractive apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y curl jq sqlite3

# OS-tier firewall off — DO Cloud Firewall is the boundary.
if command -v ufw >/dev/null 2>&1; then
  ufw --force disable || true
fi

# Dead-man switch.
shutdown -P +480 "ai-memory a2a-gate dead-man switch" & disown

log "installing ai-memory release v${AI_MEMORY_VERSION}"
cd /tmp
curl -sSL -o amem.tgz \
  "https://github.com/alphaonedev/ai-memory-mcp/releases/download/v${AI_MEMORY_VERSION}/ai-memory-x86_64-unknown-linux-gnu.tar.gz"
tar xzf amem.tgz
install -m 0755 ai-memory /usr/local/bin/ai-memory
ai-memory --version

# Serve on all interfaces — VPC firewall restricts to 10.260.0.0/24
# inbound; there's no production-sensitive data here, and the
# a2a-gate's scenarios run end-to-end in under 20 minutes per
# campaign.
mkdir -p /var/lib/ai-memory
nohup ai-memory serve \
  --host 0.0.0.0 --port 9077 \
  --db /var/lib/ai-memory/a2a.db \
  > /var/log/ai-memory-serve.log 2>&1 &
disown

# Health-check with a 30s window.
for attempt in $(seq 1 30); do
  if curl -sSf http://127.0.0.1:9077/api/v1/health 2>/dev/null | grep -q '"ok"'; then
    log "memory node ready on :9077"
    exit 0
  fi
  sleep 1
done

log "memory node FAILED to come up in 30s — see /var/log/ai-memory-serve.log"
tail -n 40 /var/log/ai-memory-serve.log >&2 || true
exit 1
