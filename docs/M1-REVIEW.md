# M1 exit review — recognisability and restraint

Task T-VCMPLAN1-017. Reviewed 2026-07-26 against `PLAN.md`, `tasks.md`,
`spikes/a11y/AUDIT.md`, `Sources/VirtualCodexMicro/`, and the rendered panel at
`docs/renders/panel-light.png` / `panel-dark.png`.

## Verdict: GO, with four conditions

The structure is recognisable, the agent keys correctly dominate, hit-target
discipline is properly engineered, and there is no visual brand infringement.
Those are the things this gate was set up to test and they pass.

Against that, two measured defects go to the product's core claim, one control is
functionally dead and has no design for saying so, one wiring is silently
dropped, the keyboard story may be inert on a default machine and has never been
checked, and the product name carries legal exposure that gets more expensive to
change every week. None of that is "stop the project". All of it is cheap now and
expensive after M2 builds on these surfaces.

One process fact shapes the recommendation. M2 is already roughly seven tasks
deep in the tree: `State/StateEngine.swift`, `State/SessionRegistry.swift`,
`State/DriftGuard.swift`, `State/ActivityLog.swift`,
`Backends/ClaudeHookSource.swift`, `Backends/ClaudeHookInstaller.swift`,
`Backends/ClaudeTranscriptSource.swift`, `Backends/FocusResolver.swift` and
`Panel/SessionPopover.swift` all exist, while `tasks.md` still lists 018, 020,
021, 022, 026, 027 and 028 as TODO. A NO-GO would be fiction. What a gate can
usefully do at this point is name a short blocking set and let the rest proceed
in parallel.

### The four conditions

**C1. Fix achromatic state separation, and add the check that would have caught
it.** See finding 1. Extend the existing `minimumStateSeparation` floor from the
single pair it currently guards to all 21 pairs of composed fills across all four
appearances, and fix the palette until it passes. Include the light-mode
idle / unassigned / backdrop cluster, which has no hue to fall back on.

**C2. Render all seven states before certifying seven states.** `idle` is absent
from `OffscreenRender.demoStates` (`Panel/OffscreenRender.swift:68-71`), so this
gate was asked to judge seven states from an artifact showing six, and the
missing one is the worst-measured of the set. Add it and re-review that render.

**C3. Establish what Tab actually does on a default machine, then either wire
`FocusOrder` or write down that arrow-key traversal is in scope.** See finding 8.
While a screen reader is open, also verify the single assumption at
`Keys/CommandKeyView.swift:218-224` that a disabled SwiftUI `Button` is still
visited and announced as dimmed. Task 025 is about to build more capability
gating on top of it.

**C4. Decide the product name.** Not the icon and not the marketing copy. The
name, because it is embedded in the bundle identifier, the TCC identity, the
Application Support directory, the Carbon hotkey signature, the UserDefaults keys
and the hook script's own self-description. See finding 6. This is a decision,
not necessarily a rename.

Conditions C1 and C2 are one work item in practice. C3 is a measurement first and
possibly a scope item second. C4 is a decision that costs nothing today.

### Findings index

Numbered by severity across the whole review, then grouped by topic in the
sections below, so the numbers do not run consecutively within a section.

| # | Severity | Finding | Section |
|---|---|---|---|
| 1 | critical | Four lit states are isochromatic; no separation without hue | 2 |
| 2 | critical | idle, unassigned and the panel are one tile in light mode | 2 |
| 8 | critical | Keyboard traversal unverified, possibly inert; `FocusOrder` unwired | 4 |
| 3 | high | Disabled command keys and unassigned agent keys share a dashed idiom | 2 |
| 4 | high | Dial has no disabled treatment and is dead on observed sessions | 2 |
| 5 | high | `onPreset` dropped, four of five pad targets inert | 2 |
| 6 | high | The product name is the legal exposure | 3 |
| 11 | high | Agent key never states what pressing it does | 4 |
| 9 | medium | Compact size class is a latent trap | 2 |
| 10 | medium | Three focus-ring languages across four zones | 4 |
| 12 | medium | No screen reader run; one load-bearing assumption unverified | 4 |
| 7 | pass | Hit targets | 2 |

---

## 1. Recognisability

### What works

The four zones read as four zones. `zoneGap` at 14pt against `agentKeyGap` 10pt
and `commandKeyGap` 8pt (`Support/PanelLayout.swift:105,110,115`) does the
grouping without borders, exactly as the file claims. Zone order and placement
match the control map: 3x2 agent block top-left, command cluster centre-bottom,
dial right, pad lower-left.

Agent-key dominance holds, and it holds by several independent means rather than
one. Largest keycap at 56pt against 40pt command keys and 36pt pad cells
(`PanelLayout.swift:109,114,118`). Highest fill opacity, 0.85 to 0.94 against the
command cluster's 0.50 resting and 0.62 hovered
(`Support/StateColors.swift:178-237`, `Keys/CommandKeyView.swift:269-273`).
Saturated hues where every other zone is neutral. Widest glow radius. Task 010
asked that every other component read as quieter than this one, and in both
renders it does. This is the single most important structural requirement in the
brief and it is met.

Restraint is real. There is no faux-hardware chrome, no bezel gradients, no fake
screws, no skeuomorphic keycap bevels. The temptation the PRD warned about mostly
did not happen.

### Three structural criticisms

**The pad does not read as a joystick.** It renders as four separate rounded
keycaps with arrow glyphs in an inverted-T, which is the visual language of
cursor keys on a keyboard. Task 014 and `PanelLayout.swift:16-22` describe a
planar four-way pad, and the hardware affordance is joystick-like. Four discrete
caps with no visual connection between them lose the "one control, four
directions" reading. The centre cell compounds it by using `square.grid.2x2`
(`Controls/DirectionPadView.swift:256`), which is semantically right for a chooser
and breaks the pad silhouette completely.

The underlying problem is that whitespace is carrying two contradictory jobs. The
same signal that says "these five cells are one control" is the signal that says
"these are four different zones". A shared recessed plate behind the five cells,
or a continuous cross shape, fixes it without touching geometry. The geometry
itself is good: leaving the four diagonal cells inert
(`PanelLayout.swift:307-311`) is the right call for pointer accuracy.

**The dial is the largest element on the panel and carries the least
information.** 108pt diameter against 56pt agent keys
(`PanelLayout.swift:109,121`), occupying roughly the right third of the surface,
to display one value. In both renders its ring face is nearly featureless: a
pointer line, a knurled knob, two faint tick marks. Task 013 asked for discrete
notches that read as a rotary encoder rather than a slider bent into a circle.
With three steps and two visible notches it reads as an empty circle with a dot.
Prominence is inverted against information density. The knurling
(`Controls/DialView.swift:338`) is texture doing no work at this size, and is the
one thing on the panel I would call decorative noise.

**The dead space is in the most salient place available.** An 84 x 146pt
contiguous void sits at top centre, bounded by the agent zone's right edge at
x=204, the dial's left edge at x=288, and the command zone's top at y=162. That
is about 11% of the surface in one block, in the second-most-salient region after
top-left, while the command cluster is squeezed into the bottom band. The bands
above and below the dial are similarly empty.

This follows from `panelSizeBase` being derived rather than composed
(`PanelLayout.swift:155-158`): width is `max(agentZone.maxX, commandZone.maxX) +
gap + dial + padding`, height is `padZone.maxY + padding`. The panel is the
bounding box of four independently placed zones, so leftover space pools wherever
the arithmetic leaves it rather than where a layout decision put it.

Also shipping as content: the `c1` and `c2` command caps
(`CommandKeyView.swift:128-129`) are placeholder labels.

### Judgement

Someone familiar with the hardware would identify six agent keys, a command
cluster, a dial and a pad from either render. Two of four zones have prominence or
affordance problems that weaken the reading without destroying it. Not blocking.

I did not see the reference device. This judgement is against the control map as
described in `PLAN.md` and `tasks.md`, not against the hardware.

---

## 2. Did the fidelity push cost usability

This is where the real findings are. Ranked by severity.

### Finding 1 (critical). The seven states do not read as seven without colour

Measured from `StateColors.swift` by compositing each `keyFill` over
`panelBackdrop` at its own `fillOpacity`, which is what the eye sees and what the
file's own contrast maths uses.

Light appearance, each composed fill against the panel:

| State | vs panel | Notes |
|---|---|---|
| running | 4.83:1 | |
| unknown | 4.67:1 | |
| complete | 4.56:1 | |
| error | 4.54:1 | |
| needsInput | 1.62:1 | |
| unassigned | 1.19:1 | |
| idle | 1.17:1 | |

Worst pairwise separations, light:

| Pair | Separation |
|---|---|
| complete vs error | 1.00:1 |
| complete vs unknown | 1.02:1 |
| error vs unknown | 1.03:1 |
| running vs unknown | 1.03:1 |
| running vs complete | 1.06:1 |
| running vs error | 1.06:1 |
| unassigned vs needsInput | 1.36:1 |
| unassigned vs idle | 1.40:1 |

Dark behaves the same way for the lit states: running vs complete 1.00:1, error
vs unknown 1.02:1, complete vs error 1.04:1.

The four saturated states are isochromatic. They differ in hue and not in
lightness. `complete` against `error` is 1.00:1 in light and 1.04:1 in dark,
which is a red and green pair at identical luminance: the textbook worst case for
deuteranopia.

I confirmed this on the actual pixels rather than the palette by converting both
committed renders to greyscale. Keys 1, 3 and 4 (running, done, error) become the
same dark tile. Key 5 (unknown) is the same tile and survives only because of its
hatch. Key 2 (waiting) survives as a lighter tile, but it becomes the palest of
the lit keys, so the attention hierarchy inverts: the one state flagged
`isAttentionWorthy` alongside error (`Support/AgentState.swift:35-37`) reads as
the least urgent.

The cause is structural and worth naming, because it explains why careful work
produced this. Every lit state was tuned so its label clears 4.5:1 against its own
fill, and most of them use a white label. That constraint pushes all four
saturated fills onto roughly the same luminance. Each key was optimised in
isolation and the set was never checked as a set.

What partly saves it: every state carries an icon and a text label
(`Keys/AgentKeyView.swift:403,410`), `unknown` gets a diagonal hatch
(`AgentKeyView.swift:378-392`) and `unassigned` gets a dashed edge
(`AgentKeyView.swift:369-373`). Those two texture channels are the only cues that
survive greyscale, and they exist precisely because someone thought about this.
The other five states have no texture channel.

Why it still matters despite that mitigation: the product's thesis is peripheral
glance. Peripheral vision is rod-dominated and largely hue-blind, and reading a
9.8pt label is not a glance. For a colour-blind user, or for anyone reading the
panel out of the corner of their eye, the six-key status wall degrades into "go
and read six labels", which is the value proposition inverted.

The self-check cannot catch this as written. `StateColors.swift:373-380` tests
only whether two composed fills are byte-identical, which `complete` and `error`
are not. `StateColors.swift:383-390` applies the real 1.8:1
`minimumStateSeparation` floor to exactly one pair, unknown against unassigned.
The right floor exists, is correctly chosen, and is applied to 1 of 21 pairs.

Cheapest honest fix: the four lit states do not have to share a luminance.
Nothing requires white labels on all of them, and `needsInput` already uses a dark
one. Re-tuning two of the four fills for lightness while keeping hue, letting the
label colour follow, fixes the achromatic collapse without changing the design
language. Whichever route is taken, the all-pairs check has to land with it,
because this defect passed a check written specifically to prevent it.

### Finding 2 (critical, light appearance). idle, unassigned and the panel are one tile

From the table above: idle against the panel is 1.17:1, unassigned against the
panel is 1.19:1, and idle against unassigned is 1.40:1, below the code's own 1.8
floor. Unlike finding 1 there is no hue to rescue this, because all three are
neutral. In light appearance a live session doing nothing and an empty slot are
not distinguishable at a glance, and neither reads clearly as a key at all.

Dark inverts and is fine: idle sits at 10.46:1 against the backdrop.

`StateColors.swift:226-238` argues carefully that `unknown` must not read as an
empty slot, because "we lost track of a real session" and "nothing here" are
different facts. That argument is correct, the code enforces it, and it holds:
unknown is at 4.67:1 against the panel where unassigned is at 1.19:1. The sibling
case went unnoticed. A bound-and-idle session and an empty slot are also
different facts, and nothing separates them.

This is the state absent from the render (condition C2). The worst-measured state
in the palette is the one the review artifact does not show.

### Finding 3 (high). Disabled command keys and unassigned agent keys share one visual language

Both are dashed borders drawn from the same colour token.

- Command disabled: `CommandKeyView.swift:279-283`, dash `[3, 2]` at
  `StateColors.keyEdge(.unassigned)` at 0.40 opacity, fill opacity 0.30
  (`:272`).
- Agent unassigned: `AgentKeyView.swift:369-373`, dash
  `[side * 0.1, side * 0.07]`, which is `[5.6, 3.92]` at the shipping 56pt key.

So one idiom expresses two unrelated facts: "no session is bound to this slot"
and "this action cannot fire right now". A user cannot learn what dashed means,
because it means two things. In the greyscale renders key 6 and the five disabled
command keys read as one family. They are distinguishable today by size and
position, not by treatment.

The comment at `CommandKeyView.swift:275-277` defends the dashed border as
surviving greyscale, colour-blind vision and Increase Contrast, and in isolation
that is true. Neither component knows the other exists. Same root cause as the
focus-ring finding below: nobody owns cross-zone visual vocabulary.

### Finding 4 (high). The dial has no disabled treatment, and it is dead on observed sessions

`FocusOrder` already models the gate. `Support/FocusOrder.swift:120-123` carries
`dialAcceptsInput` and its comment states that `DialView` does not gate itself and
that this is "the single place to tighten when the dial is capability-gated in
M2". `PLAN.md`'s capability matrix says the dial is unavailable on observed
sessions.

`DialView` has no enabled, disabled or capability concept anywhere in its 678
lines, and `Panel/PanelRootView.swift:55` passes no gate. The consequence is
visible in the committed render, which is deliberately built with
`capabilities: .observed` (`OffscreenRender.swift:26`): accept and reject are
correctly greyed while the dial renders fully live and cannot do anything.

Task 012 insisted that disabled be a first-class visual state for command keys and
it is. The dial got nothing. Per the focus spike, observed sessions are the common
case on the development machine, so this is an unlabelled dead control occupying
the largest area on the panel. The wiring is task 025; the missing piece is the
design, which is M1's.

### Finding 5 (high). `onPreset` is dropped, so four of five pad targets do nothing

`main.swift:100` passes `onPreset: { direction in print("preset \(direction)") }`.
`PanelRootView.swift:20` declares the property and then
`PanelRootView.swift:60` builds the pad with
`DirectionPadView.defaultPresets { _ in }`, a no-op. `onOpenChooser` is wired at
`:61`, so the centre cell works and the four arms do not.

No compiler warning, because the property is stored and simply never read. Task
014's "up, right, down, left each fire a workflow preset" is not satisfied by the
assembled panel. One-line fix.

### Finding 7 (pass). Hit targets

This is the part of the fidelity and usability trade that was handled properly,
and the mechanism is the right one rather than a patch at each call site.
`minimumHitTarget` is 28pt (`PanelLayout.swift:73`). `minimumScale` is
`28 / padCellSide` (`:96-97`), so lowering `requestedCompactScale` can shrink the
panel but cannot breach the floor. `selfCheckFailures` asserts every non-nested
target at every size class (`:389-393`) and runs a full pairwise overlap sweep
(`:396-403`). At the shipping regular size, targets are 56, 40 and 36pt. Verified:
`VCM_SELFTEST=1` exits 0.

### Finding 9 (medium). Label legibility passes at what ships; the compact class is a latent trap

The shipping path is `.regular`. `main.swift:16-19` passes `layout: .regular`
explicitly, so the render at 412x276 is what the app displays. I checked this
because `PanelController.swift:54` still defaults to `.compact` and the a11y audit
concluded compact was the shipping default; that conclusion is now stale. Nothing
in the shipping path constructs `.compact` — the only uses are
`PanelLayout.swift:178`, `PanelLayout.swift:36` and a self-check at
`Panel/SessionPopover.swift:666`.

At regular the sizes are: agent slot number 10.64pt, agent state label 9.80pt,
command cap 8.00pt, dial knob 9.60pt, pad glyph 13pt. Legible in both renders.

`PanelLayout.minimumFontSize = 9` and `fontSize(_:)` (`:83-90`) have landed since
the a11y audit, which addresses its defect 6. Three notes on what that leaves:

- The clamp currently protects a code path nothing uses. If a size toggle ships
  in M3, at compact the agent slot number, the agent state label and the command
  cap all clamp to exactly 9pt. The type hierarchy between the dominant zone and
  the secondary zone flattens to nothing, which undoes part of what makes the
  agent keys dominant.
- `DirectionPadView.swift:171` uses `13 * layout.scale` raw, bypassing
  `fontSize(_:)`, which `PanelLayout.swift:82` explicitly instructs callers to
  use. Harmless today at 10.4pt, and invisible to the self-check at `:407`
  because that check can only see calls that route through the clamp.
- The `minimumScaleFactor` floors are unchanged at 0.65, 0.75 and 0.55
  (`AgentKeyView.swift:413`, `CommandKeyView.swift:244`, `DialView.swift:327`).
  A longer dial label arriving from an adapter still reaches roughly 4.95pt, and
  `DialScale` labels do arrive from adapters (`DialView.swift:25-37`).

Either delete `.compact` or fix it before exposing it. A half-live size class is
the kind of thing that ships by accident.

---

## 3. Brand and legal distance

The visuals are clean. No logos, no wordmarks, no borrowed colour or type, no
imitation of a product photo, nothing resembling official packaging. I verified
across `Sources/`, `Scripts/` and `Package.swift` that there are zero occurrences
of `openai`, `open ai`, `work louder`, `worklouder`, `chatgpt`, `gpt`, `official`,
`authorized`, `licensed`, `partner`, `compatible`, `replica` or `clone`. The
exposure is not in the pixels.

### Finding 6 (high). The name is the exposure

`Scripts/bundle.sh:24` sets `CFBundleName` to `Virtual Codex Micro`. "Codex Micro"
is the referenced product's name taken verbatim, and "Codex" is separately an
active OpenAI product line, including the Codex CLI this app's own `PLAN.md`
plans to adapt. Prefixing "Virtual" does not create distance. It reads as the
virtual version of the Codex Micro, which is to say a first-party companion app.

It appears in the three places a user reads a product's identity:

- `bundle.sh:24` — the Finder, Dock and About label.
- `bundle.sh:32` — `NSAppleEventsUsageDescription`, "Virtual Codex Micro raises
  the terminal window that owns an agent session when you click its key." This is
  the macOS Automation consent sheet, which is a high-trust moment.
- `Backends/ClaudeHookInstaller.swift` writes "Installed by Virtual Codex Micro"
  into a shell script placed in the user's Application Support directory.

There is no "unofficial", no "inspired by" and no disclaimer anywhere in shipped
copy. The ambiguity is worse here than it would be for an unrelated app, because
this one genuinely integrates with the adjacent tool ecosystem, so a user has a
plausible reason to assume affiliation rather than a far-fetched one.

`bundle.sh:26` sets the bundle identifier to `dev.local.virtualcodexmicro`, a
placeholder that must not ship, and it disagrees with the logger subsystem
`com.virtualcodexmicro.app` at `State/SessionRegistry.swift:4`.

Task 034 defers the legal pass to M4. For copy and the icon that is defensible.
For the name it is not, because the name is load-bearing on the bundle
identifier, the TCC identity, the Application Support path
(`ClaudeHookInstaller.swift`), the Carbon four-char signature
(`Panel/HotkeyCenter.swift:145`), the `VCM.panel.*` UserDefaults keys
(`PanelController.swift:28-29`) and the hook script's own self-description.
Renaming after M2 is a migration with a TCC re-prompt, not a copy edit. Hence
condition C4.

### Not a brand problem, worth fixing anyway

Every "Claude" reference names the backend being integrated, which is accurate and
nominative. One rough edge: `State/StateEngine.swift:314` builds
`reason = "\(winner.sourceID) reported \(state.rawValue)"`, and the doc comment at
`:131` says that string goes in a tooltip. A user therefore sees
`claude.hooks reported running`. A `displayName` on the source fixes it.

Separately, and outside the shipped binary: `virtual-codex-micro-prd.md:5`
describes the app as recreating the layout and colour semantics of "OpenAI and
Work Louder's Codex Micro". That does not ship in the app, but it ships in the
repository if the repository is ever public.

---

## 4. The four known items

### Finding 10 (medium). Three focus-ring languages. Does not block M2

Confirmed, and it is three languages across four zones:

- `AgentKeyView.swift:424-436` — detached two-tone ring outside the key, drawn in
  the key's own `keyLabel` and `keyFill`.
- `CommandKeyView.swift:255-256` — `Color.accentColor` ring, outset by 2pt.
- `DirectionPadView.swift:160-164` — `Color.accentColor` ring, inset.
- `DialView.swift:242` — a `.tint` circle.

Tabbing across the panel changes the "you are here" marker three times. Each is
individually visible, so nobody is locked out, and it degrades gracefully. Assign
it to one owner now rather than after M2 adds a popover with a fifth. Same root
cause as finding 3.

### Finding 11 (high). The agent key never says what pressing it does. Blocks narrowly

Still open. `AgentKeyView` has no `accessibilityHint` and no named action
(verified: zero matches in the file), and `main.swift:96-97` still prints instead
of calling `FocusResolver`. A VoiceOver user hears "Agent key 3, audit ledger
sync, running, button" and is not told that activating it raises a terminal
window, which is the one action available on every session type.

What makes this more than a one-line fix is that `FocusResolver` now exists and
returns three tiers with a user-facing sentence per tier
(`Backends/FocusResolver.swift:119-148`). The hint cannot be a fixed string. It
has to reflect the tier: raises the window and tab, or raises cmux but cannot
target the tab, or why nothing can be raised. That is a small design decision, and
it should be settled while the key is being wired rather than retrofitted after.

### Finding 8 (critical). Keyboard traversal is unverified and may be inert. Blocks

The most serious of the four known items, and not really a test gap.

macOS "Keyboard navigation" is off by default. With it off, Tab moves focus only
between text fields and lists. All 18 stops on this panel are `Button`s or
`.focusable()` cells. Nothing in the repository addresses this: no onboarding, no
in-panel arrow traversal, no probe of `AppleKeyboardUIMode` (verified, zero
matches). On a default machine the likely outcome is that Tab reaches nothing and
the entire keyboard story is inert. M1's exit criterion in `PLAN.md` says "full
keyboard + VoiceOver".

Two things make it worse than it sounds:

- `FocusOrder` is 448 lines with a thorough self-check, and it is referenced only
  by `SelfCheck.swift:52` and by itself. No view holds a cross-zone
  `@FocusState`, and nothing calls `next(after:)` or `previous(before:)`. The
  canonical 18-stop order is a validated model of behaviour that does not exist.
  `PanelRootView` now composes all four zones, which the a11y audit said was the
  missing prerequisite, but it did not take the focus responsibility with it.
- The four zones still own four independent `@FocusState` scopes
  (`AgentKeyView.swift:255`, `CommandKeyView.swift:169`, `DialView.swift:208`,
  `DirectionPadView.swift:112`), so whatever traversal happens is SwiftUI's
  default view-tree walk. `PanelRootView`'s declaration order happens to match
  `FocusOrder`'s intended order, which is luck, and no check defends it.

Credit where due: the audit's item 12 is fixed. `main.swift:43` now calls
`showAndTakeKeyboardFocus()` on summon, so a hotkey-summoned panel can receive
keys at all.

Why this blocks: M1 cannot be signed off against "full keyboard" until someone
has established empirically what Tab does on a default machine. That is a
twenty-minute check, not a project. Either it works, in which case wire
`FocusOrder` and move on, or it does not, in which case in-panel arrow traversal
is a real scope item that has to be decided before M2 adds more controls.

### Finding 12 (medium). No screen reader run. Blocks in one specific respect only

A full VoiceOver pass can wait. One assumption inside it cannot.

`CommandKeyView.swift:218-224` asserts that a disabled SwiftUI `Button` is still
visited by VoiceOver and announced as dimmed, and both the disabled-key design and
`FocusOrder`'s skip logic rest on it. The a11y audit calls it "the single most
load-bearing unverified assumption in the pass" and it is still unverified. If it
is wrong, the explanation of why a key is dead never reaches a screen-reader
user, which is the entire point of capability gating, and task 025 is about to
build more of exactly that. Verify this one thing under C3; defer the rest.

---

## 5. Fix before M2 versus what can wait

### Before more M2 UI lands on these surfaces

1. Achromatic state separation, all 21 pairs, all four appearances, with the check
   (findings 1 and 2). Condition C1.
2. `idle` added to the render, then re-review that render (finding 2). Condition
   C2.
3. Empirical Tab behaviour on a default machine, plus the disabled-`Button`
   VoiceOver assumption (findings 8 and 12). Condition C3.
4. Product name decision (finding 6). Condition C4.

### Assigned, not blocking

5. Dial disabled treatment: design it in M1, wire it in task 025 (finding 4).
6. `onPreset` dropped at `PanelRootView.swift:60`, one line (finding 5).
7. One owner for cross-zone visual vocabulary: reconcile the three focus rings and
   the dashed-border collision together, since they are the same defect (findings
   3 and 10).
8. Tier-aware `accessibilityHint` on the agent key, settled while task 024 is
   wired (finding 11).
9. Pad reads as cursor keys: add a shared plate or continuous cross so the five
   cells read as one control.
10. Dial prominence: either give the ring notch detail that earns 108pt, or shrink
    it and reclaim the top-centre void.
11. Compact size class: delete it or fix it, but do not expose a toggle to it as
    it stands (finding 9).
12. `StateEngine.swift:314` leaks `claude.hooks` into a tooltip; add a source
    display name.
13. Reduce Transparency in `DialView` and `DirectionPadView`, the a11y audit's
    defect 3, still unaddressed. Determine whether AppKit's automatic
    `NSVisualEffectView` substitution covers it, then either assert that or fix
    it.
14. `tasks.md` is stale: seven M2 tasks have code in the tree and sit in TODO.
15. Placeholder content: `c1` and `c2` command caps.

---

## 6. What I could not judge

Stated plainly, because a static render cannot show these and neither can source
reading.

- All motion: the running pulse, state-transition timing, the dial's springs.
- Hover and press treatments, and whether the 1.04 and 0.955 scale changes read
  as intended.
- Whether Reduce Transparency, Reduce Motion and Increase Contrast produce the
  intended pixels. The self-checks prove the decision functions branch correctly,
  not what gets drawn.
- Actual VoiceOver output: phrasing, order, whether the 33-word disabled reason is
  tolerable when heard, whether the dial's adjustable action and named reset are
  reachable, whether the pad produces one group of five or a flattened list.
- Real Tab behaviour, which is finding 8.
- Pointer accuracy in practice, behaviour at non-default display scaling, and
  behaviour on a second monitor at a different backing scale factor.
- The reference hardware, which I have not seen. Section 1 judges the control map
  as described in `PLAN.md` and `tasks.md`.

### Evidence run for this review

```
swift build                                    → Build complete
VCM_SELFTEST=1 ./.build/debug/VirtualCodexMicro → selfcheck: ok (7 states), exit 0
VCM_RENDER=<scratch> ./.build/debug/VirtualCodexMicro
   → both PNGs byte-identical to docs/renders/, so the reviewed
     artifact matches current source
sips --matchTo "Generic Gray Profile.icc"      → greyscale conversion of both
                                                  renders, for finding 1
```

Contrast and separation figures were computed independently from the raw values in
`StateColors.swift`, using the same WCAG relative-luminance formula and the same
source-over compositing the file implements, so they are directly comparable to
the numbers its own self-check produces.

One caveat on the build: a first `swift build` failed with
`cannot find 'ClaudeHookInstaller' in scope` at `ClaudeHookSource.swift:259`. This
was a transient race, not a defect. Files were landing in the tree every thirty
seconds or so during the review, `ClaudeHookInstaller.swift` appeared mid-review,
and a rebuild was clean. Worth recording only as evidence for the observation in
the verdict that M2 is being written concurrently with its own gate.
