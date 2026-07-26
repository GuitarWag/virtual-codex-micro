#!/usr/bin/env python3
"""Does anything get written to the transcript while a tool sits pending?

For every tool_use whose tool_result took > THRESH seconds, print the record
kinds that appear in between. If that list is always empty, the transcript is
silent during a permission prompt and 'running' vs 'needsInput' is unknowable
from the file alone.
"""
import json
import os
import sys
from datetime import datetime

THRESH = float(sys.argv[1]) if len(sys.argv) > 1 else 60.0
root = os.path.expanduser("~/.claude/projects")


def kind(rec):
    t = rec.get("type", "?")
    if t == "system":
        return f"system/{rec.get('subtype', '?')}"
    if t == "assistant":
        return f"assistant/{rec.get('message', {}).get('stop_reason')}"
    if t == "user":
        c = rec.get("message", {}).get("content")
        if isinstance(c, list) and c and isinstance(c[0], dict):
            return f"user/{c[0].get('type')}"
        return "user/prompt"
    return t


def ts(rec):
    s = rec.get("timestamp")
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None


files = [os.path.join(d, n) for d, _, ns in os.walk(root) for n in ns if n.endswith(".jsonl")]
rows = []
for p in sorted(files):
    recs = []
    with open(p, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if line:
                try:
                    recs.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    open_uses = {}  # id -> (index, name, ts)
    for i, r in enumerate(recs):
        if r.get("type") == "assistant":
            for b in r.get("message", {}).get("content", []):
                if isinstance(b, dict) and b.get("type") == "tool_use":
                    open_uses[b["id"]] = (i, b.get("name"), ts(r))
        elif r.get("type") == "user":
            c = r.get("message", {}).get("content")
            if isinstance(c, list):
                for b in c:
                    if isinstance(b, dict) and b.get("type") == "tool_result":
                        e = open_uses.pop(b.get("tool_use_id"), None)
                        if not e:
                            continue
                        i0, name, t0 = e
                        t1 = ts(r)
                        if not (t0 and t1):
                            continue
                        dt = (t1 - t0).total_seconds()
                        if dt < THRESH:
                            continue
                        between = [kind(x) for x in recs[i0 + 1:i]]
                        rows.append((dt, name, r.get("toolDenialKind"),
                                     b.get("is_error"), between,
                                     os.path.basename(p)[:8]))

rows.sort(reverse=True, key=lambda x: x[0])
print(f"# tool_use -> tool_result gaps over {THRESH}s: {len(rows)}\n")
for dt, name, denial, err, between, f in rows[:40]:
    b = ", ".join(between) if between else "<nothing written>"
    print(f"{dt:9.0f}s  {name:<22} denial={denial} err={err}  [{f}]\n           between: {b}")

print("\n# all user-rejected denials (any latency)")
for p in sorted(files):
    recs = []
    with open(p, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if line:
                try:
                    recs.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    for i, r in enumerate(recs):
        if r.get("toolDenialKind"):
            prev = [kind(x) for x in recs[max(0, i - 3):i]]
            print(f"  {os.path.basename(p)[:8]} kind={r['toolDenialKind']} "
                  f"preceded_by={prev}")
