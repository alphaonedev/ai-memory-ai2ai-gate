# Topology

This page is the authoritative description of the 4-node
infrastructure shape every A2A campaign provisions. If the
Terraform module and this page disagree, **Terraform wins** — file
an issue against the discrepancy.

## Physical layout

```
GitHub Actions runner (ubuntu-24.04, ephemeral)
        │
        │  SSH (public IPs, port 22)
        ▼
 ┌──────────────────────────────────────────────────────┐
 │        DigitalOcean VPC 10.260.0.0/24 (nyc3)         │
 │                                                      │
 │  ┌────────────┐  ┌────────────┐  ┌────────────┐      │
 │  │   node-1   │  │   node-2   │  │   node-3   │      │
 │  │ s-2vcpu-4gb│  │ s-2vcpu-4gb│  │ s-2vcpu-4gb│      │
 │  │ OpenClaw   │  │  Hermes    │  │ OpenClaw   │      │
 │  │ ai:alice   │  │  ai:bob    │  │ai:charlie  │      │
 │  └─────┬──────┘  └─────┬──────┘  └─────┬──────┘      │
 │        │               │               │             │
 │        └───────────────┼───────────────┘             │
 │                        │                             │
 │                        │ MCP over stdio-to-local    │
 │                        │ + HTTP 9077 to node-4      │
 │                        ▼                             │
 │              ┌──────────────────┐                    │
 │              │     node-4       │                    │
 │              │  s-2vcpu-4gb     │                    │
 │              │  ai-memory serve │                    │
 │              │  --mcp --http    │                    │
 │              │  port 9077       │                    │
 │              └──────────────────┘                    │
 │                                                      │
 └──────────────────────────────────────────────────────┘
```

## Droplet roles

| Droplet | Public IP | Private IP | OS | Size | Role |
|---|---|---|---|---|---|
| `node-1` | yes (SSH only) | `10.260.0.11` | Ubuntu 24.04 | `s-2vcpu-4gb` | OpenClaw agent host (`ai:alice`) |
| `node-2` | yes (SSH only) | `10.260.0.12` | Ubuntu 24.04 | `s-2vcpu-4gb` | Hermes agent host (`ai:bob`) |
| `node-3` | yes (SSH only) | `10.260.0.13` | Ubuntu 24.04 | `s-2vcpu-4gb` | OpenClaw agent host (`ai:charlie`) |
| `node-4` | yes (SSH only) | `10.260.0.14` | Ubuntu 24.04 | `s-2vcpu-4gb` | `ai-memory serve` authoritative |

The private CIDR `10.260.0.0/24` is distinct from the ship-gate's
`10.250.0.0/24` so both campaigns can run concurrently against the
same DigitalOcean account without VPC conflicts.

## Why 4 nodes and not 3

The ship-gate campaign uses 3 peer nodes because its goal is to
validate **quorum replication** (W=2 of N=3). The A2A gate's goal
is different — it validates **how agents use a shared memory
store**. That needs:

- ≥ 2 different agent hosts to demonstrate A2A handoff.
- ≥ 3 different `agent_id` values to demonstrate contradiction
  surfacing to an uninvolved third party.
- 1 dedicated authoritative store so agent-side failures don't
  muddy the memory-side measurement.

Three agent hosts + one authoritative store = 4 droplets. Adding
more agents is a future variant; not required for the default
pass.

## Network + firewall

- **DO Cloud Firewall** allows:
  - SSH (22) from the GitHub Actions runner's ephemeral egress
  - HTTP 9077 inside the VPC for MCP + HTTP API traffic between
    agents (nodes 1-3) and the authoritative store (node-4)
  - No inbound public traffic to port 9077 — all A2A traffic is
    VPC-private
- **Outbound** — agents need internet to pull container images
  / Python deps during setup; firewall leaves egress open during
  provisioning and tightens it before scenarios start.

## Authentication shape

- **Operator → droplets**: SSH with the provisioner's ed25519 key
  (same custody model as ship-gate).
- **Agent → ai-memory (node-4)**: defaults to `X-API-Key` header
  auth inside the VPC. mTLS option available; off by default for
  A2A campaigns because cert rotation would dominate setup time.
- **Agent identity**: every memory carries `metadata.agent_id`
  set to one of `ai:alice` / `ai:bob` / `ai:charlie`. Immutability
  is an invariant the scenarios check (see
  [scenario 1](scenarios/1-write-read.md)).

## Lifecycle

1. GitHub Actions dispatches `a2a-gate.yml`.
2. Terraform provisions the 4-node VPC.
3. Node-4 gets `ai-memory serve` provisioned first; scripts wait
   for health before proceeding.
4. Nodes 1-3 get agent frameworks provisioned (OpenClaw or Hermes)
   with MCP client configured to point at node-4's private IP.
5. Scenarios 1-8 run in sequence, each emitting a JSON report.
6. Aggregator produces `a2a-summary.json`.
7. `terraform destroy` tears everything down regardless of phase
   outcome.
8. Dead-man switch backstop: every droplet has a `shutdown -P +480`
   at provision so worst-case spend is bounded to 8 hours.

## Related

- [Security](security.md) — TLS, mTLS, key custody details.
- [Reproducing](reproducing.md) — how to run your own A2A gate
  campaign on your own DigitalOcean account.
