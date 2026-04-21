#!/usr/bin/env bash
# Copyright 2026 AlphaOne LLC
# SPDX-License-Identifier: Apache-2.0
#
# Scenario 2 — Shared-context handoff.
#
# Proves the CORE A2A handoff primitive: Agent A drops a handoff
# memory on node-1, Agent B on node-2 picks it up within quorum
# settle, writes an acknowledgement, Agent A reads B's ack back.
#
# This is the "task handed from A to B" case — the minimum viable
# multi-agent coordination through shared memory.

set -euo pipefail

: "${NODE1_IP:?}"; : "${NODE2_IP:?}"; : "${AGENT_GROUP:?}"
log() { printf '[scenario-2 %s] %s\n' "$AGENT_GROUP" "$*" >&2; }

NS="scenario2-handoff"
HANDOFF_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "h-$RANDOM-$RANDOM")
ACK_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "a-$RANDOM-$RANDOM")
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

# Phase A: alice on node-1 writes handoff memory.
log "phase A: ai:alice writes handoff to ai:bob (uuid=$HANDOFF_UUID)"
ssh $SSH_OPTS root@"$NODE1_IP" \
  "curl -sS -X POST 'http://127.0.0.1:9077/api/v1/memories' \
    -H 'X-Agent-Id: ai:alice' -H 'Content-Type: application/json' \
    -d '{\"tier\":\"mid\",\"namespace\":\"$NS\",\"title\":\"handoff-to-bob\",\"content\":\"$HANDOFF_UUID\",\"priority\":7,\"confidence\":1.0,\"source\":\"api\",\"metadata\":{\"agent_id\":\"ai:alice\",\"scenario\":\"2\",\"role\":\"handoff\",\"target\":\"ai:bob\"}}'" \
  >/dev/null

log "settle 8s for quorum fanout"
sleep 8

# Phase B: bob on node-2 reads handoff.
log "phase B: ai:bob reads handoff on node-2"
bob_sees=$(ssh $SSH_OPTS root@"$NODE2_IP" \
  "curl -sS 'http://127.0.0.1:9077/api/v1/memories?namespace=$NS&limit=20' \
    | jq --arg u '$HANDOFF_UUID' --arg a 'ai:alice' \
      '[.memories[]? | select(.content == \$u and (.metadata.agent_id // \"\") == \$a)] | length'" \
  2>/dev/null | tail -1)
bob_sees=${bob_sees:-0}
log "  ai:bob sees $bob_sees handoff memories from ai:alice"

# Phase C: bob writes ack.
log "phase C: ai:bob writes acknowledgement (uuid=$ACK_UUID)"
ssh $SSH_OPTS root@"$NODE2_IP" \
  "curl -sS -X POST 'http://127.0.0.1:9077/api/v1/memories' \
    -H 'X-Agent-Id: ai:bob' -H 'Content-Type: application/json' \
    -d '{\"tier\":\"mid\",\"namespace\":\"$NS\",\"title\":\"ack-from-bob\",\"content\":\"$ACK_UUID\",\"priority\":7,\"confidence\":1.0,\"source\":\"api\",\"metadata\":{\"agent_id\":\"ai:bob\",\"scenario\":\"2\",\"role\":\"ack\",\"target\":\"ai:alice\"}}'" \
  >/dev/null

log "settle 8s for reverse-direction fanout"
sleep 8

# Phase D: alice reads ack.
log "phase D: ai:alice reads ack on node-1"
alice_sees=$(ssh $SSH_OPTS root@"$NODE1_IP" \
  "curl -sS 'http://127.0.0.1:9077/api/v1/memories?namespace=$NS&limit=20' \
    | jq --arg u '$ACK_UUID' --arg a 'ai:bob' \
      '[.memories[]? | select(.content == \$u and (.metadata.agent_id // \"\") == \$a)] | length'" \
  2>/dev/null | tail -1)
alice_sees=${alice_sees:-0}
log "  ai:alice sees $alice_sees ack memories from ai:bob"

# Verdict.
PASS=true
REASONS=()
[ "$bob_sees" -ge 1 ] 2>/dev/null || { PASS=false; REASONS+=("ai:bob did not see handoff from ai:alice after 8s settle"); }
[ "$alice_sees" -ge 1 ] 2>/dev/null || { PASS=false; REASONS+=("ai:alice did not see ack from ai:bob after 8s settle"); }

jq -n \
  --arg pass "$PASS" \
  --arg agent_group "$AGENT_GROUP" \
  --arg handoff_uuid "$HANDOFF_UUID" \
  --arg ack_uuid "$ACK_UUID" \
  --argjson bob_sees "$bob_sees" \
  --argjson alice_sees "$alice_sees" \
  --argjson reasons "$(printf '%s\n' "${REASONS[@]:-}" | jq -R . | jq -s 'map(select(. != ""))')" \
  '{scenario:"2", pass:($pass=="true"), agent_group:$agent_group,
    path:"serve-http",
    per_agent: { "ai:bob": {sees_handoff:$bob_sees}, "ai:alice": {sees_ack:$alice_sees} },
    handoff_uuid:$handoff_uuid, ack_uuid:$ack_uuid,
    reasons:$reasons}'

$PASS || exit 1
