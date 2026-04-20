# Scenario 1 — Per-agent write + read

## Purpose

The foundational A2A round-trip. Every other scenario is built on
the assumption that this one works; if it doesn't, nothing in the
A2A story does.

## Mechanics

1. Each of the three agents (`ai:alice`, `ai:bob`, `ai:charlie`)
   issues 10 `memory_store` MCP calls in its own namespace
   (`scenario1-<agent>`). Memories are well-formed, `source=api`,
   `scope=private` by default, no tags, random content.
2. Each agent then issues 10 `memory_recall` calls for memories
   written by *the other two* agents, via full-namespace match on
   the shared `scenario1-*` prefix.
3. Each recall's response is checked against the writer's stored
   row for payload equality and `metadata.agent_id` preservation.

## Pass criterion

- Every write returns an MCP response with a valid `id` and
  `agent_id` equal to the caller's expected value.
- Every recall returns the expected count of memories (≥ 20 per
  recaller, since each recaller excludes itself but should see
  the other two).
- Every recalled row's `metadata.agent_id` matches the original
  writer's, not the recaller's. (This is the immutability
  invariant from ai-memory-mcp CLAUDE.md §Agent Identity.)

## Report shape

```json
{
  "scenario": 1,
  "pass": true,
  "per_agent": {
    "ai:alice":   {"writes": 10, "recall_count": 20, "identity_preserved": true},
    "ai:bob":     {"writes": 10, "recall_count": 20, "identity_preserved": true},
    "ai:charlie": {"writes": 10, "recall_count": 20, "identity_preserved": true}
  },
  "reasons": [""]
}
```

## What a green result proves

- The MCP tool surface is callable from both OpenClaw and Hermes
  on real infrastructure.
- Writes durably reach the authoritative store.
- Reads return exactly the rows those writes produced.
- `agent_id` metadata is preserved — which is the foundational
  security invariant that every later scope check depends on.

## What a red result would mean

- MCP transport broken (check node-to-node-4 connectivity).
- `agent_id` propagation regression in ai-memory-mcp (recalled
  `metadata.agent_id` doesn't match the writer's).
- Namespace filtering regression (recall not returning the
  expected rows).

Diagnostic path: if scenario 1 is red, skip scenarios 2-8 —
nothing else is meaningful without this foundation.

## For three audiences

=== "End users"

    This tells you that three different AI agents, written in
    two different frameworks, can all write to a shared memory
    and read each other's memories correctly. It's the basic "do
    the agents actually talk through this system" check.

=== "C-level"

    Green means the foundational memory round-trip across agent
    frameworks is working. This is the floor — nothing else in
    the A2A story matters if this is red. A stable green on
    scenario 1 across time is the baseline evidence that the
    shared-memory substrate claim is real.

=== "Engineers"

    30 writes, 60 recalls across the three agents. Asserts the
    Task 1.2-established `metadata.agent_id` immutability
    contract end-to-end through real MCP clients on real network
    paths. Foundational test; a false here invalidates every
    downstream scenario.
