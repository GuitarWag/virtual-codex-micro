# T-VCMPLAN1-001 — PTY control of an owned agent session

Spike run 2026-07-26 on macOS 26.5.2 (build 25F84), arm64, Apple Swift 6.3.3, Claude Code 2.1.220.

## VERDICT: RELIABLE WITH CAVEATS

The PTY mechanism is solid. A macOS app can spawn a child under its own pseudo-terminal, inject
keystrokes and control characters, and have them land deterministically — including while the child is
mid-render and including before the child has finished `exec`. 30/30 injections landed in the race
test; a full-screen `vi` session accepted keystrokes typed at t=0 and wrote the expected bytes to disk.

Two things are not reliable, and both concern the *other* half of the loop:

1. **Reading state out of a TUI byte stream is not trustworthy.** Substring matching finds a prompt
   when the text is written contiguously and misses it when redraw order splits it. It also fires
   once per redraw and never un-fires. Fixable only by running a real terminal emulator (screen
   buffer plus cursor model) in-process — and even then you are pattern-matching on someone else's UI.
2. **Blind injection can be silently discarded.** A child that enters raw mode with
   `tcsetattr(..., TCSAFLUSH, ...)` throws away input queued before that call. Reproduced. So "user
   presses accept, we write `1\r`" is only safe once we *know* the prompt is up — which loops back to
   problem 1.

The way out is that we do not have to read the TUI. `claude --print --input-format stream-json
--output-format stream-json` is a documented line-delimited JSON protocol on the same stdin/stdout we
already control, it carries `session_id`, and it emits hook lifecycle events inline. Measured under
our PTY: 99% printable bytes, one escape sequence in 20 KB, zero alternate-screen use.

**Recommendation: build the command-key cluster. Do not build it on TUI screen-scraping.** Owned
sessions should be driven over the structured stream-json channel for state, with PTY keystroke
injection kept for the case where the user also wants to watch the same session in a real terminal.

## Files

| File | What it is |
|---|---|
| `ptyspike.swift` | The harness. Build/run instructions in the header. Ten modes, each with a hard timeout. |
| `approval_stub.py` | Stand-in for an approval prompt: alternate screen, spinner, ~10 fps redraws, one contiguous question, one written out of order, raw mode with configurable `tcsetattr` `when`. |

Built outside `Package.swift` on purpose — `spikes/` is not under `Sources/`, so SwiftPM never
compiles it and the app build is unaffected:

```
swiftc -O -o /tmp/ptyspike spikes/pty/ptyspike.swift
```

## Evidence

### 1. The mechanism works; input written before the child exists still runs

```
$ /tmp/ptyspike sh-basic
read end: eof(errnoValue: 0) clean EOF
waitpid: exited(0)
PASS sh-basic: command injected at t=0 executed, output read back
```

Both commands were written to the master immediately after `forkpty()` returned, before the child
could have `exec`'d. The needle uses `printf` with a format argument so `hello` can only come from the
child's output, never from the pty echo of our input.

### 2. Injection is deterministic, not lucky — 30/30, worst case 20ms

```
$ /tmp/ptyspike race 30
PASS race: 30/30 rounds landed. spawn→echo avg 8.5ms worst 20.3ms
```

No round needed a retry; none was lost.

### 3. A full-screen TUI accepts keystrokes typed during its own render

```
$ /tmp/ptyspike vi
  bytes=3412 printable=2960 (86%) CSI=69 cursorMoves=33 erase=2
  altScreen enter=1 leave=1
file on disk: "injected-mid-render\n"
PASS vi: keystrokes landed during render
```

`vi` used the alternate screen, set raw mode, and still consumed bytes queued at t=0 — so `vi` does
not use `TCSAFLUSH`. Verified by the file on disk, not by reading the screen.

**Caveat found by accident:** the first version called `waitpid()` before draining the master and
reported a timeout while `vi` sat blocked in `write()` with a full pty buffer. **You must keep reading
the master continuously or the child deadlocks.** This is an implementation constraint for the app,
not a harness quirk.

### 4. TUI output is not parseable for state detection by substring matching

Contiguous text is found; text written out of order is not.

```
raw-stream substring match for "Do you want to proceed?": true
split-across-escapes needle "Apply this patch": raw=false stripped=false
```

`Apply this patch to disk?` occupies one visual row, but the stub draws `| Apply this`, jumps to row 9
for the spinner, then back to row 6 column 16 for ` patch to disk?`. Stripping escapes concatenates
runs in *write* order, not *screen* order. Any real Ink/React TUI does this whenever it partially
invalidates a line or wraps text.

And a match is not an event — one unanswered prompt produced 60 hits:

```
$ grep -o 'Do you want to proceed?' stub.txt | wc -l
      60
```

The needle appears once per redraw and is still in the stream after the prompt is gone, so
`stream.contains(needle)` is sticky and would report "needs input" forever. Edge detection needs a
screen model, and "last frame" is not a concept the byte stream provides.

`top` shows the ceiling: 165 cursor moves, and after stripping there are no line breaks at all
because `top` positions the cursor instead of emitting newlines.

### 5. Input queued before the child enters raw mode can be discarded

Answer written at t=0 instead of after detection, across three `tcsetattr` modes:

```
--raw-when=drain --early  → PASS
--raw-when=now   --early  → PASS
--raw-when=flush --early  → FAIL   ANSWER=<none>
```

`TCSAFLUSH` is Python's `tty.setraw()` default and common in readline-style libraries. When the child
uses it, everything written before that call is gone — no error, nothing to detect. `vi` does not do
this; we do not know what `claude` does.

Consequence: an accept keystroke must be sent *while the prompt is up*, and the app needs a way to
confirm it was consumed. Fire-and-forget into a PTY is not safe for an action that commits a diff.

### 6. Child crash and non-zero exit are both cleanly observable

```
crash exit  → readEnd=eof  waitpid=exited(3)
crash segv  → readEnd=eof  waitpid=signalled(SIGSEGV)
crash wedge → readEnd=timedOut  waitpid=TIMED OUT (still running) → SIGKILL reaped
```

"Session died" and "session failed" are separable states. A child trapping SIGTERM/SIGINT needs
SIGKILL escalation on a timeout.

### 7. Orphans: the pty hangup mostly works, but is not reliable. Explicit `killpg` required

Closing the master hangs up the terminal and the child dies (`waitpid → signalled(SIGHUP)`). But over
66 runs where the parent called `_exit(0)` with no cleanup, the child survived **once**, reparented to
`launchd` with its tty still attached. It is a race at exit, so hangup cannot be the cleanup mechanism.

Grandchildren that ignore SIGHUP survive every time:

```
$ SPIKE_DELAY_MS=400 /tmp/ptyspike orphan /bin/sh -c 'nohup sleep 300 & ...'
pty child 86195 alive: no
grandchild 86196 alive: YES     PGID 86195
```

The grandchild kept the child's PGID, so `killpg(childPid, SIGTERM)` then `SIGKILL` would have caught
it. An agent CLI that spawns language servers, MCP servers or node workers is exactly this shape, so
the app needs that `killpg` on quit *and* a startup sweep for strays from a previous crash.

### 8. `forkpty` vs `openpty` + Foundation `Process` — not interchangeable

`forkpty` does `setsid()` + `TIOCSCTTY` in the child, so the pty is the **controlling** terminal:

```
/dev/ttys020      TTY ttys020   STAT Ss+
```

`openpty()` + `Process` with the slave as stdio makes `isatty()` true, but `Process` gives no hook
between fork and exec, so there is no controlling terminal — and closing the master does nothing:

```
TTY ??   STAT S
closing master fd → waitpid: TIMED OUT — child SURVIVED the hangup
```

Job control, SIGWINCH, `^C` and hangup-on-close all stop working, and every child becomes a guaranteed
orphan. **Use `forkpty`.** This is a correctness requirement, not a preference.

### 9. Claude Code has a structured channel that removes the need to parse the TUI

Relevant flags, verbatim from `claude --help` under the pty:

- `--input-format <format>` — `text` (default) or `stream-json` (realtime streaming input)
- `--output-format <format>` — `text`, `json`, or `stream-json`
- `--include-hook-events` — include hook lifecycle events in the output stream
- `--replay-user-messages` — re-emit user messages from stdin back on stdout for acknowledgment
- `--effort <level>` — low, medium, high, xhigh, max
- `--permission-mode <mode>` — acceptEdits, auto, bypassPermissions, manual, dontAsk, plan
- `--session-id <uuid>`, `-r/--resume`, `--fork-session`
- `--ax-screen-reader` — flat text, no decorative borders or animations
- `--remote-control [name]`

One non-interactive probe under our pty (20682 bytes, 99% printable, CSI=1, no redraws) produced
newline-delimited JSON, one object per line. Message types in order: `system/hook_started`,
`system/hook_response`, `system/init`, `assistant`, `rate_limit_event`, `result`. Every object carried
`session_id`. `system/init` carried `cwd`, `model`, `permissionMode`, tool list and slash-command list;
`result` carried `is_error`, `duration_ms`, `stop_reason`, cost and per-model token usage.
`--no-session-persistence` was used so the probe wrote nothing under `~/.claude/projects`.

Two incidental findings: the session's `slash_commands` list includes `effort`, so the dial has a
slash-command target as well as the flag; and hook events already arrive inline on this stream, which
overlaps with T-VCMPLAN1-002 and may make a separate HTTP listener unnecessary for owned sessions.

## Not tested — be explicit about this

- **The real interactive `claude` TUI was never driven** (per task constraints). Open: does its
  approval prompt accept a single injected keystroke; does it use `TCSAFLUSH`; does it use the
  alternate screen; is its question text contiguous or split by redraw. The existence of
  `--ax-screen-reader` ("no decorative borders or animations") is indirect evidence the default
  render *is* decorated and animated.
- **Slash-command injection into a live interactive session.** Untested.
- **Approval detection latency against real state changes.** The 521ms figure is a property of the
  stub's spinner phase, not a measurement of anything real.
- **Six concurrent PTY children**, the M2 target. Every test used one.
- **Sleep/wake, display reconfiguration, SIGWINCH/TIOCSWINSZ resize handling.**
- **Startup sweep for strays** from a previous crash — identified as needed, not built.

## What this means for the plan

| Command key | Verdict | Route |
|---|---|---|
| accept / reject | build it | stream-json turn on stdin, or PTY keystroke gated on a prompt event from hooks — not on scraped text |
| new session | build it | `forkpty` + a `--session-id <uuid>` we generate |
| effort dial | build it | `--effort` at spawn, `/effort` mid-session |
| push-to-talk | unaffected | already P2 |

1. **`forkpty`, not `openpty` + `Process`** (test 8). Correctness requirement.
2. **Owned sessions get a structured channel, not a scraped one.** The adapter should speak
   stream-json and treat the PTY as transport, not as a screen to read.
3. **Continuous drain is mandatory** (test 3) or the child blocks in `write()` and looks hung.
4. **Teardown must `killpg` then `SIGKILL` with a timeout** (tests 6, 7). Do not rely on pty hangup.
5. **Accept/reject need delivery confirmation before the key returns to idle.**
   `--replay-user-messages` provides it on the stream-json path; the raw PTY path has no equivalent,
   which is the strongest argument for point 2.

If a later decision forces owned sessions to be scraped interactive TUIs after all, this verdict drops
to UNRELIABLE for accept/reject and the command cluster should collapse to focus-only: test 4 shows we
cannot tell a pending approval from a stale one without an embedded terminal emulator, and test 5
shows we cannot confirm the keystroke landed.
