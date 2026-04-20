#!/usr/bin/env bash
# Copyright 2026 AlphaOne LLC
# SPDX-License-Identifier: Apache-2.0
#
# Aggregator — read every scenario-N.json in phase-reports/ and
# produce a2a-summary.json with overall_pass = all-scenarios-pass.
# Mirrors the ship-gate's collect_reports.sh pattern.
#
# Robustness:
#   - Tolerates legacy mixed log+JSON files (r1–r6 artifact format)
#     by extracting the final {...} JSON object. Emits a warning.
#   - Always writes a2a-summary.json, even when no reports exist,
#     so the dashboard has something to render.
#   - Pulls campaign metadata from phase-reports/campaign.meta.json
#     when present and embeds it so per-run pages can render infra.

set -euo pipefail

SUMMARY=${1:-a2a-summary.json}
DIR=${2:-phase-reports}
META="$DIR/campaign.meta.json"

# Extract the last top-level JSON object from a file. Works for:
#   - pure JSON (returns the file content unchanged)
#   - log + trailing JSON blob (historical r1–r6 artifact shape)
# Returns empty string if no JSON object can be recovered.
extract_trailing_json() {
  local f="$1"
  # Fast path — already valid JSON.
  if jq -e . "$f" >/dev/null 2>&1; then
    jq -c '.' "$f"
    return 0
  fi
  # Slow path — find the last line starting with '{' and stream to EOF,
  # then validate. Tolerates multi-line pretty-printed trailing blob.
  local last_open
  last_open=$(grep -n '^{' "$f" 2>/dev/null | tail -1 | cut -d: -f1 || true)
  if [ -z "$last_open" ]; then
    return 1
  fi
  tail -n +"$last_open" "$f" | jq -c '.' 2>/dev/null || return 1
}

scenarios=()
skipped=()
if [ -d "$DIR" ]; then
  for f in "$DIR"/scenario-*.json; do
    [ -f "$f" ] || continue
    if blob=$(extract_trailing_json "$f"); then
      if [ -n "$blob" ]; then
        scenarios+=("$blob")
      else
        skipped+=("$(basename "$f"):empty")
      fi
    else
      skipped+=("$(basename "$f"):unparseable")
      echo "WARN: $(basename "$f") contains no recoverable JSON — skipping" >&2
    fi
  done
fi

if [ "${#scenarios[@]}" -eq 0 ]; then
  overall_pass=false
  reasons='["no scenario reports recovered"]'
  scenario_json='[]'
else
  # overall_pass = every scenario's .pass is true (null = not
  # applicable and is ignored so skipped scenarios don't block).
  overall_pass=$(printf '%s\n' "${scenarios[@]}" | jq -s '[.[] | select(.pass != null) | .pass] | all')
  overall_pass=${overall_pass:-false}
  scenario_json=$(printf '%s\n' "${scenarios[@]}" | jq -s '.')
  reasons=$(printf '%s\n' "${scenarios[@]}" | jq -s '[.[] | select(.pass == false) | .reasons // [] | .[]] | unique | map(select(length > 0))')
fi

# Embed campaign metadata when present. When absent (legacy runs,
# local smoke tests) we still write a summary — meta is just null.
if [ -f "$META" ]; then
  meta_json=$(jq -c '.' "$META" 2>/dev/null || echo 'null')
else
  meta_json='null'
fi

# Build skipped list JSON.
if [ "${#skipped[@]}" -eq 0 ]; then
  skipped_json='[]'
else
  skipped_json=$(printf '%s\n' "${skipped[@]}" | jq -R . | jq -s '.')
fi

jq -n \
  --arg campaign_id "${CAMPAIGN_ID:-unknown}" \
  --arg ref "${AI_MEMORY_GIT_REF:-unknown}" \
  --arg group "${AGENT_GROUP:-unknown}" \
  --arg completed "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson overall_pass "$overall_pass" \
  --argjson scenarios "$scenario_json" \
  --argjson reasons "$reasons" \
  --argjson meta "$meta_json" \
  --argjson skipped "$skipped_json" \
  '{
    campaign_id:$campaign_id,
    agent_group:$group,
    ai_memory_git_ref:$ref,
    completed_at:$completed,
    overall_pass:$overall_pass,
    scenarios:$scenarios,
    reasons:$reasons,
    meta:$meta,
    skipped_reports:$skipped
  }' > "$SUMMARY"

echo "wrote $SUMMARY (overall_pass=$overall_pass, ${#scenarios[@]} scenarios, ${#skipped[@]} skipped)"
