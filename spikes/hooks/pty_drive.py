#!/usr/bin/env python3
"""Drive a real interactive Claude Code session over a PTY.

Needed because the permission prompt -- the candidate needsInput signal -- only
exists in the interactive TUI. Print mode (-p) never shows one.

Timestamps every PTY output chunk so we have an external ground truth for
"when did the permission dialog actually appear on screen", to compare against
hook receipt times in events.jsonl.

Writes pty.jsonl:  {"t_ms": ..., "kind": "out"|"in"|"note", "text": ...}
"""

import errno
import fcntl
import json
import os
import pty
import re
import select
import signal
import struct
import sys
import termios
import time

ANSI = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]|\x1b[()][A-B0-9]|\x1b[=>]|\r")
LOG = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "pty.jsonl"), "w")


def log(kind, text):
    LOG.write(json.dumps({"t_ms": round(time.time() * 1000, 1), "kind": kind, "text": text}) + "\n")
    LOG.flush()


def plain(b):
    return ANSI.sub("", b.decode("utf-8", "replace"))


def main():
    claude = "/Users/wagnerjosedasilva/.local/share/claude/versions/2.1.220"
    settings = os.path.join(os.path.dirname(os.path.abspath(__file__)), "scratch-config/settings.json")
    cwd = sys.argv[1]
    prompt = sys.argv[2]

    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(cwd)
        os.environ["TERM"] = "xterm-256color"
        os.environ.pop("CLAUDE_CODE_ENTRYPOINT", None)
        os.execv(claude, [claude, "--settings", settings, "--model", "sonnet"])

    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 45, 140, 0, 0))
    log("note", "spawned")

    screen = []
    sent_prompt = False
    saw_dialog = False
    declined = False
    t_start = time.time()

    def pump(seconds):
        end = time.time() + seconds
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.2)
            if not r:
                continue
            try:
                data = os.read(fd, 65536)
            except OSError as e:
                if e.errno == errno.EIO:
                    return False
                raise
            if not data:
                return False
            txt = plain(data)
            screen.append(txt)
            log("out", txt)
        return True

    def send(s, note):
        log("in", note)
        os.write(fd, s.encode())

    # let the TUI boot
    pump(6)

    send(prompt + "\r", "prompt+enter")
    sent_prompt = True

    # watch for the permission dialog, keeping strictly hands off the keyboard
    # afterwards so the 6s idle debounce on the permission_prompt notification
    # is allowed to elapse.
    while time.time() - t_start < 150:
        if not pump(1):
            break
        blob = "".join(screen[-80:])
        if not saw_dialog and ("Do you want" in blob or "needs your permission" in blob):
            saw_dialog = True
            log("note", "DIALOG_VISIBLE")
        if saw_dialog and time.time() - t_start > 0:
            # hold for 25s of total keyboard silence, then decline
            if not declined and "".join(screen).count("DIALOG_HOLD_DONE") == 0:
                hold_end = time.time() + 25
                while time.time() < hold_end:
                    if not pump(1):
                        break
                log("note", "hold elapsed, declining")
                send("\x1b", "escape (decline)")
                declined = True
                pump(4)
                break

    log("note", "exiting")
    send("\x03", "ctrl-c")
    pump(1)
    send("\x03", "ctrl-c")
    pump(3)
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    pump(2)
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    os.waitpid(pid, 0)
    log("note", "done")
    print("saw_dialog=", saw_dialog)


if __name__ == "__main__":
    main()
