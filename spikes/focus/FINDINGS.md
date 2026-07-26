# T-VCMPLAN1-004 — Foregrounding a foreign terminal session

Run 2026-07-26. macOS 26.5.2 (25F84), Command Line Tools only. Every result below comes from a script
that was actually executed; nothing is inferred from documentation.

## Emulators present

| Emulator | Installed | Notes |
|---|---|---|
| Terminal.app | yes | `/System/Applications/Utilities` |
| iTerm2 | yes | 3.6.11 |
| cmux.app | yes | hosts 3 of the 4 live agent sessions on this machine |
| Ghostty | **no** | see trap below |
| WezTerm, Alacritty, kitty, Warp | no | not tested, no claims made |
| tmux | yes | 3.6b |
| IDE terminals (GoLand, VS Code, Zed) | yes | one live `claude` sits in a GoLand terminal |

Trap worth knowing before any detection code is written: inside cmux, `TERM_PROGRAM=ghostty`, because
cmux embeds libghostty — and Ghostty is not installed on this machine at all. **`TERM_PROGRAM` identifies
a terminal implementation, not the app that owns the window.** Detection must walk the process tree; the
environment variable will send you to an app that does not exist.

## The identification chain

`host-for-pid.sh` implements it and prints `<tty> <host .app> <tmux target>`:

1. `ps -o tty= -p <pid>` → `ttys007` → `/dev/ttys007`. (An earlier draft of this document wrote the
   field as `s007`; the running `ps` prints `ttys007`, and fixtures built on the wrong form fail.) A process showing `??` has no controlling terminal and
   is unfocusable by any path here.
2. If tmux is installed, match the tty against
   `tmux list-panes -a -F '#{pane_tty} #{session_name}:#{window_index}.#{pane_index}'`. This must come
   first: a pane's parent chain dead-ends at the tmux server, whose parent is launchd, so the tree walk
   cannot find the host from a pane.
3. Otherwise walk PPID until an ancestor's executable path contains `.app/Contents/MacOS/` — that is the
   owning bundle. Reliable in every case tested, including `claude → zsh → login → cmux.app` and
   `claude → zsh → GoLand.app`.
4. For a tmux pane, resolve the host from the attached client's tty
   (`tmux list-clients -t <session> -F '#{client_tty}'`) and run the walk on that.

Verified against the four `claude` processes actually running here:

```
pid 22755 -> /dev/ttys000 /Applications/cmux.app          -
pid 42513 -> /dev/ttys001 /Applications/cmux.app          -
pid 59794 -> /dev/ttys002 ~/Applications/GoLand.app       -
pid 26648 -> /dev/ttys010 /Applications/cmux.app          -
pid 98167 -> /dev/ttys026 Terminal.app                    vcmspike:1.1
```

One bug found and fixed while testing, because it is exactly the class of failure that ships silently: an
unscoped `tmux list-clients` returned a client of an **unrelated** session, so a detached session was
reported as living in a Terminal.app window. `-t <session>` fixes it; a detached session must report "no
host" and be handled, not guessed at.

## Support matrix

| Emulator | Installed | TTY→window mapping | Script works | Permission | Reliability |
|---|---|---|---|---|---|
| Terminal.app | yes | yes — `tty of <tab>` | **yes**, 5/5 window cases + 4/4 as tmux host | Automation → Terminal | Solid. Window ids stable; wrong-window case returns `notfound` and changes nothing. Tab *selection* untested (caveat below). |
| iTerm2 3.6.11 | yes | yes — `tty of <session>`, incl. splits | **yes after rewrite**, 10/10 across windows, tabs, splits | Automation → iTerm2 | Works, but only one exact call sequence works and six documented ones silently do not. Brittle across updates. |
| cmux.app | yes | **no** | partial — app raised, panel not targeted | Automation → cmux | Real sdef with `focus`/`select tab`, but a terminal panel exposes only id, title and working directory. No tty, no pid. Titles were all "Terminal"; two panels shared one cwd, twice. Nothing to match on. |
| GoLand | yes | no | app-level only, 3/3 | Automation → GoLand | `activate` works; `windows` errors -1728. No tab model. |
| VS Code, Zed | yes | no | app-level only | Automation → app | `windows` errors -1728. |
| Ghostty, WezTerm, Alacritty, kitty, Warp | no | untested | untested | — | Not installed. No claim either way. |

Caveat on Terminal.app tabs: a second tab could not be created to test with. Terminal has no scriptable
"new tab" — `do script … in window id N` reuses the existing tab (verified: `tabs=1` afterwards), and the
keystroke route needs Accessibility, which is denied here. The equivalent "raise a non-frontmost view
inside the right window" case is covered by the tmux pane results (4/4). `set selected of tab N to true`
is one statement in the same script and errors loudly if it fails, so the risk is low but untested.

## Terminal.app — works

Verified sequence:

```applescript
set selected of tab foundIdx of window id foundID to true
set index of window id foundID to 1
activate
```

Results, each attempt starting from another app in front:

```
windowA:       intra=PASS front=PASS
windowC:       intra=PASS front=PASS
windowB:       intra=PASS front=PASS
windowA again: intra=PASS front=PASS
bogus tty:     notfound, nothing raised   <- correct
```

Two real traps, both hit during this spike:

- `windows` yields **positional** references. After `set index of w to 1` the reference `w` points at a
  different window. The first version read `id of w` after reordering and reported a window id that did
  not own the requested tty — it happened to raise correctly but reported the wrong thing, and any
  further work through `w` would have acted on the wrong window. Capture the id first, then address
  everything through `window id <n>`.
- `tell application "Terminal" to …` **launches Terminal if it is not running.** The first probe of this
  spike started Terminal on a machine where it had not been open. Both scripts now guard with
  `System Events → exists process`. In the real app use `NSWorkspace.runningApplications`, which needs no
  permission and cannot launch anything.

## iTerm2 — works, and is a minefield

What does **not** work in 3.6.11, all silent or misleading:

| Attempt | Result |
|---|---|
| `set current tab of window id N to tab M` | error -10000 (sdef says rw) |
| `set current session of tab M to session K` | error -10000 (sdef says rw) |
| `set frontmost of window id N to true` | error -10000 (sdef says rw) |
| `set index of window id N to 1` | no error, no effect |
| `select session K of tab M of window id N` | no error, no effect |
| `close window 1` | no error, no effect |
| `select <session>` only | switches splits within the current tab only; does not switch tabs |
| `select <window>` first, then reuse refs below it | raised the **wrong tab** — refs invalidate on reorder |

Specifiers rooted at `window id N` are ignored across the board. The only thing that works is `select`
sent to a reference reached by iterating `windows`, applied outside-in, **re-finding the window after
every mutation**:

```applescript
-- phase 1: locate without mutating (positional refs die on reorder) -> wid, ti, si
-- phase 2:
repeat with w in windows
  if (id of w) is wid then select w
end repeat            -- window
repeat with w in windows
  if (id of w) is wid then select tab ti of w
end repeat            -- tab
repeat with w in windows
  if (id of w) is wid then select session si of tab ti of w
end repeat            -- split
activate
```

Before the rewrite: 2/15 correct, and the failures were not errors — the script returned `ok` while
leaving a different session current, and twice returned `notfound` for a session that provably existed.
That is the silent-wrong-target failure mode, observed rather than theorised. After the rewrite: 10/10
across two windows, two tabs and a split, including repeat hits on the same target.

Verdict for iTerm2: works, do not trust it to keep working. The one working path is undocumented
behaviour of iteration order sitting next to six broken documented ones. The app needs a self-test that
re-verifies the raise landed rather than trusting the `ok`.

## tmux — works, with two honest holes

Setup: session with two windows, a vertical split in the second, attached from a Terminal.app window.
Focus is `select-window` + `select-pane`, then raise the **client's** window (never the pane tty — a pane
tty belongs to no window).

```
w2-split-b:  active-pane=PASS host-window=PASS
w1:          active-pane=PASS host-window=PASS
w2-split-a:  active-pane=PASS host-window=PASS
w1-again:    active-pane=PASS host-window=PASS
```

4/4 on both signals. The most reliable path tested, because tmux answers the mapping question directly
instead of being interrogated through an Apple Events object model.

Two holes:

- **Detached session.** Pane selection succeeds but there is no window to raise; host resolves to `-`. The
  app must say "session is detached" and offer to attach, not silently do half the job.
- **Multiple clients on one session.** Verified with two clients attached: `select-window` moved **both**,
  and `list-clients` order decides which window gets raised — arbitrary. Focusing agent A can yank an
  unrelated screen the user was watching. Either surface it or scope it (`tmux switch-client -c <client>`,
  untested here).

## Permissions

| Path | Permission | Observed |
|---|---|---|
| `tell application "Terminal"/"iTerm2"/"cmux"/"GoLand"` | Automation, per source app × target app | Worked with no prompt — grants already exist for whatever app owns this shell. A freshly built bundle starts from zero and prompts once per target emulator. |
| `System Events → exists process` | Automation → System Events | Worked (Processes Suite, not Accessibility) |
| `System Events → keystroke` | **Accessibility** | **Denied**: `osascript is not allowed to send keystrokes. (1002)` |
| `System Events → windows of process` | **Accessibility** | **Denied**: `not allowed assistive access. (-25211)` |
| Reading the TCC database | Full Disk Access | Denied; grant state is not inspectable from here |

Onboarding consequences:

- Accessibility is denied here and **cannot be granted non-interactively**. Both denials arrived as
  ordinary error codes with **no dialog** — from a CLI context the user is never asked, the feature just
  fails. Anything needing Accessibility (AXRaise, keystroke injection, window lists for non-scriptable
  emulators) needs an explicit onboarding screen plus a runtime probe, because there is no prompt to rely
  on.
- A fresh Automation prompt was deliberately not triggered: doing so writes a permanent allow/deny
  decision into the user's TCC state. The per-app prompt is documented and unavoidable (denial surfaces
  as -1743) but the dialog itself was not exercised.
- Grants attach to the **responsible app bundle**, matching the bundling note in PLAN.md: a bare SwiftPM
  binary cannot hold Automation grants, so `Scripts/bundle.sh` is a prerequisite for this feature, not
  just for the hotkey.

## Latency

Warm, after the first call: **215–550 ms** for a Terminal.app raise, tmux path included. First call in a
process is 1.0–2.3 s (Apple Events bridge warm-up). Inside a click-to-focus budget, but the first click
after launch feels slow unless the bridge is warmed at startup.

## Fragility, stated plainly

- Two of the three code paths were **wrong in a way that produced no error** on the first attempt. Both
  reported success while raising the wrong thing. Any shipped version must verify after acting (re-read
  the front window's tty and compare) instead of trusting the return value.
- App-level activation could not be measured cleanly: a person was using this machine and Safari
  repeatedly took focus back. Isolated trials: Terminal 6/6, iTerm2 5/6 at 0.4 s settle, GoLand 3/3. Read
  that as "activation works, and a determined foreground app can win the race", not as a per-emulator
  difference.
- TTY numbers are recycled within minutes of a window closing. A cached tty must be re-validated against
  the live pid before any raise, or the app raises a stranger's window.
- On this machine, **0 of 4 live agent sessions are fully targetable**: three in cmux (no tty mapping),
  one in a GoLand terminal (no tab model). The two emulators that work fully had to be populated by the
  spike itself.

## VERDICT

**Click-to-focus cannot ship as a uniform, dependable feature. It ships as three explicitly different
tiers, and the UI must show which tier each bound session is in.**

- **Tier 1 — window and tab** (Terminal.app, iTerm2, tmux in either). Verified correct, sub-second,
  re-verifiable. Genuinely good where it applies.
- **Tier 2 — app only** (cmux, GoLand, VS Code, Zed, any emulator without a tty→window map). Bring the
  app forward, nothing more. Must be labelled — e.g. "raises cmux — cannot target the tab" — so landing
  on the wrong tab reads as a known limit rather than a bug.
- **Tier 3 — nothing** (no controlling tty, detached tmux, unknown host). Key visibly inert with a reason,
  same spirit as the capability-gated accept/reject keys. Detached tmux is the one case worth an action
  instead of a refusal: offer "attach".

Consequences for the plan:

1. The M2 exit criterion "focus works on the primary terminal" holds if that terminal is Terminal.app or
   iTerm2. It does **not** hold for the terminal the sessions on this machine actually live in. Either
   cmux gains a tty-capable focus route (its sdef is close — it needs `tty` or `pid` on a terminal panel),
   or the demo runs agents in iTerm2, or focus stays Tier 2 for the primary case. Decide before M2, not
   in the demo.
2. `focus.sh` is the reference shape for the Swift implementation: resolve → dispatch → return a tier,
   never a boolean. Exit codes 0 focused / 1 degraded / 2 impossible.
3. Add a startup self-test per emulator (raise a known session, verify, cache the tier). Only defence
   against an iTerm2 update silently downgrading the feature.
4. Focus alone does not carry the product in this machine's own configuration. The thesis survives — six
   keys showing truthful state is the core — but "one-click focus" must be described as per-terminal from
   the first line of copy.

## Housekeeping

Everything the spike opened was closed; Terminal.app, which was not running beforehand, was quit again.
No system or app settings were changed. `test-tmux.sh` leaves session `vcmspike` behind when re-run —
clean up with `tmux kill-session -t vcmspike`.
