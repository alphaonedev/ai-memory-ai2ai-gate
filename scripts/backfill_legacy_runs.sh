#!/usr/bin/env bash
# Copyright 2026 AlphaOne LLC
# SPDX-License-Identifier: Apache-2.0
#
# One-shot back-fill for r1–r6 style runs where scenario-N.json was
# accidentally written with log text prefixed (stdout + stderr merged
# by the workflow). Splits each file into:
#   scenario-N.json  — pure final JSON object
#   scenario-N.log   — every line before that JSON object
# Then re-aggregates a2a-summary.json and regenerates the evidence
# HTML via the same scripts the CI pipeline uses.
#
# Safe to re-run: if a file already starts with '{' it's treated as
# pure JSON and left alone.

set -euo pipefail

ROOT="${1:-runs}"

split_one() {
  local f="$1"
  # Fast path — already clean JSON.
  if jq -e . "$f" >/dev/null 2>&1; then
    return 0
  fi
  # Find the line of the last top-level '{'. Tail from there is the
  # JSON blob; everything before is the console trace.
  local last_open
  last_open=$(grep -n '^{' "$f" 2>/dev/null | tail -1 | cut -d: -f1 || true)
  if [ -z "$last_open" ]; then
    echo "skip $f — no JSON object found" >&2
    return 0
  fi
  local dir base name log_file json_tmp
  dir=$(dirname "$f")
  base=$(basename "$f" .json)
  log_file="$dir/${base}.log"
  json_tmp="$f.tmp.$$"
  # Write the trailing JSON blob (validated) to a tmp, then swap in.
  if ! tail -n +"$last_open" "$f" | jq -c '.' > "$json_tmp" 2>/dev/null; then
    rm -f "$json_tmp"
    echo "skip $f — trailing blob didn't parse" >&2
    return 0
  fi
  # Preserve the original console trace as the .log file.
  head -n $((last_open - 1)) "$f" > "$log_file"
  mv "$json_tmp" "$f"
  echo "split $f → $(basename "$f") (pure JSON) + $(basename "$log_file") (trace)"
}

for dir in "$ROOT"/*/; do
  [ -d "$dir" ] || continue
  name=$(basename "$dir")
  echo "=== $name ==="
  for f in "$dir"/scenario-*.json; do
    [ -f "$f" ] || continue
    split_one "$f"
  done

  # Seed a minimal campaign.meta.json from the campaign id when
  # absent. Historical runs have neither DO node IPs nor actor; we
  # record the group/ref we can parse out of the campaign id.
  meta="$dir/campaign.meta.json"
  if [ ! -f "$meta" ]; then
    group=$(echo "$name" | sed -E 's/^a2a-([^-]+)-.*/\1/')
    ref=$(echo "$name" | sed -E 's/.*-(v[0-9]+\.[0-9]+\.[0-9]+)-r[0-9]+$/\1/')
    [ -n "$ref" ] || ref="unknown"
    jq -n \
      --arg campaign_id "$name" \
      --arg agent_group "$group" \
      --arg ai_memory_ref "$ref" \
      '{
        campaign_id:$campaign_id,
        agent_group:$agent_group,
        ai_memory_git_ref:$ai_memory_ref,
        infra:null,
        scenarios_requested:["1"],
        timing:null,
        ci:{actor:"a2a-gate-bot", workflow_url:null, harness_sha:null, runner_os:"ubuntu-24.04"},
        notes:"Back-filled by scripts/backfill_legacy_runs.sh — historical run predates campaign.meta.json emission."
      }' > "$meta"
    echo "seeded $meta"
  fi

  # Re-aggregate. Use the harden'd collect_reports.sh on the run dir
  # itself (it now accepts a directory of scenario JSONs).
  CAMPAIGN_ID="$name" \
  AI_MEMORY_GIT_REF=$(jq -r '.ai_memory_git_ref' "$meta") \
  AGENT_GROUP=$(jq -r '.agent_group' "$meta") \
    bash scripts/collect_reports.sh "$dir/a2a-summary.json" "$dir"
  bash scripts/generate_run_html.sh "$dir"
done
