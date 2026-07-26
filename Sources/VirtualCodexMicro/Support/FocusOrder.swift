import Foundation

/// Keyboard traversal across all four zones.
///
/// Each component already owns its own internal focus: `AgentKeyView` has a
/// `@FocusState Bool`, `CommandKeyCluster` a `@FocusState CommandSlot?`,
/// `DirectionPadView` a `@FocusState PadDirection?`, `DialView` a
/// `@FocusState Bool`. Four private focus scopes, and nothing above them decides
/// what comes after the last command key or what Shift-Tab does from the top of
/// the pad. This file is that missing owner, as a pure value so the traversal can
/// be checked with no window server, no render pass and no screen reader.
///
/// ## The order
///
///     agent 0…5  →  command accept…custom2  →  dial  →  pad up,right,down,left,centre
///
/// 18 stops. It is *not* strict visual reading order, and it is not the order
/// `PanelLayout.hitTargets` publishes — both of those are recorded and justified
/// in `spikes/a11y/AUDIT.md`. The rule it follows is task adjacency:
///
/// 1. **Agent keys first.** Six of them are the product. Someone tabbing into
///    the panel is looking for a session, and the cluster sits top-left anyway,
///    so intent and geometry agree here.
/// 2. **Command keys second.** They act on the session the agent keys select.
///    Select-then-act is the panel's most common two-step, and putting any other
///    zone between the two halves means tabbing through controls that have
///    nothing to do with what the user is mid-way through doing.
/// 3. **Dial third.** Effort also acts on the bound session, so it belongs with
///    the command cluster, not with the pad. One stop rather than a cluster, and
///    it changes value with arrow keys once focused, so it is cheap to pass
///    through in either direction.
/// 4. **Pad last.** The pad launches workflows; it is the one zone that does not
///    read the bound session at all. Last keeps the select-then-act path
///    uninterrupted, and it gives Shift-Tab a single-stop landmark (the dial)
///    between the panel's two multi-stop clusters.
///
/// Within each zone the order is the component's own published order, so this
/// file never contradicts a component: agent keys row-major by index,
/// `CommandSlot.allCases` (row-major, and `PanelLayout` documents that ordering
/// as load-bearing for muscle memory), `PadDirection.allCases` (clockwise from
/// the top, chooser last — the order `DirectionPadView` documents).
///
/// ## Skipping
///
/// A 19-target panel makes tabbing into a dead end a real failure. Each
/// component avoided it locally — a disabled `Button` leaves SwiftUI's focus
/// chain, `focusable(live)` keeps an unbound pad cell out of it — but nobody
/// guaranteed it across zones, and the guarantee has to be global: it is the
/// *sequence* that strands focus, not any one control.
///
/// So `next(after:)` and `previous(before:)` return only focusable stops, and the
/// focusability rule is not restated here — it is delegated to the component that
/// owns it (`CommandKeyView.isEnabled`, `DirectionPadView.isActionable`), so the
/// two cannot drift. Traversal wraps and is bounded by `all.count` iterations, so
/// it terminates even when nothing at all is focusable, in which case it reports
/// `nil` rather than spinning.
///
/// ## What is deliberately not a stop
///
/// `PanelLayout.hitTargets` publishes 19 targets; this order has 18. The
/// difference is `dial reset`, the concentric centre target, which `PanelLayout`
/// itself marks `nested: true`. `DialView` exposes it as a VoiceOver action
/// (`Reset to medium`) and as the Home key, not as a separate element — the
/// keyboard reaches it without a stop of its own. `selfCheckFailures()` enforces
/// exactly that shape: every non-nested hit target must be a stop, and any hit
/// target that is not a stop must be nested. A control added to `PanelLayout`
/// therefore cannot become silently unreachable.
public struct FocusOrder: Sendable, Equatable {

    // MARK: - Stops

    /// One keyboard stop. Names match `PanelLayout.HitTarget.name` exactly, which
    /// is what makes the cross-check against `hitTargets` mechanical rather than
    /// a list someone has to remember to update.
    public enum Target: Hashable, Sendable {
        case agent(Int)
        case command(PanelLayout.CommandSlot)
        case overflow

        public var hitTargetName: String {
            switch self {
            case .agent(let index): "agent \(index)"
            case .command(let slot): "command \(slot.rawValue)"
            case .overflow: "overflow"
            }
        }

        public var zone: PanelLayout.Zone {
            switch self {
            case .agent: .agents
            case .command: .commands
            case .overflow: .status
            }
        }
    }

    /// The canonical order. Built from `allCases` and `agentKeyCount` rather than
    /// listed, so a seventh command slot or a fifth pad direction joins the
    /// traversal without an edit here.
    public static let all: [Target] =
        (0 ..< PanelLayout.agentKeyCount).map { Target.agent($0) }
            + PanelLayout.CommandSlot.allCases.map { Target.command($0) }
            + [.overflow]

    // MARK: - What is currently reachable

    /// Capabilities of the session the command cluster targets; `nil` when
    /// nothing is bound.
    public var capabilities: SessionCapabilities?
    /// Whether any connected backend can spawn a session. Gates `newSession`,
    /// which is the one slot that does not read the bound session.
    public var canSpawnSessions: Bool
    /// Directions with a workflow bound. The centre is always live, so it is not
    /// listed here.
    public var boundPadDirections: Set<PanelLayout.PadDirection>
    /// Whether the dial can change anything. `DialView` does not gate itself
    /// today — see the audit — so this defaults to the current behaviour and is
    /// the single place to tighten when the dial is capability-gated in M2.
    public var dialAcceptsInput: Bool
    /// Whether the overflow chip has anything to show. An empty chip renders
    /// nothing, so it must not be a keyboard stop.
    public var hasUnboundSessions: Bool

    public init(
        capabilities: SessionCapabilities?,
        canSpawnSessions: Bool = true,
        boundPadDirections: Set<PanelLayout.PadDirection> = [],
        dialAcceptsInput: Bool = true,
        hasUnboundSessions: Bool = false
    ) {
        self.capabilities = capabilities
        self.canSpawnSessions = canSpawnSessions
        self.boundPadDirections = boundPadDirections
        self.dialAcceptsInput = dialAcceptsInput
        self.hasUnboundSessions = hasUnboundSessions
    }

    /// An agent key is always a stop, including an empty one: clicking or
    /// activating an unassigned slot is how a session gets bound to it, so
    /// dropping it from the chain would make binding pointer-only.
    @MainActor
    public func isFocusable(_ target: Target) -> Bool {
        switch target {
        case .agent:
            true
        case .command(let slot):
            CommandKeyView.isEnabled(slot, capabilities: capabilities, canSpawnSessions: canSpawnSessions)
        case .overflow:
            // Reachable only when there is something to overflow. An empty chip
            // renders nothing, so focusing it would be a dead stop.
            hasUnboundSessions
        }
    }

    /// A preset dictionary shaped for `DirectionPadView.isActionable`. The
    /// closures are never run — only key presence is read.
    @MainActor
    private var padPresets: [PanelLayout.PadDirection: WorkflowPreset] {
        var presets: [PanelLayout.PadDirection: WorkflowPreset] = [:]
        for direction in boundPadDirections where direction != .center {
            presets[direction] = WorkflowPreset(name: direction.rawValue) {}
        }
        return presets
    }

    @MainActor
    public var focusable: [Target] { Self.all.filter(isFocusable) }

    // MARK: - Navigation

    /// The next reachable stop. `nil` for `target` means "tab into the panel", so
    /// this returns the first focusable stop.
    ///
    /// Passing a stop that is *not* currently focusable is legal and deliberate:
    /// a command key can be disabled by a capability change while it holds focus,
    /// and traversal must continue from where focus actually is rather than
    /// refusing to move. That is the case that strands focus if it is not handled.
    @MainActor
    public func next(after target: Target? = nil) -> Target? {
        Self.step(from: target, by: 1, in: Self.all, focusable: isFocusable)
    }

    @MainActor
    public func previous(before target: Target? = nil) -> Target? {
        Self.step(from: target, by: -1, in: Self.all, focusable: isFocusable)
    }

    /// The traversal itself, with the order and the focusability rule injected.
    ///
    /// Exposed rather than kept private for one reason: the "never loops forever"
    /// guarantee is only provable by driving it with a predicate that refuses
    /// everything, and no real `FocusOrder` can produce that (agent keys are
    /// always focusable). `selfCheckFailures()` drives it directly for that case.
    ///
    /// Bounded at `order.count` probes, so it either lands on a focusable stop or
    /// reports `nil`. Wrapping is what keeps a panel-local Tab from falling out
    /// of the last zone into nothing.
    public static func step(
        from target: Target?,
        by direction: Int,
        in order: [Target],
        focusable: (Target) -> Bool
    ) -> Target? {
        guard !order.isEmpty, direction != 0 else { return nil }
        // Off the end by one in the direction of travel, so the first probe lands
        // on the first (or last) element.
        let start = target.flatMap { order.firstIndex(of: $0) }
            ?? (direction > 0 ? -1 : order.count)
        for offset in 1 ... order.count {
            let raw = start + direction * offset
            let index = ((raw % order.count) + order.count) % order.count
            if focusable(order[index]) { return order[index] }
        }
        return nil
    }

    // MARK: - Self check

    /// Empty when healthy. One line wires it in — see the audit; `SelfCheck.swift`
    /// is not edited here.
    @MainActor
    public static func selfCheckFailures() -> [String] {
        var failures: [String] = []

        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        let order = all

        // 1. No duplicates. A repeated stop makes Tab visit one control twice and
        //    silently shortens the reachable set.
        if Set(order).count != order.count {
            var seen = Set<Target>()
            for target in order where !seen.insert(target).inserted {
                failures.append("duplicate stop \(target.hitTargetName)")
            }
        }

        // 2. Every interactive target PanelLayout publishes is reachable, and
        //    anything not in the order is there by declared design (nested).
        //    Checked at both size classes because `hitTargets` is per-layout.
        let names = Set(order.map(\.hitTargetName))
        for sizeClass in PanelLayout.SizeClass.allCases {
            let layout = PanelLayout(sizeClass: sizeClass)
            let tag = sizeClass.rawValue
            var published = Set<String>()

            for target in layout.hitTargets {
                published.insert(target.name)
                if target.nested {
                    // A nested target is reached through its parent, so it must
                    // NOT also be a stop, or Tab visits the same control twice.
                    if names.contains(target.name) {
                        failures.append("\(tag): nested target \(target.name) is also a keyboard stop")
                    }
                } else if !names.contains(target.name) {
                    failures.append(
                        "\(tag): \(target.name) is pointer-hittable but has no keyboard stop"
                    )
                }
            }

            for name in names where !published.contains(name) {
                failures.append("\(tag): keyboard stop \(name) is not a published hit target")
            }
        }

        // Zone assignment must agree with the layout's, or the order is grouped
        // by something other than the zones it claims to walk.
        let zoneByName = Dictionary(
            PanelLayout.regular.hitTargets.map { ($0.name, $0.zone) },
            uniquingKeysWith: { first, _ in first }
        )
        for target in order where zoneByName[target.hitTargetName] != target.zone {
            failures.append(
                "\(target.hitTargetName) claims zone \(target.zone.rawValue), layout says "
                    + (zoneByName[target.hitTargetName]?.rawValue ?? "nothing")
            )
        }

        // 3. Zones are walked as contiguous runs, in the documented order. A zone
        //    interleaved with another is the version of this order that reads as
        //    random when tabbed through.
        let expectedZones: [PanelLayout.Zone] = [.agents, .commands, .status]
        var runs: [PanelLayout.Zone] = []
        for target in order where runs.last != target.zone { runs.append(target.zone) }
        check("zone runs are \(runs.map(\.rawValue)), expected \(expectedZones.map(\.rawValue))",
              runs == expectedZones)

        // Within the agent cluster, index order must be the layout's row-major
        // order, so Tab reads left-to-right and not down the columns.
        let agentIndices = order.compactMap { target -> Int? in
            if case .agent(let index) = target { return index }
            return nil
        }
        check("agent stops are \(agentIndices), expected 0..<\(PanelLayout.agentKeyCount) in order",
              agentIndices == Array(0 ..< PanelLayout.agentKeyCount))

        // 4. Traversal, across configurations that each disable a different mix.
        //    Every entry is a situation the panel really reaches: nothing bound,
        //    an observed session, an owned one, a partial capability set.
        let allPadDirections = Set(DirectionPadView.cardinals)
        let configurations: [(String, FocusOrder)] = [
            ("owned, all presets bound", FocusOrder(
                capabilities: .owned, canSpawnSessions: true,
                boundPadDirections: allPadDirections, dialAcceptsInput: true
            )),
            ("observed, two presets", FocusOrder(
                capabilities: .observed, canSpawnSessions: true,
                boundPadDirections: [.up, .down], dialAcceptsInput: false
            )),
            ("nothing bound, cannot spawn", FocusOrder(
                capabilities: nil, canSpawnSessions: false,
                boundPadDirections: [], dialAcceptsInput: false
            )),
            ("empty capability set", FocusOrder(
                capabilities: SessionCapabilities([]), canSpawnSessions: true,
                boundPadDirections: [.left], dialAcceptsInput: true
            )),
            ("focus and prompt only", FocusOrder(
                capabilities: [.focus, .sendPrompt], canSpawnSessions: false,
                boundPadDirections: allPadDirections, dialAcceptsInput: true
            )),
        ]

        for (label, focusOrder) in configurations {
            let reachable = focusOrder.focusable

            // The panel always has stops: agent keys are unconditional, so a
            // completely untabbable panel is unreachable by construction. Assert
            // it rather than trust it — this is the floor everything else rests on.
            if reachable.count < PanelLayout.agentKeyCount {
                failures.append("\(label): only \(reachable.count) stops, agent keys alone are \(PanelLayout.agentKeyCount)")
            }

            // 4a. Focusability must be the components' own answer, not a copy of
            //     it that has drifted.
            for slot in PanelLayout.CommandSlot.allCases {
                let mine = focusOrder.isFocusable(.command(slot))
                let theirs = CommandKeyView.isEnabled(
                    slot, capabilities: focusOrder.capabilities,
                    canSpawnSessions: focusOrder.canSpawnSessions
                )
                if mine != theirs {
                    failures.append("\(label): command \(slot.rawValue) focusability disagrees with CommandKeyView")
                }
            }
            // The encoder and joystick are gone: their cells are agent keys now, so
            // there is no per-control agreement left to check here.
            if focusOrder.isFocusable(.overflow) != focusOrder.hasUnboundSessions {
                failures.append("\(label): overflow focusability disagrees with whether anything is unbound")
            }

            // 4b. Every stop next/previous hands back is actually focusable, from
            //     every position — including from positions that are themselves
            //     unfocusable, which is how focus gets stranded when a key is
            //     disabled underneath it.
            for target in order {
                guard let forward = focusOrder.next(after: target) else {
                    failures.append("\(label): next() stranded focus at \(target.hitTargetName)")
                    continue
                }
                if !focusOrder.isFocusable(forward) {
                    failures.append("\(label): next() from \(target.hitTargetName) landed on unfocusable \(forward.hitTargetName)")
                }
                guard let backward = focusOrder.previous(before: target) else {
                    failures.append("\(label): previous() stranded focus at \(target.hitTargetName)")
                    continue
                }
                if !focusOrder.isFocusable(backward) {
                    failures.append("\(label): previous() from \(target.hitTargetName) landed on unfocusable \(backward.hitTargetName)")
                }
            }

            // 4c. Tabbing in and Shift-Tabbing in land on the first and last
            //     reachable stops, not on whatever happens to be at index 0.
            check("\(label): tabbing in does not reach the first focusable stop",
                  focusOrder.next(after: nil) == reachable.first)
            check("\(label): shift-tabbing in does not reach the last focusable stop",
                  focusOrder.previous(before: nil) == reachable.last)

            // 4d. True inverses, over the stops a user can actually hold. (From
            //     an unfocusable stop they cannot be inverses: forward and back
            //     leave from the same index and neither can return to a place
            //     focus is not allowed to be.)
            for target in reachable {
                let there = focusOrder.next(after: target)
                let back = there.flatMap { focusOrder.previous(before: $0) }
                if back != target {
                    failures.append(
                        "\(label): previous(next(\(target.hitTargetName))) = "
                            + (back?.hitTargetName ?? "nil")
                    )
                }
                let backFirst = focusOrder.previous(before: target)
                let forwardAgain = backFirst.flatMap { focusOrder.next(after: $0) }
                if forwardAgain != target {
                    failures.append(
                        "\(label): next(previous(\(target.hitTargetName))) = "
                            + (forwardAgain?.hitTargetName ?? "nil")
                    )
                }
            }

            // 4e. Termination: repeated Tab from every reachable stop visits every
            //     reachable stop exactly once and returns to where it started, in
            //     exactly `reachable.count` steps. A cycle shorter than that means
            //     part of the panel is unreachable; one that never closes means
            //     Tab does not terminate.
            for start in reachable {
                var visited: [Target] = []
                var cursor = start
                for _ in 0 ..< reachable.count {
                    guard let step = focusOrder.next(after: cursor) else { break }
                    cursor = step
                    visited.append(step)
                }
                if cursor != start {
                    failures.append("\(label): tabbing from \(start.hitTargetName) does not return in \(reachable.count) steps")
                }
                if Set(visited).count != reachable.count {
                    failures.append(
                        "\(label): tabbing from \(start.hitTargetName) reached \(Set(visited).count) of \(reachable.count) stops"
                    )
                }
            }
        }

        // 5. The pathological case no real configuration produces: nothing
        //    focusable at all. Traversal must report nil, not iterate forever.
        check("an all-unfocusable order must report nil going forward",
              step(from: nil, by: 1, in: order, focusable: { _ in false }) == nil)
        check("an all-unfocusable order must report nil going backward",
              step(from: order.last, by: -1, in: order, focusable: { _ in false }) == nil)
        check("an empty order must report nil",
              step(from: nil, by: 1, in: [], focusable: { _ in true }) == nil)
        check("a zero direction must report nil rather than stall",
              step(from: nil, by: 0, in: order, focusable: { _ in true }) == nil)
        // A stop the order does not contain is treated as "outside", i.e. tab in.
        check("an unknown stop must be treated as tabbing in",
              step(from: .agent(99), by: 1, in: order, focusable: { _ in true }) == order.first)

        return failures
    }
}
