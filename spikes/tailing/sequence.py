#!/usr/bin/env python3
"""Turn-boundary and tail-shape analysis of Claude Code transcripts. Read-only.

Answers:
  - what record kinds follow an assistant end_turn / tool_use
  - what the last records of each session file look like (the cold-start view)
  - whether every tool_use gets a tool_result, and how long resolution takes
  - value domains of permissionMode / promptSource / operation
"""
import json
import os
from collections import Counter, defaultdict
from datetime import datetime, timezone

root = os.path.expanduser("~/.claude/projects")


def kind(rec):
    t = rec.get("type", "?")
    if t == "system":
        return f"system/{rec.get('subtype', '?')}"
    if t == "assistant":
        if rec.get("isApiErrorMessage"):
            return "assistant/api_error"
        blocks = {b.get("type") for b in rec.get("message", {}).get("content", [])
                  if isinstance(b, dict)}
        sr = rec.get("message", {}).get("stop_reason")
        return f"assistant/{sr}" + ("+text" if "text" in blocks and sr == "tool_use" else "")
    if t == "user":
        c = rec.get("message", {}).get("content")
        if isinstance(c, list) and c and isinstance(c[0], dict):
            k = f"user/{c[0].get('type')}"
            if rec.get("toolDenialKind"):
                k += f"[{rec['toolDenialKind']}]"
            elif c[0].get("is_error"):
                k += "[err]"
            return k
        return f"user/prompt[{rec.get('promptSource', '?')}]"
    if t == "queue-operation":
        return f"queue-operation/{rec.get('operation')}"
    return t


def ts(rec):
    s = rec.get("timestamp")
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None


follows = defaultdict(Counter)
tails = []
pending_stats = Counter()
resolve_secs = []
domains = defaultdict(Counter)
sidechain_kinds = Counter()

files = []
for dirpath, _, names in os.walk(root):
    for n in names:
        if n.endswith(".jsonl"):
            files.append(os.path.join(dirpath, n))

for path in sorted(files):
    recs = []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                recs.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    if not recs:
        tails.append((path, 0, []))
        continue

    kinds = [kind(r) for r in recs]
    for a, b in zip(kinds, kinds[1:]):
        follows[a][b] += 1

    for r in recs:
        if r.get("isSidechain"):
            sidechain_kinds[kind(r)] += 1
        for f in ("permissionMode", "promptSource", "operation", "level", "entrypoint",
                  "userType", "toolDenialKind"):
            if f in r and isinstance(r[f], str):
                domains[f][r[f]] += 1
        if r.get("type") == "permission-mode":
            domains["permission-mode.permissionMode"][r.get("permissionMode")] += 1

    # tool_use -> tool_result pairing and latency
    uses = {}
    for r in recs:
        if r.get("type") == "assistant":
            for b in r.get("message", {}).get("content", []):
                if isinstance(b, dict) and b.get("type") == "tool_use":
                    uses[b["id"]] = (b.get("name"), ts(r))
        elif r.get("type") == "user":
            c = r.get("message", {}).get("content")
            if isinstance(c, list):
                for b in c:
                    if isinstance(b, dict) and b.get("type") == "tool_result":
                        tid = b.get("tool_use_id")
                        if tid in uses:
                            name, t0 = uses.pop(tid)
                            t1 = ts(r)
                            if t0 and t1:
                                resolve_secs.append(((t1 - t0).total_seconds(), name))
                            pending_stats["resolved"] += 1
                        else:
                            pending_stats["result_without_use"] += 1
    pending_stats["never_resolved"] += len(uses)
    if uses:
        pending_stats[f"file_with_unresolved:{os.path.basename(path)[:8]}"] = len(uses)

    mtime = os.path.getmtime(path)
    tails.append((path, len(recs), kinds[-6:], mtime, ts(recs[-1])))

print("## what follows each kind (top 6 successors)")
for a in sorted(follows):
    tot = sum(follows[a].values())
    succ = ", ".join(f"{b} {c}" for b, c in follows[a].most_common(6))
    print(f"\n{a}  (n={tot})\n    -> {succ}")

print("\n\n## tail shape of every session file (last 6 record kinds)")
for t in sorted(tails, key=lambda x: -x[1]):
    path, n, kinds = t[0], t[1], t[2]
    last_ts = t[4] if len(t) > 4 else None
    print(f"\n{os.path.basename(path)}  records={n}")
    print(f"    last_ts={last_ts}")
    print(f"    {' | '.join(kinds)}")

print("\n\n## tool_use resolution")
for k, v in pending_stats.most_common():
    print(f"  {v:6d}  {k}")
if resolve_secs:
    xs = sorted(s for s, _ in resolve_secs)
    def pct(p):
        return xs[min(len(xs) - 1, int(len(xs) * p))]
    print(f"  latency s: p50={pct(.5):.1f} p90={pct(.9):.1f} p99={pct(.99):.1f} max={xs[-1]:.1f}")
    print("  slowest 10: " + ", ".join(f"{s:.0f}s/{n}" for s, n in
                                       sorted(resolve_secs, reverse=True)[:10]))

print("\n## value domains")
for f in sorted(domains):
    print(f"  {f}: {dict(domains[f])}")

print("\n## kinds seen with isSidechain=true")
for k, v in sidechain_kinds.most_common():
    print(f"  {v:6d}  {k}")
