# Reproducing the baseline — operator playbook

Step-by-step recipe to run this exact baseline anywhere. Two paths:
**A** — dispatch a full campaign on DigitalOcean via GitHub Actions
(the intended operator path). **B** — provision a single baseline
node locally for debugging or verification.

The authoritative spec is [docs/baseline.md](baseline.md). This file
is the repeatable operational recipe. If the two disagree, the spec
file wins; please file an issue.

---

## Path A — full campaign on DigitalOcean (15-25 minutes)

### A.1 Prerequisites

- A DigitalOcean account with available resources for 4 × `s-2vcpu-4gb` droplets in your chosen region
- A GitHub fork of [alphaonedev/ai-memory-ai2ai-gate](https://github.com/alphaonedev/ai-memory-ai2ai-gate) (or direct access if you're an alphaonedev operator)
- An xAI API key with access to `grok-4-fast-non-reasoning` (get one at [console.x.ai](https://console.x.ai/))
- `gh` CLI authenticated to your GitHub account
- An ed25519 SSH keypair whose **public** key is uploaded to DO and whose fingerprint is recorded

### A.2 Configure repository secrets

```sh
FORK=your-gh-user/ai-memory-ai2ai-gate    # or alphaonedev/ai-memory-ai2ai-gate

# DigitalOcean
gh secret set DIGITALOCEAN_TOKEN                -R "$FORK"  # paste DO API token
gh secret set DIGITALOCEAN_SSH_PRIVATE_KEY      -R "$FORK" < ~/.ssh/id_ed25519
gh secret set DIGITALOCEAN_SSH_KEY_FINGERPRINT  -R "$FORK"  # paste the DO-registered fingerprint

# xAI
gh secret set XAI_API_KEY                       -R "$FORK"  # paste xAI key
```

**None of these values touch the repository.** They live in GitHub's encrypted secret store. The workflow consumes them at dispatch time. The commit-pass redaction step blocks any that leak into artefacts — see [baseline.md §9b](baseline.md#9b-security--secrets--pii-handling).

### A.3 Dispatch a campaign

```sh
# One dispatch per agent group. Both can run in parallel — distinct
# VPC CIDRs, distinct concurrency groups.

gh workflow run a2a-gate.yml -R "$FORK" \
  -f ai_memory_git_ref=v0.6.0 \
  -f agent_group=openclaw \
  -f campaign_id=a2a-openclaw-v0.6.0-rN \
  -f scenarios="1 1b"

gh workflow run a2a-gate.yml -R "$FORK" \
  -f ai_memory_git_ref=v0.6.0 \
  -f agent_group=hermes \
  -f campaign_id=a2a-hermes-v0.6.0-rN \
  -f scenarios="1 1b"
```

### A.4 Watch the baseline gate + scenarios

```sh
gh run list -R "$FORK" --workflow=a2a-gate.yml --limit 2
gh run watch -R "$FORK" <run-id>
```

Typical timing:
- Terraform apply: ~60s
- SSH wait + provision: ~8-12 min (openclaw) / ~15-25 min (hermes — heavier Python install)
- Per-node functional probes F1 + F2 (xAI chat + agent-driven MCP canary): part of provision, ~6s each
- **Baseline enforcement (per-node attestation): ~5s** (any node failing = scenarios skipped, job fails at that step)
- **F3 peer A2A probe: ~12s** (write + 8s settle + 3-peer verify)
- Scenarios: ~90s each
- Redaction pass: ~1s (fails build if any secret value leaks to artefacts)
- Terraform destroy: ~30s (runs via `if: always()`)

### A.5 Find the evidence

```sh
git pull
ls runs/a2a-*-v0.6.0-rN/
#   a2a-baseline.json          ← per-node C1-C8 + F1 + F2 + negative invariants
#   f3-peer-a2a.json           ← F3 cross-node peer A2A probe verdict
#   a2a-summary.json           ← scenario rollup + overall_pass
#   baselines/node-N.json      ← raw attestation from each node
#   campaign.meta.json         ← DO region, node IPs, actor, workflow URL
#   scenario-1.json            ← scenario 1 (MCP-native) verdict
#   scenario-1.log             ← scenario 1 full console trace (redacted)
#   scenario-1b.json           ← scenario 1b (serve-HTTP) verdict
#   scenario-1b.log            ← scenario 1b full console trace (redacted)
#   index.html                 ← human-readable dashboard page
```

Dashboard (after the pages workflow completes):
https://alphaonedev.github.io/ai-memory-ai2ai-gate/evidence/a2a-openclaw-v0.6.0-rN/

---

## Path B — single-node baseline verification

For operators who want to verify the baseline recipe on a single
machine before dispatching a full campaign, or who want to debug a
baseline violation without paying DO costs.

### B.1 Prerequisites

- Ubuntu 24.04 LTS host (local VM, dedicated box, single DO droplet)
- Root or sudo
- Outbound network access to `api.x.ai`, `github.com`, `openclaw.ai`, `raw.githubusercontent.com`
- An xAI API key

### B.2 Clone the repo

```sh
git clone https://github.com/alphaonedev/ai-memory-ai2ai-gate.git
cd ai-memory-ai2ai-gate
```

### B.3 Run setup_node.sh with baseline env

```sh
export NODE_INDEX=5
export ROLE=agent
export AGENT_TYPE=openclaw              # or hermes
export AGENT_ID=ai:dave                 # any ai:-prefixed id
export PEER_URLS="http://<peer-1>:9077,http://<peer-2>:9077,http://<peer-3>:9077"
export AI_MEMORY_VERSION=0.6.0
export XAI_API_KEY=<your-xAI-key>

bash scripts/setup_node.sh
```

The script will:

1. Install base packages (curl, jq, python3, nodejs, npm, sqlite3)
2. **Disable UFW** — belt-and-suspenders (`ufw --force reset && ufw --force disable`), verify, exit 3 on failure
3. Flush iptables to ACCEPT
4. Set an 8-hour `shutdown -P +480` dead-man switch (skip on local machines)
5. Install `ai-memory` v0.6.0 binary
6. Start `ai-memory serve` in federation mode on `0.0.0.0:9077`
7. Install the agent framework (authentic upstream — `openclaw/openclaw` OR `NousResearch/hermes-agent`)
8. Write framework config with full baseline lock-down — xAI Grok as the only LLM, ai-memory as the only MCP server, every alternative A2A channel disabled
9. **PROBE F1** — xAI Grok reachability + auth (direct `POST /v1/chat/completions`, expects non-empty content)
10. **PROBE F2** — end-to-end agent → MCP → ai-memory canary (agent invokes `memory_store`, probe verifies via local HTTP + `metadata.agent_id`)
11. Emit `/etc/ai-memory-a2a/baseline.json` with config_attestation + negative_invariants + functional_probes + baseline_pass
12. Exit 2 if `baseline_pass` is false

**Note:** `setup_node.sh` covers the per-node side of the baseline (C1–C8 + F1 + F2). The workflow-level probe **F3 — peer A2A via shared memory** requires coordination across multiple nodes and runs from the GitHub Actions runner in the `a2a-gate.yml` step named "Functional probe F3". On a single local host you can skip F3, but no campaign scenario will ever run without F3 green.

### B.4 Verify

```sh
cat /etc/ai-memory-a2a/baseline.json | jq '.baseline_pass'
# must print: true
```

If `true` — your node is baseline-equivalent to a campaign agent droplet. You can use it as a fourth peer for a live federation, or as a debug environment to iterate on scenario scripts.

If `false` — inspect:
```sh
cat /etc/ai-memory-a2a/baseline.json | jq '.config_attestation, .negative_invariants, .functional_probes'
```
to find the specific failing field.

---

## Common baseline violations + fixes

| Symptom | Field | Likely cause | Fix |
|---|---|---|---|
| `framework_is_authentic: false` | C1 | Binary is a symlink to another CLI | Re-install upstream binary; check `readlink -f $(which openclaw)` |
| `llm_backend_is_xai_grok: false` | C3 | Wrong `base_url` or `default_model` in config | Re-run setup_node.sh with correct `XAI_API_KEY` |
| `agent_id_stamped: false` | C6 | `AI_MEMORY_AGENT_ID` env missing in MCP env block | Check `AGENT_ID` was exported before setup_node.sh |
| `federation_live: false` | C7 | `ai-memory serve` crashed or port 9077 blocked | Check `/var/log/ai-memory-serve.log`; verify UFW off |
| `ufw_disabled: false` | C8 | UFW re-enabled itself after reset | Ship-gate r21/r23 lesson; `ufw status verbose` |
| `xai_grok_chat_reachable: false` | F1 | Key invalid, out of credit, or outbound HTTPS blocked | `curl -v https://api.x.ai/v1/models -H "Authorization: Bearer $XAI_API_KEY"` |
| `agent_mcp_ai_memory_canary: false` | F2 | MCP dispatch broken, tool misselection, agent reasoning failure | Check `/tmp/canary-$AGENT_TYPE.log` for the agent's actual output |
| `a2a_protocol_off: false` | Negative | Config file lost the explicit disable | Re-run setup_node.sh; verify with `jq '.agentToAgent'` |
| `tool_allowlist_is_memory_only: false` | Negative | A non-`memory_*` tool leaked into allowlist | Edit config back to spec; see [baseline.md §6b.2](baseline.md) |

---

## Cost envelope

| Path | Cost | Time |
|---|---|---|
| Path A full campaign (per group) | ~$0.20-0.30 per clean run | 15-25 min wall |
| Path B single-node on DO | ~$0.02/hour | 5-10 min |
| Baseline-violation triage | Campaign halts before scenarios, ~1 min of droplet time wasted | 1-3 min |
| Dead-man switch worst case | ~$1.30 per droplet × 4 = ~$5.20 | 8 hours |

---

## Disputing a finding

If your fork's campaign passes and this repo's fails (or vice versa), open an issue citing:

- Both campaign IDs
- The specific scenario that disagrees
- The `ai_memory_git_ref` each ran against
- Any infra differences (region, droplet size, DO account tier)
- **Both `a2a-baseline.json` files** — if the negative_invariants differ, the gate wasn't running the same test

Cross-fork comparison is the point. An unreproducible result is a bug in the harness, and we want to find it.

---

## Change control

If you change ANY baseline configuration during a campaign's life, follow the semver rules in [baseline.md §12](baseline.md#12-change-control):

- Adding a new invariant → **minor** bump
- Tightening an existing invariant → **minor** bump with migration note
- Relaxing or removing → **major** bump with `analysis/run-insights.json` narrative entry

Every change must update:
1. `docs/baseline.md` (authoritative spec)
2. `scripts/setup_node.sh` (emit/check)
3. The aggregator + dashboard renderer (if visible)
4. `analysis/run-insights.json` for the first run under the new baseline
