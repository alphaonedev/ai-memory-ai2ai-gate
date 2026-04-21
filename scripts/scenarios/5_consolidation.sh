#!/usr/bin/env bash
# Copyright 2026 AlphaOne LLC
# SPDX-License-Identifier: Apache-2.0
#
# Scenario 5 — Consolidation + curation.
#
# All 3 agents write 3 related memories each to scenario5-consolidate
# (9 rows total). A consolidate call is issued against the namespace.
# After settle, all 3 original writers' agent_ids must appear in the
# consolidated memory's metadata.consolidated_from_agents field.

set -euo pipefail

: "${NODE1_IP:?}"; : "${NODE2_IP:?}"; : "${NODE3_IP:?}"; : "${NODE4_IP:?}"; : "${AGENT_GROUP:?}"
log() { printf '[scenario-5 %s] %s\n' "$AGENT_GROUP" "$*" >&2; }

NS="scenario5-consolidate"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

# Each agent writes 3 related memories.
log "phase A: each agent writes 3 related memories"
for trip in ai:alice:$NODE1_IP ai:bob:$NODE2_IP ai:charlie:$NODE3_IP; do
  aid=${trip%:*}; ip=${trip##*:}
  log "  $aid on $ip"
  for i in 1 2 3; do
    u=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "c-$aid-$i-$RANDOM")
    ssh $SSH_OPTS root@"$ip" \
      "curl -sS -X POST 'http://127.0.0.1:9077/api/v1/memories' \
        -H 'X-Agent-Id: $aid' -H 'Content-Type: application/json' \
        -d '{\"tier\":\"mid\",\"namespace\":\"$NS\",\"title\":\"c-$aid-$i\",\"content\":\"observation $i from $aid: $u\",\"priority\":5,\"confidence\":1.0,\"source\":\"api\",\"metadata\":{\"agent_id\":\"$aid\",\"scenario\":\"5\"}}'" \
      >/dev/null
  done
done
sleep 8

# Trigger consolidation via HTTP.
log "phase B: trigger memory_consolidate on node-1"
consolidate_result=$(ssh $SSH_OPTS root@"$NODE1_IP" \
  "curl -sS -X POST 'http://127.0.0.1:9077/api/v1/memories/consolidate' \
    -H 'X-Agent-Id: ai:alice' -H 'Content-Type: application/json' \
    -d '{\"namespace\":\"$NS\"}' -w '\\n%{http_code}'" 2>/dev/null)
cons_code=$(echo "$consolidate_result" | tail -1)
cons_body=$(echo "$consolidate_result" | head -n -1)
log "  consolidate returned HTTP $cons_code"
consolidated_id=$(echo "$cons_body" | jq -r '.id // .memory_id // .consolidated_memory_id // empty' 2>/dev/null || true)
log "  consolidated memory id=$consolidated_id"
sleep 10

# Verify consolidated memory metadata on node-4 (aggregator).
log "phase C: verifying consolidated_from_agents on node-4"
agents_field=''
if [ -n "$consolidated_id" ]; then
  agents_field=$(ssh $SSH_OPTS root@"$NODE4_IP" \
    "curl -sS 'http://127.0.0.1:9077/api/v1/memories/$consolidated_id' \
      | jq -c '.metadata.consolidated_from_agents // .metadata.consolidated_from // []'" \
    2>/dev/null | tail -1)
fi
log "  consolidated_from_agents=$agents_field"

# Check all 3 writers are present.
has_alice=$(echo "$agents_field" | jq 'index("ai:alice")' 2>/dev/null || echo null)
has_bob=$(echo "$agents_field" | jq 'index("ai:bob")' 2>/dev/null || echo null)
has_charlie=$(echo "$agents_field" | jq 'index("ai:charlie")' 2>/dev/null || echo null)

# Verdict.
PASS=true
REASONS=()
if [ "$cons_code" != "200" ] && [ "$cons_code" != "201" ]; then
  PASS=false
  REASONS+=("consolidate endpoint returned HTTP $cons_code — may not exist in this ai-memory version")
fi
if [ -z "$consolidated_id" ]; then
  PASS=false
  REASONS+=("consolidate did not return a new memory id")
fi
[ "$has_alice" != "null" ] 2>/dev/null || { PASS=false; REASONS+=("consolidated_from_agents missing ai:alice"); }
[ "$has_bob" != "null" ] 2>/dev/null || { PASS=false; REASONS+=("consolidated_from_agents missing ai:bob"); }
[ "$has_charlie" != "null" ] 2>/dev/null || { PASS=false; REASONS+=("consolidated_from_agents missing ai:charlie"); }

jq -n \
  --arg pass "$PASS" \
  --arg agent_group "$AGENT_GROUP" \
  --arg consolidated_id "$consolidated_id" \
  --arg cons_code "$cons_code" \
  --arg agents_field "$agents_field" \
  --argjson reasons "$(printf '%s\n' "${REASONS[@]:-}" | jq -R . | jq -s 'map(select(. != ""))')" \
  '{scenario:"5", pass:($pass=="true"), agent_group:$agent_group,
    consolidated_id:$consolidated_id,
    consolidate_http_code:$cons_code,
    consolidated_from_agents:$agents_field,
    reasons:$reasons}'

$PASS || exit 1
