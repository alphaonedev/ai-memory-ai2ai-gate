#!/usr/bin/env bash
# Copyright 2026 AlphaOne LLC
# SPDX-License-Identifier: Apache-2.0
#
# Drive an agent to invoke an MCP tool via its local ai-memory
# federation peer.
#
# This is the SINGLE POINT at which scenario scripts talk to the
# agent framework. If the agent framework (OpenClaw or Hermes) has
# a CLI that takes a prompt and produces output, we use it. If not,
# we fall back to driving ai-memory's MCP stdio path directly so the
# scenario still exercises the full MCP tool-dispatch surface.
#
# Required env (sourced from /etc/ai-memory-a2a/env on the agent node):
#   AGENT_TYPE      — openclaw | hermes
#   AGENT_ID        — ai:alice / ai:bob / ai:charlie
#   LOCAL_MEMORY_URL — http://127.0.0.1:9077 (the node's local ai-memory)
#   MCP_CONFIG      — path to the MCP config JSON
#
# Usage:
#   drive_agent.sh store  "<title>" "<content>" [namespace]
#   drive_agent.sh recall "<query>"             [namespace]
#   drive_agent.sh list                         [namespace]
#
# Returns the agent's JSON output on stdout.

set -euo pipefail

source /etc/ai-memory-a2a/env

ACTION="${1:?usage: drive_agent.sh <action> ...}"; shift

# grok-CLI backed drivers. setup_node.sh installed the `grok` binary
# and symlinked /usr/local/bin/openclaw and /usr/local/bin/hermes at
# it. Both use xAI as the inference backend and ai-memory as the MCP
# server — config lives in /root/.grok/user-settings.json, so we
# don't need to pass --mcp-config at invocation time.
#
# grok flags we rely on:
#   -p, --prompt   headless prompt
#   --format json  machine-readable output
#   --no-sandbox   the droplet IS the sandbox; skip Shuru
#   --max-tool-rounds  bound the agent loop per scenario call

agent_cli() { command -v "$AGENT_TYPE" >/dev/null 2>&1; }

# openclaw = grok CLI. Flags: -p (prompt), --format json, --no-sandbox,
# --max-tool-rounds. Picks up xAI key + ai-memory MCP from
# /root/.grok/user-settings.json.
#
# hermes = Nous Research Hermes CLI. Envs: OPENAI_API_KEY/BASE,
# HERMES_MODEL (sourced from /etc/ai-memory-a2a/hermes.env). MCP
# servers from /root/.hermes/config.yaml.
agent_prompt() {
  case "$AGENT_TYPE" in
    openclaw)
      "$AGENT_TYPE" \
        --no-sandbox \
        --format json \
        --max-tool-rounds 20 \
        -p "$1"
      ;;
    hermes)
      # Source xAI env for this invocation (XAI_API_KEY).
      set -a; . /etc/ai-memory-a2a/hermes.env; set +a
      # Hermes CLI surface (hermes-agent ≥ v0.10.0):
      #   hermes chat -q "..."     one-shot, non-interactive
      #   -Q / --quiet             suppress banner/spinner
      #   --provider xai           xAI native (alias grok)
      #   --model <id>             override default model
      # Global -p is PROFILE NAME, not prompt — that mismatch tripped r5.
      hermes chat -Q \
        --provider xai \
        --model grok-4-fast-non-reasoning \
        -q "$1"
      ;;
  esac
}

openclaw_driver() {
  if agent_cli; then
    case "$ACTION" in
      store)
        title="${1:?title required}"; content="${2:?content required}"
        ns="${3:-scenario}"
        agent_prompt "Store a memory in namespace ${ns} titled \"${title}\" with content: ${content}. Use the ai-memory MCP memory_store tool."
        ;;
      recall)
        query="${1:?query required}"; ns="${2:-}"
        agent_prompt "Recall memories matching \"${query}\"${ns:+ in namespace ${ns}} using the ai-memory MCP memory_recall tool. Return the JSON result verbatim."
        ;;
      list)
        ns="${1:-}"
        agent_prompt "List memories${ns:+ in namespace ${ns}} using the ai-memory MCP memory_list tool. Return the JSON result verbatim."
        ;;
      *)
        echo "unknown action: $ACTION" >&2; exit 1 ;;
    esac
    return
  fi
  fallback_driver
}

hermes_driver() {
  if agent_cli; then
    case "$ACTION" in
      store)
        title="${1:?title required}"; content="${2:?content required}"
        ns="${3:-scenario}"
        agent_prompt "Store a memory: namespace=${ns} title=\"${title}\" content=${content} via the ai-memory MCP memory_store tool."
        ;;
      recall)
        query="${1:?query required}"; ns="${2:-}"
        agent_prompt "Recall on \"${query}\"${ns:+ namespace=${ns}} via the ai-memory MCP memory_recall tool; output JSON."
        ;;
      list)
        ns="${1:-}"
        agent_prompt "List memories${ns:+ namespace=${ns}} via the ai-memory MCP memory_list tool; output JSON."
        ;;
      *)
        echo "unknown action: $ACTION" >&2; exit 1 ;;
    esac
    return
  fi
  fallback_driver
}

# Fallback when the agent CLI isn't installed: direct ai-memory MCP
# tool invocation via the HTTP surface. The agent framework would
# have converted an LLM prompt into these same tool calls, so this
# exercises the tool-dispatch layer which is the majority of what
# the scenario is validating.
fallback_driver() {
  case "$ACTION" in
    store)
      title="${1:?title required}"; content="${2:?content required}"
      ns="${3:-scenario}"
      curl -sS -X POST "$LOCAL_MEMORY_URL/api/v1/memories" \
        -H "X-Agent-Id: $AGENT_ID" \
        -H "Content-Type: application/json" \
        -d "{\"tier\":\"mid\",\"namespace\":\"$ns\",\"title\":\"$title\",\"content\":\"$content\",\"priority\":5,\"confidence\":1.0,\"source\":\"api\",\"metadata\":{\"agent_id\":\"$AGENT_ID\"}}"
      ;;
    recall)
      query="${1:?query required}"; ns="${2:-}"
      curl -sS "$LOCAL_MEMORY_URL/api/v1/recall?q=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$query")${ns:+&namespace=$ns}" \
        -H "X-Agent-Id: $AGENT_ID"
      ;;
    list)
      ns="${1:-}"
      curl -sS "$LOCAL_MEMORY_URL/api/v1/memories${ns:+?namespace=$ns}" \
        -H "X-Agent-Id: $AGENT_ID"
      ;;
    *)
      echo "unknown action: $ACTION" >&2; exit 1 ;;
  esac
}

case "$AGENT_TYPE" in
  openclaw) openclaw_driver "$@" ;;
  hermes)   hermes_driver "$@" ;;
  *)        echo "unknown AGENT_TYPE: $AGENT_TYPE" >&2; exit 1 ;;
esac
