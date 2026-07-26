#!/usr/bin/env python3
"""Per-file presence of the marker record kinds we might depend on. Read-only.

The point: find out whether turn_duration / stop_hook_summary are universal or
only present in recent CLI versions / hook-configured setups.
"""
import json
import os
from collections import Counter

root = os.path.expanduser("~/.claude/projects")
files = [os.path.join(d, n) for d, _, ns in os.walk(root) for n in ns if n.endswith(".jsonl")]

hdr = (f"{'file':<21}{'recs':>6}{'versions':<20}{'turnDur':>8}{'stopHook':>9}"
       f"{'away':>6}{'mode':>6}{'sidech':>7}  entrypoint")
print(hdr)
print("-" * len(hdr))
for p in sorted(files):
    c = Counter()
    vers, ent = set(), set()
    side = 0
    with open(p, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue
            t = r.get("type")
            c[r.get("subtype") if t == "system" else t] += 1
            if r.get("version"):
                vers.add(r["version"])
            if r.get("entrypoint"):
                ent.add(r["entrypoint"])
            if r.get("isSidechain"):
                side += 1
    print(f"{os.path.basename(p)[:20]:<21}{sum(c.values()):>6}"
          f"{','.join(sorted(vers))[:19]:<20}{c['turn_duration']:>8}"
          f"{c['stop_hook_summary']:>9}{c['away_summary']:>6}{c['mode']:>6}"
          f"{side:>7}  {','.join(sorted(ent))}")
