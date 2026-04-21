#!/usr/bin/env bash
# Copyright 2026 AlphaOne LLC
# SPDX-License-Identifier: Apache-2.0
#
# Scenario 17 — Stats consistency across peers.
#
# All 3 agents write 5 memories to a dedicated namespace. After
# settle, query every peer's memory count for the namespace. All
# four (alice, bob, charlie, node-4) must agree on the count.

set -euo pipefail

: "${NODE1_IP:?}"; : "${NODE2_IP:?}"; : "${NODE3_IP:?}"; : "${NODE4_IP:?}"; : "${AGENT_GROUP:?}"
log() { printf '[scenario-17 %s] %s\n' "$AGENT_GROUP" "$*" >&2; }

NS="scenario17-stats"
PER_AGENT=5
EXPECTED=$((3 * PER_AGENT))
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

# Phase A: each agent writes PER_AGENT memories.
log "phase A: each of 3 agents writes $PER_AGENT memories to $NS"
for trip in ai:alice:$NODE1_IP ai:bob:$NODE2_IP ai:charlie:$NODE3_IP; do
  aid=${trip%:*}; ip=${trip##*:}
  log "  $aid on $ip"
  ssh $SSH_OPTS root@"$ip" bash -s -- "$aid" "$NS" "$PER_AGENT" <<'REMOTE'
set -e
AID="$1"; NS="$2"; N="$3"
for i in $(seq 1 "$N"); do
  u="stats-$AID-$i-$(cat /proc/sys/kernel/random/uuid)"
  # Title must include AID so UPSERT on (title, namespace) doesn't dedup
  # cross-agent writes to the same stats-N slot.
  curl -sS -X POST 'http://127.0.0.1:9077/api/v1/memories' \
    -H "X-Agent-Id: $AID" -H 'Content-Type: application/json' \
    -d "{\"tier\":\"mid\",\"namespace\":\"$NS\",\"title\":\"stats-$AID-$i\",\"content\":\"$u\",\"priority\":5,\"confidence\":1.0,\"source\":\"api\",\"metadata\":{\"agent_id\":\"$AID\",\"scenario\":\"17\"}}" \
    >/dev/null
done
REMOTE
done
log "settle 15s for W=2 fanout"
sleep 15

# Phase B: query every peer's count for the namespace.
log "phase B: querying count on every peer"
declare -A COUNTS
ALL_EQUAL=true
for trip in node-1:$NODE1_IP node-2:$NODE2_IP node-3:$NODE3_IP node-4:$NODE4_IP; do
  name=${trip%%:*}; ip=${trip##*:}
  n=$(ssh $SSH_OPTS root@"$ip" \
    "curl -sS 'http://127.0.0.1:9077/api/v1/memories?namespace=$NS&limit=200' \
      | jq '.memories | length'" \
    2>/dev/null | tail -1)
  n=${n:-0}
  COUNTS[$name]=$n
  log "  $name count=$n (expected $EXPECTED)"
done

# Check all equal and all equal expected.
vals=$(printf '%s\n' "${COUNTS[@]}" | sort -u | wc -l | tr -d ' ')
if [ "$vals" != "1" ]; then ALL_EQUAL=false; fi

# Verdict.
PASS=true
REASONS=()
[ "${COUNTS[node-1]:-0}" -eq "$EXPECTED" ] 2>/dev/null || { PASS=false; REASONS+=("node-1 count=${COUNTS[node-1]:-0} != expected $EXPECTED"); }
[ "${COUNTS[node-2]:-0}" -eq "$EXPECTED" ] 2>/dev/null || { PASS=false; REASONS+=("node-2 count=${COUNTS[node-2]:-0} != expected $EXPECTED"); }
[ "${COUNTS[node-3]:-0}" -eq "$EXPECTED" ] 2>/dev/null || { PASS=false; REASONS+=("node-3 count=${COUNTS[node-3]:-0} != expected $EXPECTED"); }
[ "${COUNTS[node-4]:-0}" -eq "$EXPECTED" ] 2>/dev/null || { PASS=false; REASONS+=("node-4 count=${COUNTS[node-4]:-0} != expected $EXPECTED"); }
[ "$ALL_EQUAL" = "true" ] || { PASS=false; REASONS+=("peer counts diverge — ${COUNTS[node-1]:-?}/${COUNTS[node-2]:-?}/${COUNTS[node-3]:-?}/${COUNTS[node-4]:-?}"); }

jq -n \
  --arg pass "$PASS" \
  --arg agent_group "$AGENT_GROUP" \
  --argjson expected "$EXPECTED" \
  --argjson n1 "${COUNTS[node-1]:-0}" \
  --argjson n2 "${COUNTS[node-2]:-0}" \
  --argjson n3 "${COUNTS[node-3]:-0}" \
  --argjson n4 "${COUNTS[node-4]:-0}" \
  --argjson reasons "$(printf '%s\n' "${REASONS[@]:-}" | jq -R . | jq -s 'map(select(. != ""))')" \
  '{scenario:"17", pass:($pass=="true"), agent_group:$agent_group,
    expected_count:$expected,
    per_peer:{node_1:$n1,node_2:$n2,node_3:$n3,node_4:$n4},
    reasons:$reasons}'

$PASS || exit 1
