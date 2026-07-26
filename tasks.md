# Virtual Codex Micro

> Native macOS floating macro pad for AI coding agents. Milestones M0–M4, see PLAN.md.

## TODO

- [ ] [T-VCMPLAN1-049] **error's light glyph sits at 3.48:1 against a 4.5 WCAG floor** `priority:high` `assignee:claude` `tags:m1,a11y` `due:2026-09-06`
  > Measured off rendered pixels, not modelled. It is ratcheted as a non-regressable ceiling rather than silently lowered, so it cannot get worse without failing, but it is below the standard the rest of the palette meets. The trap is that it is coupled: darkening error's glow to lift the glyph to 4.23 drove running/error separation down in lockstep, 1.59 to 1.29. So this cannot be fixed by nudging one value - it needs the achromatic channel moved off the fill, which is the same structural change task 048 describes.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [ ] [T-VCMPLAN1-050] **Visible-cap separation collapses to 1.17:1, far below the centre we enforce** `priority:high` `assignee:claude` `tags:m1,a11y` `due:2026-09-06`
  > The pixel check measures two bands and prints both: the cap centre, where the floor is enforced, and the whole visible cap. Centre is 1.57-1.67; the visible cap is 1.17-1.43, because the shared white frosted rim saturates it. So at a glance, across the full key face, lit states are much closer in brightness than the enforced number suggests - which is the greyscale and colour-blind discrimination the ladder exists to protect.
  > Enforcing on the visible cap instead is NOT the fix, and there is evidence: re-applying the historical full-face frost moved the visible cap by 0.01 while the centre moved 0.17, so a floor low enough to pass the visible band today would be a check that can never fail. The real fix is to stop asking the fill to carry the achromatic channel - see 048.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [ ] [T-VCMPLAN1-048] **Move the achromatic channel off the cap fill** `priority:high` `assignee:claude` `tags:m1,a11y,ui` `due:2026-09-13`
  > The root cause behind 038, 049 and 050, named independently by the M1 re-review and the pixel-check work. Five 1.8:1 luminance steps need 18.9:1 of range; the reference device's lit cap band offers 1.17:1, and every fix inside the fill trades one pair against another - it is saturated. Chroma already matches the reference (ours 0.30-0.56 peak against 0.35-0.50); the mismatch is luminance. So the fill should carry hue and the second, non-colour channel should live somewhere with room: the glyph, an edge treatment, or the halo. Until this lands, greyscale discrimination stays weaker than the ladder's declared intent.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [ ] [T-VCMPLAN1-043] **The tailer must clear amber after a rejection** `priority:critical` `assignee:claude` `tags:m2,backend,state` `due:2026-09-13`
  > Witnessed in spikes/needsinput: rejecting a permission prompt emits NO hook event whatsoever. Not PermissionDenied, not Stop, not PostToolUseFailure, and no Notification even after 170s idle. So the hook stream leaves a rejected slot amber forever. The transcript DOES mark it - `tool_result.is_error = true` plus the literal `[Request interrupted by user for tool use]` - so ClaudeTranscriptSource is the only thing that can clear needsInput on the reject path. This is a new requirement on a source currently scoped to running/idle/liveness only, and it sits on the M2 critical path: without it the amber key is permanently stuck after the first rejection.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [ ] [T-VCMPLAN1-044] **Accept/reject must read permission_suggestions, not a hard-coded option index** `priority:high` `assignee:claude` `tags:m2,backend` `due:2026-09-13`
  > The needsInput spike drove deny with the keystroke `3`, which worked because that Bash prompt happened to list No third. A prompt with a different option list puts No at a different index, so injecting a fixed digit would answer the wrong option - and on an approval dialog answering the wrong option is the worst available failure. PermissionRequest carries the full `permission_suggestions` array; the keystrokes must be derived from it. Note the spike also confirmed both reject affordances work through a PTY (option number and ESC), which closes the hook spike's G6 caveat about deny being unreliable to drive.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [ ] [T-VCMPLAN1-049] **error's glyph renders at 3.48:1 and the ladder has no room to fix it** `priority:high` `assignee:claude` `tags:m1,a11y` `due:2026-08-30`
  > Found by the new rendered-pixel check (task 037), which is why it was invisible before: the model measures error's white glyph at 5.12:1 against composedKeyFill, the rendered cap measures 3.48:1 against a 4.5 WCAG floor. The cap centre under the glyph is the state glow at 0.85 opacity, and the glow is lighter than the fill. It is not tunable: sweeping error's lightGlow darker walked the glyph up 3.48 -> 3.76 -> 3.99 -> 4.23 and walked running-vs-error down 1.59 -> 1.46 -> 1.37 -> 1.29 in lockstep, because red cannot pass 0.21 relative luminance while staying red and running is pinned beneath it by blue's 0.07 ceiling. Needs a glyph treatment that does not depend on the cap under it - an outline or a shadow, or dark ink with the ladder rebuilt around it. Recorded in PixelCheck.knownGlyphShortfall as a ceiling meanwhile, so it cannot quietly get worse; delete that entry when this is fixed.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [ ] [T-VCMPLAN1-050] **Measured across the whole cap, the frost flattens the luminance ladder to 1.17** `priority:high` `assignee:claude` `tags:m1,a11y,ui` `due:2026-08-30`
  > The ladder holds where the state lives and collapses where the eye looks. PixelCheck measures both bands and prints them side by side: on the state-bearing centre the tightest lit pairs are 1.57-1.71, but across the whole visible cap the same pairs are 1.17-1.77 - worst error vs unknown in dark at 1.17, running vs unknown in light at 1.18 - against a model claiming 1.81-1.83. Cause is plasticShell, which ramps every cap's rim to 80% white; that white is shared by all six caps, so it pulls them toward each other. This is precisely the property the ladder exists for, because a glance and peripheral vision integrate the whole cap, so greyscale and deuteranope legibility are worse than the enforced floor suggests. Deliberately NOT enforced at that band: it is saturated, and re-applying the historical full-face frost regression moves it by 0.01, so a floor there could not fail - evidence in PixelCheck.capOuter. Fixing it means less rim white or a larger clear centre, then re-measuring both bands.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

## IN PROGRESS

## DONE

- [x] [T-VCMPLAN1-006] **Scaffold Xcode project and build config** `priority:high` `assignee:claude` `tags:m1,panel` `due:2026-08-05`
  > Done, with scope amended by the environment. This machine has Command Line Tools only — no Xcode — which rules out xcodebuild, .xcodeproj, actool for asset catalogs, XCTest and swift-testing. So: SwiftPM executable target instead of an Xcode project, macOS 14 minimum, accessory activation policy set programmatically rather than via LSUIElement in a dev Info.plist, and an assert-based self-check run with VCM_SELFTEST=1 instead of a test target. Scripts/bundle.sh assembles an ad-hoc signed .app because TCC and Carbon hotkey registration both key off bundle identity and neither will attach to a bare SwiftPM binary. Verified: builds clean, self-check passes, bundled app launches. Zero dependencies.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [x] [T-VCMPLAN1-009] **Layout spec and device silhouette frame** `priority:high` `assignee:claude` `tags:m1,ui` `due:2026-08-12`
  > Single source-of-truth layout definition covering all four zones: six agent keys, command cluster, dial on the right, four-way pad lower-left. Rounded device-like silhouette instead of standard window chrome. Positions and ordering follow the reference control map; absolute proportions get tuned for pointer hit targets rather than traced. Every downstream component reads geometry from this one file so a spacing change never means editing six views.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [x] [T-VCMPLAN1-011] **State colour tokens for light, dark and high contrast** `priority:high` `assignee:claude` `tags:m1,ui,a11y` `due:2026-08-14`
  > Semantic colour set defined in Swift code — NOT an asset catalog, because actool ships with Xcode and this machine has Command Line Tools only. Light and dark variants plus a high-contrast pair for each state: white idle, blue running, green complete, amber needs-input, red error, dim unassigned, grey-hatched unknown. Verify contrast of the paired label text against the key fill in all four appearance combinations. Colours are named by meaning, never by hue, so a later palette change touches one place.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [x] [T-VCMPLAN1-001] **M0 gate: spike PTY control of an owned agent session** `priority:critical` `assignee:claude` `tags:m0,spike,backend` `due:2026-07-31`
  > Throwaway harness that spawns `claude` under a pseudo-terminal (Foundation Process + openpty, or SwiftPTY), reads its output stream, and injects input: a plain prompt, an approval keystroke on a pending diff, and a slash command such as effort change. Measure whether input lands deterministically when the child is mid-render, and whether output is parseable enough to detect a pending approval. Deliverable: harness in spikes/pty/ plus a verdict paragraph in PLAN.md. This gates the entire command-key cluster — if injection is unreliable, command keys become focus-only and M1 scope shrinks before we spend three weeks on chrome.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [x] [T-VCMPLAN1-003] **M0: spike transcript tailing as cold-start fallback** `priority:high` `assignee:claude` `tags:m0,spike,state` `due:2026-08-01`
  > Watch ~/.claude/projects/<slug>/*.jsonl with FSEvents and infer state from the tail of the record stream (last message role, unresolved tool_use, error entries). Needed because hooks only cover sessions that started after hook installation, and the panel will routinely open mid-session. Compare inferred state against ground truth from the hook spike on the same session. Deliverable: accuracy note and a decision on whether tailing is good enough to ship as fallback or only as a hint.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [x] [T-VCMPLAN1-007] **Floating NSPanel shell** `priority:critical` `assignee:claude` `tags:m1,panel` `due:2026-08-08`
  > NSPanel subclass with .nonactivatingPanel and .titled styles suppressed, level .floating, collectionBehavior .canJoinAllSpaces plus .fullScreenAuxiliary, hosting SwiftUI via NSHostingView. Must not steal focus from the editor when shown, must survive Space switches and display reconfiguration, and must restore its last screen position across launches. Pin toggle switches between always-visible and hide-on-focus-loss. This is the load-bearing piece of the whole product; the rest of M1 hangs off it.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [x] [T-VCMPLAN1-008] **Global hotkey to summon, hide and pin** `priority:high` `assignee:claude` `tags:m1,panel` `due:2026-08-09`
  > System-wide shortcut registration that works while another app is frontmost. Use Carbon RegisterEventHotKey (or the KeyboardShortcuts package if a recorder UI is wanted) rather than NSEvent global monitors, so no Accessibility permission is required just to summon the panel. Default binding plus a user-recordable override, conflict detection against existing system shortcuts, and a separate binding for pin.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [x] [T-VCMPLAN1-010] **Agent key component with seven states** `priority:critical` `assignee:claude` `tags:m1,ui` `due:2026-08-14`
  > Frosted key view with inner glow driven by state: unassigned, idle, running, complete, needs-input, error, unknown. Hover, press and focus-ring treatments. State transitions animate; animation is gated on Reduce Motion and glow is gated on Reduce Transparency. The brightest element on the panel, because it carries the entire at-a-glance proposition — every other component should read as quieter than this one.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [x] [T-VCMPLAN1-012] **Command key cluster** `priority:high` `assignee:claude` `tags:m1,ui` `due:2026-08-16`
  > Six fixed-position command keys — accept, reject, new session, push-to-talk, custom 1, custom 2 — with icon plus short label, lower fill intensity than agent keys, and a distinct disabled treatment. Disabled is a first-class visual state here, not an afterthought: on observed sessions accept and reject genuinely cannot fire, and the key must say so rather than fail silently on click.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [x] [T-VCMPLAN1-013] **Rotary dial control** `priority:medium` `assignee:claude` `tags:m1,ui` `due:2026-08-18`
  > Circular effort selector with discrete notches, driven by rotational drag, horizontal drag and scroll wheel. Centre click resets to default. Tooltip and accessibility value both report the semantic label rather than a raw number. Keyboard equivalent: arrow keys step, Home resets. Should read as a rotary encoder, not a slider bent into a circle.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [x] [T-VCMPLAN1-014] **Four-direction preset launcher** `priority:medium` `assignee:claude` `tags:m1,ui` `due:2026-08-18`
  > Planar four-way pad with centre. Up, right, down, left each fire a workflow preset; centre tap opens the preset chooser. Hover reveals the bound preset name. Keyboard equivalents for all five targets, since a pad is the hardest zone to reach by tab order alone.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [x] [T-VCMPLAN1-015] **Mock state driver** `priority:high` `assignee:claude` `tags:m1,state` `due:2026-08-19`
  > Scripted driver that walks the six keys through every state and transition on a timeline, plus a manual override panel in debug builds. Lets M1 be reviewed, screenshotted and QA'd with zero backend, and becomes the fixture for later UI tests. Implements the same protocol the real adapters will, so M2 swaps it out rather than deleting it.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [x] [T-VCMPLAN1-002] **M0 gate: spike hook-based state push from Claude Code** `priority:critical` `assignee:claude` `tags:m0,spike,state` `due:2026-07-31`
  > Register SessionStart, Stop, Notification, PreToolUse and PostToolUse hooks in a scratch copy of ~/.claude/settings.json, each POSTing its JSON payload to a local HTTP listener. Record which of the six product states (unassigned, idle, running, complete, needs-input, error) each hook can actually witness, the wall-clock latency from real transition to received event, and what session identity the payload carries so events can be attributed to a bound key. Notification is the candidate signal for needs-input — confirm or kill that assumption. Deliverable: event/state mapping table in PLAN.md.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [x] [T-VCMPLAN1-004] **M0: spike foregrounding a foreign terminal session** `priority:high` `assignee:claude` `tags:m0,spike,backend` `due:2026-08-01`
  > Given a session id, raise the exact window and tab that owns it. Test Terminal.app, iTerm2 and Ghostty via AppleScript/Automation, plus tmux select-window when the process sits inside a tmux pane. Record which permission prompt each path triggers and which emulators cannot be targeted at all. Focus is the one action that works on observed sessions, so its reliability sets the floor for the product's value. Deliverable: per-emulator support matrix.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [x] [T-VCMPLAN1-019] **AgentBackend protocol and capability model** `priority:critical` `assignee:claude` `tags:m2,backend` `due:2026-08-29`
  > One protocol every adapter implements: enumerate sessions, bind a session, publish a normalized status stream, dispatch a command, and declare capabilities. Capabilities are per session rather than per backend, because an owned session and an observed session from the same provider differ in exactly what they will accept. The UI consumes only this protocol — no provider branching above the adapter line.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [x] [T-VCMPLAN1-005] **M0: record architecture and distribution decisions** `priority:critical` `assignee:claude` `tags:m0,spike` `due:2026-08-02`
  > Close the PRD open questions with written decisions: Claude Code as first-class v1 backend; owned-vs-observed session split with capability gating; direct notarized distribution rather than App Store (sandbox cannot host PTY spawning plus ~/.claude reads plus Automation); replica fidelity as zone-and-order faithful with pointer-optimised proportions. Add the seventh `unknown` visual state to the state model, distinct from `unassigned`. Blocks M1 — the layout and the key component both depend on the final state list.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [x] [T-VCMPLAN1-016] **Accessibility pass** `priority:high` `assignee:claude` `tags:m1,a11y` `due:2026-08-21`
  > Every key reachable and actuatable by keyboard with a predictable order across the four zones. VoiceOver labels that state role, binding and current status. Every colour state paired with text, icon or pulse so status never depends on hue alone. Reduce Motion disables pulse and glow animation; Reduce Transparency swaps frosted materials for solid fills with defined edges. Labels must stay legible at the compact panel size. Non-negotiable scope — this is the accessibility floor, not polish.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [x] [T-VCMPLAN1-024] **Focus action for bound sessions** `priority:high` `assignee:claude` `tags:m2,backend` `due:2026-09-16`
  > Ships as THREE explicit tiers, not one feature — resolve, dispatch, return a tier, never a boolean. Tier 1 full window+tab: Terminal.app (5/5 verified), iTerm2 (10/10 after rewrite), tmux in either (4/4). Tier 2 app-only: cmux, GoLand, VS Code, Zed — no tty-to-window mapping exists, so we raise the app and must LABEL that we cannot target the tab. Tier 3 inert with a reason: no controlling tty, or detached tmux (offer attach instead of refusing). Note the uncomfortable finding: 0 of 4 live sessions on the dev machine are Tier 1 — three in cmux, one in GoLand — so this needs a decision before M2, not during a demo. Three traps: TERM_PROGRAM lies (cmux reports ghostty, which is not installed) so walk the process tree instead; iTerm2 has six documented approaches that fail SILENTLY and one undocumented iteration order that works; tty numbers recycle within minutes so re-validate against the live pid or raise a stranger's window. Two of three spike code paths were initially wrong with no error raised, so verify after acting by re-reading the front window's tty. Port spikes/focus/focus.sh as the reference shape.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [x] [T-VCMPLAN1-022] **Claude Code adapter: transcript tailing fallback** `priority:medium` `assignee:claude` `tags:m2,backend,state` `due:2026-09-09`
  > PROMOTED from fallback to requirement by the hook spike: hooks are edge-triggered with no snapshot and no query, so a panel opening mid-session learns nothing until the next transition. Tailing is the only way to populate six keys at launch. Cleared by the M0 spike at 93% agreement, 0.9% wrong, 6.1% abstained, sub-250ms detection — but scoped to `running`, `idle` and liveness ONLY. A pending permission prompt writes no transcript record at all, so this source can never produce `needsInput`; that comes from hooks or not at all. Port spikes/tailing/watch.py, keeping its three hard-won rules: exclude subagent transcripts (they never contain a turn-boundary record, so each looks permanently mid-turn and would add phantom running siblings); join sessions to processes on the candidate id set, never the filename (a resumed session's records carry a different session_id than its filename, and filename matching reports live sessions as dead); and ship the `ps` liveness join alongside, because without it idle and crashed are the same colour. Stat-polling at 200ms is sufficient — FSEvents is not needed at this file count. Beware the three format traps documented in the findings: most tail records carry no timestamp, the last-prompt/ai-title/mode/permission-mode cluster is NOT a turn boundary, and `end_turn` does not end a turn (only `turn_duration` does).
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [x] [T-VCMPLAN1-018] **Normalized state engine** `priority:critical` `assignee:claude` `tags:m2,state` `due:2026-08-28`
  > Owns the seven-state model and the legal transitions between them, independent of any provider vocabulary. Includes a staleness timer: a source that goes quiet past its threshold drives the key to `unknown` rather than leaving the last known colour on screen. Provider-specific statuses are mapped in at the adapter boundary, so the views never see a raw backend string.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [x] [T-VCMPLAN1-020] **Session registry with persistent key bindings** `priority:high` `assignee:claude` `tags:m2,state` `due:2026-09-02`
  > Persist which session occupies which of the six slots so a key keeps meaning the same thread across app restarts and machine sleep. Handle the reconnect cases explicitly: session still alive, session gone, session replaced by a new one in the same repo. A stale binding must resolve to `unknown` and offer rebind, never silently re-point at a different thread.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [x] [T-VCMPLAN1-026] **Session detail popover and rebinding** `priority:medium` `assignee:claude` `tags:m2,ui` `due:2026-09-20`
  > Hover and secondary click surface session name, backend, repo, branch, capability summary and last state transition with timestamp. Actions: rebind to another session, clear the slot, open the activity log filtered to this session. Keeps the panel itself minimal while the detail lives one gesture away.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [x] [T-VCMPLAN1-021] **Claude Code adapter: observe path via hooks** `priority:critical` `assignee:claude` `tags:m2,backend,state` `due:2026-09-06`
  > Local event receiver plus an idempotent installer that adds our hook entries to ~/.claude/settings.json without touching or duplicating existing user hooks, with explicit consent and a clean uninstall. Maps received events to normalized states using the table produced by the M0 hook spike. Primary state source for sessions the user started themselves — and, per the tailing spike, the ONLY possible source for `needsInput`, since a pending permission prompt leaves no trace on disk. That makes this task load-bearing rather than merely preferred: if a user declines hook installation, the panel must state that `needsInput` is unavailable rather than silently never lighting the amber key. SETTLED by the hook spike, and the plan's assumption was wrong: `Notification` is debounced by a fixed 6s idle timer, suppressed while the user is active, interactive-only, and shares a channel with ten unrelated notification types. Use `PermissionRequest` instead — 1ms, unconditional, and it carries tool_name, tool_input and permission_suggestions, which the accept/reject keys also need. Keep `Notification` only for notification_type=idle_prompt. Two hard constraints: `SessionStart` MUST be a command hook because http silently receives zero SessionStart events, and that command hook is also how we get CLAUDE_PID for liveness and window focus. Filter any event carrying `agent_id` or subagent events will thrash the slot. Hooks block the transition synchronously, so use command+async:true or treat listener latency as a hard budget — a wedged listener degrades the user's Claude Code, which is worse than a wrong colour. `error` remains UNVERIFIED: StopFailure never fired in 12 sessions.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [x] [T-VCMPLAN1-027] **Activity strip and local event log** `priority:medium` `assignee:claude` `tags:m2,state` `due:2026-09-22`
  > Subtle strip showing the most recent state changes and dispatched actions, backed by a bounded in-memory ring buffer with an inspectable full view. Exists for trust and debugging: when the panel and reality disagree, this is what tells the user which event we did or did not receive. Stays local, no network.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [x] [T-VCMPLAN1-028] **Drift guard: reconcile on wake and focus** `priority:high` `assignee:claude` `tags:m2,state` `due:2026-09-24`
  > Re-verify every bound session on app foreground, display wake and system wake: is the process still alive, is the transcript still growing, did we miss events while asleep. Anything unverifiable goes to `unknown`. Directly addresses the PRD's first-named risk — a panel confidently showing a stale colour is worse than one admitting it lost track.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [x] [T-VCMPLAN1-017] **M1 exit review: recognisability and restraint** `priority:medium` `assignee:claude` `tags:m1,ui` `due:2026-08-23`
  > Review the prototype against the reference control map and against the PRD's own risk of overfitting to mimicry. Confirm someone familiar with the hardware recognises the structure immediately, that labels and hit targets survived the fidelity push, and that nothing in the visuals or copy reads as an official product. Written go/no-go before M2 starts.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [x] [T-VCMPLAN1-029] **Overflow handling beyond six sessions** `priority:medium` `assignee:claude` `tags:m2,ui` `due:2026-09-25`
  > Count badge for unbound sessions plus paging or a chooser, with priority given to surfacing any session in needs-input or error that has no slot. Answers the PRD open question about representing more than six agents. Silent truncation is not acceptable here: a hidden blocked agent defeats the purpose of the panel.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [x] [T-VCMPLAN1-030] **Permission and hook-install onboarding** `priority:medium` `assignee:claude` `tags:m2,ship` `due:2026-09-27`
  > First-run flow that explains, before the OS prompt appears, why Automation or Accessibility access is being requested and exactly what breaks without it. Asks consent before writing hooks into ~/.claude/settings.json, shows the diff it intends to make, and offers one-click removal. Degraded modes must remain usable rather than dead-ending.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [x] [T-VCMPLAN1-033] **Remapping and workflow preset editor** `priority:medium` `assignee:claude` `tags:m3,config` `due:2026-10-22`
  > Configuration surface for rebinding command keys, editing the two custom slots, and defining the four pad presets such as review PR, debug issue, explain code, write docs. Global defaults with per-project override, resolved project-first — global-only breaks for anyone with several repos, per-project-only costs too much setup to survive the activation metric. Presets are plain files, importable and diffable.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [x] [T-VCMPLAN1-035] **Push-to-talk capture (deferred from v1 P1)** `priority:low` `assignee:claude` `tags:m3,backend` `due:2026-10-25`
  > Hold-to-record prompt capture using the Speech framework with on-device recognition, microphone permission handling, and dispatch of the transcript into an owned session. Demoted from the PRD's P1 because it is a self-contained subsystem orthogonal to the core thesis, and shipping it before state is trustworthy buys nothing. Until then the push-to-talk key ships visibly disabled.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [x] [T-VCMPLAN1-023] **Claude Code adapter: owned sessions under PTY** `priority:critical` `assignee:claude` `tags:m2,backend` `due:2026-09-13`
  > Spawn and supervise sessions the app owns. The M0 spike settled the mechanism, so these are now requirements rather than choices: use forkpty, NOT openpty plus Foundation Process (Process gives no hook between fork and exec, so the pty never becomes the controlling terminal and every child is a guaranteed orphan); keep a reader draining the pty master for the life of every child or it blocks in write() and looks hung; tear down with killpg then SIGKILL on a timeout, because the pty hangup leaked once in 66 runs and never reaches SIGHUP-ignoring grandchildren like MCP servers or language servers. DECIDED: owned sessions run a VISIBLE TUI (not headless stream-json), because the PRD's non-goal is not replacing the terminal and the hook spike removed the reason injection was unsafe. Sequence: PermissionRequest hook fires at 1ms -> key amber -> user presses accept -> keystroke injected into the PTY -> PostToolUse confirms -> key returns to running. Detection comes from hooks, never from scraped text. HARD REQUIREMENT on the reject path: PermissionDenied never fired in 12 spike sessions, so there is no proven signal a rejection landed. After injecting, wait for a confirming event within a bounded window and drive the key to `unknown` if none arrives. An unconfirmed reject must NEVER be reported as done. Spawn with --settings pointing at our own hook file, which gives full hook coverage with zero writes to the user's ~/.claude/settings.json. Untested and still open: six concurrent children, sleep/wake, SIGWINCH resize, and a startup sweep for strays from a previous crash.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [x] [T-VCMPLAN1-025] **Wire command keys with capability gating** `priority:high` `assignee:claude` `tags:m2,backend,ui` `due:2026-09-18`
  > Connect accept, reject and new session to adapter dispatch, and bind the dial to effort where the session supports it. Each key's enabled state derives from the bound session's declared capabilities, so an observed session shows accept and reject disabled with a hover explanation. No optimistic UI: a key reflects the outcome the adapter reports, not the click.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [x] [T-VCMPLAN1-034] **Ship: notarized build, updates, idle click-through, legal pass** `priority:medium` `assignee:claude` `tags:m4,ship` `due:2026-11-15`
  > PARTLY DONE, one part blocked. Done: Scripts/package.sh builds a release, runs the self-check before packaging, bundles and produces a verified DMG (1.6MB, CRC valid); click-through-when-idle exists on PanelController, off by default and always cleared by the summon hotkey, because a floating window that silently stops accepting clicks is indistinguishable from a frozen app; brand audit clean - no OpenAI or Work Louder strings anywhere, and `Codex` appears only inside the app's own name. Blocked: notarytool and stapler ship with Xcode, which is not installed — installing Xcode is a prerequisite for this task, and Scripts/bundle.sh currently ad-hoc signs instead. Scope: notarized DMG with a Sparkle update channel and hardened runtime entitlements that still permit PTY spawning and Automation. Click-through transparency when idle via ignoresMouseEvents, deliberately last so it never masks an untrustworthy state layer. Opt-in local-only metrics covering the PRD's activation and engagement measures. Final review of copy, icon and visuals to keep clear of implying an official OpenAI or Work Louder product.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [x] [T-VCMPLAN1-037] **Colour checks measure the model, not rendered pixels** `priority:high` `assignee:claude` `tags:m1,a11y` `due:2026-08-30`
  > Found while frosting the caps: the colour suite reads StateColors.composedKeyFill and never looks at a rendered pixel, so it is structurally incapable of detecting a regression introduced by any layer drawn ON TOP of the fill. A throwaway probe compositing the real layer stack caught two the suite missed - a full-face frost dropped error's glyph contrast to 3.12:1 and compressed three lit pairs below the 1.8 floor. Port that probe into the checked path so the assertion measures what the user sees.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [x] [T-VCMPLAN1-038] **Rendered complete/error separation is 1.78 against a declared 1.8 floor** `priority:medium` `assignee:claude` `tags:m1,a11y` `due:2026-08-30`
  > The palette model measures 1.82 but the composited render measures 1.78, because the glow layer sits over the fill. Predates the frosting work and is invisible to the current check (see task 037). Either bring the render up to the floor or lower the declared floor to what is actually achieved - a declared invariant the render quietly violates is worse than an honest lower number.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [x] [T-VCMPLAN1-040] **The app cannot be found if the hotkey does not fire** `priority:high` `assignee:claude` `tags:m1,panel,ship` `due:2026-08-30`
  > LSUIElement means no Dock icon and no menu bar item, so the only route to the panel is Ctrl-Opt-Cmd-V - which is the one link never verified, because a real keypress needs a human. Observed live: the saved frame put the panel on a second display and it was simply unfindable. Two fixes, both cheap: add a menu bar item as a guaranteed route, and centre the default frame instead of the bottom-right corner at y=24, which sits behind the Dock on first launch.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [x] [T-VCMPLAN1-041] **Onboarding, keymap editor and activity log are unreachable** `priority:high` `assignee:claude` `tags:m2,config,ship` `due:2026-09-27`
  > All three views are built and checked but referenced from zero places outside their own files. Consequence: hook installation has no consent path in the UI at all - it currently requires VCM_HOOKAPPLY from a terminal, which is not a product. Add a reachable route (a menu bar item per task 040, or a context menu on the plate) and present onboarding on first launch when hooks are absent.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [x] [T-VCMPLAN1-042] **Redo the M1 exit review against the current layout** `priority:medium` `assignee:claude` `tags:m1,ui` `due:2026-08-30`
  > docs/M1-REVIEW.md reviewed a 412x276 four-zone panel that no longer exists. Three of its structural criticisms dissolved when the layout was rebuilt from the reference photos as a square 4x4 grid, but its verdict and its GO conditions now describe superseded geometry. Re-review the real thing, including the frosted caps and the case underglow, and check the invented plate legends read as ours rather than as a copy.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [x] [T-VCMPLAN1-039] **needsInput is wired but never witnessed** `priority:critical` `assignee:claude` `tags:m2,backend,state` `due:2026-09-06`
  > PermissionRequest is installed and the mapping is in place, but it has never fired: it only occurs on an interactive session hitting a real approval prompt, and -p mode has no permission lifecycle at all. The amber key - the state the entire fast-glance thesis rests on - is therefore unproven end to end. Same for PermissionDenied, which never fired across 12 spike sessions, so the reject path's unconfirmed-resolves-to-unknown behaviour is also unwitnessed. Verify both against a real interactive session.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

## BLOCKED

- [!] [T-VCMPLAN1-036] **Spike Codex observability and control surface** `priority:low` `assignee:claude` `tags:deferred,spike,backend`
  > Blocked: Codex CLI is not installed on the development machine, so none of this can be verified rather than guessed. When it is available, establish three things against the real build: whether the `notify` setting in ~/.codex/config.toml invokes an external program on turn events and what payload it carries; what session state is recoverable from ~/.codex/sessions; and whether a Codex session spawned under our own PTY accepts approval input and reasoning-effort changes as cleanly as Claude does. Unblocks task 031.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [!] [T-VCMPLAN1-031] **Codex adapter behind the same protocol** `priority:low` `assignee:claude` `tags:deferred,backend`
  > Blocked: no Codex CLI available to develop or test against, and blocked behind spike 036 for its capability shape. Scope when unblocked: session discovery from ~/.codex/sessions, spawn-under-PTY for owned sessions, reasoning-effort mapping onto the dial. Success condition stays the same — no view code changes to support it. Nothing in M1 or M2 should be designed around this landing; the protocol in task 019 is what keeps the option open.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z

- [!] [T-VCMPLAN1-032] **Cross-backend semantic normalization** `priority:low` `assignee:claude` `tags:deferred,state`
  > Blocked: needs a second real backend to normalize against, so it cannot start before task 031. Scope when unblocked: reconcile what counts as complete versus idle, how a tool-approval pause differs from a clarification question, and how errors are distinguished from cancellations, so blue means running and red means error in both. Until then the single-backend mapping lives in the Claude adapter and the seven-state model in task 018 is the contract that keeps a second provider mappable later.
  > Created: 2026-07-26T00:00:00.000Z | Updated: 2026-07-26T00:00:00.000Z
