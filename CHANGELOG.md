# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). This project has no
version scheme beyond the DMG tag below — see the status line in README.md for what "works" means
right now.

## [Unreleased]

### Added

- `Skills/v-micro-connect/`: the `/v-micro-connect` Claude Code skill, previously present only
  on the author's machine (`~/.claude/skills/`). README now documents installing it from the
  repo — without it, "Connecting a session by hand" was undocumented dead air for anyone who
  didn't already have it.
- README: a `vcm` zsh function for rebuilding-and-opening the app from source, and a note that
  managed (MDM) Macs may never offer Gatekeeper's "Open Anyway" at all — building from source
  sidesteps that instead of waiting on it.

### Removed

- Local machine/session data that had been committed by accident: a `.claude` scratch config
  (hashed machine and user IDs, a full session transcript) and several captured hook test runs
  under `spikes/`, all containing local absolute paths.
- Process and planning documents nothing in the source references: `tasks.md`, its supporting
  `Scripts/task.py`, `virtual-codex-micro-prd.md`, `docs/M1-REVIEW.md`. `PLAN.md` stays — six
  source files cite it directly as design rationale.
- Raw captured logs from the `spikes/` runs (`run*-events.jsonl`, `stream.jsonl`, `pty.jsonl`,
  etc.) superseded by each spike's `FINDINGS.md`. The scripts that produced them stay.
- Four third-party reference photographs of the physical Codex Micro hardware from `docs/` —
  not this project's to redistribute.
- The raw probe scripts under `spikes/` (~25 files: python/shell/AppleScript/Swift), once their
  `FINDINGS.md` already stated the load-bearing numbers. Kept the four files shipped code cites as
  ported verbatim from: `spikes/focus/host-for-pid.sh`, `raise-terminal.applescript`,
  `raise-iterm.applescript`, and `spikes/tailing/watch.py`.

## [0.1.0] - 2026-07-28

First downloadable build. Universal (Apple Silicon + Intel) DMG, ad-hoc signed, unnotarized.

### Added

- Floating `NSPanel` macro pad, eight agent keys, menu bar item, global hotkeys (summon / pin).
- Per-key state from live Claude Code sessions: idle, running, needsInput, complete, error,
  unknown, unassigned — each with its own glyph and fill so colour is never the only channel.
- State arbitration (`StateEngine`) across four sources — cmux events, Claude Code hooks,
  transcript tailing, and manual `/v-micro-connect` requests — on a confidence ladder
  (`inferred < reported < forced`), since the sources disagree constantly and none is sufficient
  alone.
- `LivenessMap`: one definition of "is this session's process still alive", checked against argv,
  hook-learned pids, persisted registry pids, and a working-directory join for a bare `claude`.
- Tiered focus resolution: exact window-and-tab for Terminal/iTerm2, app-only for everything else
  process-ancestry can identify, an attach offer for detached tmux. cmux sessions focus through
  cmux's own socket API instead.
- Approve/reject for permission prompts, wired through the cmux socket API.
- Claude Code hook installer (`VCM_HOOKPLAN` / `VCM_HOOKAPPLY`), backing up existing settings
  before writing.
- `/v-micro-connect` skill: sessions identify themselves by their own session ID rather than being
  guessed at, plus a forced-colour mode for testing the pipeline end to end.
- `status.tsv`, written on every state change, naming the source and confidence behind each key's
  colour.
- Checks in place of a test target (Command Line Tools ships neither XCTest nor swift-testing):
  `SelfCheck` (pure invariants), `PixelCheck` (contrast measured from rendered pixels, not the
  colour model), `check-render.sh` (light/dark render diff against committed baselines).
- Universal release packaging (`Scripts/package.sh`): per-architecture cross-compile plus `lipo`,
  no Xcode required.
- README, demo clips, DMG release.

### Fixed

- Two writers racing on one session's state (`pollCmux`, `ingest`) — last write won and dropped
  the cmux backend and its `.approve` capability. Unified into one `merge` point.
- `repoPath` decoded from the project-directory slug, where `-` stands in for both `-` and `/` and
  is not invertible — `codex-micro` was read back as `codex/micro` and compared unequal to itself.
  Now read from the transcript's own `cwd`, or left nil.
- Four divergent definitions of "session is alive" (cold-start poll, `VCM_PROBE`, transcript
  `updates()`, reconcile) — collapsed into `LivenessMap`, with no default argument left for a
  caller to silently fall back to the narrowest one.
- A pid claimed from the persisted registry could drop out of the ambiguity check, letting one
  live process get attributed to two sessions in the same directory.
- `needsInput` not clearing after a rejection, and the PTY injection gate staying open afterward.
- Renderer dropping blurred layers; the colour model disagreeing with measured rendered pixels.
- Key-cap contrast and colour-blind separation failures: the achromatic channel moved off the
  glyph's silhouette onto its ink coverage (filled vs. hollow), `error`'s glyph raised from
  3.48:1 to 5.29:1 against a 4.5 WCAG floor, and a measured glance-separation floor added
  alongside the existing whole-cap contrast ladder.

### Known issues

- Dark-mode `needsInput` halo carries almost no perceptible amber — see README "Known fault".
- Approve/reject works only for sessions under cmux; a plain terminal gets focus, not typing.
- Codex backend is designed (protocol supports it) but not implemented — no Codex install exists
  to build or test against.
- No test target; correctness rests on `SelfCheck` and `PixelCheck` instead of `swift test`.
