#!/usr/bin/env bash
# Copyright 2026 AlphaOne LLC
# SPDX-License-Identifier: Apache-2.0
#
# Scenario 15 — Read-your-writes.
#
# alice writes M1 on node-1 and immediately reads it back from the
# SAME node. No settle required; this is local durability, not
# federation. If this fails, the local write-then-read guarantee
# is broken — a product-level correctness bug.

set -euo pipefail

: "${NODE1_IP:?}"; : "${AGENT_GROUP:?}"
log() { printf '[scenario-15 %s] %s\n' "$AGENT_GROUP" "$*" >&2; }

NS="scenario15-ryw"
UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "ryw-$RANDOM")
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

# alice writes and immediately reads on the same node.
log "alice writes + immediately reads M1 on node-1 (uuid=$UUID)"
result=$(ssh $SSH_OPTS root@"$NODE1_IP" bash -s <<REMOTE
set -e
NS='$NS'
UUID='$UUID'
# Write.
curl -sS -X POST 'http://127.0.0.1:9077/api/v1/memories' \
  -H 'X-Agent-Id: ai:alice' -H 'Content-Type: application/json' \
  -d "{\"tier\":\"mid\",\"namespace\":\"\$NS\",\"title\":\"ryw\",\"content\":\"\$UUID\",\"priority\":5,\"confidence\":1.0,\"source\":\"api\",\"metadata\":{\"agent_id\":\"ai:alice\",\"scenario\":\"15\"}}" \
  >/dev/null
# Immediate read (no sleep).
curl -sS "http://127.0.0.1:9077/api/v1/memories?namespace=\$NS&limit=20" \
  | jq --arg u "\$UUID" '[.memories[]? | select(.content == \$u)] | length'
REMOTE
)
hit=$(echo "$result" | tail -1)
hit=${hit:-0}
log "  alice sees $hit (expected 1) immediately after write"

# Verdict.
PASS=true
REASONS=()
[ "$hit" -ge 1 ] 2>/dev/null || { PASS=false; REASONS+=("writer did not see own write immediately on same node — local read-your-writes broken"); }

jq -n \
  --arg pass "$PASS" \
  --arg agent_group "$AGENT_GROUP" \
  --arg uuid "$UUID" \
  --argjson hit "$hit" \
  --argjson reasons "$(printf '%s\n' "${REASONS[@]:-}" | jq -R . | jq -s 'map(select(. != ""))')" \
  '{scenario:"15", pass:($pass=="true"), agent_group:$agent_group,
    uuid:$uuid, writer_sees_own_write:$hit, reasons:$reasons}'

$PASS || exit 1
