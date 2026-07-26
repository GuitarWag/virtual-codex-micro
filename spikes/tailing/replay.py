#!/usr/bin/env python3
"""Offline accuracy replay: infer() against look-ahead ground truth.

Walks every transcript record by record. At each step it calls the same infer()
the watcher uses, seeing only the prefix, with the clock pinned to just before
the next record arrives — the worst-case observation moment. Truth comes from
looking forward in the file, which the live watcher cannot do.

Truth labels (objective, from the records themselves):
  needsInput  a tool_use is outstanding and its eventual result carries
              toolDenialKind (the approval prompt was open), or the outstanding
              tool is AskUserQuestion
  running     a tool_use is outstanding that later resolved normally, or the
              turn has not yet been closed by turn_duration/stop_hook_summary
  idle        the turn is closed and the next event is a fresh user prompt
  error       the record stream shows an API error at this point

`unknown` from infer() is scored as an abstention, not an error: the panel
renders a grey hatch and the user learns nothing, which is the intended
behaviour. A confidently wrong colour is what we count as a failure.

    python3 replay.py [quiet_after]
"""
import json
import os
import sys
from collections import Counter
from datetime import timedelta

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from watch import NOISE, infer, parse_ts  # noqa: E402

QUIET = float(sys.argv[1]) if len(sys.argv) > 1 else 60.0
WINDOW = 60  # records of context handed to infer(), same as the watcher keeps
root = os.path.expanduser("~/.claude/projects")

TURN_END = {"turn_duration", "stop_hook_summary"}
SAFE = {"unknown"}
# States that are compatible enough that calling one the other is not a lie.
EQUIV = {("complete", "idle"), ("idle", "complete")}

conf = Counter()
examples = {}
wrong_by_file = Counter()
entry_by_file = {}

for d, _, ns in os.walk(root):
    for n in ns:
        if not n.endswith(".jsonl"):
            continue
        path = os.path.join(d, n)
        recs = []
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if line:
                    try:
                        recs.append(json.loads(line))
                    except json.JSONDecodeError:
                        pass

        # Pre-index: tool_use id -> (index it was requested, denial kind, name)
        req, denial, tname, resolved_at = {}, {}, {}, {}
        for i, r in enumerate(recs):
            if r.get("type") == "assistant":
                for b in r.get("message", {}).get("content", []) or []:
                    if isinstance(b, dict) and b.get("type") == "tool_use":
                        req[b["id"]] = i
                        tname[b["id"]] = b.get("name")
            elif r.get("type") == "user":
                c = r.get("message", {}).get("content")
                if isinstance(c, list):
                    for b in c:
                        if isinstance(b, dict) and b.get("type") == "tool_result":
                            tid = b.get("tool_use_id")
                            if tid in req and tid not in resolved_at:
                                denial[tid] = r.get("toolDenialKind")
                                resolved_at[tid] = i

        resolved = {tid: (req[tid], j) for tid, j in resolved_at.items()}

        for i in range(len(recs)):
            prefix = recs[max(0, i - WINDOW):i + 1]
            if not any(r.get("type") not in NOISE for r in prefix):
                continue
            nxt = next((parse_ts(r.get("timestamp")) for r in recs[i + 1:]
                        if parse_ts(r.get("timestamp"))), None)
            if nxt is None:
                continue
            clock = nxt - timedelta(milliseconds=1)

            # --- truth ---
            open_now = [tid for tid, (a, b) in resolved.items() if a <= i < b]
            truth = None
            if any(r.get("isApiErrorMessage") for r in recs[max(0, i - 1):i + 1]) or \
               (recs[i].get("type") == "system" and recs[i].get("subtype") == "api_error"):
                truth = "error"
            elif open_now:
                if any(denial.get(t) for t in open_now) or \
                   all(tname.get(t) == "AskUserQuestion" for t in open_now):
                    truth = "needsInput"
                else:
                    truth = "running"
            else:
                closed = any(r.get("type") == "system" and r.get("subtype") in TURN_END
                             for r in recs[i:i + 1])
                later_prompt = next((r for r in recs[i + 1:]
                                     if r.get("type") not in NOISE), None)
                if closed or (later_prompt is not None
                              and later_prompt.get("promptSource") in ("typed", "queued")):
                    truth = "idle"
                else:
                    truth = "running"

            got, c, why = infer(prefix, QUIET, now=clock)
            if got not in SAFE and got != truth and (truth, got) not in EQUIV:
                wrong_by_file[os.path.basename(path)[:8]] += 1
            entry_by_file.setdefault(os.path.basename(path)[:8],
                                     recs[0].get("entrypoint", "?"))
            key = (truth, got)
            conf[key] += 1
            if got not in SAFE and got != truth and key not in EQUIV \
                    and key not in examples:
                examples[key] = f"[{os.path.basename(path)[:8]}#{i}] {why}"

total = sum(conf.values())
correct = sum(v for (t, g), v in conf.items() if t == g or (t, g) in EQUIV)
abstain = sum(v for (t, g), v in conf.items() if g in SAFE and t != g)
wrong = total - correct - abstain

print(f"quiet_after={QUIET}s  observations={total}")
print(f"  correct   {correct:6d}  {100 * correct / total:5.1f}%")
print(f"  abstained {abstain:6d}  {100 * abstain / total:5.1f}%  (rendered `unknown`)")
print(f"  WRONG     {wrong:6d}  {100 * wrong / total:5.1f}%")

print("\ntruth -> inferred")
for (t, g), v in sorted(conf.items(), key=lambda kv: -kv[1]):
    tag = "ok" if t == g or (t, g) in EQUIV else ("abstain" if g in SAFE else "WRONG")
    print(f"  {t:<11} -> {g:<11} {v:6d}  {tag}")

print("\nwrong observations by file")
for f, v in wrong_by_file.most_common(10):
    print(f"  {v:5d}  {f}  entrypoint={entry_by_file.get(f)}")

if examples:
    print("\nfirst example of each wrong pairing")
    for k, v in examples.items():
        print(f"  {k[0]} -> {k[1]}: {v}")
