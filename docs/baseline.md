# BASELINE TESTING CONFIGURATION — A2A standard

> **Authoritative, repeatable, enforced.** Every agent droplet of
> every campaign in this repository must satisfy this baseline before
> any scenario is permitted to run. The workflow
> (`.github/workflows/a2a-gate.yml`) enforces it, `scripts/setup_node.sh`
> is the single implementation, and `/etc/ai-memory-a2a/baseline.json`
> on each node is the self-attestation. One false field → provision
> hard-fails → zero scenarios run → dashboard shows ❌ VIOLATION.

**Spec version:** 1.0.0 (locked 2026-04-21)
**Authority:** `docs/baseline.md` in [alphaonedev/ai-memory-ai2ai-gate](https://github.com/alphaonedev/ai-memory-ai2ai-gate).
Any rendered copy (GitHub Pages, PDFs, internal mirrors) is a *copy*; the file in the repository wins.

---

## 1. Scope

Applies to **every agent droplet** of every campaign in this repo.
Both `agent_group=openclaw` and `agent_group=hermes` dispatches are
covered. Node-4 (memory-only) doesn't emit an agent attestation but
must still satisfy the infrastructure-level invariants
(UFW disabled, `ai-memory serve` live and peered).

No per-campaign overrides. No opt-outs. No exceptions.

---

## 2. Infrastructure target

| | Value |
|---|---|
| Cloud provider | DigitalOcean |
| OS image | `ubuntu-24-04-x64` (Ubuntu 24.04 LTS, x86_64) |
| Region | `nyc3` (default; overridable per dispatch) |
| Droplet size | `s-2vcpu-4gb` default; `s-4vcpu-16gb` for Ollama scenarios |
| Network | Dedicated VPC per agent_group, partitioned CIDRs (10.251/24 openclaw, 10.252/24 hermes) |
| Topology | 4 droplets — node-1 / node-2 / node-3 agents + node-4 memory-only aggregator |
| Mesh | ai-memory federation W=2 of N=4, all-to-all peer list on port 9077 over private IPs |
| SSH | ed25519 key, fingerprint registered at DO + in repo secret `DIGITALOCEAN_SSH_PRIVATE_KEY` |
| Lifetime | Dead-man switch: `shutdown -P +480` on every node — 8-hour upper bound regardless of workflow state |

---

## 3. Firewall policy — UFW MUST be disabled

Ubuntu 24.04 ships with UFW installed and pre-configured. Left on, it blocks loopback and intra-VPC traffic the ai-memory federation mesh needs. Ship-gate campaigns r21–r23 all hung specifically because of this. **This is non-negotiable.**

Every node runs, at the top of `setup_node.sh` before anything else:

```bash
ufw --force disable                  # disable
ufw --force reset                    # some UFW builds re-enable on reset — wipe rules
ufw --force disable                  # disable again (belt-and-suspenders)
ufw status                           # verify
case "$ufw_status" in
  *inactive*|*disabled*)  log "UFW confirmed disabled" ;;
  *)                      log "FATAL: UFW still active"; exit 3 ;;  # ← HARD FAIL
esac

# Flush iptables too (Docker-prepped images sometimes have residual DROP policies)
iptables -P INPUT ACCEPT
iptables -P OUTPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -F
```

The `ufw_disabled` field in the baseline attestation re-verifies at the end of provision, and is part of the `baseline_pass` conjunction. A node where UFW is still active cannot pass baseline.

Firewalling is done at the **VPC layer** (DigitalOcean-managed firewalls, configured in `terraform/main.tf`) — same-VPC traffic flows freely, inbound-internet is blocked except for SSH from the runner. OS-level UFW would only interfere.

---

## 4. Agent framework install — authentic upstream binaries

No surrogates. No symlinks to another CLI. If we claim to test OpenClaw, the binary must be `openclaw/openclaw`. If we claim to test Hermes, the binary must be `NousResearch/hermes-agent`.

### OpenClaw

```bash
# Install via the official one-liner (git install method, headless --yes)
curl -fsSL https://openclaw.ai/install.sh | bash -s -- --install-method git --yes

# Fallback if install.sh fails
npm install -g openclaw

# Verify authentic binary (readlink -f must NOT resolve to a non-openclaw path)
openclaw --version
```

### Hermes

```bash
# Install via Nous Research's official installer
curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh \
  | bash -s -- --skip-setup

# Upstream install.sh (as of 2026-04-21) doesn't install python-dotenv
# yet hermes_cli/env_loader.py imports it unconditionally. Patch:
python3 -m pip install --break-system-packages --quiet python-dotenv
```

---

## 5. LLM backend — xAI Grok for both frameworks

**Both frameworks reason with xAI Grok, model `grok-4-fast-non-reasoning`.** Holding the LLM constant is what makes framework-vs-framework comparison meaningful.

### OpenClaw configuration (`~/.openclaw/openclaw.json`)

```json
{
  "providers": {
    "xai": {
      "type": "openai-compatible",
      "api_key": "${XAI_API_KEY}",
      "base_url": "https://api.x.ai/v1",
      "default_model": "grok-4-fast-non-reasoning"
    }
  },
  "defaultProvider": "xai",
  "mcpServers": {
    "memory": {
      "command": "ai-memory",
      "args": ["--db", "/var/lib/ai-memory/a2a.db", "mcp", "--tier", "semantic"],
      "env": {
        "AI_MEMORY_AGENT_ID": "ai:alice"
      }
    }
  }
}
```

Also registered via the CLI to surface in `openclaw mcp list`:
```bash
openclaw mcp set memory '{"command":"ai-memory","args":["--db","/var/lib/ai-memory/a2a.db","mcp","--tier","semantic"]}'
```

### Hermes configuration (`~/.hermes/config.yaml`)

```yaml
mcp_servers:
  memory:
    command: ai-memory
    args:
      - "--db"
      - "/var/lib/ai-memory/a2a.db"
      - "mcp"
      - "--tier"
      - "semantic"
    env:
      AI_MEMORY_AGENT_ID: "ai:alice"
    enabled: true
```

Plus `/etc/ai-memory-a2a/hermes.env` (sourced by `drive_agent.sh`):
```bash
XAI_API_KEY=<from repo secret>
```

Hermes takes the LLM as invocation flags rather than config:
```bash
hermes chat -Q --provider xai --model grok-4-fast-non-reasoning -q "<prompt>"
```

### Why both have the same shape

Both frameworks express the same baseline through their own idiomatic config formats. Same substrate, same model, different reasoning scaffolds — **that's the A2A comparison.**

| Aspect | OpenClaw | Hermes |
|---|---|---|
| Config file | `~/.openclaw/openclaw.json` | `~/.hermes/config.yaml` |
| Config format | JSON | YAML |
| LLM location | In-file (`providers.xai`) | CLI flag + env file |
| MCP key spelling | `mcpServers` (camelCase) | `mcp_servers` (snake_case) |
| Headless invocation | `openclaw run --non-interactive -p "..."` | `hermes chat -Q --provider xai --model ... -q "..."` |

---

## 6. MCP server — ai-memory, and ONLY ai-memory

The agent's only MCP server is `ai-memory`, running as a stdio child process spawned per tool call. This is substrate isolation: any result is attributable to one product, not a mixture of tools.

Same binary, same DB file, same args on both frameworks:
- Command: `ai-memory`
- Args: `["--db", "/var/lib/ai-memory/a2a.db", "mcp", "--tier", "semantic"]`
- Env: `AI_MEMORY_AGENT_ID=<agent-id>`

`AI_MEMORY_AGENT_ID` enforces the Task 1.2 immutability contract from ai-memory-mcp: every memory write carries its writer's identity in `metadata.agent_id`, provably and inviolably.

---

## 7. Federation mesh — W=2 of N=4

Every node (all 4) runs `ai-memory serve` as a long-running daemon on `0.0.0.0:9077`:

```bash
ai-memory serve \
  --host 0.0.0.0 --port 9077 \
  --db /var/lib/ai-memory/a2a.db \
  --quorum-writes 2 \
  --quorum-peers "<comma-separated private-IP peer list (the other 3 nodes)>"
```

Quorum semantics: every `POST /api/v1/memories` must replicate to at least 2 peers before the 201 returns; the remaining peer catches up via post-quorum fanout (the PR #309 fix that made v0.6.0 shippable).

The `federation_live` baseline field confirms this daemon is responding on every node before scenarios run.

---

## 8. Baseline attestation schema

Every agent node emits `/etc/ai-memory-a2a/baseline.json` at the end of `setup_node.sh`. The workflow scp's these back, aggregates into `runs/<campaign-id>/a2a-baseline.json`, and gates `Run scenarios` on every node passing.

```json
{
  "agent_type": "openclaw",
  "agent_id": "ai:alice",
  "node_index": "1",
  "framework_version": "openclaw v2026.4.x",
  "ai_memory_version": "0.6.0",
  "peer_urls": "http://10.251.0.102:9077,http://10.251.0.103:9077,http://10.251.0.104:9077",

  "config_attestation": {
    "framework_is_authentic":           true,   // C1 — readlink on binary, no surrogate
    "mcp_server_ai_memory_registered":  true,   // C2 — jq against config file
    "llm_backend_is_xai_grok":          true,   // C3 — jq confirms base_url + model
    "llm_is_default_provider":          true,   // C4 — jq confirms defaultProvider
    "mcp_command_is_ai_memory":         true,   // C5 — jq confirms command string
    "agent_id_stamped":                 true,   // C6 — jq confirms env map
    "federation_live":                  true,   // C7 — curl /health on 127.0.0.1:9077
    "ufw_disabled":                     true    // C8 — ufw status grep inactive
  },

  "functional_probes": {
    "xai_grok_chat_reachable":          true,   // F1 — direct POST to api.x.ai/v1
    "xai_grok_sample_reply":            "READY",// F1 — actual response content
    "agent_mcp_ai_memory_canary":       true,   // F2 — agent-driven canary roundtrip
    "canary_uuid":                      "...",  // F2 — the UUID that was stored
    "canary_namespace":                 "_baseline_canary"
  },

  "baseline_pass": true                         // conjunction(C1..C8, F1, F2)
}
```

### 8.1 Invariants in full

| # | Field | Type | What it proves |
|---|---|---|---|
| C1 | `framework_is_authentic` | Static | Binary is upstream `openclaw/openclaw` or `NousResearch/hermes-agent`, not a symlink to another CLI |
| C2 | `mcp_server_ai_memory_registered` | Static | Config file has an MCP server named `memory` |
| C3 | `llm_backend_is_xai_grok` | Static | Config specifies xAI as provider with model `grok-4-fast-non-reasoning` |
| C4 | `llm_is_default_provider` | Static | xAI is the default provider (openclaw); hermes uses CLI flags |
| C5 | `mcp_command_is_ai_memory` | Static | MCP server command is literally `ai-memory` |
| C6 | `agent_id_stamped` | Static | `AI_MEMORY_AGENT_ID` env var matches `$AGENT_ID` on this node |
| C7 | `federation_live` | Functional (partial) | Local `ai-memory serve` responds on `127.0.0.1:9077/health` |
| C8 | `ufw_disabled` | Functional (partial) | `ufw status` returns "inactive" |
| F1 | `xai_grok_chat_reachable` | Functional | Direct POST to `api.x.ai/v1/chat/completions` returns non-empty content |
| F2 | `agent_mcp_ai_memory_canary` | Functional | Agent-driven end-to-end canary: prompt → tool selection → MCP stdio → ai-memory write → agent_id provenance stamp verified via HTTP |

### 8.2 Diagnostic separation

The split into config attestation vs. functional probes is intentional and diagnostic:

- **C1–C8 pass, F1 fails** → LLM layer is broken (bad API key, network, xAI outage). Config is right but the wire doesn't work.
- **C1–C8 pass, F1 passes, F2 fails** → Agent reasoning or MCP dispatch broken. xAI works, but the agent didn't select the right tool or the MCP stdio pipe failed.
- **F1 + F2 pass** → Full stack is live. Scenarios proceed.
- **Any C field false** → config is wrong; dashboard flags specific invariant so the human knows which file to fix.

---

## 9. Workflow enforcement

`.github/workflows/a2a-gate.yml` runs these steps in order:

1. **Terraform apply** — provisions 4 DO droplets in a dedicated VPC.
2. **SSH wait** — confirms all 4 droplets accept the repo's SSH key.
3. **Provision all 4 nodes** — scp `setup_node.sh` + `drive_agent.sh` to each, run setup_node.sh with the right env. `setup_node.sh` hard-fails (exit 3) if UFW is still active or baseline not satisfied.
4. **Collect + enforce BASELINE** — scp `/etc/ai-memory-a2a/baseline.json` from each of 3 agent nodes, aggregate into `phase-reports/a2a-baseline.json`, fail the job if any `baseline_pass` is false.
5. **Run scenarios** — `if: steps.baseline.outputs.baseline_ok == 'true'` — skipped entirely if baseline failed.
6. **Emit campaign.meta.json** — DO region, droplet size, node roster, workflow URL, dispatching actor.
7. **Aggregate campaign summary** + **Regenerate evidence HTML**.
8. **Commit campaign artefacts** to `runs/<campaign-id>/`.
9. **Tear down infrastructure** — always runs, even on failure.

The gate closes at step 4. No scenarios run without a clean baseline.

---

## 10. Repeatability recipe — single-node reproduction

To verify any node — or bring up a fifth peer — the same script is the single source of truth:

```bash
export NODE_INDEX=5                      # any unused index
export ROLE=agent                        # or memory-only
export AGENT_TYPE=openclaw               # or hermes
export AGENT_ID=ai:dave                  # any ai:-prefixed identifier
export PEER_URLS="http://<peer-1>:9077,http://<peer-2>:9077,http://<peer-3>:9077"
export AI_MEMORY_VERSION=0.6.0
export XAI_API_KEY=...                   # required on agent nodes

bash scripts/setup_node.sh

cat /etc/ai-memory-a2a/baseline.json     # must show "baseline_pass": true
```

That's it. The CI workflow runs exactly those steps per droplet — nothing special happens inside GitHub Actions. Any node provisioned by this script, anywhere, is baseline-equivalent to a campaign agent droplet.

---

## 11. Evidence trail

Every campaign leaves a full evidence trail in `runs/<campaign-id>/`:

| File | Source | Purpose |
|---|---|---|
| `a2a-baseline.json` | aggregator | Per-node baseline attestation union |
| `campaign.meta.json` | workflow | DO region, node IPs, actor, workflow URL |
| `a2a-summary.json` | aggregator | Scenario rollup, overall_pass |
| `scenario-N.json` | scenario scripts | Per-scenario verdict + reasons |
| `scenario-N.log` | scenario scripts | Full console trace (stderr) |
| `baselines/node-N.baseline.json` | per-node scp | The raw self-attestation from each node |
| `index.html` | `generate_run_html.sh` | Human-readable dashboard page |

The dashboard at https://alphaonedev.github.io/ai-memory-ai2ai-gate/runs/ renders a row per campaign with a `Baseline` column (✅ OK / ❌ VIOLATION / — pre-baseline) so you can see at a glance which runs were under the enforced gate.

---

## 12. Change control

Any change to this baseline is a semver-relevant harness change:

| Change | Semver |
|---|---|
| Adding a new invariant (e.g., require TLS on peer-to-peer) | **minor** bump |
| Tightening an existing invariant (e.g., model version change from `grok-4-fast-non-reasoning` to something else) | **minor** bump + explicit migration note |
| Relaxing or removing an invariant | **major** bump — requires narrative justification in `analysis/run-insights.json` |

Every change must:
1. Update `docs/baseline.md` (this file).
2. Update `scripts/setup_node.sh` to emit/check the new field.
3. Update the aggregator + dashboard renderer if the field is visible.
4. Add an entry to `analysis/run-insights.json` for the first run under the new baseline.

---

## 13. Implementation index

The spec's backing source files, for auditors and contributors:

| Concern | File |
|---|---|
| Authoritative spec (this doc) | `docs/baseline.md` |
| Per-node provisioning + attestation | `scripts/setup_node.sh` |
| Agent CLI surface | `scripts/drive_agent.sh` |
| Baseline aggregation step | `.github/workflows/a2a-gate.yml` → "Collect + enforce BASELINE" |
| Scenario gate | `.github/workflows/a2a-gate.yml` → "Run scenarios" (conditional on baseline) |
| Terraform infra | `terraform/main.tf` |
| Evidence HTML generator | `scripts/generate_run_html.sh` → `render_baseline()` |
| Runs landing dashboard | `.github/workflows/pages.yml` → "Build a landing page for runs/" |

---

## 14. Read next

- [Methodology](methodology.md) — why these invariants exist
- [Topology](topology.md) — the 4-node mesh in detail
- [Agents: OpenClaw](agents/openclaw.md) — framework-specific notes
- [Agents: Hermes](agents/hermes.md) — framework-specific notes
- [Campaign runs](runs/) — live evidence of baseline compliance per run
- [Reproducing](reproducing.md) — step-by-step operator guide
