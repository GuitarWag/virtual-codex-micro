# T-VCMPLAN1-039 — the amber key, witnessed

Run 2026-07-26 on macOS 26.5.2 arm64 against Claude Code 2.1.220, four real interactive sessions driven
under `forkpty`. Everything below was measured on this machine.

## VERDICT

**`PermissionRequest` fires.** 4 of 4 real interactive sessions, at the moment the dialog was painted,
carrying `tool_name`, `tool_input` and `permission_suggestions`. The app's own
`ClaudeHookSource.outcome(for:)` turns the captured bytes into `needsInput`. The amber key is real and
the mapping is correct as written.

**But it delivered nothing in the live install, and the cause was a bug in our own code.**
`ClaudeHookInstaller.apply` did `removeItem(at: Self.forwarderDirectory)` on *any* uninstall — the
hard-coded real path, recursive, ignoring `plan.forwarderURL`. Since `selfCheckFailures()` applies two
fixture uninstalls, **running the app's self-check deleted the live forwarder** while leaving all eleven
`~/.claude/settings.json` entries pointing at it. `async: true` discards the resulting `exit 127`, so the
breakage was silent. Observed three times during this spike. *(Fixed after this report: the directory is
now derived from the plan and removed only when empty, plus a `targetsLiveInstall` guard.)*

**Third result, previously unwitnessed: rejecting a permission prompt emits no hook event at all.** Not
`PermissionDenied`, not `Stop`, not `PostToolUseFailure` — nothing.

## What was run

`needsinput.py` — `os.forkpty()` (so the child gets a real *controlling* terminal, verified as `STAT
Ss+`), continuous drain of the master, teardown by `killpg`. Detection is **the spool only**; the TUI
byte stream is timestamped for latency ground truth and never parsed to decide a prompt exists, which is
the thing the PTY spike proved unreliable.

Each run: throwaway `cwd` under `/private/tmp`, one turn, prompt `Run exactly this one bash command and
then stop: /bin/echo vcm-amber-probe`, default permission mode.

`--no-session-persistence` **could not be used** — it works only with `--print`. So each session left a
transcript under `~/.claude/projects/` and an entry in `~/.claude.json`.

| mode | hook config | answer | events received |
|---|---|---|---|
| `allow` | own `--settings` | CR (option 1) | SessionStart, UserPromptSubmit, PreToolUse, **PermissionRequest**, PostToolUse, PostToolBatch, Stop |
| `deny` | own `--settings` | ESC | SessionStart, UserPromptSubmit, PreToolUse, **PermissionRequest**, then **nothing** |
| `no` | own `--settings` | `3` (option 3) | SessionStart, UserPromptSubmit, PreToolUse, **PermissionRequest**, then **nothing** |
| `realconfig` | the real `~/.claude/settings.json` | CR | **nothing — forwarder absent, exit 127** |

Three runs used a scratch `--settings` file: the same CLI code path, the same event, and a hook entry
byte-identical in shape to the installed one pointing at a **verbatim copy of
`ClaudeHookInstaller.forwarderScript`** — so what was exercised is the app's own forwarder.

The `realconfig` run is explained read-only from its own transcript, which records hook dispatch:

```json
{"type": "async_hook_response", "hookName": "SessionStart:startup",
 "stderr": "/bin/sh: ~/.virtual-codex-micro/claude-hook.sh: No such file or directory",
 "exitCode": 127}
```

So the settings entries dispatch correctly and the shell invocation is right; only the script was
missing. Useful side finding: **the CLI records async hook failures in the transcript**, which is the
only place an install this broken is visible.

## The captured payload

Real bytes, `capture-allow/spool/tmp.tfkyaflP.json`. Forwarder header line, then the CLI payload
verbatim. Home paths shortened.

```
vcm	pid=10146	term=vcm-needsinput-spike	entry=cli
```
```json
{
  "hook_event_name": "PermissionRequest",
  "session_id": "6497a136-df0c-4688-98e9-52ab59012234",
  "prompt_id": "f5591209-f988-4cee-b904-4d2008824ce0",
  "cwd": "/private/tmp/claude-501/vcm-needsinput/allow/workdir",
  "transcript_path": "~/.claude/projects/-private-tmp-.../6497a136-….jsonl",
  "permission_mode": "default",
  "effort": { "level": "high" },
  "tool_name": "Bash",
  "tool_input": {
    "command": "/bin/echo vcm-amber-probe",
    "description": "Echo the string vcm-amber-probe"
  },
  "permission_suggestions": [
    { "type": "addRules", "behavior": "allow", "destination": "localSettings",
      "rules": [ { "toolName": "Bash", "ruleContent": "/bin/echo vcm-amber-probe *" } ] }
  ]
}
```

Matches the hook spike's shape field for field. Two notes: **`agent_id` is absent**, so the subagent
filter passes it through as required; and `pid=10146` is the CLI process itself and was the `forkpty`
child, so the `session_id → CLAUDE_PID → tty → window` chain focus needs is intact on the event that
matters most.

## Latency

Ground truth external: wall clock at which `Do you want to proceed` first appeared in the pty byte
stream, versus the spool file's mtime.

| run | hook − dialog paint |
|---|---|
| `allow` | **+11 ms** |
| `deny` | **+6 ms** |
| `no` | **+26 ms** |

6–26 ms against the 1 s M2 criterion. The spike's 1 ms was an `http` hook; these are `command` hooks and
the extra ~5–25 ms is process spawn, exactly as predicted. Plus the receiver's 200 ms spool poll, the
worst case end to end is ~230 ms.

The sign is noise, not ordering: the paint marker is detected on a read boundary, so this measurement
carries read-granularity error.

## The mapping, run against the real bytes

`mapcheck.swift` compiles the app's actual `AgentState`, `AgentBackend`, `StateEngine`,
`ClaudeHookSource` and `ClaudeHookInstaller` and feeds it the captured spool files — the shipped code on
the real payload, not a re-reading of the table:

```
SessionStart         -> openSlot(source: Optional("startup"))
UserPromptSubmit     -> state(AgentState.running)
PreToolUse           -> state(AgentState.running)
PermissionRequest    -> state(AgentState.needsInput)
  tool_name           : Bash
  tool_input.command  : /bin/echo vcm-amber-probe
  suggestions present : true
  claudePID / term    : 10146 / vcm-needsinput-spike
  agentID (must be nil): nil
PostToolUse          -> state(AgentState.running)
PostToolBatch        -> state(AgentState.running)
Stop                 -> state(AgentState.complete)
mapcheck OK
```

## `PermissionDenied` still never fires, and there is no clearing signal

The dialog offers three options plus an escape. Both reject affordances were driven and both genuinely
rejected — ground truth from the transcripts, not the screen:

```json
{"type":"tool_result","is_error":true,
 "content":"The user doesn't want to proceed with this tool use. The tool use was rejected …"}
{"type":"text","text":"[Request interrupted by user for tool use]"}
```

| affordance | keystroke | rejection confirmed | hooks after `PermissionRequest` |
|---|---|---|---|
| "Esc to cancel" | `\x1b` | yes | **none** |
| option 3, "No" | `3` | yes | **none** |

Selecting deny through the PTY *is* reliable — that closes the hook spike's G6 "not reliable" caveat.
What is not reliable is our ability to observe it:

- **`PermissionDenied` did not fire.** Registered alongside `Elicitation` and `ElicitationResult`; none
  appeared. Across 12 spike sessions plus these 4, it has now never been seen. Its `.ignore(...)`
  disposition is correct and should stay.
- **No other event fires either.** No `Stop`, `StopFailure`, `PostToolUse` or `PostToolUseFailure`. The
  turn simply ends. The transcript records a `turn_duration`; the hook stream records nothing.
- Waiting did not help: the `deny` session sat idle ~170 s with `Notification` registered and nothing
  arrived.

**Consequence, now witnessed rather than assumed: after a rejection the hook stream leaves the slot
amber forever.** "Unconfirmed resolves to unknown, never to done" is the only correct choice and is now
load-bearing rather than defensive.

The way out: the transcript *does* mark the rejection, with `tool_result.is_error = true` plus the
literal `[Request interrupted by user for tool use]`. So **the tailer, not the hook stream, is what
clears amber on the reject path.** New requirement on `ClaudeTranscriptSource`, on the M2 critical path.

## Correction to the PTY spike: SIGTERM before SIGKILL makes `claude` unreapable

The PTY spike recommended `killpg(SIGTERM)` then `SIGKILL`. Against `/bin/sh` that is right. Against
`claude` it is wrong, and it cost four runs a false "not reaped".

| teardown | result | n |
|---|---|---|
| `killpg(SIGTERM)` then `killpg(SIGKILL)` | **never reaped** within 3 s + 3 s | 5/5 |
| `killpg(SIGKILL)` alone | reaped in 0.1 s, `waitpid → (pid, 9)` | 3/3 |

`claude` catches SIGTERM and keeps running (`STAT` stays `Ss+` two seconds later). A SIGKILL sent
afterwards leaves it in macOS `E` (exiting) state — `?Es`, controlling terminal already dropped — where
`waitpid` never returns it. With no SIGTERM first, SIGKILL produces a clean zombie and `waitpid` returns
immediately.

No stray `claude` survived any run, so the wedged process does go away once the parent exits. But the app
cannot *confirm* teardown on the SIGTERM path, and a long-lived panel opening and closing owned sessions
would accumulate unreapable children for its whole lifetime. **`OwnedSession` teardown should go straight
to `killpg(SIGKILL)`.** Mechanism not fully explained; worth a dedicated look before the command cluster
ships.

## What could not be tested

- **`PermissionRequest` end to end through the untouched real install.** The one run that used it
  exclusively found the forwarder already deleted by the installer bug. What is proven for the real
  install is that its entries dispatch correctly, recorded as `exit 127` on the missing script. Repeat
  once the installer fix is in — a one-turn run.
- **`Notification(permission_prompt)` at its 6 s debounce** was not re-measured. The `deny` run does show
  that once a prompt is answered, no `Notification` follows.
- **`Elicitation` / `ElicitationResult`** registered in all three scratch runs, never fired.
- **`StopFailure` / `PostToolUseFailure`** still never fired. The red key remains the least trustworthy
  thing on the panel.
- **Concurrency.** One session at a time; the M2 target of six was not attempted.
- **Whether the `3` keystroke is stable across dialog shapes.** It worked for a three-option Bash prompt.
  A different option list would put "No" at a different index, so the accept/reject keys must read
  `permission_suggestions` rather than hard-code one.

## Files

| File | What it is |
|---|---|
| `needsinput.py` | The harness. `selfcheck` \| `allow` \| `deny` \| `no` \| `none` \| `realconfig`. `python3 needsinput.py selfcheck` proves the forwarder turns a payload on stdin into a parseable spool file. |
| `mapcheck.swift` | Feeds captured spool bytes through the app's own parse and mapping. Build line in its header. |
| `spoolwatch.py` | Mirrors the real spool by copy, never move, so observing it cannot consume what the running app needs. |
| `claude-hook.sh` | Verbatim copy of what `ClaudeHookInstaller.forwarderScript` generates — evidence of what was exercised. |
| `capture-allow/`, `capture-deny/`, `capture-no/` | Per-run `run.json`, raw pty `stream.txt`, untouched `spool/`. `"teardown": "not reaped"` is the SIGTERM fault above, not a leak. |
| `capture-realconfig/` | The real-install run. No spool copy by design — shared with the running app. |
| `capture-real/index.json` | Empty. 200 s mirroring the real spool while sessions fired hooks: zero events, because the forwarder was absent. |

Left on the machine: four throwaway transcripts under `~/.claude/projects/`
(`-private-tmp-claude-501-vcm-needsinput-*`) and their `~/.claude.json` entries, unavoidable because
`--no-session-persistence` is print-mode only. `~/.claude/settings.json` was read, never written. The real
spool was mirrored by copy and never cleared.
