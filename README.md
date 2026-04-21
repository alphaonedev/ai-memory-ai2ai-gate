# ai-memory-ai2ai-gate

Reproducible, peer-reviewable AI-to-AI (A2A) integration testing for
[ai-memory-mcp](https://github.com/alphaonedev/ai-memory-mcp). Where
[ai-memory-ship-gate](https://github.com/alphaonedev/ai-memory-ship-gate)
validates ai-memory itself (CRUD, federation, migration, chaos), this
repository validates what happens when **real AI agents use
ai-memory to talk to each other** on real DigitalOcean infrastructure.

Every green ship-gate campaign gates a release tag. Every green
ai2ai-gate campaign gates the claim that ai-memory actually serves
its stated purpose — persistent, shared, multi-agent memory.

> **Baseline testing configuration** (authoritative + enforced):
> every agent droplet of every campaign is pre-validated against a
> hard-gated [BASELINE standard](docs/baseline.md) — authentic
> upstream framework binaries, xAI Grok (`grok-4-fast-non-reasoning`)
> as the LLM backend, `ai-memory` as the only MCP server, UFW
> disabled, agent-ID provenance stamped, plus live functional probes
> (xAI chat reachable + end-to-end agent → MCP → ai-memory canary)
> **before any scenario is permitted to run.** Each run publishes
> its per-node attestation as `a2a-baseline.json`. See
> [docs/baseline.md](docs/baseline.md) for the full spec.

---

## Position in the release protocol

| Stage | Harness | Validates |
|---|---|---|
| Unit + integration | `cargo test` in ai-memory-mcp | per-module correctness |
| Ship-gate Phases 1-4 | [ai-memory-ship-gate](https://github.com/alphaonedev/ai-memory-ship-gate) | single-node functional, 3-node federation, migration round-trip, fault tolerance |
| **A2A gate** | **this repo** | **multi-agent A2A communication through shared memory** |

The A2A gate dispatches **after** the ship-gate returns
`overall_pass: true`. A red A2A gate blocks customer-facing claims
about "AI agents talk to each other through ai-memory" even if the
underlying infrastructure passes its own gates.

---

## The four-node topology

```
           ┌──────────────────┐
           │   ai-memory      │
           │   HTTP + MCP     │
           │   (federation    │
           │    mesh — 3      │
           │    peers + this  │
           │    coordinator)  │
           └───────┬──────────┘
                   │
    ┌──────────────┼──────────────┐
    │              │              │
    ▼              ▼              ▼
 ┌────────┐    ┌────────┐    ┌────────┐
 │ Node 1 │    │ Node 2 │    │ Node 3 │
 │OpenClaw│    │ Hermes │    │OpenClaw│
 │ Agent  │    │ Agent  │    │ Agent  │
 │ alice  │    │  bob   │    │charlie │
 └────┬───┘    └────┬───┘    └────┬───┘
      │             │             │
      └─────────────┼─────────────┘
                    │   MCP / HTTP writes + recalls
                    ▼
              Node 4: ai-memory serve
              (authoritative store)
```

Four droplets:

| Droplet | Role | Agent | Size |
|---|---|---|---|
| `node-1` | Agent host | OpenClaw — `ai:alice` | `s-2vcpu-4gb` |
| `node-2` | Agent host | Hermes — `ai:bob` | `s-2vcpu-4gb` |
| `node-3` | Agent host | OpenClaw — `ai:charlie` | `s-2vcpu-4gb` |
| `node-4` | ai-memory authoritative | `ai-memory serve --mcp --http` | `s-2vcpu-4gb` |

All four in a DigitalOcean VPC. Agents reach ai-memory via the MCP
stdio transport plus `/api/v1/` HTTP for batch operations. Between
themselves agents never speak directly — every handoff flows through
ai-memory as the shared substrate.

---

## Full-spectrum test surface

Each campaign exercises every memory capability that an agent can
touch:

### 1. Write + read

- Each agent stores memories in its own `agent_id` namespace.
- Each agent recalls memories written by the others.
- Assertions: every write returns 201; every recall returns the
  expected corpus; `agent_id` immutability preserved across the
  round-trip.

### 2. Shared-context handoff

- Agent A writes a memory tagged `handoff-to-B` with scope=team.
- Agent B recalls memories matching `handoff-*` and must see A's
  handoff within the quorum-settle window.
- Tests the explicit A2A communication pattern.

### 3. Targeted share (if v0.6.0.1 `memory_share` is present)

- Agent A invokes the `memory_share` MCP tool to hand-pick a subset
  and push to Agent C's instance.
- Agent C confirms receipt via recall.
- Tests the issue-#311 capability.

### 4. Federation-aware agents

- Agent A writes to node-4 (the authoritative store).
- Agent B reads from its closest federation peer (node-2's local
  ai-memory replica under quorum-writes 2).
- Assertions: convergence within the ship-gate Phase 2 settle
  window, no `quorum_not_met` under steady state.

### 5. Consolidation + curation

- Agents write 100 similar memories.
- `memory_consolidate` is invoked; agents re-read and see the
  consolidated form.
- Tests that the consolidation pipeline respects agent identity
  preservation.

### 6. Contradiction detection

- Agent A writes "X is true."
- Agent B writes "X is false."
- `memory_detect_contradiction` is invoked; both memories surface
  with the `contradicts` link.
- Agent C recalls on topic X and sees both plus the link.

### 7. Scoping visibility

- private, team, unit, org, collective scopes each exercised by
  a different agent.
- Assertion matrix: each scope's visibility rules enforced at
  recall time.

### 8. Auto-tagging (if Ollama is provisioned)

- Agents write memories without tags.
- Auto-tag pipeline runs.
- Agents recall by the auto-generated tags.
- Opt-in (requires bumping droplet size to `s-4vcpu-16gb` for
  Gemma 4 E2B — cost note in methodology).

---

## Pass criteria

Campaign-level verdict collapses into a single JSON
`{pass: bool, reasons: [...]}` per test group. The aggregator
(`scripts/collect_reports.sh`, to be written) produces an
`a2a-summary.json` with `overall_pass` = all-groups-pass.

Ship-gate posture applies: red campaign blocks release-eligibility
for customer-facing A2A claims.

---

## Running your own campaign

```sh
gh repo fork alphaonedev/ai-memory-ai2ai-gate --clone
gh secret set DIGITALOCEAN_TOKEN -R <your-fork>
gh secret set DIGITALOCEAN_SSH_KEY_FINGERPRINT -R <your-fork>
gh secret set DIGITALOCEAN_SSH_PRIVATE_KEY -R <your-fork>
gh workflow run a2a-gate.yml -R <your-fork> \
  -f ai_memory_git_ref=release/v0.6.0 \
  -f campaign_id=my-a2a-run
```

(Workflow + scripts to be written in follow-up commits.)

---

## Status

Scaffolding phase. This README is the design document. Next commits
will add:

1. `terraform/` — 4-node VPC module
2. `.github/workflows/a2a-gate.yml` — campaign dispatcher
3. `scripts/setup_openclaw_agent.sh` — per-node agent provisioning
4. `scripts/setup_hermes_agent.sh` — same for Hermes
5. `scripts/scenarios/` — one file per test group above
6. `docs/` — methodology, per-group pass criteria, reproducing
7. `runs/` — per-campaign artefacts (mirrors ship-gate convention)

---

## Related

- [ai-memory-mcp](https://github.com/alphaonedev/ai-memory-mcp) — the
  memory system under test.
- [ai-memory-ship-gate](https://github.com/alphaonedev/ai-memory-ship-gate)
  — the prior-stage gate that validates ai-memory itself.
- Issue [ai-memory-mcp#311](https://github.com/alphaonedev/ai-memory-mcp/issues/311)
  — targeted `memory_share` capability that scenario 3 exercises.

---

## License

Apache-2.0. See `LICENSE` (to be committed).

Copyright © 2026 AlphaOne LLC.
