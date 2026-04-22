#!/usr/bin/env python3
# Copyright 2026 AlphaOne LLC
# SPDX-License-Identifier: Apache-2.0
"""
Post-campaign AI NHI analyzer.

Reads a completed run directory (a2a-summary.json + campaign.meta.json +
scenario-*.json), synthesizes a tri-audience analysis via xAI Grok, and
writes `ai-nhi-analysis.json` into the run dir. The HTML generator
(scripts/generate_run_html.sh) prefers this per-run file over the
curated global analysis/run-insights.json.

Usage:
    python3 scripts/analyze_run.py <run_dir>

Environment:
    XAI_API_KEY           — required; xAI Grok API key.
    A2A_GATE_LLM_MODEL    — optional; model id (default: grok-4-0709).
    A2A_GATE_LLM_BASE_URL — optional; override (default: https://api.x.ai/v1).

Stdlib only (urllib, json, os, pathlib). No pip installs on the runner.
"""

import json
import os
import pathlib
import sys
import urllib.error
import urllib.request


REQUIRED_KEYS = (
    "headline", "verdict", "what_it_tested", "what_it_proved",
    "for_non_technical", "for_c_level", "for_sme", "next_run_change",
)


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def load_summary(run_dir: pathlib.Path) -> dict:
    """Stitch together a compact campaign summary from the artefacts."""
    summary_path = run_dir / "a2a-summary.json"
    meta_path = run_dir / "campaign.meta.json"
    out: dict = {
        "campaign_id": run_dir.name,
        "summary": {},
        "meta": {},
        "scenarios": [],
    }
    try:
        out["summary"] = json.loads(summary_path.read_text())
    except Exception as e:
        log(f"warning: could not read a2a-summary.json: {e}")
    try:
        out["meta"] = json.loads(meta_path.read_text())
    except Exception as e:
        log(f"warning: could not read campaign.meta.json: {e}")
    for jf in sorted(run_dir.glob("scenario-*.json")):
        try:
            doc = json.loads(jf.read_text())
            # Trim bulky fields to keep the prompt under the model's context.
            slim = {
                "scenario": doc.get("scenario") or jf.stem.replace("scenario-", ""),
                "pass": doc.get("pass"),
                "skipped": doc.get("skipped", False),
                "reason": (doc.get("reason") or "")[:500],
                "reasons": (doc.get("reasons") or [])[:6],
            }
            out["scenarios"].append(slim)
        except Exception as e:
            log(f"warning: could not read {jf.name}: {e}")
    return out


SYSTEM_PROMPT = """You are an AI NHI (non-human intelligence) infrastructure analyst embedded in the alphaonedev/ai-memory-ai2ai-gate project. Your job is to read a single campaign run artifact and produce a crisp JSON analysis with an exact schema. Be direct, evidence-based, and audience-aware.

Output JSON keys (ALL required, strings only, no nested objects):
- headline: <=12 words, plain language, captures the run's primary finding.
- verdict: "PASS" / "FAIL" / "PARTIAL" / "DEGRADED" with a short qualifier (e.g., "PARTIAL — 2 scenarios skipped under mTLS").
- what_it_tested: one sentence describing scenarios exercised and coverage axes (transport, framework, primitives).
- what_it_proved: one sentence summarizing what the results actually demonstrated.
- for_non_technical: 2-3 sentences for a general audience. No jargon. Focus on "do agents reliably share memory or not".
- for_c_level: 2-3 sentences for an executive. Risk posture, production readiness, customer-facing claim viability, what changed vs. prior runs.
- for_sme: 2-4 sentences for a software engineer / architect. Specific failure modes, primitives impacted, probable root cause, testbook/probe identifiers (S#, F#).
- next_run_change: one sentence describing the single most valuable change to make before the next campaign (can be "none — keep cadence" when the run is clean).

Rules:
- NEVER invent facts. If coverage is partial, say so.
- When pass=null + skipped=true, count the scenario as "skipped" (neither pass nor fail).
- Prefer concrete numbers ("37/42 scenarios green") over qualitative hedges.
- Return ONLY the JSON object — no prose, no markdown fences."""


def build_user_prompt(data: dict) -> str:
    return (
        "CAMPAIGN ARTIFACT (summary + meta + slim per-scenario results):\n"
        + json.dumps(data, indent=2)
        + "\n\nReturn the tri-audience analysis as a single JSON object."
    )


def call_grok(system: str, user: str) -> dict:
    api_key = os.environ.get("XAI_API_KEY", "").strip()
    if not api_key:
        raise RuntimeError("XAI_API_KEY is not set")
    base = os.environ.get("A2A_GATE_LLM_BASE_URL", "https://api.x.ai/v1").rstrip("/")
    model = os.environ.get("A2A_GATE_LLM_MODEL", "grok-4-0709")

    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "temperature": 0.2,
        "response_format": {"type": "json_object"},
    }
    req = urllib.request.Request(
        f"{base}/chat/completions",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=90) as resp:
            body = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")[:500]
        raise RuntimeError(f"xAI HTTP {e.code}: {body}")
    choices = body.get("choices") or []
    if not choices:
        raise RuntimeError(f"xAI returned no choices: {json.dumps(body)[:300]}")
    content = choices[0].get("message", {}).get("content", "")
    if not content:
        raise RuntimeError(f"xAI returned empty content: {json.dumps(body)[:300]}")
    try:
        return json.loads(content)
    except json.JSONDecodeError as e:
        raise RuntimeError(f"xAI response not JSON: {e}; raw={content[:500]}")


def placeholder_analysis(data: dict, failure_reason: str) -> dict:
    """Fallback so the run page always has *something* rendered."""
    scenarios = data.get("scenarios") or []
    passed = sum(1 for s in scenarios if s.get("pass") is True)
    failed = sum(1 for s in scenarios if s.get("pass") is False)
    skipped = sum(1 for s in scenarios if s.get("skipped") is True)
    total = len(scenarios)
    verdict = "PASS" if failed == 0 and passed > 0 else "FAIL" if failed > 0 else "PARTIAL"
    headline = f"{passed}/{total} scenarios passed; {failed} failed, {skipped} skipped"
    return {
        "headline": headline,
        "verdict": f"{verdict} — auto-generated (LLM unavailable: {failure_reason[:120]})",
        "what_it_tested": f"Campaign {data.get('campaign_id')} ran {total} testbook scenarios across transport, primitives, and cross-cutting axes.",
        "what_it_proved": f"Direct counts: pass={passed}, fail={failed}, skip={skipped}.",
        "for_non_technical": (
            f"This run exercised {total} tests of AI-agent-to-AI-agent communication through ai-memory. "
            f"{passed} worked correctly, {failed} did not, and {skipped} were intentionally skipped because prerequisites weren't met."
        ),
        "for_c_level": (
            f"Run verdict {verdict.lower()}. Detailed narrative synthesis unavailable (LLM call failed: {failure_reason[:120]}). "
            "Counts are reliable; consult the per-scenario PASS/FAIL and the testbook for primitive-level mapping."
        ),
        "for_sme": (
            f"Scenario outcomes: pass={passed} fail={failed} skip={skipped} of {total} total. "
            f"First failure reasons are persisted on each scenario-N.json. LLM narrative unavailable: {failure_reason[:120]}."
        ),
        "next_run_change": "Investigate the LLM-call failure or re-run with XAI_API_KEY verified; counts are unaffected.",
    }


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <run_dir>", file=sys.stderr)
        return 2
    run_dir = pathlib.Path(sys.argv[1]).resolve()
    if not run_dir.is_dir():
        print(f"error: not a directory: {run_dir}", file=sys.stderr)
        return 2

    data = load_summary(run_dir)
    log(f"analyze_run: {run_dir.name} — {len(data['scenarios'])} scenarios")

    try:
        analysis = call_grok(SYSTEM_PROMPT, build_user_prompt(data))
        missing = [k for k in REQUIRED_KEYS if k not in analysis]
        if missing:
            raise RuntimeError(f"LLM response missing keys: {missing}")
    except Exception as e:
        log(f"analyze_run: LLM call failed ({e}); emitting placeholder")
        analysis = placeholder_analysis(data, str(e))

    # Minimal provenance block alongside the schema the renderer reads.
    analysis["_generated_by"] = "scripts/analyze_run.py"
    analysis["_model"] = os.environ.get("A2A_GATE_LLM_MODEL", "grok-4-0709")
    analysis["_campaign_id"] = data.get("campaign_id")

    out_path = run_dir / "ai-nhi-analysis.json"
    out_path.write_text(json.dumps(analysis, indent=2, sort_keys=True))
    log(f"analyze_run: wrote {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
