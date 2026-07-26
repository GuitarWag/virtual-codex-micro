#!/usr/bin/env python3
"""Isolate the poller's own detection delay from the CLI's write latency.

Writes synthetic transcript records into a throwaway tree at known wall times
and reports how long watch.py's polling loop takes to see each one. Nothing
under ~/.claude is touched.

    python3 delay_test.py                 # 200ms poll, 20 appends
    python3 delay_test.py 0.05 40         # 50ms poll, 40 appends
"""
import json
import os
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone

interval = float(sys.argv[1]) if len(sys.argv) > 1 else 0.2
n = int(sys.argv[2]) if len(sys.argv) > 2 else 20
gap = max(interval * 3, 0.4)

root = tempfile.mkdtemp(prefix="vcm-delay-")
proj = os.path.join(root, "-tmp-fake-project")
os.makedirs(proj)
path = os.path.join(proj, "00000000-0000-0000-0000-000000000000.jsonl")
here = os.path.dirname(os.path.abspath(__file__))

# The watcher alternates the session between running and complete, so every
# append forces a transition line we can timestamp.
frames = [
    {"type": "assistant", "message": {"stop_reason": "tool_use",
     "content": [{"type": "tool_use", "id": "t%d", "name": "Bash"}]}},
    {"type": "user", "message": {"role": "user",
     "content": [{"type": "tool_result", "tool_use_id": "t%d"}]}},
    {"type": "assistant", "message": {"stop_reason": "end_turn",
     "content": [{"type": "text", "text": "ok"}]}},
]

with open(path, "w") as fh:
    fh.write(json.dumps({"type": "system", "subtype": "turn_duration",
                         "timestamp": datetime.now(timezone.utc)
                         .isoformat().replace("+00:00", "Z")}) + "\n")

env = dict(os.environ, VCM_PROJECTS=root, PYTHONUNBUFFERED="1")
watcher = subprocess.Popen(
    [sys.executable, os.path.join(here, "watch.py"), "--interval", str(interval),
     "--quiet-after", "3600", "--duration", str(n * gap + 4)],
    env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

time.sleep(1.0)  # let it finish its cold-start scan
writes = []
for i in range(n):
    f = json.loads(json.dumps(frames[i % 3]).replace("t%d", f"t{i // 3}"))
    f["timestamp"] = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    with open(path, "a") as fh:
        fh.write(json.dumps(f) + "\n")
        fh.flush()
        os.fsync(fh.fileno())
    writes.append(time.time())
    time.sleep(gap)

out, _ = watcher.communicate(timeout=60)
print(out)

# Pair each printed transition with the write that caused it, by clock order.
seen = []
for line in out.splitlines():
    if line.startswith("[") and "->" in line:
        seen.append(line[1:9])


def to_epoch(hms):
    lt = time.localtime()
    h, m, s = (int(x) for x in hms.split(":"))
    return time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, h, m, s, 0, 0, -1))


delays = []
for i, hms in enumerate(seen):
    if i < len(writes):
        delays.append(to_epoch(hms) - int(writes[i]))
print(f"poll interval {interval}s, {len(writes)} appends, "
      f"{len(seen)} transitions detected")
if delays:
    print(f"whole-second resolution delay: min={min(delays):.0f}s "
          f"max={max(delays):.0f}s  (transition log is second-granular; the "
          f"bound below is what matters)")
print(f"theoretical bound: detection <= poll interval + stat cost = "
      f"~{interval:.3f}s worst case")
print(f"temp tree left at {root} (delete when done)")
