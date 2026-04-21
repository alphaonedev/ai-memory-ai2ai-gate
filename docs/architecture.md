# Architecture — ai-memory A2A gate

**How every piece fits together.** For operators running campaigns, engineers extending the harness, and auditors verifying the evidence chain.

---

## 1. What this repository is

A reproducible test harness that provisions a 4-node DigitalOcean VPC, installs two heterogeneous AI agent frameworks (OpenClaw + Hermes, one per campaign), wires both to the same `ai-memory` federation mesh, and runs a suite of scenarios proving (or disproving) that agents can coordinate through shared memory as their only communication channel.

The output is committed evidence. No closed-box claims.

---

## 2. System layers

```
┌─────────────────────────────────────────────────────────────┐
│                   GitHub (source of truth)                  │
│  ┌──────────────────┐   ┌────────────────────────────────┐  │
│  │  main branch     │   │  repo secrets (encrypted)       │  │
│  │  - scripts/      │   │  - DIGITALOCEAN_TOKEN           │  │
│  │  - terraform/    │   │  - DIGITALOCEAN_SSH_PRIVATE_KEY │  │
│  │  - docs/         │   │  - DIGITALOCEAN_SSH_KEY_FP      │  │
│  │  - .github/      │   │  - XAI_API_KEY                  │  │
│  └──────────────────┘   └────────────────────────────────┘  │
│           │                        │                         │
│           │ workflow_dispatch     │ consumed by workflow    │
│           ▼                        ▼                         │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  .github/workflows/a2a-gate.yml  (the gate)            │  │
│  │  ubuntu-24.04 runner                                   │  │
│  └───────────────────────────────────────────────────────┘  │
└──────────────────────────────┬──────────────────────────────┘
                               │  Terraform + ssh
                               ▼
┌─────────────────────────────────────────────────────────────┐
│                DigitalOcean (ephemeral)                      │
│  ┌──────────────────┐   ┌────────────────────────────────┐  │
│  │  VPC 10.251/24   │   │  DO Cloud Firewall             │  │
│  │  (openclaw)      │   │  - 22 in  (runner only)         │  │
│  │  or 10.252/24    │   │  - 9077 in (same VPC only)      │  │
│  │  (hermes)        │   │  - * out  (xAI, GitHub, etc)   │  │
│  └────────┬─────────┘   └────────────────────────────────┘  │
│           │                                                  │
│     ┌─────┼─────┬─────────┬─────────────┐                   │
│     │     │     │         │             │                   │
│     ▼     ▼     ▼         ▼             ▼                   │
│  ┌─────┐┌─────┐┌─────┐┌─────────────────────────┐           │
│  │ node│ node│ node│ node-4                   │           │
│  │  -1 │  -2 │  -3 │ memory-only              │           │
│  │alice│ bob │charl│ (aggregator, no agent)   │           │
│  └──┬──┘└──┬──┘└──┬──┘└───────────┬─────────────┘           │
│     │     │     │               │                            │
│     └─────┴─────┴───────────────┘                            │
│       federation W=2/N=4 over port 9077                       │
└─────────────────────────────────────────────────────────────┘
```

Each droplet is **Ubuntu 24.04 LTS x64** (`ubuntu-24-04-x64`) running:

1. `ai-memory serve --quorum-writes 2 --quorum-peers <other-3>` — the long-running federation daemon on `0.0.0.0:9077`
2. `ai-memory mcp` — short-lived stdio child, spawned per MCP tool call by the agent CLI
3. Agent framework (`openclaw` or `hermes`) — takes prompts, invokes MCP tools
4. `shutdown -P +480` — dead-man switch capping droplet life at 8h

---

## 3. Communication topology

**The only A2A path permitted by the baseline**:

```
  Agent A on node-1              Agent B on node-2
       │                                ▲
       │ 1. agent reasons (xAI Grok)    │ 5. agent reads (MCP recall)
       │ 2. selects memory_store tool    │
       ▼                                │
  `ai-memory mcp` stdio child           │
       │                                │
       │ 3. writes to local serve HTTP   │ 4. local serve returns row
       │                                │
       ▼                                │
  Local `ai-memory serve` on node-1     Local `ai-memory serve` on node-2
       │                                ▲
       │   federation W=2 fanout        │
       └───────► other 3 peers ◄────────┘
                   (nodes 2, 3, 4)
```

Every other agent-to-agent communication channel that OpenClaw or Hermes natively supports is **explicitly disabled** in the per-droplet config (see [baseline.md §6b.2 / §6b.3](baseline.md#6b-a2a-communication-architecture--the-single-allowed-path)):

- OpenClaw: `agentToAgent: false`, no sessions_send/spawn tools, no Telegram/Discord/Slack/Moltbook channels, no gateway remote mode, no node hosts, no subAgent, no agentTeams, no shared Postgres/Redis/Supabase
- Hermes: `acp.enabled: false`, `messaging.gateway_enabled: false`, no execution backends, `mcp_server_mode: false`, no subagent_delegation

This lock-down makes the A2A gate's thesis — "agents can coordinate through shared memory alone" — **falsifiable**: if a scenario passes, it passed via ai-memory, not via a back-channel.

---

## 4. The gate sequence

`.github/workflows/a2a-gate.yml` runs these steps. Each gate is sequential — the next step only executes on green.

| Step | Action | Gate | Exit on fail |
|---|---|---|---|
| 1 | `actions/checkout@v5` | Source retrievable | workflow abort |
| 2 | `hashicorp/setup-terraform@v3` | Terraform CLI available | workflow abort |
| 3 | `terraform init + apply` | 4 droplets + VPC + firewall created | abort (destroy runs at cleanup) |
| 4 | Wait for SSH (30 × 5s retries per node) | All 4 droplets SSH-reachable | abort |
| 5 | Provision all 4 nodes (`setup_node.sh` via ssh) | UFW disabled + ai-memory serve live + agent installed + C1–C10 + F1 + F2a + F2b attested + baseline.json emitted; exit 2/3 on baseline fail | abort |
| 6 | Collect + enforce BASELINE | scp baseline.json from 3 agent nodes; all must show `baseline_pass: true` | `baseline_ok = false` → next step skipped |
| 7 | Functional probe F3 (peer A2A canary) | Write on node-1, W=2 settle, verify on nodes 2, 3, 4 | `f3_ok = false` → scenarios skipped |
| 8 | Run scenarios (`if: baseline_ok && f3_ok`) | Each scenario script emits `scenario-N.json` (stdout) + `scenario-N.log` (stderr) | script exit code recorded; doesn't halt others |
| 9 | Emit `campaign.meta.json` (always) | DO region + node roster + actor + workflow URL | soft error |
| 10 | Aggregate campaign summary (always) | `collect_reports.sh` → `a2a-summary.json` | soft error |
| 11 | Regenerate evidence HTML (always) | `generate_run_html.sh` → `index.html` | soft error |
| 12 | Redact secrets (always) | sed pass + grep verify; **exit 4 if any known secret leaks** | workflow fail |
| 13 | Commit campaign artifacts (always) | git add + commit + push with 5-retry rebase loop | soft error |
| 14 | Tear down (`if: always()`) | `terraform destroy -auto-approve` | soft error (dead-man switch is backstop) |

**Every long-running subprocess inside setup_node.sh has a timeout** (since commit `6face55` after r11 hang):

| Subprocess | Timeout |
|---|---|
| `openclaw install.sh` | 600s |
| `hermes install.sh` | 600s |
| `npm install -g openclaw` fallback | 300s |
| `pip install python-dotenv` | 180s |
| F2b agent CLI canary | 60s |
| F1 xAI curl | 20s |
| Base apt-get install | no explicit cap (rarely hangs) |

---

## 5. Evidence chain

Every run produces a deterministic evidence bundle under `runs/<campaign-id>/`:

```
runs/a2a-openclaw-v0.6.0-rN/
├── a2a-baseline.json          # per-node attestation union
├── baselines/
│   ├── node-1.baseline.json   # raw self-attestation from alice's droplet
│   ├── node-2.baseline.json   # from bob's droplet
│   └── node-3.baseline.json   # from charlie's droplet
├── f3-peer-a2a.json           # cross-node A2A probe verdict
├── campaign.meta.json         # DO region, node IPs (public + private), actor, workflow URL, harness SHA
├── a2a-summary.json           # scenario rollup, overall_pass, reasons
├── scenario-1.json            # per-scenario JSON verdict
├── scenario-1.log             # per-scenario stderr trace
├── scenario-1b.json
├── scenario-1b.log
├── scenario-2.json
├── scenario-2.log
├── ... (per scenario in the dispatch)
└── index.html                 # human-readable dashboard page
```

The **pages workflow** (`.github/workflows/pages.yml`) then:
1. Regenerates every `runs/*/index.html` (so generator upgrades propagate)
2. Builds the runs landing table with Baseline / F3 / Scenarios / Group / ref / Spec / Actor columns
3. Mirrors `runs/` → `site/evidence/`
4. Builds the `mkdocs-material` site
5. Deploys to GitHub Pages

Both the raw JSON artifacts and the rendered HTML land at `https://alphaonedev.github.io/ai-memory-ai2ai-gate/evidence/<campaign-id>/`. The runs landing is at `https://alphaonedev.github.io/ai-memory-ai2ai-gate/runs/`.

---

## 6. Security posture

- **Secrets**: live only in GitHub encrypted secrets + the ephemeral droplets that `terraform destroy` erases. Redaction sed pass + post-redaction grep verify before commit; `exit 4` if any known secret value is found in any file about to be pushed.
- **Droplet IPs**: committed to `campaign.meta.json` intentionally (audit linkage; ephemeral).
- **No operator PII**: the harness captures only the GitHub actor handle (public) and the workflow run URL.
- **Firewall**: DO Cloud Firewall enforces inbound; Ubuntu UFW explicitly disabled on every node to prevent interference with federation loopback traffic.
- **Dead-man switch**: every droplet schedules `shutdown -P +480` immediately after SSH is reachable. 8h worst-case droplet lifetime regardless of CI state.

See [baseline.md §9b](baseline.md#9b-security--secrets--pii-handling) for the full secret-handling contract.

---

## 7. Who authors what — the AI NHI collaboration model

This harness is built by multiple AI NHIs (non-human identities) collaborating through git commits + committed evidence. No live channels.

| Role | Who | How |
|---|---|---|
| **Harness authoring** | Claude Opus 4.7 (this instance) | Writes scripts + docs + workflow + analysis. Commits to `main`. Never runs on a droplet. |
| **Agent reasoning on droplets** | xAI Grok (`grok-4-fast-non-reasoning`) | Invoked by `openclaw run` or `hermes chat`. Selects MCP tools. Reasoning NEVER read by Claude directly — only via committed scenario logs. |
| **Substrate under test** | ai-memory-mcp (v0.6.0) | The product being validated. Receives MCP tool calls from agents. |
| **Narrative analysis** | Claude Opus 4.7 | Reads committed evidence + writes tri-audience narratives into `analysis/run-insights.json` (engineering / product / executive framing). |

Claude observes the agent AIs only post-hoc via committed files. The A2A gate is therefore a test of AI agents that AI Claude has authored — a legitimate AI-NHI-builds-tests-for-AI-NHIs operation.

---

## 8. What the gate does NOT claim

- Not a chaos engineering harness — injects no faults beyond the partition-tolerance scenario (S14, deferred)
- Not a load-test harness — S4 exercises burst writes but ~100 rows/burst, not thousands
- Not a security penetration test — [docs/security.md](security.md) covers the security posture contract, not red-team coverage
- Not cross-framework A2A by default — current campaigns are homogeneous (all openclaw or all hermes); mixed campaigns are a planned future scenario
- Not a replacement for the [ship-gate](https://github.com/alphaonedev/ai-memory-ship-gate) — which validates ai-memory as a product (CRUD, federation, migration, chaos). The A2A gate sits ON TOP of a green ship-gate to validate agent integration.

---

## 9. Read next

- [Baseline configuration](baseline.md) — the invariants gate
- [Test book](testbook.md) — the scenario catalog
- [Reproducing](reproducing.md) — operator playbook
- [Runbook](runbook.md) — day-to-day operations + diagnostics
- [Incidents](incidents.md) — what we learned from each iteration
- [Methodology](methodology.md) — why these invariants
- [Security](security.md) — threat model + secret handling
