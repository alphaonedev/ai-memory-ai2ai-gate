# Methodology

Every scenario is a discrete, independently-runnable test against
the 4-node topology. The campaign's `overall_pass` is the logical
AND of all enabled scenarios' `pass` flags. Each scenario's pass
criterion is explicit and measured against concrete JSON output.

## Pass/fail aggregation

Each scenario script writes a JSON report to
`runs/<campaign-id>/scenario-N.json` with the schema:

```json
{
  "scenario": 1,
  "pass": true,
  "reasons": [""],
  "<scenario-specific-fields>": "..."
}
```

The aggregator (`scripts/collect_reports.sh`, modelled on
ship-gate's) produces `a2a-summary.json`:

```json
{
  "campaign_id": "...",
  "ai_memory_git_ref": "release/v0.6.0",
  "completed_at": "2026-04-20T20:00:00Z",
  "overall_pass": true,
  "scenarios": [ ... ]
}
```

Campaign workflow fails the build on `overall_pass: false`.

## Scenarios (full methodology link-outs)

1. **[Per-agent write + read](scenarios/1-write-read.md)** —
   foundational round-trip. Each agent writes to its own
   `agent_id` namespace; each agent recalls memories written by
   the other two. Asserts payload equality, `agent_id`
   immutability, and scope enforcement at the most basic level.
2. **[Shared-context handoff](scenarios/2-handoff.md)** —
   explicit A2A pattern. Agent A writes a `handoff-to-B` memory
   tagged with scope=`team`. Agent B recalls within a bounded
   window. Tests the canonical request-response agent flow.
3. **[Targeted share](scenarios/3-targeted-share.md)** —
   exercises the `memory_share` MCP tool from issue
   [ai-memory-mcp#311](https://github.com/alphaonedev/ai-memory-mcp/issues/311)
   when that capability is present (v0.6.0.1+). Tests point-to-
   point subset push.
4. **[Federation-aware agents](scenarios/4-federation.md)** —
   run a 3-peer federation mesh (agents' local ai-memory replicas
   under `--quorum-writes 2`). Agent A writes to node-4; agent B
   reads from its local replica after convergence.
5. **[Consolidation + curation](scenarios/5-consolidation.md)** —
   agents write a burst of similar memories. `memory_consolidate`
   is invoked. Validates that `metadata.consolidated_from_agents`
   preserves the full author set.
6. **[Contradiction detection](scenarios/6-contradiction.md)** —
   two agents write logically conflicting memories. A third agent
   recalls on the topic and must see both plus the `contradicts`
   link.
7. **[Scoping visibility](scenarios/7-scoping.md)** — exhaustive
   matrix: each scope (private / team / unit / org / collective)
   written by each agent, then recalled by every other agent from
   every scope position. Asserts the Task 1.5 visibility contract.
8. **[Auto-tagging](scenarios/8-auto-tagging.md)** — opt-in. Agent
   writes without tags; auto-tagger runs (requires Ollama-enabled
   droplet size); another agent recalls by generated tag.

## Per-scenario timeouts

- Scenarios 1-3, 6, 7: ~30 s each (direct MCP calls).
- Scenario 4: ~3 min (federation settle).
- Scenario 5: ~1 min (consolidation run).
- Scenario 8: ~5 min when enabled (Ollama embedder warm-up).

Campaign workflow has a 60-min ceiling per job. The in-droplet
dead-man switch destroys infrastructure at 8 hours regardless.

## What the A2A gate does NOT cover

- **Cross-cloud A2A.** All four droplets are same-region, same-
  VPC. Cross-cloud (DO ↔ AWS) is a future variant.
- **Human-in-the-loop supervision.** Agents run autonomously here.
  Approval-gated pending writes (see ai-memory-mcp pending-
  approval pipeline) are exercised in a separate campaign.
- **Adversarial-agent scenarios.** We test cooperation, not
  byzantine behaviour. Agent misbehaviour detection is a v0.7+
  topic, probably in a separate gate.
- **Large-corpus performance.** The A2A gate runs on 10s-to-100s
  of memories per scenario. Throughput benchmarking lives in the
  ai-memory-mcp `bench/` directory, run separately.
- **LLM quality of results.** We assert that memories written by
  Agent A are retrievable by Agent B. We don't assert that Agent B
  makes good decisions with them — that's the agent's problem,
  not ai-memory's.

## Claim shape

The A2A gate emits **boolean pass/fail claims about inter-agent
memory semantics** under the documented topology and fault model.
It does not claim:

- Memory recall quality ranking (ADR-0001 in ai-memory-mcp covers
  that shape).
- Bounded-time convergence under adversarial conditions.
- Performance or throughput.

A green A2A gate is evidence that **the specified A2A semantics
hold under the specified conditions**. Operators extending this
campaign to their own use cases should add their own scenarios
rather than reinterpret the existing ones.

## Related

- [Topology](topology.md) — 4-node VPC architecture.
- Each scenario page in [Scenarios](scenarios/1-write-read.md) —
  concrete methodology per test group.
