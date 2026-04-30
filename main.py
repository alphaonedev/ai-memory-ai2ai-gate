"""mkdocs-macros entry point for the A2A-gate site.

Reads ``releases/<version>/summary.json`` files from the repo root and exposes
the highest-semver release as the "current" one for the landing page. The
landing page is converted from inline-edited Markdown numbers to a single
``{{ render_current_release() }}`` macro call so that bumping a version no
longer requires touching ``docs/index.md``.

A2A summaries use ``cells[]`` (one entry per agent_group x tls_mode cell)
rather than ``phases[]``, but the macro accepts either shape so the same
template module can be used by both gates if desired.

Per-release summaries are validated against ``releases/schema.json`` by
``.github/workflows/release-summary-gate.yml`` on every ``v*`` tag push.
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

_SEMVER_RE = re.compile(
    r"^v(\d+)\.(\d+)\.(\d+)(?:\.(\d+))?(?:-([0-9A-Za-z.-]+))?$"
)


def _parse_semver(name: str) -> tuple[int, int, int, int, tuple[Any, ...]] | None:
    m = _SEMVER_RE.match(name)
    if not m:
        return None
    major, minor, patch, hotfix, pre = m.groups()
    hotfix_n = int(hotfix) if hotfix is not None else 0
    if pre is None:
        pre_key: tuple[Any, ...] = (1,)
    else:
        ids: list[Any] = []
        for ident in pre.split("."):
            if ident.isdigit():
                ids.append((0, int(ident)))
            else:
                ids.append((1, ident))
        pre_key = (0, tuple(ids))
    return (int(major), int(minor), int(patch), hotfix_n, pre_key)


def _discover_releases(root: Path) -> list[tuple[Path, dict[str, Any]]]:
    releases_dir = root / "releases"
    if not releases_dir.is_dir():
        return []
    found: list[tuple[tuple[int, int, int, int, tuple[Any, ...]], Path, dict[str, Any]]] = []
    for child in releases_dir.iterdir():
        if not child.is_dir():
            continue
        key = _parse_semver(child.name)
        if key is None:
            continue
        summary = child / "summary.json"
        if not summary.is_file():
            continue
        try:
            data = json.loads(summary.read_text())
        except json.JSONDecodeError:
            continue
        found.append((key, summary, data))
    found.sort(key=lambda triple: triple[0])
    return [(p, d) for _, p, d in found]


def _human_seconds(s: int | None) -> str:
    if s is None:
        return "—"
    if s < 60:
        return f"{s}s"
    minutes, sec = divmod(s, 60)
    if minutes < 60 and sec == 0:
        return f"{minutes}m"
    if minutes < 60:
        return f"{minutes}m{sec}s"
    hours, minutes = divmod(minutes, 60)
    return f"{hours}h{minutes}m"


def _render_cell_row(cell: dict[str, Any]) -> str:
    badge = "✅" if cell.get("pass") else "❌"
    name = cell.get("cell", "?")
    passc = cell.get("pass_count", 0)
    failc = cell.get("fail_count", 0)
    total = cell.get("scenario_total") or (passc + failc)
    wall = cell.get("wall_human") or _human_seconds(cell.get("wall_seconds"))
    notes = cell.get("notes", "")
    return f"| `{name}` | {badge} | {passc} / {total} | {wall} | {notes} |"


def _render_current_release(summary: dict[str, Any]) -> str:
    version = summary.get("version", "?")
    date = summary.get("date", "?")
    pass_count = summary.get("pass_count", 0)
    fail_count = summary.get("fail_count", 0)
    wall = summary.get("wall_human") or _human_seconds(summary.get("wall_seconds"))
    verdict = summary.get("verdict", "?").upper()
    headline = summary.get("headline") or (
        f"{version} — {pass_count}/{pass_count + fail_count} green — {wall} — {date}"
    )
    evidence = summary.get("evidence", {}) or {}
    release = summary.get("release", {}) or {}
    cells = summary.get("cells", []) or []
    closed = summary.get("scenarios_closed", []) or []

    admonition_kind = "success" if verdict == "PASS" else "danger"
    lines: list[str] = []
    lines.append(f'!!! {admonition_kind} "{headline}"')
    lines.append("")
    lines.append(
        f"    **Campaign `{summary.get('campaign_run_id', '?')}` returned "
        f"`overall_pass: {str(verdict == 'PASS').lower()}` on {date}.**"
    )
    if summary.get("ai_memory_commit"):
        lines.append(
            f"    Validated against ai-memory commit "
            f"`{summary['ai_memory_commit']}` "
            f"({summary.get('ai_memory_git_ref', '?')})."
        )
    lines.append("")

    if cells:
        lines.append("    | Cell | Verdict | Scenarios | Wall | Notes |")
        lines.append("    |---|---|---|---|---|")
        for c in cells:
            lines.append("    " + _render_cell_row(c))
        lines.append("")

    if closed:
        lines.append("    **Scenarios closed in this release:**")
        lines.append("")
        for sc in closed:
            sid = sc.get("id", "?")
            name = sc.get("name", "")
            prev = sc.get("previously", "")
            now = sc.get("now", "")
            lines.append(f"    - **{sid} ({name})** — was {prev}; now {now}.")
        lines.append("")

    links: list[str] = []
    if evidence.get("campaign_dir"):
        links.append(
            f"[**→ {version} evidence directory**]"
            f"(https://github.com/alphaonedev/ai-memory-ai2ai-gate/tree/main/{evidence['campaign_dir']})"
        )
    if evidence.get("offline_html"):
        links.append(
            f"[**→ {version} offline HTML**]({evidence['offline_html']})"
        )
    if evidence.get("test_hub_url"):
        links.append(f"[**→ test-hub release page**]({evidence['test_hub_url']})")
    if evidence.get("release_notes_url"):
        links.append(f"[**→ release notes**]({evidence['release_notes_url']})")
    if links:
        lines.append("    " + " &middot; ".join(links))
        lines.append("")

    if release.get("channels"):
        lines.append(
            "    Distribution channels: "
            + ", ".join(f"`{c}`" for c in release["channels"])
            + "."
        )
        lines.append("")

    return "\n".join(lines)


def _render_release_history(releases: list[tuple[Path, dict[str, Any]]]) -> str:
    if not releases:
        return ""
    rows = ["| Version | Date | Verdict | Pass / Fail | Wall | Evidence |", "|---|---|---|---|---|---|"]
    for _, data in reversed(releases):
        version = data.get("version", "?")
        date = data.get("date", "?")
        verdict = data.get("verdict", "?").upper()
        passc = data.get("pass_count", 0)
        failc = data.get("fail_count", 0)
        wall = data.get("wall_human") or _human_seconds(data.get("wall_seconds"))
        evidence = data.get("evidence", {}) or {}
        link = (
            f"[evidence]({evidence['offline_html']})"
            if evidence.get("offline_html")
            else "—"
        )
        rows.append(f"| {version} | {date} | {verdict} | {passc} / {failc} | {wall} | {link} |")
    return "\n".join(rows)


def define_env(env):  # noqa: D401 — mkdocs-macros entry point
    """Bind release helpers into the Jinja env used by mkdocs-macros."""
    repo_root = Path(env.project_dir)
    releases = _discover_releases(repo_root)
    current = releases[-1][1] if releases else {}

    env.variables["current_release"] = current
    env.variables["all_releases"] = [d for _, d in releases]

    @env.macro
    def render_current_release() -> str:
        if not current:
            return (
                '!!! warning "No release summary published yet"\n\n'
                "    No `releases/<version>/summary.json` was found in this repo.\n"
            )
        return _render_current_release(current)

    @env.macro
    def render_release_history() -> str:
        return _render_release_history(releases)

    @env.macro
    def current_release_field(field: str, default: str = "") -> str:
        return str(current.get(field, default))
