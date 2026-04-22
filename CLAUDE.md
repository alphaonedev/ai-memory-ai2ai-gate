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
| Provision all 4 nodes | 6–8 min | 15 min |
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

| | off | tls | mtls |
|---|---|---|---|
| **ironclaw** | ✅ v3r5 (21/13) | ⛔ blocked ai-memory-mcp#333 | ⛔ blocked ai-memory-mcp#333 |
| **hermes** | ✅ v3r7 (21/13) | ⛔ blocked ai-memory-mcp#333 | ⛔ blocked ai-memory-mcp#333 |
| **mixed** | ⏸ terraform topology work | ⛔ ai-memory-mcp#333 + topology | ⛔ ai-memory-mcp#333 + topology |

Keep this table current — every completed / blocked cell updated in this file AND in issue #14.

### §R5. v3 test suite invariants

- All 42 scenarios are Python 3 under `scripts/scenarios/*.py`.
- Shared harness: `scripts/a2a_harness.py` — stdlib only, NO pip installs on the runner.
- Emit contract: stdout = single JSON line; stderr = human log; exit 0 on clean run (pass/fail/skip); non-zero only on hard crash.
- Scenarios framework-agnostic — same scripts run on ironclaw & hermes droplets identically (proven 2026-04-22).

### §R6. What NOT to touch here (owned by the-standard)

- General engineering standards, RCA ladder, verification protocol, commit discipline, signing, secret scanning, memory discipline, architecture / design / UX principles — **all in the-standard**. Don't duplicate; reference.
