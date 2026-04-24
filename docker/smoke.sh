#!/usr/bin/env bash
# Copyright 2026 AlphaOne LLC
# SPDX-License-Identifier: Apache-2.0
#
# Mesh smoke — S1-style cross-node write-read + S40-style 500-row
# bulk fanout. Proves the 4-node quorum mesh is wired up before any
# scenario harness runs.
set -euo pipefail

log() { printf '[smoke %s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
fail() { log "FAIL: $*"; exit 1; }

# --- Node health -----------------------------------------------------
log "health check on all 4 nodes"
for i in 1 2 3 4; do
  status=$(docker inspect -f '{{.State.Status}}/{{if .State.Health}}{{.State.Health.Status}}{{else}}no-health{{end}}' "a2a-node-$i" 2>&1 || echo "missing")
  log "  a2a-node-$i: $status"
  [[ "$status" == running/healthy ]] || fail "a2a-node-$i not healthy ($status)"
done

# --- S1-style cross-node write-read ----------------------------------
smoke_s1() {
  local writer="$1" reader="$2" marker="$3"
  local ns="smoke-s1-${marker}"
  local title="smoke-${marker}-from-${writer}"
  log "S1: $writer writes in $ns, $reader reads"

  docker exec "$writer" curl -sSf -X POST \
    -H 'Content-Type: application/json' \
    -H "X-Agent-Id: ai:${writer#a2a-}" \
    --data "{\"tier\":\"long\",\"namespace\":\"$ns\",\"title\":\"$title\",\"content\":\"body-$marker\",\"tags\":[],\"priority\":5,\"confidence\":1.0,\"source\":\"api\"}" \
    http://127.0.0.1:9077/api/v1/memories >/dev/null \
    || fail "write failed on $writer"

  sleep 3

  local count
  count=$(docker exec "$reader" curl -sSf "http://127.0.0.1:9077/api/v1/memories?namespace=$ns&limit=10" 2>/dev/null \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print(sum(1 for m in (d.get("memories") or d.get("items") or []) if m.get("title")))')
  [[ "$count" -ge 1 ]] || fail "$reader saw 0 memories in $ns (expected ≥1)"
  log "  PASS: $reader saw $count memory in $ns"
}

smoke_s1 a2a-node-1 a2a-node-2 a1
smoke_s1 a2a-node-2 a2a-node-3 b2
smoke_s1 a2a-node-3 a2a-node-4 c3

# --- S40-style bulk fanout -------------------------------------------
smoke_s40() {
  local leader="a2a-node-1"
  local ns="smoke-bulk-$(date +%s)"
  log "S40: $leader bulk-posts 500 rows in $ns"

  python3 -c "
import json, sys
print(json.dumps([
  {'tier':'long','namespace':'$ns','title':f'sb-{i:03d}',
   'content':f'r{i}','tags':[],'priority':5,'confidence':1.0,'source':'api'}
  for i in range(500)]))" > /tmp/smoke-bulk.json

  docker cp /tmp/smoke-bulk.json "$leader:/tmp/smoke-bulk.json"
  local created
  created=$(docker exec "$leader" bash -c 'curl -sSf -X POST -H "Content-Type: application/json" -H "X-Agent-Id: ai:smoke" --data @/tmp/smoke-bulk.json http://127.0.0.1:9077/api/v1/memories/bulk' \
    | python3 -c 'import sys,json;print(json.load(sys.stdin).get("created",0))')
  [[ "$created" == "500" ]] || fail "bulk create returned created=$created (expected 500)"
  log "  bulk POST returned created=500"

  log "  settle 20s for fanout + catchup..."
  sleep 20

  local ok=1
  for n in a2a-node-2 a2a-node-3 a2a-node-4; do
    local count
    count=$(docker exec "$n" curl -sSf "http://127.0.0.1:9077/api/v1/memories?namespace=$ns&limit=1000" 2>/dev/null \
      | python3 -c 'import sys,json;d=json.load(sys.stdin);print(len(d.get("memories") or d.get("items") or []))')
    log "  $n count=$count / 500"
    [[ "$count" == "500" ]] || ok=0
  done
  [[ $ok == 1 ]] || fail "bulk fanout incomplete on one or more peers"
  log "  PASS: all 3 peers saw 500/500"
}

smoke_s40

log "SMOKE PASS"
