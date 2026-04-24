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
#   AGENT_TYPE      — ironclaw | hermes | openclaw
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

# Agent CLI drivers. Two authentic frameworks, each with its own
# invocation surface. Both resolve xAI Grok as the LLM backend and
# ai-memory as the only MCP server — but the reasoning layer is
# genuinely different, which is the whole point of the A2A gate.
#
#   openclaw → openclaw/openclaw CLI, ~/.openclaw/openclaw.json,
#              xAI via OpenAI-compatible provider.
#   hermes   → NousResearch/hermes-agent CLI, ~/.hermes/config.yaml,
#              xAI native via --provider xai.

agent_cli() { command -v "$AGENT_TYPE" >/dev/null 2>&1; }

# openclaw headless prompt. Per docs.openclaw.ai/cli:
#   openclaw run --non-interactive -p "<prompt>"
#   --format json     machine-readable output
#   --max-tool-rounds bound the agent loop per scenario call
#   Config lives in ~/.openclaw/openclaw.json (MCP + provider).
#
# hermes: hermes chat -Q --provider xai --model $A2A_GATE_LLM_MODEL -q "<prompt>"
#   Source /etc/ai-memory-a2a/hermes.env first for XAI_API_KEY.
#   Model SKU parameterized via $A2A_GATE_LLM_MODEL (default grok-4-0709 =
#   Grok 4.2 reasoning). Override for cost-optimized runs (#4).
: "${A2A_GATE_LLM_MODEL:=grok-4-0709}"
agent_prompt() {
  case "$AGENT_TYPE" in
    openclaw)
      openclaw run \
        --non-interactive \
        --format json \
        --max-tool-rounds 20 \
        -p "$1"
      ;;
    hermes)
      set -a; . /etc/ai-memory-a2a/hermes.env; set +a
      hermes chat -Q \
        --provider xai \
        --model "$A2A_GATE_LLM_MODEL" \
        -q "$1"
      ;;
    ironclaw)
      # ironclaw headless prompt. xAI OpenAI-compatible backend is
      # configured in ~/.ironclaw/.env; LLM_BACKEND=openai_compatible
      # + LLM_BASE_URL=https://api.x.ai/v1 + LLM_MODEL make this a
      # single-flag invocation. If a future ironclaw version renames
      # chat -> run or changes the prompt flag, update here.
      ironclaw chat -p "$1"
      ;;
  esac
}

openclaw_driver() {
  if agent_cli; then
    case "$ACTION" in
      store)
        title="${1:?title required}"; content="${2:?content required}"
        ns="${3:-scenario}"
        if agent_prompt "Store a memory in namespace ${ns} titled \"${title}\" with content: ${content}. Use the ai-memory MCP memory_store tool."; then return; fi
        ;;
      recall)
        query="${1:?query required}"; ns="${2:-}"
        if agent_prompt "Recall memories matching \"${query}\"${ns:+ in namespace ${ns}} using the ai-memory MCP memory_recall tool. Return the JSON result verbatim."; then return; fi
        ;;
      list)
        ns="${1:-}"
        if agent_prompt "List memories${ns:+ in namespace ${ns}} using the ai-memory MCP memory_list tool. Return the JSON result verbatim."; then return; fi
        ;;
      *)
        echo "unknown action: $ACTION" >&2; exit 1 ;;
    esac
  fi
  # Agent CLI not installed OR invocation failed — fall back to the
  # deterministic ai-memory HTTP surface so the scenario exercises the
  # tool-dispatch layer regardless of upstream CLI version drift.
  # Pass through the driver's positional args so fallback_driver's
  # `${1:?title required}` etc. resolve correctly.
  fallback_driver "$@"
}

hermes_driver() {
  if agent_cli; then
    case "$ACTION" in
      store)
        title="${1:?title required}"; content="${2:?content required}"
        ns="${3:-scenario}"
        if agent_prompt "Store a memory: namespace=${ns} title=\"${title}\" content=${content} via the ai-memory MCP memory_store tool."; then return; fi
        ;;
      recall)
        query="${1:?query required}"; ns="${2:-}"
        if agent_prompt "Recall on \"${query}\"${ns:+ namespace=${ns}} via the ai-memory MCP memory_recall tool; output JSON."; then return; fi
        ;;
      list)
        ns="${1:-}"
        if agent_prompt "List memories${ns:+ namespace=${ns}} via the ai-memory MCP memory_list tool; output JSON."; then return; fi
        ;;
      *)
        echo "unknown action: $ACTION" >&2; exit 1 ;;
    esac
  fi
  fallback_driver "$@"
}

# Fallback when the agent CLI isn't installed OR its invocation
# fails (ironclaw 0.26.0 removed `chat`; hermes CLI may Python-
# traceback on pre-release builds). Drives ai-memory directly via
# HTTP, exercising the same tool-dispatch layer the agent would have
# routed to. TLS-aware: when TLS_MODE is tls/mtls, use HTTPS +
# --cacert + (under mtls) client cert — otherwise curl gets
# `Received HTTP/0.9 when not allowed` on the TLS daemon.
fallback_driver() {
  local curl_flags=()
  if [ "${TLS_MODE:-off}" != "off" ]; then
    curl_flags+=(--cacert "${TLS_CA:-/etc/ai-memory-a2a/tls/ca.pem}")
    if [ "${TLS_MODE}" = "mtls" ]; then
      curl_flags+=(
        --cert "${TLS_CLIENT_CERT:-/etc/ai-memory-a2a/tls/client.pem}"
        --key "${TLS_CLIENT_KEY:-/etc/ai-memory-a2a/tls/client.key}"
      )
    fi
  fi
  case "$ACTION" in
    store)
      title="${1:?title required}"; content="${2:?content required}"
      ns="${3:-scenario}"
      curl -sS "${curl_flags[@]}" -X POST "$LOCAL_MEMORY_URL/api/v1/memories" \
        -H "X-Agent-Id: $AGENT_ID" \
        -H "Content-Type: application/json" \
        -d "{\"tier\":\"mid\",\"namespace\":\"$ns\",\"title\":\"$title\",\"content\":\"$content\",\"priority\":5,\"confidence\":1.0,\"source\":\"api\",\"metadata\":{\"agent_id\":\"$AGENT_ID\"}}"
      ;;
    recall)
      query="${1:?query required}"; ns="${2:-}"
      curl -sS "${curl_flags[@]}" "$LOCAL_MEMORY_URL/api/v1/recall?q=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$query")${ns:+&namespace=$ns}" \
        -H "X-Agent-Id: $AGENT_ID"
      ;;
    list)
      ns="${1:-}"
      curl -sS "${curl_flags[@]}" "$LOCAL_MEMORY_URL/api/v1/memories${ns:+?namespace=$ns}" \
        -H "X-Agent-Id: $AGENT_ID"
      ;;
    *)
      echo "unknown action: $ACTION" >&2; exit 1 ;;
  esac
}

ironclaw_driver() {
  if agent_cli; then
    case "$ACTION" in
      store)
        title="${1:?title required}"; content="${2:?content required}"
        ns="${3:-scenario}"
        if agent_prompt "Store a memory: namespace=${ns} title=\"${title}\" content=${content} via the ai-memory MCP memory_store tool."; then return; fi
        ;;
      recall)
        query="${1:?query required}"; ns="${2:-}"
        if agent_prompt "Recall on \"${query}\"${ns:+ namespace=${ns}} via the ai-memory MCP memory_recall tool; output JSON."; then return; fi
        ;;
      list)
        ns="${1:-}"
        if agent_prompt "List memories${ns:+ namespace=${ns}} via the ai-memory MCP memory_list tool; output JSON."; then return; fi
        ;;
      *)
        echo "unknown action: $ACTION" >&2; exit 1 ;;
    esac
  fi
  fallback_driver "$@"
}

case "$AGENT_TYPE" in
  ironclaw) ironclaw_driver "$@" ;;
  hermes)   hermes_driver   "$@" ;;
  openclaw) openclaw_driver "$@" ;;
  *)        echo "unknown AGENT_TYPE: $AGENT_TYPE" >&2; exit 1 ;;
esac
