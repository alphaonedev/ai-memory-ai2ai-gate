#!/usr/bin/env python3
# Copyright 2026 AlphaOne LLC
# SPDX-License-Identifier: Apache-2.0
"""
Scenario 18 — Semantic query expansion.

alice + bob write semantically-related-but-keyword-distinct memories.
charlie issues /api/v1/recall with a semantic prompt and must see both
markers. Tests HNSW + embedder across the federated mesh.

RecallQuery reads the query string via `?context=<text>` (per
ai-memory-mcp src/models.rs:210).  Prior `?q=` silently left context=None
→ HTTP 400 → both markers counted as unseen.
"""

import sys
import urllib.parse
import pathlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
from a2a_harness import Harness, log, new_uuid


SCENARIO_ID = "18"


def main() -> None:
    h = Harness.from_env(SCENARIO_ID)
    ns = "scenario18-semantic"
    tag_a = f"alice-sunrise-{new_uuid()[:8]}"
    tag_b = f"bob-daybreak-{new_uuid()[:8]}"
    content_a = f"Lyra starts every sunrise by walking the hills before most people are awake. Marker={tag_a}"
    content_b = f"Before dawn Lyra enjoys brisk uphill strides along the ridge line trails. Marker={tag_b}"
    query = "morning outdoor exercise routine"

    log("alice writes A on node-1")
    h.write_memory(h.node1_ip, "ai:alice", ns, title="dawn-walk",
                   content=content_a, tier="long")
    log("bob writes B on node-2")
    h.write_memory(h.node2_ip, "ai:bob", ns, title="ridge-strides",
                   content=content_b, tier="long")
    h.settle(15, reason="fanout + index rebuild")

    log("charlie queries on node-3 with semantically-related prompt")
    q = urllib.parse.urlencode({"context": query, "namespace": ns, "limit": 20})
    _, resp = h.http_on(h.node3_ip, "GET", f"/api/v1/recall?{q}")
    memories = []
    if isinstance(resp, dict):
        memories = resp.get("memories") or []
    elif isinstance(resp, list):
        memories = resp

    def count_marker(tag: str) -> int:
        return sum(1 for m in memories
                   if isinstance(m, dict) and tag in (m.get("content") or ""))

    saw_a = count_marker(tag_a)
    saw_b = count_marker(tag_b)
    log(f"  charlie sees alice's memory: {saw_a} (expected >=1)")
    log(f"  charlie sees bob's memory: {saw_b} (expected >=1)")

    reasons: list[str] = []
    passed = True
    if saw_a < 1:
        passed = False
        reasons.append("semantic query did not surface alice's memory")
    if saw_b < 1:
        passed = False
        reasons.append("semantic query did not surface bob's memory")

    h.emit(
        passed=passed,
        reason="; ".join(reasons) if reasons else "",
        query=query,
        writers=[
            {"agent": "ai:alice", "marker": tag_a, "seen_by_charlie": saw_a},
            {"agent": "ai:bob", "marker": tag_b, "seen_by_charlie": saw_b},
        ],
        reasons=reasons,
    )


if __name__ == "__main__":
    main()
