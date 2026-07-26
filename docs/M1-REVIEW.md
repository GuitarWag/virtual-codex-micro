# M1 exit review — the 4x4 panel

Task T-VCMPLAN1-042. Reviewed 2026-07-26 (21:00–21:30) against the four
reference images in `docs/`, `PLAN.md`, `tasks.md`, `Sources/VirtualCodexMicro/`,
the committed renders in `docs/renders/`, and a fresh render of the source as it
stood at 21:21.

This replaces the review of the 412x276 four-zone panel, which described geometry
that no longer exists. Section 0 records which of its findings the rebuild
dissolved and which survived it, because that is the part worth keeping.

Two facts about the artifact, stated first because they qualify everything below.
`Scripts/check-render.sh` reports **both committed PNGs now differ from the
current source**, so `docs/renders/` is stale; my pixel numbers come from a fresh
render unless marked otherwise. And the source moved while I read it —
`Panel/MenuBarItem.swift` and `Support/PixelCheck.swift` were created during the
review, and `PixelCheck`'s own reported numbers changed between two runs ten
minutes apart. Anything I attribute to a line number is as of 21:21.

## Verdict: GO, with four conditions

The rebuild worked. The square 4x4 grid, the 1u encoder in the top-left cell, the
single round stick in the top-right, the six agent caps straddling rows 0 and 1,
the four-plus-two command cluster with a 2u microphone, the corner screws, the
status LEDs in the bottom-left cell, the orientation arrow and the three plate
legends — all of that is in the right places and reads as the object at a glance.
Three of the old review's structural criticisms were artifacts of the wrong model
and are gone. The joystick in particular went from "four cursor keys" to a
properly conceived single control with arrow keys, per-direction accessibility
actions and deliberately inert diagonals. The keyboard story went from "possibly
inert on a default machine" to actually wired. Two of the five known-open items
are already closed in code.

What holds it back is one unresolved design decision and its consequences. The
palette's luminance ladder and photographic fidelity are **formally
incompatible** on the cap fill — not in tension, incompatible, by arithmetic I
give in finding 1 — and nobody has chosen between them. Everything downstream of
that choice is currently half-committed to both: the caps are too dark to read as
the reference's white plastic, and simultaneously not separated enough to satisfy
the floor the ladder exists to enforce. The app's own new pixel probe agrees, and
it is switched off in the verify path.

None of this is "stop the project". All of it is cheaper now than after M2 builds
more UI on these surfaces.

### The four conditions

**C1. Decide where the achromatic channel lives, then re-tune.** Finding 1. Six
mutually 1.8:1-separated luminances need 18.9:1 of range; the reference's lit caps
occupy a band offering 1.17:1. The cap fill cannot carry both. Either the ladder
moves off the fill (onto the glyph, a badge, or texture — the glyph is already the
second channel and is already carrying more than it can) or fidelity on the fill
is dropped explicitly and written down. Fold in finding 6: if the glyph has to
carry more load, the fact that two of the six status glyphs are the same marks as
two of the six action glyphs one row below stops being cosmetic.

**C2. Fix the rasteriser, turn the pixel probe on, then fix what is still red.**
Findings 2, 3, 5. In this order, because the second and third steps depend on the
first. `Support/PixelCheck.swift:280-281` and `Panel/OffscreenRender.swift:48-51`
both sample `NSHostingView.cacheDisplay(in:to:)`, which I demonstrated renders a
blurred layer as nothing at all. Every blur-dependent surface — the underglow,
the per-cap light spill, the frost's smoothing pass — is therefore unverifiable
from either the artifact or the probe. `ImageRenderer` renders the same probe
correctly and is a one-line substitution. Then wire `VCM_PIXELCHECK` into
`Scripts/verify.sh`, which today sets only `VCM_SELFTEST` (`verify.sh:26`), so the
gate is green while the probe is red. Include the slot numeral, which no check
covers, and the real drawn plate colour, which the model has wrong.

**C3. Make the joystick and the dial honest.** Findings 7 and 8. M1's exit
criterion says "all 4 zones interactive". `Panel/PanelRootView.swift:144-145`
passes a no-op preset closure and an empty `openChooser`, so all five joystick
targets dispatch nothing — a regression on the old review, which found four of
five inert. `Controls/DialView.swift` still has no enabled, disabled or capability
concept in 713 lines, and `PanelRootView.swift:129-136` passes no gate, so on
observed sessions the dial renders fully live and cannot do anything. The wiring
is task 025; the missing design is M1's.

**C4. Decide the product name.** Finding 10. Unchanged as a recommendation and
materially more expensive than when it was first raised: the rename now also
orphans hook entries the installer has written into the user's own
`~/.claude/settings.json`, because idempotency is keyed on a literal path
containing the name.

C1 is a design decision that should take an hour and unblocks C2's re-tune. C2 is
sequenced work. C3 is one line plus one small design. C4 costs nothing today.

---

## 0. What the rebuild resolved, and what survived it

| Old finding | Status now |
|---|---|
| Dial is the largest element and carries the least information | **Dissolved.** It is a 1u cell, `PanelLayout.swift:223`. |
| The pad reads as cursor keys | **Dissolved.** One stick, one focus stop, arrow keys, named per-direction actions: `Controls/DirectionPadView.swift:25-60,152-185`. |
| An 84x146pt void at top centre | **Dissolved.** Every one of the sixteen cells is occupied. |
| 1 — four lit states isochromatic, complete/error 1.00:1 | **Resolved in the model, not in the pixels.** The ladder is real (`StateColors.swift:24-38,415-416,454-466`) and the model now measures 1.81–1.83. Rendered, six pairs measure 1.39–1.71. Becomes finding 2. |
| 2 — idle, unassigned and the panel are one tile in light | **Partly resolved.** `idle` moved to `0xA1A1AD` (`StateColors.swift:204-212`) and measures 1.92:1 against the rendered plate. `unassigned` versus `idle` is still ~1.55:1 in the model and still unenforced; `unassigned` versus `running` in dark is ~1.08:1 and also unenforced. Becomes finding 4. |
| 3 — disabled command keys and unassigned agent keys share a dashed idiom | **Resolved.** `CommandKeyView.swift:329-341` replaced the dash with a solid hairline plus no gloss and no shadow. The task's explicit check passes. The idiom did reappear elsewhere: finding 12. |
| 4 — dial has no disabled treatment, dead on observed sessions | **Stands.** Condition C3. |
| 5 — `onPreset` dropped, four of five pad targets inert | **Stands, worse.** Five of five. Condition C3. |
| 6 — the product name is the legal exposure | **Stands, more expensive.** Condition C4. |
| 7 — hit targets pass | **Superseded rather than resolved.** The 28pt floor still holds for all fourteen non-nested targets, but the five joystick directions are now 15.3pt sub-regions marked `nested` and exempt from the floor (`PanelLayout.swift:30-33,235-244`). Defensible — the stick is a drag plus arrow keys, not five buttons — but pointer precision on a direction went from a 36pt cap to a 15pt drag-release zone. Recorded, not charged. |
| 8 — keyboard traversal unverified, possibly inert, `FocusOrder` unwired | **Resolved.** `PanelRootView.swift:22` holds the cross-zone `@FocusState`; `:36-46` wires Tab and Shift-Tab through `FocusOrder.step`, which sidesteps the macOS "Keyboard navigation" default entirely. Residual in finding 14. |
| 9 — compact size class is a latent trap | **Unchanged.** `PanelController.swift:54` still defaults to `.compact`; nothing in the shipping path constructs it. |
| 10 — three focus-ring languages | **Improved to two.** The agent key draws a detached two-tone ring in its own colours (`AgentKeyView.swift:593-605`); the other three zones all resolve to the accent colour (`CommandKeyView.swift:266`, `DialView.swift:266`, `DirectionPadView.swift:155`). Not blocking. |
| 11 — the agent key never states what pressing it does | **Stands.** Zero `accessibilityHint` in `AgentKeyView.swift`, while the joystick, the overflow chip and the popover all have one. |
| 12 — no screen reader run | **Stands.** |
| `c1` / `c2` placeholder caps | **Mostly resolved.** They carry `bolt` and `face.smiling` (`CommandKeyView.swift:159-160`); `face.smiling` is still a placeholder where the reference has a terminal glyph. |

## Findings index

Ranked by severity across the whole review.

| # | Severity | Finding | Section |
|---|---|---|---|
| 1 | critical | The luminance ladder and cap fidelity are arithmetically incompatible, and nothing has chosen | 1 |
| 2 | critical | Six rendered lit pairs miss the declared floor; the ladder is enforced on the one region the glyph covers | 2 |
| 3 | critical | The slot numeral is the only per-key address and no check covers it; 2.7–3.5:1 | 2 |
| 4 | high | `unassigned` is outside the enforced set and collides with `running` in dark | 2 |
| 5 | high | The underglow reserves 22pt and delivers 2pt, and cannot be verified from the artifact | 4 |
| 6 | high | Two status glyphs are the same marks as two action glyphs, one row apart | 2 |
| 7 | high | All five joystick targets dispatch nothing | 2 |
| 8 | high | The dial still has no disabled treatment or gate | 2 |
| 9 | high | Attention hierarchy inverts in light: `needsInput` is the quietest lit cap | 2 |
| 10 | high | The name, not the legends, is the brand exposure — and the rename bill grew | 3 |
| 11 | medium | The enabled command cap is less distinct from the plate than the disabled one | 2 |
| 12 | medium | The dashed idiom now means "empty slot" and "joystick", and the joystick's dash copies a render artifact | 1 |
| 13 | medium | `claude.hooks` still reaches a visible, hoverable, spoken string | 3 |
| 14 | medium | Two competing Tab handlers; Shift-Tab may never step backwards | 2 |
| 15 | low | `face.smiling` placeholder; two stale comments; competitor marks compiled into the binary | 1, 3 |

---

## 1. Fidelity and recognisability

### What reads as the object

Structure first, because it is the thing that was wrong before and is right now.
`PanelLayout.swift:15-20` draws the grid it implements, and the implementation
matches the photographs cell for cell: encoder at `(0,0)`, agent caps at `(0,1)`,
`(0,2)` and all of row 1, the bolt / accept / reject / branch row, then the status
cluster, the 2u microphone and the sixth command cap. Four of six command glyphs
match the reference exactly — bolt, check-circle, x-circle, branch arrow
(`CommandKeyView.swift:155-160`). The plate furniture is all there and all quiet:
four recessed hex screws (`DeviceChrome.swift:312-338`), three capsule LEDs and
the small dark button in the bottom-left cell (`:386-408`), the orientation arrow
above the grid, the two rotated side legends and the bottom-centre legend
(`:342-360`). The panel measures 324x318pt, aspect 1.019, and the self-check
defends squareness (`PanelLayout.swift:377-380`). Someone who has seen the
hardware would name this device from either render.

The restraint holds. No faux bezel gradients, no fake switch housings, no
skeuomorphic keycap walls. The reference's caps are visibly proud of the plate
with dark switch bodies showing in the gaps; ours are flat tiles separated by 6pt
of plate. That is a deliberate and correct trade — I would not spend fidelity
budget on moulded sidewalls — but it is worth naming as the reason the caps read
as tiles rather than as caps, because it compounds finding 1 rather than being
independent of it.

### Finding 1 (critical). The ladder and the caps cannot both be right, and nothing has chosen

The task brief frames the known gap as "our cap cores stay more saturated than the
reference's pale LEDs". Measured, that framing is wrong in a way that matters:
**chroma is already comparable; luminance is the entire gap.**

Peak chroma and its luminance, sampled over each lit cap and over the reference's
lit caps (max channel minus min channel; JPEG, white balance and the fact that
two of the four references are product renders rather than photographs all apply):

| Cap | Peak chroma | Luminance there |
|---|---|---|
| reference, lit teal cap (`codex_micro_…jpg`) | 0.496 | 0.89 |
| reference, lit band row 0 (`OIF-450125000.jpg`) | 0.351 | 0.97 |
| reference, lit band row 1 (`OIF-450125000.jpg`) | 0.365 | 0.85 |
| ours, `needsInput` | 0.304 | 0.84 |
| ours, `complete` | 0.328 | 0.66 |
| ours, `error` | 0.532 | 0.45 |
| ours, `running` | 0.559 | 0.35 |

The reference's LEDs are strongly chromatic *and* sit at 0.85–0.97 luminance: a
hue riding on near-white plastic. `needsInput` matches it. `running` is 2.5x too
dark and `error` 2x. Desaturating would not close that; only raising luminance
would, and raising luminance is precisely what the ladder forbids —
`StateColors.swift:34-38` explains that a saturated blue cannot exceed 0.07
relative luminance, so `running` is pinned to the bottom rung, and `:276-280`
pins `unknown` near black on a light panel because it has no hue and takes
whichever rung is left.

The incompatibility is arithmetic, not aesthetic. Five 1.8:1 steps require
`1.8^5 = 18.9` of luminance range. The reference's cap band, roughly 0.85 to
1.00 relative luminance, offers `(1.05/0.90) = 1.17`. There is no assignment of
six states to that band that satisfies the floor. The palette file knows half of
this — `StateColors.swift:409-414` already documents that a sixth rung does not
fit between black and white and drops `idle` off the ladder for that reason. The
unstated corollary is that the ladder is only satisfiable if the caps are allowed
to go dark, which is exactly what makes them stop looking like the object.

So this is a decision, and it has been deferred by building both. My
recommendation, for what it is worth: keep the ladder as the guarantee and move
it off the fill. The panel already has a second non-colour channel — the glyph —
and a third it is not using: the glyph's own container, which is currently a
circle for five of seven states. A pale cap in the reference's luminance band
with a *dark, high-contrast, differently-shaped* mark in it satisfies both, and
it is closer to the hardware than either half of the current compromise. That
also fixes finding 9 for free. What it costs is that hue stops being sufficient
on its own, which the file's own thesis already concedes.

### Finding 12 (medium). The dashed idiom, and a copied render artifact

Two things about the joystick's dashed outline (`DirectionPadView.swift:189,210`,
dash `[3, 2.2]`).

First, provenance. The comment at `:27-29` says the reference shows "a slightly
recessed square with a dashed outline silkscreened around it". That is true of the
three product renders. It is **not** true of `openai_codex_micro_…jpg`, the one
image that is a photograph of a real device on a real desk — there the stick is a
plain black round cap in a plain recess, with no dashed square anywhere. The
dashed outline is almost certainly a mask or alignment box in the marketing
renders, not a feature of the object. We have faithfully reproduced an artifact.

Second, collision. `AgentKeyView.swift:528-532` still dashes the `unassigned`
edge at `[4.6, 3.22]`. In the dark render the joystick's dashed square sits
directly above agent key 6 in `unassigned`, which is a dashed cap containing a
dashed circle glyph. One idiom, two unrelated meanings, in adjacent cells. This is
the collision the old review found between command keys and agent keys — fixed
there (`CommandKeyView.swift:329-334`), reintroduced here. Dropping the dash on
the joystick fixes the collision and the fidelity question in the same edit.

### Finding 15 (low, fidelity half)

`CommandKeyView.swift:160` uses `face.smiling` for `custom2`, where the reference
has a `>_` mark in a rounded pentagon. It is the one glyph on the panel that means
nothing. `PanelLayout.swift:93` still says the bottom of the plate carries the
"Let's build" legend; it carries `glance, don't stare`.

---

## 2. Did the fidelity push cost usability

The PRD's named risk. Mostly no — and where it did, the cost is measurable.

The word did come off the agent caps (`AgentKeyView.swift:553-564`) and that was
the right call: a 9pt word on a 46pt cap was the main thing stopping the panel
looking like the object, and the word moved rather than disappeared —
`accessibilityValue` and the tooltip both carry `state.label`, enforced across
`allCases` at `:627-640`. The glyph set that replaced it is genuinely distinct as
a set: play, exclamation, check, x-in-octagon, question, pause, dashed circle
(`:139-149`), all seven proven unique and proven to resolve as real SF Symbols
(`:646-662`). At the shipping regular size the glyph renders at 17pt on a 46pt
cap, which is legible in both renders. Breaking the circle family for `error`
with an octagon (`:136-138`) is the single best small decision in this file.

What the glyph cannot do is carry the load alone, and three findings below are
different faces of it being asked to.

### Finding 2 (critical). Six rendered pairs miss the floor, and the floor is measured where the glyph is

The app's own new probe and my independent sampling agree, which is the useful
part. `VCM_PIXELCHECK=1` reports, at 21:21:

```
running vs error       1.61 light   (model 1.82)
complete vs needsInput 1.63 light   (model 1.81)
complete vs error      1.71 light   (model 1.83)
complete vs needsInput 1.63 dark    (model 1.82)
complete vs error      1.63 dark    (model 1.82)
error vs unknown       1.51 dark    (model 1.82)
```

Sampling the fresh render myself over an annulus at r = 0.22–0.32 of the cap side
— just outside the glyph, where the eye reads "the cap colour" — gives
`running/error 1.63`, `running/unknown 1.65`, `needsInput/complete 1.65`,
`complete/error 1.71` in light and `error/unknown 1.39`, `needsInput/complete
1.64`, `complete/error 1.69` in dark. Two methods, within 0.02–0.12 of each
other. The declared floor is 1.8 (`StateColors.swift:401`).

Task 038 records this as "1.78 against a declared 1.8 floor". That number is not
reproducible from the repo — it exists only as prose in `tasks.md:12` and in a
comment at `AgentKeyView.swift:434`. The real worst case is 1.39–1.51, and a
1.4:1 separation between "failed" and "we lost track" is not a rounding
shortfall to wave through.

Three mechanisms, all worth naming because each is a separate fix:

**The measured region is the one the glyph covers.** `StateSwatch.composedKeyFill`
(`StateColors.swift:159-161`) is the fill composited over the backdrop, and the
comment at `AgentKeyView.swift:429-437` says the frost is kept clear "at the
centre out to r≈0.19·side, which clears a 17pt glyph" specifically to protect
that measurement. It protects it into irrelevance: cutting across the `error` cap
at cap-centre height, the pixels from 6pt either side of centre read
`0.988/0.954/0.953` in light — that is the white `xmark.octagon.fill`, not the
fill. Sampling r < 0.16 gives `running/unknown 1.03` and `running/error 1.06`,
which are the *glyph* colours colliding because four states use a white glyph.
The 1.8 floor is enforced on a disc that ships with a label drawn over it.

**"White outside the glyph costs it nothing" is measurably false.** Same comment,
`AgentKeyView.swift:436-437`. Moving my annulus outward from r = 0.22–0.32 to
0.34–0.44 takes light `running/error` from 1.63 to 1.57 and dark `error/unknown`
from 1.39 to 1.36. The frost ramp (`:442-468`) and the moulding gradient
(`:480-496`) both add white, sRGB luminance is convex, so the dark end of the
ladder gains more than the light end and the ladder compresses monotonically
outward. The white is not free; it is the difference between the model's 1.82 and
the render's 1.61.

**The declared backdrop is not the drawn plate.** `panelBackdrop(.light)` is
`0xE8E8ED`, relative luminance 0.810 (`StateColors.swift:116`). The plate the caps
actually sit on measures **1.000** — pure white — at both the top and left bands,
falling to 0.93 at the bottom, because `DeviceChrome.swift:291` fills it with
`controlBackgroundColor` and `:293-300` lays a white 0.40 gradient over the top.
In dark it is worse: declared 0.0117, measured 0.179 in the top band, 0.041
mid-plate and 0.024 at the bottom. The plate's own gradient spans 7.5:1
top-to-bottom, so a cap in row 0 sits on a surface several times brighter than one
in row 1, and there is no single backdrop value for the model to be right about.
Every "versus panel" ratio in `StateColors` is computed against a surface the app
does not draw.

That third mechanism is the real content of task 037. "The colour checks measure
the model rather than rendered pixels" undersells it: the model is measuring a
composite over the wrong backdrop, in the wrong region, before the two whitening
passes that ship. The fix is not only to add a pixel probe — it is to stop
treating the plate as a constant.

### Finding 3 (critical). Nothing checks the one label that addresses a key

The slot numeral is how a user maps a cap to a session, and how every other
surface refers to a slot. It is drawn at `AgentKeyView.swift:580-583` in
`.black.opacity(0.42)` — deliberately *not* `keyLabel`, with a documented reason
(`:573-579`) that the corner goes near-white on every state so a white-labelled
state would lose a white numeral. The reasoning is sound and the consequence is
unmeasured, because `StateColors.selfCheckFailures()` only ever compares
`keyLabel` against `composedKeyFill` (`:429-436`) and the numeral is neither.

Best-case ratios from the fresh render, taking the darkest ink pixel against the
lightest plastic pixel in each cap's corner box — a generous estimate, since the
true ink-versus-immediate-background ratio can only be lower:

| Cap | light | dark |
|---|---|---|
| complete | 2.83 | 2.72 |
| idle / unassigned | 2.94 | 5.24 |
| needsInput | 3.28 | 3.47 |
| error | 5.28 | 3.20 |
| running | 7.04 | 8.29 |
| unknown | 9.43 | 6.16 |

Three of six caps in each appearance fail 4.5:1 at best case, and `complete`
fails it by a wide margin in both. A fixed 42% black over a frost ramp whose
brightness is state-dependent cannot be right for all seven states; the numeral
needs to be measured like everything else, or drawn on something whose luminance
is known.

The same probe reports four glyph failures, which is the same defect on the other
label: `unassigned` 2.76 light and 2.86 dark, `error` 3.66 light, `unknown` 4.36
dark, against models of 9.66, 6.48, 5.12 and 7.62. The model believes these are
comfortable and they are not.

### Finding 4 (high). `unassigned` is outside the enforced set and collides in dark

`litStates` excludes both `unassigned` and `idle` (`StateColors.swift:415-416`),
and the only guard on `unassigned` is against `unknown` (`:469-476`). That guard
is well argued and it holds. Its two siblings are not guarded and one of them
fails.

Computing from the declared values: in the dark appearance, `running` composites
to relative luminance 0.0261 and `unassigned` to 0.0196 — a separation of
**1.08:1**. A working session and an empty slot, told apart in dark only by hue
in a state whose hue is a very dark navy, plus a play glyph against a dashed
circle. In light, `idle` versus `unassigned` is ~1.55:1, improved from the old
review's 1.40 but still under the file's own floor.

`idle` being off the ladder is documented and defended. `unassigned` versus
everything is neither. If an empty slot is going to recede into the plate — and it
should — then the states adjacent to the plate in luminance need a floor against
it, or the pair that means "working" versus "nothing here" is a squint apart in
the appearance most developers use.

### Finding 6 (high). Status glyphs and action glyphs share marks, one row apart

- `complete` is `checkmark.circle.fill` (`AgentKeyView.swift:144`); `accept` is
  `checkmark.circle` (`CommandKeyView.swift:155`).
- `error` is `xmark.octagon.fill` (`AgentKeyView.swift:146`); `reject` is
  `xmark.circle` (`CommandKeyView.swift:156`).

A check in row 1 means "this session finished". A check in row 2 means "approve
the thing it is asking about". The two rows are separated by six points of plate
(`PanelLayout.swift:88`). The x pair is better separated by its container but is
the same mark. Both views
enforce glyph uniqueness — `AgentKeyView.swift:646-653` and
`CommandKeyView.swift:377-380` — and each enforces it only within its own file.
Nobody owns cross-zone vocabulary, which is the same root cause as the old
review's dashed-border finding and as finding 12 above. It matters more now than
it would have before, because the glyph is the channel C1 is likely to load
further.

### Finding 7 (high). The joystick dispatches nothing

`PanelRootView.swift:144` builds the pad with
`DirectionPadView.defaultPresets { _ in }` and `:145` passes `openChooser: {}`.
Every one of the five targets is inert in the assembled panel. The old review
found the four arms inert and the centre working; the centre has since regressed.
`OverflowView`'s `onBind` is also `{ _, _ in }` (`:156`), and the popover's
rebind, clear and open-log callbacks only dismiss (`:112-114`).

The control itself is not the problem — it is the best-built thing in this review.
`DirectionPadView` is one focusable element matching the single `FocusOrder`
stop, takes arrow keys and Space/Return (`:161-167`), publishes each bound
direction as a named accessibility action so a screen-reader user can fire a
specific direction without four focus stops (`:178-181`), carries a real
`accessibilityHint` (`:172`), gates its material on Reduce Transparency
(`:127-131`), and leaves the diagonal cells deliberately inert so a slipped push
fires nothing rather than the neighbour. All of that is wasted on a closure that
discards its argument.

### Finding 8 (high). The dial has no disabled treatment and no gate

Unchanged from the old review and now easier to fix, since the dial is a 46pt
cell. `Support/FocusOrder.swift:126` carries `dialAcceptsInput` and models it
correctly; `Controls/DialView.swift` contains no match for `enabled`, `disabled`
or `capabilit` anywhere in 713 lines; `PanelRootView.swift:129-136` passes no
gate. `PLAN.md`'s capability matrix says the dial is unavailable on observed
sessions, and both committed renders are built with `capabilities: .observed`
(`OffscreenRender.swift:26`) — so accept and reject are correctly greyed while
the encoder next to them renders live and does nothing. Task 012 made disabled a
first-class visual state for command keys; the dial never got the design.

### Finding 9 (high). The attention state is the quietest cap in light

From the committed render, each cap's mid-annulus against the plate: `unknown`
7.46:1, `running` 5.05, `error` 3.41, `complete` 2.11, `idle` 1.80,
**`needsInput` 1.35**. The one state `AgentState.isAttentionWorthy` flags
alongside `error`, and the one `PLAN.md:95-98` says the entire fast-glance thesis
rests on, is the least distinct lit cap against the surface it sits on.

This is forced, not careless: the ladder puts amber on the top rung because amber
only reads as amber when it is light (`StateColors.swift:241-245`), and the light
plate is white, so the brightest state is the one nearest its background. The
underglow partly compensates by pushing opacity harder for attention states
(`DeviceChrome.swift:136-138`), which is the right instinct. But on the keys
themselves the hierarchy is inverted, and it is inverted by the same mechanism as
finding 1. Whichever way C1 resolves, this is the case to check first.

### Finding 11 (medium). The enabled command cap is the less distinct one

`CommandKeyView.swift:278-281` intends the command caps to be "the brightest thing
on the device — brighter than the plate they sit on", matching the reference where
they clearly are. Measured in light, the enabled `branch` cap's face is 1.01:1
against the plate and the disabled caps are 1.10:1. A pure white cap on a pure
white plate has no face contrast at all; what separates it is a 0.45-opacity
hairline (`:335-341`), the gloss (`:305-316`) and the plate shadow (`:321-327`).
Those do work — in both renders the enabled cap reads as a cap and the disabled
ones read as sunk into the plate, which is the correct reading and a real
improvement on the dashed border it replaced. But the intended mechanism is not
the one doing the job, and the margin is thin enough that a plate tint change
would collapse it.

The task asked specifically whether disabled command keys are distinguishable
from unlit agent keys. They are, comfortably: different size, different position,
solid hairline versus dash, glyph versus glyph, and the agent `unassigned` cap
keeps a glow and a hatch neighbour that the command cluster never has. That check
passes.

Compact legibility, also asked: `PanelLayout.fontSize(_:)` clamps at 9pt
(`:298-300`) and the self-check asserts it across both size classes (`:365-367`),
so at compact scale 0.8 the glyph falls to 13.6pt while the numeral and the
legends clamp up to 9pt. Nothing becomes illegible; the type hierarchy between the
dominant zone and the plate print flattens. Since nothing in the shipping path
constructs `.compact` (`main.swift` passes `.regular`; `PanelController.swift:54`
merely defaults to it), this stays what it was: a half-live size class that should
be deleted or finished before any toggle exposes it.

### Finding 14 (medium). Two Tab handlers

`PanelRootView.swift:36` registers `.onKeyPress(.tab) { step(by: 1) }` and
`:37-40` registers a second handler on the same key that returns `.ignored`
unless Shift is held. If the first is consulted first it consumes Shift-Tab and
backward traversal never happens. I cannot determine handler order from source and
cannot test interaction from a static render. Worth twenty seconds with the app
open. Separately: with the system's own "Keyboard navigation" setting *on*, both
the system's Tab and the app's handler are live, which may double-step.

---

## 3. Brand and legal distance

### The legends are far enough. The name is not.

The invented plate legends are sufficient distance. The real plate reads "Work
Louder | OpenAI 2026", "You can just build things", "Let's build"; ours reads
"VIRTUAL PANEL · 2026", "six keys, one glance", "glance, don't stare"
(`DeviceChrome.swift:150-161`). No mark is reproduced, the self-check enforces
that across all four legends (`:521-529`), and the voice is our own rather than a
pastiche — "six keys, one glance" is a product description, not an imitation of a
slogan. What is copied is the *arrangement*: maker-and-year rotated down the left
edge, tagline rotated up the right, a short phrase bottom-centre, all at the same
weight and tracking. That is plate trade dress rather than trademark, and for a
homage tool it is acceptable. It would stop being acceptable if the left legend
adopted a two-part "MAKER | MAKER YEAR" form with a real second party in it;
"VIRTUAL PANEL · 2026" stays clear of that.

Nothing else in the visuals reads as an official product. No logos, no wordmarks,
no borrowed type, no imitation packaging.

### Finding 10 (high). The name, and what a rename now costs

`Scripts/bundle.sh:24` sets `CFBundleName` to `Virtual Codex Micro`. "Codex Micro"
is the referenced product's name verbatim, "Codex" is a live OpenAI product line
including the CLI this app's own `PLAN.md` plans to adapt, and "Virtual X" reads
most naturally as the first-party virtual edition of X. It reaches the user in
every high-trust moment: Finder and the Dock, the DMG volume name
(`Scripts/package.sh:46`), System Settings, and each TCC consent sheet — where
the sentence is "Virtual Codex Micro would like to control…"
(`bundle.sh:32,38,40`, mirrored in Swift at `SpeechCapture.swift:247,250`). There
is no "unofficial", no "inspired by" and no disclaimer in any shipped string.

The exposure is unchanged. The bill for fixing it has grown, and that is the new
information. When this was first raised the cost was a bundle-identifier change, a
TCC re-prompt and some paths. It now also includes:

- **The user's own settings file.** `ClaudeHookInstaller.swift:102` builds
  `~/.virtual-codex-micro/claude-hook.sh`, and that literal path is written into
  `~/.claude/settings.json` once per subscribed event, eleven of them (`:130`).
  Idempotency is detected by matching that path (`:221-222`), so after a rename
  the installer no longer recognises its own prior entries: reinstall leaves the
  old eleven behind and adds eleven more. There is already a
  `legacyForwarderURLs` cleanup list at `:109-111`, which is precedent for the
  migration, not a substitute for the decision.
- **Two Application Support paths** holding the user's key bindings and slot
  bindings (`ClaudeHookInstaller.swift:80`, `KeyMapStore.swift:409`,
  `SessionRegistry.swift:41`), which a rename orphans unless migrated.
- **Six mutually non-derivable spellings** of one identity:
  `dev.local.virtualcodexmicro` (bundle id, `bundle.sh:26`),
  `com.virtualcodexmicro.app` (logger subsystem, four files), `vcm1` (Carbon
  four-char signature, `HotkeyCenter.swift:145`), `VCM.panel.*` (UserDefaults,
  `PanelController.swift:28-29`), `VirtualCodexMicro` (Application Support), and
  `.virtual-codex-micro` (home directory). The bundle id and the logger subsystem
  disagree on both prefix and form, and `dev.local.` is a placeholder that must not
  ship.

Deciding the name is still free today. Deciding it after M2 ships hooks to real
users is a migration against a file we do not own.

### Finding 15 (low, brand half). The guard is the only thing that violates itself

`DeviceChrome.swift:524` iterates `["openai", "work louder", "codex"]` to assert
no legend carries a competitor mark. Those are real string literals in the shipped
binary, so `strings` on the app returns `openai` and `work louder` — which is
exactly how a due-diligence sweep would check. Trivially fixable and worth fixing,
because the alternative is explaining it.

Also repo-only but shipped if the repo ever goes public:
`virtual-codex-micro-prd.md:5` describes the app as recreating the layout and
colour semantics of "OpenAI and Work Louder's Codex Micro", `PLAN.md:237` uses
"replica", and the four reference images are unlicensed product photography
checked into git with `openai` in a filename.

### Finding 13 (medium). `claude.hooks` is still visible, hoverable and spoken

`State/ActivityLog.swift:155` builds `"\(from.label) → \(to.label) · \(source)"`
from the raw `sourceID`, and `Panel/ActivityStripView.swift:187,195,196` renders
that same string as visible row text, as the tooltip and as the VoiceOver label.
A user reads, hovers and hears `running → complete · claude.hooks (witnessed)`.
The codebase already solved this once: `Panel/SessionPopover.swift:90-97` carries
a display-name map with a comment saying raw ids "read as debug output", and maps
`claude.hooks` to "Claude Code hooks". Two surfaces, two vocabularies, one of them
debug output. Not a brand problem — every "Claude" reference is accurate and
nominative — but it is the one place the app looks unfinished in a way a user can
see.

---

## 4. The underglow

### The rule is right. The order is wrong, and the light may not be reaching the desk.

Taking the rule first, since it is the part the previous review never saw.
Most-urgent-wins is correct and the alternative is worse. `DeviceChrome.swift:26-30`
argues it and `:451-461` defends it properly: every pair in the chain is tested
with the stronger state outnumbered five to one, so an implementation that counted
or averaged would fail the check. Five calm sessions must not be able to bury the
one that needs a human. Keep the mechanism.

Two things about it are wrong.

**`error` above `needsInput` is the wrong order for this product.** The declared
chain is error > needsInput > unknown > running > complete > idle
(`:74-84`). An error is a fact that has already happened and stays true until
someone acts; `needsInput` is a person blocked *right now*, and it is the only
state where turning your head changes the outcome. `PLAN.md:95-98` says
`needsInput` is what the entire fast-glance thesis rests on. With error ranked
above it, one stale failed session pins the case red indefinitely and the amber
that means "you, now" never reaches peripheral vision again — which is the burial
the rule exists to prevent, displaced one rank up. Both committed renders
demonstrate it: five states are on screen, one of them `needsInput`, and the case
is red.

**A single unqualified colour loses more than it needs to.** One blocked session
and six blocked sessions are the same picture, and nothing decays. Per-slot colour
is not the answer — the hardware has one light strip and mimicking that is
correct — but the glow already has a second dimension it barely uses: opacity
already varies by `isAttentionWorthy` (`:136-138`), so it could vary by count, or
a state unacknowledged for some minutes could drop a rank so a stale error stops
outranking a live prompt. Either is a few lines and neither breaks the rule.

Worth noting that the glow has *no* non-colour channel at all. `:40-44`
deliberately refuses to pulse, and that decision is right — a pulsing case in
peripheral vision cannot be ignored, and the panel must be ignorable until it is
not. But it means that for a colour-blind user the case says "something" and never
"what". The keys still carry glyphs, so this is degradation rather than failure;
still, the file's own thesis is that the case is the peripheral channel and the
keys are the detail (`:7`), which makes the peripheral channel the one with no
redundancy. Under Reduce Transparency the halo already becomes a solid ring
(`:139`), and varying that ring's *width* by rank would be free.

### Finding 5 (high). 22pt reserved, 2pt delivered — and the artifact cannot settle it

`PanelLayout.swift:98-102` reserves a 22pt transparent margin on every side
explicitly "so the state underglow can bleed outside the device the way the
reference photographs show", noting that without it "the whole at-a-glance
effect — which is ambient light spilling onto the desk, not a lit key — is lost".
That margin costs 44pt of a 324pt panel dimension, about a quarter of the panel's
area.

Sampling the alpha channel outward from each of the four case edges gives the same
profile on all four sides: 0.29 at 2pt out, **0.00 at 4pt out and beyond**. The
declared blur radius is 17.6pt (`DeviceChrome.swift:134`, `bleed * 0.8`). Area-
averaged chroma in the left bleed margin is 0.026 against 0.276 in the equivalent
strip of desk below the reference device. Meanwhile our case *wall* averages 0.183
chroma against the reference skirt's 0.143 — so the colour is stronger than the
reference inside the shell and roughly absent outside it. What reads as underglow
in our renders is the tinted wall, not light in the air.

I cannot tell you whether that is a geometry bug or a rendering artifact, and that
is itself the finding. `Panel/OffscreenRender.swift:48-51` samples
`NSHostingView.cacheDisplay(in:to:)`. I built the smallest probe that
distinguishes the two — a 40pt red square blurred by 20pt in a 120pt canvas — and
`cacheDisplay` produced **alpha 0.00 everywhere, including the square's own
centre**, while `ImageRenderer` on the identical view produced the expected
profile (0.50 at centre falling to 0.02 at +56pt). So that rasteriser can drop a
blurred layer entirely. It clearly does not drop every blur in the panel — the
cap frost ramp and the wall wash both render — but it is demonstrably unreliable
for the one pass this section is about.

That indicts two things at once. The committed renders are the artifact this gate
was pointed at, and they cannot answer the question this gate was asked. And
`Support/PixelCheck.swift:280-281` uses the same call, so the new pixel probe is
measuring a stack with an unknown subset of its blur passes missing — neither the
model nor the shipping pixels, but a third thing. Hence the ordering inside
condition C2: substitute `ImageRenderer`, re-render, re-measure, then decide
whether the glow geometry needs changing. The self-check at `DeviceChrome.swift:517`
asserts only that spread plus blur *would fit* inside the bleed margin; nothing
asserts that any of it is drawn there, which is the assertion this finding wants.

---

## 5. The five known-open items

**037, colour checks measure the model rather than rendered pixels — half done,
and the remainder blocks.** A pixel probe now exists (`Support/PixelCheck.swift`,
318 lines, rendering one `AgentKeyView` per state per appearance and sampling the
bitmap). It reports ten failures. `Support/SelfCheck.swift:77-79` gates it behind
`VCM_PIXELCHECK`, and `Scripts/verify.sh:26` sets only `VCM_SELFTEST`, so the
default gate is green while the probe is red. A check that exists and is off is
worse than one that does not exist, because it converts a known unknown into a
believed-clean. Two further caveats found while running it: in my first run the
two increased-contrast appearances produced pixel numbers *identical to two
decimal places* to their normal counterparts while the model numbers differed by
up to 53%, which suggests the harness cannot actually apply Increase Contrast —
and in my second run those rows had disappeared entirely, because the file is
being edited. **Blocks. Condition C2.**

**038, rendered complete/error is 1.78 against a declared 1.8 floor — blocks, and
the number understates it.** Measured 1.51–1.71 across six pairs and both
appearances by two independent methods; the worst case is `error` versus `unknown`
in dark at 1.39–1.51. The 1.78 in `tasks.md:12` is unreproducible from the repo
and appears only as prose. This is not a 1% shortfall to accept by exception; it is
a design decision, and it is condition C1. **Blocks.**

**039, `needsInput` wired but never witnessed — does not block M1. Blocks M2.**
The task note as written is too strong: `PermissionRequest` *was* witnessed
against a real interactive session at 1ms latency
(`spikes/hooks/FINDINGS.md:90,146`), and it is the only thing that produces the
state (`ClaudeHookSource.swift:337`). What is unwitnessed is the event travelling
our own pipeline and lighting the amber key end to end, which is exactly what M2's
"state correct within 1s of a real transition" exists to prove. M1's criterion is
"mock driver cycles all states", and `State/MockBackend.swift:168` schedules a
synthetic `needsInput`. `PermissionDenied` remaining unwitnessed (spike gap G6) is
also an M2 item, already recorded as a requirement on task 023. Retitle the task
to name the pipeline rather than the event, and move it to M2.

**040, the app can be unfindable with no menu bar item — resolved. Does not
block.** `Panel/MenuBarItem.swift:73` creates the status item, retained at
`main.swift:34-35` after hotkey installation, with a toggle
(`MenuBarItem.swift:95-98,146-149`) and a "Bring Panel to Main Screen" escape
hatch for the observed second-display failure (`:109-113,155-163`). The related
half is fixed too: `PanelController.swift:266-280` now centres the default frame
on the primary screen instead of placing it under an auto-hiding Dock. Close the
task; its note describes the pre-fix state.

**041, onboarding unreachable so hook install has no consent path — resolved for
the product path. Does not block.** `MenuBarItem.swift:117-121` adds "Setup &
Permissions…", "Keys & Presets…" and "Activity Log…"; `:181-203` presents
onboarding on first launch when hooks are absent and it has not been offered
before, with a pure predicate at `:39-42`. Install writes only from
`OnboardingView.swift:774` to `:814`, and the view's own `.task` calls `plan` and
`recheck` only (`:561-564`), so opening the window changes nothing. One residual:
`main.swift:90-105` still applies a hook plan with no UI when
`VCM_HOOKAPPLY=install` is set. That is a developer path and it should stay, but it
should be named in the task closure rather than discovered later. Close the task.

---

## 6. What I could not judge

- **All motion.** The `running` pulse (`AgentKeyView.swift:524-526`), state
  transition timing, the dial's springs, the stick's spring-back.
- **Hover and press.** Whether the 1.04 and 0.955 scale changes read as intended,
  and whether the hover rim reads as a bevel rather than as a state change.
- **The underglow on a real desk**, which is the whole point of it, and everything
  else blur-dependent — see finding 5 for why the artifact cannot stand in.
- **Increase Contrast pixels.** The self-checks prove the decision functions
  branch correctly; the probe's increased-contrast rows look like they are not
  actually exercising the setting.
- **Real VoiceOver output.** Phrasing, order, whether the joystick's per-direction
  named actions are discoverable in practice, whether a disabled `Button` is
  visited and announced as dimmed — still the single load-bearing unverified
  assumption, at `CommandKeyView.swift:225-231`, and task 025 is about to build
  more capability gating on it.
- **Shift-Tab**, finding 14, and Tab behaviour with the system's own keyboard
  navigation enabled.
- **Pointer precision on a 15pt joystick direction**, and behaviour at non-default
  display scaling or on a second monitor with a different backing scale factor.
- **Anything that moved during the review.** `MenuBarItem.swift` and
  `PixelCheck.swift` appeared while I was reading; `AgentKeyView`, `StateColors`
  and `PixelCheck` all changed between my first and last measurement, in one case
  shifting a reported ratio from 1.49 to 1.61. Re-run the numbers in section 2
  before acting on any single one of them; the pattern is what I would rely on,
  not the third digit.

### Evidence run

```
swift build                                        → Build complete
VCM_SELFTEST=1                                     → selfcheck: ok (7 states), exit 0
VCM_SELFTEST=1 VCM_PIXELCHECK=1                    → 10 failures (4 glyph, 6 separation)
Scripts/check-render.sh                            → light: DIFFERS, dark: DIFFERS
VCM_RENDER=/tmp/rev042                             → 324x318 light + dark, current source
```

Pixel measurements were taken with two throwaway samplers over the PNGs: mean
colour across annuli at r = 0–0.16, 0.22–0.32 and 0.34–0.44 of each cap side; peak
chroma with its luminance over each cap and over the corresponding regions of the
four reference images; min-versus-max luminance across each cap's numeral corner;
and alpha profiles outward from all four case edges. Ratios use the WCAG 2.1
relative-luminance formula, the same one `StateColors` implements, so they are
directly comparable to the numbers its own check produces. The blur question was
settled with a separate minimal probe comparing `cacheDisplay(in:to:)` against
`ImageRenderer` on one identical blurred shape.

Reference-image caveat: `openai_codex_micro_c68b01d3cf-*.jpg` is a photograph;
the other three are product renders, so their LED luminances are idealised and my
chroma figures carry JPEG and white-balance error. The direction and magnitude of
the luminance gap in finding 1 survive that error comfortably — it is a factor of
two to two and a half, not a few percent — but the specific decimals should not be
treated as targets.
