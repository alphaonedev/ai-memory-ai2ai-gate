#!/usr/bin/env bash
# Copyright 2026 AlphaOne LLC
# SPDX-License-Identifier: Apache-2.0
#
# Scenario 4 — Federation-aware concurrent writes (burst).
#
# All 3 agents concurrently write 30 memories each (90 total) in a
# ~5s burst into distinct namespaces. After settle, node-4 aggregator
# must see all 30 rows per namespace with correct metadata.agent_id.
# Tests quorum preservation under load (PR #309 regression at A2A level).

set -euo pipefail

: "${NODE1_IP:?}"; : "${NODE2_IP:?}"; : "${NODE3_IP:?}"; : "${NODE4_IP:?}"; : "${AGENT_GROUP:?}"
log() { printf '[scenario-4 %s] %s\n' "$AGENT_GROUP" "$*" >&2; }

PER_AGENT=30
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

# Launch all 3 writers in parallel.
log "phase A: launching concurrent $PER_AGENT-row bursts from 3 agents"
for trip in ai:alice:$NODE1_IP ai:bob:$NODE2_IP ai:charlie:$NODE3_IP; do
  aid=${trip%:*}; ip=${trip##*:}
  (
    ssh $SSH_OPTS root@"$ip" bash -s -- "$aid" "$PER_AGENT" <<'REMOTE' 2>&1 | sed "s/^/[$aid] /"
set -e
AID="$1"; N="$2"
NS="scenario4-fed-$AID"
for i in $(seq 1 "$N"); do
  u="fed-$AID-$i-$(cat /proc/sys/kernel/random/uuid)"
  curl -sS -X POST 'http://127.0.0.1:9077/api/v1/memories' \
    -H "X-Agent-Id: $AID" -H 'Content-Type: application/json' \
    -d "{\"tier\":\"mid\",\"namespace\":\"$NS\",\"title\":\"fed-$i\",\"content\":\"$u\",\"priority\":5,\"confidence\":1.0,\"source\":\"api\",\"metadata\":{\"agent_id\":\"$AID\",\"scenario\":\"4\"}}" \
    >/dev/null &
  # burst — don't wait between writes, just limit in-flight batch
  if (( i % 10 == 0 )); then wait; fi
done
wait
REMOTE
  ) &
done
wait
log "all 3 bursts complete; settle 20s for W=2 fanout convergence"
sleep 20

# Query node-4 aggregator for each agent's namespace.
log "phase B: querying node-4 aggregator for per-agent counts"
declare -A COUNTS
declare -A WRONG_AGENT
for aid in ai:alice ai:bob ai:charlie; do
  ns="scenario4-fed-$aid"
  resp=$(ssh $SSH_OPTS root@"$NODE4_IP" \
    "curl -sS 'http://127.0.0.1:9077/api/v1/memories?namespace=$ns&limit=200'" \
    2>/dev/null)
  count=$(echo "$resp" | jq '.memories | length' 2>/dev/null || echo 0)
  wrong=$(echo "$resp" | jq --arg a "$aid" '[.memories[]? | select((.metadata.agent_id // "") != $a)] | length' 2>/dev/null || echo 0)
  COUNTS[$aid]=${count:-0}
  WRONG_AGENT[$aid]=${wrong:-0}
  log "  $aid: count=${COUNTS[$aid]} (expected $PER_AGENT) wrong_agent_id=${WRONG_AGENT[$aid]}"
done

# Verdict.
PASS=true
REASONS=()
for aid in ai:alice ai:bob ai:charlie; do
  [ "${COUNTS[$aid]:-0}" -eq "$PER_AGENT" ] 2>/dev/null || { PASS=false; REASONS+=("$aid: node-4 saw ${COUNTS[$aid]:-0} rows, expected $PER_AGENT"); }
  [ "${WRONG_AGENT[$aid]:-0}" -eq 0 ] 2>/dev/null || { PASS=false; REASONS+=("$aid: ${WRONG_AGENT[$aid]} rows have wrong agent_id"); }
done

jq -n \
  --arg pass "$PASS" \
  --arg agent_group "$AGENT_GROUP" \
  --argjson expected "$PER_AGENT" \
  --argjson alice "${COUNTS[ai:alice]:-0}" \
  --argjson bob "${COUNTS[ai:bob]:-0}" \
  --argjson charlie "${COUNTS[ai:charlie]:-0}" \
  --argjson alice_wrong "${WRONG_AGENT[ai:alice]:-0}" \
  --argjson bob_wrong "${WRONG_AGENT[ai:bob]:-0}" \
  --argjson charlie_wrong "${WRONG_AGENT[ai:charlie]:-0}" \
  --argjson reasons "$(printf '%s\n' "${REASONS[@]:-}" | jq -R . | jq -s 'map(select(. != ""))')" \
  '{scenario:"4", pass:($pass=="true"), agent_group:$agent_group,
    expected_per_agent:$expected,
    per_agent:{
      "ai:alice":   {count:$alice,   wrong_agent_id:$alice_wrong},
      "ai:bob":     {count:$bob,     wrong_agent_id:$bob_wrong},
      "ai:charlie": {count:$charlie, wrong_agent_id:$charlie_wrong}
    },
    reasons:$reasons}'

$PASS || exit 1
