# Topology

Authoritative description of the 4-node infrastructure every a2a-gate
campaign provisions. If this page and the Terraform module disagree,
Terraform wins — file an issue against the discrepancy.

## Homogeneous agent groups

Each campaign exercises **one** agent framework. A complete release-
validation cycle runs the workflow **twice**:

- **OpenClaw group**: 4 fresh droplets, three OpenClaw agents + one memory node.
  `campaign_id = a2a-openclaw-<release>-rN`.
- **Hermes group**: 4 fresh droplets, three Hermes agents + one memory node.
  `campaign_id = a2a-hermes-<release>-rN`.

Homogeneous groups isolate framework-specific regressions. An OpenClaw-
only campaign that fails while a Hermes-only campaign passes points at
the OpenClaw MCP client implementation, not at ai-memory. Cross-
framework interop is a separate campaign type, deferred to a future
variant.

## Every node runs `ai-memory serve` (4-peer federation mesh)

All four droplets run `ai-memory serve` with `--quorum-writes 2
--quorum-peers <other-three>`. A write on any node's local serve
synchronously acknowledges on the leader plus one other peer, then
post-quorum-fanouts to the remaining two (PR #309 detach behaviour
from v0.6.0). Agents always talk to their **local** ai-memory at
`http://127.0.0.1:9077` — no cross-node HTTP from an agent's
perspective. Federation handles replication.

### Why a dedicated memory-only node (node-4)?

Node-4 participates in the federation quorum but doesn't host an
agent. It's the aggregator query target for scenarios that need to
inspect cross-cluster state independently of any agent — e.g.
scenario 1 phase C verifies every row's `metadata.agent_id` matches
the original writer, which must be checked OUTSIDE the agent path
so the check isn't itself mediated by the agent framework under
test.

W=2 of N=4 means the cluster tolerates any single-node failure, so
a node-4 crash doesn't stop the campaign.

## Droplet roles

| Droplet | Public | Private | Image | Size | Role |
|---|---|---|---|---|---|
| `node-1` | SSH only | `10.260.0.x` | Ubuntu 24.04 | `s-2vcpu-4gb` | agent (ai:alice) + serve peer |
| `node-2` | SSH only | `10.260.0.x` | Ubuntu 24.04 | `s-2vcpu-4gb` | agent (ai:bob) + serve peer |
| `node-3` | SSH only | `10.260.0.x` | Ubuntu 24.04 | `s-2vcpu-4gb` | agent (ai:charlie) + serve peer |
| `node-4` | SSH only | `10.260.0.x` | Ubuntu 24.04 | `s-2vcpu-4gb` | memory-only (serve peer, no agent) |

`agent_droplet_size` is a workflow input — bump to `s-4vcpu-16gb`
for scenario 8 (Ollama auto-tagging).

The VPC CIDR `10.260.0.0/24` is distinct from the ship-gate's
`10.250.0.0/24` so both campaigns can run concurrently on the same
DigitalOcean account. VPC names bake in the agent_type, so both
groups can execute concurrently without conflict.

## Agent ↔ ai-memory wiring (MCP config)

Each agent droplet has an MCP configuration at
`/etc/ai-memory-a2a/mcp-config/config.json`:

```json
{
  "mcpServers": {
    "memory": {
      "command": "ai-memory",
      "args": ["--db", "/var/lib/ai-memory/a2a.db", "mcp"],
      "env": { "AI_MEMORY_AGENT_ID": "ai:alice" }
    }
  }
}
```

The agent framework (OpenClaw or Hermes) loads this file. When a
scenario prompts the agent, the agent chooses the appropriate
`memory_*` tool and invokes it over MCP stdio against the local
ai-memory. The `AI_MEMORY_AGENT_ID` env var stamps every store with
the right `metadata.agent_id` so identity preservation is
exercised end-to-end.

## Driving scenarios through the agent

`scripts/drive_agent.sh` is the single hand-off point at which
scenarios talk to the agent framework. It supports:

- `store <title> <content> [namespace]`
- `recall <query> [namespace]`
- `list [namespace]`

If the framework's CLI is installed (`openclaw` or `hermes` on
PATH), the driver uses it with `--mcp-config` pointing at the
generated config. If not, it falls back to direct HTTP against the
local ai-memory — same MCP tool dispatcher, just no LLM prompt
interpretation. That fallback is explicit so scenario scripts still
run end-to-end before the framework install commands are wired in.

## Network + firewall

- **DO Cloud Firewall** (single enforcement boundary):
  - SSH (22) from anywhere (runner-side outbound only in practice)
  - port 9077 from inside the VPC only (federation traffic)
  - ICMP inside the VPC
- **OS-tier UFW: explicitly DISABLED** at provision time. Ship-gate
  lesson: Ubuntu 24.04's default-on UFW interferes with loopback +
  VPC workloads.

## Authentication

- **Runner → droplets**: SSH with the campaign ed25519 key.
- **Agent → ai-memory**: loopback stdio MCP (no network auth).
- **Federation ai-memory ↔ ai-memory**: HTTP on port 9077 over the
  VPC. mTLS supported by v0.6.0 (PR #229) but not enabled for
  a2a-gate campaigns because cert rotation would dominate setup
  time. Production operators should enable `--tls-cert` +
  `--mtls-allowlist`.

## Lifecycle

1. GitHub Actions dispatches `a2a-gate.yml` with `agent_group=openclaw`
   OR `agent_group=hermes`.
2. Terraform provisions the 4-node VPC.
3. Every node runs `setup_node.sh` — installs ai-memory, starts
   `serve` with federation peers, and (for agent nodes) layers the
   agent framework with MCP config pointing at local ai-memory.
4. Scenarios run in sequence; each emits scenario-N.json.
5. Aggregator produces a2a-summary.json.
6. `generate_run_html.sh` renders tri-audience evidence HTML.
7. `terraform destroy` tears down regardless of outcome.
8. Dead-man switch backstop: `shutdown -P +480` on every droplet.

## Related

- [Methodology](methodology.md) — per-scenario mechanics.
- [Reproducing](reproducing.md) — run it yourself.
- [OpenClaw agent](agents/openclaw.md) + [Hermes agent](agents/hermes.md).
