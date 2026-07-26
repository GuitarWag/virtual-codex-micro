#!/usr/bin/env python3
"""T-VCMPLAN1-039 — drive a REAL interactive `claude` to a permission prompt and
prove PermissionRequest lands in the spool.

Why Python and not Swift: the only thing under test here is the hook, not the PTY.
spikes/pty proved the PTY mechanics in Swift already, and `os.forkpty()` is
forkpty(3) — the same syscall, with setsid + TIOCSCTTY, so the child gets a real
CONTROLLING terminal. That is the one PTY property the pty spike called a
correctness requirement (openpty + a Process API gives no controlling terminal).
Everything else the pty findings insist on is honoured here:

  - continuous drain of the master, or the child blocks in write() and looks hung
  - teardown is killpg(SIGTERM) then killpg(SIGKILL) on a timeout, never the pty
    hangup, which leaked a child once in 66 runs
  - the TUI is NEVER parsed to decide the prompt is up. Detection is the spool.
    The stream is timestamped only to get an external ground truth for latency.

Usage:
    ./needsinput.py allow        # answer the prompt with "yes"
    ./needsinput.py deny         # answer the prompt with "no" (esc)
    ./needsinput.py none         # leave the prompt hanging, then tear down
"""

import json
import os
import pty  # noqa: F401  (documents intent; os.forkpty is the entry point)
import re
import select
import shutil
import signal
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
CLAUDE = os.path.join(HOME, ".local/bin/claude")  # not the PATH shim
SPIKE = os.path.dirname(os.path.abspath(__file__))
ROOT = "/private/tmp/claude-501/vcm-needsinput"

# The eleven events ClaudeHookInstaller.subscribedEvents registers.
EVENTS = [
    "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
    "PostToolBatch", "PermissionRequest", "Stop", "StopFailure",
    "PostToolUseFailure", "Notification",
    # Not installed by the app, but registered here so a fired-or-not answer
    # exists for the two the mapping table calls unverified.
    "PermissionDenied", "Elicitation", "ElicitationResult",
]

# The prompt. Trivial, in a throwaway dir, and it needs Bash approval under the
# default permission mode. Costs one turn.
PROMPT = "Run exactly this one bash command and then stop: /bin/echo vcm-amber-probe"

# Markers only for latency ground truth: the wall clock at which the dialog was
# painted. Never used to decide that a prompt exists.
DIALOG_MARKERS = [
    "Do you want to proceed",
    "don't ask again",
    "tell Claude what to do differently",
]
TRUST_MARKERS = ["Do you trust the files in this folder", "trust the files"]

ANSI = re.compile(rb"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b[]P^_].*?(?:\x07|\x1b\\)|\x1b[()][A-Za-z0-9]|\x1b[=>MNOc78]", re.S)


def strip(b):
    return ANSI.sub(b"", b).decode("utf-8", "replace")


def forwarder_script(spool):
    """Byte-identical to ClaudeHookInstaller.forwarderScript(spoolDirectory:),
    with the spool path substituted. Verbatim on purpose: the point is to test
    the app's own forwarder, not a stand-in for it."""
    quoted = "'" + spool.replace("'", "'\\''") + "'"
    return (
        "#!/bin/sh\n"
        "# Installed by Virtual Codex Micro. Its uninstaller deletes this file.\n"
        "#\n"
        "# Reads one Claude Code hook payload on stdin and drops it in the app's spool\n"
        "# directory. The settings entry sets \"async\": true so the CLI does not wait on\n"
        "# this, and the script itself does one mkdir, one write and one rename.\n"
        "#\n"
        "# Always exits 0: a hook exiting non-zero can block the transition it fired on,\n"
        "# and exit code 2 is a blocking error the model is told about.\n"
        f"d={quoted}\n"
        'mkdir -p "$d" 2>/dev/null || exit 0\n'
        'f=$(mktemp "$d/tmp.XXXXXXXX" 2>/dev/null) || exit 0\n'
        "# First line is the environment the JSON payload does not carry. CLAUDE_PID is\n"
        "# the CLI process itself, which is what liveness polling and window focus need.\n"
        "{\n"
        "  printf 'vcm\\tpid=%s\\tterm=%s\\tentry=%s\\n' \"${CLAUDE_PID:-}\" \"${TERM_PROGRAM:-}\" \"${CLAUDE_CODE_ENTRYPOINT:-}\"\n"
        "  cat\n"
        '} > "$f" 2>/dev/null\n'
        "# Rename last. The receiver reads only *.json, so it never sees a partial write.\n"
        'mv -f "$f" "$f.json" 2>/dev/null || rm -f "$f" 2>/dev/null\n'
        "exit 0\n"
    )


def setup(mode):
    root = os.path.join(ROOT, mode)
    shutil.rmtree(root, ignore_errors=True)
    work, spool = os.path.join(root, "workdir"), os.path.join(root, "spool")
    for d in (work, spool):
        os.makedirs(d)
    fwd = os.path.join(root, "claude-hook.sh")
    with open(fwd, "w") as f:
        f.write(forwarder_script(spool))
    os.chmod(fwd, 0o755)
    entry = {"type": "command", "command": fwd, "async": True}
    with open(os.path.join(root, "settings.json"), "w") as f:
        json.dump({"hooks": {e: [{"hooks": [entry]}] for e in EVENTS}}, f, indent=2)
    return root, work, spool, fwd


def drain_spool(spool, seen):
    """New complete payloads, oldest-mtime first. Reads only *.json — the same
    rule ClaudeHookSource.drain uses, so an in-flight tmp.XXXX is never seen.
    Does NOT delete: the files are the evidence."""
    out = []
    for name in sorted(os.listdir(spool)):
        if not name.endswith(".json") or name in seen:
            continue
        path = os.path.join(spool, name)
        try:
            st = os.stat(path)
            with open(path, "rb") as f:
                data = f.read()
        except OSError:
            continue
        seen.add(name)
        header, _, body = data.partition(b"\n")
        try:
            payload = json.loads(body)
        except ValueError:
            payload = None
        out.append({"file": name, "mtime": st.st_mtime, "header": header.decode(), "payload": payload})
    return sorted(out, key=lambda e: e["mtime"])


def kill_tree(pid, master, signals=(signal.SIGKILL,)):
    """pty hangup is not the cleanup mechanism (pty findings, test 7): killpg the
    group, then close the master.

    SIGKILL only, and that is a correction to the pty spike's recommendation #4.
    `claude` catches SIGTERM and keeps running (STAT stays Ss+), and a SIGKILL
    sent AFTERWARDS leaves it wedged in macOS `E` (exiting) state where waitpid
    never returns it — reproduced 5/5. killpg(SIGKILL) with no SIGTERM first
    reaped cleanly as a zombie, waitpid -> (pid, 9). See FINDINGS.md."""
    for sig in signals:
        try:
            os.killpg(pid, sig)
        except OSError:
            pass
        for _ in range(30):
            try:
                if os.waitpid(pid, os.WNOHANG)[0] == pid:
                    try:
                        os.close(master)
                    except OSError:
                        pass
                    return f"reaped after SIG{'TERM' if sig == signal.SIGTERM else 'KILL'}"
            except ChildProcessError:
                # Already reaped. Not a failure — the first run reported
                # "not reaped" here and no stray existed.
                try:
                    os.close(master)
                except OSError:
                    pass
                return "already reaped"
            time.sleep(0.1)
    try:
        os.close(master)
    except OSError:
        pass
    return "not reaped"


def run(mode, budget=180.0):
    root, work, spool, fwd = setup(mode)
    log = {"mode": mode, "root": root, "claude": CLAUDE, "events": [], "notes": []}

    env = {k: v for k, v in os.environ.items() if not k.startswith("CLAUDE")}
    env.update(TERM="xterm-256color", LINES="40", COLUMNS="110", TERM_PROGRAM="vcm-needsinput-spike")

    if mode == "realconfig":
        # No --settings at all. The ONLY hook configuration in play is the user's
        # own ~/.claude/settings.json, its own forwarder and its own spool — the
        # exact install the product ships. Read-only: nothing here writes to any
        # of the three, and spoolwatch.py mirrors the spool by copy, never move.
        argv = [CLAUDE, "--model", "sonnet"]
        spool = os.path.expanduser("~/Library/Application Support/VirtualCodexMicro/hook-spool")
        log["notes"].append("REAL config: no --settings, watching the app's own spool")
    else:
        argv = [CLAUDE, "--settings", os.path.join(root, "settings.json"), "--model", "sonnet"]
    # --no-session-persistence is print-mode only (verified in --help), so it
    # cannot be used here. The session therefore leaves a transcript behind.
    log["argv"] = argv

    t_spawn = time.time()
    pid, master = os.forkpty()
    if pid == 0:
        os.chdir(work)
        os.execve(argv[0], argv, env)
        os._exit(127)

    stream = bytearray()
    reads = []            # (t, nbytes)
    marks = {}            # marker -> first wall clock it appeared
    seen = set()
    answered = False
    t_answer = None
    typed = False
    trusted = False
    quiet_since = time.time()
    deadline = t_spawn + budget
    stop_at = None        # set once the permission answer is in and the turn ends

    while time.time() < deadline:
        r, _, _ = select.select([master], [], [], 0.1)
        if r:
            try:
                chunk = os.read(master, 65536)
            except OSError:
                chunk = b""
            if not chunk:
                log["notes"].append(f"pty EOF at t+{time.time() - t_spawn:.1f}s")
                break
            stream += chunk
            reads.append((time.time(), len(chunk)))
            quiet_since = time.time()
            plain = strip(bytes(stream))
            for m in DIALOG_MARKERS + TRUST_MARKERS:
                if m not in marks and m in plain:
                    marks[m] = time.time()

        # spool is the detector, never the screen
        for ev in drain_spool(spool, seen):
            name = (ev["payload"] or {}).get("hook_event_name", "?")
            # The real spool is shared: the operator's own agent session writes to
            # it too. Attribute by cwd, which every payload carries.
            if mode == "realconfig" and (ev["payload"] or {}).get("cwd") != work:
                continue
            ev["t_rel"] = ev["mtime"] - t_spawn
            log["events"].append(ev)
            print(f"  [t+{ev['t_rel']:7.3f}] {name:22} {ev['file']}", flush=True)
            if name == "PermissionRequest" and not answered:
                answered = True
                t_answer = time.time()
                time.sleep(0.4)  # let the dialog settle; it is already up
                if mode in ("allow", "realconfig"):
                    os.write(master, b"\r")        # option 1, the default
                    log["notes"].append("answered ALLOW with CR (option 1)")
                    stop_at = time.time() + 30
                elif mode == "deny":
                    os.write(master, b"\x1b")      # esc = "Esc to cancel"
                    log["notes"].append("answered DENY with ESC (cancel)")
                    stop_at = time.time() + 30
                elif mode == "no":
                    os.write(master, b"3")         # option 3, literally "No"
                    log["notes"].append("answered NO by typing 3")
                    stop_at = time.time() + 30
                else:
                    log["notes"].append("left the prompt unanswered")
                    stop_at = time.time() + 25   # past the 6s Notification debounce
            if name in ("Stop", "SessionEnd", "PostToolUse", "PermissionDenied") and answered:
                stop_at = time.time() + 8   # keep draining for trailers

        idle = time.time() - quiet_since
        # Trust dialog: a first run in an unknown directory asks before anything
        # else happens. One CR, once, gated on quiet output.
        if not trusted and idle > 2.0 and len(stream) > 200:
            os.write(master, b"\r")
            trusted = True
            quiet_since = time.time()
            log["notes"].append(f"sent CR for the folder-trust dialog at t+{time.time() - t_spawn:.1f}s")
            time.sleep(1.5)
            continue
        if trusted and not typed and idle > 2.0:
            os.write(master, PROMPT.encode())
            time.sleep(0.6)
            os.write(master, b"\r")
            typed = True
            quiet_since = time.time()
            log["prompt_sent_at"] = time.time() - t_spawn
            log["notes"].append(f"typed the prompt at t+{log['prompt_sent_at']:.1f}s")

        if stop_at and time.time() > stop_at:
            log["notes"].append("done draining trailers")
            break

    log["teardown"] = kill_tree(pid, master)
    log["elapsed"] = time.time() - t_spawn
    log["marks"] = {k: v - t_spawn for k, v in marks.items()}
    log["bytes"] = len(stream)
    log["answered_at"] = (t_answer - t_spawn) if t_answer else None

    # latency: hook mtime vs the externally observed dialog paint
    perm = [e for e in log["events"] if (e["payload"] or {}).get("hook_event_name") == "PermissionRequest"]
    if perm and marks:
        paint = min(marks[m] for m in DIALOG_MARKERS if m in marks) if any(m in marks for m in DIALOG_MARKERS) else None
        if paint:
            log["latency_ms_hook_minus_paint"] = (perm[0]["mtime"] - paint) * 1000.0

    out = os.path.join(SPIKE, f"capture-{mode}")
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)
    if mode != "realconfig":   # never copy the shared spool wholesale
        shutil.copytree(spool, os.path.join(out, "spool"))
    with open(os.path.join(out, "stream.txt"), "wb") as f:
        f.write(bytes(stream))
    with open(os.path.join(out, "run.json"), "w") as f:
        json.dump(log, f, indent=2, sort_keys=True)

    names = [(e["payload"] or {}).get("hook_event_name") for e in log["events"]]
    print(f"\n== {mode} ==")
    print("  order    :", " ".join(n or "?" for n in names) or "(nothing)")
    print("  teardown :", log["teardown"], f"in {log['elapsed']:.1f}s, {len(stream)} pty bytes")
    print("  marks    :", {k: round(v, 2) for k, v in log["marks"].items()})
    if "latency_ms_hook_minus_paint" in log:
        print(f"  latency  : PermissionRequest mtime - dialog paint = {log['latency_ms_hook_minus_paint']:.0f} ms")
    print("  notes    :", "; ".join(log["notes"]))
    print("  captured :", out)
    return log


def check():
    """The one runnable check: the forwarder we generate really does turn a
    payload on stdin into a *.json in the spool with the header line the parser
    expects. Fails if either half breaks."""
    root, _, spool, fwd = setup("selfcheck")
    subprocess.run(
        [fwd], input=b'{"hook_event_name":"PermissionRequest","session_id":"probe"}',
        env={**os.environ, "CLAUDE_PID": "4242", "TERM_PROGRAM": "probe", "CLAUDE_CODE_ENTRYPOINT": "cli"},
        check=True,
    )
    got = drain_spool(spool, set())
    assert len(got) == 1, got
    assert got[0]["payload"]["hook_event_name"] == "PermissionRequest"
    assert "pid=4242" in got[0]["header"] and "term=probe" in got[0]["header"], got[0]["header"]
    assert os.path.exists(CLAUDE), CLAUDE
    print("selfcheck OK: forwarder spools a parseable payload with pid/term header")


if __name__ == "__main__":
    arg = sys.argv[1] if len(sys.argv) > 1 else "selfcheck"
    if arg == "selfcheck":
        check()
    else:
        run(arg)
