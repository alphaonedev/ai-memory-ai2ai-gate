#!/usr/bin/env bash
# Copyright 2026 AlphaOne LLC
# SPDX-License-Identifier: Apache-2.0
#
# Scenario 12 — Agent registration (Task 1.3).
#
# alice on node-1 calls memory_agent_register for a new agent
# identity "ai:dave-probe-<uuid>". After settle, bob on node-2,
# charlie on node-3, and node-4 aggregator must all see ai:dave
# in their memory_agent_list response.
#
# Tests Task 1.3 agent registration shipped in v0.6.0.

set -euo pipefail

: "${NODE1_IP:?}"; : "${NODE2_IP:?}"; : "${NODE3_IP:?}"; : "${NODE4_IP:?}"; : "${AGENT_GROUP:?}"
log() { printf '[scenario-12 %s] %s\n' "$AGENT_GROUP" "$*" >&2; }

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

DAVE_ID="ai:dave-probe-$(cat /proc/sys/kernel/random/uuid 2>/dev/null | cut -c1-8)"
DAVE_NS="_agent_registry_test"

log "alice registers new agent $DAVE_ID on node-1"
# RegisterAgentBody schema (ai-memory-mcp src/handlers.rs:407):
# required: agent_id (String), agent_type (String)
# optional: capabilities (Vec<String>)
# `namespace` and `scope` are NOT part of this endpoint — prior scenario
# versions sent them and got HTTP 422 Unprocessable Entity.
register_result=$(ssh $SSH_OPTS root@"$NODE1_IP" \
  "curl -sS -X POST 'http://127.0.0.1:9077/api/v1/agents' \
    -H 'X-Agent-Id: ai:alice' -H 'Content-Type: application/json' \
    -d '{\"agent_id\":\"$DAVE_ID\",\"agent_type\":\"probe\",\"capabilities\":[\"memory_store\",\"memory_recall\"]}' \
    -w '\\n%{http_code}'" 2>/dev/null)
register_code=$(echo "$register_result" | tail -1)
log "  POST /api/v1/agents returned HTTP $register_code"
sleep 10

# Query memory_agent_list on every peer.
declare -A SEES
for trip in node-2:$NODE2_IP node-3:$NODE3_IP node-4:$NODE4_IP; do
  name=${trip%%:*}; ip=${trip##*:}
  hit=$(ssh $SSH_OPTS root@"$ip" \
    "curl -sS 'http://127.0.0.1:9077/api/v1/agents?limit=100' \
      | jq --arg a '$DAVE_ID' '[.agents[]? // .[]? | select((.agent_id // .id // \"\") == \$a)] | length'" \
    2>/dev/null | tail -1)
  hit=${hit:-0}
  SEES[$name]=$hit
  log "  $name sees $DAVE_ID registered: $hit (expected >=1)"
done

# Verdict.
PASS=true
REASONS=()
if [ "$register_code" != "200" ] && [ "$register_code" != "201" ]; then
  PASS=false
  REASONS+=("register POST returned HTTP $register_code — endpoint may not exist in this ai-memory version")
fi
for name in node-2 node-3 node-4; do
  [ "${SEES[$name]:-0}" -ge 1 ] 2>/dev/null || { PASS=false; REASONS+=("$name did not see registered agent $DAVE_ID"); }
done

jq -n \
  --arg pass "$PASS" \
  --arg agent_group "$AGENT_GROUP" \
  --arg dave_id "$DAVE_ID" \
  --arg register_code "$register_code" \
  --argjson n2 "${SEES[node-2]:-0}" --argjson n3 "${SEES[node-3]:-0}" --argjson n4 "${SEES[node-4]:-0}" \
  --argjson reasons "$(printf '%s\n' "${REASONS[@]:-}" | jq -R . | jq -s 'map(select(. != ""))')" \
  '{scenario:"12", pass:($pass=="true"), agent_group:$agent_group,
    registered_agent:$dave_id,
    register_http_code:$register_code,
    peers_see:{node_2:$n2, node_3:$n3, node_4:$n4},
    reasons:$reasons}'

$PASS || exit 1
