#!/usr/bin/env python3
"""Value domains for attachment.type / hookEvent and the stop_details field.

Point: hook results land in the transcript as `attachment` records, so check
whether any of them name a Notification-style event we could use as a
'needs input' signal without installing our own listener.
"""
import json
import os
from collections import Counter

root = os.path.expanduser("~/.claude/projects")
atypes, hevents, hnames, stopdet, meta = Counter(), Counter(), Counter(), Counter(), Counter()

for d, _, ns in os.walk(root):
    for n in ns:
        if not n.endswith(".jsonl"):
            continue
        with open(os.path.join(d, n), encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    r = json.loads(line)
                except json.JSONDecodeError:
                    continue
                a = r.get("attachment")
                if isinstance(a, dict):
                    atypes[a.get("type")] += 1
                    if a.get("hookEvent"):
                        hevents[a["hookEvent"]] += 1
                    if a.get("hookName"):
                        hnames[a["hookName"]] += 1
                sd = r.get("message", {}).get("stop_details") if isinstance(
                    r.get("message"), dict) else None
                if sd is not None:
                    stopdet[json.dumps(sd, sort_keys=True)[:80]] += 1
                for k in ("isMeta", "isCompactSummary", "isVisibleInTranscriptOnly"):
                    if r.get(k):
                        meta[f"{r.get('type')}.{k}"] += 1

for label, c in (("attachment.type", atypes), ("attachment.hookEvent", hevents),
                 ("attachment.hookName", hnames), ("message.stop_details", stopdet),
                 ("meta flags", meta)):
    print(f"\n## {label}")
    for k, v in c.most_common(20):
        print(f"  {v:6d}  {k}")
