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

# Pair each printed transition with the nearest earlier write. Only appends that
# actually change the inferred state produce a line, so this is a subset.
seen = []
for line in out.splitlines():
    if line.startswith("[") and "->" in line:
        seen.append(line[1:line.index("]")])


def to_epoch(hms):
    lt = time.localtime()
    h, m, rest = hms.split(":")
    s, ms = rest.split(".")
    return time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, int(h), int(m),
                        int(s), 0, 0, -1)) + int(ms) / 1000


delays = []
for hms in seen:
    det = to_epoch(hms)
    earlier = [w for w in writes if w <= det]
    if earlier:
        delays.append(det - earlier[-1])
print(f"poll interval {interval}s, {len(writes)} appends, "
      f"{len(seen)} state transitions detected")
if delays:
    xs = sorted(delays)
    print(f"write -> transition printed: min={xs[0]:.3f}s "
          f"p50={xs[len(xs) // 2]:.3f}s max={xs[-1]:.3f}s")
print(f"expected bound: detection <= poll interval + stat cost = "
      f"~{interval:.3f}s worst case")
print(f"temp tree left at {root} (delete when done)")
