#!/usr/bin/env python3
"""How long can a genuinely busy session stay silent?

That number sets the floor for --quiet-after. Anything smaller and the panel
flips a working session to `unknown`; anything larger and an abandoned session
keeps showing `running` for that long.

Measures the gap between consecutive timestamped records strictly inside a turn
(after a typed prompt, before the turn_duration that closes it).
"""
import json
import os
from datetime import datetime

root = os.path.expanduser("~/.claude/projects")


def ts(r):
    s = r.get("timestamp")
    if not isinstance(s, str):
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None


in_turn, all_gaps = [], []
for d, _, ns in os.walk(root):
    for n in ns:
        if not n.endswith(".jsonl"):
            continue
        p = os.path.join(d, n)
        recs = []
        with open(p, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if line:
                    try:
                        recs.append(json.loads(line))
                    except json.JSONDecodeError:
                        pass
        busy = False
        prev = None
        for r in recs:
            t = ts(r)
            if r.get("type") == "user" and r.get("promptSource") in ("typed", "queued"):
                busy, prev = True, t
                continue
            if r.get("type") == "system" and r.get("subtype") in (
                    "turn_duration", "stop_hook_summary"):
                busy = False
            if t is None:
                continue
            if prev is not None:
                g = (t - prev).total_seconds()
                if 0 <= g < 86400:
                    all_gaps.append(g)
                    if busy:
                        in_turn.append((g, os.path.basename(p)[:8], r.get("type")))
            prev = t

for label, xs in (("inside a turn (session is busy)", [g for g, _, _ in in_turn]),
                  ("all consecutive records", all_gaps)):
    xs = sorted(xs)
    if not xs:
        continue
    def q(f):
        return xs[min(len(xs) - 1, int(len(xs) * f))]
    print(f"\n## {label}  n={len(xs)}")
    print(f"  p50={q(.5):.2f}s p90={q(.9):.2f}s p99={q(.99):.1f}s "
          f"p99.9={q(.999):.1f}s max={xs[-1]:.1f}s")
    for thresh in (10, 20, 30, 60, 120, 300):
        over = sum(1 for x in xs if x > thresh)
        print(f"  gaps > {thresh:>4}s: {over:5d}  ({100 * over / len(xs):.2f}%)")

print("\n## the ten longest silences while busy")
for g, f, t in sorted(in_turn, reverse=True)[:10]:
    print(f"  {g:8.0f}s  [{f}] next record type={t}")
