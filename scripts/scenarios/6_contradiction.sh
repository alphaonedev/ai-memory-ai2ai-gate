#!/usr/bin/env bash
# Copyright 2026 AlphaOne LLC
# SPDX-License-Identifier: Apache-2.0
#
# Scenario 6 — Contradiction detection.
#
# alice writes "X is true". bob writes "X is false" (same topic,
# different claim). charlie calls memory_detect_contradiction on
# the topic and verifies both memories are returned with a
# `contradicts` link between them.

set -euo pipefail

: "${NODE1_IP:?}"; : "${NODE2_IP:?}"; : "${NODE3_IP:?}"; : "${AGENT_GROUP:?}"
log() { printf '[scenario-6 %s] %s\n' "$AGENT_GROUP" "$*" >&2; }

NS="scenario6-contradiction"
TOPIC="sky-color-$(cat /proc/sys/kernel/random/uuid 2>/dev/null | cut -c1-8)"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

log "alice writes claim: \"$TOPIC is blue\" on node-1"
m_alice=$(ssh $SSH_OPTS root@"$NODE1_IP" \
  "curl -sS -X POST 'http://127.0.0.1:9077/api/v1/memories' \
    -H 'X-Agent-Id: ai:alice' -H 'Content-Type: application/json' \
    -d '{\"tier\":\"mid\",\"namespace\":\"$NS\",\"title\":\"$TOPIC\",\"content\":\"$TOPIC is blue\",\"priority\":5,\"confidence\":1.0,\"source\":\"api\",\"metadata\":{\"agent_id\":\"ai:alice\",\"scenario\":\"6\",\"topic\":\"$TOPIC\"}}' \
    | jq -r '.id // .memory_id // empty'" 2>/dev/null | tail -1)

log "bob writes contradicting claim: \"$TOPIC is red\" on node-2"
m_bob=$(ssh $SSH_OPTS root@"$NODE2_IP" \
  "curl -sS -X POST 'http://127.0.0.1:9077/api/v1/memories' \
    -H 'X-Agent-Id: ai:bob' -H 'Content-Type: application/json' \
    -d '{\"tier\":\"mid\",\"namespace\":\"$NS\",\"title\":\"$TOPIC\",\"content\":\"$TOPIC is red\",\"priority\":5,\"confidence\":1.0,\"source\":\"api\",\"metadata\":{\"agent_id\":\"ai:bob\",\"scenario\":\"6\",\"topic\":\"$TOPIC\"}}' \
    | jq -r '.id // .memory_id // empty'" 2>/dev/null | tail -1)
log "  alice.id=$m_alice bob.id=$m_bob"
sleep 10

# charlie calls detect_contradiction on the topic.
log "charlie queries memory_detect_contradiction on node-3"
detect_url="http://127.0.0.1:9077/api/v1/contradictions?topic=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$TOPIC")&namespace=$NS"
detect_resp=$(ssh $SSH_OPTS root@"$NODE3_IP" \
  "curl -sS '$detect_url' -w '\\n%{http_code}'" 2>/dev/null)
detect_code=$(echo "$detect_resp" | tail -1)
detect_body=$(echo "$detect_resp" | head -n -1)
log "  HTTP $detect_code; body length=$(echo -n "$detect_body" | wc -c)"

sees_both=0
sees_link=0
if [ "$detect_code" = "200" ]; then
  # Try common response shapes.
  c_alice=$(echo "$detect_body" | jq --arg id "$m_alice" '[.memories[]? // .contradictions[]? | select((.id // .memory_id // "") == $id)] | length' 2>/dev/null || echo 0)
  c_bob=$(echo "$detect_body" | jq --arg id "$m_bob"   '[.memories[]? // .contradictions[]? | select((.id // .memory_id // "") == $id)] | length' 2>/dev/null || echo 0)
  if [ "${c_alice:-0}" -ge 1 ] && [ "${c_bob:-0}" -ge 1 ]; then sees_both=1; fi
  # Link check — contradicts relation present?
  c_link=$(echo "$detect_body" | jq '[.links[]? // .relations[]? | select((.relation // .type // "") | contains("contradict"))] | length' 2>/dev/null || echo 0)
  if [ "${c_link:-0}" -ge 1 ]; then sees_link=1; fi
fi

log "  sees both memories: $sees_both; sees contradicts link: $sees_link"

# Verdict.
PASS=true
REASONS=()
if [ "$detect_code" != "200" ]; then
  PASS=false
  REASONS+=("detect_contradiction endpoint returned HTTP $detect_code — may not exist in this ai-memory version")
fi
[ "$sees_both" = "1" ] || { PASS=false; REASONS+=("response did not include both memories"); }
[ "$sees_link" = "1" ] || { PASS=false; REASONS+=("response did not include a contradicts relation"); }

jq -n \
  --arg pass "$PASS" \
  --arg agent_group "$AGENT_GROUP" \
  --arg topic "$TOPIC" \
  --arg m_alice "$m_alice" --arg m_bob "$m_bob" \
  --arg detect_code "$detect_code" \
  --argjson sees_both "$sees_both" --argjson sees_link "$sees_link" \
  --argjson reasons "$(printf '%s\n' "${REASONS[@]:-}" | jq -R . | jq -s 'map(select(. != ""))')" \
  '{scenario:"6", pass:($pass=="true"), agent_group:$agent_group,
    topic:$topic, alice_id:$m_alice, bob_id:$m_bob,
    detect_http_code:$detect_code,
    charlie_sees_both_memories:$sees_both,
    charlie_sees_contradicts_link:$sees_link,
    reasons:$reasons}'

$PASS || exit 1
