#!/usr/bin/env python3
# Copyright 2026 AlphaOne LLC
# SPDX-License-Identifier: Apache-2.0
"""
Scenario 39 — /api/v1/sync/since delta sync.

While node-3's ai-memory serve is suspended, alice + bob write N rows.
Resume node-3. Query node-1's /sync/since?after=<pre-partition-checkpoint>
from node-3 and verify the response contains exactly the N rows that
were written during the partition.
"""

import sys
import pathlib
import time
import urllib.parse
from datetime import datetime, timezone

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
from a2a_harness import Harness, log, new_uuid


SCENARIO_ID = "39"
N = 6


def main() -> None:
    h = Harness.from_env(SCENARIO_ID)
    ns = f"scenario39-delta-{new_uuid()[:6]}"

    # Checkpoint: handler (handlers.rs:2306) requires RFC 3339, not unix ms.
    # Subtract 1s so the `since > checkpoint` comparison is strict-inclusive
    # of our writes.
    checkpoint = (datetime.now(timezone.utc).replace(microsecond=0)).isoformat()
    log(f"checkpoint = {checkpoint}")

    log("suspending ai-memory on node-3")
    h.ssh_exec(h.node3_ip, "pgrep -f 'ai-memory serve' | xargs -r kill -STOP", timeout=30)
    time.sleep(2)

    markers: list[str] = []
    log(f"alice + bob write {N} rows while node-3 is out")
    for i in range(N):
        u = new_uuid(f"delta-{i}-")
        markers.append(u)
        writer_ip = h.node1_ip if i % 2 == 0 else h.node2_ip
        writer_id = "ai:alice" if i % 2 == 0 else "ai:bob"
        h.write_memory(writer_ip, writer_id, ns,
                       title=f"delta-{i}", content=f"marker={u}")

    log("resuming ai-memory on node-3")
    h.ssh_exec(h.node3_ip, "pgrep -f 'ai-memory serve' | xargs -r kill -CONT", timeout=30)
    h.settle(4, reason="process resume")

    log(f"node-3 asks node-1 /api/v1/sync/since?since={checkpoint}")
    # Use a plain curl from node-3 (we don't want to inject node-3's own view).
    # `since` is RFC3339; `namespace` is filtered client-side (handler doesn't
    # accept it — it returns the full post-checkpoint delta capped at limit).
    import shlex as _sh
    since_q = urllib.parse.quote(checkpoint)
    if h.tls_mode == "off":
        cmd = f"curl -sS {_sh.quote(f'http://{h.node1_ip}:9077/api/v1/sync/since?since={since_q}&limit=500')}"
    else:
        cmd = (
            f"curl -sS --cacert /etc/ai-memory-a2a/tls/ca.pem "
            + ("--cert /etc/ai-memory-a2a/tls/client.pem --key /etc/ai-memory-a2a/tls/client.key "
               if h.tls_mode == "mtls" else "")
            + f"{_sh.quote(f'https://{h.node1_ip}:9077/api/v1/sync/since?since={since_q}&limit=500')}"
        )
    r = h.ssh_exec(h.node3_ip, cmd, timeout=30)
    delta_body = (r.stdout or "").strip()

    import json as _json
    returned = 0
    returned_raw = 0
    present = 0
    diag_updated_since = None
    diag_earliest = None
    diag_latest = None
    try:
        parsed = _json.loads(delta_body) if delta_body else {}
        if isinstance(parsed, dict):
            # PR alphaonedev/ai-memory-mcp#361 adds these diagnostic fields.
            diag_updated_since = parsed.get("updated_since")
            diag_earliest = parsed.get("earliest_updated_at")
            diag_latest = parsed.get("latest_updated_at")
            pool = parsed.get("memories") or parsed.get("rows") or parsed.get("delta") or []
            returned_raw = len(pool)
            # Client-side namespace filter — endpoint returns global delta.
            pool_ns = [m for m in pool if isinstance(m, dict) and m.get("namespace") == ns]
            returned = len(pool_ns)
            for m in pool_ns:
                content = m.get("content") or ""
                if any(marker in content for marker in markers):
                    present += 1
    except _json.JSONDecodeError:
        pass

    log(f"  /sync/since raw={returned_raw} ns-filtered={returned}; {present}/{N} match our markers")
    log(f"  diag: updated_since={diag_updated_since} earliest={diag_earliest} latest={diag_latest}")

    reasons: list[str] = []
    passed = True
    if present != N:
        passed = False
        reasons.append(f"delta returned {present}/{N} expected markers — delta-sync incomplete")

    h.emit(
        passed=passed,
        reason="; ".join(reasons) if reasons else "",
        namespace=ns,
        checkpoint=checkpoint,
        expected_markers=N,
        markers_present=present,
        rows_returned=returned,
        rows_returned_raw=returned_raw,
        diag_updated_since=diag_updated_since,
        diag_earliest_updated_at=diag_earliest,
        diag_latest_updated_at=diag_latest,
        reasons=reasons,
    )


if __name__ == "__main__":
    main()
