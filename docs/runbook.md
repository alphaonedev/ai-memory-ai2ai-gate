# Operator runbook

Day-to-day operations for an operator running A2A gate campaigns. Every task below is a single named procedure, runnable in bounded time.

---

## 1. Dispatch a campaign

Per-group, matching the documented testbook defaults:

```sh
FORK=alphaonedev/ai-memory-ai2ai-gate   # or your fork

# IronClaw campaign (primary Rust agent — default since 2026-04-21)
gh workflow run a2a-gate.yml -R "$FORK" \
  -f ai_memory_git_ref=v0.6.1 \
  -f agent_group=ironclaw \
  -f campaign_id="a2a-ironclaw-v0.6.1-r$(date +%s)" \
  -f scenarios="1 1b 2 4 9 10 15 17"

# Hermes campaign
gh workflow run a2a-gate.yml -R "$FORK" \
  -f ai_memory_git_ref=v0.6.1 \
  -f agent_group=hermes \
  -f campaign_id="a2a-hermes-v0.6.1-r$(date +%s)" \
  -f scenarios="1 1b 2 4 9 10 15 17"
```

Both can run concurrently — they provision distinct VPCs (`10.251/24` ironclaw vs `10.252/24` hermes). Legacy openclaw dispatches remain accepted (`agent_group=openclaw`) but require a 16GB droplet slug override + DO account-tier upgrade — see [agents/ironclaw.md](agents/ironclaw.md) for the switch rationale.

---

## 2. Watch a running campaign

```sh
gh run list -R alphaonedev/ai-memory-ai2ai-gate --workflow=a2a-gate.yml --limit 3
gh run watch -R alphaonedev/ai-memory-ai2ai-gate <run-id>
```

Per-step progress:
```sh
# Get the job ID
JOB=$(gh run view <run-id> --repo alphaonedev/ai-memory-ai2ai-gate --json jobs --jq '.jobs[0].databaseId')
gh run view --job=$JOB --repo alphaonedev/ai-memory-ai2ai-gate
```

Live log of a specific failed step:
```sh
gh run view <run-id> --repo alphaonedev/ai-memory-ai2ai-gate --log-failed
```

---

## 3. Expected timing

| Step | OpenClaw | Hermes |
|---|---|---|
| Terraform apply | ~60s | ~60s |
| SSH wait | ~30s | ~30s |
| Provision (4 nodes) | ~5-10 min | ~12-20 min |
| Collect + enforce BASELINE | ~10s | ~10s |
| F3 peer A2A probe | ~12s | ~12s |
| Scenarios (8 default) | ~10-15 min | ~10-15 min |
| Aggregate + HTML + redact + commit + destroy | ~90s | ~90s |
| **Total** | **15-25 min** | **25-40 min** |

If any step exceeds 1.5× its expected duration, investigate — either upstream (xAI, npm, GitHub, DO) has issues OR there's a harness regression.

---

## 4. Triage a baseline violation

If `baseline_ok=false` at step 6 of the workflow:

1. `git pull` to get the committed `runs/<campaign-id>/a2a-baseline.json`
2. `jq '.per_node[] | {node_index, baseline_pass, config_attestation, functional_probes, negative_invariants}' runs/<campaign-id>/a2a-baseline.json`
3. Find the first field that is `false` for each node. That's the failing invariant.
4. Consult the violation table:

| Field (false) | Class | Likely cause | First fix to try |
|---|---|---|---|
| `framework_is_authentic` | C1 | Binary is a symlink to another CLI | Check `readlink -f $(which openclaw)` on the droplet; re-run install |
| `mcp_server_ai_memory_registered` | C2 | Config file malformed | Inspect `~/.openclaw/openclaw.json` or `~/.hermes/config.yaml` |
| `llm_backend_is_xai_grok` | C3 | Model string wrong in config | Check `default_model` field; spec says `grok-4-fast-non-reasoning` |
| `llm_is_default_provider` | C4 | `defaultProvider` != `xai` | OpenClaw config only |
| `mcp_command_is_ai_memory` | C5 | MCP server `command` not `ai-memory` | Config drift; re-run setup_node.sh |
| `agent_id_stamped` | C6 | `AI_MEMORY_AGENT_ID` env not in MCP config | Check `AGENT_ID` was exported before setup_node.sh |
| `federation_live` | C7 | Local `ai-memory serve` crashed or port 9077 unreachable | `/var/log/ai-memory-serve.log` on the droplet; UFW status |
| `ufw_disabled` | C8 | UFW re-enabled itself | `ufw status verbose`; check for re-enable scripts |
| `iptables_flushed` | C9 | Residual DROP rules | `iptables -L -v` |
| `dead_man_switch_scheduled` | C10 | `shutdown -P +480` not running | `ps aux \| grep shutdown` |
| `xai_grok_chat_reachable` (F1) | Functional | xAI key invalid / out of credit / network | `curl -v https://api.x.ai/v1/models -H "Authorization: Bearer $XAI_API_KEY"` from droplet |
| `substrate_http_canary_f2a` (F2a) | Functional | Local serve HTTP path broken — unusual | Check ai-memory serve log; spec bug if this fails |
| `agent_mcp_canary_f2b` (F2b) | Functional (non-gating) | Agent didn't invoke tool correctly OR #318 substrate bug | See `/tmp/canary-<agent_type>.log` for agent response; expected to fail until #318 ships |
| `a2a_protocol_off` | Negative | Config file lost the explicit disable | Re-run setup_node.sh |
| `tool_allowlist_is_memory_only` | Negative | Non-`memory_*` tool leaked into allowlist | Check config file; re-run |

---

## 5. Triage F3 failure

If baseline passes but F3 fails:

1. `jq . runs/<campaign-id>/f3-peer-a2a.json`
2. Note the `canary_uuid` and `writer_agent`
3. F3 writes to node-1 and verifies on nodes 2, 3, 4. If F3 fails, federation fanout is broken from node-1 — escalate to ai-memory-mcp team.

---

## 6. Triage a hung campaign

A campaign stalled at the same step for >15 min beyond expected:

1. Check which step via `gh run view --job=$JOB`
2. If "Provision all 4 nodes": something in `setup_node.sh` is hung. Every long-running subprocess has a timeout (see [architecture.md §4](architecture.md#4-the-gate-sequence)); worst-case a 600s install timeout + 60s agent canary + 15 min baseline collection = ~25 min ceiling per run.
3. If truly stuck past ceiling: `gh run cancel <run-id>` to stop DO spend, then inspect the Actions log for the last `[setup-node-N HH:MM:SS]` timestamp emitted.

**Historical incidents** (see [incidents.md](incidents.md)):
- r11 stalled 37+ min on Provision → added timeouts to every subprocess in commit `6face55`. Should not recur.

---

## 7. Cancel a campaign

```sh
gh run cancel <run-id> --repo alphaonedev/ai-memory-ai2ai-gate
```

`terraform destroy` runs automatically in the `if: always()` teardown step, so cancellation is safe — no orphan droplets. If for some reason destroy fails (DO API outage), the 8h dead-man switch on every droplet is the backstop.

Manual teardown (only if needed):
```sh
cd terraform
terraform destroy -auto-approve \
  -var "campaign_id=<id>" \
  -var "do_token=$DO_TOKEN" \
  -var "ssh_key_fingerprint=$SSH_FP"
```

---

## 8. Inspect evidence locally

```sh
git pull
cd runs/<campaign-id>

# Overall campaign verdict
jq '.overall_pass, .reasons' a2a-summary.json

# Baseline per-node view
jq '[.per_node[] | {node: .node_index, pass: .baseline_pass}]' a2a-baseline.json

# Per-scenario verdict grid
for f in scenario-*.json; do
  echo "=== $f ==="
  jq '{scenario, pass, reasons}' "$f"
done

# Open the human-readable page
open index.html     # macOS
xdg-open index.html # Linux
```

Or browse on Pages: `https://alphaonedev.github.io/ai-memory-ai2ai-gate/evidence/<campaign-id>/`

---

## 9. Add a new scenario

1. Write `scripts/scenarios/<N>_<slug>.sh` following the pattern of `15_read_your_writes.sh` (simplest).
2. Emit JSON on stdout + logs on stderr. Final JSON must match the contract in [testbook.md §4.4](testbook.md#44-json-report-schema).
3. `chmod +x scripts/scenarios/<N>_<slug>.sh`.
4. Add to the default dispatch scenarios in `.github/workflows/a2a-gate.yml` OR pass via `-f scenarios="..."` at dispatch.
5. Add a full test plan entry to `docs/testbook.md` §4 (Objective / Pre-conditions / Procedure / Pass criteria / Failure modes / Evidence).
6. Update the coverage matrix in [testbook.md §3](testbook.md#3-coverage-by-ai-memory-primitive).
7. Bump the test book version (minor or major per §7 change-control).
8. Commit + push + dispatch.

---

## 10. Tighten a baseline invariant

1. Update the invariant spec in `docs/baseline.md` §8.1.
2. Add the check logic to `scripts/setup_node.sh` (follow the `baseline_check` / `jq -e` patterns).
3. Add the field to the jq emit block.
4. Add the field to the `baseline_pass` conjunction.
5. Update `scripts/generate_run_html.sh` `render_baseline()` table to include the new column.
6. Bump baseline spec version in `docs/baseline.md` §0 changelog.
7. Commit. The pages workflow regenerates every run's HTML on next deploy so historical runs retroactively render with a `—` in the new column.

---

## 11. Rotate credentials

```sh
# xAI key
gh secret set XAI_API_KEY -R alphaonedev/ai-memory-ai2ai-gate

# DO token
gh secret set DIGITALOCEAN_TOKEN -R alphaonedev/ai-memory-ai2ai-gate

# SSH key (after registering new public half with DO)
gh secret set DIGITALOCEAN_SSH_PRIVATE_KEY -R alphaonedev/ai-memory-ai2ai-gate < ~/.ssh/id_ed25519
gh secret set DIGITALOCEAN_SSH_KEY_FINGERPRINT -R alphaonedev/ai-memory-ai2ai-gate
```

The redaction pass (see [baseline.md §9b](baseline.md#9b-security--secrets--pii-handling)) catches any pre-rotation secret value that might be in historical logs: it regex-masks `xai-[A-Za-z0-9_-]{20,}` patterns even when the specific old key isn't known to the workflow. So rotated-key safety is automatic for XAI keys.

---

## 12. Investigate a past run

```sh
# Every artifact is in git history
git log -- runs/a2a-openclaw-v0.6.0-r7/
git show <commit-sha> -- runs/a2a-openclaw-v0.6.0-r7/a2a-summary.json
```

Every commit includes the campaign ID in the message. The actor + workflow URL are in the run's `campaign.meta.json`.
