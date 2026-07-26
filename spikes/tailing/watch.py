#!/usr/bin/env python3
"""Tail Claude Code session transcripts and infer AgentState. Read-only.

    python3 watch.py --snapshot          # one-shot state of every session
    python3 watch.py                     # follow, print transitions + delay stats
    python3 watch.py --selftest          # assert-based check of the inference
    python3 watch.py --interval 0.1 --quiet-after 20

Liveness comes from `ps`, not the file: the transcript is append-and-close, so
nothing holds an open handle and lsof tells you nothing (verified).

ponytail: polls stat() instead of FSEvents. 31 files at 200ms is ~150 stat/s,
noise on any Mac. Swap in FSEventStreamCreate if the session count reaches the
hundreds or the interval needs to go below ~50ms.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone

PROJECTS = os.environ.get("VCM_PROJECTS") or os.path.expanduser("~/.claude/projects")

# Records that carry no turn-state meaning. Written at unpredictable times,
# including in the middle of a pending tool call, so they must never be read as
# a turn boundary (verified: a 466s Bash had the whole title cluster inside it).
NOISE = {
    "ai-title", "custom-title", "agent-name", "mode", "permission-mode",
    "last-prompt", "file-history-snapshot", "file-history-delta", "pr-link",
    "attachment",
}
# Window read on cold start. A tool_use older than this loses its pairing.
TAIL_BYTES = 1 << 20

CONF_HIGH, CONF_MED, CONF_LOW, CONF_NONE = "high", "medium", "low", "none"


def now_hms():
    """Millisecond wall clock. The transition log doubles as the measurement
    record for detection delay, so seconds are not enough resolution."""
    return datetime.now().strftime("%H:%M:%S.%f")[:-3]


def parse_ts(s):
    if not isinstance(s, str):
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None


def infer(records, quiet_after, now=None):
    """(state, confidence, reason) from a list of parsed records, oldest first.

    Pure. Everything time-dependent comes in via `now` and the record
    timestamps, so the selftest can pin the clock.
    """
    now = now or datetime.now(timezone.utc)
    events = [r for r in records if r.get("type") not in NOISE]
    if not events:
        return "unknown", CONF_NONE, "no state-bearing records"

    # Age of the newest record that actually has a timestamp. Many tail records
    # (ai-title, mode, permission-mode, last-prompt) have none at all.
    last_ts = next((parse_ts(r.get("timestamp")) for r in reversed(records)
                    if parse_ts(r.get("timestamp"))), None)
    age = (now - last_ts).total_seconds() if last_ts else None
    quiet = age is not None and age > quiet_after

    # Unresolved tool_use: the assistant asked for a tool and no tool_result
    # for that id ever arrived.
    pending = {}
    for r in events:
        if r.get("type") == "assistant":
            for b in r.get("message", {}).get("content", []) or []:
                if isinstance(b, dict) and b.get("type") == "tool_use":
                    pending[b.get("id")] = b.get("name")
        elif r.get("type") == "user":
            c = r.get("message", {}).get("content")
            if isinstance(c, list):
                for b in c:
                    if isinstance(b, dict) and b.get("type") == "tool_result":
                        pending.pop(b.get("tool_use_id"), None)

    last = events[-1]
    t = last.get("type")
    sub = last.get("subtype")

    # Hard error: the API itself failed. Distinct from a failed tool call.
    if last.get("isApiErrorMessage") or (t == "system" and sub == "api_error"):
        return "error", CONF_HIGH, f"api error ({last.get('apiErrorStatus', sub)})"

    if pending:
        names = set(pending.values())
        # AskUserQuestion is a genuine 'waiting for the human' tool, and the
        # name is in the tool_use block, so this one case is knowable.
        if names <= {"AskUserQuestion"}:
            return "needsInput", CONF_HIGH, "pending AskUserQuestion"
        if quiet:
            # Cannot tell a slow tool from a permission prompt. Nothing is
            # written while either is outstanding (verified over 76 gaps >30s).
            return "unknown", CONF_NONE, (
                f"pending {sorted(names)} quiet {age:.0f}s — slow tool or "
                f"approval prompt, indistinguishable")
        return "running", CONF_MED, f"pending {sorted(names)}"

    # Turn boundary. turn_duration is emitted at the end of every CLI turn;
    # stop_hook_summary only when the user has Stop hooks configured.
    if t == "system" and sub in ("turn_duration", "stop_hook_summary", "away_summary"):
        if quiet:
            return "idle", CONF_MED, f"turn ended, quiet {age:.0f}s"
        return "complete", CONF_MED, f"turn ended ({sub})"

    if t == "assistant":
        sr = last.get("message", {}).get("stop_reason")
        if sr == "end_turn":
            # end_turn is NOT a turn boundary. 115 of 372 end_turns in the
            # corpus are followed immediately by another end_turn: the CLI
            # emits one per assistant message, and a turn can hold several.
            # Only turn_duration closes a turn. So a fresh end_turn is exactly
            # the ambiguity this state model exists for.
            if quiet:
                return "idle", CONF_LOW, f"end_turn then {age:.0f}s silence"
            return "unknown", CONF_NONE, (
                "end_turn with no turn_duration — finished, or mid-turn "
                "between assistant messages")
        if sr is None:
            # Streaming chunk mid-response.
            return "running", CONF_MED, "assistant chunk, stop_reason null"
        return "running", CONF_LOW, f"assistant stop_reason={sr}"

    if t == "user":
        # A tool_result with no pending tool_use left means the assistant is
        # about to be called again. is_error here is routine, not a session
        # error — the agent reads the failure and carries on.
        if quiet:
            return "unknown", CONF_NONE, f"mid-turn record, quiet {age:.0f}s"
        return "running", CONF_MED, "mid-turn user record"

    if t == "queue-operation":
        return "running", CONF_LOW, f"queue {last.get('operation')}"

    return "unknown", CONF_NONE, f"unhandled tail record {t}/{sub}"


def session_ids(recs, path):
    """(display_id, {candidate ids}) for joining a transcript to a live process.

    Two differently-spelled fields, two different meanings:
      sessionId   camelCase. Transcript identity; equals the filename for main
                  transcripts, the parent's id inside subagents/.
      session_id  snake_case. The id of the process that actually wrote the
                  record. On a resumed or forked session this is a *different*
                  uuid — a29ca670....jsonl carries records stamped 6e5140c0,
                  which is the id the live `claude --session-id` argv shows.

    Matching a running process on the filename alone reports a live resumed
    session as dead, so try every candidate.
    """
    base = os.path.basename(path)[:-6]
    cands, display = {base}, None
    for r in reversed(recs):
        for k in ("session_id", "sessionId"):
            v = r.get(k)
            if v:
                cands.add(v)
                if k == "session_id" and display is None:
                    display = v  # newest writer wins
    return display or base, cands


def live_sessions():
    """session-id -> pid for every running claude CLI. Requires --session-id in
    argv; a bare `claude` launched by hand has none and is invisible here."""
    out = {}
    try:
        ps = subprocess.run(["ps", "-Ao", "pid=,command="], capture_output=True,
                            text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return out
    for line in ps.splitlines():
        if "/claude " not in line and not re.search(r"/claude$", line):
            continue
        m = re.search(r"--session-id\s+([0-9a-f-]{36})", line)
        if m:
            out[m.group(1)] = int(line.split(None, 1)[0])
    return out


def read_tail(path, offset=None):
    """Return (records, new_offset). offset=None means cold start: last TAIL_BYTES."""
    size = os.path.getsize(path)
    with open(path, "rb") as fh:
        if offset is None:
            start = max(0, size - TAIL_BYTES)
            fh.seek(start)
            data = fh.read()
            if start:  # drop the partial first line
                data = data.split(b"\n", 1)[1] if b"\n" in data else b""
        else:
            if size < offset:  # truncated or replaced
                offset = 0
            fh.seek(offset)
            data = fh.read()
        consumed = fh.tell()
    # Keep only whole lines; leave a partial trailing line for the next poll.
    if data and not data.endswith(b"\n"):
        cut = data.rfind(b"\n")
        if cut == -1:
            return [], offset or 0
        consumed -= len(data) - cut - 1
        data = data[:cut + 1]
    recs = []
    for line in data.splitlines():
        line = line.strip()
        if line:
            try:
                recs.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return recs, consumed


def find_transcripts(include_subagents=False):
    out = []
    for dirpath, _, names in os.walk(PROJECTS):
        if not include_subagents and os.path.basename(dirpath) == "subagents":
            continue
        for n in names:
            if n.endswith(".jsonl"):
                out.append(os.path.join(dirpath, n))
    return out


def snapshot(args):
    live = live_sessions()
    rows = []
    known = set()
    for path in find_transcripts(args.subagents):
        recs, _ = read_tail(path)
        sid, cands = session_ids(recs, path)
        known |= cands
        state, conf, why = infer(recs, args.quiet_after)
        pid = next((live[c] for c in cands if c in live), None)
        if sid != os.path.basename(path)[:-6]:
            why += f" [resumed/forked; file {os.path.basename(path)[:8]}]"
        rows.append((os.path.getmtime(path), sid, state, conf, pid, why))
    rows.sort(reverse=True)
    print(f"{'mtime':<9}{'session':<14}{'inferred':<11}{'conf':<8}{'pid':<8}reason")
    for mt, sid, state, conf, pid, why in rows:
        print(f"{time.strftime('%H:%M:%S', time.localtime(mt)):<9}{sid[:12]:<14}"
              f"{state:<11}{conf:<8}{str(pid or '-'):<8}{why}")
    ghosts = set(live) - known
    for g in sorted(ghosts):
        print(f"{'-':<9}{g[:12]:<14}{'unknown':<11}{'none':<8}{live[g]:<8}"
              f"live process, no transcript file on disk")
    print(f"\nlive claude processes: {len(live)}  transcripts: {len(rows)}")


def follow(args):
    files = {}
    delays = []
    live = live_sessions()
    last_ps = time.time()
    for path in find_transcripts(args.subagents):
        recs, off = read_tail(path)
        state, conf, why = infer(recs, args.quiet_after)
        files[path] = {"off": off, "recs": recs[-40:], "state": state, "conf": conf,
                       "ids": session_ids(recs, path)}
    print(f"watching {len(files)} transcripts, interval {args.interval}s. ctrl-c to stop.")
    for path, f in files.items():
        if f["state"] != "unknown":
            print(f"  init {os.path.basename(path)[:12]} -> {f['state']}/{f['conf']}")
    deadline = time.time() + args.duration if args.duration else None
    try:
        while not (deadline and time.time() > deadline):
            time.sleep(args.interval)
            now_t = time.time()
            if now_t - last_ps > 2:
                live, last_ps = live_sessions(), now_t
            for path in find_transcripts(args.subagents):
                f = files.get(path)
                if f is None:
                    recs, off = read_tail(path)
                    files[path] = f = {"off": off, "recs": recs[-40:],
                                       "state": "unassigned", "conf": CONF_NONE,
                                       "ids": session_ids(recs, path)}
                    print(f"[{now_hms()}] NEW FILE "
                          f"{os.path.basename(path)[:12]}")
                try:
                    if os.path.getsize(path) == f["off"]:
                        pass  # no growth; still re-infer below for time decay
                    else:
                        new, f["off"] = read_tail(path, f["off"])
                        if new:
                            detect = datetime.now(timezone.utc)
                            for r in new:
                                rt = parse_ts(r.get("timestamp"))
                                if rt:
                                    delays.append((detect - rt).total_seconds())
                            f["recs"] = (f["recs"] + new)[-40:]
                            f["ids"] = session_ids(f["recs"], path)
                except OSError:
                    continue
                state, conf, why = infer(f["recs"], args.quiet_after)
                if (state, conf) != (f["state"], f["conf"]):
                    sid, cands = f["ids"]
                    pid = next((live[c] for c in cands if c in live), None)
                    print(f"[{now_hms()}] {sid[:12]} "
                          f"{f['state']}/{f['conf']} -> {state}/{conf} "
                          f"pid={pid or '-'} :: {why}")
                    f["state"], f["conf"] = state, conf
    except KeyboardInterrupt:
        pass
    if delays:
        xs = sorted(delays)
        def p(q):
            return xs[min(len(xs) - 1, int(len(xs) * q))]
        print(f"\nappend->detect delay over {len(xs)} records (includes the CLI's "
              f"own write latency):\n  min={xs[0]:.3f}s p50={p(.5):.3f}s "
              f"p90={p(.9):.3f}s p99={p(.99):.3f}s max={xs[-1]:.3f}s")
    else:
        print("\nno appends observed")


# --------------------------------------------------------------------------- #

def selftest():
    T = "2026-07-26T12:00:00.000Z"
    now = parse_ts(T)
    late = datetime.fromisoformat("2026-07-26T12:10:00+00:00")

    def A(stop, blocks, ts=T, **kw):
        return dict(type="assistant", timestamp=ts,
                    message={"stop_reason": stop, "content": blocks}, **kw)

    def U(blocks, ts=T, **kw):
        return dict(type="user", timestamp=ts,
                    message={"role": "user", "content": blocks}, **kw)

    use = lambda i, n: {"type": "tool_use", "id": i, "name": n}
    res = lambda i, **kw: dict(type="tool_result", tool_use_id=i, **kw)
    sysrec = lambda sub, ts=T: dict(type="system", subtype=sub, timestamp=ts)
    noise = [{"type": "ai-title"}, {"type": "mode"}, {"type": "permission-mode"},
             {"type": "last-prompt"}]

    cases = [
        ("empty", [], now, "unknown"),
        ("only noise", noise, now, "unknown"),
        ("mid tool, fresh", [A("tool_use", [use("t1", "Bash")])], now, "running"),
        # The headline limit: same records, older clock -> must not claim running.
        ("mid tool, quiet", [A("tool_use", [use("t1", "Bash")])], late, "unknown"),
        ("AskUserQuestion pending", [A("tool_use", [use("t1", "AskUserQuestion")])],
         late, "needsInput"),
        # A fresh end_turn is ambiguous: could be the last message of the turn
        # or one of several within it. Must abstain.
        ("tool resolved then end_turn",
         [A("tool_use", [use("t1", "Bash")]), U([res("t1")]),
          A("end_turn", [{"type": "text", "text": "x"}])], now, "unknown"),
        ("end_turn then silence",
         [A("end_turn", [{"type": "text", "text": "x"}])], late, "idle"),
        ("turn_duration fresh",
         [A("end_turn", [])] + noise + [sysrec("turn_duration")], now, "complete"),
        ("two end_turns in one turn are not a boundary",
         [A("end_turn", []), A("end_turn", [])], now, "unknown"),
        ("turn_duration stale",
         [A("end_turn", [])] + noise + [sysrec("turn_duration")], late, "idle"),
        # Noise after a turn boundary must not reset the reading.
        ("noise after turn_duration", [sysrec("turn_duration")] + noise, late, "idle"),
        ("api error", [dict(type="assistant", timestamp=T, isApiErrorMessage=True,
                            apiErrorStatus=401, message={"stop_reason": "stop_sequence",
                                                         "content": []})], now, "error"),
        ("system api_error", [sysrec("api_error")], now, "error"),
        # A failed tool call is routine, not a session error.
        ("tool_result is_error", [A("tool_use", [use("t1", "Bash")]),
                                  U([res("t1", is_error=True)])], now, "running"),
        ("user rejected a tool", [A("tool_use", [use("t1", "Bash")]),
                                  U([res("t1", is_error=True)],
                                    toolDenialKind="user-rejected")], now, "running"),
        ("fresh prompt", [U("do the thing")], now, "running"),
        ("stale mid-turn", [A("tool_use", [use("t1", "B")]), U([res("t1")])],
         late, "unknown"),
        # Two tools out, one resolved: still pending.
        ("partial resolution", [A("tool_use", [use("t1", "B"), use("t2", "R")]),
                                U([res("t1")])], now, "running"),
    ]
    fails = []
    for name, recs, clock, want in cases:
        got, conf, why = infer(recs, quiet_after=30, now=clock)
        if got != want:
            fails.append(f"{name}: want {want} got {got} ({why})")
    # Confidence must never be high for a guess.
    got, conf, _ = infer([A("tool_use", [use("t1", "Bash")])], 30, late)
    if conf != CONF_NONE:
        fails.append(f"quiet pending tool must have no confidence, got {conf}")
    for f in fails:
        print("FAIL", f)
    print(f"selftest: {len(cases) + 1 - len(fails)}/{len(cases) + 1} passed")
    return 1 if fails else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--snapshot", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--interval", type=float, default=0.2)
    ap.add_argument("--quiet-after", type=float, default=30.0,
                    help="seconds of silence before a mid-turn tail becomes unknown")
    ap.add_argument("--duration", type=float, default=0,
                    help="stop following after N seconds (0 = until ctrl-c)")
    ap.add_argument("--subagents", action="store_true",
                    help="also watch <session>/subagents/agent-*.jsonl")
    args = ap.parse_args()
    if args.selftest:
        return selftest()
    if args.snapshot:
        snapshot(args)
        return 0
    follow(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
