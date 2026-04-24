# IronClaw agent

The A2A gate's **primary Rust-based agent framework**, replacing
OpenClaw as of 2026-04-21. Hosted on `node-1` (`ai:alice`) and
`node-3` (`ai:charlie`) in every ironclaw campaign.

Upstream: [github.com/nearai/ironclaw](https://github.com/nearai/ironclaw)

## Why IronClaw replaces OpenClaw

OpenClaw is a Python-based agent framework whose install-time
dependency graph pulls ~8 GB of ML / native packages. The a2a-gate
harness consistently OOM'd during openclaw install on anything
smaller than a DO 16 GB droplet (see `docs/incidents.md` r18). DO's
General Purpose 16 GB slug is account-tier-restricted. Two paths
out: (a) pay for the tier bump, or (b) run openclaw via the
[local Docker mesh](../local-docker-mesh.md) which allocates 16 GB
per container on a single workstation — no DO bill required.

IronClaw is a Rust reimplementation from NEAR AI, advertising
feature parity for agentic-loops + tool-use + MCP-client. Observed
resource profile:

| Dimension | OpenClaw | IronClaw |
|---|---|---|
| Runtime | Python + ML deps | Rust binary |
| Install-time RAM | > 8 GB (r18 OOM) | < 1 GB |
| Steady-state RAM | heavy | ~50–500 MB |
| DO Basic droplet fit | no (needs 16 GB tier) | yes (`s-2vcpu-4gb`) |
| Cost per campaign | ~$0.36 / hr | ~$0.03 / hr |
| MCP client | ✅ (stdio) | ✅ (stdio) |
| xAI Grok via OpenAI-compat | ✅ | ✅ |

## What IronClaw brings to the A2A gate

- MCP-native agent runtime (`ironclaw mcp add memory --transport stdio
  --command ai-memory --arg ... --env AI_MEMORY_AGENT_ID=$AGENT_ID`).
- Two independent `agent_id` values (`ai:alice`, `ai:charlie`) so
  scenarios can assert agent-identity preservation and immutability
  across independent writers of the same framework.
- Rust-on-Rust stack with ai-memory — deterministic, low-overhead
  test substrate. No Python GC pauses, no pip version skew.
- Same thesis-integrity profile as every other a2a-gate agent group:
  `a2a_gate_profile = shared-memory-only`, all messaging channels
  disabled, gateway pinned to local, only ai-memory MCP registered.

## Per-node setup (via `scripts/setup_node.sh` case `ironclaw)`)

1. **Install PostgreSQL 15 + pgvector** — ironclaw persists its own
   agent memory in a local postgres (does NOT affect the ai-memory
   substrate, which stays SQLite-backed). Provisioned via
   `apt-get install postgresql postgresql-15-pgvector`, started via
   `systemctl start postgresql`, `CREATE EXTENSION vector`.
2. **Install ironclaw** — official installer script:
   ```bash
   curl --proto '=https' --tlsv1.2 -LsSf \
     https://github.com/nearai/ironclaw/releases/latest/download/ironclaw-installer.sh | sh
   ```
   Binary symlinked to `/usr/local/bin/ironclaw` for deterministic
   `PATH` across SSH sessions.
3. **Bootstrap `.env`** at `/root/.ironclaw/.env` with:
   - `DATABASE_URL` (local postgres)
   - `LLM_BACKEND=openai_compatible`
   - `LLM_BASE_URL=https://api.x.ai/v1`
   - `LLM_API_KEY=$XAI_API_KEY`
   - `LLM_MODEL=$A2A_GATE_LLM_MODEL` (default `grok-4-0709`)
   - Mode `chmod 600`
4. **`ironclaw config init --force`** — scaffold default
   `~/.ironclaw/config.toml`.
5. **Thesis-integrity lockdowns** via `ironclaw config set`:
   - `channels.telegram.enabled=false`
   - `channels.discord.enabled=false`
   - `channels.slack.enabled=false`
   - `gateway.mode=local`
   - `a2a_gate_profile=shared-memory-only`
   - `a2a_gate_profile_version=1.0.0`
6. **Register ai-memory MCP** — the sole tool surface:
   ```bash
   ironclaw mcp add memory \
     --transport stdio \
     --command ai-memory \
     --arg --db --arg /var/lib/ai-memory/a2a.db \
     --arg mcp --arg --tier --arg semantic \
     --env "AI_MEMORY_AGENT_ID=$AGENT_ID" \
     --description "Shared-memory A2A via ai-memory (a2a-gate)"
   ```
7. **Verify** — `ironclaw mcp list` must show `memory`, else FATAL.

## Baseline attestations on every ironclaw node

`a2a-baseline.json` emitted by `scripts/setup_node.sh` asserts the
following fields true on every ironclaw agent before scenarios run:

| Field | Check |
|---|---|
| `is_authentic` | `/usr/local/bin/ironclaw` resolves to an upstream binary path containing `ironclaw` (not a symlink to a different CLI) |
| `fw_version` | `ironclaw --version` first-line captured into attestation |
| `mcp_registered` | `ironclaw mcp list \| grep memory` |
| `has_xai` | `.env` has `LLM_BASE_URL=https://api.x.ai/v1` + `LLM_MODEL=$SKU` |
| `default_xai` | `.env` has `LLM_BACKEND=openai_compatible` |
| `has_mem` | `ironclaw mcp list --verbose` references `ai-memory` command |
| `has_aid` | `ironclaw mcp list --verbose` carries `AI_MEMORY_AGENT_ID=$AGENT_ID` |
| `a2a_master_off` | `ironclaw config get gateway.mode` == `local` |
| `no_chat_channels` | all three `channels.*.enabled` settings are `false` |
| `tools_are_memory_only` | exactly one MCP server registered and it is `memory` |
| `profile_locked` | `ironclaw config get a2a_gate_profile` == `shared-memory-only` |

Any `false` in the generated baseline blocks scenario dispatch.

## Scenarios covered (shared with openclaw/hermes)

IronClaw campaigns exercise the full 14-scenario spectrum listed in
[Test book](../testbook.md). Scenarios are agent-group-agnostic: they
drive ai-memory's HTTP surface directly, so the agent framework
under test only affects baseline attestation and substrate
provenance, not scenario logic.

## Dispatch

From the [A2A gate workflow](https://github.com/alphaonedev/ai-memory-ai2ai-gate/actions/workflows/a2a-gate.yml):

- **`agent_group`**: `ironclaw`
- **`campaign_id`**: `a2a-ironclaw-<release>-rN`
- **`agent_droplet_size`**: `s-2vcpu-4gb` (default; Basic-tier friendly)
- **`ai_memory_git_ref`**: the ai-memory release or commit under test
- **`llm_model`**: defaults to `grok-4-0709` (Grok 4.2 reasoning)

Evidence lands at `runs/<campaign_id>/` and is surfaced on
[the Pages dashboard](https://alphaonedev.github.io/ai-memory-ai2ai-gate/runs/).

## Open items

- **v1 lockdown set is best-effort** — IronClaw's config schema is
  still evolving; we pin the visible A2A surfaces and will refine as
  the upstream surfaces solidify.
- **PostgreSQL dependency** adds ~30s to per-droplet provision time
  vs a pure-SQLite agent. Acceptable; still completes within the
  per-node provisioning budget.
- **NEAR AI account not required** — we route LLM traffic directly
  to xAI Grok via the OpenAI-compatible endpoint; no NEAR AI
  credentials ever hit the droplet.
