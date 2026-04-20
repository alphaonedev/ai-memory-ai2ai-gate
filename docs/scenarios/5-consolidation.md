# Scenario 5 — Consolidation + curation

## Purpose

Agents accumulate repetitive or overlapping memories naturally.
The `memory_consolidate` MCP tool folds them into a single
canonical memory. This scenario validates that consolidation
preserves agent-identity provenance — which author contributed
which source memory — through the collapse.

## Mechanics

1. Agent A writes 10 similar memories about topic X in the
   `scenario5-consolidation` namespace.
2. Agent B writes 10 more, also about topic X, slightly different
   phrasings.
3. Agent A invokes `memory_consolidate` with target namespace +
   topic filter.
4. Consolidation runs (may invoke Ollama on a scenario-8-capable
   droplet; falls back to heuristic consolidation otherwise).
5. Agent C recalls on the namespace.
6. Assertions:
    - Count of consolidated memories is 1 (or a small number if
      multiple clusters formed).
    - The consolidated memory's `metadata.consolidated_from_agents`
      is a set containing both `ai:alice` and `ai:bob` —
      provenance preserved.
    - The consolidator's `metadata.agent_id` is `ai:alice` (the
      invoker) — consolidation is an action by the invoking agent.
    - The source 20 memories are archived, not deleted (per the
      consolidation contract).

## Pass criterion

- Consolidated count < 20 (reduction happened).
- `consolidated_from_agents` contains both `ai:alice` and `ai:bob`
  exactly once each.
- `metadata.agent_id` on the consolidated row = the invoker.
- Source memories present in the archive table.

## Report shape

```json
{
  "scenario": 5,
  "pass": true,
  "source_count": 20,
  "consolidated_count": 1,
  "provenance_agents": ["ai:alice", "ai:bob"],
  "invoker_agent_id": "ai:alice",
  "archive_intact": true,
  "reasons": [""]
}
```

## What a green result proves

- Curation doesn't silently drop authorship. Over time, even as
  the memory store consolidates, operators can still see which
  agents contributed which information.
- The invoker's `agent_id` is the authoritative author of the
  consolidation action itself — critical for audit trails.

## What a red result would mean

- Consolidation dropping one author from `consolidated_from_agents`
  (partial provenance loss).
- Consolidation overwriting the invoker's `agent_id` or clearing it.
- Archive not populated — source memories lost instead of
  preserved (a serious correctness regression).

## For three audiences

=== "End users"

    As agents accumulate knowledge, the system combines repetitive
    memories into one. This scenario proves the combination doesn't
    lose track of which agent contributed what. Nothing disappears
    from the record — old memories just move to an archive.

=== "C-level"

    Audit posture: "who said what, when" must survive memory
    consolidation. A compliance reviewer asking for the
    provenance of a consolidated memory gets the full list of
    contributing agents, not a lossy summary. This scenario is
    that guarantee on record.

=== "Engineers"

    Tests the `consolidated_from_agents` array invariant and the
    `ai-memory archive` contract. Also validates that the
    consolidator's own `agent_id` is correctly set on the output
    row (the invoker-is-author semantics, not the upstream-
    authors-are-authors semantics).
