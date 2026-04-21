# Changelog

All notable changes to the ai-memory-ai2ai-gate harness.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Baseline spec + test book versions follow their own semver lines within this log.

---

## [Unreleased]

### Added
- 16 scenarios across 6 suites in `scripts/scenarios/` — full-spectrum A2A coverage (was 8)
- `docs/architecture.md` — system architecture with diagrams + AI NHI collaboration model
- `docs/runbook.md` — operator day-to-day procedures with triage tables
- `docs/incidents.md` — r2–r11 incident log with learnings
- `docs/testbook.md` v2.0.0 — 18-scenario formal test plan
- `docs/baseline.md` v1.2.0 — C1-C10 + F1 + F2a/F2b + negative invariants + gate sequence diagram
- Functional probes F1 (xAI reachability), F2a (substrate HTTP canary, deterministic), F2b (agent MCP canary, LLM-dependent, non-gating), F3 (peer A2A via shared memory)
- Config attestation for iptables, dead-man switch, config file SHA-256
- Negative invariants — explicit disable of every alternative A2A channel per framework
- Baseline attestation schema with versioning
- Redaction pass on committed artifacts with post-redaction grep verify
- Timeout hardening on every long-running subprocess in `setup_node.sh`
- ERR trap with line number logging
- Timestamp-prefixed log lines for wall-clock diagnosis
- `framework_version` drift capture when hard pinning isn't available

### Changed
- Workflow default scenarios: `"1 1b"` → `"1 1b 2 4 5 6 9 10 11 12 13 14 15 16 17 18"`
- openclaw install: grok-CLI surrogate → authentic `openclaw/openclaw` via official installer
- hermes install pinned to `HERMES_INSTALL_REF=main` (will pin to tag in v1.3)
- `python-dotenv` pinned to `1.0.1`
- Baseline spec version bumped `1.0.0 → 1.1.0 → 1.2.0` over the 2026-04-21 iteration sequence

### Fixed
- r7-r8 openclaw install.sh exit-1 in non-TTY environments (commit `bc5f025`)
- r8 `openclaw --version | head -1` SIGPIPE under `set -o pipefail` (`195e349`)
- r10 `npm install -g openclaw@2026.4.20` ETARGET (display label ≠ npm semver)
- r11 provision stall at 37+ min — timeouts on every subprocess (`6face55`)
- Scenario `scenario-N.json` stdout corruption by log lines (`e30586f` era — stdout/stderr split)
- `collect_reports.sh` fragile on legacy mixed files — robust JSON recovery
- `generate_run_html.sh` false-UNKNOWN rendering when `.pass: false` (jq `//` treating false as null)
- Dashboard missing baseline + F3 columns — full attestation now rendered

### Security
- Redaction sed pass + grep verify before commit; `exit 4` on any known-secret leak
- Generic xAI key pattern masking (rotated-key safety net)
- Authorization Bearer header masking
- Droplet IPs committed intentionally (ephemeral); no operator PII
- UFW disabled + verified + hard-fail (`exit 3`) on every node

---

## Baseline spec history

| Version | Date | Notes |
|---|---|---|
| 1.2.0 | 2026-04-21 | F2 split (F2a gates, F2b attestation-only); iptables + dead-man + config_sha fields; version pinning §3b |
| 1.1.0 | 2026-04-21 | Added F3 peer A2A probe; terminology fix (VPC vs DO Cloud Firewall) |
| 1.0.0 | 2026-04-21 | Initial lockdown: C1–C8 + F1 + F2 + negative invariants + security spec |

## Test book history

| Version | Date | Notes |
|---|---|---|
| 2.0.0 | 2026-04-21 | Full-spectrum expansion to 18 scenarios across 6 suites (A-F); same-node + between-node A2A |
| 1.0.0 | 2026-04-21 | Initial 8-scenario core |

## Release history

Tags referenced by this harness:
- `ai-memory-mcp` `v0.6.0` — current substrate target (release 2026-04-20)
- `ai-memory-mcp` `v0.6.0.1` — planned, includes #318 MCP-stdio-federation fix

## Campaign run history

Published evidence at https://alphaonedev.github.io/ai-memory-ai2ai-gate/runs/. See [docs/incidents.md](docs/incidents.md) for per-run narrative and learnings.
