#!/usr/bin/env bash
# Copyright 2026 AlphaOne LLC
# SPDX-License-Identifier: Apache-2.0
#
# Generate a self-contained index.html inside runs/<campaign-id>/.
# Layout:
#   1. Run focus + AI NHI tri-audience analysis from
#      analysis/run-insights.json (non-technical / C-level / SME)
#   2. Per-scenario PASS/FAIL with raw JSON collapsible
#   3. All-artefacts link list

set -euo pipefail

DIR="${1:?usage: $0 <run-directory>}"
[ -d "$DIR" ] || { echo "not a directory: $DIR" >&2; exit 1; }
SUMMARY="$DIR/a2a-summary.json"
[ -f "$SUMMARY" ] || { echo "no a2a-summary.json in $DIR — skipping" >&2; exit 0; }

OUT="$DIR/index.html"
NAME=$(basename "$DIR")

INSIGHTS=""
if [ -f analysis/run-insights.json ]; then
  INSIGHTS="analysis/run-insights.json"
elif [ -f "$(dirname "$DIR")/../analysis/run-insights.json" ]; then
  INSIGHTS="$(dirname "$DIR")/../analysis/run-insights.json"
fi

REF=$(jq -r '.ai_memory_git_ref // "?"' "$SUMMARY")
COMPLETED=$(jq -r '.completed_at // "?"' "$SUMMARY")
PASS=$(jq -r '.overall_pass // false' "$SUMMARY")
GROUP=$(jq -r '(.scenarios[0].agent_group // "?") | tostring' "$SUMMARY" 2>/dev/null)

if [ "$PASS" = "true" ]; then PASS_CLASS="pass"; PASS_LABEL="PASS"; else PASS_CLASS="fail"; PASS_LABEL="FAIL"; fi

html_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

insight_field() {
  local key="$1"
  [ -n "$INSIGHTS" ] || { printf ''; return; }
  jq -r --arg n "$NAME" --arg k "$key" '(.[$n][$k] // "") | tostring' "$INSIGHTS" 2>/dev/null || printf ''
}

render_insights() {
  [ -n "$INSIGHTS" ] || return 0
  local has
  has=$(jq -r --arg n "$NAME" '.[$n] != null' "$INSIGHTS" 2>/dev/null || echo false)
  if [ "$has" != "true" ]; then
    cat <<HERE
      <section class="ai-insight">
        <h2>AI NHI analysis</h2>
        <p class="muted">No per-campaign narrative recorded yet. Append to <code>analysis/run-insights.json</code> after the run completes; the dashboard will refresh on next push.</p>
      </section>
HERE
    return 0
  fi
  local headline verdict tested proved nt cl sme nxt
  headline=$(insight_field headline | html_escape)
  verdict=$(insight_field verdict | html_escape)
  tested=$(insight_field what_it_tested | html_escape)
  proved=$(insight_field what_it_proved | html_escape)
  nt=$(insight_field for_non_technical | html_escape)
  cl=$(insight_field for_c_level | html_escape)
  sme=$(insight_field for_sme | html_escape)
  nxt=$(insight_field next_run_change | html_escape)
  cat <<HERE
      <section class="run-focus">
        <p class="label">Run focus</p>
        <h2>${headline}</h2>
        <p><strong>What this campaign tested:</strong> ${tested}</p>
        <p><strong>What it demonstrated:</strong> ${proved}</p>
      </section>
      <section class="ai-insight">
        <p class="tag">AI NHI analysis &middot; Claude Opus 4.7</p>
        <h2>${headline}</h2>
        <p class="verdict">${verdict}</p>
        <h3>For three audiences</h3>
        <div class="audiences">
          <article><h4>Non-technical end users</h4><p>${nt}</p></article>
          <article><h4>C-level decision makers</h4><p>${cl}</p></article>
          <article><h4>Engineers &amp; architects</h4><p>${sme}</p></article>
        </div>
HERE
  if [ -n "$nxt" ]; then
    printf '        <h3>What changes going into the next campaign</h3>\n        <p>%s</p>\n' "$nxt"
  fi
  printf '      </section>\n'
}

scenario_block() {
  local n="$1" title="$2"
  local file="$DIR/scenario-${n}.json"
  [ -f "$file" ] || return 0
  local pass badge
  pass=$(jq -r '.pass // empty' "$file" 2>/dev/null || true)
  case "$pass" in
    true)  badge='<span class="badge pass">PASS</span>' ;;
    false) badge='<span class="badge fail">FAIL</span>' ;;
    *)     badge='<span class="badge fail">N/A</span>' ;;
  esac
  printf '      <section class="phase">\n'
  printf '        <h2>Scenario %s — %s %s</h2>\n' "$n" "$title" "$badge"
  local reasons
  reasons=$(jq -r '(.reasons // []) | map(select(length > 0)) | join(" | ")' "$file" 2>/dev/null)
  if [ -n "$reasons" ] && [ "$reasons" != "null" ]; then
    printf '        <p class="muted"><strong>Reasons:</strong> %s</p>\n' "$(echo "$reasons" | html_escape)"
  fi
  printf '        <details><summary>raw scenario-%s.json</summary>\n' "$n"
  printf '          <pre>'
  jq --tab . "$file" 2>/dev/null | html_escape || cat "$file" | html_escape
  printf '</pre>\n'
  printf '          <p><a href="./scenario-%s.json">raw JSON</a></p>\n' "$n"
  printf '        </details>\n'
  printf '      </section>\n'
}

{
cat <<EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Campaign ${NAME} — ai-memory A2A gate</title>
  <style>
    :root { --fg:#1a1a1a; --bg:#fff; --muted:#666; --pass:#1a8b3c; --fail:#b32222; --pass-bg:#e6f6ea; --fail-bg:#fceaea; --border:#e0e0e0; --code-bg:#f7f7f9; --accent:#3952c8; --accent-bg:#eef1fd; }
    @media (prefers-color-scheme: dark) { :root { --fg:#eaeaea; --bg:#181818; --muted:#a0a0a0; --pass:#4adc76; --fail:#ff6a6a; --pass-bg:#153d23; --fail-bg:#401818; --border:#2a2a2a; --code-bg:#202028; --accent:#8da3ff; --accent-bg:#1c2140; } }
    * { box-sizing:border-box; }
    body { font:15px/1.6 -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif; color:var(--fg); background:var(--bg); margin:0; }
    main { max-width:960px; margin:0 auto; padding:2rem 1.25rem 4rem; }
    header { border-bottom:1px solid var(--border); padding-bottom:1rem; margin-bottom:1.5rem; }
    header p.crumb { color:var(--muted); font-size:13px; margin:0 0 .25rem; }
    h1 { margin:.25rem 0 .75rem; font-size:1.85rem; }
    h2 { margin:1.75rem 0 .5rem; font-size:1.2rem; border-bottom:1px solid var(--border); padding-bottom:.25rem; }
    h3 { margin:1.25rem 0 .4rem; font-size:1rem; color:var(--muted); text-transform:uppercase; letter-spacing:.05em; font-weight:600; }
    h4 { margin:.5rem 0 .25rem; font-size:1rem; }
    dl.meta { display:grid; grid-template-columns:max-content 1fr; gap:.35rem 1rem; margin:0; }
    dl.meta dt { color:var(--muted); }
    dl.meta dd { margin:0; }
    .badge { display:inline-block; padding:.15rem .55rem; border-radius:999px; font-size:12px; font-weight:600; letter-spacing:.03em; text-transform:uppercase; margin-left:.4rem; vertical-align:middle; }
    .badge.pass { color:var(--pass); background:var(--pass-bg); }
    .badge.fail { color:var(--fail); background:var(--fail-bg); }
    .run-focus { background:var(--code-bg); border-left:4px solid var(--accent); padding:1rem 1.25rem; margin:1.5rem 0; border-radius:0 6px 6px 0; }
    .run-focus h2 { border:none; margin:0 0 .5rem; padding:0; font-size:1.1rem; }
    .run-focus p.label { color:var(--accent); font-size:12px; text-transform:uppercase; letter-spacing:.06em; font-weight:600; margin:0 0 .25rem; }
    .ai-insight { background:var(--accent-bg); border-radius:8px; padding:1.25rem 1.5rem; margin:1.5rem 0 2rem; border-left:4px solid var(--accent); }
    .ai-insight h2 { border:none; padding:0; margin-top:.25rem; }
    .ai-insight p.tag { color:var(--accent); font-size:12px; text-transform:uppercase; letter-spacing:.08em; font-weight:600; margin:0 0 .25rem; }
    .ai-insight p.verdict { font-size:1.05rem; margin:.5rem 0 1rem; }
    .audiences { display:grid; grid-template-columns:1fr; gap:.75rem; margin-top:.5rem; }
    @media (min-width: 720px) { .audiences { grid-template-columns:repeat(3,1fr); } }
    .audiences article { background:var(--bg); border:1px solid var(--border); border-radius:6px; padding:.85rem 1rem; }
    .audiences article h4 { margin-top:0; color:var(--accent); font-size:14px; }
    details { border:1px solid var(--border); border-radius:6px; padding:.25rem .75rem; margin:.5rem 0; }
    summary { cursor:pointer; padding:.45rem 0; font-weight:500; }
    pre { background:var(--code-bg); padding:.75rem; border-radius:6px; overflow-x:auto; font:12px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace; margin:.5rem 0; }
    a { color:var(--accent); } a:hover { text-decoration:underline; }
    .muted { color:var(--muted); font-size:14px; }
    footer { color:var(--muted); font-size:12px; border-top:1px solid var(--border); padding-top:1rem; margin-top:3rem; }
  </style>
</head>
<body>
  <main>
    <header>
      <p class="crumb"><a href="../">../ runs index</a></p>
      <h1>Campaign ${NAME} <span class="badge ${PASS_CLASS}">${PASS_LABEL}</span></h1>
      <dl class="meta">
        <dt>Agent group</dt><dd><code>${GROUP}</code> (homogeneous)</dd>
        <dt>ai-memory ref</dt><dd><code>${REF}</code></dd>
        <dt>Completed at</dt><dd>${COMPLETED}</dd>
        <dt>Overall pass</dt><dd>${PASS}</dd>
      </dl>
    </header>
EOF

render_insights
scenario_block 1 "Per-agent write + read"
scenario_block 2 "Shared-context handoff"
scenario_block 3 "Targeted share"
scenario_block 4 "Federation-aware agents"
scenario_block 5 "Consolidation + curation"
scenario_block 6 "Contradiction detection"
scenario_block 7 "Scoping visibility"
scenario_block 8 "Auto-tagging (opt-in)"

cat <<EOF
    <section>
      <h2>All artefacts</h2>
      <ul>
EOF
for f in "$DIR"/*.json; do
  [ -e "$f" ] || continue
  fn=$(basename "$f")
  printf '        <li><a href="./%s">%s</a></li>\n' "$fn" "$fn"
done
cat <<EOF
      </ul>
    </section>
    <footer>
      Generated by <code>scripts/generate_run_html.sh</code>.
      Methodology: <a href="https://alphaonedev.github.io/ai-memory-ai2ai-gate/methodology/">alphaonedev.github.io/ai-memory-ai2ai-gate/methodology</a>.
      Analysis source: <code>analysis/run-insights.json</code>.
    </footer>
  </main>
</body>
</html>
EOF
} > "$OUT"

echo "wrote $OUT"
