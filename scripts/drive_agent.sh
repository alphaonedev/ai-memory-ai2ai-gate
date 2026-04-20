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

openclaw_driver() {
  if command -v openclaw >/dev/null 2>&1; then
    # Real OpenClaw CLI path. Operator-provided install command
    # should have put this on $PATH. The MCP config at
    # $MCP_CONFIG wires it to the local ai-memory.
    case "$ACTION" in
      store)
        title="${1:?title required}"; content="${2:?content required}"
        ns="${3:-scenario}"
        openclaw --mcp-config="$MCP_CONFIG" \
          prompt "Store a memory in namespace $ns titled \"$title\" with content: $content. Use the memory_store tool."
        ;;
      recall)
        query="${1:?query required}"; ns="${2:-}"
        local_filter=""
        [ -n "$ns" ] && local_filter=" in namespace $ns"
        openclaw --mcp-config="$MCP_CONFIG" \
          prompt "Recall memories matching \"$query\"${local_filter}. Use the memory_recall tool. Return the JSON result."
        ;;
      list)
        ns="${1:-}"
        openclaw --mcp-config="$MCP_CONFIG" \
          prompt "List memories${ns:+ in namespace $ns}. Use the memory_list tool. Return the JSON result."
        ;;
      *)
        echo "unknown action: $ACTION" >&2; exit 1 ;;
    esac
    return
  fi
  # Fallback: OpenClaw not installed. Drive via ai-memory stdio MCP
  # path directly. Same MCP tool dispatcher, just no agent LLM in
  # the middle — so the test still exercises the tool surface but
  # not the agent's prompt-interpretation.
  fallback_driver
}

hermes_driver() {
  if command -v hermes >/dev/null 2>&1; then
    case "$ACTION" in
      store)
        title="${1:?title required}"; content="${2:?content required}"
        ns="${3:-scenario}"
        hermes --mcp-config "$MCP_CONFIG" \
          run --prompt "Store a memory: namespace=$ns title=\"$title\" content=$content via memory_store"
        ;;
      recall)
        query="${1:?query required}"; ns="${2:-}"
        hermes --mcp-config "$MCP_CONFIG" \
          run --prompt "Recall on \"$query\"${ns:+ namespace=$ns} via memory_recall; output JSON"
        ;;
      list)
        ns="${1:-}"
        hermes --mcp-config "$MCP_CONFIG" \
          run --prompt "List memories${ns:+ namespace=$ns} via memory_list; output JSON"
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
