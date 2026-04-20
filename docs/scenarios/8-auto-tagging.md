# Scenario 8 — Auto-tagging

## Purpose

ai-memory's autonomous curator can auto-generate tags for
memories that were written without them, using an on-node LLM
(Ollama). This scenario validates that auto-generated tags round-
trip through agent frameworks — specifically, that an agent can
later recall by a tag it never explicitly wrote.

**Opt-in.** Requires the droplets to be sized `s-4vcpu-16gb` (Gemma
4 E2B needs the RAM). Default A2A campaigns skip this scenario
because the cost delta is significant.

## Mechanics

When enabled (`auto_tag=true` workflow input):

1. All four droplets are provisioned at `s-4vcpu-16gb` with Ollama
   and a pinned Gemma-4-E2B model.
2. Agent A writes 20 memories in `scenario8-autotag` namespace
   with no explicit tags. Content is varied enough that
   distinguishable tags can be generated.
3. The ai-memory curator is invoked on node-4 with
   `memory_auto_tag` on the namespace.
4. Curator generates tags per memory via the local LLM.
5. Agent B recalls with a tag filter matching one of the
   generated tags.
6. Assertion: Agent B's recall returns at least one memory whose
   generated tags include the filter tag.

## Pass criterion

- Auto-tagger runs without errors.
- At least 50% of the 20 memories receive at least one generated
  tag (reasonable-coverage heuristic).
- Agent B's tag-filter recall returns a non-empty set.
- `metadata.agent_id` preservation: the tags are generated, but
  the original writer's `agent_id` stays put.

## Report shape

```json
{
  "scenario": 8,
  "pass": true,
  "capability_enabled": true,
  "memories_tagged": 18,
  "tag_coverage_ratio": 0.9,
  "recall_count_by_tag": 7,
  "authorship_preserved": true,
  "reasons": [""]
}
```

When scenario 8 is disabled (default): `pass: null`,
`capability_enabled: false`, reason = `"auto_tag=false — scenario
skipped"`. Aggregator treats null as "not applicable" for
overall_pass computation.

## What a green result proves

- The autonomous curator's tag-generation pipeline works end-to-
  end with local LLM inference on real DigitalOcean droplets.
- Agents can recall by tags they didn't write, enabling emergent
  discovery across agent boundaries.

## What a red result would mean

- Ollama/Gemma integration regression — tags not generated.
- Tag storage path regression — tags generated but not returned
  on recall.
- Agent identity regression — tag generation overwriting the
  original writer's `agent_id`.

## For three audiences

=== "End users"

    When enabled, your agents can discover each other's memories
    through automatically-generated tags, without anyone having
    to explicitly label what they wrote. It's the
    autoclassification layer that makes a shared memory actually
    navigable as it grows.

=== "C-level"

    Differentiating feature: most memory stores require manual
    taxonomy management. ai-memory's optional LLM-backed auto-
    tagging removes that overhead. This scenario is the
    end-to-end evidence that the feature works on real
    infrastructure. The cost/benefit — 3× droplet cost for
    LLM-capable sizing — is documented so operators can
    decide per-campaign whether to exercise it.

=== "Engineers"

    Exercises `memory_auto_tag` + Ollama integration + the tag-
    filter read path in sequence. Coverage threshold (≥ 50%) is
    heuristic because LLMs are non-deterministic; we're testing
    that the pipeline RUNS, not that every memory gets a tag.
    Retry/rerun strategy documented in the scenario script
    for handling transient LLM failures.
