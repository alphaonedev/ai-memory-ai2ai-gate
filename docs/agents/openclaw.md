# OpenClaw agent

OpenClaw is a first-class agent framework in the A2A gate alongside
IronClaw (Rust) and Hermes (Python). On DigitalOcean the 8+ GB
install-time memory demand constrained the matrix to tier-upgraded
droplets; as of 2026-04-24 OpenClaw runs as a fully certified cell
on the **[local Docker mesh](../local-docker-mesh.md)** where each
openclaw node is allocated 16 GB of container memory on a workstation.
IronClaw is still the DO default for the Basic-tier 4 GB cost path
(~$0.03 per campaign).

The A2A gate hosts three OpenClaw agent instances (on `node-1`,
`node-2`, `node-3`) + one memory-only aggregator (`node-4`) to
demonstrate that ai-memory's A2A semantics work with the OpenClaw
agent framework's specific MCP client.

## What OpenClaw brings to the A2A gate

- An MCP-native agent runtime that invokes `memory_store`,
  `memory_recall`, and the rest of the ai-memory tool surface via
  stdio.
- Two different `agent_id` values (`ai:alice`, `ai:charlie`) so
  scenarios can assert agent-identity preservation and immutability
  across independent writers of the same framework.

## Per-node setup (`scripts/setup_openclaw_agent.sh` — to be written)

```
1. apt-get update + install runtime deps
2. Install OpenClaw from release tarball or container image
3. Configure MCP client to target node-4:
     AI_MEMORY_MCP_ENDPOINT=http://10.260.0.14:9077
     AI_MEMORY_AGENT_ID=ai:alice   # or ai:charlie on node-3
4. Provision the scenario-runner script from the ship-gate
   conventions
5. Health-check: agent CLI `openclaw version` + echo-request to
   ai-memory
```

## Why two OpenClaw agents and not one

Scenarios 6 (contradiction detection) and 7 (scoping visibility)
both require at least three distinct `agent_id` values to
exercise their full assertion matrix:

- Agent A writes something
- Agent B writes a contradicting or scope-boundary-testing
  something
- Agent C, the uninvolved third party, recalls and must see the
  state

Two OpenClaw agents + one Hermes agent satisfies "≥ 3 distinct
agents" while also exercising the "same-framework × different-
agent-id" axis that catches identity-preservation bugs specific
to OpenClaw's MCP client implementation.

## What the A2A gate measures against OpenClaw

- Correctness of tool invocation under the MCP schema (validated
  by `memory_store` responses carrying the expected `id` field).
- Identity preservation on each write (`metadata.agent_id` on the
  returned row matches the caller's).
- Scope honoring (agent A's `private`-scope writes invisible to
  agent C's recall).

If a release of OpenClaw changes MCP client behaviour in a way
that breaks these assertions, the A2A gate will flag it the next
time a campaign runs.

## Version pinning

The specific OpenClaw release tested in each campaign is recorded
in the artifact as `openclaw_version`. Reviewers comparing
campaigns across time can filter on that field.

Pinning policy: the A2A gate defaults to the latest stable OpenClaw
release available at campaign-dispatch time. Override via a
workflow input when intentionally testing against a specific
version.

## Related

- [Hermes agent](hermes.md) — the other framework under test.
- [Topology](../topology.md) — where OpenClaw agents sit in the
  VPC.
- [Methodology](../methodology.md) — the full scenario matrix.
