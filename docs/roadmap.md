# Testing Roadmap

Forward-looking plan for the ai2ai-gate harness. This document complements `docs/testbook.md` (what scenarios we run today) and `docs/methodology.md` (how we run them) by tracking what will be added once the current baseline converges to green.

## Phase 1 — Current (OpenClaw + Hermes, Grok 4.2 reasoning)

- Two agent groups: **OpenClaw** and **Hermes**, both running against xAI Grok reasoning (`grok-4-0709`, parameterized via `A2A_GATE_LLM_MODEL`).
- 16 scenarios from `1` through `18` exercising the full ai-memory HTTP + MCP surfaces.
- 4-node federation mesh on DigitalOcean `s-2vcpu-4gb` droplets, W=2/N=4 quorum.
- F1–F4 baseline probes (xAI reachability, substrate canary, MCP canary, directional mesh connectivity) must pass before any scenario runs.
- **Exit criterion:** at least one green run per agent group against ai-memory ≥ v0.6.1 with all 16 scenarios passing.

## Phase 2 — Claude Managed Agents (planned, post-Phase 1 green)

**Source:** <https://platform.claude.com/docs/en/managed-agents/overview>

Once Phase 1 is consistently green across OpenClaw + Hermes on Grok 4.2 reasoning, the harness will add a third agent group — **Claude Managed Agents** — running against Anthropic's Claude API.

### Model under test
- **Default:** Claude Haiku 4.5 (`claude-haiku-4-5-20251001`) — Anthropic's lowest-cost production model, chosen to keep A2A campaign budget bounded while still exercising the managed-agent runtime.
- Override via a new workflow input `claude_model` matching the pattern already used for `llm_model` (Grok SKU).

### Infrastructure reuse
- Same 4-node DigitalOcean topology as Phase 1.
- Same 16 scenarios (or a compatibility-filtered subset if Claude Managed Agents cannot express some scenario-1 MCP stdio semantics).
- Same F1–F4 baseline gates.
- New baseline probes:
  - **F5 — Claude API reachability + auth**: parallel to F1 xAI reachability, hitting `https://api.anthropic.com/v1/messages` with a READY-style canary.
  - **F6 — Claude Managed Agent control-plane handshake**: spawn a minimal managed agent, verify it registers + responds + terminates cleanly. Attestation-only initially (non-blocking, like F2b).

### Workflow dispatch changes
- New `agent_group` option: `claude-managed`.
- New input `claude_api_key_secret` referencing a repo secret (parallel to `XAI_API_KEY`).
- `baseline.md` updated to document the new agent type + F5/F6.

### Why Haiku 4.5 for the default
- Cheapest Claude production model: acceptable per-campaign cost for an A2A gate that runs on every release.
- Still strong enough at tool-use + reasoning to exercise the substrate; if a scenario fails on Haiku that passes on Sonnet/Opus, that's a real signal about the ai-memory HTTP surface's tolerance for lower-temperature / shorter-context reasoning.
- Higher-tier models (Sonnet 4.6 / Opus 4.7) remain available via `claude_model` override for targeted investigation campaigns.

### Timing
- **NOT started until:** Phase 1 has ≥1 consecutive green run of all 16 scenarios on both OpenClaw and Hermes.
- **Preconditions:** v0.6.1 shipped, scenarios audited against the new endpoints added in v0.6.0.1 (delete/update/promote fanout, HTTP contradictions, partition catchup, sync_push embedding refresh).
- **First milestone after green:** pin a Phase-2 epic issue, author the Claude Managed Agents install path in `setup_node.sh`, author the F5/F6 probes, open a PR.

### Out of scope (for now)
- Multi-provider mixed groups (e.g. one node running Claude, another running Grok) — valid research question but not Phase-2 scope.
- Prompt-caching optimizations for Claude — only relevant if per-campaign cost becomes a blocker.
- Claude Agent SDK parity comparison vs Managed Agents — separate analysis campaign.

## Phase 3 — Future (not scheduled)

Candidates for later expansion, listed for completeness:

- **Anthropic Claude API without Managed Agents** using the Agent SDK directly — parallel track to Phase 2 if managed-agent restrictions prove limiting.
- **Gemini + Vertex** agent group if Google publishes a managed-agent runtime comparable to Anthropic/Claude.
- **Chaos extensions**: network-partition scenarios run as first-class ai2ai-gate campaigns (currently lives in `ai-memory-ship-gate` Phase 4).
- **Sustained-load campaigns**: 30-minute write/read soak per agent group, gating for memory leaks and long-tail latency regression.

## How to propose changes to this roadmap

Open an issue with label `roadmap` + a brief prior-art survey and cost estimate. The biologic's directive governs prioritization. AI-NHI-proposed additions require biologic approval before entering this document.
