# Configuring ai-memory as the shared MCP layer — IronClaw + Hermes

This is the **authoritative, repeatable, reproducible** standard for wiring
[ai-memory](https://alphaonedev.github.io/ai-memory-mcp/) into an agent
framework for the a2a-gate. It documents both **IronClaw** (AlphaOne, Rust
CLI-driven) and **Hermes** (Nous Research, YAML-driven) in the same shape so
results from the two campaigns are directly comparable — same substrate,
different agent reasoning layer.

The configurations below are the ones `scripts/setup_node.sh` lays down
verbatim on every agent droplet. If you change this document, update
`setup_node.sh` in the same commit (and bump `spec_version` in
`/etc/ai-memory-a2a/baseline.json`).

---

## Invariant contract (both frameworks)

Every agent node satisfies **all** of the following before scenarios run:

1. `ai-memory` binary installed at pinned version, on `PATH`
2. Framework registers **exactly one** MCP server: `memory`, pointing at
   `ai-memory` stdio
3. Framework LLM is xAI Grok (reachable + sample reply OK)
4. `AI_MEMORY_AGENT_ID` stamped in the framework's env/config so every
   write carries the node's distinct identity (`ai:alice` / `ai:bob` /
   `ai:charlie`)
5. All alternative A2A channels (Telegram, Discord, Slack, ACP,
   sub-agent spawn, remote exec backends, chat gateway) are **disabled**
6. `a2a_gate_profile` pinned to `shared-memory-only`
7. **F5 MCP handshake probe passes** — spawning the stdio subprocess with
   the framework's exact invocation returns `memory_store`, `memory_recall`,
   and `memory_list` from a `tools/list` JSON-RPC call
8. **F2a HTTP substrate probe passes** — direct write+read roundtrip on
   the local `ai-memory serve` on `127.0.0.1:9077`
9. **F4 mesh probe passes** — all `N-1` outbound edges to peer
   `ai-memory serve` instances respond to both `GET /api/v1/health` and
   `POST /api/v1/sync/push` with `dry_run=true`

`baseline_pass = true` requires all of the above. Scenarios are SKIPPED
otherwise.

---

## Prerequisites (identical on every node)

### 1. Install ai-memory at a pinned version

The a2a-gate pins `AI_MEMORY_VERSION` to a released tag and pulls the
Linux x86_64 binary from GitHub Releases:

```bash
AI_MEMORY_VERSION="0.6.2-rc.0"   # pin via workflow_dispatch input
curl -sSL -o amem.tgz \
  "https://github.com/alphaonedev/ai-memory-mcp/releases/download/v${AI_MEMORY_VERSION}/ai-memory-x86_64-unknown-linux-gnu.tar.gz"
tar xzf amem.tgz
install -m 0755 ai-memory /usr/local/bin/ai-memory
ai-memory --version                    # must print v${AI_MEMORY_VERSION}
```

### 2. Create the shared state directories

```bash
mkdir -p /var/lib/ai-memory /etc/ai-memory-a2a
```

- `/var/lib/ai-memory/a2a.db` — the SQLite database. **One DB per node.**
  Never point `--db` at a path shared across nodes or across frameworks.
- `/etc/ai-memory-a2a/baseline.json` — written by `setup_node.sh`; scp'd
  up by the campaign workflow's "Collect + enforce BASELINE" step.

### 3. Boot the local `ai-memory serve`

Every agent node runs its own `ai-memory serve` federated with the other
three nodes in the VPC (W=2 of N=4 quorum). This is the HTTP surface
F2a and F4 talk to. The details live in `scripts/setup_node.sh` under
"serve + federation bootstrap".

---

## IronClaw configuration (CLI-driven)

IronClaw has no YAML; state lives in `~/.ironclaw/config.toml` plus
`~/.ironclaw/.env`. MCP servers are registered via `ironclaw mcp add`.

### Step 1 — Bootstrap `.env`

```bash
mkdir -p /root/.ironclaw
cat > /root/.ironclaw/.env <<EOF
DATABASE_URL=postgres://ironclaw:ironclaw@127.0.0.1:5432/ironclaw?sslmode=disable
LLM_BACKEND=openai_compatible
LLM_BASE_URL=https://api.x.ai/v1
LLM_API_KEY=${XAI_API_KEY}
LLM_MODEL=${A2A_GATE_LLM_MODEL}
HTTP_PORT=8081
AI_MEMORY_AGENT_ID=${AGENT_ID}
EOF
chmod 600 /root/.ironclaw/.env
```

`AI_MEMORY_AGENT_ID` lives in `.env` so baseline checks can verify agent
identity deterministically via a file grep (CLI output format varies
between ironclaw versions).

### Step 2 — Pin the thesis-integrity profile

```bash
ironclaw config set channels.telegram.enabled false
ironclaw config set channels.discord.enabled  false
ironclaw config set channels.slack.enabled    false
ironclaw config set gateway.mode              local
ironclaw config set a2a_gate_profile          shared-memory-only
ironclaw config set a2a_gate_profile_version  1.0.0
```

### Step 3 — Register the ai-memory MCP server

IronClaw's `mcp add` uses `--arg <val>` (repeatable). Values starting
with `--` must use `--arg=--flag` so clap doesn't interpret them as
flags on `mcp add` itself:

```bash
ironclaw mcp add memory \
  --transport stdio \
  --command ai-memory \
  --env "AI_MEMORY_DB=/var/lib/ai-memory/a2a.db" \
  --env "AI_MEMORY_AGENT_ID=${AGENT_ID}" \
  --arg mcp \
  --arg=--tier \
  --arg semantic \
  --description "Shared-memory A2A via ai-memory (a2a-gate)"
```

At spawn time this resolves to:

```bash
AI_MEMORY_DB=/var/lib/ai-memory/a2a.db \
AI_MEMORY_AGENT_ID=ai:alice \
  ai-memory mcp --tier semantic
```

### Step 4 — Verify

```bash
ironclaw mcp list | grep -q memory || { echo "FATAL: memory MCP not registered"; exit 1; }
ironclaw --version
```

### IronClaw caveats

- **Tool allowlist.** IronClaw exposes tools to the LLM **only via
  registered MCP servers**. There is no separate `toolAllowlist`
  concept like openclaw. The a2a-gate asserts `tool_allowlist_is_memory_only`
  by provisioning control (exactly one `mcp add memory` call) plus the
  F5 handshake probe. `/etc/ai-memory-a2a/ironclaw-mcp-list.raw` is
  persisted every run for forensic audit.
- **Version format.** `ironclaw --version` output has varied across
  releases. Treat it as an observation, not a gate. Pin via install
  script SHA, not CLI output parsing.

---

## Hermes configuration (YAML-driven)

Hermes reads `~/.hermes/config.yaml`. Register `mcp_servers.memory` and
set the negative invariants alongside.

### Step 1 — Install + patch

```bash
HERMES_INSTALL_REF="main"     # pin via workflow_dispatch input
curl -fsSL --max-time 60 \
  "https://raw.githubusercontent.com/NousResearch/hermes-agent/${HERMES_INSTALL_REF}/scripts/install.sh" \
  | bash -s -- --skip-setup
# PEP 668 on Ubuntu 24.04 + upstream install.sh doesn't install python-dotenv
python3 -m pip install --break-system-packages --quiet "python-dotenv==1.0.1"
# Symlink onto PATH for ssh session consistency
ln -sf "$(find /root/.hermes -maxdepth 4 -name hermes -type f -executable | head -1)" /usr/local/bin/hermes
```

### Step 2 — Write `~/.hermes/config.yaml`

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
      AI_MEMORY_AGENT_ID: "${AGENT_ID}"
    enabled: true

# Thesis integrity — all alternative A2A channels OFF
acp:
  enabled: false

messaging:
  gateway_enabled: false
  platforms:
    telegram: { enabled: false }
    discord:  { enabled: false }
    slack:    { enabled: false }

execution_backends: []

mcp_server_mode: false        # client-only; never expose Hermes AS an MCP server
subagent_delegation: false    # no spawn_subagent — forces all coordination through memory

tool_allowlist:
  - memory_store
  - memory_recall
  - memory_list
  - memory_get
  - memory_share
  - memory_link
  - memory_update
  - memory_detect_contradiction
  - memory_consolidate

a2a_gate_profile: shared-memory-only
a2a_gate_profile_version: "1.0.0"
```

Then:

```bash
chmod 600 /root/.hermes/config.yaml
cat > /etc/ai-memory-a2a/hermes.env <<EOF
XAI_API_KEY=${XAI_API_KEY}
EOF
chmod 600 /etc/ai-memory-a2a/hermes.env
```

### Step 3 — Verify

```bash
grep -q '^  memory:' /root/.hermes/config.yaml
grep -q 'command: ai-memory' /root/.hermes/config.yaml
grep -q "AI_MEMORY_AGENT_ID.*${AGENT_ID}" /root/.hermes/config.yaml
hermes --version
```

### Hermes caveats

- **`python-dotenv` is not installed by `install.sh`** but is imported at
  module-top in `hermes_cli/env_loader.py`. Always install the pinned
  version explicitly (surfaced by a2a-hermes-v0.6.0-r6).
- **`tool_allowlist` is explicit YAML.** Unlike ironclaw, hermes has a
  first-class tool allowlist. The list above is the reference — copy
  verbatim. Adding a tool here that doesn't start with `memory_` breaks
  the negative invariant and fails `baseline_pass`.
- **Sampling.** Hermes enables MCP sampling by default. ai-memory doesn't
  need it (no LLM callback). If you want to be strict add
  `sampling: { enabled: false }` to the `memory:` block.

---

## The F5 deterministic handshake probe

F5 is framework-agnostic. It spawns the ai-memory stdio subprocess with
the **exact invocation the framework would use** and sends three
line-delimited JSON-RPC messages over stdin:

```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"a2a-gate-baseline-f5","version":"1.0.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
```

F5 passes iff:

- `id=1` reply has `.result.serverInfo.name` non-empty
- `id=2` reply's `.result.tools[].name` **contains** `memory_store`,
  `memory_recall`, **and** `memory_list`

Per-framework invocation used by F5:

| Framework | Invocation |
|-----------|------------|
| ironclaw  | `AI_MEMORY_DB=/var/lib/ai-memory/a2a.db AI_MEMORY_AGENT_ID=… ai-memory mcp --tier semantic` |
| hermes    | `AI_MEMORY_AGENT_ID=… ai-memory --db /var/lib/ai-memory/a2a.db mcp --tier semantic` |
| openclaw  | `AI_MEMORY_AGENT_ID=… ai-memory --db /var/lib/ai-memory/a2a.db mcp --tier semantic` |

Raw F5 response is persisted at `/tmp/f5-mcp-response-${AGENT_TYPE}.jsonl`
and the stderr at `/tmp/f5-stderr.log` for post-mortem.

### Why F5 and F2b both exist

- **F2a** — HTTP canary on `127.0.0.1:9077`. Proves the federation-side
  write path is alive. **Does not exercise the MCP stdio channel at all.**
- **F5** — MCP stdio handshake. Proves the exact subprocess the framework
  will spawn can initialize and advertise memory tools. **Deterministic
  (no LLM).** Replaces the previous "is only one MCP server registered"
  heuristic, which was brittle against `ironclaw mcp list` output format
  drift.
- **F2b** — Agent-driven MCP canary. Asks the framework's LLM to use
  memory via a prompt. **LLM-dependent** — a model flaking doesn't
  invalidate the baseline, so F2b is observed but **does not gate**
  `baseline_pass`. When F2b fails while F2a + F5 pass, the regression is
  in the framework's reasoning layer, not in ai-memory.

---

## Quick end-to-end smoke test (runs on any provisioned node)

```bash
# 1. Binary healthy
which ai-memory && ai-memory --version

# 2. Stdio MCP responds (F5-equivalent, manual)
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  | timeout 10 ai-memory --db /var/lib/ai-memory/a2a.db mcp --tier semantic \
  | jq -rs '.[] | select(.id==2) | .result.tools[]?.name' | sort

# 3. HTTP substrate roundtrip (F2a-equivalent, manual)
curl -sS -X POST "http://127.0.0.1:9077/api/v1/memories" \
  -H "X-Agent-Id: ai:alice" -H "Content-Type: application/json" \
  -d '{"tier":"mid","namespace":"_smoke","title":"smoke","content":"hello","priority":5,"confidence":1.0,"source":"api","metadata":{"agent_id":"ai:alice","probe":"smoke"}}'
curl -sS "http://127.0.0.1:9077/api/v1/memories?namespace=_smoke&limit=5" | jq '.memories[].content'

# 4. Full baseline.json
jq . /etc/ai-memory-a2a/baseline.json
```

All three should print non-empty results and `.baseline_pass == true`.

---

## Troubleshooting

### `baseline_pass: false` with `tool_allowlist_is_memory_only: false`

- **Hermes**: read `/root/.hermes/config.yaml` — any entry in
  `tool_allowlist` that doesn't start with `memory_` fails the invariant.
  Fix the YAML and rerun setup.
- **IronClaw**: check `/etc/ai-memory-a2a/ironclaw-mcp-list.raw`.
  The provisioning script registers only `memory`; if the raw dump shows
  additional servers, something re-registered behind our back.

### `baseline_pass: false` with `ai_memory_mcp_stdio_f5: false`

Read `/tmp/f5-stderr.log` for the actual subprocess error. Common causes:

1. Binary not on PATH or wrong architecture → `ai-memory: command not
   found` or `exec format error`
2. DB path not writable → `sqlite: unable to open database file`
3. Wrong `--tier` → `unknown tier '…'`
4. Protocol version mismatch — if a future ai-memory release bumps past
   `2024-11-05`, update the `protocolVersion` in F5.

### `baseline_pass: false` with `substrate_http_canary_f2a: false`

`ai-memory serve` isn't listening on `127.0.0.1:9077` or quorum isn't
satisfied. Check the serve logs:

```bash
journalctl -u ai-memory-serve -n 200 --no-pager
curl -sS http://127.0.0.1:9077/api/v1/health
```

### `baseline_pass: false` with `mesh_connectivity_f4: false`

Check the VPC firewall rules (DigitalOcean cloud firewall + iptables on
each droplet). The 9077/tcp rule must allow the VPC CIDR in both
directions.

```bash
iptables -S | grep 9077
# From this node, can we reach the others?
for peer in 10.251.0.2 10.251.0.3 10.251.0.4; do
  curl -sS --max-time 3 "http://${peer}:9077/api/v1/health"
done
```

---

## References

- ai-memory documentation: <https://alphaonedev.github.io/ai-memory-mcp/>
- ai-memory GitHub: <https://github.com/alphaonedev/ai-memory-mcp>
- IronClaw MCP commands: `ironclaw mcp --help`
- Hermes Agent MCP docs: <https://hermes-agent.nousresearch.com/docs/user-guide/features/mcp>
- This repo's baseline spec: [`docs/baseline.md`](baseline.md)
- This repo's reproduction guide: [`docs/reproducing.md`](reproducing.md)
- The authoritative setup script: [`scripts/setup_node.sh`](../scripts/setup_node.sh)
