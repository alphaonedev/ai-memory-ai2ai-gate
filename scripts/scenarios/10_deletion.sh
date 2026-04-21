#!/usr/bin/env bash
# Copyright 2026 AlphaOne LLC
# SPDX-License-Identifier: Apache-2.0
#
# Scenario 10 — Deletion propagation.
#
# alice writes M1, confirms it's visible on all peers after settle,
# then issues DELETE. After settle, all peers (bob, charlie, and
# the node-4 aggregator) must NOT find M1.

set -euo pipefail

: "${NODE1_IP:?}"; : "${NODE2_IP:?}"; : "${NODE3_IP:?}"; : "${NODE4_IP:?}"; : "${AGENT_GROUP:?}"
log() { printf '[scenario-10 %s] %s\n' "$AGENT_GROUP" "$*" >&2; }

NS="scenario10-deletion"
UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "d-$RANDOM")
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

# alice writes M1.
log "alice writes M1 content=$UUID on node-1"
m1_id=$(ssh $SSH_OPTS root@"$NODE1_IP" \
  "curl -sS -X POST 'http://127.0.0.1:9077/api/v1/memories' \
    -H 'X-Agent-Id: ai:alice' -H 'Content-Type: application/json' \
    -d '{\"tier\":\"mid\",\"namespace\":\"$NS\",\"title\":\"m1\",\"content\":\"$UUID\",\"priority\":5,\"confidence\":1.0,\"source\":\"api\",\"metadata\":{\"agent_id\":\"ai:alice\",\"scenario\":\"10\"}}' \
    | jq -r '.id // .memory_id // empty'" 2>/dev/null | tail -1)
log "  created memory id=$m1_id"
sleep 8

# Verify M1 visible on all 3 peers + node-4 before deletion.
log "pre-delete: verifying M1 is visible on all peers"
pre_visible=0
for trip in node-2:$NODE2_IP node-3:$NODE3_IP node-4:$NODE4_IP; do
  name=${trip%%:*}; ip=${trip##*:}
  hit=$(ssh $SSH_OPTS root@"$ip" \
    "curl -sS 'http://127.0.0.1:9077/api/v1/memories?namespace=$NS&limit=20' \
      | jq --arg u '$UUID' '[.memories[]? | select(.content == \$u)] | length'" \
    2>/dev/null | tail -1)
  hit=${hit:-0}
  log "  pre-delete $name sees $hit"
  if [ "$hit" -ge 1 ] 2>/dev/null; then pre_visible=$((pre_visible + 1)); fi
done

# alice deletes M1.
log "alice deletes M1 on node-1"
delete_code=$(ssh $SSH_OPTS root@"$NODE1_IP" \
  "curl -sS -X DELETE 'http://127.0.0.1:9077/api/v1/memories/$m1_id' \
    -H 'X-Agent-Id: ai:alice' -w '%{http_code}' -o /dev/null" 2>/dev/null | tail -1)
log "  DELETE returned HTTP $delete_code"
sleep 15

# Post-delete: every peer must NOT have M1.
log "post-delete: verifying M1 is GONE from all peers"
post_visible=0
declare -A POST_HIT
for trip in node-2:$NODE2_IP node-3:$NODE3_IP node-4:$NODE4_IP; do
  name=${trip%%:*}; ip=${trip##*:}
  hit=$(ssh $SSH_OPTS root@"$ip" \
    "curl -sS 'http://127.0.0.1:9077/api/v1/memories?namespace=$NS&limit=20' \
      | jq --arg u '$UUID' '[.memories[]? | select(.content == \$u)] | length'" \
    2>/dev/null | tail -1)
  hit=${hit:-0}
  POST_HIT[$name]=$hit
  log "  post-delete $name sees $hit (expected 0)"
  if [ "$hit" -ge 1 ] 2>/dev/null; then post_visible=$((post_visible + 1)); fi
done

# Verdict.
PASS=true
REASONS=()
if [ "$pre_visible" -lt 3 ]; then
  PASS=false
  REASONS+=("only $pre_visible/3 peers saw M1 before delete — fanout issue, not a deletion bug")
fi
if [ "$post_visible" -gt 0 ]; then
  PASS=false
  REASONS+=("$post_visible/3 peers still see M1 after delete — tombstone not propagated")
fi
if [ "$delete_code" != "200" ] && [ "$delete_code" != "204" ]; then
  PASS=false
  REASONS+=("DELETE returned HTTP $delete_code — expected 200 or 204")
fi

jq -n \
  --arg pass "$PASS" \
  --arg agent_group "$AGENT_GROUP" \
  --arg m1_id "$m1_id" \
  --arg uuid "$UUID" \
  --arg delete_code "$delete_code" \
  --argjson pre_visible "$pre_visible" \
  --argjson post_visible "$post_visible" \
  --argjson reasons "$(printf '%s\n' "${REASONS[@]:-}" | jq -R . | jq -s 'map(select(. != ""))')" \
  '{scenario:"10", pass:($pass=="true"), agent_group:$agent_group,
    m1_id:$m1_id, uuid:$uuid, delete_http_code:$delete_code,
    pre_delete_visible_peers:$pre_visible, post_delete_still_visible_peers:$post_visible,
    reasons:$reasons}'

$PASS || exit 1
