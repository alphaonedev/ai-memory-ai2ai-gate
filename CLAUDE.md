# AI NHI operational standards — alphaonedev/ai-memory-ai2ai-gate

**Purpose:** durable contract for any AI NHI (Claude, Codex, Grok, etc.) picking up work on this repo. Read this first, every session. Violations are treated as regressions.

---

## 1. The "no babysitting" standard

You are an autonomous engineer. The human should NOT have to ping you for status. If they do, you failed the standard.

**Forward progress or explicit blocker, every turn.** No silent idle. No "waiting for run" without a plan to check it.

Concretely:
- Do NOT wait passively for a workflow run to complete and sit doing nothing. Use the wait time to analyze, prepare the next step, or fix adjacent issues.
- When dispatching anything that takes > 5 min (CI run, DO provisioning, etc.), immediately plan the next 3–5 actions that don't depend on the result, and execute them.
- If nothing else can be done, state that explicitly AND schedule a check-back (via `/loop dynamic` / `ScheduleWakeup` if in loop mode, or tell the user the ETA and stop — don't dribble useless tokens).

**The overnight-hang failure** (2026-04-22): terraform jobs hung for hundreds of minutes with zero forward progress. This happened because I lacked:
- Step-level workflow timeouts (one hung step consumed the entire job budget)
- Automated diagnosis of hung infra
- A /loop wake-up to kill stuck runs

All three are now required. See §4 below.

## 2. Methodical, sequenced engineering

- **One change, one PR, one validation** — don't stack 5 unrelated fixes into one PR.
- **Hypothesis → test → observation → next hypothesis.** Never guess twice without a new data point in between.
- **Read the source, not the documentation.** Both product source (`/root/ai-memory-mcp`) and workflow code are on disk. When you see HTTP 400/404/405/422, grep the handler before re-reading the test.
- **Commit boundaries match logical units.** One PR = one specific root cause addressed. Artifacts commits (`campaign: ...`) are data, not code changes.
- **Track in GitHub issues, not session-local tasks.** Every multi-PR effort references an EPIC issue (currently #14 for testbook v3.0.0). Every commit body must reference it.

## 3. Data-proven forward progress

Before declaring anything complete:
1. Is there a green GitHub Actions run? Link it.
2. Is there a JSON artifact in `runs/<campaign-id>/`? Inspect it.
3. Is the PR merged to main? Verify via `git log origin/main`.

"I committed the fix" is not completion. "The workflow ran and the fix produced expected output" is.

## 4. Infrastructure watchdogs (required)

Every long-running operation MUST have a timeout smaller than its "normal × 3" expected duration, so hangs cap themselves instead of burning the full job budget.

Current standards (enforced in `.github/workflows/a2a-gate.yml`):

| Step | Normal | Timeout |
|---|---|---|
| `Terraform init + apply` | 2–3 min | **8 min** |
| `Wait for SSH` | 30–60 s | 3 min |
| `Generate ephemeral TLS material` | < 10 s | 2 min |
| `Provision all 4 nodes (federation mesh)` | 6–8 min | **15 min** |
| `Collect + enforce BASELINE` | 1–2 min | 5 min |
| `Functional probe F3` | 10–15 s | 2 min |
| `Run scenarios` | 8–12 min | **25 min** |
| Job-level `timeout-minutes` | – | **50 min** (cap) |

If you observe a run exceeding its step timeout, **cancel and diagnose** — don't wait for the job-level cap.

## 5. Dispatch hygiene (9-cell matrix)

- Always dispatch with `--ref main` so the queued run uses the exact committed SHA.
- Dispatches of different `agent_group` use different VPC CIDRs (`agent_type × tls_mode` map in `terraform/main.tf`) and can run in parallel.
- Dispatches of the SAME `agent_group` + different `tls_mode` ALSO have different CIDRs but GH Actions `concurrency` groups them on `agent_group` → they queue serially. Expect ~25 min per cell; plan accordingly.
- DO VPC teardown is asynchronous. The `Pre-apply VPC cleanup` step (see `.github/workflows/a2a-gate.yml`) handles orphans. If it ever reports `no orphan VPC at X — clean` but apply still fails, the CIDR map is wrong.

## 6. Status-update standards

Every status message must include:
1. **What was done since last turn** (not "I'm working on X")
2. **Current state** (PR open/merged/running, artifact paths, scenario counts)
3. **Next 1–3 actions** (not a 10-step plan — 3 concrete steps)
4. **Blockers**, if any, with what I'll do about them

No filler. No "I'll keep you posted" with no substance. No narrating thought process — state outcomes and decisions.

## 7. Canonical references (read before editing)

- **Tracking epic**: [#14](https://github.com/alphaonedev/ai-memory-ai2ai-gate/issues/14) — all 9-cell matrix progress.
- **Plan memory**: `f33a9d4f-bb9d-4995-90ee-1a8bc446d524` in `ai-memory` namespace.
- **This standards memory**: stored as `ai-memory` priority 10 long-tier on 2026-04-22.
- **Testbook**: `docs/testbook.md` (v3.0.0, 42 scenarios).
- **Baseline spec**: `scripts/setup_node.sh` + `docs/baseline.md`.
- **Harness**: `scripts/a2a_harness.py` (stdlib only, no pip on runner).

## 8. Anti-patterns (do NOT)

- ❌ Wait silently for a run without scheduling your own check-back.
- ❌ Dispatch 6+ workflows in rapid succession without accounting for DO VPC teardown + GH concurrency.
- ❌ Commit a fix and declare victory before seeing the green run JSON.
- ❌ Guess at a broken endpoint's payload when the handler source is checked out at `/root/ai-memory-mcp/`.
- ❌ Skip referencing the tracking epic in a commit body.
- ❌ Push directly to `main` — always through a PR.
- ❌ Leave an in-flight PR un-merged when all checks are green and the PR is obviously correct.
- ❌ Narrate your thinking as a substitute for doing the work.
