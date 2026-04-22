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

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
from a2a_harness import Harness, log, new_uuid


SCENARIO_ID = "39"
N = 6


def main() -> None:
    h = Harness.from_env(SCENARIO_ID)
    ns = f"scenario39-delta-{new_uuid()[:6]}"

    # Checkpoint: unix ms timestamp before partition.
    checkpoint_ms = int(time.time() * 1000)
    log(f"checkpoint = {checkpoint_ms}")

    log("suspending ai-memory on node-3")
    h.ssh_exec(h.node3_ip, "pgrep -f 'ai-memory serve' | xargs -r kill -STOP", timeout=15)
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
    h.ssh_exec(h.node3_ip, "pgrep -f 'ai-memory serve' | xargs -r kill -CONT", timeout=15)
    h.settle(4, reason="process resume")

    log(f"node-3 asks node-1 /api/v1/sync/since?after={checkpoint_ms}")
    # Use a plain curl from node-3 (we don't want to inject node-3's own view).
    curl = h._remote_curl_prefix()
    import shlex as _sh
    url = f"{h.remote_base_url()}/api/v1/sync/since?after={checkpoint_ms}&namespace={ns}"
    url_remote = url.replace("localhost", h.node1_ip if h.tls_mode == "off" else "localhost")
    # When TLS, --resolve maps to 127.0.0.1 which is LOCAL; we want node-1 via its public IP.
    if h.tls_mode == "off":
        cmd = f"curl -sS {_sh.quote(f'http://{h.node1_ip}:9077/api/v1/sync/since?after={checkpoint_ms}&namespace={ns}')}"
    else:
        cmd = (
            f"curl -sS --cacert /etc/ai-memory-a2a/tls/ca.pem "
            + ("--cert /etc/ai-memory-a2a/tls/client.pem --key /etc/ai-memory-a2a/tls/client.key "
               if h.tls_mode == "mtls" else "")
            + f"{_sh.quote(f'https://{h.node1_ip}:9077/api/v1/sync/since?after={checkpoint_ms}&namespace={ns}')}"
        )
    r = h.ssh_exec(h.node3_ip, cmd, timeout=30)
    delta_body = (r.stdout or "").strip()

    import json as _json
    returned = 0
    present = 0
    try:
        parsed = _json.loads(delta_body) if delta_body else {}
        if isinstance(parsed, dict):
            pool = parsed.get("memories") or parsed.get("rows") or parsed.get("delta") or []
            returned = len(pool)
            for m in pool:
                if isinstance(m, dict):
                    content = m.get("content") or ""
                    if any(marker in content for marker in markers):
                        present += 1
    except _json.JSONDecodeError:
        pass

    log(f"  /sync/since returned {returned} rows; {present}/{N} match our markers")

    reasons: list[str] = []
    passed = True
    if present != N:
        passed = False
        reasons.append(f"delta returned {present}/{N} expected markers — delta-sync incomplete")

    h.emit(
        passed=passed,
        reason="; ".join(reasons) if reasons else "",
        namespace=ns,
        checkpoint_ms=checkpoint_ms,
        expected_markers=N,
        markers_present=present,
        rows_returned=returned,
        reasons=reasons,
    )


if __name__ == "__main__":
    main()
