# v1.0 GA criteria

**Publishing the criteria, not the date.** Every 0.6.x / 0.7.x / 0.8.x release is step N toward the contract below. When every line in this document is green, and has been green for the qualifying window, the `v1.0.0` tag cuts.

This document spans three repositories — [`ai-memory-mcp`](https://github.com/alphaonedev/ai-memory-mcp) (the substrate), [`ai-memory-ship-gate`](https://github.com/alphaonedev/ai-memory-ship-gate) (substrate validation against live infrastructure), and [`ai-memory-ai2ai-gate`](https://github.com/alphaonedev/ai-memory-ai2ai-gate) (this repo — multi-agent integration validation) — because v1.0 is a statement about the whole stack, not any single component.

Authority: [THE STANDARD](https://github.com/alphaonedev/ai-memory-mcp/blob/develop/docs/AI_DEVELOPER_GOVERNANCE.md) governs process; this document is the technical target.

---

## 1. Substrate — `ai-memory-mcp`

### 1.1 API contract frozen (breaking-change budget = 0)

- The HTTP API surface (`/api/v1/*`) is stable: every endpoint documented in [`handlers.rs`](https://github.com/alphaonedev/ai-memory-mcp/blob/develop/src/handlers.rs) carries a deprecation policy instead of a removal policy.
- The MCP tool surface (23+ tools defined in [`mcp.rs`](https://github.com/alphaonedev/ai-memory-mcp/blob/develop/src/mcp.rs)) is stable: no tool rename, no parameter rename, no response shape change between v1.0 and any v1.x.
- The CLI surface (26+ subcommands) is stable: same rule.
- Any additive field is explicitly marked additive in the release notes and defaults to backwards-compatible behavior.
- The wire format for federation (`POST /api/v1/sync/push`) is versioned and dual-reads until v2.

### 1.2 Test posture

- `cargo fmt --check` + `cargo clippy -- -D warnings -D clippy::all -D clippy::pedantic` + `cargo test` + `cargo audit` green on ubuntu / macos / windows for three consecutive tagged releases.
- Integration test count ≥ 200, all green. Baseline today: 183 (see [tests/integration.rs](https://github.com/alphaonedev/ai-memory-mcp/blob/develop/tests/integration.rs)).
- Benchmark suite ([`cargo bench`](https://github.com/alphaonedev/ai-memory-mcp/blob/develop/benches/recall.rs)) runs clean; no regression > 10% on `recall`, `search`, `detect_contradiction` compared to v0.6.0 baseline.
- No `unsafe`, no `panic!()` in non-test code, no `.unwrap()` on untrusted input.

### 1.3 Security posture

- No open `cargo audit` finding at any severity.
- Signed commits on every merge to `main` / `release/*`. Signed release tags (via `jbridger2021` key, registered on crates.io and GitHub).
- mTLS support (Layer 2 in v0.6.0, carried forward) has a documented production-deployment runbook in [`docs/`](https://github.com/alphaonedev/ai-memory-mcp/tree/develop/docs).
- SBOM published alongside every release (SPDX JSON attached to the GitHub release).
- Secret-scanning enabled on all repos; zero detections carry forward into a tag.
- No unresolved `CVE` advisories against runtime dependencies.

### 1.4 Observability

- Prometheus `/metrics` surface covers all five subsystems: writes, recalls, GC, federation (acks + quorum-misses), cache. [Standing policy](https://github.com/alphaonedev/ai-memory-mcp/blob/develop/src/handlers.rs) — any new handler that mutates state adds a counter.
- `OTEL_*` / OpenTelemetry export behind a feature flag, with a documented Grafana dashboard and Loki query set.
- Every error path returns a classified `ApiError` (not a raw string). Error codes are documented.

### 1.5 SDK coverage

- **Python SDK** — 1.0-pinned, published to PyPI with a [semver guarantee](https://semver.org/). Full HTTP + MCP coverage. Tested against three consecutive ai-memory-mcp releases.
- **TypeScript SDK** — 1.0-pinned, published to npm, same guarantee.
- **Rust crate** — `ai-memory-client` sibling crate separate from the binary, published to crates.io.
- Each SDK has a getting-started tutorial + ≥ 5 runnable cookbook examples.

### 1.6 Documentation

- Full API reference (mkdocs or similar) covers every HTTP endpoint + every MCP tool + every CLI subcommand.
- Operations guide: deployment, scaling, backup, restore, migration, upgrade-path, disaster recovery.
- Security hardening guide: TLS, mTLS, SQLCipher, secret rotation, agent identity.
- Federation guide: topology choice, quorum tuning, partition recovery, cross-version compatibility matrix.

---

## 2. Substrate validation — `ai-memory-ship-gate`

- **Phases 1 – 4 green on three consecutive releases:**
  - Phase 1: single-node smoke (write / recall / GC / restart).
  - Phase 2: 3-node federation (quorum writes, catchup, partition convergence).
  - Phase 3: SAL cross-backend (SQLite ↔ Postgres migration, 1000-memory round-trip, zero errors).
  - Phase 4: chaos harness (SIGSTOP, network blip, disk-full, `kill -9`).
- Evidence published live under [`alphaonedev.github.io/ai-memory-ship-gate/`](https://alphaonedev.github.io/ai-memory-ship-gate/). Every phase artefact is a JSON file peer-reviewable out-of-band.
- Ship-gate dispatch is triggered on every tag; failure blocks GHCR / crates.io / Homebrew / PPA publication.

---

## 3. Multi-agent integration — `ai-memory-ai2ai-gate` (this repo)

### 3.1 Full-matrix certification

Homogeneous-framework matrix:

| | off | tls | mtls |
|---|---|---|---|
| **ironclaw** | 34 / 34 × 3 | 35 / 35 × 3 | 36 / 36 × 3 |
| **hermes**   | 34 / 34 × 3 | 35 / 35 × 3 | 36 / 36 × 3 |

Mixed-framework matrix (post-topology work, gated by this repo's terraform changes):

| | off | tls | mtls |
|---|---|---|---|
| **mixed (ironclaw + hermes)** | 34 / 34 × 3 | 35 / 35 × 3 | 36 / 36 × 3 |

"`N / N × 3`" = three consecutive `overall_pass = true` runs at full scenario coverage. See the [certification threshold on the home page](index.md#certification-threshold) for the counting rule — a single red resets the streak for that cell.

### 3.2 Framework expansion

- **Phase 2 — Claude Managed Agents** (per [`roadmap.md`](roadmap.md)): `claude-managed` agent group green on Claude Haiku 4.5 default, across all three transport modes, for ≥ 1 full matrix sweep. Adds an independent runtime to the "framework-agnostic" claim.
- **Phase 3 — cross-cloud** (stretch, may land in v1.1): one non-DigitalOcean provider (AWS, GCP, Hetzner) proven as a drop-in target.

### 3.3 Adversarial + Byzantine coverage

- Suite G scenarios (S20 – S27) green across the matrix. mTLS happy-path, anonymous rejected, identity spoofing, malicious content fuzz, Byzantine peer, clock skew — all pinned.
- Zero known bypasses of the scope visibility matrix under the scope-enforcement contract (Task 1.5).

### 3.4 Observability surface

- Every failing scenario produces a one-line failure narrative in [`analysis/run-insights.json`](https://github.com/alphaonedev/ai-memory-ai2ai-gate/blob/main/analysis/run-insights.json). No silent "0-byte report" scenarios (see historical bug [ai-memory-ai2ai-gate#2](https://github.com/alphaonedev/ai-memory-ai2ai-gate/issues/2)).
- `baseline_pass` / `overall_pass` emitted per-campaign-per-cell, aggregated into a public dashboard.

---

## 4. Release discipline

- Every release from v0.6.0 forward has landed under the [AlphaOne Root Cause Analysis Standard v1](https://github.com/alphaonedev/ai-memory-mcp) (authored 2026-04-21). v1.0 cuts only after **≥ 10 consecutive releases** under the standard without a post-release RCA.
- Every release carries an **AI involvement** section (per [`AI_DEVELOPER_WORKFLOW.md` §8.2](https://github.com/alphaonedev/ai-memory-mcp/blob/develop/docs/AI_DEVELOPER_WORKFLOW.md)) disclosing the AI NHI(s) involved, the authority class exercised, and the biologic review path.
- Every commit is signed, every PR has a Co-Authored-By trailer, every merged PR has green CI across all three platforms.

---

## 5. Explicit non-goals for v1.0

To keep the contract honest, these are deliberately **out of scope** for v1.0:

- **Multi-tenant SaaS.** The HTTP API is multi-tenant *per request* (agent_id) but not *per tenant boundary*; that's a v1.x item tracked as [ai-memory-mcp#148](https://github.com/alphaonedev/ai-memory-mcp/issues/148) and the upcoming attested-agent-id work.
- **Cross-cloud federation as a first-class product.** v1.0 validates on one cloud (DigitalOcean) end-to-end; cross-cloud is a stretch (see §3.2).
- **Human-in-the-loop agent supervision UX.** Governance primitives ship (pending / approve / reject, policy rules). A polished supervisor UI does not; that is AgenticMem commercial surface.
- **LLM-native query planner.** The smart/autonomous tiers use LLMs opportunistically (auto-tag, contradiction detection, query expansion) but the core recall pipeline remains deterministic in v1.0.
- **Formal verification of the CRDT / LWW semantics.** v1.0 ships vector-clock + LWW with documented edge-cases; formal proofs are a v1.x research item.

---

## 6. How we keep this honest

This document lives in version control and is re-rendered on every merge to `main`. Any of the following changes the contract and requires a corresponding PR that updates this page, the home page's certification threshold section, and the affected release notes:

- Changing the scenario corpus size (new suite, removed scenario).
- Adding or removing a transport mode.
- Adding or removing an agent framework to the matrix.
- Changing the streak length for certification (currently 3).
- Changing the breaking-change budget (currently 0).

If you find this document out of date relative to what's actually shipping, that's a bug — [file an issue](https://github.com/alphaonedev/ai-memory-ai2ai-gate/issues/new) against the `docs` label.

---

## Related

- [Home — certification threshold](index.md#certification-threshold) · the streak counter + current best
- [Testbook v3.0.0](testbook.md) · the 42-scenario corpus
- [Baseline v1.4.0](baseline.md) · the pre-scenario gate
- [Methodology](methodology.md) · what each scenario proves
- [Roadmap](roadmap.md) · Phase 2 (Claude Managed Agents) and beyond
