# Accessibility audit — T-VCMPLAN1-016

Cross-zone pass over the four M1 components, 2026-07-26. Per-component work
(VoiceOver labels, focus rings, Reduce Motion, non-colour status) was already done
by each component's author; this is the traversal nobody owned plus verification
that the per-component claims survive being checked against the source.

## What was actually run

```
swift build --scratch-path .build-a11y      → Build complete, zero warnings
VCM_SELFTEST=1 ./.build-a11y/debug/VirtualCodexMicro
                                            → selfcheck: ok (7 states), exit 0
```

`FocusOrder.selfCheckFailures()` is not yet wired into `SelfCheck.swift` (that
file is off-limits here), so it was compiled and driven standalone from
`Support/{AgentState,AgentBackend,PanelLayout,StateColors,FocusOrder}.swift`,
`Keys/CommandKeyView.swift` and `Controls/DirectionPadView.swift`:

```
focusorder: ok (18 stops)
```

One line wires it in — add to the module block in `SelfCheck.run()`:

```swift
failures += FocusOrder.selfCheckFailures().map { "focus: \($0)" }
```

## Deliverable A — the traversal order

`Sources/VirtualCodexMicro/Support/FocusOrder.swift`. 18 stops:

```
agent 0 · agent 1 · agent 2 · agent 3 · agent 4 · agent 5
command accept · command reject · command newSession · command pushToTalk · command custom1 · command custom2
dial ring
pad up · pad right · pad down · pad left · pad center
```

### Justification

Not strict visual reading order. Zone top edges at regular scale are agents
y=16, dial y=84, pad y=152, commands y=162, so reading order would be
agents → dial → pad → commands. The order below is task adjacency instead:

1. **Agent keys first.** Six of them are the product. Someone tabbing in is
   looking for a session, and the cluster is top-left anyway, so intent and
   geometry agree at the one point where it matters most.
2. **Command keys second.** They act on the session the agent keys select.
   Select-then-act is the panel's dominant two-step; any zone placed between the
   halves means tabbing through controls unrelated to what the user is mid-way
   through.
3. **Dial third.** Effort acts on the bound session too, so functionally it
   belongs with the command cluster, not with the pad. One stop, and it adjusts
   with arrow keys once focused, so it is cheap to pass through either way.
4. **Pad last.** The pad launches workflows and is the only zone that does not
   read the bound session. Last keeps select-then-act uninterrupted and leaves a
   single-stop landmark (the dial) between the panel's two multi-stop clusters
   for Shift-Tab.

Within each zone the order is the component's own: agent keys row-major by index,
`CommandSlot.allCases` (row-major; `PanelLayout.swift:50-51` calls that ordering
load-bearing for muscle memory), `PadDirection.allCases` (clockwise from the top,
chooser last — the order `DirectionPadView.swift:38-43` documents).

### The 19th target

`PanelLayout.hitTargets` publishes 19; this order has 18. The difference is
`dial reset`, which `PanelLayout.swift:320` already marks `nested: true`.
`DialView.swift:257,272` expose it as the Home key and a VoiceOver action
(`Reset to medium`), not as a separate element, so the keyboard reaches it with
no stop of its own. `selfCheckFailures()` enforces that shape both ways: every
non-nested hit target must be a stop, and any hit target that is *not* a stop
must be nested. A control added to `PanelLayout` therefore cannot become silently
unreachable, and a nested one cannot become a duplicate stop.

### Skip logic

Focusability is delegated, never restated: `CommandKeyView.isEnabled` and
`DirectionPadView.isActionable` are called, and the self-check asserts agreement
per configuration so the two cannot drift. Traversal wraps and is bounded at
`all.count` probes, so it terminates by construction rather than by reaching an
end. Observed behaviour:

| Situation | Reachable | Notes |
|---|---|---|
| owned session, 4 presets bound | 18 | everything live |
| observed session, 2 presets, dial gated | 10 | accept/reject/talk/c1/c2 and dial skipped |
| nothing bound, cannot spawn | 7 | six agent keys plus the pad centre |

Tab from a *disabled* `command accept` (observed session) lands on
`command newSession`, and Shift-Tab from `pad up` lands on `command newSession`
— i.e. traversal continues correctly from a stop that is itself unfocusable,
which is the case that strands focus when a capability changes while a key holds
it. Agent keys are focusable unconditionally, including empty slots (activating
one is how a session gets bound), so the panel can never have zero stops; the
check asserts that floor rather than assuming it.

### Two documentation contradictions this creates

Both are in files I was told not to restructure, and neither is a code defect,
but they now disagree with the canonical order and should be corrected by their
owners:

- `PanelLayout.swift:307` — "Doubles as a sane default keyboard traversal order:
  agent keys, command keys, pad, dial." `hitTargets` is a geometry sweep built
  for the overlap check; it is not the traversal order, and its zone sequence
  puts the pad before the dial.
- `DirectionPadView.swift:41-43` — "That matches the order
  `PanelLayout.hitTargets` publishes for the pad zone, so the documented panel
  traversal order and the real focus order cannot drift apart." The pad's
  *internal* order does match and is unchanged; the claim about the panel-level
  order no longer holds.

`FocusOrder`'s self-check cross-checks `hitTargets` by set membership and zone,
never by sequence, so the two can hold different orders without failing.

## Deliverable B — claim verification

| # | Claim | Verdict |
|---|---|---|
| 1 | Every `AgentState` renders text or an icon, not colour alone (all 7) | **HOLDS** |
| 2 | Reduce Motion honoured everywhere motion exists | **HOLDS** |
| 3 | Reduce Transparency honoured everywhere a material is used | **DEFECT** |
| 4 | Every interactive target has a non-empty label naming purpose, not position | **HOLDS** (two gaps noted) |
| 5 | Disabled command keys explain why, in tooltip and VoiceOver label | **HOLDS** (one gap noted) |
| 6 | Labels legible at the compact size class | **DEFECT** |
| 7 | No component conveys state through colour alone | **HOLDS** |

### 1. Non-colour status for all seven states — HOLDS

`AgentState.label` is non-empty for all seven (`AgentState.swift:21-31`);
`AgentKeyView.iconName(for:)` covers all seven exhaustively by `switch`
(`AgentKeyView.swift:119-129`); both are rendered on the face, icon at
`AgentKeyView.swift:403` and label at `:410`. Two of the seven get a third,
non-hue channel: `unknown` is hatched (`:343`, `:378-392`) and `unassigned` is
dashed (`:232`, `:369-373`), which is the distinction PLAN.md names as risk #1.
`AgentKeyView.swift:458-471` and `SelfCheck.swift:39` both walk `allCases`, so an
eighth state fails the check instead of shipping as a hue.

Icons resolve: `CommandKeyView.swift:303` verifies command icons through
`NSImage(systemSymbolName:)` at runtime. Agent-key icon names are **not** resolved
that way — `AgentKeyView.swift:468` only checks the string is non-empty. All seven
are SF Symbols 1.0 names so they will resolve on macOS 14, but a typo would ship
as an invisible glyph and the check would pass. One-line fix available by copying
the `NSImage` probe from `CommandKeyView`.

### 2. Reduce Motion — HOLDS

Every animation in the module, checked individually:

| Location | Motion | Under Reduce Motion |
|---|---|---|
| `AgentKeyView.swift:288` | state transition, 0.18s ease-out | duration 0 via `:181-186`; snaps |
| `AgentKeyView.swift:341,366` | running pulse, `repeatForever` | `shouldPulse` is `state == .running && !reduceMotion` (`:309`), so `isPulsing` never becomes true and `pulseAnimation` is `nil` |
| `CommandKeyView.swift:262` | hover fill, 0.12s ease-out | `nil` |
| `DialView.swift:306` | pointer spring | `nil` |
| `DialView.swift:338` | knurl spring | `nil` |
| `PanelController.swift:89` | window show/hide fade | `animationBehavior = .none` unconditionally — no motion at all |

Two places have visual change with no animation attached, so there is nothing to
suppress: `AgentKeyView.swift:361` hover/press `scaleEffect` (the `.animation` at
`:288` is scoped to `value: state`, so scale changes are already instant), and the
`DirectionPadView` hover tint and focus ring (`:151`, `:160-164`) and `DialView`
active-notch change (`:280-285`), none of which carry an `.animation` modifier.
The pulse is the one that matters and it is switched off at the source, not merely
sped up.

### 3. Reduce Transparency — DEFECT

Handled, explicitly and with an assertion:

- `AgentKeyView.swift:233` — `usesMaterial: !reduceTransparency && fillOpacity < 1`,
  fill forced opaque at `:205`, edge widened to ≥1.5 at `:206`, and
  `:585-600` asserts all three across every state and appearance.
- `CommandKeyView.swift:270` — no material at all; `fillOpacity` returns 1 under
  Reduce Transparency, and `:279` widens the border 0.75 → 1.5.

Not handled:

- `DialView.swift:232` — `Circle().fill(.ultraThinMaterial)` (the ring face)
- `DialView.swift:312` — `Circle().fill(.regularMaterial)` (the knob face)
- `DirectionPadView.swift:150` — `.ultraThinMaterial` for live pad cells

Neither file reads `\.accessibilityReduceTransparency` at all (`DialView` reads
only `accessibilityReduceMotion` at `:210`; `DirectionPadView` reads neither), and
neither self-check asserts anything about it.

Honest qualification, because it changes what the fix should be: on macOS,
SwiftUI `Material` is backed by `NSVisualEffectView`, which AppKit substitutes for
an opaque appearance when Reduce Transparency is on. If that holds, these three
sites degrade acceptably at runtime *by accident*. I did not toggle the setting
and look at pixels, so I cannot state that as verified — see the unverifiable
list. What is verifiable from source is that the panel now has two policies for
the same requirement: the agent key drops the material and proves it, two zones
rely on undocumented framework behaviour and prove nothing. A refactor onto any
non-`NSVisualEffectView` fill would break those two silently. Recommended fix,
owned by each component: read the environment value and swap for an opaque fill
plus a 1.5pt edge, matching `AgentKeyView`, then assert it.

### 4. Labels name purpose, not position — HOLDS, two gaps

| Target | Label | Purpose named? |
|---|---|---|
| agent key | `AgentKeyView.swift:134-140` → "Agent key 3, audit ledger sync" + value from `:144-156` | yes when bound; `:138` deliberately drops a stale session title from a cleared slot |
| command key | `CommandKeyView.swift:227` → `actionName(for:)` (`:134-143`), full words | yes |
| pad cell | `DirectionPadView.swift:221-227` → "up, run review PR" / "up, no preset bound" / "centre, open preset chooser" | yes — names the preset, and the comment at `:220` says exactly why position alone is not enough |
| dial | `DialView.swift:260-264` → label "Effort", value "medium", hint at `:264`, adjustable action at `:265` | yes |
| dial reset | `DialView.swift:272` → action named "Reset to medium" | yes |

Two gaps, neither fatal:

- **The agent key never says what pressing it does.** No `accessibilityHint` and
  no named action. Per PLAN.md and task 024, activating an agent key raises the
  terminal window that owns the session — the one action that works on every
  session type. A VoiceOver user hears "Agent key 3, audit ledger sync, running,
  button" and is not told that. A hint ("Brings the session's terminal to the
  front") is the fix.
- **An unassigned slot is position-only by design.** Label is "Agent key 1", value
  "empty, no session bound". That is honest rather than wrong — there is no
  purpose yet — but it does mean six identical-purpose stops when the panel is
  empty, which is the first-run state.

### 5. Disabled command keys explain why — HOLDS, one gap

`CommandKeyView.swift:227` sets `.accessibilityLabel(reason ?? actionName)` and
`:230` sets `.help(reason ?? actionName)` from the same `reason` computed at
`:192-196`, so the tooltip and the spoken label are literally one string. The
tooltip is on the `ZStack` wrapper, not the `Button`, so `.disabled` cannot
suppress it (`:207-210` explains this). `:338-357` asserts across a five-entry
capability matrix × both spawn values that enabled and reason never disagree and
that a disabled key is never silent. The reasons are specific rather than generic:
`:99-103` distinguishes "this session can only be observed" from `:104-105`
"did not declare the … capability", and `:87-92` handles `newSession` separately
because it is gated on the app rather than the bound session.

The gap: the reason is used as the **label**, and the observed-session reason is
33 words. VoiceOver reads a label in full every time focus lands on the element,
so the identity of the control arrives buried in a paragraph. It does at least
lead with the action name ("Accept is unavailable: …"), so nothing is lost, but
the conventional split is a short label plus the explanation as
`accessibilityHint` or `accessibilityValue`. Cosmetic, and worth doing before M2
adds more capability shapes.

### 6. Compact-size legibility — DEFECT

Computed from `PanelLayout` rather than eyeballed. Compact scale is
`max(0.8, 28/36) = 0.8`.

| Text | Regular | Compact | `minimumScaleFactor` floor (compact) | Source |
|---|---|---|---|---|
| agent slot number | 10.64pt | **8.51pt** | n/a | `AgentKeyView.swift:400` (`side * 0.19`) |
| agent state icon | 11.20pt | 8.96pt | n/a | `AgentKeyView.swift:404-407` |
| agent state label | 9.80pt | **7.84pt** | **5.10pt** (0.65) | `AgentKeyView.swift:411-413` |
| command cap label | **8.00pt** | **6.40pt** | **4.80pt** (0.75) | `CommandKeyView.swift:242-244` |
| dial knob label | 9.60pt | **8.00pt** | **4.40pt** (0.55) | `DialView.swift:316-318` |
| pad glyph | 13.00pt | 10.40pt | n/a — icon only | `DirectionPadView.swift:157` |

Nothing overflows: the agent key's state label has 34.94pt of text width at
compact and "unknown" needs roughly 27pt at 7.84pt, so `minimumScaleFactor`
should not engage on the current strings. The failure is size, not clipping.

Three findings:

- **Three of four zones put text below 9pt at compact**, and the command cap
  label is below 9pt at *regular* too.
- **Compact is the shipping default.** `PanelController.init` defaults
  `layout: .compact` (`PanelController.swift:54`). This is not an edge case a
  user has to opt into; it is what launches.
- **The `minimumScaleFactor` floors are the larger latent risk.** 4.4–5.1pt is
  not legible under any definition. On the current fixed strings it should not
  trigger, but `DialScale` labels arrive from an adapter
  (`DialView.swift:29-37`), so a provider exposing "very high" instead of "high"
  reaches the 4.40pt floor in a 32pt knob with no code change and no check to
  catch it.

I did not fix this, deliberately. Every available patch is a font clamp
(`max(9, side * 0.175)`) applied independently in three components, which is the
shape of fix that leaves the root cause in place: one number,
`PanelLayout.requestedCompactScale = 0.8` (`PanelLayout.swift:81`), sets the
compact floor for all of them, and `PanelLayout` is off-limits to me. The
principled fixes are, in order of preference:

1. Give `PanelLayout` a `minimumLabelPointSize` (or clamp `requestedCompactScale`
   against a text floor the way `minimumScale` already clamps it against
   `minimumHitTarget` at `:80`) and have the three components read it. That
   mirrors the pattern the file already established for hit targets and keeps the
   floor in one place.
2. Raise the type ratios in the three components so compact clears 9pt, and raise
   `minimumScaleFactor` to something defensible (≈0.85) so the floor cannot go
   below it.

### 7. No colour-alone state — HOLDS

| Signal | Non-colour channel |
|---|---|
| agent state (7) | icon + text label; plus hatch for `unknown`, dashed edge for `unassigned` (`AgentKeyView.swift:232,343,403,410`) |
| agent hover / press / focus | geometry only — 1.04 / 0.955 scale, inset rim, detached ring (`:213-217,351-355,424-436`). `:527-536` asserts fill and glow opacity are identical across all interactions, so a pointer can never read as a state change |
| command key disabled | dashed border (`CommandKeyView.swift:278-283`) + reduced opacity + the reason string in tooltip and label. The comment at `:277` names greyscale and colour-blind vision explicitly |
| pad cell unbound | dashed border + dimmed glyph + different fill style + "no preset bound" in tooltip and label (`DirectionPadView.swift:150-158,213,223`) |
| dial value | knob text label + pointer angle + active notch, which differs in **width and height** as well as tint (`DialView.swift:283-285`) |
| focus, all zones | ring presence, not ring hue |

One nit: the pad's hover highlight is `Color.accentColor.opacity(0.18)`
(`DirectionPadView.swift:151`), which is colour-only. Hover is not state and the
pointer is its own cue, so this is not a violation, but it is the only place in
the panel where a colour carries a signal with no second channel.

Cross-zone observation, not a defect: there are **three focus-ring languages** for
one concept — a detached two-tone ring in the key's own swatch colours
(`AgentKeyView.swift:424-436`), an inset `Color.accentColor` ring
(`CommandKeyView.swift:253-258`, `DirectionPadView.swift:160-164`), and a
`.tint` circle (`DialView.swift:242`). Each is individually visible. Tabbing
across all four zones means the "you are here" marker changes appearance three
times, which is worth one owner's decision before M1 exit review (task 017).

## Corrective edits made

**None.** Two real defects were found (items 3 and 6) and neither has a fix that
is both minimal and in the right place:

- Reduce Transparency in `DialView` / `DirectionPadView` needs an environment
  read plus a fill swap plus a self-check assertion in each — the component
  author's call, and possibly a no-op if AppKit's automatic substitution already
  covers it, which I could not verify.
- The font floor's root cause is a single `PanelLayout` constant I am not
  permitted to touch; patching three call sites instead would be the
  fix-every-caller anti-pattern.

Everything else is reported as a gap with the one-line fix named, for the owner
to apply.

## Deliverable D — what could NOT be verified here

Reasoned from source, never observed. Do not read anything below as tested.

**No screen reader was run. No VoiceOver output was heard.** Every statement about
what VoiceOver says is a reading of the accessibility modifiers in the source. In
particular these are unverified:

1. That a **disabled SwiftUI `Button` is still visited by VoiceOver** and
   announced as dimmed. `CommandKeyView.swift:218-224` states this as the reason
   it is safe to drop disabled keys from the Tab order. If it is wrong, the "why"
   never reaches a screen-reader user and the disabled-key design collapses.
   This is the single most load-bearing unverified assumption in the pass.
2. That a **disabled `Button` really leaves the keyboard focus chain**. The same
   comment asserts it, and `FocusOrder`'s skip logic is built to match. If
   SwiftUI keeps it focusable, the model and reality disagree in the exact way
   the model exists to prevent.
3. **Announcement order and phrasing** — whether label, value, hint and traits are
   read in the order intended, whether "Agent key 3, audit ledger sync, running,
   button" is what is actually spoken, and whether the 33-word disabled reason is
   tolerable or unusable in practice.
4. Whether `accessibilityAdjustableAction` on the dial (`DialView.swift:265`) is
   reachable with VO-arrows and whether the named reset action
   (`:272`) appears in the actions menu.
5. Whether the pad's per-cell `.accessibilityElement()` inside a
   `children: .contain` container (`DirectionPadView.swift:133,183`) produces one
   group of five, or a flattened list, or duplicates.

**No Reduce Transparency / Reduce Motion / Increase Contrast toggle was
exercised.** The self-checks drive the *decision functions* with the flags set,
which proves the logic branches correctly. They do not prove the rendered result:

6. Whether `.ultraThinMaterial` and `.regularMaterial` become opaque under
   Reduce Transparency (item 3 above turns on this).
7. Whether an `.easeOut(duration: 0)` animation (`AgentKeyView.swift:186`) is
   genuinely indistinguishable from no animation, or still schedules a frame.
8. Whether measured WCAG ratios in `StateColors` survive composition over a
   *material*. The maths composites the tint over a flat `panelBackdrop`
   (`StateColors.swift:98-105`); the real key has `.ultraThinMaterial` behind the
   tint, sampling whatever is under the panel. On a bright window the effective
   backdrop is not the value the contrast was measured against.

**Nothing was tabbed through, because nothing composes the four zones yet.**
`main.swift` is still the smoke scaffold (`SmokeView`, two `Text` views) and no
view in the repo renders all four zones together. Consequences:

9. `FocusOrder` is a model and a guard, not wired behaviour. Connecting it needs
   one owner view holding the cross-zone `@FocusState` and calling
   `next(after:)` / `previous(before:)`, and that view does not exist. Until then
   the four `@FocusState` scopes remain independent and the real Tab order is
   whatever SwiftUI's default view-tree walk produces.
10. The **18-stop order has never been walked**. Everything in Deliverable A is
    proven about the model, nothing about the app.
11. **macOS "Keyboard navigation" is off by default.** Tab moves focus only
    between text fields and lists unless the user enables it in Settings →
    Keyboard. All 18 stops are buttons and pad cells. Whether they are tabbable at
    all on a default machine is unverified, and if they are not, the task's
    "reachable and actuatable by keyboard" needs either onboarding that names the
    setting or an in-panel arrow-key traversal. This is a scope question, not just
    a test gap.
12. Whether a hotkey summon leaves the panel able to receive keys.
    `PanelController.show()` (`:146-148`) deliberately never makes the panel key;
    `showAndTakeKeyboardFocus()` (`:172-175`) exists for callers that want the
    keyboard. `HotkeyCenter` does not currently call either. A keyboard-only user
    reaches zero zones unless the summon path calls the second one.

**Not attempted at all:** legibility judged by a human eye at compact size (item 6
is arithmetic against a 9pt threshold, not an observation); pointer accuracy on
the 28.8pt compact pad cells; behaviour at non-default Dynamic Type or display
scaling; anything on a second monitor at a different backing scale factor.
