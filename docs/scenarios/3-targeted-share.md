# Scenario 3 — Targeted share

## Purpose

Exercise the `memory_share` MCP tool from
[ai-memory-mcp#311](https://github.com/alphaonedev/ai-memory-mcp/issues/311)
— point-to-point subset push. One agent hand-picks a set of
memories and sends them to a specific recipient, rather than
relying on the shared store's mesh propagation.

This scenario is **skipped when the capability is absent**
(pre-v0.6.0.1 ai-memory) and reported as `pass: null`.

## Mechanics

1. Agent A (`ai:alice`) writes 20 memories into
   `scenario3-source` namespace with assorted tags.
2. Agent A invokes `memory_share` with selection predicates:
    - 5 specific `--id` values
    - Everything tagged `priority-high` (asserted to be 5 rows)
    - `--last 3` (the 3 most recently updated)
    - Target: Agent C's `ai-memory serve` on node-3.
3. Agent C recalls on `scenario3-source` namespace.
4. The returned set is compared against Agent A's expected
   hand-picked selection.

## Pass criterion

- If `memory_share` tool is absent: `pass: null`, reason =
  `"memory_share not present in ai-memory-mcp — scenario skipped"`.
- If present: the memories Agent C received exactly match the
  union of Agent A's three selection predicates (deduplicated by
  id).
- `insert_if_newer` semantics respected — if Agent C already had
  a newer version of any shared memory, it's not overwritten.

## Report shape

```json
{
  "scenario": 3,
  "pass": true,
  "capability_present": true,
  "selected_ids": ["uuid1", "uuid2", ...],
  "delivered_ids": ["uuid1", "uuid2", ...],
  "exact_match": true,
  "reasons": [""]
}
```

## What a green result proves

- Operators CAN explicitly hand-curate context for another
  agent's memory, not just rely on mesh propagation.
- The NHI-to-NHI "please take these specific memories" flow
  works end-to-end across agent frameworks.

## What a red result would mean

- `memory_share` selection logic bug (delivered set doesn't match
  predicates).
- Recipient-side validation failure (Agent C's `ai-memory serve`
  rejected the payload).
- Authentication misconfigured between A's client and C's server.

## For three audiences

=== "End users"

    Think of this as "Agent A carefully picks a handful of
    memories and personally delivers them to Agent C." It's the
    opposite of Agent A yelling into a crowd and hoping Agent C
    is listening. Useful when Agent A wants to be deliberate
    about what Agent C sees.

=== "C-level"

    The v0.6.0.1 `memory_share` capability is tested end-to-end
    on real infrastructure. If present, green means the feature
    works across agent frameworks. If absent (pre-0.6.0.1), the
    scenario is cleanly skipped so the overall gate doesn't
    spuriously fail against older ai-memory builds.

=== "Engineers"

    Tests the union of three selection predicates. Asserts
    `insert_if_newer` semantics on the recipient. `capability_
    present: false` short-circuits with `pass: null` so the
    aggregator can distinguish "doesn't apply to this build" from
    "failed."
