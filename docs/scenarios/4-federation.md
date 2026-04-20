# Scenario 4 — Federation-aware agents

## Purpose

Validate that agents running their own local ai-memory replica
(backed by the ship-gate-validated 3-peer federation mesh) behave
identically to agents hitting a single authoritative store. The
A2A promise must hold whether operators deploy centrally or
decentrally.

## Mechanics

1. Reconfigure: in addition to node-4's authoritative serve, stand
   up a mini 3-peer federation on nodes 1/2/3 (each node's
   ai-memory runs in `--quorum-writes 2 --quorum-peers <other two>`
   mode) pointed at each other. node-4 stays as the "central"
   store for comparison.
2. Agent A on node-1 writes 50 memories via its LOCAL ai-memory
   replica under quorum.
3. Wait the ship-gate Phase 2 settle bound (90 s).
4. Agent B on node-2 recalls via its LOCAL ai-memory replica.
5. Compare Agent B's recall count against Agent A's write count
   and enforce ≥ 95% convergence per the Phase 2 pass criterion.
6. Run quorum probes analogous to Phase 2: kill node-3's serve,
   confirm Agent A's next write still returns 201. Kill node-2's
   serve too, confirm the next write returns 503.

## Pass criterion

- Convergence ≥ 95% of `ok` writes on both surviving peers after
  90 s settle.
- Quorum probes classify correctly (one-peer-down → 201, both-
  peers-down → 503).

## Report shape

```json
{
  "scenario": 4,
  "pass": true,
  "writes_ok": 50,
  "converged_node1": 50,
  "converged_node2": 50,
  "probe_one_peer_down": "201",
  "probe_both_peers_down": "503",
  "reasons": [""]
}
```

## What a green result proves

- Agents can run local ai-memory replicas with correct A2A
  semantics. No single-point-of-failure required.
- The ship-gate Phase 2 guarantees extend cleanly to the A2A
  layer — nothing in the agent framework breaks quorum.

## What a red result would mean

- A regression between the ship-gate (which passes the same
  test) and the A2A harness's federation configuration. Either
  the harness misconfigured quorum, or a subtle interaction
  with the agent framework's MCP transport changed behaviour.

## For three audiences

=== "End users"

    This is the test that proves you don't need a central server
    for your agents to talk through ai-memory. If you deploy
    three agents each with its own local copy, they'll stay in
    sync automatically.

=== "C-level"

    Deployment flexibility is a customer-facing feature. This
    scenario proves the same correctness guarantees hold in the
    decentralized topology as in the centralized one. A red
    here means either topology breaks; a green means both work.

=== "Engineers"

    Re-runs ship-gate Phase 2's 200-write / 95%-convergence /
    quorum-probe contract, but through real MCP clients under
    agent workloads rather than synthetic curl bursts. Catches
    divergence between the HTTP-direct Phase 2 story and the
    MCP-client-initiated A2A story.
