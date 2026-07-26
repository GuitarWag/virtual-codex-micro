#!/usr/bin/env python3
"""Stand-in for a Claude Code approval prompt, for the PTY spike (T-VCMPLAN1-001).

We are NOT allowed to drive a real interactive `claude` session in this spike (expensive,
and it can hang), so this reproduces the mechanics that make such a prompt hard to read
off a byte stream:

  * alternate screen + hidden cursor (smcup), like any Ink/React-based TUI
  * a spinner phase that redraws the whole screen before the prompt exists
  * the prompt box redrawn ~10x/second, so the question text repeats in the stream
  * one question written contiguously ("Do you want to proceed?")
  * one question written OUT OF ORDER, with an unrelated draw in between
    ("Apply this" ... other rows ... " patch to disk?"), like a wrapped/partially
    invalidated line
  * raw-mode single-keypress input, applied with a configurable tcsetattr() `when`

Usage:  approval_stub.py [--raw-when=drain|flush|now]

`--raw-when=flush` is the interesting one: TCSAFLUSH discards input that was queued
before the child entered raw mode. That is Python's tty.setraw() default and a common
choice in readline-style libraries.
"""
import select
import sys
import termios
import time
import tty

WHEN = {"drain": termios.TCSADRAIN, "flush": termios.TCSAFLUSH, "now": termios.TCSANOW}
arg = next((a for a in sys.argv[1:] if a.startswith("--raw-when=")), "--raw-when=drain")
when = WHEN[arg.split("=", 1)[1]]

fd = sys.stdin.fileno()
SPIN = "|/-\\"


def w(s):
    sys.stdout.write(s)
    sys.stdout.flush()


w("\x1b[?1049h\x1b[?25l")  # alt screen on, cursor hidden

# Phase 1: "running a tool", full-screen redraws, no prompt yet.
for i in range(8):
    w("\x1b[H\x1b[2J")
    w("\x1b[2;3H%s Running Edit(src/app.swift)" % SPIN[i % 4])
    w("\x1b[4;3H" + "-" * 44)
    time.sleep(0.06)

saved = termios.tcgetattr(fd)
tty.setraw(fd, when)

answer = None
for frame in range(60):  # ~6s ceiling
    w("\x1b[H\x1b[2J")
    w("\x1b[2;3H+" + "-" * 44 + "+")
    w("\x1b[3;3H| Edit  src/app.swift")
    w("\x1b[5;3H| Do you want to proceed?")          # contiguous needle
    w("\x1b[6;3H| Apply this")                        # split needle, part 1
    w("\x1b[9;3H| %s esc to interrupt" % SPIN[frame % 4])
    w("\x1b[6;16H patch to disk?")                    # split needle, part 2 (out of order)
    w("\x1b[7;3H|  1. Yes   2. No")
    w("\x1b[10;3H+" + "-" * 44 + "+")
    r, _, _ = select.select([fd], [], [], 0.1)
    if r:
        answer = sys.stdin.read(1)
        break

termios.tcsetattr(fd, termios.TCSADRAIN, saved)
w("\x1b[?25h\x1b[?1049l")  # cursor back, leave alt screen
print("ANSWER=%s FRAMES=%d RAWWHEN=%s" % (answer if answer else "<none>", frame + 1, arg))
