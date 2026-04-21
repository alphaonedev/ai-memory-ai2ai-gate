#!/usr/bin/env bash
# Copyright 2026 AlphaOne LLC
# SPDX-License-Identifier: Apache-2.0
#
# Scenario 9 — Mutation round-trip.
#
# alice writes M1 with content "v1". bob issues a memory_update
# against M1 setting content="v2". charlie (uninvolved third agent)
# reads M1 and verifies:
#   1. Content is v2 (update propagated)
#   2. metadata.agent_id is STILL ai:alice (Task 1.2 immutability —
#      the original writer's identity is never overwritten)

set -euo pipefail

: "${NODE1_IP:?}"; : "${NODE2_IP:?}"; : "${NODE3_IP:?}"; : "${AGENT_GROUP:?}"
log() { printf '[scenario-9 %s] %s\n' "$AGENT_GROUP" "$*" >&2; }

NS="scenario9-mutation"
V1_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "v1-$RANDOM")
V2_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "v2-$RANDOM")
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

# alice writes M1 with content=v1.
log "alice writes M1 content=$V1_UUID on node-1"
m1_id=$(ssh $SSH_OPTS root@"$NODE1_IP" \
  "curl -sS -X POST 'http://127.0.0.1:9077/api/v1/memories' \
    -H 'X-Agent-Id: ai:alice' -H 'Content-Type: application/json' \
    -d '{\"tier\":\"mid\",\"namespace\":\"$NS\",\"title\":\"m1\",\"content\":\"$V1_UUID\",\"priority\":5,\"confidence\":1.0,\"source\":\"api\",\"metadata\":{\"agent_id\":\"ai:alice\",\"scenario\":\"9\"}}' \
    | jq -r '.id // .memory_id // empty'" 2>/dev/null | tail -1)
log "  created memory id=$m1_id"
sleep 5

# bob issues update against M1 setting content=v2.
log "bob updates M1 content=$V2_UUID on node-2 via PUT"
update_result=$(ssh $SSH_OPTS root@"$NODE2_IP" \
  "curl -sS -X PUT 'http://127.0.0.1:9077/api/v1/memories/$m1_id' \
    -H 'X-Agent-Id: ai:bob' -H 'Content-Type: application/json' \
    -d '{\"content\":\"$V2_UUID\"}' -w '\\n%{http_code}'" 2>/dev/null)
update_code=$(echo "$update_result" | tail -1)
log "  PUT returned HTTP $update_code"
sleep 8

# charlie reads M1 on node-3.
log "charlie reads M1 on node-3 and checks content + provenance"
charlie_view=$(ssh $SSH_OPTS root@"$NODE3_IP" \
  "curl -sS 'http://127.0.0.1:9077/api/v1/memories/$m1_id' \
    | jq -c '{content:(.memory.content // \"\"), agent_id:(.memory.metadata.agent_id // \"\")}'" 2>/dev/null | tail -1)
charlie_content=$(echo "$charlie_view" | jq -r '.content // ""')
charlie_agent_id=$(echo "$charlie_view" | jq -r '.agent_id // ""')
log "  charlie sees content=\"$charlie_content\" agent_id=\"$charlie_agent_id\""

# Verdict.
PASS=true
REASONS=()
if [ "$charlie_content" != "$V2_UUID" ]; then
  PASS=false
  REASONS+=("charlie expected content=$V2_UUID got \"$charlie_content\" (update didn't propagate)")
fi
if [ "$charlie_agent_id" != "ai:alice" ]; then
  PASS=false
  REASONS+=("metadata.agent_id changed from ai:alice to \"$charlie_agent_id\" — Task 1.2 immutability breach")
fi

jq -n \
  --arg pass "$PASS" \
  --arg agent_group "$AGENT_GROUP" \
  --arg m1_id "$m1_id" \
  --arg v1_uuid "$V1_UUID" \
  --arg v2_uuid "$V2_UUID" \
  --arg charlie_content "$charlie_content" \
  --arg charlie_agent_id "$charlie_agent_id" \
  --arg update_code "$update_code" \
  --argjson reasons "$(printf '%s\n' "${REASONS[@]:-}" | jq -R . | jq -s 'map(select(. != ""))')" \
  '{scenario:"9", pass:($pass=="true"), agent_group:$agent_group,
    m1_id:$m1_id, v1_uuid:$v1_uuid, v2_uuid:$v2_uuid,
    put_http_code:$update_code,
    charlie_view:{content:$charlie_content, agent_id:$charlie_agent_id},
    reasons:$reasons}'

$PASS || exit 1
