# Every test performed

The canonical list of **every** AI-to-AI integration test the a2a-gate
runs against ai-memory. Two tiers: **baseline probes** gate scenario
execution; **scenarios** exercise the full A2A surface.

Authoritative sources:

- Baseline probes → [`scripts/setup_node.sh`](../scripts/setup_node.py)
- Scenario runners → [`scripts/scenarios/`](https://github.com/alphaonedev/ai-memory-ai2ai-gate/tree/main/scripts/scenarios)
- Per-scenario full plans → [`docs/testbook.md`](testbook.md)

If this page and the testbook disagree, the testbook (v3.0.0+) is the
current contract; this page is the index / summary view. Every scenario
is implemented in Python 3 (testbook v3.0.0 convention); the shared
harness lives at [`scripts/a2a_harness.py`](https://github.com/alphaonedev/ai-memory-ai2ai-gate/blob/main/scripts/a2a_harness.py).

---

## 1. Baseline probes (8)

Every agent droplet runs these before scenarios are allowed to execute.
`baseline_pass=true` requires **all** gate-marked probes green. The
three-node baseline (3 agent nodes × 8 probes) + the 4th memory-only
node gate every campaign.

| Probe | What it exercises | Gates `baseline_pass`? | Failure indicates |
|---|---|---|---|
| **F1** xAI Grok reachability | Direct HTTPS POST to `api.x.ai/v1/chat/completions`; expects `READY` literal reply | yes | LLM backend down or API key revoked |
| **F2a** HTTP substrate canary | Direct `POST /api/v1/memories` + `GET` on local `ai-memory serve`; write+read roundtrip | yes | ai-memory HTTP daemon not running or SQLite broken |
| **F2b** Agent-driven MCP canary | Framework LLM prompted to use `memory_store` via MCP stdio; deterministic retrieval verification | **no** (observation only — LLM-dependent) | Framework-MCP loop broken; baseline still passes if F2a + F5 pass |
| **F3** Peer A2A canary | One node writes via MCP; other two nodes + node-4 aggregator must see it via HTTP | yes (separate step in workflow) | Federation fanout broken; S1b regression |
| **F4** Mesh directional reachability | Every node runs `GET /health` + `POST /sync/push?dry_run=true` against every peer. N-1 edges per node; aggregator ANDs across N nodes = full N*(N-1) bidirectional mesh | yes | VPC firewall/routing broken, ai-memory serve not listening, quorum peers misconfigured |
| **F5** ai-memory MCP stdio handshake | Spawns `ai-memory mcp --tier semantic` with the exact invocation each framework uses; sends MCP 2024-11-05 `initialize` + `tools/list`; verifies `memory_store`, `memory_recall`, `memory_list` in the response | yes | ai-memory binary missing, stdio protocol broken, or framework invocation mismatched |
| **F6** TLS handshake (planned, tls_mode ≥ tls) | Verify `ai-memory serve` presents a server cert and completes a TLS 1.3 handshake on every peer edge | yes (when tls_mode ≥ tls) | Cert material missing on disk or rustls config rejected |
| **F7** mTLS enforcement (planned, tls_mode=mtls) | Anonymous client (no client cert) MUST be rejected. Client with off-allowlist fingerprint MUST be rejected. Client with on-allowlist fingerprint MUST succeed | yes (when tls_mode=mtls) | `--mtls-allowlist` ignored or fingerprint verifier bypass |

### Per-probe implementation

All probes live in `scripts/setup_node.sh` and emit a single line each
into `/etc/ai-memory-a2a/baseline.json` under `functional_probes`.
The baseline.json is scp'd back to the runner and aggregated into
`runs/<campaign_id>/a2a-baseline.json` (rendered on [campaign run pages](runs/)).

F6 and F7 ship with [Tranche 2 — TLS/mTLS](#tranche-2--tls--mtls).

---

## 2. Config + negative invariants (10)

These are **attestations**, not probes — each one reads a config file
or runs a static check and records the result. All ten must be `true`
for `baseline_pass=true`.

| Invariant | What it asserts | Per-framework evidence |
|---|---|---|
| `framework_is_authentic` | Binary is the upstream one (not a same-named stub) | `readlink -f $(which <framework>)` contains framework name |
| `mcp_server_ai_memory_registered` | The `memory` MCP server is registered with the framework | IronClaw: `ironclaw mcp list` contains `memory`; Hermes: YAML `mcp_servers.memory`; OpenClaw: JSON `mcpServers.memory` |
| `llm_backend_is_xai_grok` | LLM provider is xAI Grok | IronClaw: `.env` has `LLM_BASE_URL=https://api.x.ai/v1`; Hermes: `XAI_API_KEY` in hermes.env; OpenClaw: `providers.xai` in JSON |
| `llm_is_default_provider` | xAI Grok is the default (not a second fallback) | Per-framework config default-provider field |
| `mcp_command_is_ai_memory` | MCP server command resolves to `ai-memory` binary | Grep config for `command: ai-memory` (or equivalent) |
| `agent_id_stamped` | Every write carries this node's `AI_MEMORY_AGENT_ID` | Env/config contains `AI_MEMORY_AGENT_ID=ai:<alice|bob|charlie>` |
| `federation_live` | Local `ai-memory serve` is listening + has ≥1 peer | `GET /api/v1/health` returns `{"status":"ok"}` |
| `ufw_disabled` | Ubuntu UFW is OFF (ship-gate lesson — blocks intra-VPC) | `ufw status` contains `inactive` or UFW not installed |
| `iptables_flushed` | iptables policies are ACCEPT on INPUT/OUTPUT/FORWARD | `iptables -S` shows 3 `-P … ACCEPT` lines |
| `dead_man_switch_scheduled` | `shutdown -P +480` scheduled at boot (8hr cap on spend) | `shutdown -c` dry-run or `/run/systemd/shutdown/scheduled` check |

### Thesis-preserving negative invariants (5)

| Invariant | What it asserts | Enforcement |
|---|---|---|
| `a2a_protocol_off` | No direct agent-to-agent RPC channel (ACP, sessions, etc.) | Per-framework config flag(s) |
| `sub_agent_or_sessions_spawn_off` | No parent/child agent hierarchy or session-spawn tool | Framework config + tool allowlist |
| `alternative_channels_off` | No Telegram / Discord / Slack / Moltbook / gateway / execution_backends | Per-framework disable blocks |
| `tool_allowlist_is_memory_only` | Only `memory_*` tools available to the agent | Hermes: `tool_allowlist` YAML list; IronClaw: only one MCP server registered (provisioning-control); OpenClaw: `toolAllowlist` JSON |
| `a2a_gate_profile_locked` | `a2a_gate_profile: shared-memory-only` tag present | Per-framework config set |

Any `false` here = thesis preserved (good). The negative invariants only
pass `baseline_pass` when all `true`. Document sources: [`docs/baseline.md`](baseline.md) §6b.

---

## 3. Scenarios

### 3.1 Suite A — Core A2A (3 scenarios)

| # | Name | What it proves | Primary primitives | Runner |
|---|---|---|---|---|
| **S1** | Per-agent write + read (MCP stdio) | Framework can accept prompt → choose `memory_store` tool → invoke via MCP stdio → memory lands with correct `metadata.agent_id` | `memory_store`, `memory_recall` | [`1_write_read_mcp.py`](https://github.com/alphaonedev/ai-memory-ai2ai-gate/blob/main/scripts/scenarios/1_write_read_mcp.py) |
| **S1b** | Per-agent write + read (HTTP direct) | Green-path counterpart: federation + substrate work independent of the MCP-stdio path | `memory_store`, `memory_list` | [`1b_write_read_http.py`](https://github.com/alphaonedev/ai-memory-ai2ai-gate/blob/main/scripts/scenarios/1b_write_read_http.py) |
| **S2** | Shared-context handoff | Agent A writes a handoff memory; agent B picks it up within quorum settle; round-trips back to A | `memory_store`, `memory_recall`, `memory_list` | [`2_handoff.py`](https://github.com/alphaonedev/ai-memory-ai2ai-gate/blob/main/scripts/scenarios/2_handoff.py) |

### 3.2 Suite B — A2A primitives (4 scenarios)

| # | Name | What it proves | Primary primitives | Runner |
|---|---|---|---|---|
| **S3** | Targeted `memory_share` | Subset of memories lands on exactly the targeted peer (not broadcast) | `memory_share` | (deferred until v0.6.0.1 / #311) |
| **S5** | Consolidation + curation | `memory_consolidate` preserves `consolidated_from_agents` metadata | `memory_consolidate` | [`5_consolidation.py`](https://github.com/alphaonedev/ai-memory-ai2ai-gate/blob/main/scripts/scenarios/5_consolidation.py) |
| **S6** | Contradiction detection | Contradicting memories produce a `contradicts` link visible to third agent | `memory_detect_contradiction`, `memory_link` | [`6_contradiction.py`](https://github.com/alphaonedev/ai-memory-ai2ai-gate/blob/main/scripts/scenarios/6_contradiction.py) |
| **S11** | Link integrity | Linked memories returned together on peer query | `memory_link`, `memory_get` | [`11_link_integrity.py`](https://github.com/alphaonedev/ai-memory-ai2ai-gate/blob/main/scripts/scenarios/11_link_integrity.py) |

### 3.3 Suite C — Mutation + lifecycle (3 scenarios)

| # | Name | What it proves | Primary primitives | Runner |
|---|---|---|---|---|
| **S9** | Mutation round-trip | `memory_update` from agent A is visible with new content on agent B | `memory_update` | [`9_mutation.py`](https://github.com/alphaonedev/ai-memory-ai2ai-gate/blob/main/scripts/scenarios/9_mutation.py) |
| **S10** | Deletion propagation | `memory_delete` / `memory_forget` propagates to all peers | `memory_delete`, `memory_forget` | [`10_deletion.py`](https://github.com/alphaonedev/ai-memory-ai2ai-gate/blob/main/scripts/scenarios/10_deletion.py) |
| **S16** | Tier promotion | `short` → `mid` → `long` promotion visible to peers | `memory_promote` | [`16_tier_promotion.py`](https://github.com/alphaonedev/ai-memory-ai2ai-gate/blob/main/scripts/scenarios/16_tier_promotion.py) |

### 3.4 Suite D — Scope + governance (3 scenarios)

| # | Name | What it proves | Primary primitives | Runner |
|---|---|---|---|---|
| **S7** | Scope visibility matrix | Each (scope, caller_scope) pair produces correct visibility | `as_agent` filter, `scope` metadata | (partial — Task 1.5 ongoing) |
| **S8** | Auto-tagging round-trip | Agent writes without tags; tags appear; recall-by-tag works | `memory_auto_tag` | (requires Ollama-backed droplets) |
| **S12** | Agent registration (Task 1.3) | `memory_agent_register` on A visible to B's `memory_agent_list` | `memory_agent_register`, `memory_agent_list` | [`12_agent_register.py`](https://github.com/alphaonedev/ai-memory-ai2ai-gate/blob/main/scripts/scenarios/12_agent_register.py) |

### 3.5 Suite E — Resilience + observability (5 scenarios)

| # | Name | What it proves | Primary primitives | Runner |
|---|---|---|---|---|
| **S13** | Concurrent write contention | Two agents updating the same row converge to a consistent outcome | `memory_update`, `memory_store` | [`13_concurrent_contention.py`](https://github.com/alphaonedev/ai-memory-ai2ai-gate/blob/main/scripts/scenarios/13_concurrent_contention.py) |
| **S14** | Partition tolerance | Temporary peer loss → recovery → convergence within bounded time | federation sync | [`14_partition_tolerance.py`](https://github.com/alphaonedev/ai-memory-ai2ai-gate/blob/main/scripts/scenarios/14_partition_tolerance.py) |
| **S15** | Read-your-writes | Writing agent sees its own write immediately (no settle required) | `memory_store`, `memory_recall` | [`15_read_your_writes.py`](https://github.com/alphaonedev/ai-memory-ai2ai-gate/blob/main/scripts/scenarios/15_read_your_writes.py) |
| **S17** | Stats consistency | `memory_stats` returns equal counts across peers post-settle | `memory_stats` | [`17_stats_consistency.py`](https://github.com/alphaonedev/ai-memory-ai2ai-gate/blob/main/scripts/scenarios/17_stats_consistency.py) |
| **S18** | Semantic query expansion | Semantic recall surfaces memories written under synonyms, across writers | `memory_expand_query`, `memory_recall` | [`18_query_expansion.py`](https://github.com/alphaonedev/ai-memory-ai2ai-gate/blob/main/scripts/scenarios/18_query_expansion.py) |

### 3.6 Suite F — Topology variants (2 scenarios)

| # | Name | What it proves | Primary primitives | Runner |
|---|---|---|---|---|
| **S4** | Federation-aware concurrent writes (quorum burst) | Quorum preserved under N-agent concurrent write burst | federation quorum | [`4_federation_burst.py`](https://github.com/alphaonedev/ai-memory-ai2ai-gate/blob/main/scripts/scenarios/4_federation_burst.py) |
| **S19** | Same-node A2A | Two agents on ONE droplet share local ai-memory without federation | `memory_store`, `memory_recall` (same-node) | (planned, testbook v2.0.0) |

---

## 4. Tranche 2 — TLS / mTLS (shipped v3.0.0)

Enabled via `tls_mode: tls | mtls` workflow input. Adds F6/F7 baseline
probes and the scenarios below. See [ai-memory integration](ai-memory-integration.md)
for the cert material layout.

| # | Name | What it proves | Gates |
|---|---|---|---|
| **F6** | Server TLS handshake | Every peer presents a valid server cert; rustls completes TLS 1.3 | baseline (when `tls_mode ≥ tls`) |
| **F7** | mTLS client-cert enforcement | Anonymous client must be rejected; off-allowlist fingerprint must be rejected; on-allowlist must succeed | baseline (when `tls_mode = mtls`) |
| **S20** | mTLS happy-path | Agent with valid client cert writes/reads across the federation | scenario |
| **S21** | Anonymous client rejected | POST `/api/v1/memories` without client cert → handshake rejected | scenario |

---

## 5. Tranche 3 — Adversarial + cross-framework (shipped v3.0.0)

| # | Name | What it proves | Category |
|---|---|---|---|
| **S22** | Identity spoofing | `X-Agent-Id` vs body.metadata.agent_id precedence honored; stored identity is one of the declared values, never a silent third | identity |
| **S23** | Malicious content fuzz | SQL-like, XSS, NUL bytes, oversize (~1 MB), unicode+RTL: no crash, no injection, oversize cleanly rejected or round-trip faithful, others byte-for-byte preserved | robustness |
| **S24** | Byzantine peer | Node-2 crafts a sync_push claiming sender=ai:alice; node-3 preserves declared `metadata.agent_id` (no silent re-attribution) or rejects | federation integrity |
| **S25** | Clock skew tolerance | Node-3 offset +300 s; alice's write from node-1 still converges to node-3 via vector clocks | time |
| **S26** | Mixed-framework campaign | IronClaw + Hermes on same VPC; writes cross readable both directions | cross-stack |
| **S27** | OpenClaw legacy regression | openclaw-only campaign regression lane (skipped unless `agent_group=openclaw`) | legacy |

---

## 6. Tranche 4 — Uncovered primitive coverage (shipped v3.0.0)

| # | Name | What it proves | Primary primitives |
|---|---|---|---|
| **S28** | memory_search keyword A2A | Keyword search (distinct from `/recall` semantic) consistent across peers | `memory_search` |
| **S29** | memory_archive lifecycle | archive → archive_list → archive_restore → archive_stats round-trip | `memory_archive_*` |
| **S30** | memory_capabilities handshake | Protocol version + tool surface match across peers | `memory_capabilities` |
| **S31** | memory_gc quiescence | After forget+gc, non-deleted rows remain readable on all peers | `memory_gc`, `memory_forget` |
| **S32** | memory_inbox + memory_notify | Notify delivers to target's inbox; non-target cannot read | `memory_notify`, `memory_inbox` |
| **S33** | memory_subscribe pub/sub | subscribe → write → deliver → unsubscribe → no-deliver | `memory_subscribe`, `memory_unsubscribe`, `memory_list_subscriptions` |
| **S34** | memory_pending governance | `governance.write=approve` → pending → approve/reject visibility | `memory_pending_{list,approve,reject}` |
| **S35** | memory_namespace standards | Parent-chain rules merged into namespace standard | `memory_namespace_{get,set,clear}_standard` |
| **S36** | memory_session_start lifecycle | Session-tagged writes recall by session_id only | `memory_session_start` |
| **S37** | memory_get_links bidirectional | Both forward and reverse traversal resolve the pair | `memory_get_links` |

---

## 7. Tranche 5 — HTTP-only endpoint coverage (shipped v3.0.0)

| # | Name | What it proves | Endpoint |
|---|---|---|---|
| **S38** | export + import round-trip | Export one peer's namespace → import elsewhere → stats match | `/api/v1/export`, `/api/v1/import` |
| **S39** | sync/since delta | Post-partition delta returns exactly the missed rows | `/api/v1/sync/since` |
| **S40** | bulk write | 500-row `/bulk` POST reaches every peer + aggregator | `/api/v1/memories/bulk` |
| **S41** | metrics Prometheus | Required counters present and monotonic post-activity | `/api/v1/metrics` |
| **S42** | namespaces enumeration | Namespace list (with counts) equivalent across peers | `/api/v1/namespaces` |

---

## 8. Dispatch matrix (what runs in a given campaign)

The default dispatch runs the **v3.0.0 always-on set** (35 scenarios):

- **Baseline probes** F1, F2a, F2b, F3, F4, F5 on every agent node; + F6 when `tls_mode ≥ tls`; + F7 when `tls_mode = mtls`.
- **Scenarios**: S1, S1b, S2, S4, S5, S6, S9, S10, S11, S12, S13, S14, S15, S16, S17, S18, S22, S23, S24, S25, S28, S29, S30, S31, S32, S33, S34, S35, S36, S37, S38, S39, S40, S41, S42.

Auto-appended conditionally by the workflow's *Compute scenarios list* step:

- **S20** when `tls_mode ∈ {tls, mtls}`
- **S21** when `tls_mode = mtls`
- **S26** when `agent_group = mixed`
- **S27** when `agent_group = openclaw`

`agent_group` selects the framework:

- `ironclaw` (primary as of 2026-04-21)
- `hermes` (primary)
- `openclaw` (legacy — explicit dispatch only)
- `mixed` — heterogeneous agents in one campaign (S26)

---

## 7. Read next

- [Baseline configuration](baseline.md) — every invariant this gate defends
- [ai-memory integration (IronClaw + Hermes)](ai-memory-integration.md) — the authoritative config standard
- [Reproducing](reproducing.md) — run it yourself
- [Campaign runs](runs/) — live evidence dashboard
