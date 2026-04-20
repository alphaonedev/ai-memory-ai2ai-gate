# Scenario 7 — Scoping visibility

## Purpose

ai-memory's Task-1.5 scope system defines how memories become
visible across agents at different namespace positions. This
scenario validates the full visibility matrix on real
infrastructure — no private memory leaks cross-scope, no team
memory fails to propagate within scope.

## The scope model (recap)

- **private** — visible only in the exact namespace the memory
  was written under.
- **team** — visible under any sibling namespace sharing the same
  immediate parent.
- **unit** — visible within the grandparent subtree.
- **org** — visible within a higher ancestor.
- **collective** — visible globally, cross-namespace.

## Mechanics

Each of the three agents writes one memory at each of the five
scopes, in namespaces laid out as:

```
org.unit.team.alice
org.unit.team.bob
org.unit.team.charlie
```

That's 15 memories total (3 agents × 5 scopes).

Each agent then recalls "as" its own namespace position, with
scope-filter logic applied server-side. The expected visibility
matrix is:

|  | alice writer, alice recalls | alice writer, bob recalls | alice writer, charlie recalls |
|---|---|---|---|
| private | ✅ | ❌ | ❌ |
| team | ✅ | ✅ | ✅ |
| unit | ✅ | ✅ | ✅ |
| org | ✅ | ✅ | ✅ |
| collective | ✅ | ✅ | ✅ |

(And symmetric for bob-writes, charlie-writes.)

"private" is the strict case: alice-private rows are NEVER
visible to bob or charlie. Every other scope propagates within
its own boundary.

## Pass criterion

Every (writer, reader, scope) tuple in the expected matrix
matches observed visibility. A single false-positive (bob sees
alice's private memory) or false-negative (bob doesn't see
alice's team memory) fails the scenario.

## Report shape

```json
{
  "scenario": 7,
  "pass": true,
  "matrix_observed": {
    "alice->bob": {"private": false, "team": true, "unit": true, "org": true, "collective": true},
    "alice->charlie": { ... },
    "bob->alice": { ... },
    "...": "..."
  },
  "matrix_expected_equals_observed": true,
  "reasons": [""]
}
```

## What a green result proves

- The scope system enforces its security contract: private means
  private, even across agents in the same namespace family.
- Team / unit / org / collective propagation works within its
  boundary — multi-agent teams can share context at the
  appropriate granularity.

## What a red result would mean

- **Over-sharing**: a lower-scope memory visible from a broader
  scope. Serious security regression — agents seeing memories
  they shouldn't.
- **Under-sharing**: a higher-scope memory invisible to an agent
  that should see it. Usability regression — broken agent
  collaboration.

Either direction fails the scenario and blocks the release.

## For three audiences

=== "End users"

    Your AI agents can have both private thoughts and shared
    thoughts, and the system keeps them separate. What you tell
    one agent privately stays with that agent. What you tell
    the team goes to the team. The system guards the boundary
    even when agents are collaborating.

=== "C-level"

    Scope enforcement is the multi-tenancy story — the evidence
    that agents operating on the same ai-memory store don't leak
    private context across tenant boundaries. A green scenario 7
    is the test-result you hand to a customer's security review
    when they ask "can agent X see agent Y's private memories?"
    The answer, backed by this campaign, is no.

=== "Engineers"

    3 writers × 3 readers × 5 scopes = 45 visibility observations.
    Asserts the full Task 1.5 contract. Catches regressions in
    `list_memories` / `recall` scope-filtering logic that unit
    tests miss because they don't exercise the multi-namespace
    hierarchy on real agent clients.
