# Baseline configuration — A2A standard

**Authoritative spec.** Every agent droplet of every campaign in this
repository MUST satisfy this baseline before scenarios are allowed to
run. The workflow (`.github/workflows/a2a-gate.yml`) enforces it; the
implementation is `scripts/setup_node.sh`; the per-node verification
artifact is `/etc/ai-memory-a2a/baseline.json` on each agent droplet,
collected back into `phase-reports/a2a-baseline.json` and embedded in
every run's evidence page.

If any field below is `false` on any agent node, the campaign halts
before scenario 1 runs. That is the hard gate. No exceptions, no
per-campaign overrides.

## Scope

Applies to all agent nodes (node-1 / node-2 / node-3) in every
`a2a-gate` campaign — both `agent_group=openclaw` and
`agent_group=hermes`. Node-4 is memory-only (no agent) and is not
subject to the agent-specific fields, but must still satisfy the
federation-membership field.

## The invariants

Two classes: **config attestation** (static: "the intent is set") and
**functional probes** (dynamic: "the intent works on the live wire").
Both must pass. Neither alone is sufficient.

### Config attestation (static)

| # | Invariant | Why it matters |
|---|---|---|
| C1 | Agent framework is the authentic upstream binary | No surrogates, no symlinks to another CLI. If we claim to test OpenClaw, the binary must be `openclaw/openclaw`. |
| C2 | Agent's LLM backend is xAI Grok (model `grok-4-fast-non-reasoning`) | Framework-vs-framework comparison is only meaningful when the reasoning model is held constant. Same model in both groups; only the agent scaffolding differs. |
| C3 | Agent's ONLY MCP server is `ai-memory` on the local node | Substrate isolation. Any result is attributable to one product, not a mixture of tools. |
| C4 | Agent ID is stamped into the MCP environment (`AI_MEMORY_AGENT_ID`) | Task 1.2 immutability contract from `ai-memory-mcp` — provenance of every memory write must survive through the MCP stdio path. |
| C5 | Local `ai-memory serve` is a member of the 4-node W=2/N=4 federation mesh | The substrate under test. Scenarios assume quorum semantics hold; they can't if the daemon isn't live and peered. |
| C6 | Ubuntu UFW firewall is DISABLED on every node (agent and memory-only) | Ship-gate r21/r23 lesson: UFW on 24.04 blocks loopback/intra-VPC traffic in subtle ways. Every `setup_node.sh` runs `ufw --force reset && ufw --force disable` and verifies; provision **hard-fails** (exit 3) if UFW is still active. |

### Functional probes (dynamic, run BEFORE any scenario)

| # | Invariant | What the probe actually does |
|---|---|---|
| F1 | xAI Grok is reachable and the API key authenticates | Direct `POST https://api.x.ai/v1/chat/completions` with model `grok-4-fast-non-reasoning`, trivial prompt (`max_tokens=10`). Passes if response has non-empty `.choices[0].message.content`. Independent of the agent framework — tests the raw LLM layer. |
| F2 | Agent → MCP → ai-memory canary succeeds end-to-end | Drive the agent (via `openclaw run --non-interactive -p` or `hermes chat -Q -q`) with a prompt: *"Use the ai-memory MCP memory_store tool to save title=canary-<id>, content=<uuid>, namespace=`_baseline_canary`"*. Then `GET /api/v1/memories?namespace=_baseline_canary` on local serve and confirm the uuid is there with `metadata.agent_id == AGENT_ID`. Proves: agent reasoning → tool selection → MCP stdio → ai-memory write → provenance stamp. |

**Diagnostic separation:** If F1 fails but config attestation passes, the LLM is broken (bad key, network, xAI outage). If F2 fails but F1 passes, the MCP dispatch or agent tool-selection is broken. If F1 passes and F2 passes, the full stack is live and scenarios will run.

### Gate

| # | Invariant | Why it matters |
|---|---|---|
| G1 | The full baseline is asserted by `/etc/ai-memory-a2a/baseline.json` on the node itself, **before** any scenario executes | A self-attesting node. The workflow collects the attestation; the dashboard renders it per campaign. |
| G2 | `baseline_pass = conjunction(all of C1..C6, F1, F2)` | One false → job halts → zero scenarios run → dashboard shows `⚠️ BASELINE VIOLATION`. |

## Per-framework configuration surfaces

Both frameworks express the same baseline through their own
idiomatic config formats. This table makes the equivalence explicit.

| Aspect | OpenClaw | Hermes |
|---|---|---|
| Binary source | `openclaw/openclaw` via `curl -fsSL https://openclaw.ai/install.sh \| bash` | `NousResearch/hermes-agent` via `curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh \| bash` |
| Config file | `~/.openclaw/openclaw.json` | `~/.hermes/config.yaml` |
| Config format | JSON | YAML |
| LLM provider | `providers.xai` (OpenAI-compatible type) with `base_url=https://api.x.ai/v1` | Native xAI via `--provider xai` flag |
| Model | `default_model: grok-4-fast-non-reasoning` | `--model grok-4-fast-non-reasoning` |
| MCP server key | `mcpServers.memory` (object, keyed by name) | `mcp_servers.memory` (underscored, keyed by name) |
| MCP command | `ai-memory` | `ai-memory` |
| MCP args | `["--db", "/var/lib/ai-memory/a2a.db", "mcp", "--tier", "semantic"]` | Same |
| Agent ID env | `env.AI_MEMORY_AGENT_ID` | `env.AI_MEMORY_AGENT_ID` |
| CLI registration | Also registered via `openclaw mcp set memory ...` | Registered via `config.yaml` (no CLI equivalent) |
| Headless invocation | `openclaw run --non-interactive --format json --max-tool-rounds 20 -p "<prompt>"` | `hermes chat -Q --provider xai --model grok-4-fast-non-reasoning -q "<prompt>"` |

## Baseline verification — the `/etc/ai-memory-a2a/baseline.json` contract

Every agent node emits this file at the end of `setup_node.sh`. The
workflow halts if any node's `baseline_pass` is not `true`.

```json
{
  "agent_type": "openclaw",
  "agent_id": "ai:alice",
  "node_index": "1",
  "framework_version": "openclaw v2026.4.x",
  "ai_memory_version": "0.6.0",
  "peer_urls": "http://10.251.0.102:9077,http://10.251.0.103:9077,http://10.251.0.104:9077",
  "baseline": {
    "framework_is_authentic": true,
    "mcp_server_ai_memory_registered": true,
    "llm_backend_is_xai_grok": true,
    "llm_is_default_provider": true,
    "mcp_command_is_ai_memory": true,
    "agent_id_stamped": true,
    "federation_live": true
  },
  "baseline_pass": true
}
```

Every field in `baseline` is checked from the node's actual state
(not the intent): `jq` against the real `~/.openclaw/openclaw.json`
or `~/.hermes/config.yaml`, `readlink` on the binary to confirm
it's not a surrogate, `curl` against `127.0.0.1:9077/api/v1/health`
to confirm the daemon is live. `baseline_pass` is the conjunction
of all of them.

## Reproducing the baseline on a single node

To verify a new host — or any machine you'd like to integrate as a
fifth peer — the same script is the single source of truth:

```bash
export NODE_INDEX=5                      # any unused index
export ROLE=agent                        # or memory-only
export AGENT_TYPE=openclaw               # or hermes
export AGENT_ID=ai:dave                  # any ai:-prefixed id
export PEER_URLS="http://<peer-1>:9077,http://<peer-2>:9077,http://<peer-3>:9077"
export AI_MEMORY_VERSION=0.6.0
export XAI_API_KEY=...                   # required on agent nodes

bash scripts/setup_node.sh               # runs every step
cat /etc/ai-memory-a2a/baseline.json     # must show baseline_pass: true
```

That's it. The CI workflow runs exactly those steps per droplet —
nothing special happens inside GitHub Actions. Any node provisioned
by this script, anywhere, is baseline-equivalent to a campaign
agent droplet.

## Why these invariants, in three audiences

### For non-technical readers

We test two different AI "scaffoldings" (OpenClaw and Hermes) side
by side. For the comparison to mean anything, every test subject
has to be set up the same way: same AI brain (xAI Grok), same
memory system (ai-memory), same identity stamp, same network. The
baseline is the pre-flight checklist that guarantees we're holding
everything constant except the one thing we're comparing. If even
one node doesn't pass the checklist, we refuse to run the test —
better no data than misleading data.

### For C-level readers

The baseline turns a soft claim ("both agents are configured to use
ai-memory and xAI Grok") into a hard, per-run, per-node cryptographic
attestation that the workflow enforces. It's the compliance story:
every result in the dashboard is backed by a `baseline.json` on each
node proving the comparison was fair. If you audit the evidence
six months from now, you can tell exactly what was installed on
each droplet of the campaign that produced that result.

### For engineers and architects

`setup_node.sh` is the spec-as-code. The JSON/YAML config files on
each droplet are the spec-as-data. `baseline.json` on each droplet
is the spec-verified attestation. The workflow fails closed — no
scenarios run unless all agent nodes attest. The attestation is
committed as evidence (`runs/<campaign-id>/a2a-baseline.json`) and
linkable to both the node's private IP and the dispatching
workflow run URL. End-to-end provenance from `git log` →
`setup_node.sh` → `baseline.json` → dashboard.

## Change control

Any change to this baseline is a semver-relevant harness change:

- Adding a new invariant is a **minor** harness version bump.
- Tightening an existing invariant (e.g., model version change) is
  a **minor** bump with explicit migration note in the changelog.
- Relaxing or removing an invariant is a **major** bump (requires
  narrative justification in `analysis/run-insights.json`).

The authoritative version of this page is
`docs/baseline.md` in [alphaonedev/ai-memory-ai2ai-gate](https://github.com/alphaonedev/ai-memory-ai2ai-gate).
Any rendered copy (GitHub Pages, PDFs, internal mirrors) is a copy;
if they diverge, the file in the repository wins.
