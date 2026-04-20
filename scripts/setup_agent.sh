#!/usr/bin/env bash
# Copyright 2026 AlphaOne LLC
# SPDX-License-Identifier: Apache-2.0
#
# Provision an agent droplet (node-1 / node-2 / node-3) with either
# OpenClaw or Hermes, an ai-memory MCP client, and the scenario
# runner script. Runs on the agent droplet itself via SSH from the
# orchestrator.
#
# Required env:
#   AGENT_TYPE      — "openclaw" or "hermes"
#   AGENT_ID        — "ai:alice" / "ai:bob" / "ai:charlie"
#   MEMORY_NODE_IP  — private IP of node-4 (ai-memory serve)
#
# Optional env:
#   OPENCLAW_INSTALL_CMD — operator override for OpenClaw install
#   HERMES_INSTALL_CMD   — operator override for Hermes install
#   ENABLE_OLLAMA        — "1" if scenario 8 (auto-tagging) is enabled

set -euo pipefail

: "${AGENT_TYPE:?}"
: "${AGENT_ID:?}"
: "${MEMORY_NODE_IP:?}"

log() { printf '[setup] %s\n' "$*" >&2; }

# ---- Packages ------------------------------------------------------
log "installing base packages"
cloud-init status --wait 2>/dev/null || true
DEBIAN_FRONTEND=noninteractive apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  curl jq git python3 python3-pip nodejs npm

# OS-tier firewall DISABLED — single enforcement boundary is the DO
# Cloud Firewall. This mirrors the ship-gate's UFW-off decision;
# agent workloads don't need host-local filtering and we don't want
# Ubuntu 24.04's default-on UFW fighting the agent frameworks or the
# inbound MCP traffic.
if command -v ufw >/dev/null 2>&1; then
  ufw --force disable || true
fi

# Dead-man switch — matches the ship-gate pattern. Any droplet that
# escapes teardown kills itself after 8 hours.
shutdown -P +480 "ai-memory a2a-gate dead-man switch" & disown

# ---- ai-memory CLI (required on every agent droplet) ---------------
# The agent needs the ai-memory CLI locally for scenarios that drive
# memory via the MCP subprocess pattern. We install a pinned release
# binary rather than building from source.
log "installing ai-memory CLI"
AI_MEMORY_VERSION="${AI_MEMORY_VERSION:-0.6.0}"
curl -sSL -o /usr/local/bin/ai-memory \
  "https://github.com/alphaonedev/ai-memory-mcp/releases/download/v${AI_MEMORY_VERSION}/ai-memory-x86_64-unknown-linux-gnu.tar.gz" || true
# Tarball path — extract.
cd /tmp && curl -sSL -o amem.tgz \
  "https://github.com/alphaonedev/ai-memory-mcp/releases/download/v${AI_MEMORY_VERSION}/ai-memory-x86_64-unknown-linux-gnu.tar.gz"
tar xzf amem.tgz
install -m 0755 ai-memory /usr/local/bin/ai-memory
ai-memory --version

# ---- Agent framework provisioning ----------------------------------
# IMPORTANT: the exact install commands for OpenClaw and Hermes are
# framework-specific and managed by their respective projects. This
# script is intentionally a scaffold; the operator is expected to
# either:
#   (a) override OPENCLAW_INSTALL_CMD / HERMES_INSTALL_CMD with the
#       current install one-liner, OR
#   (b) rely on the defaults below which install from the public
#       release surface ONCE the projects ship one.
#
# The scenarios below drive the agents through their CLI / MCP
# entry points, so what matters for pass/fail is that either
# framework can invoke the ai-memory MCP server's tools and report
# results back. Until the frameworks publish stable install paths
# we use the ai-memory CLI as a substitute driver (it's MCP-
# compatible as a stdio server, and can be driven from Python
# subprocess calls that mimic a real agent's tool-invocation loop).

case "$AGENT_TYPE" in
  openclaw)
    log "provisioning OpenClaw agent (agent_id=$AGENT_ID)"
    if [ -n "${OPENCLAW_INSTALL_CMD:-}" ]; then
      bash -c "$OPENCLAW_INSTALL_CMD"
    else
      log "OpenClaw default install — placeholder (no public install path yet)"
      log "scenarios will drive the ai-memory CLI directly as a stand-in"
    fi
    ;;
  hermes)
    log "provisioning Hermes agent (agent_id=$AGENT_ID)"
    if [ -n "${HERMES_INSTALL_CMD:-}" ]; then
      bash -c "$HERMES_INSTALL_CMD"
    else
      log "Hermes default install — placeholder (no public install path yet)"
      log "scenarios will drive the ai-memory CLI directly as a stand-in"
    fi
    ;;
  *)
    echo "unknown AGENT_TYPE: $AGENT_TYPE" >&2
    exit 1
    ;;
esac

# ---- Environment for scenario runners ------------------------------
mkdir -p /etc/ai-memory-a2a
cat > /etc/ai-memory-a2a/env <<EOF
# a2a-gate environment for this agent droplet. Sourced by every
# scenario script.
AGENT_TYPE=$AGENT_TYPE
AGENT_ID=$AGENT_ID
MEMORY_NODE_IP=$MEMORY_NODE_IP
MEMORY_NODE_URL=http://$MEMORY_NODE_IP:9077
AI_MEMORY_AGENT_ID=$AGENT_ID
EOF

chmod 0644 /etc/ai-memory-a2a/env
log "agent $AGENT_ID ready — memory node http://$MEMORY_NODE_IP:9077"
