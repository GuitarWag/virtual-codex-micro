#!/usr/bin/env python3
"""Schema survey of Claude Code session transcripts. Read-only.

Usage: python3 analyse.py [~/.claude/projects]
Prints record-type counts, key sets per type, and the tail shape of each session.
"""
import json
import os
import sys
from collections import Counter, defaultdict

root = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else "~/.claude/projects")

types = Counter()
keys_by_type = defaultdict(Counter)
content_blocks = Counter()
stop_reasons = Counter()
subtypes = Counter()
tool_names = Counter()
errorish = Counter()
files = []

for dirpath, _, names in os.walk(root):
    for n in names:
        if n.endswith(".jsonl"):
            files.append(os.path.join(dirpath, n))

for path in sorted(files):
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                types["<unparseable>"] += 1
                continue
            t = rec.get("type", "<no type>")
            types[t] += 1
            for k in rec:
                keys_by_type[t][k] += 1
            if "subtype" in rec:
                subtypes[f"{t}/{rec['subtype']}"] += 1
            msg = rec.get("message")
            if isinstance(msg, dict):
                for k in msg:
                    keys_by_type[f"{t}.message"][k] += 1
                if msg.get("stop_reason") is not None:
                    stop_reasons[f"{t}:{msg['stop_reason']}"] += 1
                c = msg.get("content")
                if isinstance(c, list):
                    for b in c:
                        if isinstance(b, dict):
                            bt = b.get("type")
                            content_blocks[f"{t}:{bt}"] += 1
                            if bt in ("tool_use", "tool_result", "server_tool_use"):
                                if b.get("name"):
                                    tool_names[b["name"]] += 1
                            if bt == "tool_result" and b.get("is_error"):
                                errorish["tool_result.is_error"] += 1
                elif isinstance(c, str):
                    content_blocks[f"{t}:<string>"] += 1
            if rec.get("isApiErrorMessage"):
                errorish["isApiErrorMessage"] += 1
            if rec.get("toolUseResult") is not None:
                tur = rec["toolUseResult"]
                if isinstance(tur, dict):
                    for k in tur:
                        keys_by_type["<toolUseResult>"][k] += 1

print(f"# files: {len(files)}  records: {sum(types.values())}\n")
print("## record types")
for t, c in types.most_common():
    print(f"{c:8d}  {t}")
print("\n## subtypes")
for t, c in subtypes.most_common(30):
    print(f"{c:8d}  {t}")
print("\n## content block types")
for t, c in content_blocks.most_common(30):
    print(f"{c:8d}  {t}")
print("\n## stop_reason")
for t, c in stop_reasons.most_common():
    print(f"{c:8d}  {t}")
print("\n## error signals")
for t, c in errorish.most_common():
    print(f"{c:8d}  {t}")
print("\n## keys per type (count of records having the key)")
for t in sorted(keys_by_type):
    print(f"\n### {t}")
    for k, c in keys_by_type[t].most_common():
        print(f"  {c:8d}  {k}")
print("\n## tool names (top 25)")
for t, c in tool_names.most_common(25):
    print(f"{c:8d}  {t}")
