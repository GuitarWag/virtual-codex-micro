# Virtual Codex Micro — Feasibility Review & Delivery Plan

Reviewed against `virtual-codex-micro-prd.md`, 2026-07-26.

## Verdict

Feasible, with one structural correction to the PRD.

Everything visual and every window behaviour the PRD asks for is routine native macOS work:
`NSPanel` at `.floating` level with `.nonactivatingPanel`, SwiftUI content in an `NSHostingView`,
`.ultraThinMaterial` for the frosted keys, custom drag-driven rotary and 4-way pad. Phase 1 carries
almost no technical risk. The dial, joystick, glow states, light/dark tuning, keyboard access and
reduced-motion handling are all solved problems.

The risk is entirely in the backend layer, and the PRD understates it in one specific way.

## The correction: owned vs observed sessions

The PRD promises accept / reject / effort-change / push-to-talk against "the connected backend",
and treats that as one uniform capability. It is not. There are two very different situations:

**Observed sessions** — a `claude` or `codex` process the user started themselves in Terminal,
iTerm, Ghostty or tmux. We can read its state and we can raise its window. We *cannot* reliably
type into it. Injecting keystrokes into another process's TTY means either Accessibility keystroke
injection into whichever terminal happens to own it, or AppleScript per terminal emulator — fragile,
permission-gated, and silently wrong when the wrong pane has focus. Approving a pending diff this
way is the kind of thing that works in a demo and corrupts a real branch at 3am.

**Owned sessions** — a session the app itself spawned under its own pseudo-terminal. Here we control
stdin, so accept, reject, new session, slash commands and effort changes are all straightforward and
deterministic.

So the honest v1 capability matrix is:

| Action | Owned session | Observed session |
|---|---|---|
| Show normalized state | yes | yes |
| Foreground / focus | yes | yes, per-terminal support |
| Accept / reject | yes | no — key disabled, capability-gated |
| New session | yes | n/a |
| Effort / reasoning dial | yes | no |

This is not a downgrade of the product thesis. Six keys showing truthful state plus one-click focus
already delivers the "fast-glance awareness" the PRD is built on. What it does mean is that command
keys must be **capability-gated per bound session** rather than always-live, and the UI must show an
explicit `unknown` state instead of guessing. Drift between the panel and reality is the failure mode
the PRD itself names as risk #1 — the fix is to never render a confidence we don't have.

## M0 spike verdicts (2026-07-26)

Two of the four gates have reported. Both confirm the owned-vs-observed correction and both sharpen it
in ways the original plan got wrong.

**PTY control — RELIABLE WITH CAVEATS** (`spikes/pty/FINDINGS.md`). Injection into a pseudo-terminal is
deterministic: 30/30 landed, worst case 20ms, including bytes written before the child finished `exec`
and into a full-screen TUI mid-render. So the mechanism is not the problem. Two things are:

- Reading state back out of a TUI byte stream does not work. A prompt written across a redraw boundary
  is invisible to substring matching — the stub's question `Apply this patch to disk?` occupies one
  visual row but is written in three fragments out of order, and stripping escapes concatenates them in
  write order, not screen order. Worse, a match is not an event: one unanswered prompt produced 60 hits
  and stayed in the stream after the prompt was gone, so `contains(needle)` is sticky and would report
  "needs input" forever.
- Blind injection can be silently discarded. A child entering raw mode with `TCSAFLUSH` throws away
  anything queued before that call. Reproduced. So an accept keystroke is only safe once we *know* the
  prompt is up — which needs the detection we just established we do not have from the stream.

The escape is that we do not have to read the TUI at all. `claude --input-format stream-json
--output-format stream-json` is line-delimited JSON on the stdin/stdout we already own, carries
`session_id`, emits hook events inline, and `--replay-user-messages` gives the delivery confirmation
raw injection lacks. Measured under a PTY: 99% printable, one escape sequence in 20 KB, no
alternate-screen use.

Three findings that are correctness requirements, not preferences:

1. **`forkpty`, not `openpty` + Foundation `Process`.** `Process` offers no hook between fork and exec,
   so the pty never becomes the controlling terminal: job control, `SIGWINCH`, `^C` and hangup-on-close
   all stop working, and every child becomes a guaranteed orphan.
2. **A reader must drain the master continuously** for the life of every child, or the child blocks in
   `write()` and the session merely looks hung.
3. **Teardown must `killpg` then `SIGKILL` on a timeout.** The pty hangup is not cleanup — a child
   survived it once in 66 runs, and `SIGHUP`-ignoring grandchildren (language servers, MCP servers, node
   workers — exactly what an agent CLI spawns) survive every time while keeping the child's PGID.

**Transcript tailing — ship it, but only because it abstains** (`spikes/tailing/FINDINGS.md`). 93%
agreement with look-ahead truth over 13,677 observations, 0.9% wrong, 6.1% abstained to `unknown`, and
sub-250ms detection at a 200ms poll. Good enough to make six keys useful the moment the panel opens.

But the headline is a hard limit: **a pending permission prompt produces no transcript record at all.**
Nothing is written between a `tool_use` and its `tool_result`, so a `Bash` call that ran for 100 minutes
and an approval prompt that sat open for 145 minutes before being rejected have byte-identical tails.
The denial is recorded only after the user answers. The single exception is `AskUserQuestion`, whose tool
name is in the `tool_use` block and which exists only to wait for a human.

So `needsInput` — the state the PRD's entire fast-glance thesis rests on — is not inferrable from disk.
**Hooks are not a latency optimisation over tailing; they are the only source for the amber key.** If a
user declines the hook installer, the panel must say `needsInput` is unavailable rather than quietly
never lighting up.

Three implementation constraints fell out of it: subagent transcripts must be excluded (they never
contain a turn-boundary record, so every one looks permanently mid-turn and would add phantom running
siblings); the session-to-process join must use the candidate id set rather than the filename (a resumed
session's records carry a different `session_id` than its filename, so filename matching reports live
sessions as dead); and a `ps` liveness join must ship alongside, because without it "idle" and "crashed"
are the same colour.

## Where state actually comes from

For Claude Code there are two viable sources, and they should both exist:

1. **Hooks (primary).** `SessionStart`, `Stop`, `Notification`, `PreToolUse`, `PostToolUse` entries in
   `~/.claude/settings.json` can push events to a local listener. This is a push channel with real
   semantics — `Notification` in particular is the closest thing to "needs input". Low latency,
   no polling, no guessing. Cost: we must edit the user's settings file, which needs consent and an
   idempotent installer that never clobbers existing hooks.
2. **Transcript tailing (fallback).** Session JSONL under `~/.claude/projects/<slug>/` is appended
   live; FSEvents plus a tail gives state inference for sessions that predate hook installation.
   Less precise, but it covers the cold-start case where the panel opens mid-session.

**Claude Code is the only backend in scope.** Codex CLI is not installed on the development machine,
so anything written about its capabilities would be guesswork and anything built against it would be
untested. Tasks 031, 032 and the Codex spike are parked in the board's blocked column with their
scope recorded, not deleted — this answers PRD open question #1 by circumstance as much as by
judgement, and it drops the PRD's second P0 adapter from v1 outright.

What keeps that reversible is the adapter boundary, and it earns its keep even with one provider.
Capabilities are declared per session rather than per backend, because owned and observed Claude
sessions already differ in what they accept — the same mechanism a second provider would use later.
M2 proves the boundary by keeping the mock adapter (task 015) bindable to a real slot next to live
sessions, with deliberately different declared capabilities. If the UI needs to know which adapter it
is talking to, the protocol is wrong, and that is cheaper to discover in September against a mock
than in a future month against a real second backend.

For the record, whenever Codex does come into scope: session logs sit under `~/.codex/sessions/`, and
a `notify` setting in `~/.codex/config.toml` may invoke an external program on turn events, which
would be a partial push channel rather than log-tailing only. Unverified — that is what the parked
spike is for.

## Other PRD open questions, answered

- **Exactness of the replica** — preserve zone order, relative positions and key count; optimise
  absolute proportions for pointer targets. Recognisable structure, not traced geometry. This also
  keeps distance from the brand-confusion risk.
- **Click-through when idle** — yes, `ignoresMouseEvents` toggled on idle, but ship it in M4. It is a
  polish feature and it makes the app feel broken if it lands before state is trustworthy.
- **Joystick presets global or per-project** — global defaults with per-project override. Per-project
  only is too much setup for the activation metric; global only breaks for anyone with more than one
  repo.
- **More than six waiting agents** — an overflow affordance on the key cluster (count badge plus
  paging), never silent truncation. A panel that hides a blocked agent is worse than no panel.

## Build environment

Verified on this machine, 2026-07-26: macOS 26.5.2, Swift 6.3.3, **Command Line Tools only — no
Xcode**. That single fact reshaped four decisions, so it is worth stating plainly rather than
rediscovering it later.

| Wanted | Available? | What we do instead |
|---|---|---|
| `xcodebuild`, `.xcodeproj` | no | SwiftPM package, `swift build` |
| Asset catalog for colours (`actool`) | no | Colours defined in Swift with dynamic light/dark resolution |
| `XCTest` / `swift-testing` | neither | Assert-based `SelfCheck`, run via `VCM_SELFTEST=1` |
| `notarytool`, `stapler` | no | Ad-hoc signing for dev; notarization needs Xcode installed |
| SwiftUI, AppKit, `NSPanel` | yes | Confirmed compiling and launching |

Two of these are genuinely fine — a SwiftPM package with zero dependencies is a better fit for this
app than an Xcode project, and code-defined colours are more testable than a catalog, since the
contrast ratios can be asserted rather than trusted. The other two are real gaps: no test framework
means invariants live in a hand-rolled self-check, and notarization in M4 is blocked until Xcode is
installed.

One thing the bundling script exists for, non-obviously: TCC (Accessibility, Automation) and Carbon
hotkey registration both identify an app by bundle identity. A bare SwiftPM executable cannot hold
either grant, and the permission would be re-prompted or silently denied. So `Scripts/bundle.sh`
wraps the binary in an ad-hoc signed `.app` — needed from M1 for the global hotkey, not at ship time.

The `tasks` CLI is also absent and has no discoverable installer, so `Scripts/task.py` is a ~90-line
stand-in that reads and writes `tasks.md` in the identical format. Installing the real CLI later is a
drop-in replacement.

## Distribution constraint

Reading `~/.claude`, spawning processes under a PTY, and Automation/Accessibility access mean the App
Store sandbox is not realistic. Plan for direct distribution: notarized DMG plus Sparkle updates.
Decide this in M0, not after the entitlements fight starts.

## Scope changes from the PRD

- **Codex adapter cut from v1.** The PRD lists it P0; there is no Codex install to build or test
  against. Parked with scope intact, reachable through the existing adapter protocol when it returns.
- **Push-to-talk demoted P1 → P2.** It is a whole speech subsystem (`SFSpeechRecognizer`, mic
  permission, hold-to-record UX) and it is orthogonal to the core thesis. Ships in M3 at the earliest.
- **Command keys become capability-gated**, per the matrix above.
- **`unknown` added to the state model** as a seventh visual state, distinct from `Unassigned`.
  Required for honesty when a source goes quiet.

## Milestones

| Milestone | Goal | Exit criteria | Target |
|---|---|---|---|
| **M0 — De-risk** | Prove the four unknowns before writing product code | Written verdict on PTY control, hook push, transcript tailing, foreign-window focus; architecture + distribution decision recorded | 2026-08-02 |
| **M1 — Visual prototype** | PRD Phase 1: convincing panel, no backend | Panel floats, summons by hotkey, all 4 zones interactive, mock driver cycles all states, full keyboard + VoiceOver, light/dark/high-contrast/reduced-motion all pass | 2026-08-23 |
| **M2 — Claude Code MVP** | PRD Phase 2: one backend, truthfully | Bind 6 real sessions; state correct within 1s of a real transition; accept/reject work on owned sessions; focus works on the primary terminal; capability gating visible; no false state after sleep/wake; **one slot driven by the mock adapter alongside real ones, with differing capabilities, to prove the protocol boundary holds** | 2026-09-27 |
| **M3 — Config & workflows** | Remapping and presets as first-class | Key remapping and pad presets editable; global + per-project resolution working; push-to-talk on owned sessions | 2026-10-25 |
| **M4 — Ship** | Public build | Notarized DMG, Sparkle channel, first-run flow that binds a key inside two minutes, opt-in local metrics, click-through idle mode, copy/visual legal pass | 2026-11-15 |

M0 is a gate, not a formality. If the PTY spike shows we cannot drive an owned `claude` session
cleanly, the command cluster collapses to focus-only and the product should be rescoped before M1
spends three weeks on chrome.

## Task board

See `tasks.md` — 33 active tasks plus 3 blocked, tagged by milestone (`m0`…`m4`, `deferred`) and area
(`spike`, `panel`, `ui`, `state`, `backend`, `a11y`, `config`, `ship`).
