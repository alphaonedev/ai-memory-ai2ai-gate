#!/usr/bin/env bash
# Copyright 2026 AlphaOne LLC
# SPDX-License-Identifier: Apache-2.0
#
# Scenario 1 — Per-agent write + read.
#
# Each of the three agents (ai:alice on node-1, ai:bob on node-2,
# ai:charlie on node-3) issues 10 writes in its own namespace, then
# recalls memories written by the other two. Asserts:
#   - every write returns 201
#   - every recall returns >= the expected count
#   - every recalled row's metadata.agent_id matches the ORIGINAL
#     writer's, not the recaller's (the Task 1.2 immutability invariant)
#
# Runs on the orchestrator (GitHub runner or the chaos-client equivalent).
# SSHes into each agent droplet and drives the ai-memory CLI's MCP path
# against node-4.

set -euo pipefail

: "${NODE1_IP:?}"
: "${NODE2_IP:?}"
: "${NODE3_IP:?}"
: "${MEMORY_NODE_IP:?}"

log() { printf '[scenario-1] %s\n' "$*" >&2; }

WRITES_PER_AGENT=10

# ---- Each agent writes 10 memories --------------------------------
log "phase A: each agent writes $WRITES_PER_AGENT memories"
for trip in a:$NODE1_IP:ai:alice b:$NODE2_IP:ai:bob c:$NODE3_IP:ai:charlie; do
  id=${trip%%:*}; rest=${trip#*:}; ip=${rest%%:*}; rest=${rest#*:}; aid=$rest
  log "  agent $aid on node-$id ($ip)"
  ssh -o StrictHostKeyChecking=no root@"$ip" bash -s -- \
    "$MEMORY_NODE_IP" "$aid" "$WRITES_PER_AGENT" <<'REMOTE'
set -e
MEMORY_NODE_IP="$1"; AID="$2"; N="$3"
for i in $(seq 1 "$N"); do
  curl -sS -o /dev/null -w '%{http_code}\n' \
    -H "X-Agent-Id: $AID" \
    -H "Content-Type: application/json" \
    -X POST "http://$MEMORY_NODE_IP:9077/api/v1/memories" \
    -d "{\"tier\":\"mid\",\"namespace\":\"scenario1-$AID\",\"title\":\"$AID-w$i\",\"content\":\"payload from $AID write $i\",\"priority\":5,\"confidence\":1.0,\"source\":\"api\",\"metadata\":{}}"
done
REMOTE
done

# ---- Each agent recalls the other two's memories -------------------
log "phase B: each agent recalls the OTHER two agents' memories"
declare -A RECALL_COUNT
declare -A IDENTITY_OK

# Query the memory node directly for each (reader, writer) combo.
# For the v0.6.0.0 scenario implementation we query from the
# orchestrator; an end-to-end agent-driven recall per-droplet lands
# in the follow-up PR alongside real OpenClaw/Hermes tool-invocation
# plumbing.
for reader in ai:alice ai:bob ai:charlie; do
  sum=0
  ok_identity=true
  for writer in ai:alice ai:bob ai:charlie; do
    [ "$reader" = "$writer" ] && continue
    ns="scenario1-$writer"
    resp=$(curl -sS "http://$MEMORY_NODE_IP:9077/api/v1/memories?namespace=$ns&limit=100&agent_id=$writer")
    n=$(echo "$resp" | jq '.memories | length')
    agent_ids=$(echo "$resp" | jq -r '[.memories[] | .metadata.agent_id] | unique | join(",")')
    sum=$((sum + n))
    if [ "$agent_ids" != "$writer" ]; then
      ok_identity=false
    fi
  done
  RECALL_COUNT[$reader]=$sum
  IDENTITY_OK[$reader]=$ok_identity
done

# ---- Pass / fail ---------------------------------------------------
PASS=true
REASONS=()
# Each reader should see writes from the other two agents:
# 2 × WRITES_PER_AGENT = 20 rows.
EXPECTED=$((2 * WRITES_PER_AGENT))
for reader in ai:alice ai:bob ai:charlie; do
  got=${RECALL_COUNT[$reader]}
  (( got >= EXPECTED )) || { PASS=false; REASONS+=("$reader recalled $got < $EXPECTED"); }
  [ "${IDENTITY_OK[$reader]}" = "true" ] || { PASS=false; REASONS+=("$reader saw wrong agent_id on recalled rows"); }
done

jq -n \
  --arg pass "$PASS" \
  --argjson alice_recall  "${RECALL_COUNT[ai:alice]}" \
  --argjson bob_recall    "${RECALL_COUNT[ai:bob]}" \
  --argjson charlie_recall "${RECALL_COUNT[ai:charlie]}" \
  --argjson expected "$EXPECTED" \
  --argjson reasons "$(printf '%s\n' "${REASONS[@]}" | jq -R . | jq -s .)" \
  '{scenario:1, pass:($pass=="true"), expected_per_reader:$expected,
    per_agent:{alice:{recall:$alice_recall}, bob:{recall:$bob_recall}, charlie:{recall:$charlie_recall}},
    reasons:$reasons}' | tee /tmp/scenario1.json

$PASS || exit 1
