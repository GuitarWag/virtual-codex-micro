#!/usr/bin/env python3
"""Print redacted structural samples of interesting record kinds. Read-only.

Redaction: every string value is replaced by <str:len> unless its key is in KEEP.
That keeps the structure and the discriminating enum-ish fields, and drops all
prose, code, paths and anything that could be a secret.
"""
import json
import os
import sys
from collections import defaultdict

root = os.path.expanduser("~/.claude/projects")

KEEP = {
    "type", "subtype", "role", "stop_reason", "stop_sequence", "operation",
    "permissionMode", "promptSource", "origin", "toolDenialKind", "level",
    "isMeta", "isSidechain", "userType", "entrypoint", "name", "is_error",
    "interrupted", "isImage", "noOutputExpected", "hasOutput",
    "preventedContinuation", "stopReason", "hookCount", "messageCount",
    "durationMs", "isApiErrorMessage", "apiErrorStatus", "userModified",
    "isCompactSummary", "isVisibleInTranscriptOnly", "isSnapshotUpdate",
    "status", "success", "code", "retryAttempt", "maxRetries", "retryInMs",
}


def redact(o, depth=0):
    if depth > 4:
        return "<deep>"
    if isinstance(o, dict):
        out = {}
        for k, v in o.items():
            if k in KEEP:
                out[k] = redact(v, depth + 1) if isinstance(v, (dict, list)) else v
            elif isinstance(v, (dict, list)):
                out[k] = redact(v, depth + 1)
            elif isinstance(v, str):
                out[k] = f"<str:{len(v)}>"
            else:
                out[k] = v
        return out
    if isinstance(o, list):
        return [redact(x, depth + 1) for x in o[:3]] + (["<...>"] if len(o) > 3 else [])
    if isinstance(o, str):
        return f"<str:{len(o)}>"
    return o


def kind(rec):
    t = rec.get("type", "?")
    if t == "system":
        return f"system/{rec.get('subtype', '?')}"
    if t == "user":
        c = rec.get("message", {}).get("content")
        if isinstance(c, list) and c and isinstance(c[0], dict):
            return f"user/{c[0].get('type')}" + ("/denied" if rec.get("toolDenialKind") else "")
        return "user/prompt"
    if t == "assistant":
        if rec.get("isApiErrorMessage"):
            return "assistant/api_error"
        return f"assistant/{rec.get('message', {}).get('stop_reason')}"
    return t


want = sys.argv[1:] or None
seen = defaultdict(int)
LIMIT = 1

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
                continue
            k = kind(rec)
            if want and k not in want:
                continue
            if seen[k] >= LIMIT:
                continue
            seen[k] += 1
            print(f"\n=== {k}")
            print(json.dumps(redact(rec), indent=1)[:2600])
