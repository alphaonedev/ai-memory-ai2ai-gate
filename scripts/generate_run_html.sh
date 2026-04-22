#!/usr/bin/env bash
# Copyright 2026 AlphaOne LLC
# SPDX-License-Identifier: Apache-2.0
#
# Generate a self-contained index.html inside runs/<campaign-id>/.
# Layout:
#   1. Header — campaign id, overall verdict, completion timestamp
#   2. Infrastructure — DO region, droplet sizes, node roster, workflow URL
#   3. AI NHI tri-audience analysis from analysis/run-insights.json
#   4. Per-scenario PASS/FAIL with reasons, collapsible JSON + log
#   5. All-artifacts link list
#
# Never exits early — if the summary is missing we still render what
# we have, so the dashboard reflects that the run actually ran.

set -euo pipefail

DIR="${1:?usage: $0 <run-directory>}"
[ -d "$DIR" ] || { echo "not a directory: $DIR" >&2; exit 1; }

SUMMARY="$DIR/a2a-summary.json"
META="$DIR/campaign.meta.json"
OUT="$DIR/index.html"
NAME=$(basename "$DIR")

INSIGHTS=""
if [ -f analysis/run-insights.json ]; then
  INSIGHTS="analysis/run-insights.json"
elif [ -f "$(dirname "$DIR")/../analysis/run-insights.json" ]; then
  INSIGHTS="$(dirname "$DIR")/../analysis/run-insights.json"
fi

# Pull summary fields (safe when file absent).
if [ -f "$SUMMARY" ]; then
  REF=$(jq -r '.ai_memory_git_ref // "?"' "$SUMMARY")
  COMPLETED=$(jq -r '.completed_at // "?"' "$SUMMARY")
  PASS=$(jq -r '.overall_pass // false' "$SUMMARY")
  GROUP=$(jq -r '.agent_group // (.scenarios[0].agent_group // "?")' "$SUMMARY")
  SKIPPED_COUNT=$(jq -r '(.skipped_reports // []) | length' "$SUMMARY")
else
  REF="?"; COMPLETED="?"; PASS="false"; GROUP="?"; SKIPPED_COUNT=0
fi

if [ "$PASS" = "true" ]; then
  PASS_CLASS="pass"; PASS_LABEL="PASS"
elif [ -f "$SUMMARY" ]; then
  PASS_CLASS="fail"; PASS_LABEL="FAIL"
else
  PASS_CLASS="warn"; PASS_LABEL="NO SUMMARY"
fi

html_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# Pull a field from meta (campaign.meta.json) or from summary.meta.
meta_field() {
  local key="$1"
  if [ -f "$META" ]; then
    jq -r --arg k "$key" '.[$k] // empty' "$META" 2>/dev/null
  elif [ -f "$SUMMARY" ]; then
    jq -r --arg k "$key" '.meta // {} | .[$k] // empty' "$SUMMARY" 2>/dev/null
  fi
}

render_infra() {
  # Prefer campaign.meta.json (authoritative, written by the workflow)
  # over the meta nested inside a2a-summary.json.
  local meta_json=""
  if [ -f "$META" ]; then
    meta_json=$(cat "$META")
  elif [ -f "$SUMMARY" ]; then
    meta_json=$(jq -c '.meta // null' "$SUMMARY" 2>/dev/null || echo null)
  fi
  if [ -z "$meta_json" ] || [ "$meta_json" = "null" ]; then
    cat <<HERE
      <section class="infra">
        <h2>Infrastructure</h2>
        <p class="muted">No <code>campaign.meta.json</code> captured for this run (pre-upgrade artifact format). Infrastructure details recoverable from the workflow run logs.</p>
      </section>
HERE
    return 0
  fi

  local provider region size topo wurl actor sha started ended notes
  provider=$(echo "$meta_json"  | jq -r '.infra.provider // "?"')
  region=$(echo "$meta_json"    | jq -r '.infra.region // "?"')
  size=$(echo "$meta_json"      | jq -r '.infra.droplet_size // "?"')
  topo=$(echo "$meta_json"      | jq -r '.infra.topology // "?"')
  wurl=$(echo "$meta_json"      | jq -r '.ci.workflow_url // ""')
  actor=$(echo "$meta_json"     | jq -r '.ci.actor // "?"')
  sha=$(echo "$meta_json"       | jq -r '.ci.harness_sha // "?"')
  started=$(echo "$meta_json"   | jq -r '.timing.started_at // "?"')
  ended=$(echo "$meta_json"     | jq -r '.timing.ended_at // "?"')
  notes=$(echo "$meta_json"     | jq -r '.notes // ""')

  cat <<HERE
      <section class="infra">
        <h2>Infrastructure</h2>
        <dl class="meta">
          <dt>Provider</dt><dd><code>${provider}</code></dd>
          <dt>Region</dt><dd><code>${region}</code></dd>
          <dt>Droplet size</dt><dd><code>${size}</code></dd>
          <dt>Topology</dt><dd>${topo}</dd>
          <dt>Scenarios started</dt><dd>${started}</dd>
          <dt>Scenarios ended</dt><dd>${ended}</dd>
          <dt>Dispatched by</dt><dd><code>${actor}</code></dd>
          <dt>Harness SHA</dt><dd><code>${sha:0:12}</code></dd>
HERE
  if [ -n "$wurl" ] && [ "$wurl" != "null" ]; then
    printf '          <dt>Workflow run</dt><dd><a href="%s">%s</a></dd>\n' "$wurl" "$wurl"
  fi
  cat <<HERE
        </dl>
HERE
  if [ -n "$notes" ]; then
    printf '        <p class="muted"><em>%s</em></p>\n' "$(echo "$notes" | html_escape)"
  fi
  # Node roster — only render when nodes are known.
  local nodes_len
  nodes_len=$(echo "$meta_json" | jq -r '.infra.nodes // [] | length')
  if [ "$nodes_len" -gt 0 ] 2>/dev/null; then
    cat <<HERE
        <h3>Node roster</h3>
        <table class="nodes">
          <thead><tr><th>#</th><th>Role</th><th>Agent ID</th><th>Public IP</th><th>Private IP</th></tr></thead>
          <tbody>
HERE
    echo "$meta_json" | jq -r '.infra.nodes[]? | "<tr><td>\(.index)</td><td>\(.role)</td><td><code>\(.agent_id // "—")</code></td><td><code>\(.public_ip)</code></td><td><code>\(.private_ip)</code></td></tr>"'
    cat <<HERE
          </tbody>
        </table>
HERE
  fi
  printf '      </section>\n'
}

insight_field() {
  local key="$1"
  [ -n "$INSIGHTS" ] || { printf ''; return; }
  jq -r --arg n "$NAME" --arg k "$key" '(.[$n][$k] // "") | tostring' "$INSIGHTS" 2>/dev/null || printf ''
}

render_insights() {
  # Prefer the auto-generated per-run analysis over the curated global
  # file. The per-run file is a flat object (no campaign-id key) written
  # by scripts/analyze_run.py immediately after scenarios complete; the
  # global file is the hand-curated one in analysis/run-insights.json
  # keyed by campaign id.
  local use_per_run=false
  if [ -f "$DIR/ai-nhi-analysis.json" ]; then
    use_per_run=true
  fi
  local has=false
  if [ "$use_per_run" = "true" ]; then
    has=true
  elif [ -n "$INSIGHTS" ]; then
    has=$(jq -r --arg n "$NAME" '.[$n] != null' "$INSIGHTS" 2>/dev/null || echo false)
  fi
  if [ "$has" != "true" ]; then
    cat <<HERE
      <section class="ai-insight">
        <h2>AI NHI analysis</h2>
        <p class="muted">No per-campaign narrative recorded yet. <code>scripts/analyze_run.py</code> will generate one on the next dispatch.</p>
      </section>
HERE
    return 0
  fi
  # insight_field() reads from the global file; per-run flat file is
  # read directly with jq instead.
  local headline verdict tested proved nt cl sme nxt
  if [ "$use_per_run" = "true" ]; then
    local pf="$DIR/ai-nhi-analysis.json"
    headline=$(jq -r '.headline // ""' "$pf" | html_escape)
    verdict=$(jq -r '.verdict // ""' "$pf" | html_escape)
    tested=$(jq -r '.what_it_tested // ""' "$pf" | html_escape)
    proved=$(jq -r '.what_it_proved // ""' "$pf" | html_escape)
    nt=$(jq -r '.for_non_technical // ""' "$pf" | html_escape)
    cl=$(jq -r '.for_c_level // ""' "$pf" | html_escape)
    sme=$(jq -r '.for_sme // ""' "$pf" | html_escape)
    nxt=$(jq -r '.next_run_change // ""' "$pf" | html_escape)
  else
    headline=$(insight_field headline | html_escape)
    verdict=$(insight_field verdict | html_escape)
    tested=$(insight_field what_it_tested | html_escape)
    proved=$(insight_field what_it_proved | html_escape)
    nt=$(insight_field for_non_technical | html_escape)
    cl=$(insight_field for_c_level | html_escape)
    sme=$(insight_field for_sme | html_escape)
    nxt=$(insight_field next_run_change | html_escape)
  fi
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
  local jfile="$DIR/scenario-${n}.json"
  local lfile="$DIR/scenario-${n}.log"
  [ -f "$jfile" ] || [ -f "$lfile" ] || return 0
  local pass="" reasons="" badge
  # jq -e . (no path) checks the file parses as JSON; .pass would
  # evaluate the value and return 1 on boolean false, which is wrong
  # for our purposes.
  # NOTE: jq's `//` treats false as "absent" (alternative operator).
  # Use `if .pass == null then empty else .pass end` instead so that
  # boolean-false actually returns "false", not empty string.
  if [ -f "$jfile" ] && jq -e . "$jfile" >/dev/null 2>&1; then
    pass=$(jq -r 'if .pass == null then empty else .pass end' "$jfile" 2>/dev/null || true)
    reasons=$(jq -r '(.reasons // []) | map(select(length > 0)) | join(" | ")' "$jfile" 2>/dev/null || true)
  elif [ -f "$jfile" ]; then
    local last_open
    last_open=$(grep -n '^{' "$jfile" 2>/dev/null | tail -1 | cut -d: -f1 || true)
    if [ -n "$last_open" ]; then
      pass=$(tail -n +"$last_open" "$jfile" | jq -r 'if .pass == null then empty else .pass end' 2>/dev/null || true)
      reasons=$(tail -n +"$last_open" "$jfile" | jq -r '(.reasons // []) | map(select(length > 0)) | join(" | ")' 2>/dev/null || true)
    fi
  fi
  case "$pass" in
    true)  badge='<span class="badge pass">PASS</span>' ;;
    false) badge='<span class="badge fail">FAIL</span>' ;;
    *)     badge='<span class="badge warn">UNKNOWN</span>' ;;
  esac
  printf '      <section class="phase" id="scenario-%s">\n' "$n"
  printf '        <h2>Scenario %s — %s %s</h2>\n' "$n" "$title" "$badge"
  if [ -n "$reasons" ] && [ "$reasons" != "null" ]; then
    printf '        <p class="muted"><strong>Reasons:</strong> %s</p>\n' "$(echo "$reasons" | html_escape)"
  fi
  if [ -f "$jfile" ]; then
    printf '        <details><summary>scenario-%s.json (report)</summary>\n' "$n"
    printf '          <pre>'
    if jq -e . "$jfile" >/dev/null 2>&1; then
      jq --tab . "$jfile" 2>/dev/null | html_escape
    else
      html_escape < "$jfile"
    fi
    printf '</pre>\n'
    printf '          <p><a href="./scenario-%s.json">raw file</a></p>\n' "$n"
    printf '        </details>\n'
  fi
  if [ -f "$lfile" ]; then
    printf '        <details><summary>scenario-%s.log (console trace)</summary>\n' "$n"
    printf '          <pre class="log">'
    html_escape < "$lfile"
    printf '</pre>\n'
    printf '          <p><a href="./scenario-%s.log">raw file</a></p>\n' "$n"
    printf '        </details>\n'
  fi
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
    :root { --fg:#1a1a1a; --bg:#fff; --muted:#666; --pass:#1a8b3c; --fail:#b32222; --warn:#b36b00; --pass-bg:#e6f6ea; --fail-bg:#fceaea; --warn-bg:#fdf3e0; --border:#e0e0e0; --code-bg:#f7f7f9; --accent:#3952c8; --accent-bg:#eef1fd; }
    @media (prefers-color-scheme: dark) { :root { --fg:#eaeaea; --bg:#181818; --muted:#a0a0a0; --pass:#4adc76; --fail:#ff6a6a; --warn:#ffb74d; --pass-bg:#153d23; --fail-bg:#401818; --warn-bg:#3a2d10; --border:#2a2a2a; --code-bg:#202028; --accent:#8da3ff; --accent-bg:#1c2140; } }
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
    table.nodes { width:100%; border-collapse:collapse; margin-top:.5rem; font-size:14px; }
    table.nodes th, table.nodes td { border:1px solid var(--border); padding:.35rem .6rem; text-align:left; }
    table.nodes th { background:var(--code-bg); font-weight:600; }
    .badge { display:inline-block; padding:.15rem .55rem; border-radius:999px; font-size:12px; font-weight:600; letter-spacing:.03em; text-transform:uppercase; margin-left:.4rem; vertical-align:middle; }
    .badge.pass { color:var(--pass); background:var(--pass-bg); }
    .badge.fail { color:var(--fail); background:var(--fail-bg); }
    .badge.warn { color:var(--warn); background:var(--warn-bg); }
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
    pre { background:var(--code-bg); padding:.75rem; border-radius:6px; overflow-x:auto; font:12px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace; margin:.5rem 0; max-height:480px; }
    pre.log { max-height:640px; }
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
        <dt>Skipped reports</dt><dd>${SKIPPED_COUNT}</dd>
      </dl>
    </header>
EOF

render_infra
render_baseline() {
  local bfile="$DIR/a2a-baseline.json"
  [ -f "$bfile" ] || return 0
  local pass
  pass=$(jq -r '.baseline_pass' "$bfile" 2>/dev/null || echo unknown)
  local badge_class badge_text
  case "$pass" in
    true)  badge_class="pass"; badge_text="BASELINE OK" ;;
    false) badge_class="fail"; badge_text="BASELINE VIOLATION" ;;
    *)     badge_class="warn"; badge_text="BASELINE UNKNOWN" ;;
  esac
  cat <<HERE
      <section class="baseline">
        <h2>Baseline attestation <span class="badge ${badge_class}">${badge_text}</span></h2>
        <p class="muted">Per the <a href="../baseline/">authoritative baseline spec</a>, every agent node must emit a self-attestation before any scenario is permitted to run. This run's attestation:</p>
        <p class="muted">Spec version: <code>$(jq -r '.per_node[0].spec_version // "1.0.0"' "$bfile" 2>/dev/null)</code> — see <a href="../baseline/">authoritative baseline</a>.</p>
        <table class="nodes">
          <thead><tr><th>Node</th><th>Agent</th><th>Framework</th><th>Authentic</th><th>MCP ai-memory</th><th>xAI cfg</th><th>xAI default</th><th>Agent ID</th><th>Federation</th><th>UFW off</th><th>iptables</th><th>dead-man</th><th>F1 xAI</th><th>F2a substrate</th><th>F2b agent (non-gating)</th><th>Config SHA</th><th>Pass</th></tr></thead>
          <tbody>
HERE
  jq -r '.per_node[]? | "<tr><td>node-\(.node_index)</td><td><code>\(.agent_id)</code></td><td><code>\(.agent_type) \(.framework_version // "?")</code></td><td>\(if (.config_attestation // .baseline).framework_is_authentic then "✅" else "❌" end)</td><td>\(if (.config_attestation // .baseline).mcp_server_ai_memory_registered and (.config_attestation // .baseline).mcp_command_is_ai_memory then "✅" else "❌" end)</td><td>\(if (.config_attestation // .baseline).llm_backend_is_xai_grok then "✅" else "❌" end)</td><td>\(if (.config_attestation // .baseline).llm_is_default_provider then "✅" else "❌" end)</td><td>\(if (.config_attestation // .baseline).agent_id_stamped then "✅" else "❌" end)</td><td>\(if (.config_attestation // .baseline).federation_live then "✅" else "❌" end)</td><td>\(if ((.config_attestation // .baseline).ufw_disabled // false) then "✅" else "—" end)</td><td>\(if ((.config_attestation // .baseline).iptables_flushed // null) == true then "✅" elif ((.config_attestation // .baseline).iptables_flushed // null) == false then "❌" else "—" end)</td><td>\(if ((.config_attestation // .baseline).dead_man_switch_scheduled // null) == true then "✅" elif ((.config_attestation // .baseline).dead_man_switch_scheduled // null) == false then "❌" else "—" end)</td><td>\(if (.functional_probes.xai_grok_chat_reachable // false) then "✅" else "❌" end)</td><td>\(if (.functional_probes.substrate_http_canary_f2a // .functional_probes.agent_mcp_ai_memory_canary // false) then "✅" else "❌" end)</td><td>\(if (.functional_probes.agent_mcp_canary_f2b // null) == true then "✅" elif (.functional_probes.agent_mcp_canary_f2b // null) == false then "⚠️" else "—" end)</td><td><code>\((.config_file_sha256 // "—") | .[0:12])</code></td><td>\(if .baseline_pass then "<strong>PASS</strong>" else "<strong>FAIL</strong>" end)</td></tr>"' "$bfile"
  cat <<HERE
          </tbody>
        </table>
        <details><summary>a2a-baseline.json</summary>
          <pre>
HERE
  jq --tab . "$bfile" 2>/dev/null | html_escape
  cat <<HERE
</pre>
          <p><a href="./a2a-baseline.json">raw file</a></p>
        </details>
      </section>
HERE
}
render_baseline
render_f3() {
  local ffile="$DIR/f3-peer-a2a.json"
  [ -f "$ffile" ] || return 0
  local pass uuid ns writer
  pass=$(jq -r '.pass // false' "$ffile")
  uuid=$(jq -r '.canary_uuid' "$ffile")
  ns=$(jq -r '.canary_namespace' "$ffile")
  writer=$(jq -r '.writer_agent' "$ffile")
  local badge_class badge_text
  if [ "$pass" = "true" ]; then badge_class=pass; badge_text="F3 OK"; else badge_class=fail; badge_text="F3 FAIL"; fi
  cat <<HERE
      <section class="f3">
        <h2>F3 — peer A2A via shared memory <span class="badge ${badge_class}">${badge_text}</span></h2>
        <p class="muted">Workflow-level probe answering "can agents communicate through ai-memory?". Writer <code>${writer}</code> posted canary UUID <code>${uuid}</code> to namespace <code>${ns}</code> via node-1's local <code>ai-memory</code> serve HTTP. After W=2 fanout settle, probe confirmed the canary on each of the 3 peer nodes via their local <code>GET /api/v1/memories</code>.</p>
        <details><summary>f3-peer-a2a.json</summary>
          <pre>
HERE
  jq --tab . "$ffile" 2>/dev/null | html_escape
  cat <<HERE
</pre>
          <p><a href="./f3-peer-a2a.json">raw file</a></p>
        </details>
      </section>
HERE
}
# ---- Testbook v3.0.0 scenario catalog ------------------------------
# Human-friendly title for every scenario id. Also drives the
# "Tests performed" summary table and the per-scenario PASS/FAIL blocks.
declare -A SCENARIO_TITLES=(
  [1]="Per-agent write + read (MCP stdio)"
  [1b]="Per-agent write + read (HTTP)"
  [2]="Shared-context handoff"
  [3]="Targeted memory_share"
  [4]="Federation-aware concurrent writes"
  [5]="Consolidation + curation"
  [6]="Contradiction detection"
  [7]="Scope visibility matrix"
  [8]="Auto-tagging round-trip"
  [9]="Mutation round-trip"
  [10]="Deletion propagation"
  [11]="Link integrity"
  [12]="Agent registration"
  [13]="Concurrent write contention"
  [14]="Partition tolerance"
  [15]="Read-your-writes"
  [16]="Tier promotion"
  [17]="Stats consistency"
  [18]="Semantic query expansion"
  [19]="Same-node A2A"
  [20]="mTLS happy-path"
  [21]="Anonymous client rejected"
  [22]="Identity spoofing resistance"
  [23]="Malicious content fuzz"
  [24]="Byzantine peer"
  [25]="Clock skew tolerance"
  [26]="Mixed ironclaw + hermes"
  [27]="Legacy OpenClaw regression"
  [28]="memory_search keyword"
  [29]="memory_archive lifecycle"
  [30]="memory_capabilities handshake"
  [31]="memory_gc quiescence"
  [32]="memory_inbox + notify"
  [33]="memory_subscribe pub/sub"
  [34]="memory_pending governance"
  [35]="memory_namespace standards"
  [36]="memory_session_start"
  [37]="memory_get_links bidirectional"
  [38]="/export + /import"
  [39]="/sync/since delta"
  [40]="/memories/bulk"
  [41]="/metrics Prometheus"
  [42]="/namespaces enumeration"
)

# Discover scenarios that actually ran in this campaign (one scenario-*.json
# per scenario, written by the workflow Run scenarios step).
shopt -s nullglob
declare -a _SCN_IDS_SEEN=()
for _jfile in "$DIR"/scenario-*.json; do
  _sid=$(basename "$_jfile" .json); _sid="${_sid#scenario-}"
  _SCN_IDS_SEEN+=("$_sid")
done
# Sort numerically; "1b" lands between 1 and 2.
IFS=$'\n' _SCN_SORTED=($(printf '%s\n' "${_SCN_IDS_SEEN[@]}" | awk '
  { n=$0; gsub(/[^0-9]/,"",n); if (n=="") n=999; printf "%d\t%s\n", n, $0 }
' | sort -k1,1n -k2,2 | cut -f2))
unset IFS

render_tests_performed() {
  [ "${#_SCN_SORTED[@]}" -gt 0 ] || return 0
  cat <<'HERE'
      <section class="tests-performed">
        <h2>Tests performed in this run</h2>
        <p class="muted">Every scenario that produced a JSON report in this campaign, in testbook order. Click a row's scenario id to jump to its full report below. See the <a href="../../tests/">Every test performed</a> page for the authoritative catalog.</p>
        <table class="tests-table">
          <thead><tr><th>ID</th><th>Title</th><th>Result</th><th>Reason</th></tr></thead>
          <tbody>
HERE
  for sid in "${_SCN_SORTED[@]}"; do
    local title="${SCENARIO_TITLES[$sid]:-scenario-$sid}"
    local jf="$DIR/scenario-${sid}.json"
    local pass="?" skipped="false" reason=""
    if [ -f "$jf" ]; then
      pass=$(jq -r '.pass // "null"' "$jf" 2>/dev/null)
      skipped=$(jq -r '.skipped // false' "$jf" 2>/dev/null)
      reason=$(jq -r '.reason // ""' "$jf" 2>/dev/null | head -c 200)
    fi
    local badge
    case "$pass" in
      true)                      badge='<span class="badge pass">PASS</span>' ;;
      false)                     badge='<span class="badge fail">FAIL</span>' ;;
      null|"") if [ "$skipped" = "true" ]; then badge='<span class="badge warn">SKIP</span>'; else badge='<span class="badge warn">?</span>'; fi ;;
      *)                         badge='<span class="badge warn">?</span>' ;;
    esac
    printf '            <tr><td><a href="#scenario-%s">S%s</a></td><td>%s</td><td>%s</td><td>%s</td></tr>\n' \
      "$sid" "$sid" "$(printf '%s' "$title" | html_escape)" "$badge" "$(printf '%s' "$reason" | html_escape)"
  done
  cat <<'HERE'
          </tbody>
        </table>
      </section>
HERE
}

render_f3
render_insights
render_tests_performed
unset IFS
for _sid in "${_SCN_SORTED[@]}"; do
  _title="${SCENARIO_TITLES[$_sid]:-scenario-$_sid}"
  scenario_block "$_sid" "$_title"
done

cat <<EOF
    <section>
      <h2>All artifacts</h2>
      <ul>
EOF
for f in "$DIR"/*.json "$DIR"/*.log; do
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
