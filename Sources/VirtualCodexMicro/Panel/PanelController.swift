import AppKit
import Foundation
import SwiftUI

/// The floating shell every other M1 component lives inside.
///
/// Wire-in, in `AppDelegate.applicationDidFinishLaunching` (main.swift is owned
/// by the parent agent, so this file does not touch it). Exactly:
///
///     panelController = PanelController(content: SmokeView())
///     panelController?.show()
///
/// with a `private var panelController: PanelController?` stored on the
/// delegate — the controller must outlive the function or the panel is released.
/// `NSApp.setActivationPolicy(.accessory)` stays where it is; this type does not
/// set it, because activation policy is an app-wide decision.
///
/// Everything visual comes from `PanelLayout`: size, and the corner radius of
/// the device silhouette. The window itself is transparent and chromeless, so
/// the SwiftUI content draws the only visible edge.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {

    // MARK: - Persistence keys

    /// Only the origin is meaningful across launches — size is layout-owned, so
    /// a later size-class change must not be overridden by a stale saved size.
    private static let frameKey = "VCM.panel.frame"
    private static let pinnedKey = "VCM.panel.pinned"

    /// A restored frame must keep at least this fraction of itself on some
    /// screen, or it is repositioned. See `clampedFrame`.
    nonisolated static let minimumVisibleFraction: CGFloat = 0.5

    // MARK: - State

    private let panel: NonActivatingPanel
    private let layout: PanelLayout
    private let defaults: UserDefaults

    /// Pinned: always visible. Unpinned: hides as soon as the user's attention
    /// demonstrably moves elsewhere.
    private(set) var isPinned: Bool

    var isVisible: Bool { panel.isVisible }

    /// Exposed for the hotkey task (008) and for anything that needs to parent a
    /// sheet or popover. Callers must not call `makeKeyAndOrderFront` on it —
    /// see the focus discussion in `show()`.
    var window: NSWindow { panel }

    init<Content: View>(
        content: Content,
        layout: PanelLayout = .compact,
        defaults: UserDefaults = .standard
    ) {
        self.layout = layout
        self.defaults = defaults
        self.isPinned = defaults.bool(forKey: Self.pinnedKey)

        // Borderless: the PRD wants a device silhouette, so there is no titlebar
        // to suppress — `.titled` is simply absent. `.nonactivatingPanel` is the
        // load-bearing flag: it lets the panel take keyboard focus without
        // activating this app, which is what makes non-interruption possible.
        panel = NonActivatingPanel(
            contentRect: CGRect(origin: .zero, size: layout.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init()

        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // NSPanel defaults `hidesOnDeactivate` to true. Left alone it would hide
        // the panel every time another app becomes active, which silently breaks
        // pinned mode and makes the unpinned rule untestable.
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        // We persist the frame ourselves; AppKit window restoration would fight
        // the clamping below and restore an unchecked frame first.
        panel.isRestorable = false
        // A hotkey-summoned pad should appear at once. The default fade reads as
        // lag on something meant to feel like hardware.
        panel.animationBehavior = .none
        panel.delegate = self

        let hosting = NSHostingView(rootView: content)
        hosting.frame = layout.panelBounds
        // Clip to the silhouette radius at the layer, so the window shadow
        // follows the rounded shape and no square corner leaks through before
        // the content view draws its own background.
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = layout.cornerRadius
        hosting.layer?.masksToBounds = true
        panel.contentView = hosting

        panel.setFrame(restoredFrame(), display: false)

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeApplicationChanged),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        // Monitor plugged, unplugged, resolution or arrangement changed. Without
        // this, a panel that was legal at launch can end up on a screen that no
        // longer exists while the app is running.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Visibility

    /// Shows without stealing focus.
    ///
    /// The focus tension, resolved: `canBecomeKey` returns true, but nothing
    /// here ever *makes* the panel key. `orderFrontRegardless()` raises a window
    /// without activating the app and without changing key status, so a user
    /// mid-sentence in their editor keeps every keystroke. Key status arrives
    /// only through AppKit's own path — a mouse-down inside the panel, which
    /// makes a `canBecomeKey` window key. Because the style mask includes
    /// `.nonactivatingPanel`, that click routes keyboard events to the panel
    /// *without* activating this app, so the editor stays frontmost and the
    /// keyboard-reachability requirement (every key tab-navigable) is satisfied
    /// from the first click.
    ///
    /// The rejected alternatives, for the record: leaving `canBecomeKey` at its
    /// borderless default of `false` kills keyboard access entirely, and
    /// `becomesKeyOnlyIfNeeded` defers to each view's `needsPanelToBecomeKey`,
    /// which `NSHostingView` does not meaningfully implement — SwiftUI focus
    /// would work or not depending on what happened to be under the cursor.
    func show() {
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    /// Let clicks fall through to whatever is behind the panel.
    ///
    /// Deliberately shipped last and off by default. A floating always-on-top
    /// window that silently stops accepting clicks is indistinguishable from a
    /// frozen app, so this only ever engages on explicit opt-in — and the summon
    /// hotkey always clears it, which is the escape hatch that makes it safe to
    /// offer at all. Never engage it while a key is asking for attention: a user
    /// reaching for an amber key and hitting their editor instead is the worst
    /// version of this feature.
    func setClickThrough(_ enabled: Bool) {
        panel.ignoresMouseEvents = enabled
    }

    var isClickThrough: Bool { panel.ignoresMouseEvents }

    func setPinned(_ pinned: Bool) {
        isPinned = pinned
        defaults.set(pinned, forKey: Self.pinnedKey)
        // Unpinning does not hide: the user just reached for the panel, so the
        // click that unpinned it is not focus loss.
    }

    func togglePinned() {
        setPinned(!isPinned)
    }

    /// Explicit opt-in for the caller that genuinely wants the keyboard, e.g. a
    /// hotkey summon whose contract is "show it and let me tab through it".
    /// Separate from `show()` so focus stealing can never happen by accident.
    func showAndTakeKeyboardFocus() {
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    private func hideIfUnpinned() {
        guard !isPinned, isVisible else { return }
        hide()
    }

    // MARK: - Focus loss

    /// Deliberately does NOT hide the panel, despite that being the obvious
    /// reading of "unpinned means hide on focus loss".
    ///
    /// Found by clicking the thing: this app is `.accessory` and the panel is
    /// `.nonactivatingPanel`, so a click gives the panel key status **without
    /// activating the app**. The frontmost application's own window reclaims key
    /// almost immediately, this fires, and the panel hides itself. The result was
    /// that clicking the panel dismissed it — the single worst possible response
    /// to a click, and invisible to every check we have because it needs a real
    /// pointer.
    ///
    /// The case this path was written for — clicking a window that was already
    /// frontmost, which raises no activation notification — is now not covered, so
    /// the panel stays up in that situation. That is a far smaller cost than a
    /// control surface that vanishes when touched.
    func windowDidResignKey(_ notification: Notification) {}

    /// Fires when the user switches to a different app, which the panel losing
    /// key status does not cover: an unpinned panel that was never clicked never
    /// had key status to resign.
    /// True while the pointer is over the panel. A second guard on hiding: even a
    /// correct activation event should not yank the surface out from under a
    /// pointer that is on it.
    private var pointerIsInside: Bool {
        panel.frame.contains(NSEvent.mouseLocation)
    }

    @objc private func activeApplicationChanged(_ notification: Notification) {
        let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        guard activated?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        guard !pointerIsInside else { return }
        hideIfUnpinned()
    }

    // MARK: - Position persistence

    func windowDidMove(_ notification: Notification) {
        saveFrame()
    }

    private func saveFrame() {
        defaults.set(NSStringFromRect(panel.frame), forKey: Self.frameKey)
    }

    @objc private func screenParametersChanged(_ notification: Notification) {
        let corrected = Self.clampedFrame(panel.frame, visibleScreens: Self.visibleScreenFrames())
        guard corrected != panel.frame else { return }
        panel.setFrame(corrected, display: true)
    }

    private func restoredFrame() -> CGRect {
        let screens = Self.visibleScreenFrames()
        guard let origin = savedOrigin() else { return Self.defaultFrame(size: layout.panelSize, screens: screens) }
        return Self.clampedFrame(CGRect(origin: origin, size: layout.panelSize), visibleScreens: screens)
    }

    /// Decoding is a trust boundary: `NSRectFromString` returns `.zero` for
    /// anything it cannot parse, and a defaults file can be hand-edited or
    /// carried over from a broken build. Non-finite or absent means "no saved
    /// position", which is a different answer from "clamp this".
    private func savedOrigin() -> CGPoint? {
        guard let stored = defaults.string(forKey: Self.frameKey) else { return nil }
        let rect = NSRectFromString(stored)
        guard rect.origin.x.isFinite, rect.origin.y.isFinite else { return nil }
        return rect.origin
    }

    /// Lower-right of the primary screen: a macro pad belongs at the edge of the
    /// desk, and centring an always-on-top window covers what the user is
    /// reading.
    nonisolated static func defaultFrame(size: CGSize, screens: [CGRect]) -> CGRect {
        guard let primary = screens.first else { return CGRect(origin: .zero, size: size) }
        let margin: CGFloat = 24
        return CGRect(
            x: primary.maxX - size.width - margin,
            y: primary.minY + margin,
            width: size.width,
            height: size.height
        )
    }

    /// `NSScreen.frame` includes the menu bar; `visibleFrame` does not. Position
    /// is clamped against `visibleFrame` so a restored panel cannot sit under
    /// the menu bar or the Dock, where it is present but not reachable.
    static func visibleScreenFrames() -> [CGRect] {
        NSScreen.screens.map(\.visibleFrame)
    }

    // MARK: - Clamping

    /// Corrects a saved frame against the screens that actually exist now.
    ///
    /// Pure and `nonisolated` on purpose: display reconfiguration is the case
    /// that cannot be exercised by hand — you would have to unplug a monitor
    /// between launches — so it is the case that most needs a check that runs
    /// with no display attached at all. `selfCheckFailures()` drives it with
    /// synthetic arrangements.
    ///
    /// Coordinate space is irrelevant to the maths (it is rect arithmetic), but
    /// callers should pass AppKit's global, bottom-left-origin `visibleFrame`
    /// rects so the result can go straight into `setFrame`.
    ///
    /// The rule, in order:
    /// 1. No screens at all — return the frame untouched. There is no correct
    ///    answer, and inventing one would overwrite a good position with a
    ///    guess the next time the display list is momentarily empty.
    /// 2. Enough of the frame is visible across all screens — return it
    ///    **unchanged**, byte for byte. This is the case that matters most: a
    ///    frame straddling two screens, or flush against a screen edge, is
    ///    legitimate, and a clamp that tidies it is a bug that moves the user's
    ///    window every launch.
    /// 3. Otherwise anchor to the screen the frame overlaps most, or the primary
    ///    screen if it overlaps none — fully offscreen, or saved on a monitor
    ///    that has since been unplugged — shrink to fit that screen if it is
    ///    larger than it, and slide it fully inside.
    nonisolated static func clampedFrame(_ frame: CGRect, visibleScreens screens: [CGRect]) -> CGRect {
        guard let primary = screens.first else { return frame }

        func overlapArea(_ screen: CGRect) -> CGFloat {
            let overlap = screen.intersection(frame)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }

        let area = frame.width * frame.height
        if area > 0 {
            // Summed rather than unioned: mirrored displays report identical
            // frames and double-count, which only makes this more permissive,
            // and a mirrored frame is visible by definition.
            let visible = screens.reduce(CGFloat.zero) { $0 + overlapArea($1) }
            if visible / area >= minimumVisibleFraction { return frame }
        }

        let anchor = screens.filter { $0.intersects(frame) }
            .max { overlapArea($0) < overlapArea($1) } ?? primary

        var corrected = frame
        corrected.size.width = min(frame.width, anchor.width)
        corrected.size.height = min(frame.height, anchor.height)
        // Width and height now fit the anchor, so the upper bound is never below
        // the lower one.
        corrected.origin.x = min(max(corrected.minX, anchor.minX), anchor.maxX - corrected.width)
        corrected.origin.y = min(max(corrected.minY, anchor.minY), anchor.maxY - corrected.height)
        return corrected
    }

    // MARK: - Self check

    /// Empty means healthy. Wired into `SelfCheck` by the parent.
    nonisolated static func selfCheckFailures() -> [String] {
        var failures: [String] = []

        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        // Second display to the right, taller, as a real arrangement would be.
        let right = CGRect(x: 1440, y: -100, width: 1920, height: 1080)
        let panelSize = CGSize(width: 400, height: 300)

        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        func isInside(_ frame: CGRect, _ screens: [CGRect]) -> Bool {
            screens.contains { $0.contains(frame) }
        }

        // 1. The normal case. A valid frame must come back identical — a clamp
        // that "corrects" good input drifts the panel a little every launch.
        let valid = CGRect(origin: CGPoint(x: 200, y: 200), size: panelSize)
        check("valid frame altered", clampedFrame(valid, visibleScreens: [screen]) == valid)

        // Flush against the screen edges, still valid, still untouched.
        let flush = CGRect(
            x: screen.maxX - panelSize.width,
            y: screen.minY,
            width: panelSize.width,
            height: panelSize.height
        )
        check("edge-flush frame altered", clampedFrame(flush, visibleScreens: [screen]) == flush)

        // 2. Fully offscreen: saved at a coordinate no screen covers.
        let offscreen = CGRect(origin: CGPoint(x: 5000, y: 4000), size: panelSize)
        let offscreenFixed = clampedFrame(offscreen, visibleScreens: [screen])
        check("offscreen frame not pulled back", isInside(offscreenFixed, [screen]))
        check("offscreen frame resized", offscreenFixed.size == panelSize)

        // Negative direction too — a frame above and left of everything.
        let negative = CGRect(origin: CGPoint(x: -3000, y: -2000), size: panelSize)
        check(
            "negative offscreen frame not pulled back",
            isInside(clampedFrame(negative, visibleScreens: [screen]), [screen])
        )

        // 3. Straddling two screens is legitimate — both halves are visible, so
        // the frame must survive untouched.
        let straddling = CGRect(
            x: screen.maxX - panelSize.width / 2,
            y: 300,
            width: panelSize.width,
            height: panelSize.height
        )
        check(
            "straddling frame altered",
            clampedFrame(straddling, visibleScreens: [screen, right]) == straddling
        )

        // 4. Larger than the only screen: shrink to fit, then land inside.
        let oversized = CGRect(x: -200, y: -200, width: screen.width * 2, height: screen.height * 2)
        let oversizedFixed = clampedFrame(oversized, visibleScreens: [screen])
        check("oversized frame not shrunk", oversizedFixed.width <= screen.width)
        check("oversized frame not shrunk vertically", oversizedFixed.height <= screen.height)
        check("oversized frame not inside screen", isInside(oversizedFixed, [screen]))

        // 5. The saved screen is gone: frame was on `right`, only `screen`
        // remains. Must migrate rather than stay invisible.
        let onSecondScreen = CGRect(origin: CGPoint(x: 2000, y: 400), size: panelSize)
        check(
            "frame on vanished screen kept",
            isInside(clampedFrame(onSecondScreen, visibleScreens: [screen]), [screen])
        )
        // Same frame with that screen still present must not move.
        check(
            "frame on present second screen altered",
            clampedFrame(onSecondScreen, visibleScreens: [screen, right]) == onSecondScreen
        )

        // 6. Empty screen list — transient during reconfiguration. Returning a
        // guess here would overwrite a good saved position with a bad one.
        check("empty screen list altered frame", clampedFrame(valid, visibleScreens: []) == valid)

        // Barely-visible frames are corrected: a sliver on screen is technically
        // reachable and practically lost.
        let sliver = CGRect(x: screen.maxX - 20, y: 400, width: panelSize.width, height: panelSize.height)
        check("sliver frame kept", isInside(clampedFrame(sliver, visibleScreens: [screen]), [screen]))

        // The default position must itself be legal, or first launch starts in
        // the state the clamp exists to prevent.
        check(
            "default frame off screen",
            isInside(defaultFrame(size: panelSize, screens: [screen]), [screen])
        )
        check(
            "default frame has no screen fallback",
            defaultFrame(size: panelSize, screens: []).size == panelSize
        )

        return failures
    }
}

/// The panel itself carries only the focus policy; everything else is
/// configured on the instance. See `PanelController.show()` for why
/// `canBecomeKey` is true on a window that must never take focus by itself.
private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    /// Main implies "the user's document window". A macro pad is never that, and
    /// claiming it confuses window cycling.
    override var canBecomeMain: Bool { false }
}
