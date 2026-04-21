# Incident log — what r2–r12 taught us

Every iteration of the A2A gate on 2026-04-20 / 2026-04-21 surfaced one new bug in the provisioning or test infrastructure. This log records each honestly so future operators (human or AI NHI) can see the lineage from first scaffolding dispatch to first green campaign.

Classic ship-gate pattern: the iterations ARE the diagnostic. Every red teaches something; every fix moves one step deeper into the stack.

---

## Iteration index

| Run | Date | Verdict | Root cause | Fix commit |
|---|---|---|---|---|
| r2 | 2026-04-20 | RED | VPC CIDR typo `10.260.0.0/24` (invalid IPv4) | `18f05d2` |
| r3 | 2026-04-20 | RED | Concurrent VPC CIDR collision (both groups requested same `/24`) + DO tag dots | `82d9fe2`, `4998ae2` |
| r3-hermes | 2026-04-20 | RED | Stale CIDR hardcoded in firewall `inbound_rule source_addresses` | `c7bffef` |
| r4 | 2026-04-20 | RED | Stale `.pub` file → wrong SSH key fingerprint in repo secret | key rotation |
| r5-openclaw | 2026-04-20 | MIXED | Phase B shell arithmetic crash on multi-line output + Phase C firewall-blocked public IP | `ac6f56d` (hermes) + scenario fixes |
| r5-hermes | 2026-04-20 | RED | `hermes -p` is `--profile`, not `--prompt` | `ac6f56d` |
| r6-openclaw | 2026-04-20 | RED (honest) | **MCP stdio writes bypass federation fanout coordinator** → [ai-memory-mcp#318](https://github.com/alphaonedev/ai-memory-mcp/issues/318), targeted v0.6.0.1 | substrate fix pending |
| r6-hermes | 2026-04-20 | RED | `hermes` import fails with `ModuleNotFoundError: dotenv` — upstream install.sh gap | `e129b53` |
| r7 | 2026-04-20 | RED | (a) openclaw install.sh exit-1 despite success (non-TTY wizard) (b) baseline PROBE F2 caught #318 | `dd49e5a` (real openclaw install) + `bd0db1b` (baseline spec) |
| r7 (post-baseline) | 2026-04-20 | RED (honest) | Baseline gate working — F2b canary correctly flagged #318 | gate doing its job |
| r8 | 2026-04-21 | RED | openclaw pipe SIGPIPE on `openclaw --version \| head -1` under `set -o pipefail` | `195e349` |
| r9 (hermes only) | 2026-04-21 | **GREEN** | First successful campaign — baseline + F3 + S1b all pass | — |
| r9 (openclaw) | 2026-04-21 | RED | Race: dispatched before install fix landed; install.sh exit-1 still | `bc5f025` |
| r10 (openclaw) | 2026-04-21 | RED | npm `openclaw@2026.4.20` ETARGET — that's a display label, not an npm semver | revert to install.sh + drift-capture |
| r11 | 2026-04-21 | CANCELLED | Provision step stalled 37+ min — no timeouts on F2b canary / install scripts | `6face55` (timeout hardening) |
| r12 | 2026-04-21 | in flight | Full timeout-hardened pipeline | — |

---

## Key learnings

### Lesson 1 — `set -o pipefail` + `| head -N` is a SIGPIPE landmine
In r7–r8, `openclaw --version 2>&1 | head -1` returned non-zero despite openclaw succeeding — `head` closed stdin after 1 line, SIGPIPE'd openclaw, and pipefail propagated the non-zero exit. Fix: capture output to a variable, then `echo | head` from the variable. [Commit `195e349`](https://github.com/alphaonedev/ai-memory-ai2ai-gate/commit/195e349).

### Lesson 2 — Upstream install scripts exit non-zero on headless environments
Both `openclaw.ai/install.sh` and parts of hermes-agent's installer assume a TTY and exit non-zero when run from a GitHub Actions runner (no TTY). The binaries install correctly; the wizard fails. Fix: pipe install through `| sed 'prefix'` and ignore exit code; rely on presence check. [Commit `bc5f025`](https://github.com/alphaonedev/ai-memory-ai2ai-gate/commit/bc5f025).

### Lesson 3 — Every long-running subprocess MUST have a timeout
r11 hung 37+ min on Provision because F2b agent canary had no timeout — if xAI Grok rate-limits or the agent CLI stdin-blocks, the script hangs until the 60-min workflow timeout. Fix: explicit `timeout <sec>` on every subprocess. [Commit `6face55`](https://github.com/alphaonedev/ai-memory-ai2ai-gate/commit/6face55).

### Lesson 4 — Display versions ≠ registry versions
"OpenClaw 2026.4.20 (f50202e)" is a git-commit-style label, NOT an npm semver. `npm install -g openclaw@2026.4.20` fails with ETARGET. Pinning requires knowing the actual npm semver (currently unknown for openclaw — documented as an upstream gap in [baseline.md §3b](baseline.md#3b-version-pinning--every-dependency-pinned-for-repeatability)).

### Lesson 5 — The gate catches real product bugs
r6-openclaw and r7-hermes both surfaced [ai-memory-mcp#318](https://github.com/alphaonedev/ai-memory-mcp/issues/318) — MCP stdio writes don't trigger federation fanout. The gate's job is exactly this: to refuse to run scenarios when the substrate has gaps. F2b (non-gating in v1.2.0) correctly reports this bug on every dispatch while F2a (HTTP substrate, gating) passes — making the dashboard tell the honest story without halting CI.

### Lesson 6 — `jq '// empty'` treats `false` as null
A subtle bug in the HTML generator: `jq '.pass // empty'` returned empty string when `.pass: false` because jq's `//` treats `false` as the null-alternative. Fix: `jq 'if .pass == null then empty else .pass end'`. This made r6-openclaw render "UNKNOWN" instead of "FAIL" on the dashboard. [Commit chain around `e30586f`].

### Lesson 7 — VPC CIDR partitioning is mandatory for concurrent dispatch
Running both groups simultaneously requires distinct CIDRs; otherwise terraform race-conditions on VPC creation. `local.vpc_cidr` partitions to `10.251.0.0/24` (openclaw) vs `10.252.0.0/24` (hermes). [Commit `82d9fe2`].

### Lesson 8 — UFW on Ubuntu 24.04 is default-on and must be hard-disabled
Ship-gate r21/r23 lesson, re-confirmed here: Ubuntu 24.04 ships UFW enabled and configured, interfering with loopback + intra-VPC traffic the federation mesh needs. `setup_node.sh` does `ufw --force reset && ufw --force disable` twice (reset re-enables on some UFW builds), then `iptables -P ACCEPT + iptables -F`, then baseline-level verification with `exit 3` on failure. Same belt-and-suspenders pattern as the secret redaction.

### Lesson 9 — "Absolutely truthful reporting" is a code contract
Every scenario emits a JSON verdict BEFORE the exit code is set. Every failure lists specific reasons. Every attestation is computed from live droplet state, never from config intent. The dashboard renders what the JSON says, not what we wish it said. [testbook.md §4.4](testbook.md#44-json-report-schema) + [baseline.md §8](baseline.md#8-baseline-attestation-schema).

---

## Forward-looking (not yet surfaced, documented for completeness)

Expected future incidents and their mitigations:

- **xAI rate limiting under S4 burst**: scenario 4 writes 90 rows in ~5s with 3 agents. If xAI throttles the agent CLIs, F2b will fail cleanly (60s timeout). S4 itself doesn't use xAI — it's HTTP-direct — so rate limits don't block the scenario. Baseline attestation captures the issue as F2b red while S4 passes.

- **DO region capacity**: a specific region running out of droplet capacity would fail terraform apply at step 3. `region` is a workflow input; operators can switch to `sfo3`, `ams3`, etc.

- **ai-memory v0.6.0 EOL**: when v0.6.0.1 ships with the #318 fix, the workflow's `ai_memory_git_ref` default bumps to v0.6.0.1 + F2b moves from "attestation-only" to "gates baseline" (minor spec bump per [baseline.md §12](baseline.md#12-change-control)).

- **openclaw post-install wizard change**: future openclaw releases may change the post-install behavior (could fail in a new way OR finally work headless). The drift-capture in `framework_version` attestation field would surface the version that's running.

- **Hermes breaking change on `main` ref**: we pin the install script URL to `main` branch (unpinned at tag level — documented gap). A future hermes `main` could change the install surface. `HERMES_INSTALL_REF` env override exists to pin to a specific tag once upstream ships a stable release tag.

---

## Change log of this document

- **2026-04-21** — initial authoring after r12 dispatch. Captures r2–r11 full post-mortem.

Future entries go at the top; keep the table at the top sorted newest-first once r12+ land.
