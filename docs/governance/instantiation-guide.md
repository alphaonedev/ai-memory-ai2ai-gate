# Instantiation guide — instantiating canonical governance into a per-release campaign

This guide explains how to set up a new per-release A2A campaign repo (`ai-memory-a2a-v<X.Y.Z>`) so it inherits the canonical First-Principles governance hosted in this repo (`ai-memory-ai2ai-gate`).

The canonical sources are:

- [`docs/governance/META-GOVERNANCE.md`](META-GOVERNANCE.md) — release-agnostic First-Principles document.
- [`docs/governance/phase-log.schema.json`](phase-log.schema.json) — release-agnostic §7 JSON log schema.

Per-release campaigns **copy** these into their own repo and **pin** the version-specific fields. The reference instantiation is the v0.6.3.1 campaign — see PR https://github.com/alphaonedev/ai-memory-a2a-v0.6.3.1/pull/2.

---

## 1. Prerequisites for a new release

Before instantiating, confirm:

1. The release tag (`v<X.Y.Z>`) exists on `ai-memory-mcp` and is the subject under test.
2. A release umbrella issue is open on `alphaonedev/ai-memory-mcp` tracking the release's verdict and patch candidate list.
3. Substrate ship-gate Phases 1–4 have passed for the release (this document is downstream of substrate cert; no NHI campaign runs on a substrate that hasn't passed pre-tag).
4. The set of expected-RED substrate canaries for the release is decided (may be empty for a clean release).
5. The canonical SHA of `META-GOVERNANCE.md` and `phase-log.schema.json` you are instantiating from. Pin to a commit SHA, not a branch.

---

## 2. Repo layout to create

Each per-release campaign repo follows this layout (the v0.6.3.1 campaign sets the pattern):

```
ai-memory-a2a-v<X.Y.Z>/
├── docs/
│   └── governance.md            # ← copy of META-GOVERNANCE.md, pinned
├── scripts/
│   └── schema/
│       └── phase-log.schema.json  # ← copy of canonical schema, pinned
├── releases/
│   └── v<X.Y.Z>/
│       └── summary.json
└── README.md
```

The Orchestrator runtime, prompts, and aggregator can be copied from the v0.6.3.1 campaign repo's PR #2 wholesale; this guide only covers the governance layer.

---

## 3. Instantiating `docs/governance.md`

1. Copy `docs/governance/META-GOVERNANCE.md` from this repo at a known SHA into the per-release repo as `docs/governance.md`.
2. At the top of the new file, add a citation block:

   ```markdown
   > Instantiated from `ai-memory-ai2ai-gate/docs/governance/META-GOVERNANCE.md` at commit `<canonical-sha>`. Per-release pins are below; everything else inherits unchanged.
   ```

3. Pin every field in **Appendix C — Per-release fields to pin on instantiation** of the canonical doc. Replace placeholder text with release-specific values:

   - Release tag (`v<X.Y.Z>`) — replace all `v<X.Y.Z>` placeholders with the actual tag.
   - Schema version (`v<N>`) — the ai-memory-mcp internal schema version under test.
   - Umbrella issue — the release's umbrella issue URL.
   - Cert cell target — substrate cell count for the release.
   - Phase 1 expected verdict — `GREEN` or `PARTIAL — pending Patch <n>`.
   - Expected-RED canary IDs and their bug refs.
   - Scenario D expected direction — RED-canary-present or post-fix-clean.
   - Carry-forward targets — next patch and next minor.

4. Update §1, §4, §6.1 (Scenario D expected behavior), §11, and any cross-references that name the release.

5. Replace the canonical doc's "release-agnostic" framing in §3 and §10 with the release-specific phrasing. The five-phase structure, principle text, and scenario A/B/C/D bodies stay verbatim.

6. **Do not** remove or weaken any of the six principles. Do not lower n=3. Do not collapse substrate and NHI verdicts. If the release has a legitimate reason to deviate, file a deviation note inline citing the canonical doc.

---

## 4. Instantiating `scripts/schema/phase-log.schema.json`

1. Copy `docs/governance/phase-log.schema.json` from this repo at the same canonical SHA into the per-release repo at `scripts/schema/phase-log.schema.json`.

2. Update `$id` to the per-release URL, e.g., `https://alphaonedev.github.io/ai-memory-a2a-v<X.Y.Z>/schema/phase-log.schema.json`.

3. Update `title` and `description` to name the release.

4. **Pin three fields**:

   | Canonical (release-agnostic) | Per-release (pinned) |
   |---|---|
   | `"schema_version": { "type": "string", "pattern": "^v\\d+\\.\\d+\\.\\d+(\\.\\d+)?-a2a-nhi-\\d+$" }` | `"schema_version": { "const": "v<X.Y.Z>-a2a-nhi-<rev>" }` |
   | `"release": { "type": "string", "pattern": "^v\\d+\\.\\d+\\.\\d+(\\.\\d+)?$" }` | `"release": { "const": "v<X.Y.Z>" }` |
   | `"campaign_id": { "type": "string", "pattern": "^a2a-(ironclaw\|hermes)-v\\d+\\.\\d+\\.\\d+(\\.\\d+)?-r[0-9]+$" }` | `"campaign_id": { "type": "string", "pattern": "^a2a-(ironclaw\|hermes)-v<X\\.Y\\.Z>-r[0-9]+$" }` (escape dots) |

5. Add a description note at the top of the schema citing the canonical SHA you instantiated from:

   ```json
   "description": "... Instantiated from ai-memory-ai2ai-gate/docs/governance/phase-log.schema.json at commit <canonical-sha>."
   ```

6. **Do not** add, remove, or rename any other property. Validation tooling depends on the canonical shape.

---

## 5. Verifying the instantiation

After copying:

1. The per-release `docs/governance.md` should reference the canonical SHA in its citation block.
2. The per-release schema's `$id` should resolve to the campaign repo's pages URL.
3. The per-release schema's `schema_version` `const` should match the value used in every emitted JSON record.
4. The per-release schema's `release` `const` should match every artifact's `release` field.
5. The Orchestrator's JSON validator should be pointed at the per-release schema, not the canonical one (the canonical accepts any release; the per-release locks to one).

A quick check: validate one Phase 2 scripted-exchange record against both schemas. The canonical should pass any well-formed record; the per-release should reject records carrying a wrong `schema_version` or `release`.

---

## 6. When the canonical changes

The canonical evolves rarely but does evolve. When it does:

- A per-release campaign **already in flight** does not auto-upgrade — it stays on the SHA it instantiated from. The campaign artifact is expected to be reproducible.
- A new release that opens after the canonical update instantiates from the new SHA.
- If a canonical change is significant enough to require an in-flight campaign to upgrade (e.g., a binding §7 schema change), a deviation issue is filed on the in-flight campaign repo and the human maintainer decides.

This is the same pinning discipline ai-memory-mcp itself uses for schema versions: pinned per release, never silently rolled forward.

---

## 7. Reference instantiation

The v0.6.3.1 campaign is the reference instantiation. Read these files alongside this guide:

- https://github.com/alphaonedev/ai-memory-a2a-v0.6.3.1/blob/refactor/first-principles-governance/docs/governance.md
- https://github.com/alphaonedev/ai-memory-a2a-v0.6.3.1/blob/refactor/first-principles-governance/scripts/schema/phase-log.schema.json
- PR https://github.com/alphaonedev/ai-memory-a2a-v0.6.3.1/pull/2

Anything the v0.6.3.1 campaign does that this guide does not require but does not contradict is a reasonable per-release elaboration. Anything it does that contradicts the canonical is a bug in the v0.6.3.1 instantiation, not a license to repeat it.

---

*End of instantiation guide.*
