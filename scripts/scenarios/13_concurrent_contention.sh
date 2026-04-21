#!/usr/bin/env bash
# Copyright 2026 AlphaOne LLC
# SPDX-License-Identifier: Apache-2.0
#
# Scenario 13 — Concurrent write contention.
#
# alice and bob concurrently PATCH the same memory M1. After settle,
# all 4 peers (including node-4 aggregator) must return the SAME
# final content. Whether the resolution is LWW, CRDT, or vector-
# clocked doesn't matter at this layer — what matters is consistency:
# no split-brain.

set -euo pipefail

: "${NODE1_IP:?}"; : "${NODE2_IP:?}"; : "${NODE3_IP:?}"; : "${NODE4_IP:?}"; : "${AGENT_GROUP:?}"
log() { printf '[scenario-13 %s] %s\n' "$AGENT_GROUP" "$*" >&2; }

NS="scenario13-contention"
V0_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "v0-$RANDOM")
VA_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "va-$RANDOM")
VB_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "vb-$RANDOM")
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

# alice writes initial M1.
log "alice writes M1 content=v0 on node-1"
m1_id=$(ssh $SSH_OPTS root@"$NODE1_IP" \
  "curl -sS -X POST 'http://127.0.0.1:9077/api/v1/memories' \
    -H 'X-Agent-Id: ai:alice' -H 'Content-Type: application/json' \
    -d '{\"tier\":\"mid\",\"namespace\":\"$NS\",\"title\":\"m1\",\"content\":\"$V0_UUID\",\"priority\":5,\"confidence\":1.0,\"source\":\"api\",\"metadata\":{\"agent_id\":\"ai:alice\",\"scenario\":\"13\"}}' \
    | jq -r '.id // .memory_id // empty'" 2>/dev/null | tail -1)
log "  M1 id=$m1_id"
sleep 5

# Concurrent PATCH from alice and bob.
log "alice + bob issue concurrent PATCHes (vA=$VA_UUID from alice, vB=$VB_UUID from bob)"
(
  ssh $SSH_OPTS root@"$NODE1_IP" \
    "curl -sS -X PATCH 'http://127.0.0.1:9077/api/v1/memories/$m1_id' \
      -H 'X-Agent-Id: ai:alice' -H 'Content-Type: application/json' \
      -d '{\"content\":\"$VA_UUID\"}' >/dev/null" &
  ssh $SSH_OPTS root@"$NODE2_IP" \
    "curl -sS -X PATCH 'http://127.0.0.1:9077/api/v1/memories/$m1_id' \
      -H 'X-Agent-Id: ai:bob' -H 'Content-Type: application/json' \
      -d '{\"content\":\"$VB_UUID\"}' >/dev/null" &
  wait
)
log "settle 10s for quorum convergence"
sleep 10

# Query each peer.
declare -A CONTENTS
for trip in node-1:$NODE1_IP node-2:$NODE2_IP node-3:$NODE3_IP node-4:$NODE4_IP; do
  name=${trip%%:*}; ip=${trip##*:}
  c=$(ssh $SSH_OPTS root@"$ip" \
    "curl -sS 'http://127.0.0.1:9077/api/v1/memories/$m1_id' \
      | jq -r '.content // \"(none)\"'" 2>/dev/null | tail -1)
  CONTENTS[$name]=$c
  log "  $name sees content=$c"
done

# Verdict: all 4 must agree on ONE value (either VA or VB or a merged value).
unique_vals=$(printf '%s\n' "${CONTENTS[@]}" | sort -u | wc -l | tr -d ' ')
PASS=true
REASONS=()
if [ "$unique_vals" != "1" ]; then
  PASS=false
  REASONS+=("split-brain: peers disagree — node-1=${CONTENTS[node-1]:-?} node-2=${CONTENTS[node-2]:-?} node-3=${CONTENTS[node-3]:-?} node-4=${CONTENTS[node-4]:-?}")
fi
# Also: the winning content should be ONE of the submitted values (not v0, not a nullified merge).
winning="${CONTENTS[node-1]:-}"
if [ "$winning" = "$V0_UUID" ] || [ -z "$winning" ] || [ "$winning" = "(none)" ]; then
  PASS=false
  REASONS+=("winning content is not one of the submitted PATCH values: got \"$winning\"")
fi

jq -n \
  --arg pass "$PASS" \
  --arg agent_group "$AGENT_GROUP" \
  --arg m1_id "$m1_id" \
  --arg v0 "$V0_UUID" --arg va "$VA_UUID" --arg vb "$VB_UUID" \
  --arg n1 "${CONTENTS[node-1]:-}" --arg n2 "${CONTENTS[node-2]:-}" \
  --arg n3 "${CONTENTS[node-3]:-}" --arg n4 "${CONTENTS[node-4]:-}" \
  --argjson reasons "$(printf '%s\n' "${REASONS[@]:-}" | jq -R . | jq -s 'map(select(. != ""))')" \
  '{scenario:"13", pass:($pass=="true"), agent_group:$agent_group,
    m1_id:$m1_id,
    submitted:{v0:$v0, vA_alice:$va, vB_bob:$vb},
    peer_view:{node_1:$n1, node_2:$n2, node_3:$n3, node_4:$n4},
    reasons:$reasons}'

$PASS || exit 1
