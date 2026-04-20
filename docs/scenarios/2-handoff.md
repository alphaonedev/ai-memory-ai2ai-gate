# Scenario 2 — Shared-context handoff

## Purpose

Test the canonical A2A pattern: one agent hands a piece of context
to another agent through shared memory within a synchronous-enough
window for a request-response flow to work.

## Mechanics

1. Agent A (`ai:alice`, OpenClaw on node-1) writes a memory with:
    - `namespace`: `scenario2-handoff`
    - `scope`: `team`
    - `tags`: `["handoff-to-B"]`
    - `content`: a unique token + timestamp
2. Agent A signals done (writes a sentinel memory).
3. Agent B (`ai:bob`, Hermes on node-2) polls `memory_recall` on
   the namespace + tag filter every 500 ms.
4. Agent B's recall must return A's memory within a bounded wall-
   clock window (default: the ship-gate Phase 2 settle of 90 s
   plus a 5 s grace).
5. Agent B extracts the token and writes a `handoff-ack` memory.
6. Agent A recalls the ack to confirm the round-trip.

## Pass criterion

- Agent B sees Agent A's handoff within the bounded window.
- Agent A sees Agent B's ack within the same bounded window.
- Token round-trips unchanged.
- `metadata.agent_id` on the recalled rows matches the writer's.

## Report shape

```json
{
  "scenario": 2,
  "pass": true,
  "handoff_ms": 734,
  "ack_ms": 812,
  "bound_ms": 95000,
  "token_integrity": true,
  "reasons": [""]
}
```

## What a green result proves

- Real A2A request-response agent patterns are viable through
  ai-memory at the timescales operators actually care about (sub-
  second to sub-minute handoffs).
- The scope=`team` visibility rule is permissive enough for A2A
  within a shared namespace, without leaking beyond it.
- Two different agent frameworks (OpenClaw ↔ Hermes) round-trip
  memory without any implementation-specific divergence.

## What a red result would mean

- Convergence time exceeds 95 s — could be federation-side (if
  node-4 is federated to peers we're also reading from) or
  product-side lag.
- Scope enforcement regression (agent B can't see the row at all).
- Framework-level MCP client difference in interpreting the recall
  filter — caught by the specific OpenClaw-writes / Hermes-reads
  pairing.

## For three audiences

=== "End users"

    This is the scenario that proves your AI agents can pass
    messages to each other through the memory system. When your
    assistant hands off a task to your scheduler agent, this is
    the round-trip that must work.

=== "C-level"

    This scenario directly maps to the customer-facing promise
    that agents can collaborate through ai-memory. A red result
    means the headline claim is unsupported and a release is
    blocked. The timing bound (95 s default) matches what
    customers need for typical agent-to-agent handoffs.

=== "Engineers"

    Specific tags + scope matrix: `scope=team` with namespace
    `scenario2-handoff` tagged `handoff-to-B`. Polls at 500 ms
    with a 95 s bound. Measured handoff time published in the
    artifact so regressions in convergence latency surface
    quantitatively, not just as a pass/fail.
