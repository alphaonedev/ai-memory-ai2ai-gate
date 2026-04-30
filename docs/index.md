# ai-memory A2A gate

<!--
  Latest release banner is rendered from releases/<highest-semver>/summary.json
  by the `render_current_release` macro defined in ../main.py. To bump the
  surfaced release, add a new releases/<vX.Y.Z>/summary.json with verdict
  "pass" — no edits to this file required. Schema lives in releases/schema.json
  and is enforced on tag push by .github/workflows/release-summary-gate.yml.
-->
{{ render_current_release() }}

Reproducible AI-to-AI integration testing for
[ai-memory-mcp](https://github.com/alphaonedev/ai-memory-mcp). Where
[ai-memory-ship-gate](https://github.com/alphaonedev/ai-memory-ship-gate)
validates the memory system itself, **this repository validates what
happens when real AI agents use ai-memory to communicate with each
other** — **IronClaw (Rust)**, **Hermes (Python)**, and **OpenClaw
(Python)** agents running on separate DigitalOcean droplets (or, for
the openclaw cell, the [local Docker mesh](local-docker-mesh.md)
that bypasses the DO General Purpose tier bump), sharing context
through a central ai-memory authoritative store.

- **[Baseline configuration](baseline.md)** · the hard-gated standard every agent droplet must satisfy before any scenario runs — authentic frameworks, xAI Grok, ai-memory MCP, UFW off, functional probes
- [Methodology](methodology.md) · every invariant this campaign defends
- [Topology](topology.md) · 4-node VPC architecture
- [Agents](agents/ironclaw.md) · IronClaw (Rust), Hermes (Python), and OpenClaw (Python) integration details
- [Local Docker mesh](local-docker-mesh.md) · Reproducible 4-node OpenClaw harness on a single workstation (no DO required)
- [Scenarios](scenarios/1-write-read.md) · 8 test groups covering the full memory surface
- [Campaign runs](runs/) · live evidence dashboard
- [v1.0 GA criteria](v1-ga-criteria.md) · the forward-looking contract every 0.6.x/0.7.x/0.8.x release steps toward
- [Reproducing](reproducing.md) · run it yourself on your own DO account
- [Security](security.md) · TLS, mTLS, dead-man switch, key custody

---

## Certification threshold

A2A-gate certification requires **three consecutive `overall_pass = true` runs at full scenario coverage** (up to 36 scenarios under the [testbook v3.0.0](testbook.md) × [baseline v1.4.0](baseline.md) set — 36 at `mtls`, 35 at `tls`, 34 at `off`). Any single `overall_pass = false` resets the counter; there is no credit for partial green.

**Current best (as of 2026-04-27): 48/48 on `ironclaw-mtls` at v0.6.3 — closing S18 (semantic expansion) and S39 (SSH STOP/CONT reliability), the residual blockers at v3r23 / v0.6.2.** Cert-run head commit: `release/v0.6.3 @ 2cfcc18`. Prior best was 37/37 on mtls / 35/35 on tls / 35/35 on off at v0.6.2 across ironclaw (DO), hermes (DO), and openclaw (local-docker).

**Consecutive green streak: 3 / 3 → v0.6.3 CERTIFIED (2026-04-27)** on `ironclaw-mtls` (campaign run #25021409589). Hermes and openclaw cells continue to publish per-release runs under [`runs/`](runs/); the v0.6.3 banner above tracks the headline ironclaw-mtls cell.

Testing is continuous; certification is forward-looking toward v1.0 GA. Every campaign run is published under [`runs/`](runs/) regardless of outcome — a red run is data, not a setback. See [v1.0 GA criteria](v1-ga-criteria.md) for what has to be true across ai-memory-mcp, ship-gate, and this repo for the `1.0` tag to cut.

This replaces earlier release-notes language on v0.6.0 and v0.6.1. Those releases were *validated against* the A2A-gate (per-release, against live infrastructure) — not *certified by* it. v0.6.2 was the first release to land three consecutive green runs at 36/36 on the headline mtls cells. **v0.6.3 extends that with 48/48 on `ironclaw-mtls`** — the new baseline (35) plus 4 auto-append plus 9 new scenarios introduced for v0.6.3 (capabilities v2, KG, entity, lifecycle).

---

## The 60-second pitch

ai-memory on its own is a persistent memory store. Its value lands
only when agents actually use it to maintain context, hand off tasks,
and share knowledge. The ship-gate campaign proves the substrate
works under load, under chaos, under migration. The A2A gate proves
that two heterogeneous AI agent frameworks — **IronClaw** (Rust)
and **Hermes** (Python) — can use that substrate to talk to each
other without private channels, without dedicated orchestration
layers, without any shared code except the ai-memory MCP interface.

Every scenario in this campaign is either a concrete inter-agent
use case or a safety invariant that protects those use cases. A
green A2A gate run is evidence that the shared-memory story is not
a slide deck — it runs every day on real droplets under real load.

---

## What this means to you

=== "End users (non-technical)"

    **Why should you trust that your AI agents can actually talk to
    each other through ai-memory?**

    Because on every release, three real AI agents — two IronClaw,
    one Hermes (or vice versa on the cross-framework campaign) —
    spin up on fresh cloud servers, write memories,
    read each other's memories, hand off tasks, detect
    contradictions, and propagate context exactly the way a real
    deployment would. Every handoff is measured. Every recall is
    checked. Every disagreement is surfaced to a third agent as
    evidence that the system notices when agents disagree.

    If a release breaks the ability of Agent A to see what Agent B
    just wrote, we find out in fifteen minutes and block the tag.
    If a release breaks contradiction detection or scoping
    visibility, same. You never get the breakage.

    Every campaign run is published as evidence. Every JSON artifact
    is in this repository and browsable from the
    [runs dashboard](runs/). No closed-box attestations.

=== "C-Level decision makers"

    **What business risk does the A2A gate buy down?**

    - **Integration risk.** Customers running multi-agent systems
      are the most demanding users of ai-memory. They need
      predictable, reproducible, safe agent-to-agent memory
      semantics. This campaign catches regressions in that surface
      before release.
    - **Vendor-lock-in objection, answered.** We test two different
      AI agent stacks (OpenClaw, Hermes) on the same ai-memory
      store — evidence that our memory substrate is
      framework-agnostic.
    - **Audit posture.** Every A2A test produces immutable JSON
      artifacts. A compliance reviewer asking "how do you know
      agents can't leak memories across scope boundaries?" gets a
      test artifact from this morning's campaign, not a narrative.
    - **Velocity.** A full A2A campaign runs in approximately 20
      minutes at ~$0.20 of DigitalOcean compute — a fourth droplet
      bumps spend slightly above the ship-gate's $0.10 baseline.
      Release signal stays under half an hour from dispatch.
    - **Release-gate stack.** Ship-gate green + A2A gate green is
      the combined pre-release signal. Shipping with either red
      carries risk; shipping with both green carries evidence.

=== "Engineers / architects / SREs"

    **What invariants does the A2A gate defend?**

    | Invariant | Scenario | Pass criterion |
    |---|---|---|
    | Every agent's writes reach every agent's recall | 1 | `recall` on node-N returns memories written by node-M, exact payload equivalence |
    | `agent_id` metadata is immutable across the round-trip | 1, 5 | `metadata.agent_id` of recalled row equals writer's id; also preserved through consolidate |
    | Shared-context handoff is synchronous enough for a request-response agent pattern | 2 | Agent B sees Agent A's handoff memory within the quorum-settle bound defined in ship-gate Phase 2 |
    | `memory_share` delivers subset sync when invoked | 3 | The specific ids/namespace/last-N set that A invoked lands on C with `insert_if_newer` semantics respected |
    | Quorum writes with W=2 of N=3 survive writer-peer pairing | 4 | All writes ok; settle + convergence identical to ship-gate Phase 2 contract |
    | `memory_consolidate` preserves the consolidated-from-agents provenance | 5 | `metadata.consolidated_from_agents` is the set of authors, not overwritten |
    | `memory_detect_contradiction` surfaces to an uninvolved third agent | 6 | Agent C's recall on the topic returns both A and B's memories plus the `contradicts` link |
    | Scope enforcement matrix holds across agents | 7 | Every (scope, caller_scope) pair produces the visibility specified in the Task 1.5 scope contract |
    | Auto-tag round-trip (opt-in) | 8 | Agent writes without tags; auto-tag pipeline runs; another agent recalls by generated tag and gets the row |

    Each scenario emits a structured JSON report with
    `{pass: bool, reasons: [...]}`. The aggregator produces
    `a2a-summary.json` with `overall_pass = all-scenarios-pass`.
    The workflow fails the build on false.

    See [Methodology](methodology.md) for the full mechanics and
    [Topology](topology.md) for network + auth layout.

---

## Goals of the A2A gate

1. **Prove that the shared-memory A2A story actually works** end-
   to-end on real multi-agent-framework workloads, not just
   single-process harnesses.
2. **Frame-agnostic validation.** Run two different agent stacks
   against the same memory; prove the interface is the contract,
   not the implementation.
3. **Publish evidence, not claims.** Every scenario's artifact
   lands in [`runs/`](runs/); every failure narrative lands in
   [`analysis/run-insights.json`](https://github.com/alphaonedev/ai-memory-ai2ai-gate/blob/main/analysis/run-insights.json).
4. **Catch regressions before they ship.** A red A2A gate blocks
   the customer-facing claim, regardless of ship-gate posture.
5. **Bound cost.** 4 droplets × ~20 min wall clock = ~$0.20 per
   clean run. In-droplet dead-man switch caps worst case at 8
   hours.
6. **Document what the A2A gate does NOT cover.** Cross-cloud
   A2A, human-in-the-loop agent supervision, and adversarial-agent
   scenarios are out of scope; see [Methodology § Out of scope](methodology.md).

---

## Position in the release protocol

| Stage | Harness | Validates |
|---|---|---|
| Unit + integration | `cargo test` in ai-memory-mcp | per-module correctness |
| Ship-gate Phases 1-4 | [ai-memory-ship-gate](https://github.com/alphaonedev/ai-memory-ship-gate) | single-node, 3-node federation, migration, chaos |
| **A2A gate (this repo)** | **ai-memory-ai2ai-gate** | **A2A communication through shared memory** |

A2A gate dispatches **after** the ship-gate returns
`overall_pass: true`. Both green → customer-facing claims supported.
Either red → release blocked until fixed.

---

## Cost per run

~$0.20 of DigitalOcean compute for a clean ~20-minute run. 4
droplets (3 × `s-2vcpu-4gb` for agents + 1 × `s-2vcpu-4gb` for the
authoritative store). Dead-man switch caps every droplet at 8 hours.
See [Security](security.md).

---

## Current status

Active on `release/v0.6.3` (commit `2cfcc18`, shipped 2026-04-27). The
`ironclaw-mtls` cell hit **48/48 green** on campaign run #25021409589 —
closing **S18 (semantic expansion)** and **S39 (SSH STOP/CONT reliability)**
which were the residual blockers at v3r23 / v0.6.2. Headline banner above
is regenerated from `releases/v0.6.3/summary.json`.

**Matrix** (2 frameworks × 3 transport modes, updated per campaign):

| | off | tls | mtls |
|---|---|---|---|
| **ironclaw** | tracked under `runs/` | tracked under `runs/` | **48 / 48 (v0.6.3) — CERT** |
| **hermes**   | tracked under `runs/` | tracked under `runs/` | tracked under `runs/` |
| **mixed**    | ⏸ topology              | ⏸ topology              | ⏸ topology                  |

Every campaign run — green, red, cancelled — is archived under [`runs/`](runs/). The live [README](https://github.com/alphaonedev/ai-memory-ai2ai-gate) tracks the latest dispatch and any in-flight campaigns.

---

## Release history

Every released `vX.Y.Z` ships a `releases/<version>/summary.json` artifact
that this page reads at build time. The highest-semver entry is the headline
banner at the top; the table below lists every published release in
reverse-chronological order.

{{ render_release_history() }}

The schema for `summary.json` lives in
[`releases/schema.json`](https://github.com/alphaonedev/ai-memory-ai2ai-gate/blob/main/releases/schema.json).
Pushing a `v*` tag without a matching `releases/<tag>/summary.json` fails the
release-blocking [`release-summary-gate`](https://github.com/alphaonedev/ai-memory-ai2ai-gate/actions/workflows/release-summary-gate.yml)
workflow before any artifact is published.
