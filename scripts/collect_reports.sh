#!/usr/bin/env bash
# Copyright 2026 AlphaOne LLC
# SPDX-License-Identifier: Apache-2.0
#
# Aggregator — read every scenario-N.json in phase-reports/ and
# produce a2a-summary.json with overall_pass = all-scenarios-pass.
# Mirrors the ship-gate's collect_reports.sh pattern.

set -euo pipefail

SUMMARY=${1:-a2a-summary.json}
DIR=${2:-phase-reports}

scenarios=()
for f in "$DIR"/scenario-*.json; do
  [ -f "$f" ] || continue
  scenarios+=("$(jq -c '.' "$f")")
done

if [ "${#scenarios[@]}" -eq 0 ]; then
  overall_pass=false
  reasons='["no scenario reports found"]'
  scenario_json='[]'
else
  # overall_pass = every scenario's .pass is true (null = not
  # applicable and is ignored so skipped scenarios don't block).
  overall_pass=$(printf '%s\n' "${scenarios[@]}" | jq -s '[.[] | select(.pass != null) | .pass] | all' 2>/dev/null)
  overall_pass=${overall_pass:-false}
  scenario_json=$(printf '%s\n' "${scenarios[@]}" | jq -s '.')
  reasons=$(printf '%s\n' "${scenarios[@]}" | jq -s '[.[] | select(.pass == false) | .reasons // [] | .[]] | unique | map(select(length > 0))')
fi

jq -n \
  --arg campaign_id "${CAMPAIGN_ID:-unknown}" \
  --arg ref "${AI_MEMORY_GIT_REF:-unknown}" \
  --arg completed "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson overall_pass "$overall_pass" \
  --argjson scenarios "$scenario_json" \
  --argjson reasons "$reasons" \
  '{
    campaign_id:$campaign_id,
    ai_memory_git_ref:$ref,
    completed_at:$completed,
    overall_pass:$overall_pass,
    scenarios:$scenarios,
    reasons:$reasons
  }' > "$SUMMARY"

echo "wrote $SUMMARY (overall_pass=$overall_pass, ${#scenarios[@]} scenarios)"
