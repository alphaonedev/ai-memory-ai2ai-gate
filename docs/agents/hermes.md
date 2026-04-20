# Hermes agent

The A2A gate hosts one Hermes agent instance (on `node-2`) to
demonstrate that ai-memory's A2A semantics work with a second,
independently-implemented agent framework's MCP client.

## What Hermes brings to the A2A gate

- A framework-independent validation axis. If scenarios pass for
  OpenClaw but fail for Hermes (or vice versa), the regression
  is framework-specific, not ai-memory-specific — which is
  exactly what the A2A gate exists to distinguish.
- A third `agent_id` value (`ai:bob`) to round out the minimum-
  three-agents requirement for scenarios 6 and 7.
- A different MCP client library than OpenClaw's, which catches
  subtle schema-compatibility bugs that might be hidden inside a
  single implementation.

## Per-node setup (`scripts/setup_hermes_agent.sh` — to be written)

```
1. apt-get update + install runtime deps
2. Install Hermes from release tarball or container image
3. Configure MCP client to target node-4:
     AI_MEMORY_MCP_ENDPOINT=http://10.260.0.14:9077
     AI_MEMORY_AGENT_ID=ai:bob
4. Provision the scenario-runner script
5. Health-check: agent CLI `hermes version` + echo-request to
   ai-memory
```

## What the A2A gate measures against Hermes

Same contract as OpenClaw — tool-invocation correctness, identity
preservation, scope honoring — but exercised through Hermes's MCP
client to catch any framework-specific divergence.

Where the assertions in scenarios differ between OpenClaw and
Hermes (they shouldn't, but if they do), each framework's
per-scenario behaviour is recorded separately so divergences are
visible.

## Framework-to-framework handoff

Scenario 2 (shared-context handoff) specifically tests the flow:

- Agent A on node-1 (OpenClaw) writes a handoff memory.
- Agent B on node-2 (Hermes) recalls it.
- The memory round-trips cleanly between two different MCP client
  implementations talking to the same ai-memory store.

A red result on this scenario where the ship-gate is green
narrows the diagnostic immediately: the regression is in one of
the two frameworks' MCP clients, not in ai-memory's server
handlers.

## Version pinning

Same convention as OpenClaw — `hermes_version` is recorded in
every scenario artifact. Defaults to latest stable; overridable
via workflow input.

## Related

- [OpenClaw agent](openclaw.md) — the companion framework.
- [Topology](../topology.md) — where Hermes sits in the VPC.
- [Methodology](../methodology.md) — the full scenario matrix.
