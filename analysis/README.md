# Per-campaign AI NHI analysis

Every A2A campaign must leave a narrative trail alongside the
raw JSON artifacts. This directory is where that trail lives,
using the same data-driven insight pattern the ai-memory-ship-
gate established.

## The data contract

`run-insights.json` is a map keyed by `campaign-id`. Every entry
has the same schema — the structure that the evidence HTML
generator reads to render tri-audience analysis on every per-run
page.

```json
{
  "my-first-a2a-run": {
    "headline": "One-sentence verdict",
    "verdict": "Short paragraph: what the run demonstrated.",
    "what_it_tested": "Which scenarios, against which ai-memory ref.",
    "what_it_proved": "Concretely proved / disproved.",
    "for_non_technical": "Plain-language framing.",
    "for_c_level": "Risk, cost, audit, velocity.",
    "for_sme": "File paths, commits, invariants, mechanisms.",
    "bugs": [
      {
        "title": "What broke",
        "impact": "Consequence",
        "root_cause": "Technical explanation",
        "fixed_in": [{"label": "...", "url": "..."}]
      }
    ],
    "next_run_change": "What lands between this run and the next."
  }
}
```

## Per-run workflow

Every campaign MUST be followed by an insight update before the
next one is dispatched.

1. Read the artifacts in `runs/<campaign-id>/`.
2. Append an entry to `run-insights.json` with every field
   filled. Do not skip audiences.
3. Link each bug to its fix (issue or PR URL).
4. Regenerate the evidence HTML:
   ```sh
   ./scripts/generate_run_html.sh runs/<campaign-id>
   ```
5. Commit + push. The Pages workflow redeploys the dashboard.

A run without updated narrative is a partial submission. The
Pages site will show a "No narrative recorded" placeholder — the
same anti-pattern that prompted this documentation. Treat that
placeholder as a blocker on the next run.

## Why three audiences

Correctness claims land differently depending on the reader. A
C-level reviewer needs a decision-support view; an end user needs
trust evidence; an engineer needs the mechanistic why. Giving
each audience their own framing is what turns evidence into
decision support.

If any audience field is empty, the analysis is incomplete.
