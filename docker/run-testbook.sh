#!/usr/bin/env bash
# Copyright 2026 AlphaOne LLC
# SPDX-License-Identifier: Apache-2.0
#
# Run the testbook against the local Docker OpenClaw mesh.
# Mirror of what the GitHub Actions a2a-gate workflow does on DO, but
# via docker exec instead of ssh. Produces the same runs/<campaign>/
# artifact layout so the existing Pages dashboard picks it up.
#
# Usage:
#   ./run-testbook.sh <campaign-id> [<scenarios>]
#
# Requires:
#   * ai-memory-base:local + ai-memory-openclaw:local images built
#   * docker-compose.openclaw.yml mesh UP and healthy (./smoke.sh passes)
#   * XAI_API_KEY in env (sourced from /root/.env in this repo's workflow)
#
# Contract per scenario (identical to DO workflow):
#   stdout = single-line JSON report   → scenario-<id>.json
#   stderr = human log                 → scenario-<id>.log
#   exit 0 on pass/fail/skip; non-zero = hard crash
set -euo pipefail

CAMPAIGN_ID="${1:?usage: run-testbook.sh <campaign-id> [<scenarios>]}"
SCENARIOS_ARG="${2:-1 1b 2 4 5 6 9 10 11 12 13 14 15 16 17 18 22 23 24 25 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42}"

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
RUN_DIR="$REPO_ROOT/runs/$CAMPAIGN_ID"
mkdir -p "$RUN_DIR"

log() { printf '[runbook %s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
fail() { log "FATAL: $*"; exit 1; }

# --- Pre-checks ------------------------------------------------------
for i in 1 2 3 4; do
  state=$(docker inspect -f '{{.State.Status}}/{{if .State.Health}}{{.State.Health.Status}}{{else}}no-health{{end}}' "a2a-node-$i" 2>&1 || echo "missing")
  [[ "$state" == running/healthy ]] || fail "a2a-node-$i not healthy ($state) — run compose up first"
done
log "mesh 4/4 healthy"

# --- Reset DB state across the mesh ---------------------------------
# Each round must start from a pristine database to match the DO
# behavior where every campaign provisions a fresh 4-droplet VPC.
# Without this, state from the previous round (e.g. scenario-5's
# fixed-namespace scenario5-consolidate) accumulates and scenarios
# that assume a clean slate fail on the second run.
#
# Sequence (mesh stays up — we only restart containers):
#   1) Delete the SQLite files in the volume (unlink only — serve
#      keeps its open file handles until restart)
#   2) docker restart each container in parallel → serve exits,
#      handles close, files truly gone, entrypoint re-runs and
#      brings serve up on a fresh DB
#   3) Poll for /health on each node
log "resetting database state across 4 nodes for a pristine round"
for i in 1 2 3 4; do
  docker exec "a2a-node-$i" rm -f /var/lib/ai-memory/a2a.db /var/lib/ai-memory/a2a.db-wal /var/lib/ai-memory/a2a.db-shm 2>/dev/null || true
done
docker restart a2a-node-1 a2a-node-2 a2a-node-3 a2a-node-4 >/dev/null
log "containers restarted — waiting for health"
for i in 1 2 3 4; do
  for attempt in $(seq 1 90); do
    if docker exec "a2a-node-$i" curl -sSf http://127.0.0.1:9077/api/v1/health 2>/dev/null | grep -q '"ok"'; then
      break
    fi
    sleep 1
  done
  docker exec "a2a-node-$i" curl -sSf http://127.0.0.1:9077/api/v1/health 2>/dev/null | grep -q '"ok"' \
    || fail "a2a-node-$i did not return /health after state reset"
done
log "state reset done — all 4 nodes fresh + healthy"

# --- Scenario run ---------------------------------------------------
START_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
log "campaign $CAMPAIGN_ID starting $START_TS"

# Export env for harness: TOPOLOGY=local-docker, NODE<N>_IP=container name,
# NODE<N>_PRIV=bridge IP. AGENT_GROUP=openclaw (the only supported group
# in this mesh; mesh compose file pins openclaw on nodes 1-3).
export TOPOLOGY=local-docker
export NODE1_IP="a2a-node-1"
export NODE2_IP="a2a-node-2"
export NODE3_IP="a2a-node-3"
export NODE4_IP="a2a-node-4"
export MEMORY_NODE_IP="a2a-node-4"
export NODE1_PRIV="10.88.1.11"
export NODE2_PRIV="10.88.1.12"
export NODE3_PRIV="10.88.1.13"
export MEMORY_PRIV="10.88.1.14"
export AGENT_GROUP="openclaw"
export TLS_MODE="off"

SCENARIOS_RUN=()
for s in $SCENARIOS_ARG; do
  script=$(ls "$REPO_ROOT/scripts/scenarios/${s}_"*.py 2>/dev/null | head -1)
  if [ -z "$script" ]; then
    log "  skip s=$s — no script implementation"
    continue
  fi
  log "scenario $s ($(basename "$script"))"
  SCN_START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  python3 "$script" \
    > "$RUN_DIR/scenario-${s}.json" \
    2> "$RUN_DIR/scenario-${s}.log" || true
  SCN_END=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  SCENARIOS_RUN+=("${s}:${SCN_START}:${SCN_END}")
done
END_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# --- Aggregate a2a-summary.json -------------------------------------
log "aggregating $RUN_DIR/a2a-summary.json"
python3 - "$RUN_DIR" "$CAMPAIGN_ID" "$START_TS" "$END_TS" <<'PY'
import json, sys, os, pathlib

run_dir = pathlib.Path(sys.argv[1])
campaign = sys.argv[2]
start_ts, end_ts = sys.argv[3], sys.argv[4]

scenarios = []
skipped_reports = []
for jpath in sorted(run_dir.glob("scenario-*.json")):
    sid = jpath.stem.removeprefix("scenario-")
    try:
        scenarios.append(json.loads(jpath.read_text()))
    except Exception as e:
        skipped_reports.append(f"{jpath.name}:unparseable")

reasons = []
overall_pass = True
for s in scenarios:
    if s.get("skipped"):
        continue
    if not s.get("pass"):
        overall_pass = False
        for r in (s.get("reasons") or [s.get("reason") or ""]):
            if r:
                reasons.append(f"s{s.get('scenario')}: {r}")

if skipped_reports:
    overall_pass = False
    reasons.extend(skipped_reports)

summary = {
    "campaign_id": campaign,
    "agent_group": "openclaw",
    "ai_memory_git_ref": "release/v0.6.2",
    "completed_at": end_ts,
    "overall_pass": overall_pass,
    "scenarios": scenarios,
    "reasons": reasons,
    "skipped_reports": skipped_reports,
    "meta": {
        "campaign_id": campaign,
        "agent_group": "openclaw",
        "ai_memory_git_ref": "release/v0.6.2",
        "topology": "local-docker",
        "infra": {
            "provider": "local-docker",
            "host": os.uname().nodename,
            "mesh_topology": "4-node bridge (3 openclaw agents + 1 memory-only aggregator)",
            "nodes": [
                {"index": 1, "role": "agent", "agent_id": "ai:alice",
                 "container": "a2a-node-1", "private_ip": "10.88.1.11"},
                {"index": 2, "role": "agent", "agent_id": "ai:bob",
                 "container": "a2a-node-2", "private_ip": "10.88.1.12"},
                {"index": 3, "role": "agent", "agent_id": "ai:charlie",
                 "container": "a2a-node-3", "private_ip": "10.88.1.13"},
                {"index": 4, "role": "memory-only",
                 "container": "a2a-node-4", "private_ip": "10.88.1.14"},
            ],
        },
        "scenarios_requested": [s.get("scenario") for s in scenarios],
        "timing": {"start": start_ts, "end": end_ts},
        "ci": {"runner": "local-docker", "operator": "AI NHI (Claude Opus 4.7)"},
    },
}
(run_dir / "a2a-summary.json").write_text(json.dumps(summary, indent=2))

# campaign.meta.json mirrors the DO workflow's separate meta file.
(run_dir / "campaign.meta.json").write_text(json.dumps(summary["meta"], indent=2))
print(f"summary: overall_pass={overall_pass} scenarios={len(scenarios)} reasons={len(reasons)}", file=sys.stderr)
PY

# --- Generate index.html via existing Pages script ------------------
if [ -x "$REPO_ROOT/scripts/generate_run_html.sh" ]; then
  log "rendering index.html"
  bash "$REPO_ROOT/scripts/generate_run_html.sh" "$RUN_DIR" || log "WARN: generate_run_html.sh non-zero"
fi

log "RUN DONE — $RUN_DIR"
log "  overall_pass=$(jq -r '.overall_pass' "$RUN_DIR/a2a-summary.json")"
log "  pass/total: $(jq -r '[.scenarios[] | select(.pass==true)] | length' "$RUN_DIR/a2a-summary.json") / $(jq -r '.scenarios | length' "$RUN_DIR/a2a-summary.json")"
