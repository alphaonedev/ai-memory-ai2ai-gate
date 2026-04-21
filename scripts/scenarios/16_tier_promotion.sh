#!/usr/bin/env bash
# Copyright 2026 AlphaOne LLC
# SPDX-License-Identifier: Apache-2.0
#
# Scenario 16 — Tier promotion across peers.
#
# alice writes M1 at tier=short on node-1. After settle, alice
# promotes M1 to tier=long. After settle, bob on node-2 reads M1
# and must see tier=long.

set -euo pipefail

: "${NODE1_IP:?}"; : "${NODE2_IP:?}"; : "${AGENT_GROUP:?}"
log() { printf '[scenario-16 %s] %s\n' "$AGENT_GROUP" "$*" >&2; }

NS="scenario16-tier"
UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "t-$RANDOM")
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

log "alice writes M1 tier=short on node-1"
m1_id=$(ssh $SSH_OPTS root@"$NODE1_IP" \
  "curl -sS -X POST 'http://127.0.0.1:9077/api/v1/memories' \
    -H 'X-Agent-Id: ai:alice' -H 'Content-Type: application/json' \
    -d '{\"tier\":\"short\",\"namespace\":\"$NS\",\"title\":\"t1\",\"content\":\"$UUID\",\"priority\":5,\"confidence\":1.0,\"source\":\"api\",\"metadata\":{\"agent_id\":\"ai:alice\",\"scenario\":\"16\"}}' \
    | jq -r '.id // .memory_id // empty'" 2>/dev/null | tail -1)
log "  M1 id=$m1_id"
sleep 5

log "alice promotes M1 to tier=long"
promote_result=$(ssh $SSH_OPTS root@"$NODE1_IP" \
  "curl -sS -X POST 'http://127.0.0.1:9077/api/v1/memories/$m1_id/promote' \
    -H 'X-Agent-Id: ai:alice' -H 'Content-Type: application/json' \
    -d '{\"tier\":\"long\"}' -w '\\n%{http_code}'" 2>/dev/null)
promote_code=$(echo "$promote_result" | tail -1)
log "  promote returned HTTP $promote_code"
sleep 8

# bob reads and checks tier.
log "bob reads M1 on node-2 and checks tier"
bob_tier=$(ssh $SSH_OPTS root@"$NODE2_IP" \
  "curl -sS 'http://127.0.0.1:9077/api/v1/memories/$m1_id' \
    | jq -r '.tier // \"(missing)\"'" 2>/dev/null | tail -1)
log "  bob sees tier=$bob_tier (expected long)"

# Verdict.
PASS=true
REASONS=()
if [ "$promote_code" != "200" ] && [ "$promote_code" != "204" ]; then
  PASS=false
  REASONS+=("promote endpoint returned HTTP $promote_code — may not exist in v0.6.0")
fi
if [ "$bob_tier" != "long" ]; then
  PASS=false
  REASONS+=("bob sees tier=\"$bob_tier\", expected \"long\"")
fi

jq -n \
  --arg pass "$PASS" \
  --arg agent_group "$AGENT_GROUP" \
  --arg m1_id "$m1_id" \
  --arg promote_code "$promote_code" \
  --arg bob_tier "$bob_tier" \
  --argjson reasons "$(printf '%s\n' "${REASONS[@]:-}" | jq -R . | jq -s 'map(select(. != ""))')" \
  '{scenario:"16", pass:($pass=="true"), agent_group:$agent_group,
    m1_id:$m1_id, promote_http_code:$promote_code, bob_sees_tier:$bob_tier,
    reasons:$reasons}'

$PASS || exit 1
