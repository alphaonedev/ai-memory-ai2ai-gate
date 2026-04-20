#!/usr/bin/env bash
# Copyright 2026 AlphaOne LLC
# SPDX-License-Identifier: Apache-2.0
#
# Scenario 1b — Per-agent write + read via LOCAL SERVE HTTP
# (federation-path variant of scenario 1).
#
# Exercises the SAME product-level invariant as scenario 1 (agents
# on distinct nodes can read each other's writes across the
# quorum-fanout mesh) but takes the HTTP path to the local serve
# daemon instead of the MCP stdio path.
#
# Why this variant exists: scenario 1 surfaced that ai-memory v0.6.0
# MCP stdio writes bypass the federation fanout coordinator — the
# stdio server writes to sqlite and exits, never invoking serve's
# quorum-write handler. That's a real substrate finding and stays
# RED as the honest signal. Scenario 1b targets the same agents on
# the same federated mesh but writes through the serve HTTP API
# (which DOES trigger fanout), giving us a green-path proof that
# federation itself works end-to-end while the MCP fix is in flight.
#
# Distinct namespace prefix (scenario1b-) so 1 and 1b can run in the
# same dispatch without collision.
#
# Inputs (env):
#   NODE1_IP / NODE2_IP / NODE3_IP  — public IPs for SSH
#   NODE4_IP                        — memory-only node (aggregator)
#   AGENT_GROUP                     — openclaw | hermes (for logs)

set -euo pipefail

: "${NODE1_IP:?}"
: "${NODE2_IP:?}"
: "${NODE3_IP:?}"
: "${NODE4_IP:?}"
: "${AGENT_GROUP:?}"

log() { printf '[scenario-1b %s] %s\n' "$AGENT_GROUP" "$*" >&2; }

WRITES_PER_AGENT=10
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o ServerAliveInterval=5"

# ---- Phase A: each agent writes through its LOCAL SERVE HTTP ------
log "phase A: each agent POSTs $WRITES_PER_AGENT memories to local serve"
for trip in a:$NODE1_IP:ai:alice b:$NODE2_IP:ai:bob c:$NODE3_IP:ai:charlie; do
  id=${trip%%:*}; rest=${trip#*:}; ip=${rest%%:*}; rest=${rest#*:}; aid=$rest
  log "  agent $aid on node-$id ($ip)"
  ssh $SSH_OPTS root@"$ip" bash -s -- "$WRITES_PER_AGENT" "$aid" <<'REMOTE'
set -e
N="$1"; AID="$2"
NS="scenario1b-$AID"
for i in $(seq 1 "$N"); do
  curl -sS -X POST "http://127.0.0.1:9077/api/v1/memories" \
    -H "X-Agent-Id: $AID" \
    -H "Content-Type: application/json" \
    -d "{\"tier\":\"mid\",\"namespace\":\"$NS\",\"title\":\"w${i}-${AID}\",\"content\":\"scenario1b write ${i} from ${AID} via HTTP\",\"priority\":5,\"confidence\":1.0,\"source\":\"api\",\"metadata\":{\"agent_id\":\"$AID\",\"scenario\":\"1b\"}}" \
    > /dev/null
done
REMOTE
done

# Federation fanout with W=2 should replicate before the settle window
# closes. 15s matches scenario 1's timing so we can compare apples-to-
# apples.
log "settle 15s for W=2/N=4 convergence"
sleep 15

# ---- Phase B: each agent reads the OTHER two namespaces -----------
# Unlike scenario 1, we bypass drive_agent.sh entirely — the question
# this scenario asks is about the substrate, not about the agent
# framework. If the memory replicates correctly, Phase B's row counts
# are exact integers (no natural-language parsing needed).
log "phase B: each reader counts rows in the OTHER two namespaces via local serve"

declare -A RECALL_COUNT
for reader_trip in n1:$NODE1_IP:ai:alice n2:$NODE2_IP:ai:bob n3:$NODE3_IP:ai:charlie; do
  rid=${reader_trip%%:*}; rest=${reader_trip#*:}; rip=${rest%%:*}; rest=${rest#*:}; raid=$rest
  sum=0
  for writer in ai:alice ai:bob ai:charlie; do
    [ "$raid" = "$writer" ] && continue
    ns="scenario1b-$writer"
    count=$(ssh $SSH_OPTS root@"$rip" \
      "curl -sS 'http://127.0.0.1:9077/api/v1/memories?namespace=$ns&limit=100' | jq -r '.memories | length'" \
      2>/dev/null | tail -1)
    count=${count:-0}
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    sum=$((sum + count))
  done
  RECALL_COUNT[$raid]=$sum
  log "  $raid sees $sum rows from the other two namespaces"
done

# ---- Phase C: cross-cluster identity verification via node-4 -------
# node-4 is memory-only (no agent) and its port 9077 is blocked to
# the public internet by the VPC firewall, so we SSH-hop and query
# 127.0.0.1. Every replicated row must carry metadata.agent_id equal
# to its writer — that's the Task 1.2 immutability invariant from
# ai-memory-mcp CLAUDE.md §Agent Identity, now checked across the
# federated mesh rather than on a single node.
log "phase C: cross-cluster identity verification via node-4"
ALL_OK=true
for writer in ai:alice ai:bob ai:charlie; do
  ns="scenario1b-$writer"
  resp=$(ssh $SSH_OPTS root@"$NODE4_IP" \
    "curl -sS 'http://127.0.0.1:9077/api/v1/memories?namespace=$ns&limit=100'" \
    2>/dev/null)
  n=$(echo "$resp" | jq '.memories | length' 2>/dev/null || echo 0)
  wrong=$(echo "$resp" | jq --arg w "$writer" '[.memories[] | select((.metadata.agent_id // "") != $w)] | length' 2>/dev/null || echo 0)
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  [[ "$wrong" =~ ^[0-9]+$ ]] || wrong=0
  log "  ns=$ns count=$n wrong_agent_id=$wrong"
  [ "$n" -eq "$WRITES_PER_AGENT" ] || { ALL_OK=false; log "  !! expected $WRITES_PER_AGENT rows, got $n"; }
  [ "$wrong" -eq 0 ] || { ALL_OK=false; log "  !! $wrong rows have wrong agent_id"; }
done

# ---- Pass / fail --------------------------------------------------
PASS=true
REASONS=()
EXPECTED=$((2 * WRITES_PER_AGENT))
for reader in ai:alice ai:bob ai:charlie; do
  got=${RECALL_COUNT[$reader]}
  (( got >= EXPECTED )) || { PASS=false; REASONS+=("$reader sees $got < $EXPECTED via serve HTTP"); }
done
[ "$ALL_OK" = "true" ] || { PASS=false; REASONS+=("cross-cluster identity check failed at node-4"); }

jq -n \
  --arg pass "$PASS" \
  --arg agent_group "$AGENT_GROUP" \
  --argjson alice_recall   "${RECALL_COUNT[ai:alice]:-0}" \
  --argjson bob_recall     "${RECALL_COUNT[ai:bob]:-0}" \
  --argjson charlie_recall "${RECALL_COUNT[ai:charlie]:-0}" \
  --argjson expected "$EXPECTED" \
  --argjson reasons "$(printf '%s\n' "${REASONS[@]}" | jq -R . | jq -s 'map(select(. != ""))')" \
  '{scenario:"1b", pass:($pass=="true"), agent_group:$agent_group,
    path:"serve-http",
    expected_per_reader:$expected,
    per_agent:{
      "ai:alice":   {recall:$alice_recall},
      "ai:bob":     {recall:$bob_recall},
      "ai:charlie": {recall:$charlie_recall}
    },
    reasons:$reasons}'

$PASS || exit 1
