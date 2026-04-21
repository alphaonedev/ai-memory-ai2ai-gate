#!/usr/bin/env bash
# Copyright 2026 AlphaOne LLC
# SPDX-License-Identifier: Apache-2.0
#
# Scenario 18 — Semantic query expansion.
#
# alice and bob write memories with semantically related but not
# literally-keyword-overlapping content. charlie issues a semantic
# recall and must see both.
#
# Tests the semantic tier (HNSW + embedder) across the federated
# mesh. If this fails while S1b passes, the embedding layer is
# broken but the substrate CRUD is fine.

set -euo pipefail

: "${NODE1_IP:?}"; : "${NODE2_IP:?}"; : "${NODE3_IP:?}"; : "${AGENT_GROUP:?}"
log() { printf '[scenario-18 %s] %s\n' "$AGENT_GROUP" "$*" >&2; }

NS="scenario18-semantic"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

TAG_A="alice-sunrise-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo $RANDOM)"
TAG_B="bob-daybreak-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo $RANDOM)"
# Both contents describe morning/dawn activities WITHOUT literal keyword overlap.
CONTENT_A="Lyra starts every sunrise by walking the hills before most people are awake. Marker=$TAG_A"
CONTENT_B="Before dawn Lyra enjoys brisk uphill strides along the ridge line trails. Marker=$TAG_B"
QUERY="morning outdoor exercise routine"

log "alice writes A on node-1"
# Storage tier is one of {short, mid, long} in ai-memory (see CLAUDE.md
# §Architecture). The prior "semantic" value is a FEATURE tier (keyword/
# semantic/smart/autonomous — a recall-pipeline config, not a storage
# tier). ai-memory silently defaults unknown tier strings to Mid, but
# sending "long" here is explicit + keeps the memory past the default
# mid-tier TTL through the settle + query phases.
ssh $SSH_OPTS root@"$NODE1_IP" \
  "curl -sS -X POST 'http://127.0.0.1:9077/api/v1/memories' \
    -H 'X-Agent-Id: ai:alice' -H 'Content-Type: application/json' \
    -d '{\"tier\":\"long\",\"namespace\":\"$NS\",\"title\":\"dawn-walk\",\"content\":\"$CONTENT_A\",\"priority\":5,\"confidence\":1.0,\"source\":\"api\",\"metadata\":{\"agent_id\":\"ai:alice\",\"scenario\":\"18\"}}'" \
  >/dev/null

log "bob writes B on node-2"
ssh $SSH_OPTS root@"$NODE2_IP" \
  "curl -sS -X POST 'http://127.0.0.1:9077/api/v1/memories' \
    -H 'X-Agent-Id: ai:bob' -H 'Content-Type: application/json' \
    -d '{\"tier\":\"long\",\"namespace\":\"$NS\",\"title\":\"ridge-strides\",\"content\":\"$CONTENT_B\",\"priority\":5,\"confidence\":1.0,\"source\":\"api\",\"metadata\":{\"agent_id\":\"ai:bob\",\"scenario\":\"18\"}}'" \
  >/dev/null

log "settle 15s for fanout + index rebuild"
sleep 15

# charlie issues a semantic recall. RecallQuery reads the query string
# as `?context=<text>` (ai-memory-mcp src/models.rs:210); the prior `?q=`
# silently left context=None → HTTP 400 "context is required" → empty
# .memories[] → both markers counted as unseen → false negative.
log "charlie queries on node-3 with semantically-related prompt"
query_url="http://127.0.0.1:9077/api/v1/recall?context=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$QUERY")&namespace=$NS&limit=20"
resp=$(ssh $SSH_OPTS root@"$NODE3_IP" \
  "curl -sS '$query_url'" 2>/dev/null)
# Count the markers — both TAG_A and TAG_B should appear in the top results.
saw_a=$(echo "$resp" | jq --arg t "$TAG_A" '[.memories[]? // .[]? | select((.content // "") | contains($t))] | length' 2>/dev/null || echo 0)
saw_b=$(echo "$resp" | jq --arg t "$TAG_B" '[.memories[]? // .[]? | select((.content // "") | contains($t))] | length' 2>/dev/null || echo 0)
saw_a=${saw_a:-0}; saw_b=${saw_b:-0}
log "  charlie sees alice's memory: $saw_a (expected >=1)"
log "  charlie sees bob's memory: $saw_b (expected >=1)"

# Verdict.
PASS=true
REASONS=()
[ "$saw_a" -ge 1 ] 2>/dev/null || { PASS=false; REASONS+=("semantic query did not surface alice's memory"); }
[ "$saw_b" -ge 1 ] 2>/dev/null || { PASS=false; REASONS+=("semantic query did not surface bob's memory"); }

jq -n \
  --arg pass "$PASS" \
  --arg agent_group "$AGENT_GROUP" \
  --arg query "$QUERY" \
  --arg tag_a "$TAG_A" --arg tag_b "$TAG_B" \
  --argjson saw_a "$saw_a" --argjson saw_b "$saw_b" \
  --argjson reasons "$(printf '%s\n' "${REASONS[@]:-}" | jq -R . | jq -s 'map(select(. != ""))')" \
  '{scenario:"18", pass:($pass=="true"), agent_group:$agent_group,
    query:$query,
    writers:[{agent:"ai:alice", marker:$tag_a, seen_by_charlie:$saw_a},
             {agent:"ai:bob",   marker:$tag_b, seen_by_charlie:$saw_b}],
    reasons:$reasons}'

$PASS || exit 1
