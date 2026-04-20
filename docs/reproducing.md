# Reproducing a campaign

The whole point of this repository is that any DigitalOcean account
holder can fork it, plug in their own credentials, and reproduce the
exact campaign our published runs were measured against. This page
walks through the steps.

## Prerequisites

- A DigitalOcean account with API token creation rights.
- A GitHub account and `gh` CLI installed locally.
- An SSH key you're willing to register with DigitalOcean for the
  campaign droplets (ed25519 recommended). The PRIVATE key goes
  into GitHub Secrets — encrypted at rest.
- Familiarity with `terraform`, `gh workflow run`, and reading
  JSON artifacts.

## One-time fork + secrets

```sh
gh repo fork alphaonedev/ai-memory-ai2ai-gate --clone
cd ai-memory-ai2ai-gate
# Fetch your DO API token (create one in the DO control panel if
# you don't have one).
gh secret set DIGITALOCEAN_TOKEN -R <your-fork>
# Register your SSH public key with DO, then note the fingerprint.
gh secret set DIGITALOCEAN_SSH_KEY_FINGERPRINT -R <your-fork>
# Put the PRIVATE key into secrets — encrypted at rest in GitHub
# Secrets, only decrypted at job time.
gh secret set DIGITALOCEAN_SSH_PRIVATE_KEY -R <your-fork> < ~/.ssh/id_ed25519
```

## Dispatch a campaign

```sh
gh workflow run a2a-gate.yml -R <your-fork> \
  -f ai_memory_git_ref=release/v0.6.0 \
  -f campaign_id=my-first-a2a-run
```

Valid `ai_memory_git_ref` values:

- `release/v0.6.0` — current release branch
- `main` — tip of main
- `v0.6.0` — any tag
- any commit SHA

`campaign_id` becomes the `runs/<campaign_id>/` directory name.
Convention: use a slug like `my-validation-2026-04-20`.

Optional inputs (when the workflow lands):

- `region` — DO region. Default `nyc3`.
- `scenarios` — space-separated list of scenario numbers. Default
  `1 2 3 4 5 6 7` (8 is opt-in; requires Ollama-capable droplets).
- `auto_tag` — `true` to enable scenario 8 + bump droplets to
  `s-4vcpu-16gb`. Default `false`.

## Watch the run

```sh
gh run watch --repo <your-fork>
```

Or open the Actions tab in your fork's GitHub page.

Expected wall-clock: ~20 minutes for a clean 7-scenario run. Under
~30 minutes even in pathological cases before the job timeout hits.

## Read the artifacts

After the run commits, `runs/<campaign_id>/` contains:

- `a2a-summary.json` — top-level verdict
- `scenario-1.json` through `scenario-N.json` — per-scenario reports
- `index.html` — self-contained browsable page with AI NHI tri-
  audience analysis (mirrors ship-gate's per-run evidence format)

You can also browse them as HTML from your fork's Pages site:
`https://<your-org>.github.io/ai-memory-ai2ai-gate/evidence/<campaign_id>/`.

## Dispute a finding

If your fork's campaign passes and this repo's fails (or vice
versa), open an issue citing:

- Both campaign IDs
- The specific scenario that disagrees
- The ai-memory git ref you both ran against
- Anything different about your infrastructure (region, droplet
  size, DO account age / quota tier)

Cross-fork comparison is the point. An unreproducible result is a
bug in the harness, and we want to find it.

## Cost

A clean run is ~$0.20 of DigitalOcean compute:

- 4 × `s-2vcpu-4gb` droplets × ~20 min × ~$0.03/hr = ~$0.04
- Transfer inside the VPC is free
- Base region overhead (floating IP alloc, VPC, firewall) ≈ $0

Worst case with the 8-hour dead-man switch cap: ~$1.30 per droplet
= ~$5.20 per pathological campaign. Still well under $10 even if
everything goes wrong at the workflow level.

## Teardown

The workflow runs `terraform destroy -auto-approve` as its
penultimate step regardless of phase outcome. If the workflow
itself is cancelled mid-run before that step, you can tear down
manually:

```sh
cd terraform
terraform destroy -auto-approve \
  -var "campaign_id=my-first-a2a-run" \
  -var "do_token=$DO_TOKEN" \
  -var "ssh_key_fingerprint=$SSH_FP"
```

The in-droplet `shutdown -P +480` will also destroy the VMs after
8 hours as a last-resort backstop.
