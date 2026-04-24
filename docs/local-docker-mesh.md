# Local Docker mesh

Reproducible 4-node OpenClaw + ai-memory federation mesh on a single
workstation. Bypasses DigitalOcean entirely; every run is peer-reviewable,
re-testable, and reproducible from the scripts in this repository.

**Status (2026-04-24): first-class cell** alongside the DO IronClaw and
Hermes matrix. Certification criterion — three consecutive full-testbook
`overall_pass=true` runs — is satisfied for openclaw via
`runs/a2a-openclaw-v0.6.2-local-docker-{r1,r2,r3}/` on `release/v0.6.2 @ 3e018d6`.

## Why this exists

OpenClaw's install-time memory demand (>8 GB) historically forced the
harness onto DO General Purpose tier droplets, which require a paid
account-tier upgrade. The local Docker mesh removes that barrier:

- Each openclaw container gets **16 GB** of memory (`mem_limit: 16g` in compose)
- The memory-only aggregator gets 4 GB
- Total budget 52 GB — fits on a workstation with ~64 GB+ of RAM
- Provisioning wall-clock: ~15 sec vs ~5-8 min for the DO Terraform flow
- Exactly the same scenario harness + `ai-memory` release binary + testbook

## Host prerequisites

| Requirement | Minimum | Verified on |
|---|---|---|
| Linux (any distro with Docker) | 4.x kernel, user namespaces | Pop!_OS 24.04 LTS |
| RAM | 64 GB (3×16 GB openclaw + 4 GB aggregator + OS headroom) | 93 GB host |
| CPU | 8 cores | 14 cores |
| Disk | 25 GB free (images: 10 GB, databases + logs: ~1 GB / round) | 596 GB free |
| Docker Engine | 20.10+ (29.x tested) | 29.1.3 |
| Docker Compose v2 | 2.20+ | 2.40.3 |
| `nft` / `nftables` | any recent | 1.1.2 |
| xAI API key | required for openclaw → Grok | — |

Install Docker on Ubuntu-derived hosts:
```
apt install docker.io docker-compose-v2
```

## Build

```
cd docker/
# Stage the ai-memory release binary (from the ai-memory-mcp repo at
# release/v0.6.2 @ 3e018d6 or later):
mkdir -p bin
cp /path/to/ai-memory-mcp/target/release/ai-memory bin/

# Build the base image (ubuntu:24.04 + ai-memory + MiniLM pre-baked):
docker build --network host -t ai-memory-base:local -f Dockerfile.base .

# Build the openclaw image (base + openclaw install.sh + NodeSource Node.js v22):
docker build --network host -t ai-memory-openclaw:local \
  --build-arg AI_MEMORY_BASE=ai-memory-base:local \
  -f Dockerfile.openclaw .
```

> **Why `--network host` at build time?** Docker's default bridge
> MASQUERADE is silently dropped by hosts running Tailscale + a
> restrictive `inet filter forward` chain (e.g. the CCC Gateway
> topology). `--network host` uses the host netns directly for the
> build-time `apt-get update` + `curl | bash -s openclaw install`.
> Not needed at runtime once `host-nft-docker-forward.sh` is applied
> (see next section).

## Host firewall workaround (CCC Gateway / Tailscale hosts only)

Hosts that run Tailscale AND a custom `inet filter forward policy drop`
ruleset (for example a Family Safety / CCC Gateway configuration) drop
Docker user-defined bridge egress before it reaches the external NIC.
Symptom: `curl` from a container hangs on connect; `tcpdump` shows SYN
on the bridge but zero bytes on the external interface.

```
# Idempotent. Adds four nft rules allowing Docker subnets to forward.
# NOT persistent across reboot; re-run after boot.
sudo bash docker/host-nft-docker-forward.sh
```

Rules added:
```
ip saddr 10.88.0.0/16   accept   # docker-compose user-defined bridge
ip saddr 172.17.0.0/16  accept   # docker0 default bridge
ip daddr 10.88.0.0/16   ct state new accept
ip daddr 172.17.0.0/16  ct state new accept
```

## Bring up the mesh

```
export XAI_API_KEY=sk-...   # or source /path/to/.env
docker compose -f docker-compose.openclaw.yml up -d

# Wait for 4/4 healthy:
docker compose -f docker-compose.openclaw.yml ps
```

Expected layout:

| Container | Role | agent_id | Bridge IP | Memory |
|---|---|---|---|---|
| `a2a-node-1` | agent | `ai:alice` | 10.88.1.11 | 16 GB |
| `a2a-node-2` | agent | `ai:bob` | 10.88.1.12 | 16 GB |
| `a2a-node-3` | agent | `ai:charlie` | 10.88.1.13 | 16 GB |
| `a2a-node-4` | memory-only aggregator | — | 10.88.1.14 | 4 GB |

## Smoke test

```
bash docker/smoke.sh
```

Expected output ends with `[smoke …] SMOKE PASS`. The smoke script
verifies cross-node write-read on 3 namespace pairs and a 500-row bulk
fanout (S40-style).

## Run the full testbook

```
cd docker/
bash run-testbook.sh a2a-openclaw-v0.6.2-local-docker-r1
```

Round produces `runs/a2a-openclaw-v0.6.2-local-docker-r1/` with:

- `scenario-<id>.json` — one per scenario, raw JSON report
- `scenario-<id>.log` — stderr trace, human-readable
- `a2a-summary.json` — aggregate (same shape as DO runs)
- `campaign.meta.json` — infra + provenance
- `index.html` — auto-generated Pages evidence

To satisfy the 3-of-3 certification bar:
```
bash run-testbook.sh a2a-openclaw-v0.6.2-local-docker-r1
bash run-testbook.sh a2a-openclaw-v0.6.2-local-docker-r2
bash run-testbook.sh a2a-openclaw-v0.6.2-local-docker-r3
```

DO NOT tear the mesh down between rounds — the compose stack stays
up; runs just replay against the live mesh. Per-round artifacts
remain independent under `runs/`.

## What gets run

Same testbook v3.0.0 always-on set as the DO workflow:

```
1 1b 2 4 5 6 9 10 11 12 13 14 15 16 17 18 22 23 24 25 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42
```

35 scenarios. `tls`/`mtls` modes are deferred to a later iteration
(entrypoint.sh rejects non-`off` until the ephemeral CA + cert
volume-mount design lands).

## Provenance in each run

Every `a2a-summary.json` committed under `runs/` captures:

```json
{
  "campaign_id": "a2a-openclaw-v0.6.2-local-docker-rN",
  "ai_memory_git_ref": "release/v0.6.2",
  "meta": {
    "topology": "local-docker",
    "infra": {
      "provider": "local-docker",
      "host": "<hostname>",
      "mesh_topology": "4-node bridge (3 openclaw agents + 1 memory-only aggregator)",
      "nodes": [...]
    },
    "timing": { "start": "...", "end": "..." },
    "ci": { "runner": "local-docker", "operator": "..." }
  }
}
```

Peer reviewers can reconstruct the entire run from:

1. This document + the host pre-req list above
2. `docker/Dockerfile.base` + `docker/Dockerfile.openclaw` (image recipe)
3. `docker/entrypoint.sh` (container startup contract)
4. `docker/docker-compose.openclaw.yml` (topology + memory limits)
5. `docker/run-testbook.sh` (runner + aggregator)
6. `scripts/a2a_harness.py` with `TOPOLOGY=local-docker` (harness)
7. `scripts/scenarios/*.py` (scenarios — identical to DO)
8. `release/v0.6.2 @ 3e018d6` for the `ai-memory` binary

## Tear down

```
docker compose -f docker-compose.openclaw.yml down -v   # drops volumes
docker image prune -f   # optional — free disk
```

Note the `nft` rules installed by `host-nft-docker-forward.sh` persist
until the next reboot or explicit `nft delete rule` — by design so
back-to-back test rounds don't re-prompt.

## Known gaps (tracked)

- TLS / mTLS not yet supported in local-docker topology (issue #54)
- `a2a-gate.yml` workflow doesn't dispatch local-docker runs — they
  are local-only until a self-hosted runner with 64 GB+ RAM is in scope
- Scenario parallelism is sequential (matches DO) — a parallel mode
  is feasible but would be a separate validation exercise
