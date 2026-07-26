# Virtual Codex Micro PRD

## Overview

Virtual Codex Micro is a native macOS floating app that recreates the spatial layout, key grouping, and agent-state color semantics of OpenAI and Work Louder’s Codex Micro as an on-screen control surface for AI coding agents.[cite:21][cite:27] The product is intended to give developers the same fast-glance awareness and quick-action workflow benefits of the hardware device while replacing physical keys with clickable, keyboard-accessible software controls.[cite:21][cite:25]

The core product bet is that the most valuable part of Codex Micro is not the physical hardware itself, but the interaction model: six status-aware agent keys, a dedicated command cluster, a reasoning dial, and preset workflows exposed through a joystick-like control scheme.[cite:21][cite:25] A native floating macOS panel is a practical foundation for this concept because `NSPanel` is a standard approach for always-on-top utility windows and Spotlight-like overlays in SwiftUI/AppKit applications.[cite:1][cite:5][cite:6]

## Problem

Developers using terminal-based or desktop AI coding agents often lose flow because they must repeatedly switch among terminal sessions, approval prompts, logs, chats, and editor windows to understand what agents are doing and to respond at the right moment.[cite:21][cite:27] Codex Micro demonstrates demand for a compact control layer that keeps agent monitoring and high-frequency actions within reach, but the hardware is sold as a premium physical device with limited availability and a price around $230.[cite:16][cite:17][cite:27]

A software version can remove purchasing and supply friction, support multiple agent backends, and evolve faster than hardware while still preserving the mental model that makes the device compelling.[cite:16][cite:25] The product should therefore aim to mimic the exact key positions and the color idea for agent state as closely as practical, while using software-native affordances for configuration, accessibility, and contextual feedback.[cite:21][cite:27]

## Vision

The vision is to build the best native macOS virtual macro pad for AI coding agents: visually faithful to Codex Micro, useful as a daily control surface, and extensible enough to support both Codex-oriented and Claude Code-oriented workflows.[cite:21][cite:25] The first release should focus on being a floating companion that stays visible during active work, makes state changes legible at a glance, and lets users trigger a small set of high-value actions without leaving their current context.[cite:1][cite:6][cite:21]

## Goals

- Recreate the key layout and grouping of Codex Micro in a native macOS UI.[cite:21][cite:25]
- Mirror the hardware’s agent-state color model for the six frosted agent keys.[cite:21][cite:27]
- Support fast actions such as accept, reject, new session, push-to-talk, and custom workflows aligned with the hardware concept.[cite:21][cite:23]
- Provide a dial-like reasoning or effort control where the connected backend supports this concept.[cite:21]
- Operate as a floating, always-available panel that feels like a premium macOS utility rather than a generic dashboard.[cite:1][cite:5][cite:6]

## Non-goals

- Replacing the full terminal, IDE, or chat interface for AI agents in v1.
- Achieving exact physical tactility or hardware-grade input feel.
- Shipping a cross-platform Windows or Linux version in the first release.
- Copying product branding or representing the app as an official OpenAI or Work Louder product.

## Target users

### Primary users

- Software engineers who use coding agents daily and want less context switching.
- macOS developers who prefer keyboard-first, utility-style tools.
- Early adopters who value a dedicated control layer for agent workflows.

### Secondary users

- Technical power users experimenting with multiple AI coding tools.
- Stream Deck and macropad users who want a software-only version of a similar workflow.

## User needs

Users need to see whether a given agent is idle, running, waiting for input, complete, or failed without constantly foregrounding the tool that owns that session.[cite:21][cite:27] They also need a fast way to act on the most common decisions, especially opening or selecting a session, approving or rejecting changes, launching a new session, or triggering a repeatable workflow.[cite:21][cite:23]

The product should preserve the sense that each key has a purpose and a stable position. That predictability matters more than decorative realism because the app’s value comes from building muscle memory around fixed locations, color feedback, and high-frequency operations.[cite:21][cite:25]

## Product principles

1. **Spatial fidelity first.** The virtual control surface should preserve relative key positions and groupings from Codex Micro wherever possible.[cite:21][cite:25]
2. **State at a glance.** Agent status should be visible within peripheral vision through strong, consistent color semantics.[cite:21][cite:27]
3. **Native over web-like.** The app should feel like a polished macOS utility using SwiftUI and AppKit patterns, not a browser dashboard.[cite:1][cite:5][cite:6]
4. **Configurable but opinionated.** Defaults should reflect the hardware mental model, while advanced users can remap actions later.
5. **Backend-agnostic core.** The control surface should support multiple agent providers through adapters rather than hard-coding one backend.

## Reference interaction model

Available descriptions identify Codex Micro as a 13-key macro pad with six frosted agent keys, a rotary encoder or dial, a joystick, and additional command-oriented inputs.[cite:25][cite:27] The getting-started material and coverage describe agent keys that both display live thread state and provide direct access to the associated thread, along with command keys for actions such as push-to-talk, accepting changes, and sending commands.[cite:21][cite:23]

This PRD treats that interaction model as the north star for v1. The software does not need to replicate every mechanical or industrial-design detail, but it should preserve the perceived layout, the functional zones, and the status-color system closely enough that someone familiar with Codex Micro recognizes the structure immediately.[cite:21][cite:25]

## Functional scope

### V1 features

| Feature | Description | Priority |
|---|---|---|
| Floating panel | Always-on-top virtual macro pad window based on `NSPanel` behavior.[cite:1][cite:5][cite:6] | P0 |
| Spatial key layout | Key positions arranged to mimic Codex Micro’s control map as closely as practical.[cite:21][cite:25] | P0 |
| Six agent keys | Six dedicated status keys with frosted-glass styling and click behavior.[cite:21][cite:27] | P0 |
| Agent state colors | Off, idle, running, complete, needs input, and error states mapped to distinct colors.[cite:21][cite:27] | P0 |
| Command key cluster | Fixed-position action keys for core commands such as accept, reject, new session, and custom action slots.[cite:21][cite:23] | P0 |
| Dial control | On-screen effort or reasoning selector represented as a rotary control.[cite:21] | P1 |
| Joystick-inspired control | Four directional preset workflow triggers plus center indicator.[cite:21][cite:25] | P1 |
| Backend adapters | Initial adapters for Claude Code and Codex-style workflows where feasible. | P0 |
| Global shortcut | Open, focus, hide, or pin the panel quickly.[cite:6] | P0 |
| Lightweight activity strip | Recent action and state events for trust and debugging. | P1 |

### Post-v1 features

- Menubar companion mode.
- Per-project key maps and workflow sets.
- Multiple panel sizes: compact, expanded, and mini strip.
- Sound and haptic-adjacent feedback through optional macOS audio cues.
- Sharing/importing workflow profiles.
- Plugin SDK for additional agent backends.

## State model

The six agent keys should represent these states:

| State | Meaning | Visual treatment |
|---|---|---|
| Unassigned | No agent or session bound to the key.[cite:21] | Dark or unlit key, minimal glow |
| Idle | Agent exists but is not actively processing.[cite:21][cite:27] | White glow |
| Running | Agent is thinking, processing, or actively executing.[cite:21][cite:27] | Blue glow |
| Complete | Agent finished successfully and is ready for review or follow-up.[cite:21][cite:27] | Green glow |
| Needs input | Agent is blocked and waiting for approval, clarification, or next action.[cite:21][cite:25] | Amber or peach glow |
| Error | Agent encountered a failure state.[cite:21][cite:27] | Red glow |

The meanings above should remain stable across all backends. If an underlying provider exposes more granular states, those may be normalized into this visual model so the user does not need to learn different status semantics per tool.

## Layout specification

The app should preserve the exact relative placement philosophy of Codex Micro, even if the software version uses rounded rectangles and translucent materials rather than literal keycaps.[cite:21][cite:25] The layout should be divided into four zones.

### Zone 1: Agent keys

A six-key cluster occupies the most visually prominent area of the panel. These keys should be rendered with a frosted, illuminated appearance because they carry the most important “at a glance” signal in the hardware concept.[cite:21][cite:27]

### Zone 2: Command keys

A secondary cluster contains fixed-purpose action keys. These are less luminous than agent keys and may use iconography plus short labels for clarity, but their positions should stay stable to preserve muscle memory.[cite:21][cite:23]

### Zone 3: Dial

The lower-right or right-side region contains a circular reasoning dial with visible steps or discrete notches. It should feel like an on-screen translation of a rotary encoder rather than a generic slider.[cite:21]

### Zone 4: Joystick

The lower-left or central lower region contains a four-direction launcher resembling a planar joystick. Each direction maps to a preset workflow such as review PR, debug issue, explain code, or write docs.[cite:25]

## User stories

- As a developer, a user wants to see which agents are active without checking each terminal or chat window individually.
- As a developer, a user wants each active session to remain tied to a stable visual slot so that the same key continues to represent the same thread until reassigned.
- As a developer, a user wants to click a status key to jump to or focus the corresponding agent session quickly.[cite:21]
- As a developer, a user wants to trigger the most common actions from fixed keys rather than remembering commands.
- As a developer, a user wants color states to remain consistent across tools so that “blue means running” and “red means error” everywhere.[cite:21][cite:27]
- As a developer, a user wants the floating panel to stay available but unobtrusive while coding.

## Key interactions

### Agent key interactions

- Single click: select or foreground the mapped session.[cite:21]
- Long press or secondary click: rebind, inspect details, or clear assignment.
- Hover: show session name, backend, repo, branch, and latest state transition.

### Command key interactions

- Accept: approve a pending change, action, or confirmation where backend supports it.
- Reject: decline or cancel the pending action.
- New session: create or initialize a new agent conversation.
- Push-to-talk: invoke voice or prompt capture if supported.
- Custom 1 and Custom 2: user-defined actions.

### Dial interactions

- Rotate gesture or horizontal drag: adjust effort level.
- Click center: reset to default effort.
- Tooltip: show semantic label such as low, medium, high, or 1–5.

### Joystick interactions

- Up, right, down, left: launch workflow presets.
- Center tap: open preset editor or workflow chooser.

## Information architecture

The product should expose two layers of information. The panel itself shows the minimal control surface, while deeper session details live in contextual popovers, sheets, or optional drill-down views. This keeps the main experience faithful to a macro pad while still allowing software-only richness.

The compact panel should show only the essentials: key labels, live colors, current backend, and a subtle activity indicator. Detailed logs, configuration, and mapping tools should appear in secondary UI surfaces so the primary panel remains visually disciplined.

## Visual design requirements

The app should use a native macOS aesthetic with translucent materials and careful lighting, but avoid becoming visually noisy. Agent keys should be the brightest interactive elements because they carry the product’s core value proposition.[cite:21][cite:27]

Visual requirements:
- The frame should resemble a device silhouette rather than a standard window chrome.
- Agent keys should use frosted or milk-glass materials with inner glow tied to agent state.
- Command keys should have lower-intensity fills and subtle hover states.
- The panel should support light and dark mode, with status colors tuned for readability in both.
- Motion should emphasize state transitions, glows, and selection changes without distracting from work.

## Accessibility requirements

- Every key must be keyboard accessible and reachable via tab order or custom shortcut navigation.
- State colors must be paired with text, icon, pulse, or tooltip reinforcement so status is not color-only.
- High-contrast mode should reduce translucency and increase edge definition.
- Reduced motion mode should disable pulsing or animated glow transitions.
- Tooltips and labels should remain legible at compact sizes.

## Technical architecture

### Platform stack

The product should be built as a native macOS application using SwiftUI for most interface rendering and AppKit for window management and lower-level panel behavior.[cite:1][cite:5][cite:6] `NSPanel` is the likely primitive for the floating surface because it is designed for utility and overlay behaviors such as floating above normal windows and remaining quickly accessible.[cite:5][cite:6]

### Core modules

- **Panel shell:** floating window lifecycle, pinning, focus rules, visibility behavior.
- **Key surface renderer:** visual layout, hit testing, glow states, and motion.
- **State engine:** normalized agent state model and assignment logic.
- **Backend adapters:** one adapter per connected tool, translating commands and events.
- **Workflow mapper:** user-configured actions, presets, and per-key bindings.
- **Telemetry and logs:** local event history, debugging traces, and optional analytics.

### Backend integration model

The system should isolate backend-specific behavior behind adapters. Each adapter should expose a common interface for listing sessions, binding a session to a key, reporting normalized status, dispatching commands, and surfacing capabilities such as effort control or push-to-talk.

This design allows the UI to stay stable even if Codex-oriented and Claude Code-oriented tools differ in terminology or event formats. The visual layer should only consume normalized statuses and capabilities, not raw provider-specific details.

## Assumptions

- Users are already running or have access to one or more supported AI coding tools.
- At least one supported backend exposes a practical way to launch commands and infer state changes.
- A floating panel is acceptable in daily workflows if users can quickly hide, pin, or summon it.[cite:1][cite:6]
- The value of stable key placement outweighs the limitations of a compact fixed layout.

## Risks

The largest product risk is backend integration quality. A polished panel is not enough unless the app can reliably infer meaningful states and trigger actions without confusing drift between the UI and the real agent state.

A second risk is overfitting to visual mimicry at the cost of usability. Exact spatial fidelity is desirable, but the virtual version still needs readable labels, accessible hit targets, and software-native configuration affordances.

A third risk is legal or brand confusion if the app looks too official. The product should be inspired by Codex Micro’s structure, not presented as an official replica.

## Success metrics

### Activation metrics

- Percentage of users who bind at least one agent key in their first session.
- Percentage of users who complete the first workflow launch within ten minutes.

### Engagement metrics

- Average number of key-triggered actions per active day.
- Average number of session switches performed through the panel rather than manually.
- Share of active users who keep the panel visible or pinned during work sessions.

### Outcome metrics

- Self-reported reduction in context switching.
- Retention among users who bind three or more keys.
- Number of users who create custom joystick workflows or command remaps.

## Release plan

### Phase 1: Visual prototype

Build a non-functional but high-fidelity native panel that proves the spatial layout, materials, key glow treatments, and state transitions. This phase validates whether the interface truly feels like a convincing software translation of Codex Micro.[cite:21][cite:27]

### Phase 2: Single-backend MVP

Integrate one backend deeply enough to support session binding, status changes, and a minimal set of actions. The MVP should prioritize reliability of the six agent keys and the command cluster over broader platform ambitions.

### Phase 3: Multi-backend support

Add the second backend through the adapter layer and normalize any mismatched semantics. At this stage, configuration surfaces, remapping, and workflow presets can become first-class.

## Open questions

- Which backend should be the first-class integration target in v1?
- How exact should the replica be in proportions and spacing versus using a “close but optimized” interpretation for on-screen ergonomics?
- Should the panel support click-through transparency modes when idle?
- Should the joystick presets be globally defined or per-project?
- How should the app indicate multiple waiting agents when only six slots are visible?

## Recommended MVP

The recommended MVP is a compact floating panel with six status keys, four to six command keys, one dial control, one joystick-style preset launcher, and one backend adapter capable of real session binding and state normalization.[cite:1][cite:6][cite:21] This scope is small enough to ship as a serious prototype while still proving the central thesis that Codex Micro’s interaction model can work as premium native macOS software.[cite:21][cite:25]
