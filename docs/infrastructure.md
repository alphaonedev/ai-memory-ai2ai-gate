# Infrastructure inventory

This page enumerates every component version pinned or in active use
across the a2a-gate harness, the ai-memory substrate, and the agent
frameworks exercised per campaign. Kept up to date when any version
pin moves; last refreshed 2026-04-21.

## Test substrate — ai-memory

| Component | Version | Source of truth |
|---|---|---|
| ai-memory (latest tagged) | `v0.6.1` | [GitHub release](https://github.com/alphaonedev/ai-memory-mcp/releases/tag/v0.6.1) |
| ai-memory (under test in the a2a gate) | `v0.6.1` until tagged `v0.6.2` | workflow `ai_memory_git_ref` input |
| Rust MSRV (source build) | `1.93` | [Cargo.toml rust-version](https://github.com/alphaonedev/ai-memory-mcp/blob/develop/Cargo.toml) |
| Rust in CI (x-platform `cargo clippy + test`) | `stable` via `dtolnay/rust-toolchain@stable` | [ci.yml](https://github.com/alphaonedev/ai-memory-mcp/blob/develop/.github/workflows/ci.yml) |
| Rust pin for MSRV drift gate | `1.93` (Ubuntu 26.04 `rust-defaults`) | ci.yml `msrv` job |
| Rust edition | `2024` | Cargo.toml |

ai-memory's stable-Rust CI uses whatever `stable` points to on the
GitHub runner image at CI time (today `1.94.x`). The **MSRV CI
job** separately pins rustc `1.93` and runs `cargo check --locked`
so any accidental use of post-1.93 APIs fails CI before a tag-time
PPA upload attempts it.

## Agent frameworks (per campaign)

| Framework | Role | Version / ref | Install path |
|---|---|---|---|
| **IronClaw** | primary Rust agent (replaces OpenClaw 2026-04-21) | latest release from [nearai/ironclaw](https://github.com/nearai/ironclaw/releases/latest) (0.26.0 as of this writing) | direct tarball download `ironclaw-x86_64-unknown-linux-gnu.tar.gz` into `/usr/local/bin/ironclaw` (bypasses NEAR AI's installer script due to platform-detection bug) |
| **Hermes** | Python agent | pinned ref `HERMES_INSTALL_REF=main` from [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) | `curl install.sh --skip-setup` + `pip install python-dotenv==…` pinned patch |
| **OpenClaw** | LEGACY — retained for historical dispatch reproduction | `openclaw/openclaw` via `install.sh --install-method git` | scripts/setup_node.sh legacy branch |

All three are agent-agnostic from the a2a-gate's perspective — the
scenarios drive ai-memory's HTTP surface directly, so the framework
under test only affects baseline attestation + substrate provenance,
not scenario logic.

## LLM backend

| Model SKU | Provider | Base URL | Default reasoning? |
|---|---|---|---|
| `grok-4-0709` (= Grok 4.2 reasoning) | xAI | `https://api.x.ai/v1` | yes |
| `grok-4-fast-non-reasoning` | xAI | same | no (override for cost-optimized smoke runs only) |

All agent groups use the **same** SKU per campaign so A2A
comparisons hold. Configured via `A2A_GATE_LLM_MODEL` workflow
input; default `grok-4-0709`.

## DigitalOcean infrastructure (per 4-node campaign)

| Resource | Pin | Notes |
|---|---|---|
| Droplet base image | `ubuntu-24-04-x64` | DO's Ubuntu 24.04 LTS ("noble") image |
| Agent droplet size | `s-2vcpu-4gb` | Basic tier, 2 vCPU, 4 GB RAM, ~$0.03/hr |
| Memory node droplet size | `s-2vcpu-4gb` (hard-coded in terraform/main.tf) | matches agent droplets — no upsell needed |
| Region | `nyc3` (default; overridable via workflow input) | |
| VPC CIDR — ironclaw campaigns | `10.251.0.0/24` | primary Rust agent (replaces openclaw) |
| VPC CIDR — hermes campaigns | `10.252.0.0/24` | Python agent |
| VPC CIDR — openclaw campaigns (legacy) | `10.253.0.0/24` | retired-default |
| Ship-gate VPC CIDR | `10.250.0.0/24` | [ai-memory-ship-gate](https://github.com/alphaonedev/ai-memory-ship-gate) reserves this — we deliberately avoid it |

### Per-droplet software stack

Provisioned per `scripts/setup_node.sh`:

| Component | Version | Source |
|---|---|---|
| OS | Ubuntu 24.04 LTS (noble) | DO base image |
| `ai-memory` | `${AI_MEMORY_GIT_REF}` (workflow input) | GitHub Releases binary tarball (`ai-memory-x86_64-unknown-linux-gnu.tar.gz`) |
| PostgreSQL (ironclaw only) | `15` (target) via [PGDG apt repo](https://wiki.postgresql.org/wiki/Apt) | `apt.postgresql.org.sh` adds the repo, then `apt-get install postgresql-15 postgresql-15-pgvector postgresql-contrib-15` |
| pgvector (ironclaw only) | `postgresql-15-pgvector` (matches PG major version) | PGDG apt repo (not default noble apt) |
| Node.js / npm (openclaw only, legacy) | whatever `apt install nodejs npm` pulls | used by openclaw's install.sh |
| Python 3 (hermes only) | system python3 (3.12 on noble) | used by hermes-agent |
| `python-dotenv` (hermes only) | pinned patch version in setup_node.sh | upstream hermes install doesn't install it but needs it at runtime |
| `systemd`, `curl`, `jq`, `sqlite3` | Ubuntu default | |
| UFW | **DISABLED + verified disabled** | ship-gate lesson; baseline invariant |
| iptables | flushed to ACCEPT INPUT/OUTPUT/FORWARD | baseline invariant |
| Dead-man switch | `shutdown -P +480` (8-hour auto-halt) | cost cap |

### ai-memory federation wiring

Every node runs `ai-memory serve` with:

- `--host 0.0.0.0 --port 9077`
- `--quorum-writes 2` (W=2 of N=4 mesh)
- `--quorum-peers` = comma-separated URLs of the other 3 nodes
- `--db /var/lib/ai-memory/a2a.db`

Default feature tier: `semantic` (HuggingFace-Hub embedding model
auto-downloaded at first boot).

## GitHub Actions CI

| Runner | Purpose | Image |
|---|---|---|
| `ubuntu-latest` | ai-memory `Check` x86_64, release builds | currently `ubuntu-24.04` |
| `ubuntu-24.04-arm` | ai-memory cross-compile for `aarch64-unknown-linux-gnu` | GitHub hosted ARM |
| `macos-latest` | ai-memory `Check` + release for `aarch64-apple-darwin` / `x86_64-apple-darwin` | currently `macos-14` |
| `windows-latest` | ai-memory `Check` + release for `x86_64-pc-windows-msvc` | |

| Tool | Version |
|---|---|
| Terraform | `1.9.5` (pinned via `hashicorp/setup-terraform@v3`) |
| `actions/checkout` | `v5` |
| `dtolnay/rust-toolchain` | `@stable` (for check matrix) / `@master` + explicit `1.93` (for MSRV job) |
| `Swatinem/rust-cache` | `v2` |
| `cargo-audit` | installed fresh per run via `cargo install cargo-audit --locked` |

## Distribution targets

| Channel | Compiled where? | Target audience MSRV-sensitive? |
|---|---|---|
| GitHub Release tarballs | ai-memory CI (Rust stable = 1.94 today) | no — binary |
| Fedora COPR | ai-memory CI (repackages the x86_64 / aarch64 Linux tarballs) | no — binary |
| Homebrew | ai-memory CI | no — binary |
| Docker GHCR | ai-memory CI | no — binary |
| **Ubuntu PPA** | **Launchpad's build farm** (rustc from `rust-defaults` package) | **yes — Rust 1.93 required** |
| `cargo install ai-memory` from crates.io | user's machine | yes — Rust ≥ 1.93 |

### Ubuntu PPA target release

- **Series: `resolute`** (Ubuntu 26.04 LTS — Resolute Raccoon).
- 26.04 ships `rust-defaults` pointing at **rustc 1.93** (with 1.91 + 1.92 also in the archive for side-by-side coexistence).
- The PPA CI step rewrites `debian/changelog` at tag time to set the series, then `debuild -S` + `dput` uploads the signed source package. Launchpad asynchronously compiles.
- **Earlier releases (noble 24.04 et al.) are NOT supported by new PPA uploads** as of 2026-04-21. Users on those releases must upgrade to 26.04 to receive new .debs.

## ai-memory runtime requirements

For end users installing from any path:

| Requirement | Version |
|---|---|
| OS | Linux (glibc ≥ 2.38), macOS 13+, Windows 10+ |
| RAM (keyword-only deployment) | 100 MB typical |
| RAM (semantic tier with embedder loaded) | 300–500 MB typical |
| Disk | 200 MB for binary + `~/.ai-memory` DB (grows with corpus) |
| Outbound network | `api.x.ai` (for xAI Grok tests), HuggingFace Hub (one-time model download), federation peer URLs |

## Pin-bump procedure

When any version in this table changes:

1. Update the corresponding code pin (Cargo.toml / setup_node.sh / ci.yml / terraform/main.tf).
2. Add a `CHANGELOG.md` entry in the originating repo.
3. Update the table row in this doc.
4. If the change materially affects the baseline claim (e.g. MSRV bump), re-run a full a2a-gate campaign in each group (ironclaw + hermes) before tagging the next release.

## Authoritative version list (machine-readable)

For automation, `campaign.meta.json` emitted by every campaign carries
the resolved version pins for THAT run:

```json
{
  "ai_memory_git_ref": "v0.6.1",
  "agent_group": "ironclaw",
  "infra": {
    "provider": "digitalocean",
    "region": "nyc3",
    "droplet_size": "s-2vcpu-4gb",
    "topology": "4-node federation mesh (W=2/N=4)"
  },
  "llm_model": "grok-4-0709"
}
```

Run-specific attestation also lives per-node in `a2a-baseline.json`:

```json
{
  "framework_version": "OpenClaw 2026.4.15 (041266a)",
  "ai_memory_version": "0.6.1"
}
```
