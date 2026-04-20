# Security

This document describes the security posture of the A2A gate
infrastructure. The shape mirrors the ai-memory-ship-gate's
security model (same operator, same audit posture, same
minimum-privilege stance) with adjustments for the 4-node agent
topology.

## Threat model

The A2A gate is ephemeral test infrastructure. It spins up,
exercises scenarios, tears down. Threats we defend against:

- **Credential leakage.** DO API tokens, SSH private keys, and
  any future agent-framework API keys (OpenAI, Anthropic) never
  appear in logs or artifacts.
- **Data exfiltration.** Memories written during the campaign are
  test data — never customer data. But the SHAPE of the test data
  must not include anything sensitive by accident (no real user
  ids, no production namespaces).
- **Cross-tenant contamination.** The VPC CIDR (`10.260.0.0/24`)
  is distinct from the ship-gate's (`10.250.0.0/24`) so
  concurrent campaigns cannot bridge.
- **Runaway spend.** See the dead-man switch discussion.

## Out of scope

- Adversarial agent behaviour (byzantine memory writes, scope
  escalation attempts by agents themselves) — a future campaign,
  not this one.
- Nation-state-level traffic analysis or side-channel attacks.
- Supply-chain integrity of the OpenClaw / Hermes agent binaries
  — we trust the operator to pin versions; an agent-side
  supply-chain attack is the operator's problem, not ai-memory's.

## Credentials + secrets

| Secret | Scope | Storage | Lifetime |
|---|---|---|---|
| `DIGITALOCEAN_TOKEN` | Terraform + DO API | GitHub Secrets | operator-managed rotation |
| `DIGITALOCEAN_SSH_PRIVATE_KEY` | runner → droplets | GitHub Secrets (ephemeral file in `~/.ssh/` at job time) | rotated on compromise |
| `DIGITALOCEAN_SSH_KEY_FINGERPRINT` | Terraform droplet authorized_keys | GitHub Secrets | matches the private key |
| ai-memory `X-API-Key` (if set) | agent → node-4 | per-campaign random, never leaves the runner/droplets | destroyed with droplets |
| Agent-framework API keys | per-agent | passed via droplet env vars from runner secrets | never logged |

Rotation policy: if any secret is suspected compromised, revoke
first, then rotate. DO tokens are scoped to a dedicated sub-
account; SSH keys are generated for the ship-gate + A2A use case
and not reused elsewhere.

## TLS / mTLS

- **Between agents and node-4 (ai-memory serve)** — HTTP is the
  default for A2A campaigns. VPC traffic is private; the firewall
  rule only permits 9077 inside the VPC.
- **Operators running A2A against their own production ai-memory
  fleet** should enable `--tls-cert` / `--tls-key` on node-4 and
  configure agents to present client certs via the `--client-cert`
  / `--client-key` pattern. The default-off posture for the public
  A2A gate is a test-infra simplification, not a production
  recommendation.
- **Over-the-internet A2A traffic** is out of scope for this gate.
  If you're running agents that communicate across cloud
  boundaries, TLS+mTLS is required.

## Dead-man switch

Every droplet runs `shutdown -P +480` at provision time — 8
hours from boot, the droplet powers itself off. DigitalOcean does
not bill for powered-off droplets beyond a small residual. This
caps worst-case spend regardless of workflow state.

The campaign workflow runs `terraform destroy -auto-approve` as
its penultimate step with `if: always()`, so a clean teardown runs
on success, failure, or cancellation. The dead-man switch is the
backstop for the case where the workflow itself is cancelled
before teardown runs.

## Audit trail

- Every scenario's JSON report is committed to `runs/<campaign_id>/`
  with the workflow's OIDC attestation of authorship.
- The `ai_memory_git_ref` and `campaign_id` are in every artifact,
  so provenance from "test result" back to "which commit of ai-
  memory was tested" is direct.
- The `a2a-summary.json` carries the workflow run URL and
  completion timestamp.

## Peer review

Every campaign is reproducible by any DO account holder per
[Reproducing](reproducing.md). If a customer, partner, or
regulator wants to verify a published A2A gate claim, they can
fork the repo, point at their own DO account, and reproduce the
exact run. Disagreements become issues.

## Related

- [ai-memory-ship-gate security](https://alphaonedev.github.io/ai-memory-ship-gate/security/)
  — the prior-stage gate's security posture. This gate inherits
  the same patterns.
- ai-memory-mcp's `docs/SECURITY.md` — product-level security
  contract.
