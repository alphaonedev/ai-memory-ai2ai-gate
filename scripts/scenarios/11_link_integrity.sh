#!/usr/bin/env bash
# Copyright 2026 AlphaOne LLC
# SPDX-License-Identifier: Apache-2.0
#
# Scenario 11 — Link integrity.
#
# alice writes M1 on node-1. bob writes M2 on node-2. alice issues
# memory_link linking M1 -> M2 with relation "related_to". After
# settle, charlie on node-3 queries links for M1 and must see M2 in
# the response.

set -euo pipefail

: "${NODE1_IP:?}"; : "${NODE2_IP:?}"; : "${NODE3_IP:?}"; : "${AGENT_GROUP:?}"
log() { printf '[scenario-11 %s] %s\n' "$AGENT_GROUP" "$*" >&2; }

NS="scenario11-link"
M1_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "l1-$RANDOM")
M2_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "l2-$RANDOM")
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

log "alice writes M1 on node-1"
m1_id=$(ssh $SSH_OPTS root@"$NODE1_IP" \
  "curl -sS -X POST 'http://127.0.0.1:9077/api/v1/memories' \
    -H 'X-Agent-Id: ai:alice' -H 'Content-Type: application/json' \
    -d '{\"tier\":\"mid\",\"namespace\":\"$NS\",\"title\":\"m1\",\"content\":\"$M1_UUID\",\"priority\":5,\"confidence\":1.0,\"source\":\"api\",\"metadata\":{\"agent_id\":\"ai:alice\",\"scenario\":\"11\"}}' \
    | jq -r '.id // .memory_id // empty'" 2>/dev/null | tail -1)

log "bob writes M2 on node-2"
m2_id=$(ssh $SSH_OPTS root@"$NODE2_IP" \
  "curl -sS -X POST 'http://127.0.0.1:9077/api/v1/memories' \
    -H 'X-Agent-Id: ai:bob' -H 'Content-Type: application/json' \
    -d '{\"tier\":\"mid\",\"namespace\":\"$NS\",\"title\":\"m2\",\"content\":\"$M2_UUID\",\"priority\":5,\"confidence\":1.0,\"source\":\"api\",\"metadata\":{\"agent_id\":\"ai:bob\",\"scenario\":\"11\"}}' \
    | jq -r '.id // .memory_id // empty'" 2>/dev/null | tail -1)
log "  M1=$m1_id M2=$m2_id"
sleep 5

# alice creates link M1 -> M2.
log "alice links M1 -> M2 with relation=related_to"
link_result=$(ssh $SSH_OPTS root@"$NODE1_IP" \
  "curl -sS -X POST 'http://127.0.0.1:9077/api/v1/memories/$m1_id/links' \
    -H 'X-Agent-Id: ai:alice' -H 'Content-Type: application/json' \
    -d '{\"to\":\"$m2_id\",\"relation\":\"related_to\"}' -w '\\n%{http_code}'" 2>/dev/null)
link_code=$(echo "$link_result" | tail -1)
log "  link POST returned HTTP $link_code"
sleep 8

# charlie queries links of M1 on node-3.
log "charlie queries links of M1 on node-3"
links_resp=$(ssh $SSH_OPTS root@"$NODE3_IP" \
  "curl -sS 'http://127.0.0.1:9077/api/v1/memories/$m1_id/links'" 2>/dev/null)
sees_m2=$(echo "$links_resp" | jq --arg id "$m2_id" '[.links[]? // .[]? | select((.to // .target // "") == $id)] | length' 2>/dev/null || echo 0)
sees_m2=${sees_m2:-0}
log "  charlie sees M1->M2 link: $sees_m2 (expected >=1)"

# Verdict.
PASS=true
REASONS=()
if [ "$link_code" != "200" ] && [ "$link_code" != "201" ]; then
  PASS=false
  REASONS+=("link POST returned HTTP $link_code — endpoint may not exist in this ai-memory version")
fi
[ "$sees_m2" -ge 1 ] 2>/dev/null || { PASS=false; REASONS+=("charlie could not see M1->M2 link after settle"); }

jq -n \
  --arg pass "$PASS" \
  --arg agent_group "$AGENT_GROUP" \
  --arg m1_id "$m1_id" --arg m2_id "$m2_id" \
  --arg link_code "$link_code" \
  --argjson charlie_sees "$sees_m2" \
  --argjson reasons "$(printf '%s\n' "${REASONS[@]:-}" | jq -R . | jq -s 'map(select(. != ""))')" \
  '{scenario:"11", pass:($pass=="true"), agent_group:$agent_group,
    m1_id:$m1_id, m2_id:$m2_id, relation:"related_to",
    link_http_code:$link_code, charlie_sees_link:$charlie_sees,
    reasons:$reasons}'

$PASS || exit 1
