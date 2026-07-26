#!/usr/bin/env python3
"""Mirror the REAL spool without consuming it.

The panel app is running and its own Spool actor drains every 200ms, deleting
each file as it reads it. To witness what the real installed configuration
actually delivers, copy first and never delete: this races the app's drain at
20ms and loses only if the app wins, which is itself visible as a gap.

    ./spoolwatch.py <seconds>
"""
import json
import os
import shutil
import sys
import time

SPOOL = os.path.expanduser("~/Library/Application Support/VirtualCodexMicro/hook-spool")
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "capture-real")

os.makedirs(OUT, exist_ok=True)
seen = set()
end = time.time() + float(sys.argv[1] if len(sys.argv) > 1 else 60)
index = []
while time.time() < end:
    try:
        names = os.listdir(SPOOL)
    except OSError:
        names = []
    for n in names:
        if not n.endswith(".json") or n in seen:
            continue
        seen.add(n)
        src = os.path.join(SPOOL, n)
        try:
            mtime = os.stat(src).st_mtime
            shutil.copy2(src, os.path.join(OUT, n))   # copy, never move
            with open(os.path.join(OUT, n), "rb") as f:
                header, _, body = f.read().partition(b"\n")
            p = json.loads(body)
            rec = {"file": n, "mtime": mtime, "header": header.decode(),
                   "event": p.get("hook_event_name"), "session": p.get("session_id"),
                   "cwd": p.get("cwd"), "tool": p.get("tool_name")}
            index.append(rec)
            print(f"{mtime:.3f} {rec['event']:22} cwd={rec['cwd']} {rec['header']}", flush=True)
        except (OSError, ValueError) as e:
            print(f"lost race on {n}: {e}", flush=True)
    time.sleep(0.02)

with open(os.path.join(OUT, "index.json"), "w") as f:
    json.dump(index, f, indent=2)
print(f"mirrored {len(index)} events to {OUT}")
