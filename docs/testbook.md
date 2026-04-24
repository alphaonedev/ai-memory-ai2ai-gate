# A2A test book — full spectrum

**The formal test plan for maximum-coverage AI-to-AI integration testing through ai-memory.**

Covers **same-node** A2A (two agent identities sharing a single droplet's ai-memory) and **between-node** A2A (agents on distinct droplets in the W=2/N=4 federation mesh) across every ai-memory primitive relevant to agent-to-agent coordination.

**Test book version:** 3.0.0 (2026-04-21)
**Changelog:**
- **3.0.0** — 100% A2A coverage: transport security (S20-S21), adversarial + cross-framework (S22-S27), every uncovered MCP primitive (S28-S37), every HTTP-only endpoint (S38-S42). 42 scenarios across 9 suites. Baseline bumped to v1.4.0 (adds F6 TLS handshake + F7 mTLS enforcement probes). Tracked in [EPIC #14](https://github.com/alphaonedev/ai-memory-ai2ai-gate/issues/14).
- **2.0.0** — full-spectrum expansion to 18 scenarios across 6 suites; adds mutation / lifecycle / resilience / observability / same-node A2A coverage
- **1.0.0** — initial 8-scenario core

Baseline [v1.4.0](baseline.md) must pass before any scenario runs. The test book assumes baseline green. F6 + F7 probes gate `baseline_pass` when `tls_mode ≥ tls` and `tls_mode = mtls` respectively.

---

## 1. Nine test suites, 42 scenarios

The scenario corpus is partitioned into suites so failures are diagnostically localized. A red result in Suite A tells a different story than a red in Suite G.

| Suite | Scenarios | What it proves |
|---|---|---|
| **A. Core A2A** | S1, S1b, S2 | Basic read/write visibility across agents; shared-context handoff |
| **B. A2A Primitives** | S3, S5, S6, S11 | `memory_share`, `memory_consolidate`, `memory_detect_contradiction`, `memory_link` — the tools agents reach for explicitly |
| **C. Mutation + Lifecycle** | S9, S10, S16 | `memory_update`, `memory_delete` / `memory_forget`, tier promotion across agents |
| **D. Scope + Governance** | S7, S8, S12 | Scope enforcement matrix, auto-tag pipeline, agent registration (Task 1.3) |
| **E. Resilience + Observability** | S13, S14, S15, S17, S18 | Concurrent contention, partition tolerance, read-your-writes, stats consistency, semantic query expansion |
| **F. Topology variants** | S4, S19 | Quorum-under-load, SAME-NODE A2A (two agents sharing one droplet's ai-memory) |
| **G. Transport + Adversarial + Cross-framework** (v3.0.0) | S20, S21, S22, S23, S24, S25, S26, S27 | mTLS happy-path, anonymous rejected, identity spoofing, malicious content fuzz, Byzantine peer, clock skew, mixed ironclaw+hermes, OpenClaw regression |
| **H. Uncovered primitives — 100% MCP surface** (v3.0.0) | S28, S29, S30, S31, S32, S33, S34, S35, S36, S37 | `memory_search`, archive lifecycle, `capabilities`, `gc`, `inbox`+`notify`, pub/sub, pending governance, namespace standards, `session_start`, `get_links` bidirectional |
| **I. HTTP-only endpoints — 100% REST surface** (v3.0.0) | S38, S39, S40, S41, S42 | `/export`+`/import`, `/sync/since` delta sync, `/memories/bulk`, `/metrics`, `/namespaces` |

**Coverage scorecard (v3.0.0 target)**: 37/37 MCP tools exercised, 27/27 HTTP endpoints exercised, 3 transport modes (http/tls/mtls), 3 agent groupings (ironclaw/hermes/mixed). Suites A–F are the v2.0.0 baseline; G–I are new in v3.0.0.

---

## 2. Scenario register

Each row is a one-line contract. Full per-scenario plans follow in §4.

| # | Name | Suite | Runnable on v0.6.0? | Primary invariant |
|---|---|---|---|---|
| S1 | Per-agent write + read (MCP-stdio) | A | ✅ (RED expected until #318 fix ships) | MCP write visible on local node |
| S1b | Per-agent write + read (HTTP) | A | ✅ | Quorum-HTTP write visible on peers |
| S2 | Shared-context handoff | A | ✅ | Writer's memory readable by recipient within quorum settle |
| S3 | Targeted `memory_share` | B | ⚠️ Requires v0.6.0.1 (#311) | Subset sync lands on exactly the targeted peer |
| S4 | Federation-aware concurrent writes | F | ✅ | Quorum preserved under N-agent concurrent write burst |
| S5 | Consolidation + curation | B | ✅ (HTTP-direct; LLM-consolidation variant deferred) | `consolidated_from_agents` metadata preserved |
| S6 | Contradiction detection | B | ✅ if `memory_detect_contradiction` in v0.6.0; else deferred | Contradicting memories produce a link visible to third agent |
| S7 | Scope visibility matrix | D | ⚠️ Partial (Task 1.5 scope enforcement ongoing) | Each (scope, caller_scope) pair produces the correct visibility |
| S8 | Auto-tagging round-trip | D | ⚠️ Requires Ollama-backed droplets (s-4vcpu-16gb) | Agent writes without tags; tags appear; recall-by-tag works |
| S9 | Mutation round-trip | C | ✅ | `memory_update` from agent A visible with new content on agent B |
| S10 | Deletion propagation | C | ✅ | `memory_delete` / `memory_forget` propagates to all peers |
| S11 | Link integrity | B | ✅ if `memory_link` exposed via HTTP; else documented-only | Linked memories returned together on peer query |
| S12 | Agent registration | D | ✅ (Task 1.3 shipped in v0.6.0) | `memory_agent_register` on A is visible to B's `memory_agent_list` |
| S13 | Concurrent write contention | E | ✅ | Two agents updating the same row converge to a consistent outcome |
| S14 | Partition tolerance | E | ✅ | Temporary peer loss → recovery → convergence within bounded time |
| S15 | Read-your-writes | E | ✅ | Writing agent sees its own write immediately (no settle required) |
| S16 | Tier promotion | C | ✅ if tier endpoint exposed | `short` → `mid` → `long` promotion visible to peers |
| S17 | Stats consistency | E | ✅ | `memory_stats` returns equal counts across peers post-settle |
| S18 | Semantic query expansion | E | ✅ | `memory_expand_query` returns semantically related memories across writers |
| S19 | **Same-node A2A** | F | ✅ (with topology override) | Two agents on ONE droplet share local ai-memory; writes + reads work without federation |
| S20 | mTLS happy-path | G | ✅ tls_mode=mtls | Write+read round-trip over HTTPS with client-cert on the allowlist |
| S21 | Anonymous client rejected | G | ✅ tls_mode=mtls | rustls rejects the TLS handshake when no client cert is presented |
| S22 | Identity spoofing resistance | G | ✅ any tls_mode | X-Agent-Id/body resolution precedence honored; transport identity not bypassable |
| S23 | Malicious content fuzz | G | ✅ any tls_mode | SQLi / NUL / oversize / unicode round-trip faithfully or reject cleanly |
| S24 | Byzantine peer | G | ✅ any tls_mode | Tampered `sync_push` — metadata.agent_id preserved as declared, no silent re-attribution |
| S25 | Clock skew (300s) | G | ✅ any tls_mode | Vector clock still converges with node-3 offset +300s |
| S26 | Mixed ironclaw + hermes on same VPC | G | ⚠️ requires `agent_group=mixed` | Heterogeneous A2A through shared ai-memory |
| S27 | Legacy OpenClaw regression | G | ⚠️ requires `agent_group=openclaw` | Pre-ironclaw regression lane |
| S28 | `memory_search` keyword A2A | H | ✅ | Keyword search (distinct from recall/expand_query) consistent across peers |
| S29 | `memory_archive` lifecycle | H | ✅ | archive_list/purge/restore/stats round-trip cross-peer |
| S30 | `memory_capabilities` handshake | H | ✅ v0.6.2+ | Protocol version + tool surface match across peers |
| S31 | `memory_gc` quiescence | H | ✅ | After forget+gc, non-deleted rows remain readable on all peers |
| S32 | `memory_inbox` + `memory_notify` | H | ⚠️ requires inbox feature | Notify delivers to target's inbox; non-target cannot read |
| S33 | pub/sub via `memory_subscribe` | H | ⚠️ requires sub feature | Subscribe→write→delivery→unsubscribe→no-delivery |
| S34 | `memory_pending_*` governance flow | H | ⚠️ requires governance.write=approve | Approve vs reject yields correct downstream visibility |
| S35 | `memory_namespace_*_standard` rule layering | H | ✅ | Parent chain rules merged into namespace standard |
| S36 | `memory_session_start` lifecycle | H | ✅ | Session-tagged writes recall by session_id only |
| S37 | `memory_get_links` explicit bidirectional | H | ✅ | Forward and reverse link traversal both return the pair |
| S38 | `/export` + `/import` round-trip | I | ✅ | Export one peer → import elsewhere → stats match |
| S39 | `/sync/since` delta sync | I | ✅ | Post-partition delta returns exactly the missed rows |
| S40 | `/memories/bulk` bulk write | I | ✅ | 500-row bulk POST reaches all peers + aggregator |
| S41 | `/metrics` Prometheus shape | I | ✅ | Required counters present and monotonic post-activity |
| S42 | `/namespaces` enumeration | I | ✅ | Namespace list (with counts) equivalent across peers |

---

## 3. Coverage by ai-memory primitive

Which scenario tests which tool. Empty cells = not directly exercised.

| ai-memory primitive | Scenarios |
|---|---|
| `memory_store` | S1, S1b, S2, S4, S5, S9, S10, S11, S13, S14, S15, S18, S19 |
| `memory_recall` | S1, S1b, S2, S4, S5, S15, S18 |
| `memory_list` | S2, S6, S7, S11 |
| `memory_get` | S6, S11 |
| `memory_update` | S9, S13 |
| `memory_delete` / `memory_forget` | S10 |
| `memory_share` | S3 |
| `memory_link` | S11 |
| `memory_consolidate` | S5 |
| `memory_detect_contradiction` | S6 |
| `memory_auto_tag` | S8 |
| `memory_agent_register` / `memory_agent_list` | S12 |
| `memory_stats` | S17 |
| `memory_promote` (tier) | S16 |
| `memory_expand_query` | S18 |
| Federation: quorum write | S1b, S2, S4, S9, S10, S13 |
| Federation: partition tolerance | S14 |
| Federation: convergence | S17 |
| Scope enforcement (Task 1.5) | S7 |
| `metadata.agent_id` immutability (Task 1.2) | S1, S1b, S2, S5, S6, S7, S9 |

**Saturation**: every primitive listed in the ai-memory-mcp tool catalog is covered by at least one scenario.

---

## 4. Per-scenario plans

Each plan has the same six sections: Objective · Pre-conditions · Procedure · Pass criteria · Failure modes · Evidence.

### Suite A — Core A2A

#### S1 — Per-agent write + read (MCP-stdio path)
- **Objective**: Proves that an agent framework can accept a natural-language prompt, select the `memory_store`/`memory_recall` tool, invoke it via MCP stdio, and the memory lands on the local substrate with correct `metadata.agent_id`.
- **Pre-conditions**: Baseline v1.2.0 green. F2a passed (substrate up). F2b is the scoped-down version of this scenario.
- **Procedure**: Each of 3 agents drives 10 `memory_store` calls via MCP into `scenario1-<agent-id>`. After 15s settle, each agent recalls the other two namespaces. Node-4 aggregator is queried independently.
- **Pass criteria**: Every reader sees ≥ 20 memories (10 from each of the other 2 writers). `metadata.agent_id` stamped on every row matches the writer.
- **Failure modes**:
  - `recall 0` on all readers + local HNSW index grew → MCP stdio writes bypass federation fanout (substrate bug [#318](https://github.com/alphaonedev/ai-memory-mcp/issues/318))
  - Agent CLI crash → agent framework install gap
- **Evidence**: `scenario-1.json` + `scenario-1.log` with per-agent recall counts, identity-check dump from node-4.

#### S1b — Per-agent write + read (HTTP path)
- **Objective**: Same invariant as S1 but bypasses MCP stdio. Proves the federation layer works independent of the MCP-stdio substrate bug. Green-path counterpart to S1.
- **Pre-conditions**: Baseline v1.2.0 green. F3 green (federation live).
- **Procedure**: Each of 3 agents `POST /api/v1/memories` to local serve HTTP into `scenario1b-<agent-id>`. 15s settle. Each reader counts other-namespace rows via local HTTP.
- **Pass criteria**: Every reader sees ≥ 20 rows with correct `metadata.agent_id`.
- **Failure modes**: Federation fanout broken (all 0 rows on peers) → PR #309 regression. Partial replication (1 peer sees, 2 don't) → quorum threshold issue.
- **Evidence**: `scenario-1b.json` + `scenario-1b.log`.

#### S2 — Shared-context handoff
- **Objective**: Prove an agent can drop a handoff memory that another agent picks up within bounded settle. This is the "task handed from A to B" primitive.
- **Pre-conditions**: S1b green.
- **Procedure**: Agent A (`ai:alice` on node-1) writes `scenario2-handoff/handoff-to-bob` with content describing a task. Settle 8s. Agent B (`ai:bob` on node-2) queries that namespace + title. Agent B writes `scenario2-handoff/ack-from-bob` with its acknowledgement. Settle 8s. Agent A reads the ack.
- **Pass criteria**: B sees the exact handoff payload with `metadata.agent_id = ai:alice`. A sees the exact ack payload with `metadata.agent_id = ai:bob`.
- **Failure modes**: B sees nothing → settle too short OR fanout failed. B sees handoff but A doesn't see ack → asymmetric replication (one direction works, other doesn't).
- **Evidence**: `scenario-2.json`.

### Suite B — A2A Primitives

#### S3 — Targeted share
- **Objective**: `memory_share` delivers a specific subset of memories from A to C without C querying (push semantics).
- **Pre-conditions**: Requires ai-memory v0.6.0.1 (#311) — memory_share CLI + MCP tool not in v0.6.0. **DEFERRED** until v0.6.0.1 ships.
- **Procedure (documented for when runnable)**: A writes 10 memories. A invokes `memory_share --target=ai:charlie --namespace=<X>`. Settle. C lists namespace. C sees the 10 rows with `metadata.shared_from: ai:alice`.
- **Pass criteria**: C sees exactly the shared set. B (`ai:bob`) does NOT see them (targeted, not broadcast).
- **Evidence**: `scenario-3.json`.

#### S5 — Consolidation + curation
- **Objective**: `memory_consolidate` produces a single memory whose `metadata.consolidated_from_agents` lists all contributing agents in correct order, preserving provenance.
- **Pre-conditions**: S1b green.
- **Procedure**: All 3 agents write 3 related memories to `scenario5-consolidate` (9 rows total). Request consolidation via HTTP (`POST /api/v1/memories/consolidate` if exposed, else CLI). Read back the consolidated memory from a 4th peer.
- **Pass criteria**: Consolidated memory has `metadata.consolidated_from_agents` set to `[ai:alice, ai:bob, ai:charlie]`. All three original memories still recoverable.
- **Failure modes**: Consolidation drops provenance (empty `consolidated_from_agents`). Consolidation deletes originals before consolidation row replicates.
- **Evidence**: `scenario-5.json`.

#### S6 — Contradiction detection
- **Objective**: `memory_detect_contradiction` surfaces conflicting claims from different agents to an uninvolved third agent, with a `contradicts` link between them.
- **Pre-conditions**: S1b green. Requires `memory_detect_contradiction` endpoint.
- **Procedure**: Agent A writes "X is true". Agent B writes "X is false" (different-content, same-topic). Settle. Agent C calls `memory_detect_contradiction` on topic X. Verify response includes both rows + a `contradicts` link between them.
- **Pass criteria**: C's query returns the pair + the link; neither A nor B's row is silently overwritten.
- **Failure modes**: Only one memory returned (LWW overwrite). No link present (detection not running). Memory returns but with swapped `agent_id` (provenance bug).
- **Evidence**: `scenario-6.json`.

#### S11 — Link integrity
- **Objective**: `memory_link` creates a relationship between two memories, and that relationship is traversable from any peer.
- **Pre-conditions**: S1b green.
- **Procedure**: Agent A writes memory M1. Agent B writes memory M2. Agent A invokes `memory_link --from M1 --to M2 --relation related_to`. Settle. Agent C on node-3 queries `memory_get_links M1`, expects M2 in the response.
- **Pass criteria**: C's link query returns M2. Inverse lookup (`memory_get_links M2`) also returns M1.
- **Failure modes**: Links don't replicate (only A's node sees them). Link direction not preserved (M1→M2 ≠ M2→M1 reflexive).
- **Evidence**: `scenario-11.json`.

### Suite C — Mutation + Lifecycle

#### S9 — Mutation round-trip
- **Objective**: `memory_update` from one agent is visible with the new content on other agents within quorum settle. `metadata.agent_id` of the ORIGINAL writer is preserved (Task 1.2 immutability) while `updated_by` reflects the mutator.
- **Pre-conditions**: S1b green.
- **Procedure**: A writes M1 with content "v1". B issues `memory_update M1 content="v2"`. Settle. C reads M1.
- **Pass criteria**: C sees content="v2". `metadata.agent_id` is still `ai:alice` (immutable). `metadata.updated_by` or equivalent is `ai:bob`.
- **Failure modes**: `metadata.agent_id` overwritten to `ai:bob` (Task 1.2 breach). Update doesn't propagate (C still sees "v1").
- **Evidence**: `scenario-9.json`.

#### S10 — Deletion propagation
- **Objective**: `memory_delete` / `memory_forget` from one agent propagates to all peers and to the aggregator node-4 within quorum settle.
- **Pre-conditions**: S1b green.
- **Procedure**: A writes M1. Settle. A lists M1 via HTTP, confirms present. A issues `memory_delete M1` (or `memory_forget M1`). Settle 15s. B, C, node-4 all query for M1.
- **Pass criteria**: None of the 3 peers still have M1. No tombstone leak (the row's content is not retrievable via recall).
- **Failure modes**: Soft delete: row hidden on A but still present on peers (replication failure). Deletion creates a gap: `memory_list` returns `null` entries.
- **Evidence**: `scenario-10.json`.

#### S16 — Tier promotion
- **Objective**: `memory_promote` from `short` → `mid` → `long` tier replicates across peers without losing content or provenance.
- **Pre-conditions**: S1b green. Tier endpoint exposed.
- **Procedure**: A writes M1 with `tier: short`. Settle. A issues `memory_promote M1 --tier long`. Settle. B reads M1 and checks `tier`.
- **Pass criteria**: B sees `tier: long`. Content identical. `metadata.agent_id` unchanged.
- **Evidence**: `scenario-16.json`.

### Suite D — Scope + Governance

#### S7 — Scope visibility matrix
- **Objective**: Task 1.5 scope contract enforced across agents on different nodes. Every (caller_scope, target_scope) pair produces the documented visibility.
- **Pre-conditions**: S1b green. Task 1.5 scope enforcement shipped in v0.6.0.
- **Procedure**: A writes 5 memories at scopes `private`, `team`, `unit`, `org`, `collective`. Settle. B queries each scope from different `as_agent` values (same-team, different-team, different-unit, different-org). Verify the matrix:
  - `private` → visible only to A itself
  - `team` → visible to same-team agents
  - `unit` → visible to same-unit agents (and same-team inherited)
  - `org` → visible to same-org
  - `collective` → globally visible
- **Pass criteria**: Every cell of the visibility matrix matches the Task 1.5 contract.
- **Failure modes**: Private memory leaked across scope boundary = critical. Collective memory not visible globally = replication gap.
- **Evidence**: `scenario-7.json` with full (scope, caller_scope) matrix.

#### S8 — Auto-tagging round-trip
- **Objective**: Auto-tag pipeline generates tags for untagged memories and makes them recallable by tag.
- **Pre-conditions**: Requires Ollama on s-4vcpu-16gb droplets. Auto-tag pipeline daemon running. **DEFERRED** unless `auto_tag=true` dispatch input is set.
- **Procedure**: A writes memory without tags. Wait 30s for auto-tag pipeline. B recalls by one of the generated tags.
- **Pass criteria**: B's tag-based recall returns A's memory. Tags are non-empty, non-trivial (not just content truncation).
- **Evidence**: `scenario-8.json`.

#### S12 — Agent registration
- **Objective**: `memory_agent_register` on one node makes the agent visible in `memory_agent_list` on all peers. Task 1.3 shipped in v0.6.0.
- **Pre-conditions**: S1b green.
- **Procedure**: A calls `memory_agent_register --agent-id=ai:dave --namespace=auto-registered`. Settle. B, C, node-4 each call `memory_agent_list`. All see ai:dave.
- **Pass criteria**: Consistent view of registered agents across all nodes.
- **Evidence**: `scenario-12.json`.

### Suite E — Resilience + Observability

#### S13 — Concurrent write contention
- **Objective**: Two agents updating the same memory converge to a consistent outcome across peers — whatever the resolution semantics (LWW, CRDT, vector clock) — *everyone agrees on which version won*.
- **Pre-conditions**: S1b green, S9 green.
- **Procedure**: A writes M1 with "v0". Settle. A and B concurrently issue `memory_update M1 content="vA"` and `memory_update M1 content="vB"`. Settle. All 3 peers + node-4 read M1.
- **Pass criteria**: All 4 readers return the SAME content value (whether it's vA, vB, or a CRDT merge is less important than agreement). No split-brain.
- **Failure modes**: Different peers report different content → split-brain. Metadata partial update (content vA but `updated_by` ai:bob) → inconsistent transaction.
- **Evidence**: `scenario-13.json` with the outcome vote per peer.

#### S14 — Partition tolerance
- **Objective**: Temporary loss of one peer doesn't permanently break the mesh; writes during partition converge after recovery (PR #309 + PR #312 regression test at A2A level).
- **Pre-conditions**: S1b green.
- **Procedure**: Suspend node-3 via `kill -STOP` on its ai-memory process. A and B write memories. 10s settle. Resume node-3 via `kill -CONT`. 15s settle. Query node-3 for the memories written during partition.
- **Pass criteria**: Node-3 eventually sees all writes made during its outage. Quorum (W=2) was satisfied during partition (A + B constituted quorum for each other).
- **Failure modes**: Writes during partition lost (W=2 not satisfied during outage). Node-3 partition prevents ALL writes (W=3 requirement bug).
- **Evidence**: `scenario-14.json`.

#### S15 — Read-your-writes
- **Objective**: An agent reading immediately after its own write sees the write (no settle required locally).
- **Pre-conditions**: Baseline green.
- **Procedure**: A writes M1 at time T0. A issues recall at T0+1ms from the same node. A reads its own write.
- **Pass criteria**: The write is visible to the writer itself with zero-delay local read. (Inter-agent propagation delay is separate — tested elsewhere.)
- **Failure modes**: Writer doesn't see own write locally → local-write-not-persisted bug.
- **Evidence**: `scenario-15.json`.

#### S17 — Stats consistency
- **Objective**: `memory_stats` returns the same counts across all 4 peers post-settle (total memories, per-namespace, per-agent).
- **Pre-conditions**: S1b green.
- **Procedure**: All 3 agents write 5 memories each (15 total). Settle 15s. Query `memory_stats` on each of the 4 peers.
- **Pass criteria**: `total_memories >= 15` on all 4 peers AND equal across all 4 peers (±0 tolerance post-settle).
- **Failure modes**: Count drift between peers → incomplete replication. Count mismatch with writer-count → write bug.
- **Evidence**: `scenario-17.json`.

#### S18 — Semantic query expansion
- **Objective**: `memory_expand_query` returns semantically related memories written by different agents, proving the HNSW/embedding layer works across the federated set.
- **Pre-conditions**: S1b green. Semantic tier enabled (baseline.mcp args include `--tier semantic`).
- **Procedure**: A writes "Lyra prefers morning runs". B writes "Lyra loves breakfast before exercise". Settle. C calls `memory_expand_query "dawn activity routine"` (semantically related but no literal keyword overlap).
- **Pass criteria**: Query returns both A's and B's memories despite keyword mismatch. Both have the expected `metadata.agent_id`.
- **Failure modes**: Only keyword matches returned (semantic expansion broken). Neither returned (index fails across peers).
- **Evidence**: `scenario-18.json`.

### Suite F — Topology variants

#### S4 — Federation-aware concurrent writes
- **Objective**: Quorum semantics hold under concurrent write burst. PR #309 regression test at A2A level.
- **Pre-conditions**: S1b green.
- **Procedure**: All 3 agents concurrently write 50 memories each (150 total, ~5s burst) into distinct namespaces. Settle 20s. Query node-4 aggregator for total row count per namespace.
- **Pass criteria**: Node-4 sees 50 memories in each of the 3 namespaces. No row loss. No wrong `agent_id`.
- **Failure modes**: Row loss → W=2 fanout dropping under load. Wrong `agent_id` → race condition in metadata stamping (Task 1.2 breach under concurrency).
- **Evidence**: `scenario-4.json`.

#### S19 — SAME-NODE A2A
- **Objective**: Two agent identities running on the SAME droplet, sharing the same local `ai-memory serve`, can write and read each other's memories. This is the on-device-multi-agent case (Claude Desktop + VS Code on one dev laptop, both talking to local ai-memory). Distinct from between-node federated A2A.
- **Pre-conditions**: Baseline v1.2.0 green. A modified provision: node-1 runs TWO agent identities (`ai:alice-primary` and `ai:alice-assistant`) both with MCP config pointing at the same `/var/lib/ai-memory/a2a.db`.
- **Procedure**: Primary agent writes 10 memories to `scenario19-same-node-alice`. Assistant agent (on same droplet, same serve) recalls the namespace immediately (no settle — same-process DB). Primary reads assistant's writes back.
- **Pass criteria**: Both agents see each other's writes with correct `metadata.agent_id`. No federation involvement — this is a pure local-shared-memory test.
- **Failure modes**: Agent isolation bug (alice-primary can't see alice-assistant despite shared DB). MCP stdio session caches state across calls and misses new writes from sibling agents.
- **Evidence**: `scenario-19.json`.

---

## 5. Dispatch plans

### 5.1 Standard campaign
```sh
gh workflow run a2a-gate.yml \
  -f agent_group=openclaw \
  -f scenarios="1 1b 2 4 5 9 10 12 13 15 17 18"
```
All runnable-today scenarios. Omit S3, S6, S7, S8, S11, S14, S16, S19 (deferred or special-infra).

### 5.2 Deep resilience campaign
```sh
gh workflow run a2a-gate.yml \
  -f agent_group=openclaw \
  -f scenarios="13 14"
```
Contention + partition tolerance — heavier, longer-running.

### 5.3 Auto-tag campaign (requires larger droplets)
```sh
gh workflow run a2a-gate.yml \
  -f agent_group=openclaw \
  -f scenarios="8" \
  -f agent_droplet_size=s-4vcpu-16gb
```

### 5.4 Same-node A2A campaign (requires topology override)
Documented for future dispatch; requires a `topology=same-node` dispatch input (not yet implemented).

---

## 6. Reading the evidence

Every scenario leaves a `scenario-N.json` + `scenario-N.log` in `runs/<campaign-id>/`. The aggregator rolls them up into `a2a-summary.json` with `overall_pass = all-scenarios-pass`. The dashboard at https://alphaonedev.github.io/ai-memory-ai2ai-gate/runs/ surfaces PASS/FAIL per campaign; the per-run page shows PASS/FAIL per scenario with reasons.

Evidence is committed to git with redaction; no secret value reaches the repo (see [baseline.md §9b](baseline.md#9b-security--secrets--pii-handling)).

---

## 7. Change control

Adding a scenario is a **minor** test-book version bump. Removing or relaxing a scenario is **major** and requires a narrative entry in `analysis/run-insights.json`. Every scenario added must include:

1. Entry in §2 register
2. Full §4 plan (Objective / Pre-conditions / Procedure / Pass / Failure / Evidence)
3. Working script in `scripts/scenarios/<N>_<slug>.py` (Python 3; see §7b)
4. Primitive coverage updated in §3

---

## 7b. Scenario scripting convention (v3.0.0+)

**All scenarios are Python 3.** Every script in `scripts/scenarios/` is a `.py` file that imports `scripts/a2a_harness.py` (stdlib-only — no pip installs on the runner), runs its checks, and calls `harness.emit(...)` to produce the JSON report. The workflow dispatches via `python3`.

Contract:
- `stdout` — single-line JSON scenario report (consumed by aggregator)
- `stderr` — human-readable log lines
- exit 0 on a clean run (pass, fail, or skip); non-zero only on hard crash

Why Python, not bash: complex payload construction (fuzz / bulk / export-import), real concurrency (`concurrent.futures`), clean assertions, reusable fixtures, JSON handled as data instead of shell-quoting hell.

Reference implementation: `scripts/scenarios/26_mixed_framework.py`.

---

## 8. Read next

- [Baseline configuration](baseline.md) — what must be true before any scenario runs
- [Methodology](methodology.md) — the philosophy behind the invariants
- [Reproducing](reproducing.md) — how to dispatch a campaign yourself
- [Campaign runs](runs/) — live evidence dashboard
