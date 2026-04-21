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
#   AGENT_TYPE    — "ironclaw" or "hermes" ("openclaw" legacy, being retired)
#   AGENT_ID      — "ai:alice" / "ai:bob" / "ai:charlie"
#
# Optional env:
#   AI_MEMORY_VERSION       — default 0.6.0
#   IRONCLAW_INSTALL_CMD    — operator-supplied install one-liner
#   OPENCLAW_INSTALL_CMD    — operator-supplied install one-liner
#   HERMES_INSTALL_CMD      — operator-supplied install one-liner

set -euo pipefail

# Diagnostic trap — prints the failing line + command when any step
# exits non-zero under set -e. Makes hangs/failures localizable from
# the GitHub Actions log alone.
trap 'rc=$?; echo "[setup-node-${NODE_INDEX:-?}] FAILED at line ${LINENO}: ${BASH_COMMAND} (exit $rc)" >&2' ERR

: "${NODE_INDEX:?}"
: "${PEER_URLS:?}"
: "${ROLE:?}"
: "${AI_MEMORY_VERSION:=0.6.0}"
# v0.6.0.1 (#4) — LLM under test, parameterized so the harness can target
# different Grok SKUs without code changes. Default is grok-4-0709 (the
# current "Grok 4.2 reasoning" SKU at https://x.ai/api/models). Override
# via workflow_dispatch input or env for cost-optimized smoke runs, e.g.:
#   A2A_GATE_LLM_MODEL=grok-4-fast-non-reasoning
: "${A2A_GATE_LLM_MODEL:=grok-4-0709}"

log() { printf '[setup-node-%s %s] %s\n' "$NODE_INDEX" "$(date -u +%H:%M:%S)" "$*" >&2; }

# Bound every long-running subprocess so a hang on one node can't
# stall the whole provision step (previous r11 symptom: 37+ min with
# no progress — the GitHub Actions runner timeout was about to fire).
TIMEOUT_INSTALL_SH=600     # 10 min — openclaw install via curl | bash
TIMEOUT_NPM=300            # 5 min
TIMEOUT_PIP=180            # 3 min
TIMEOUT_AGENT_CLI=60       # 1 min — F2b canary (agent reasoning + tool call)
TIMEOUT_XAI_CURL=20        # 20s — F1 xAI chat probe (already enforced inline)

# ---- Base packages -------------------------------------------------
log "installing base packages"
cloud-init status --wait 2>/dev/null || true
DEBIAN_FRONTEND=noninteractive apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  curl jq git python3 python3-pip nodejs npm sqlite3

# OS-tier firewall OFF on every node. Ship-gate r21/r23 lesson:
# UFW on Ubuntu 24.04 default-on blocks loopback mesh traffic in
# subtle ways. Disable explicitly AND verify.
log "disabling UFW + verifying"
if command -v ufw >/dev/null 2>&1; then
  ufw --force disable 2>&1 | sed 's/^/[ufw] /' || true
  # Also reset to default-deny-nothing to be extra safe, then
  # re-disable (reset re-enables on some ufw builds).
  ufw --force reset 2>&1 | sed 's/^/[ufw] /' || true
  ufw --force disable 2>&1 | sed 's/^/[ufw] /' || true
  # Verify — hard fail the provision if UFW is still active on any
  # node (agent or memory-only). Non-negotiable per user directive
  # 2026-04-21: "make sure Ubuntu firewalls are disabled for all
  # testing."
  ufw_status=$(ufw status 2>&1 | head -1 || echo "ufw status failed")
  log "UFW status: $ufw_status"
  case "$ufw_status" in
    *inactive*|*disabled*)
      log "UFW confirmed disabled"
      ;;
    *)
      log "FATAL: UFW still active on node $NODE_INDEX — halting provision. ufw status: $ufw_status"
      exit 3
      ;;
  esac
else
  log "ufw not present on this image — nothing to disable"
fi
# Flush iptables too (belt-and-suspenders; Docker-prepped images
# sometimes have residual DROP policies that UFW doesn't manage).
if command -v iptables >/dev/null 2>&1; then
  iptables -P INPUT ACCEPT 2>/dev/null || true
  iptables -P OUTPUT ACCEPT 2>/dev/null || true
  iptables -P FORWARD ACCEPT 2>/dev/null || true
  iptables -F 2>/dev/null || true
  log "iptables policies set ACCEPT + rules flushed"
fi

# Dead-man switch: every droplet self-destructs at 8h regardless.
shutdown -P +480 "ai-memory a2a-gate dead-man switch" & disown

# Add a 2GB swap file — s-2vcpu-4gb droplets can OOM during agent
# framework installs (observed r12 openclaw npm install: 4min in,
# SSH connection dropped with exit 255, symptoms consistent with
# OOM-killer terminating sshd). Swap lets the install page out
# instead of dying. Only create if not already present.
if [ ! -f /swapfile ]; then
  log "creating 2GB swap file"
  fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 2>/dev/null
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null 2>&1
  swapon /swapfile
  swap_mb=$(free -m | awk '/^Swap/ {print $2}')
  log "swap enabled: ${swap_mb} MB"
fi

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
# Two groups, two agent runtimes. Both call xAI Grok as the LLM and
# both use ai-memory as their ONLY MCP server — so every memory
# operation flows through ai-memory with the writer's agent_id
# stamped in (Task 1.2 immutability contract from ai-memory-mcp).
#
#   openclaw → alphaonedev/grok-cli binary, ~/.grok/user-settings.json
#   hermes   → NousResearch/hermes-agent (pip/uv), ~/.hermes/config.yaml
#
# The MCP stdio config points at the SAME ai-memory binary on the
# same SQLite file on the same node — so results from the two
# campaigns are directly comparable: same substrate, different
# agent reasoning layer.

: "${XAI_API_KEY:?XAI_API_KEY required on agent nodes}"

case "$AGENT_TYPE" in
  openclaw)
    # OpenClaw is distributed via openclaw.ai/install.sh. The labels
    # shown in --version (like "2026.4.20") are git-commit tags, NOT
    # npm semvers — npm install -g openclaw@2026.4.20 fails with
    # ETARGET (r9 regression). Best available deterministic install:
    # use install.sh (which IS what openclaw ships) + capture the
    # actually-installed version into config_attestation.framework_version
    # so drift is visible on the dashboard even without a hard pin.
    #
    # install.sh exits 1 under non-TTY even when the binary installs
    # cleanly (post-install wizard fails). We tolerate the exit and
    # rely on the presence check; FATAL only if the binary truly
    # isn't installed.
    # HISTORY (r12-r14): `npm install -g openclaw` as primary hangs
    # 20+ min on s-2vcpu-4gb (OOM thrash through native deps). Swap
    # file helps the OS but doesn't stop npm wall time from being
    # unbounded. install.sh is the KNOWN-WORKING path (r7 completed
    # successfully then exit-1'd at wizard, which we tolerate).
    #
    # install.sh-PRIMARY (tolerate exit, presence check authoritative),
    # npm only as last-resort fallback if install.sh somehow didn't
    # produce a binary.
    export NODE_OPTIONS="--max-old-space-size=2048"
    log "installing openclaw via official install.sh (timeout ${TIMEOUT_INSTALL_SH}s)"
    timeout -k 30 "$TIMEOUT_INSTALL_SH" bash -c '
      curl -fsSL --max-time 60 https://openclaw.ai/install.sh | bash -s -- --install-method git 2>&1
    ' | sed 's/^/[openclaw-install] /' || log "install.sh exit non-zero (expected — post-install wizard fails non-TTY) — continuing to presence check"
    if ! command -v openclaw >/dev/null 2>&1; then
      log "openclaw not on PATH after install.sh — trying npm fallback (timeout ${TIMEOUT_NPM}s)"
      timeout -k 30 "$TIMEOUT_NPM" npm install -g openclaw 2>&1 | sed 's/^/[npm-fallback] /' || \
        log "npm fallback also failed or timed out"
    fi
    # Symlink the binary into /usr/local/bin for deterministic PATH.
    if ! command -v openclaw >/dev/null 2>&1 || [ ! -x /usr/local/bin/openclaw ]; then
      OPENCLAW_BIN=$(command -v openclaw || find /root/.openclaw /usr/local/lib/node_modules /usr/lib/node_modules -maxdepth 6 -name openclaw -type f -executable 2>/dev/null | head -1)
      if [ -n "$OPENCLAW_BIN" ] && [ -x "$OPENCLAW_BIN" ]; then
        ln -sf "$OPENCLAW_BIN" /usr/local/bin/openclaw
      fi
    fi
    if ! command -v openclaw >/dev/null 2>&1; then
      log "FATAL: openclaw not on PATH after both install paths"
      exit 1
    fi
    # Ensure binary is reachable at /usr/local/bin/openclaw so later
    # SSH invocations (which load only the default PATH) can find it.
    if [ ! -x /usr/local/bin/openclaw ]; then
      OPENCLAW_BIN=$(command -v openclaw || find /root/.openclaw /usr/local/lib/node_modules -maxdepth 5 -name openclaw -type f -executable 2>/dev/null | head -1)
      if [ -n "$OPENCLAW_BIN" ] && [ -x "$OPENCLAW_BIN" ]; then
        ln -sf "$OPENCLAW_BIN" /usr/local/bin/openclaw
        log "symlinked /usr/local/bin/openclaw -> $OPENCLAW_BIN"
      fi
    fi
    # `head -1` can SIGPIPE openclaw under `set -o pipefail`; capture
    # to a variable first.
    oc_version_out=$(openclaw --version 2>&1 || true)
    if [ -z "$oc_version_out" ]; then
      log "openclaw --version returned empty — install truly incomplete"
      exit 1
    fi
    log "openclaw version: $(echo "$oc_version_out" | head -1)"

    # OpenClaw config schema per docs.openclaw.ai: ~/.openclaw/openclaw.json
    # with `mcpServers` as an OBJECT keyed by server name (not an array).
    # xAI Grok via OpenAI-compatible provider: base_url=https://api.x.ai/v1,
    # api_key=XAI_API_KEY. Model SKU is $A2A_GATE_LLM_MODEL (default
    # grok-4-0709 = Grok 4.2 reasoning) so both agent groups exercise the
    # same production-intent reasoning model — A2A comparison holds.
    mkdir -p /root/.openclaw
    # Config lock-down — THESIS INTEGRITY
    # Every OpenClaw A2A channel except ai-memory shared memory is
    # EXPLICITLY DISABLED, so a passing scenario can only be passing
    # via the memory substrate. Enumerated negations:
    #   agentToAgent: false      - master switch off
    #   sessions_send / _spawn   - not in toolAllowlist
    #   Telegram/Discord/Slack   - no credentials configured
    #   Moltbook                 - not configured
    # Tool allowlist restricted to the memory_* family only.
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
    "memory_store",
    "memory_recall",
    "memory_list",
    "memory_get",
    "memory_share",
    "memory_link",
    "memory_update",
    "memory_detect_contradiction",
    "memory_consolidate"
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

    # Register the MCP server via the CLI as well so `openclaw mcp list`
    # shows it — double-registration is a no-op but documents intent.
    openclaw mcp set memory "$(jq -c '.mcpServers.memory' /root/.openclaw/openclaw.json)" 2>/dev/null || \
      log "openclaw mcp set returned non-zero (likely already registered via config file)"

    log "openclaw configured with xAI Grok + ai-memory MCP (agent_id=${AGENT_ID})"
    ;;

  ironclaw)
    # IronClaw is NEAR AI's Rust reimplementation of OpenClaw. Same
    # agentic-loops + tool-use category, much smaller resource footprint:
    # Rust binary baseline ~50-500MB vs OpenClaw's >8GB install-time
    # memory (r18 OOM on s-4vcpu-8gb). IronClaw fits on s-2vcpu-4gb
    # Basic-tier droplets — no DO account-tier upgrade required.
    #
    # Upstream: https://github.com/nearai/ironclaw
    # Dep: PostgreSQL 15+ with pgvector (ironclaw's own memory; does
    # NOT affect ai-memory substrate which stays SQLite-backed).

    # ---- PostgreSQL + pgvector ---------------------------------------
    # Ubuntu 24.04 noble DO droplets don't ship postgresql-15-pgvector in
    # the default apt sources (r1 fallback to postgresql-16 without
    # pgvector). Add the PostgreSQL Global Development Group (PGDG) apt
    # repository via the postgresql-common helper — this is the canonical
    # way to get pgvector + version-pinned Postgres on Ubuntu.
    log "adding PGDG apt repository"
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      postgresql-common curl ca-certificates 2>&1 | sed 's/^/[pg-common] /' \
      || log "postgresql-common install non-zero; continuing"
    if [ -x /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh ]; then
      /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y 2>&1 \
        | sed 's/^/[pgdg-setup] /' \
        || log "pgdg-setup non-zero; continuing"
    else
      log "pgdg helper absent; falling back to default apt"
    fi
    log "installing PostgreSQL 15 + pgvector for ironclaw"
    DEBIAN_FRONTEND=noninteractive apt-get update 2>&1 | sed 's/^/[pg-apt-update] /' || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      postgresql-15 postgresql-15-pgvector postgresql-contrib-15 2>&1 \
      | sed 's/^/[pg-install] /' \
      || DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
           postgresql postgresql-contrib 2>&1 | sed 's/^/[pg-install-fallback] /' \
      || log "postgres install returned non-zero; continuing"
    systemctl start postgresql 2>&1 | sed 's/^/[pg-start] /' || true
    systemctl enable postgresql >/dev/null 2>&1 || true
    # Wait for postgres to accept connections (cold start can take ~3s).
    for attempt in $(seq 1 10); do
      sudo -u postgres psql -c 'SELECT 1' >/dev/null 2>&1 && break
      sleep 1
    done
    sudo -u postgres psql -c "CREATE USER ironclaw WITH PASSWORD 'ironclaw' SUPERUSER;" >/dev/null 2>&1 || true
    sudo -u postgres createdb -O ironclaw ironclaw 2>/dev/null || log "ironclaw db already exists"
    sudo -u postgres psql -d ironclaw -c "CREATE EXTENSION IF NOT EXISTS vector;" 2>&1 \
      | sed 's/^/[pgvector] /' || log "pgvector extension unavailable; ironclaw may fall back"

    # ---- IronClaw binary --------------------------------------------
    # NEAR AI's ironclaw-installer.sh has a platform-detection bug on
    # x86_64-unknown-linux-gnu (r1 dispatch 24736559618) — it claims
    # "there isn't a download for your platform" despite the
    # ironclaw-x86_64-unknown-linux-gnu.tar.gz asset being present.
    # Bypass the installer: download the tarball directly from the
    # latest release and extract into /usr/local/bin.
    IRONCLAW_TRIPLE="x86_64-unknown-linux-gnu"
    IRONCLAW_URL="https://github.com/nearai/ironclaw/releases/latest/download/ironclaw-${IRONCLAW_TRIPLE}.tar.gz"
    log "installing ironclaw direct tarball (${IRONCLAW_URL}) (timeout ${TIMEOUT_INSTALL_SH}s)"
    mkdir -p /tmp/ironclaw-extract
    timeout -k 30 "$TIMEOUT_INSTALL_SH" bash -c "
      curl --proto '=https' --tlsv1.2 -fsSL --max-time 120 '$IRONCLAW_URL' \
        | tar xz -C /tmp/ironclaw-extract 2>&1
    " | sed 's/^/[ironclaw-install] /' \
      || log "ironclaw tarball download/extract returned non-zero — falling through to presence check"
    # Tarball extracts to ironclaw-<triple>/ironclaw (standard cargo-dist layout).
    # Find and install the binary.
    IC_EXTRACTED=$(find /tmp/ironclaw-extract -maxdepth 3 -type f -executable -name ironclaw 2>/dev/null | head -1)
    if [ -n "$IC_EXTRACTED" ] && [ -x "$IC_EXTRACTED" ]; then
      install -m 0755 "$IC_EXTRACTED" /usr/local/bin/ironclaw
      log "installed /usr/local/bin/ironclaw from $IC_EXTRACTED"
    fi

    # Symlink to /usr/local/bin for deterministic PATH across SSH sessions.
    if ! command -v ironclaw >/dev/null 2>&1 || [ ! -x /usr/local/bin/ironclaw ]; then
      IC_BIN=$(command -v ironclaw || find /root/.ironclaw /root/.cargo/bin /usr/local -maxdepth 6 -name ironclaw -type f -executable 2>/dev/null | head -1)
      if [ -n "$IC_BIN" ] && [ -x "$IC_BIN" ]; then
        ln -sf "$IC_BIN" /usr/local/bin/ironclaw
        log "symlinked /usr/local/bin/ironclaw -> $IC_BIN"
      fi
    fi
    if ! command -v ironclaw >/dev/null 2>&1; then
      log "FATAL: ironclaw not on PATH after install"
      exit 1
    fi
    ic_version_out=$(ironclaw --version 2>&1 || true)
    if [ -z "$ic_version_out" ]; then
      log "ironclaw --version returned empty — install truly incomplete"
      exit 1
    fi
    log "ironclaw version: $(echo "$ic_version_out" | head -1)"

    # ---- Bootstrap .env (DATABASE_URL + LLM via OpenAI-compat xAI) ---
    # IronClaw's bootstrap honours env > DB > default, and `.env` is
    # where pre-DB settings go (per src/bootstrap.rs).
    mkdir -p /root/.ironclaw
    cat > /root/.ironclaw/.env <<EOF
DATABASE_URL=postgres://ironclaw:ironclaw@127.0.0.1:5432/ironclaw
LLM_BACKEND=openai_compatible
LLM_BASE_URL=https://api.x.ai/v1
LLM_API_KEY=${XAI_API_KEY}
LLM_MODEL=${A2A_GATE_LLM_MODEL}
HTTP_PORT=8081
EOF
    chmod 600 /root/.ironclaw/.env

    # ---- Init config.toml (default scaffold; best-effort) ------------
    ironclaw config init --force 2>&1 | sed 's/^/[ironclaw-config-init] /' \
      || log "ironclaw config init non-zero; defaults applied in-memory"

    # ---- Thesis-integrity lockdowns (shared-memory-only profile) -----
    # The gate's thesis ("shared-memory A2A works via ai-memory") is
    # only falsifiable when no OTHER A2A channel is available. Disable
    # all messaging channels, pin gateway to local, tag the profile.
    ironclaw config set channels.telegram.enabled false 2>/dev/null || true
    ironclaw config set channels.discord.enabled  false 2>/dev/null || true
    ironclaw config set channels.slack.enabled    false 2>/dev/null || true
    ironclaw config set gateway.mode local               2>/dev/null || true
    ironclaw config set a2a_gate_profile shared-memory-only 2>/dev/null || true
    ironclaw config set a2a_gate_profile_version 1.0.0      2>/dev/null || true

    # ---- Register ai-memory MCP (stdio transport) --------------------
    # IronClaw's `mcp add` uses a positional NAME + flags, with
    # command arguments passed AFTER a `--` separator (clap idiom
    # when arg values themselves start with `--`). r3 dispatch
    # 24738251537 confirmed the error tip: "to pass '--db' as a value,
    # use '-- --db'".
    #
    # Structure: `ironclaw mcp add <NAME> [URL] --transport stdio
    # --command <cmd> --env KEY=VAL [--env KEY=VAL ...] -- <cmd args>`
    ironclaw mcp add memory \
      --transport stdio \
      --command ai-memory \
      --env "AI_MEMORY_AGENT_ID=${AGENT_ID}" \
      --description "Shared-memory A2A via ai-memory (a2a-gate)" \
      -- --db /var/lib/ai-memory/a2a.db mcp --tier semantic 2>&1 \
      | sed 's/^/[ironclaw-mcp-add] /' \
      || log "ironclaw mcp add returned non-zero; may already be registered"

    # Verify MCP landed.
    if ! ironclaw mcp list 2>/dev/null | grep -q memory; then
      log "FATAL: ai-memory MCP not registered with ironclaw after mcp add"
      exit 1
    fi

    log "ironclaw configured with xAI Grok + ai-memory MCP (agent_id=${AGENT_ID})"
    ;;

  hermes)
    # PINNED REF — repeatability requirement. Bump via semver change-
    # control (docs/baseline.md §12). Verified 2026-04-20 to work with
    # python-dotenv patch below.
    HERMES_INSTALL_REF="${HERMES_INSTALL_REF:-main}"
    log "installing Nous Research Hermes Agent from ref=${HERMES_INSTALL_REF} (timeout ${TIMEOUT_INSTALL_SH}s)"
    timeout -k 30 "$TIMEOUT_INSTALL_SH" bash -c "
      curl -fsSL --max-time 60 'https://raw.githubusercontent.com/NousResearch/hermes-agent/${HERMES_INSTALL_REF}/scripts/install.sh' \
        | bash -s -- --skip-setup 2>&1
    " | sed 's/^/[hermes-install] /' || {
      log "FATAL: hermes install.sh timed out or failed"
      exit 1
    }

    # PINNED DEP — python-dotenv version locked for reproducibility.
    # Upstream install.sh doesn't install it, yet hermes_cli/env_loader.py
    # imports at module-top. Surfaced by a2a-hermes-v0.6.0-r6.
    # PEP 668 on Ubuntu 24.04 requires --break-system-packages.
    PYTHON_DOTENV_PIN="${PYTHON_DOTENV_PIN:-1.0.1}"
    log "installing python-dotenv==${PYTHON_DOTENV_PIN} (pinned, timeout ${TIMEOUT_PIP}s)"
    timeout -k 30 "$TIMEOUT_PIP" python3 -m pip install --break-system-packages --quiet "python-dotenv==${PYTHON_DOTENV_PIN}" || {
      log "FATAL: python-dotenv==${PYTHON_DOTENV_PIN} pip install timed out or failed"
      exit 1
    }

    # Ensure `hermes` is on PATH for subsequent SSH sessions the
    # scenarios run. The installer may drop it under
    # $HOME/.hermes/hermes-agent — symlink into /usr/local/bin so
    # drive_agent.sh's `command -v hermes` check works identically
    # on both groups.
    if [ ! -x /usr/local/bin/hermes ]; then
      HERMES_BIN=$(command -v hermes || find /root/.hermes -maxdepth 4 -name hermes -type f -executable | head -1)
      if [ -n "$HERMES_BIN" ] && [ -x "$HERMES_BIN" ]; then
        ln -sf "$HERMES_BIN" /usr/local/bin/hermes
        log "symlinked /usr/local/bin/hermes -> $HERMES_BIN"
      else
        log "WARN: hermes binary not found after install; drive_agent.sh will fall back to HTTP"
      fi
    fi

    # Hermes config uses YAML. mcp_servers map (underscored), one
    # entry pointing at ai-memory stdio, same DB + same MCP binary
    # as the openclaw path. tier=semantic matches how the operator
    # workstation is wired.
    #
    # THESIS INTEGRITY — Hermes's native A2A channels are EXPLICITLY
    # DISABLED so a passing scenario is only passing via ai-memory:
    #   acp.enabled: false        — Agent Communication Protocol off
    #   messaging.gateway: false  — no Telegram/Discord/Slack bridge
    #   execution_backends: []    — no SSH/Docker/Modal cross-node exec
    #   mcp_server_mode: false    — client-only (don't expose Hermes as MCP)
    #   subagent_delegation: false — no spawn_subagent
    # tool_allowlist restricted to memory_*.
    mkdir -p /root/.hermes
    cat > /root/.hermes/config.yaml <<EOF
# Nous Research Hermes Agent — ai-memory-ai2ai-gate
# Generated by scripts/setup_node.sh for agent_id=${AGENT_ID}

mcp_servers:
  memory:
    command: ai-memory
    args:
      - "--db"
      - "/var/lib/ai-memory/a2a.db"
      - "mcp"
      - "--tier"
      - "semantic"
    env:
      AI_MEMORY_AGENT_ID: "${AGENT_ID}"
    enabled: true

# A2A channel lock-down — alternative communication paths must be OFF
# for the shared-memory A2A thesis to be falsifiable.
acp:
  enabled: false

messaging:
  gateway_enabled: false
  platforms:
    telegram: { enabled: false }
    discord:  { enabled: false }
    slack:    { enabled: false }

execution_backends: []

mcp_server_mode: false     # Hermes is MCP client of ai-memory, NOT an MCP server itself
subagent_delegation: false # no spawn_subagent — forces all coordination through memory

tool_allowlist:
  - memory_store
  - memory_recall
  - memory_list
  - memory_get
  - memory_share
  - memory_link
  - memory_update
  - memory_detect_contradiction
  - memory_consolidate

a2a_gate_profile: shared-memory-only
a2a_gate_profile_version: "1.0.0"
EOF
    chmod 600 /root/.hermes/config.yaml

    # Hermes supports xAI natively via --provider xai (alias grok).
    # It reads XAI_API_KEY from env for that provider — no
    # OpenAI-compatible shim needed. drive_agent.sh sources this
    # file before invoking `hermes chat`.
    cat > /etc/ai-memory-a2a/hermes.env <<EOF
XAI_API_KEY=${XAI_API_KEY}
EOF
    chmod 600 /etc/ai-memory-a2a/hermes.env
    log "hermes configured with ai-memory MCP + xAI Grok (agent_id=${AGENT_ID})"
    ;;

  *)
    echo "unknown AGENT_TYPE: $AGENT_TYPE" >&2
    exit 1
    ;;
esac

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

# ---- BASELINE VERIFICATION ---------------------------------------
# Emit /etc/ai-memory-a2a/baseline.json asserting the invariants that
# MUST hold on every agent droplet of every campaign. The workflow
# scp's these back; collect_reports.sh embeds them into a2a-summary.
# Any false field = baseline violation; no scenarios may run.
#
# INVARIANTS (per user directive, 2026-04-21):
#   1. agent framework is the authentic upstream binary (not a
#      symlink/surrogate to a different CLI)
#   2. agent LLM backend is xAI Grok ($A2A_GATE_LLM_MODEL, default Grok 4.2 reasoning)
#   3. agent's ONLY MCP server is `ai-memory` on the local node
#   4. AGENT_ID is stamped into the MCP environment
#   5. local `ai-memory serve` is part of the W=2/N=4 federation mesh

baseline_check() {
  local label="$1" cmd="$2"
  if eval "$cmd" >/dev/null 2>&1; then echo true; else echo false; fi
}

case "$AGENT_TYPE" in
  openclaw)
    # openclaw binary resolves to openclaw/openclaw — NOT a symlink
    # to any other CLI. Accept /usr/local/bin/openclaw that's either
    # a real file or a symlink into ~/.openclaw/.
    ob=$(readlink -f "$(command -v openclaw 2>/dev/null || echo /nonexistent)" 2>/dev/null || echo "")
    is_authentic=$([ -n "$ob" ] && [ "$ob" != "/usr/local/bin/grok" ] && [ -z "${ob##*openclaw*}" ] && echo true || echo false)
    fw_version=$(openclaw --version 2>/dev/null | head -1 | tr -d '"' || echo "unknown")
    mcp_registered=$(baseline_check "mcp-list" "openclaw mcp list 2>/dev/null | grep -q memory")
    has_xai=$(jq -e --arg m "$A2A_GATE_LLM_MODEL" '.providers.xai.base_url == "https://api.x.ai/v1" and .providers.xai.default_model == $m' /root/.openclaw/openclaw.json >/dev/null 2>&1 && echo true || echo false)
    default_xai=$(jq -e '.defaultProvider == "xai"' /root/.openclaw/openclaw.json >/dev/null 2>&1 && echo true || echo false)
    has_mem=$(jq -e '.mcpServers.memory.command == "ai-memory"' /root/.openclaw/openclaw.json >/dev/null 2>&1 && echo true || echo false)
    has_aid=$(jq -e --arg a "$AGENT_ID" '.mcpServers.memory.env.AI_MEMORY_AGENT_ID == $a' /root/.openclaw/openclaw.json >/dev/null 2>&1 && echo true || echo false)
    ;;
  ironclaw)
    ob=$(readlink -f "$(command -v ironclaw 2>/dev/null || echo /nonexistent)" 2>/dev/null || echo "")
    is_authentic=$([ -n "$ob" ] && [ -z "${ob##*ironclaw*}" ] && echo true || echo false)
    fw_version=$(ironclaw --version 2>/dev/null | head -1 | tr -d '"' || echo "unknown")
    mcp_registered=$(baseline_check "mcp-list" "ironclaw mcp list 2>/dev/null | grep -q memory")
    has_xai=$(grep -qE '^LLM_BASE_URL=https://api\.x\.ai/v1' /root/.ironclaw/.env 2>/dev/null && \
              grep -qF "LLM_MODEL=${A2A_GATE_LLM_MODEL}" /root/.ironclaw/.env 2>/dev/null && echo true || echo false)
    default_xai=$(grep -qE '^LLM_BACKEND=openai_compatible' /root/.ironclaw/.env 2>/dev/null && echo true || echo false)
    has_mem=$(ironclaw mcp list --verbose 2>/dev/null | grep -qE '(command.*ai-memory|ai-memory)' && echo true || echo false)
    has_aid=$(ironclaw mcp list --verbose 2>/dev/null | grep -qF "AI_MEMORY_AGENT_ID=${AGENT_ID}" && echo true || echo false)
    ;;
  hermes)
    ob=$(readlink -f "$(command -v hermes 2>/dev/null || echo /nonexistent)" 2>/dev/null || echo "")
    is_authentic=$([ -n "$ob" ] && [ -z "${ob##*hermes*}" ] && echo true || echo false)
    fw_version=$(hermes --version 2>/dev/null | head -1 | tr -d '"' || echo "unknown")
    mcp_registered=$(grep -q '^  memory:' /root/.hermes/config.yaml 2>/dev/null && echo true || echo false)
    has_xai=$(grep -q '^XAI_API_KEY=' /etc/ai-memory-a2a/hermes.env 2>/dev/null && echo true || echo false)
    # hermes takes provider/model as drive_agent.sh flags; we assert
    # drive_agent.sh is on disk and passes the right flags.
    default_xai=$(grep -q 'provider xai' /root/drive_agent.sh 2>/dev/null && grep -q "$A2A_GATE_LLM_MODEL" /root/drive_agent.sh 2>/dev/null && echo true || echo false)
    has_mem=$(grep -q 'command: ai-memory' /root/.hermes/config.yaml 2>/dev/null && echo true || echo false)
    has_aid=$(grep -q "AI_MEMORY_AGENT_ID.*${AGENT_ID}" /root/.hermes/config.yaml 2>/dev/null && echo true || echo false)
    ;;
esac

# Federation membership: this node's ai-memory serve must be listening
# and have >=1 peer configured (we requested 3).
fed_live=$(curl -sS http://127.0.0.1:9077/api/v1/health 2>/dev/null | jq -e '.status == "ok" or .healthy == true or .ok == true' >/dev/null 2>&1 && echo true || echo false)

# UFW must be disabled — ship-gate lesson, explicit baseline invariant.
if command -v ufw >/dev/null 2>&1; then
  ufw_disabled=$(ufw status 2>/dev/null | head -1 | grep -qiE 'inactive|disabled' && echo true || echo false)
else
  # No UFW on the image = effectively disabled for our purposes.
  ufw_disabled=true
fi

# iptables policy must be ACCEPT on INPUT/OUTPUT/FORWARD.
iptables_policy_ok=$(iptables -S 2>/dev/null | grep -E '^-P (INPUT|OUTPUT|FORWARD) ACCEPT' | wc -l | tr -d ' ')
iptables_flushed=$([ "${iptables_policy_ok:-0}" = "3" ] && echo true || echo false)

# Dead-man switch — must have a scheduled shutdown to cap campaign cost.
# `shutdown -P +480` was invoked earlier in this script; check that
# the kernel recorded the scheduled shutdown.
dead_man_switch_scheduled=$([ -f /run/systemd/shutdown/scheduled ] || who -r 2>/dev/null | grep -q 'run-level 6' || pgrep -f 'shutdown.*+480' >/dev/null 2>&1 && echo true || echo false)
# Fallback check: was a shutdown command issued in the last hour?
if [ "$dead_man_switch_scheduled" != "true" ]; then
  dead_man_switch_scheduled=$(ps -eo cmd 2>/dev/null | grep -q 'shutdown -P' && echo true || echo false)
fi

# SHA256 of the agent config file — proves the deterministic emit.
# Hash is sensitive to AGENT_ID substitution so it differs per node
# but is repeatable across runs for the same (AGENT_TYPE, AGENT_ID) pair.
case "$AGENT_TYPE" in
  openclaw) config_sha256=$(sha256sum /root/.openclaw/openclaw.json 2>/dev/null | awk '{print $1}') ;;
  ironclaw) config_sha256=$(sha256sum /root/.ironclaw/.env          2>/dev/null | awk '{print $1}') ;;
  hermes)   config_sha256=$(sha256sum /root/.hermes/config.yaml     2>/dev/null | awk '{print $1}') ;;
  *)        config_sha256="" ;;
esac
config_sha256=${config_sha256:-unknown}

# NEGATIVE INVARIANTS — alternative A2A channels must be OFF.
# The gate's thesis ("shared-memory A2A works") is only falsifiable
# if no other A2A channel is available as a pass-through.
case "$AGENT_TYPE" in
  openclaw)
    a2a_master_off=$(jq -e '.agentToAgent == false' /root/.openclaw/openclaw.json >/dev/null 2>&1 && echo true || echo false)
    no_sessions_tools=$(jq -e '.toolAllowlist | map(select(startswith("sessions_"))) | length == 0' /root/.openclaw/openclaw.json >/dev/null 2>&1 && echo true || echo false)
    # Channels/gateway/subagent/agentTeams/sharedServices all off,
    # gateway.mode local, nodeHosts empty.
    no_chat_channels=$(jq -e '
      ([.channels[] | select(.enabled == true)] | length == 0) and
      (.gateway.mode == "local") and
      ((.nodeHosts // []) | length == 0) and
      (.remoteMode.enabled == false) and
      (.subAgent.enabled == false) and
      (.agentTeams.enabled == false) and
      ([.sharedServices[] | select(.enabled == true)] | length == 0)
    ' /root/.openclaw/openclaw.json >/dev/null 2>&1 && echo true || echo false)
    tools_are_memory_only=$(jq -e '[.toolAllowlist[] | select(startswith("memory_") | not)] | length == 0' /root/.openclaw/openclaw.json >/dev/null 2>&1 && echo true || echo false)
    profile_locked=$(jq -e '.a2aGateProfile == "shared-memory-only"' /root/.openclaw/openclaw.json >/dev/null 2>&1 && echo true || echo false)
    ;;
  ironclaw)
    # IronClaw has no cross-channel A2A by default (REPL-oriented Rust
    # agent). Channels/gateway are the config surface; we pinned them
    # off in the install block. Thesis-integrity = enumerated-off attest.
    a2a_master_off=$(ironclaw config get gateway.mode 2>/dev/null | grep -q local && echo true || echo false)
    # IronClaw has no "sub-agent sessions" tool family; always true.
    no_sessions_tools=true
    no_chat_channels=$(
      tg=$(ironclaw config get channels.telegram.enabled 2>/dev/null)
      di=$(ironclaw config get channels.discord.enabled  2>/dev/null)
      sl=$(ironclaw config get channels.slack.enabled    2>/dev/null)
      [ "$tg" = "false" ] && [ "$di" = "false" ] && [ "$sl" = "false" ] && echo true || echo false
    )
    # Tool allowlist happens at MCP registration time (only ai-memory
    # registered). Verify exactly one MCP server is configured.
    mcp_count=$(ironclaw mcp list 2>/dev/null | grep -cE '^[^[:space:]]' || echo 0)
    tools_are_memory_only=$([ "$mcp_count" = "1" ] && ironclaw mcp list 2>/dev/null | grep -q memory && echo true || echo false)
    profile_locked=$(ironclaw config get a2a_gate_profile 2>/dev/null | grep -q shared-memory-only && echo true || echo false)
    ;;
  hermes)
    # YAML — use python3 for robust parsing.
    python3 - <<PY > /tmp/hermes_negatives.json
import yaml, json, sys
with open("/root/.hermes/config.yaml") as f: cfg = yaml.safe_load(f) or {}
def get(path, default=None):
    cur = cfg
    for k in path.split("."):
        if not isinstance(cur, dict) or k not in cur: return default
        cur = cur[k]
    return cur
tools = cfg.get("tool_allowlist") or []
channels = (cfg.get("messaging") or {}).get("platforms") or {}
out = {
  "acp_off":          get("acp.enabled") == False,
  "gateway_off":      get("messaging.gateway_enabled") == False,
  "no_chat_channels": all(not (v or {}).get("enabled") for v in channels.values()),
  "no_exec_backends": (cfg.get("execution_backends") or []) == [],
  "mcp_client_only":  get("mcp_server_mode") == False,
  "no_subagent":      get("subagent_delegation") == False,
  "tools_memory_only": all(isinstance(t,str) and t.startswith("memory_") for t in tools) and len(tools) > 0,
  "profile_locked":   get("a2a_gate_profile") == "shared-memory-only",
}
print(json.dumps(out))
PY
    a2a_master_off=$(jq -r '.acp_off and .gateway_off' /tmp/hermes_negatives.json 2>/dev/null || echo false)
    no_sessions_tools=$(jq -r '.no_subagent' /tmp/hermes_negatives.json 2>/dev/null || echo false)
    no_chat_channels=$(jq -r '.no_chat_channels and .no_exec_backends and .mcp_client_only' /tmp/hermes_negatives.json 2>/dev/null || echo false)
    tools_are_memory_only=$(jq -r '.tools_memory_only' /tmp/hermes_negatives.json 2>/dev/null || echo false)
    profile_locked=$(jq -r '.profile_locked' /tmp/hermes_negatives.json 2>/dev/null || echo false)
    ;;
esac

# ---- FUNCTIONAL PROBES --------------------------------------------
# Static config attestation is necessary but not sufficient. These
# probes exercise the live surfaces the agent will use.

# Probe 1 — xAI reachability + auth. Direct HTTPS call, parse
# message content. max_tokens=10 keeps the probe cheap (~fractions
# of a cent per dispatch, <1s wall).
log "PROBE 1/2: xAI Grok reachability + auth"
xai_resp=$(curl -sS --max-time 20 \
  -X POST https://api.x.ai/v1/chat/completions \
  -H "Authorization: Bearer $XAI_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${A2A_GATE_LLM_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word READY and nothing else.\"}],\"max_tokens\":10,\"temperature\":0}" \
  2>/dev/null || echo '{}')
xai_content=$(echo "$xai_resp" | jq -r '.choices[0].message.content // empty' 2>/dev/null | tr -d '[:space:]')
if [ -n "$xai_content" ]; then
  xai_functional=true
  log "  PROBE 1 OK — xAI responded: \"$xai_content\""
else
  xai_functional=false
  log "  PROBE 1 FAIL — no content from xAI. Response: $(echo "$xai_resp" | head -c 200)"
fi

# Probe F2a — DETERMINISTIC substrate canary (no LLM). Direct HTTP
# POST to local serve. Proves the federation-side write path works
# independent of the agent framework. Gates baseline_pass.
log "PROBE F2a/F2b: substrate + agent-driven canary"
F2A_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "canary-a-$RANDOM-$RANDOM")
F2A_NS="_baseline_canary_f2a"
curl -sS -X POST "http://127.0.0.1:9077/api/v1/memories" \
  -H "X-Agent-Id: ${AGENT_ID}" \
  -H "Content-Type: application/json" \
  -d "{\"tier\":\"mid\",\"namespace\":\"${F2A_NS}\",\"title\":\"f2a-canary-${AGENT_ID}\",\"content\":\"${F2A_UUID}\",\"priority\":5,\"confidence\":1.0,\"source\":\"api\",\"metadata\":{\"agent_id\":\"${AGENT_ID}\",\"probe\":\"F2a\"}}" \
  > /tmp/f2a-write.log 2>&1 || true
sleep 1
f2a_hit=$(curl -sS "http://127.0.0.1:9077/api/v1/memories?namespace=${F2A_NS}&limit=20" 2>/dev/null | \
  jq --arg u "$F2A_UUID" --arg a "$AGENT_ID" \
    '[.memories[]? | select(.content == $u and (.metadata.agent_id // "") == $a)] | length' 2>/dev/null || echo 0)
if [ "${f2a_hit:-0}" -ge 1 ] 2>/dev/null; then
  f2a_functional=true
  log "  PROBE F2a OK — direct HTTP write roundtrip succeeded"
else
  f2a_functional=false
  log "  PROBE F2a FAIL — substrate unable to store + retrieve canary"
fi

# Probe F2b — AGENT-DRIVEN MCP canary. Dependent on LLM behavior, so
# it's attestation-only (NOT a baseline_pass gate). When it fails
# while F2a passes, the scenario-level MCP stdio path is the issue;
# when F2b passes, agents are fully ready for A2A scenarios.
F2B_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "canary-b-$RANDOM-$RANDOM")
F2B_NS="_baseline_canary_f2b"
F2B_PROMPT="Use the ai-memory MCP memory_store tool to save a memory with namespace=${F2B_NS}, title=canary-${AGENT_ID}, content=${F2B_UUID}. Respond with DONE when the tool call completes."
. /etc/ai-memory-a2a/env
log "  F2b: invoking $AGENT_TYPE with timeout ${TIMEOUT_AGENT_CLI}s"
case "$AGENT_TYPE" in
  openclaw)
    timeout -k 10 "$TIMEOUT_AGENT_CLI" openclaw run --non-interactive --format json --max-tool-rounds 10 -p "$F2B_PROMPT" > /tmp/canary-openclaw.log 2>&1 || \
      log "  F2b: openclaw returned non-zero or timed out (${TIMEOUT_AGENT_CLI}s) — proceeding"
    ;;
  hermes)
    set -a; . /etc/ai-memory-a2a/hermes.env; set +a
    timeout -k 10 "$TIMEOUT_AGENT_CLI" hermes chat -Q --provider xai --model "$A2A_GATE_LLM_MODEL" -q "$F2B_PROMPT" > /tmp/canary-hermes.log 2>&1 || \
      log "  F2b: hermes returned non-zero or timed out (${TIMEOUT_AGENT_CLI}s) — proceeding"
    ;;
esac
sleep 3
f2b_hit=$(curl -sS "http://127.0.0.1:9077/api/v1/memories?namespace=${F2B_NS}&limit=20" 2>/dev/null | \
  jq --arg u "$F2B_UUID" --arg a "$AGENT_ID" \
    '[.memories[]? | select(.content == $u and (.metadata.agent_id // "") == $a)] | length' 2>/dev/null || echo 0)
canary_log_file="/tmp/canary-${AGENT_TYPE}.log"
if [ -f "$canary_log_file" ]; then
  canary_response=$(head -c 800 "$canary_log_file" 2>/dev/null | tr '\000-\037' ' ' | head -c 500 || echo "")
else
  canary_response=""
fi
if [ "${f2b_hit:-0}" -ge 1 ] 2>/dev/null; then
  f2b_functional=true
  log "  PROBE F2b OK — agent-driven MCP canary landed"
else
  f2b_functional=false
  log "  PROBE F2b FAIL (non-blocking) — agent didn't land canary. Response head: ${canary_response:0:200}"
fi

# Retained for backwards-compat with existing baseline.json schema
# consumers; F2 (combined) is true only if BOTH sub-probes pass. We
# gate baseline_pass on F2a only (deterministic); F2b is observed.
canary_functional=$f2a_functional
CANARY_UUID=$F2A_UUID
CANARY_NS=$F2A_NS

# Probe F4 — DIRECTIONAL MESH CONNECTIVITY. Closes the Phase-2 baseline
# gap called out in ai-memory-ai2ai-gate#5 and AlphaOne RCA Standard v1.
# Prior baseline attested local serve health + local F2a write; it did
# NOT verify that THIS node can reach EVERY peer's 9077 port over the
# private VPC network. A partial-mesh failure (e.g., node-3 → node-1
# dark while every other direction works) would have been invisible to
# baseline_pass and surfaced only as scenario-level red, tempting
# code-level RCA into mis-attribution.
#
# This probe runs N-1 directed reachability checks from THIS node to
# each configured peer. Per-node result is edges_ok/edges_total. The
# aggregator (collect_reports.sh) ANDs across the 4 nodes to confirm
# full 12-edge bidirectional reachability (N=4 → N*(N-1)=12 edges).
#
# We probe with BOTH GET /api/v1/health (cheap, proves port-reachable +
# serve-live) AND POST /api/v1/sync/push with dry_run=true (proves the
# same verb/path peers will use during scenarios, catches mTLS/auth
# failures a bare GET would miss). Each peer edge must pass BOTH.
log "PROBE F4: directional mesh connectivity to each peer"
f4_edges_ok=0
f4_edges_total=0
f4_edges_detail=()
IFS=',' read -ra F4_PEER_ARR <<< "$PEER_URLS"
for peer_url in "${F4_PEER_ARR[@]}"; do
  [ -z "$peer_url" ] && continue
  f4_edges_total=$((f4_edges_total + 1))
  peer_label="${peer_url#http://}"
  peer_label="${peer_label%/}"

  # Leg 1: GET /health
  h_ok=false
  if curl -sS --max-time 5 "${peer_url%/}/api/v1/health" 2>/dev/null \
       | jq -e '.status == "ok" or .healthy == true or .ok == true' >/dev/null 2>&1; then
    h_ok=true
  fi

  # Leg 2: POST /api/v1/sync/push dry_run — same verb/path scenarios use.
  # dry_run=true so no row state is perturbed on the peer. Empty memories
  # array keeps the body valid per the v0.6.0 schema.
  p_ok=false
  p_resp=$(curl -sS --max-time 5 \
    -X POST "${peer_url%/}/api/v1/sync/push" \
    -H 'Content-Type: application/json' \
    -d "{\"sender_agent_id\":\"${AGENT_ID}\",\"sender_clock\":{\"entries\":{}},\"memories\":[],\"dry_run\":true}" \
    2>/dev/null || echo '')
  if echo "$p_resp" | jq -e '.applied == 0 and .dry_run == true' >/dev/null 2>&1; then
    p_ok=true
  fi

  if $h_ok && $p_ok; then
    f4_edges_ok=$((f4_edges_ok + 1))
    f4_edges_detail+=("${peer_label}:OK")
    log "  PROBE F4 ${peer_label}: OK (health + sync_push dry_run)"
  else
    f4_edges_detail+=("${peer_label}:FAIL(health=$h_ok,sync=$p_ok)")
    log "  PROBE F4 ${peer_label}: FAIL (health=$h_ok, sync_push=$p_ok)"
  fi
done
if [ "$f4_edges_ok" -eq "$f4_edges_total" ] && [ "$f4_edges_total" -gt 0 ]; then
  f4_functional=true
  log "  PROBE F4 OK — all ${f4_edges_ok}/${f4_edges_total} outbound mesh edges reachable"
else
  f4_functional=false
  log "  PROBE F4 FAIL — ${f4_edges_ok}/${f4_edges_total} outbound mesh edges reachable"
fi
f4_edges_detail_csv=$(IFS=,; echo "${f4_edges_detail[*]:-}")

jq -n \
  --arg agent_type "$AGENT_TYPE" \
  --arg agent_id "$AGENT_ID" \
  --arg node_index "$NODE_INDEX" \
  --arg fw_version "$fw_version" \
  --arg peer_urls "$PEER_URLS" \
  --arg ai_memory_version "$AI_MEMORY_VERSION" \
  --arg xai_content "$xai_content" \
  --arg canary_uuid "$CANARY_UUID" \
  --arg canary_response "$canary_response" \
  --argjson is_authentic "$is_authentic" \
  --argjson mcp_registered "$mcp_registered" \
  --argjson has_xai "$has_xai" \
  --argjson default_xai "$default_xai" \
  --argjson has_mem "$has_mem" \
  --argjson has_aid "$has_aid" \
  --argjson fed_live "$fed_live" \
  --argjson xai_functional "$xai_functional" \
  --argjson canary_functional "$canary_functional" \
  --argjson ufw_disabled "$ufw_disabled" \
  --argjson iptables_flushed "$iptables_flushed" \
  --argjson dead_man_switch_scheduled "$dead_man_switch_scheduled" \
  --argjson a2a_master_off "$a2a_master_off" \
  --argjson no_sessions_tools "$no_sessions_tools" \
  --argjson no_chat_channels "$no_chat_channels" \
  --argjson tools_are_memory_only "$tools_are_memory_only" \
  --argjson profile_locked "$profile_locked" \
  --argjson f2a_functional "$f2a_functional" \
  --argjson f2b_functional "$f2b_functional" \
  --argjson f4_functional "$f4_functional" \
  --argjson f4_edges_ok "$f4_edges_ok" \
  --argjson f4_edges_total "$f4_edges_total" \
  --arg f4_edges_detail "$f4_edges_detail_csv" \
  --arg f2a_uuid "$F2A_UUID" \
  --arg f2b_uuid "$F2B_UUID" \
  --arg config_sha256 "$config_sha256" \
  '{
    spec_version: "1.2.0",
    agent_type:$agent_type,
    agent_id:$agent_id,
    node_index:$node_index,
    framework_version:$fw_version,
    ai_memory_version:$ai_memory_version,
    peer_urls:$peer_urls,
    config_file_sha256:$config_sha256,
    config_attestation: {
      framework_is_authentic:$is_authentic,
      mcp_server_ai_memory_registered:$mcp_registered,
      llm_backend_is_xai_grok:$has_xai,
      llm_is_default_provider:$default_xai,
      mcp_command_is_ai_memory:$has_mem,
      agent_id_stamped:$has_aid,
      federation_live:$fed_live,
      ufw_disabled:$ufw_disabled,
      iptables_flushed:$iptables_flushed,
      dead_man_switch_scheduled:$dead_man_switch_scheduled
    },
    negative_invariants: {
      _description: "Alternative A2A channels must be OFF so a passing scenario is only passing via ai-memory shared memory. Any true here = thesis-preserving.",
      a2a_protocol_off:                 $a2a_master_off,
      sub_agent_or_sessions_spawn_off:  $no_sessions_tools,
      alternative_channels_off:         $no_chat_channels,
      tool_allowlist_is_memory_only:    $tools_are_memory_only,
      a2a_gate_profile_locked:          $profile_locked
    },
    functional_probes: {
      xai_grok_chat_reachable:         $xai_functional,
      xai_grok_sample_reply:           $xai_content,
      substrate_http_canary_f2a:       $f2a_functional,
      substrate_http_canary_uuid:      $f2a_uuid,
      agent_mcp_canary_f2b:            $f2b_functional,
      agent_mcp_canary_uuid:           $f2b_uuid,
      agent_canary_response_head:      $canary_response,
      _f2b_note:                       "F2b is LLM-dependent and non-blocking. F2a (deterministic HTTP substrate) gates baseline_pass.",
      mesh_connectivity_f4:            $f4_functional,
      mesh_edges_ok:                   $f4_edges_ok,
      mesh_edges_total:                $f4_edges_total,
      mesh_edges_detail:               $f4_edges_detail,
      _f4_note:                        "F4 verifies this local nodes N-1 OUTBOUND mesh edges to every peer via both GET health and POST sync_push dry_run. Aggregator ANDs across N nodes to confirm full N*(N-1) bidirectional reachability. Gates baseline_pass.",
      agent_mcp_ai_memory_canary:      $f2a_functional,
      canary_uuid:                     $f2a_uuid,
      canary_namespace:                "_baseline_canary_f2a"
    },
    baseline_pass: (
      $is_authentic and $mcp_registered and
      $has_xai and $default_xai and
      $has_mem and $has_aid and $fed_live and
      $ufw_disabled and $iptables_flushed and $dead_man_switch_scheduled and
      $a2a_master_off and $no_sessions_tools and $no_chat_channels and
      $tools_are_memory_only and $profile_locked and
      $xai_functional and $f2a_functional and $f4_functional
    )
  }' > /etc/ai-memory-a2a/baseline.json

cat /etc/ai-memory-a2a/baseline.json

bp=$(jq -r '.baseline_pass' /etc/ai-memory-a2a/baseline.json)
if [ "$bp" != "true" ]; then
  log "BASELINE VIOLATION on node $NODE_INDEX (agent $AGENT_ID) — scenarios must NOT run"
  log "See /etc/ai-memory-a2a/baseline.json for per-field status"
  exit 2
fi
log "BASELINE OK — $AGENT_TYPE agent $AGENT_ID ready for A2A testing"
