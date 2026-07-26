#!/usr/bin/env python3
"""Timestamp each line of claude's --output-format stream-json on arrival.

Gives an independent, external ground-truth clock for "when did the session
actually transition", to compare against hook receipt times in events.jsonl.

Usage:  claude -p ... --output-format stream-json --verbose | stamper.py stream.jsonl
"""

import json
import sys
import time

out = open(sys.argv[1] if len(sys.argv) > 1 else "stream.jsonl", "a")
out.write(json.dumps({"t_ms": round(time.time() * 1000, 1), "_marker": "spawned"}) + "\n")
for line in sys.stdin:
    t = round(time.time() * 1000, 1)
    line = line.strip()
    if not line:
        continue
    try:
        ev = json.loads(line)
    except ValueError:
        out.write(json.dumps({"t_ms": t, "_raw": line[:400]}) + "\n")
        out.flush()
        continue
    rec = {
        "t_ms": t,
        "type": ev.get("type"),
        "subtype": ev.get("subtype"),
        "session_id": ev.get("session_id"),
    }
    msg = ev.get("message") or {}
    if isinstance(msg, dict):
        blocks = msg.get("content")
        if isinstance(blocks, list):
            rec["blocks"] = [
                b.get("name") if b.get("type") == "tool_use" else b.get("type")
                for b in blocks
                if isinstance(b, dict)
            ]
            for b in blocks:
                if isinstance(b, dict) and b.get("type") == "text" and b.get("text"):
                    rec["text"] = b["text"][:200]
    if ev.get("type") == "hook_event":
        rec["hook"] = ev.get("hook_event_name") or ev.get("hook_name")
        rec["raw"] = {k: v for k, v in ev.items() if k not in ("type",)}
    out.write(json.dumps(rec) + "\n")
    out.flush()
out.write(json.dumps({"t_ms": round(time.time() * 1000, 1), "_marker": "eof"}) + "\n")
out.flush()
