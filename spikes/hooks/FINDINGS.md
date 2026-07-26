# T-VCMPLAN1-002 — Hook-based state push from Claude Code

Run 2026-07-26 against Claude Code 2.1.220 (native, darwin-arm64, commit `4073f595`). Everything below
was measured on this machine. Where a claim is inference rather than observation it says so.

## Isolation

`~/.claude/settings.json` was never written. SHA-256 before the first run and after the last:

```
1ad67db214ab12d45b1780e14d9206acb1e487857436a976cd28beac5fb194b5   (unchanged, 12 sessions)
```

`CLAUDE_CONFIG_DIR` was tried and **abandoned**: it relocates the credential store, so the CLI reports
`Not logged in` and no session can run. Copying credentials to a scratch dir was not acceptable, so the
spike used `--settings <scratch path>`, which loads hooks as the `flag` settings source without touching
any file. Precedence, from the binary's own schema text: `user < project < local < flag < policy`.

Side effect worth recording: merely *running* `claude` rewrites `~/.claude.json` (per-project session
bookkeeping) and appends transcripts under `~/.claude/projects/`. Not caused by this spike, but it means
"run a session, change nothing" is not achievable.

## The real event list

`hook_event_name` is a closed enum of **30** values in 2.1.220, extracted from the binary's own zod
schema, not from docs:

```
PreToolUse PostToolUse PostToolUseFailure PostToolBatch Notification UserPromptSubmit
UserPromptExpansion SessionStart SessionEnd Stop StopFailure SubagentStart SubagentStop
PreCompact PostCompact PermissionRequest PermissionDenied Setup TeammateIdle TaskCreated
TaskCompleted Elicitation ElicitationResult ConfigChange WorktreeCreate WorktreeRemove
InstructionsLoaded CwdChanged FileChanged DirectoryAdded MessageDisplay
```

The plan's five (`SessionStart`, `Stop`, `Notification`, `PreToolUse`, `PostToolUse`) are the wrong five.
**`PermissionRequest` is the event the product actually needs and it was not in the plan.**

Hook types are `command`, `http`, `prompt`, `agent`, `mcp_tool`. `http` POSTs the payload straight to a
URL with no process spawn. `command` hooks additionally support `async: true` and `asyncRewake`.

### Common envelope, on every event

```json
{
  "session_id": "7eb7c63d-b182-41a5-bd01-fadc23af2e04",
  "transcript_path": "~/.claude/projects/<slug>/7eb7c63d-….jsonl",
  "cwd": "…/spikes/hooks/workdir",
  "prompt_id": "2fb24fd0-…",
  "permission_mode": "default",
  "hook_event_name": "…",
  "effort": { "level": "high" }
}
```

`agent_id` / `agent_type` appear **only** for events originating inside a subagent. `prompt_id` is absent
until the first user turn. `SessionStart` carries neither `prompt_id` nor `permission_mode`.

## Observed order — interactive session, one turn with a permission prompt

```
SessionStart(source=startup)   ← command hook only, see gap G1
InstructionsLoaded ×3
UserPromptSubmit
PreToolUse(Bash)
PermissionRequest(Bash)
Notification(permission_prompt)     +6004 ms
PostToolUse(Bash)
PostToolBatch
Stop
SubagentStop(agent_id=…)            +3777 ms AFTER Stop
SessionEnd(reason=other)
```

Print mode is the same minus the permission pair. `Setup` never fired (keyed to init/maintenance).
`PreCompact`/`PostCompact`/`SubagentStart`/`TeammateIdle`/`Task*`/`Elicitation*`/`CwdChanged`/
`FileChanged`/`DirectoryAdded`/`ConfigChange` were registered and did not fire in these scenarios.

## Measured latency

Ground truth is external in every row — the tool printing its own epoch-millis, a timestamped PTY screen
write, or a timestamped `stream-json` line. Never Claude's own reported time.

| Transition | Ground truth | Hook | Latency |
|---|---|---|---|
| Bash tool finished | tool printed `T0 1785076558379` | `PostToolUse` (**http**) | **6 ms** |
| same | same | `PostToolUse` (**command**) | **31 ms** |
| model emitted `tool_use` | stream line | `PreToolUse` | **18 ms** |
| permission dialog painted | PTY write | `PermissionRequest` | **1 ms** |
| final assistant text | stream line | `Stop` | **25 ms** |
| process spawn | PTY note | `SessionStart` (command) | **359 / 1145 ms** |
| permission dialog painted | `PermissionRequest` receipt | `Notification(permission_prompt)` | **6004 / 6005 / 6002 ms** |

The useful events land in **6–31 ms** — inside the M2 exit criterion of 1 s with two orders of magnitude
of headroom. The extra ~25 ms on command hooks is process spawn, cheap enough to afford where the extra
context matters.

## Notification is NOT the needsInput signal

The plan said `Notification` is "the closest thing to needs input". **That assumption is wrong and should
be dropped.** Four independent reasons:

1. **It is 6.00 s late by design.** The permission dialog calls a debounced notifier (`6000` in the
   binary) that fires only once the user has been idle 6 s. Measured 6004, 6005, 6002 ms across three
   sessions — a fixed timer, not jitter.
2. **It is suppressed while the user is typing.** The same guard means an attentive user never generates
   the event at all. A key that lights only once the user has stopped working is the wrong shape for a
   fast-glance product.
3. **It is interactive-only.** The notifier is a React effect in the TUI; `-p` sessions never emit it.
4. **The channel is shared with ten unrelated things.** `notification_type` values in the binary include
   `permission_prompt`, `idle_prompt`, `agent_needs_input`, `agent_completed`, `worker_permission_prompt`,
   `auth_success`, `push_notification`, `computer_use_enter`, `computer_use_exit`,
   `elicitation_complete`, `elicitation_response`. Consuming it means getting login toasts for free.

**`PermissionRequest` is the correct signal: 1 ms, unconditional, and it carries `tool_name`, `tool_input`
and the exact `permission_suggestions` the dialog is offering** — which is also what accept/reject need
to act on.

```json
{
  "hook_event_name": "PermissionRequest",
  "session_id": "7eb7c63d-…",
  "permission_mode": "default",
  "tool_name": "Bash",
  "tool_input": { "command": "/bin/echo permission-probe", "description": "Echo a test string" },
  "permission_suggestions": [
    { "type": "addRules", "behavior": "allow", "destination": "localSettings",
      "rules": [ { "toolName": "Bash", "ruleContent": "/bin/echo permission-probe *" } ] }
  ]
}
```

Keep `Notification` as a **secondary** subscription matched to `idle_prompt` (fires after
`messageIdleNotifThresholdMs`, default 60000) — a genuine "waiting on a human for a minute" signal no
other event provides.

## Event → state mapping

| App state | Primary event | Latency | Confidence |
|---|---|---|---|
| `unassigned` | *none* | — | Our slot model, correctly unobservable |
| `idle` | derived — `Stop` then decay, or `Notification(idle_prompt)` at 60 s | 25 ms / 60 s | **Partial.** No event fires at the instant a session becomes idle |
| `running` | `UserPromptSubmit`, then `PreToolUse`/`PostToolUse`/`PostToolBatch` | 18–25 ms | **Solid.** Directly witnessed |
| `complete` | `Stop` with `agent_id` absent | 25 ms | **Solid** if subagents are filtered |
| `needsInput` | `PermissionRequest`; also `Elicitation`, `PreToolUse(AskUserQuestion)` | 1 ms | **Solid.** Best-measured signal in the spike |
| `error` | `StopFailure`, `PostToolUseFailure` | unmeasured | **Unverified.** Registered in 12 sessions, never fired |
| `unknown` | *none* | — | No heartbeat event exists; needs our own liveness check |

`SessionEnd(reason)` closes a slot; `SessionStart(source)` opens one and distinguishes
`startup`/`resume`/`clear`/`compact`/`fork`.

## Gaps

**G1 — `SessionStart` is silently dropped for `http` hooks.** Isolated with three single-variable runs:

| SessionStart config | Events received |
|---|---|
| `{"type":"http"}`, no matcher | **0** |
| `{"type":"http"}`, `"matcher":"startup"` | **0** |
| `{"type":"command"}`, no matcher | **1** |

Matcher is irrelevant; the hook *type* is the cause. Every other event delivered fine over http.
**The installer must use a `command` hook for `SessionStart`** or it will never learn a session exists.

**G2 — Hooks are edge-triggered only. No snapshot, no query.** A panel opening mid-session learns nothing
until the next transition, which for a long turn can be minutes. **This makes transcript tailing
mandatory, not a fallback**, and it is the only route to sessions that started before installation.

**G3 — No heartbeat, and `SIGKILL` produces no `SessionEnd`.** So `unknown` is unreachable from the hook
stream. Cheap fix found: a `command` hook receives `CLAUDE_PID`, so record the pid at `SessionStart` and
poll `kill(pid, 0)`.

**G4 — Subagent events will thrash the panel if unfiltered.** A `SubagentStop` landed **3.8 s after** the
main `Stop` with the same `session_id`. Its only distinguishing mark is the presence of `agent_id`. Any
event carrying `agent_id` must not move the slot's state.

**G5 — Hooks block the transition, synchronously.** Default timeout 600 s; the spike set 5 s per hook.
Every state change in every bound session waits on our listener. `async: true` exists for `command` hooks
only, not `http`. **A wedged listener degrades the user's Claude Code — a worse failure than a wrong
colour on a key.** Either use `command` + `async: true`, or accept `http` and treat listener latency as a
hard budget.

**G6 — `PermissionDenied` never fired.** Registered throughout; not reachable via `--permission-mode
dontAsk` in print mode either. Selecting "No" through the PTY driver was not reliable, so the deny path
is **unverified**. Consequence: clearing `needsInput` after a *rejection* has no proven signal — only
after an approval, via `PostToolUse`.

**G7 — Print mode has no permission lifecycle.** `-p` with a non-approved tool emits `PreToolUse` then
`PostToolBatch`, with no `PermissionRequest`, no `PermissionDenied`, no `PostToolUse`. Relevant if owned
sessions are ever spawned with `-p`.

## Session identity

`session_id` is a UUID on **every** event, stable for the session's life, sufficient to attribute an event
to a session. Verified identical across all events of a session in every run.

It is **not** sufficient to attribute a session to a terminal window, which the focus task needs. The HTTP
payload has no pid and no tty. A `command` hook does — it runs as a child of the CLI and receives
`CLAUDE_PID`, `CLAUDE_CODE_SESSION_ID`, `CLAUDE_PROJECT_DIR`, `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_EFFORT`,
`CLAUDE_CODE_EXECPATH`, `CLAUDE_CODE_CHILD_SESSION`, `CLAUDECODE`, plus inherited `TERM_PROGRAM`.

Verified `CLAUDE_PID` is the CLI process and resolves to a controlling tty in a real interactive session:

```
5409 ttys011  …/2.1.220 --model sonnet --settings …      (TERM_PROGRAM=ghostty)
4427 ??       …/2.1.220 -p Run exactly this bash command… (entrypoint=sdk-cli)
```

So the binding chain is `session_id → CLAUDE_PID → tty + TERM_PROGRAM → terminal window`, and it requires
at least one `command` hook. Combined with G1 and G3 this settles the design: `SessionStart` is a
`command` hook enriching the payload with pid/tty/term; high-frequency events stay `http`.

Not verified: whether `session_id` survives `--resume` and `/clear`. `SessionStart.source` reports which
happened, but id reuse was not tested, so slot re-binding across a resume is open.

## Coexistence with the user's existing hooks

The machine already had a user `PreToolUse` hook (matcher `Bash`). With our hooks loaded as the `flag`
source, **both ran** on every Bash call — two hook_started/hook_response pairs in the stream, and the
user's own rewriting still worked. Groups from different sources are additive; identical commands/URLs are
deduplicated.

Two consequences for the installer:

- For **observed** sessions we must edit `~/.claude/settings.json`, and the edit is an *append* to
  `hooks.<Event>[]`, never a replacement. Merging is proven safe.
- For **owned** sessions we spawn ourselves, `--settings <our own file>` gives the same coverage with
  **zero writes to the user's config**. That removes the consent problem entirely for the half of the
  product that can actually act on state. Worth taking.

## Verdict

Hooks are the right primary state source, but not sufficient alone, and the plan needs three corrections.

**Sufficient for** `running`, `complete`, `needsInput` — the three states the product is built around — at
6–31 ms, beating the 1 s requirement by 30×. Push, no polling, real semantics, and `PermissionRequest`
carries enough payload to drive the accept/reject keys as well as the colour.

**Not sufficient for** `unassigned` and `unknown` (ours by definition), `idle` (derived, no event marks
the instant), `error` (**unverified** — nothing failed in 12 sessions), and the entire cold-start case (G2).

Corrections:

1. **Replace `Notification` with `PermissionRequest`** as the `needsInput` source; keep `Notification`
   only for `idle_prompt`.
2. **`SessionStart` must be a `command` hook** (G1), which also yields pid/tty for foregrounding and
   liveness. `http` for the rest.
3. **Transcript tailing is required, not a fallback** (G2) — on the critical path for M2.

Remaining work before this is fully closed: reproduce a real turn failure to confirm `StopFailure` (the
only `error` candidate), and drive the permission deny path to confirm `PermissionDenied` (G6). Neither
blocks the architecture; both change how honest the `error` key can be at M2.
