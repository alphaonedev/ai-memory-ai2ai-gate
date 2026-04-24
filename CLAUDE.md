# CLAUDE.md — alphaonedev/ai-memory-ai2ai-gate

**THIS FILE IS A THIN OVERLAY.** The master engineering / architecture / RCA / security standards live in ai-memory:

> **`the-standard` namespace → memory `f57e9da1-08e5-4401-b5fc-fe909e97a1ec`**
>
> *"THE STANDARD — AI NHI Bible for software engineering, architecture, design, delivery (v1, 2026-04-22)"*

**First action on every session:**

```
memory_namespace_get_standard the-standard
memory_get f57e9da1-08e5-4401-b5fc-fe909e97a1ec
memory_recall "<your current task keywords>" --namespace ai-memory
```

If `the-standard` and this file ever conflict, **the-standard wins**. File an issue to remove the duplication.

---

## Repo-specific context (a2a-gate only)

Everything below supplements the-standard with info that's unique to this repo. No general engineering rules here — those live in the-standard.

### §R1. Authoritative references

- **Tracking epic**: [#14](https://github.com/alphaonedev/ai-memory-ai2ai-gate/issues/14) — testbook v3.0.0 matrix.
- **Plan memory**: `f33a9d4f-bb9d-4995-90ee-1a8bc446d524` in `ai-memory` namespace.
- **ai-memory repo-specific standards memory**: `11234e70-1c42-489d-94b4-1d3f6b7d3ac2` (inherits from the-standard).
- **RCA memories**:
  - `a5d2026b-c96b-49a6-9fc4-31599054b198` — federation quorum timeout under TLS (upstream bug, ai-memory-mcp#333).
- **Testbook**: `docs/testbook.md` (v3.0.0, 42 scenarios).
- **Baseline spec**: `scripts/setup_node.sh` + `docs/baseline.md`.
- **Python test harness**: `scripts/a2a_harness.py` (stdlib only).

### §R2. Enforced workflow watchdogs

Per the-standard §9. Current enforcement in `.github/workflows/a2a-gate.yml`:

| Step | Normal | Timeout |
|---|---|---|
| Pre-apply VPC cleanup | 30 s | 6 min |
| Terraform init + apply | 2–3 min | 8 min |
| Wait for SSH | 30–60 s | 3 min |
| Generate ephemeral TLS material | < 10 s | 2 min |
| Runner build (source-build only) | 2–3 min (warm cache) | 15 min |
| Distribute ai-memory binary | 5–8 s per droplet, parallel | 5 min |
| Provision all 4 nodes | 5–8 min (binary pre-staged) · 15–20 min (legacy source-build) | 20 min (was 40; runner-build path dominates) |
| Collect + enforce BASELINE | 1–2 min | 5 min |
| Functional probe F3 | 10–15 s | 2 min |
| Compute scenarios list | < 5 s | 1 min |
| Run scenarios | 8–12 min | 25 min |
| Tear down infrastructure | 2 min | 6 min |
| Job-level cap | – | 50 min |

If a step exceeds its timeout: cancel & diagnose (don't wait for job cap).

### §R3. Dispatch hygiene (9-cell matrix)

- Always dispatch with `--ref main`.
- Different `agent_group` → different VPC CIDRs (`agent_type × tls_mode` map in `terraform/main.tf` lives at `10.10-13.x.0/24`). Parallel-safe.
- Same `agent_group` + different `tls_mode` → different CIDRs, but GH Actions `concurrency` groups on `agent_group` → queue serially (~25 min/cell).
- DO VPC teardown is async. The `Pre-apply VPC cleanup` step deletes orphans matching the target CIDR before `terraform apply`.

### §R4. testbook v3.0.0 matrix status (live)

All cells run on `release/v0.6.2` + `ai_memory_source_build=true` on DigitalOcean and, for openclaw, also on the [local Docker mesh](docs/local-docker-mesh.md).

| | off | tls | mtls |
|---|---|---|---|
| **ironclaw (DO)** | ✅ v3r30 35/35 | ✅ v3r30 35/35 | ✅ v3r30 37/37 |
| **hermes (DO)** | ✅ v3r30 35/35 | ✅ v3r30 35/35 | ✅ v3r30 37/37 |
| **openclaw (local-docker)** | ✅ r3 35/35 | ✅ tls-r3 35/35 | ✅ mtls-r3 37/37 |
| **mixed** | ⏸ terraform topology work | ⏸ topology | ⏸ topology |

**v0.6.2 CERTIFIED 2026-04-24** — streak 3/3 achieved on DO (v3r28/r29/r30) + three consecutive full-testbook greens for openclaw on local-docker (`a2a-openclaw-v0.6.2-local-docker-{r1,r2,r3}`). Cert run head commit on `release/v0.6.2`: `3e018d6` (PRs ai-memory-mcp#368 + #369 S40 fanout retry + terminal catchup batch). Harness updates in this cycle: ai-memory-ai2ai-gate#55 (drop S20 from tls append), #56 (S23 large-body-via-ssh-stdin), plus the harness `TOPOLOGY=local-docker` fork.

Dispatch lesson: **DO droplet quota is shared across both agent_group concurrency queues.** At most 2 concurrent 4-node campaigns can coexist. Safe pattern: dispatch `off` pair → wait both → dispatch `tls` pair → wait both → dispatch `mtls` pair. Local-docker mesh has no DO quota — runs can dispatch back-to-back instantly.

mTLS unblocked on 2026-04-22 via two a2a-gate fixes:
- #35 — allowlist generator emits labels as separate comment lines (ai-memory-mcp parser-tolerance follow-up: alphaonedev/ai-memory-mcp#358).
- #36 — F6 probe presents client cert under mtls so `openssl s_client` handshake completes.

The 13 scenario-level failures (`1, 12, 18, 28, 29, 30, 32, 33, 34, 35, 36, 39, 40`) are framework-level issues — identical set across ironclaw × off / hermes × off / ironclaw × mtls / hermes × mtls. Not mtls regressions.

mtls-specific scenarios `S20` (TLS enforcement) + `S21` (mtls enforcement) PASS on both frameworks — mtls is functionally proven end-to-end.

Keep this table current — every completed / blocked cell updated in this file AND in issue #14.

### §R5. v3 test suite invariants

- All 42 scenarios are Python 3 under `scripts/scenarios/*.py`.
- Shared harness: `scripts/a2a_harness.py` — stdlib only, NO pip installs on the runner.
- Emit contract: stdout = single JSON line; stderr = human log; exit 0 on clean run (pass/fail/skip); non-zero only on hard crash.
- Scenarios framework-agnostic — same scripts run on ironclaw & hermes droplets identically (proven 2026-04-22).

### §R6. What NOT to touch here (owned by the-standard)

- General engineering standards, RCA ladder, verification protocol, commit discipline, signing, secret scanning, memory discipline, architecture / design / UX principles — **all in the-standard**. Don't duplicate; reference.
