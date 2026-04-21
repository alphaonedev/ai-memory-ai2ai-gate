#!/usr/bin/env bash
# Copyright 2026 AlphaOne LLC
# SPDX-License-Identifier: Apache-2.0
#
# Scenario 14 — Partition tolerance.
#
# Suspend node-3's ai-memory serve process (SIGSTOP). While node-3
# is "out", alice and bob write memories — W=2 quorum of (alice+bob)
# is still satisfiable. Resume node-3 (SIGCONT). After settle,
# node-3 must see all the writes made during its outage.
#
# This is the A2A-level regression test for PR #309 (post-quorum
# fanout fix that landed in v0.6.0).

set -euo pipefail

: "${NODE1_IP:?}"; : "${NODE2_IP:?}"; : "${NODE3_IP:?}"; : "${AGENT_GROUP:?}"
log() { printf '[scenario-14 %s] %s\n' "$AGENT_GROUP" "$*" >&2; }

NS="scenario14-partition"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
WRITES=10

# Suspend node-3 ai-memory.
log "suspending ai-memory on node-3 (SIGSTOP)"
ssh $SSH_OPTS root@"$NODE3_IP" \
  "pgrep -f 'ai-memory serve' | xargs -r kill -STOP" 2>/dev/null || true
sleep 2

# alice + bob write during partition.
log "writing $WRITES memories each from alice + bob during node-3 outage"
declare -a UUIDS
for i in $(seq 1 $WRITES); do
  u_alice=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "pa-$i-$RANDOM")
  u_bob=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "pb-$i-$RANDOM")
  UUIDS+=("$u_alice" "$u_bob")
  ssh $SSH_OPTS root@"$NODE1_IP" \
    "curl -sS -X POST 'http://127.0.0.1:9077/api/v1/memories' \
      -H 'X-Agent-Id: ai:alice' -H 'Content-Type: application/json' \
      -d '{\"tier\":\"mid\",\"namespace\":\"$NS\",\"title\":\"p-alice-$i\",\"content\":\"$u_alice\",\"priority\":5,\"confidence\":1.0,\"source\":\"api\",\"metadata\":{\"agent_id\":\"ai:alice\",\"scenario\":\"14\"}}' \
      >/dev/null" &
  ssh $SSH_OPTS root@"$NODE2_IP" \
    "curl -sS -X POST 'http://127.0.0.1:9077/api/v1/memories' \
      -H 'X-Agent-Id: ai:bob' -H 'Content-Type: application/json' \
      -d '{\"tier\":\"mid\",\"namespace\":\"$NS\",\"title\":\"p-bob-$i\",\"content\":\"$u_bob\",\"priority\":5,\"confidence\":1.0,\"source\":\"api\",\"metadata\":{\"agent_id\":\"ai:bob\",\"scenario\":\"14\"}}' \
      >/dev/null" &
  wait
done

log "resuming ai-memory on node-3 (SIGCONT)"
ssh $SSH_OPTS root@"$NODE3_IP" \
  "pgrep -f 'ai-memory serve' | xargs -r kill -CONT" 2>/dev/null || true

log "settle 20s for post-partition catchup"
sleep 20

# Count on node-3 — must see all 2*WRITES writes.
log "checking node-3 caught up"
node3_count=$(ssh $SSH_OPTS root@"$NODE3_IP" \
  "curl -sS 'http://127.0.0.1:9077/api/v1/memories?namespace=$NS&limit=200' \
    | jq '.memories | length'" 2>/dev/null | tail -1)
node3_count=${node3_count:-0}
expected=$((2 * WRITES))
log "  node-3 sees $node3_count memories in $NS (expected $expected)"

# Verdict.
PASS=true
REASONS=()
if [ "$node3_count" -lt "$expected" ] 2>/dev/null; then
  PASS=false
  REASONS+=("node-3 only saw $node3_count/$expected writes after partition recovery — catchup failed or W=2 wasn't satisfied during outage")
fi

jq -n \
  --arg pass "$PASS" \
  --arg agent_group "$AGENT_GROUP" \
  --argjson expected "$expected" \
  --argjson actual "$node3_count" \
  --argjson reasons "$(printf '%s\n' "${REASONS[@]:-}" | jq -R . | jq -s 'map(select(. != ""))')" \
  '{scenario:"14", pass:($pass=="true"), agent_group:$agent_group,
    partition_target:"node-3",
    expected_post_recovery:$expected, node3_saw:$actual,
    reasons:$reasons}'

$PASS || exit 1
