# Scenario 6 — Contradiction detection

## Purpose

Two agents write logically conflicting memories. A third,
uninvolved agent must see both memories AND the `contradicts`
link between them on recall — not silently one-over-the-other.
The system must surface disagreement, not hide it.

## Mechanics

1. Agent A (`ai:alice`) writes into `scenario6-contradiction`:
    - `title`: "X status"
    - `content`: "X is true as of 2026-04-20."
2. Agent B (`ai:bob`) writes in the same namespace:
    - `title`: "X status"
    - `content`: "X is false as of 2026-04-20."
3. Agent A invokes `memory_detect_contradiction` with scope
   = the namespace.
4. Tool returns a `contradicts` link between the two memories.
5. Agent C (`ai:charlie`, uninvolved) recalls on the namespace
   with `include_links=true`.
6. Agent C's response must include:
    - Both A's and B's memories (no silent overwrite).
    - The `contradicts` link connecting them.

## Pass criterion

- `memory_detect_contradiction` returns a result with at least
  one contradicting pair identified.
- The contradicting pair is specifically (A's memory, B's
  memory), not something unrelated.
- Agent C's recall returns BOTH rows + the link.
- `metadata.agent_id` on both rows is preserved — authorship
  is intact.

## Report shape

```json
{
  "scenario": 6,
  "pass": true,
  "contradictions_detected": 1,
  "pair": ["uuid-a", "uuid-b"],
  "link_surfaced_to_third_party": true,
  "authorship_preserved": true,
  "reasons": [""]
}
```

## What a green result proves

- The system refuses to silently collapse conflicting facts into
  one. Operators see disagreement when it exists.
- Contradiction surfacing reaches agents that weren't party to
  the original disagreement — a third-party observer can audit.
- Authorship survives — critical for accountability when
  disagreements need resolution.

## What a red result would mean

- Contradiction detector failing to identify obvious logical
  conflicts (semantic regression).
- The `contradicts` link stored but not surfaced on recall
  (read-path regression).
- Silent overwrite (one memory replacing the other rather than
  coexisting with the conflict noted).

## For three audiences

=== "End users"

    When two of your AI agents disagree, the system tells a third
    agent about the disagreement instead of picking one at random.
    Your agents can reason about contradictions rather than stumble
    over them silently.

=== "C-level"

    Silent conflict resolution is a class of AI failure mode that
    creates serious business risk (one agent's claim quietly
    overrides another's). This scenario is the evidence that
    ai-memory surfaces conflicts for humans and agents to resolve
    explicitly. Audit posture: nothing is silently overwritten.

=== "Engineers"

    Exercises the `memory_detect_contradiction` tool and the
    typed-link read path in one go. Asserts that an uninvolved
    agent (Agent C) sees the `contradicts` link, which is the
    hard case — detection alone is necessary but not sufficient;
    propagation to third parties is the real A2A invariant.
