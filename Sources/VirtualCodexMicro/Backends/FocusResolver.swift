import AppKit
import Foundation

/// How completely a bound session can be brought on screen. Focus is not one
/// feature — the M0 spike (`spikes/focus/FINDINGS.md`) measured three genuinely
/// different outcomes, so the API returns a tier and the UI states which one it
/// got. Never a boolean.
public enum FocusTier: Int, Sendable, Codable, CaseIterable {
    /// Window *and* tab/pane targeted. Verified: Terminal.app 5/5, iTerm2 10/10,
    /// tmux hosted in either 4/4.
    case windowAndTab = 1
    /// App raised, tab not targetable. cmux, GoLand, VS Code, Zed and any other
    /// emulator that exposes no tty→window mapping. Must be labelled as such.
    case appOnly = 2
    /// Nothing to raise: no controlling tty, detached tmux, or an unidentifiable
    /// host. Detached tmux is the one case that gets an offer instead of a refusal.
    case impossible = 3

    public var label: String {
        switch self {
        case .windowAndTab: "window and tab"
        case .appOnly: "app only"
        case .impossible: "not focusable"
        }
    }
}

/// The three facts the resolution chain produces, plus the tier they imply and
/// the sentence the UI shows. `reason` is never empty for any tier — a key that
/// is visibly inert without saying why is the failure this whole design avoids.
public struct FocusPlan: Sendable, Equatable {
    public let pid: pid_t
    /// `/dev/ttysNNN`, or nil when the process has no controlling terminal.
    public let tty: String?
    /// `/Applications/cmux.app`, or nil when the walk found no owning bundle.
    public let hostBundlePath: String?
    /// `session:window.pane`, or nil when the process is not inside tmux.
    public let tmuxTarget: String?
    public let tier: FocusTier
    public let reason: String
    /// Non-nil only for a detached tmux session: the command that would make it
    /// focusable. Tier 3 with an action attached.
    public let attachCommand: String?

    /// `cmux`, `Terminal`, `iTerm2` — what the UI names in its label.
    public var hostName: String? {
        hostBundlePath.map { ($0 as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "") }
    }
}

/// Result of actually acting. `verified` is the load-bearing field: two of the
/// three spike code paths were initially wrong in a way that produced *no error*
/// — they returned success while raising the wrong thing. So the raise is
/// re-checked by reading the front window's tty back, and `verified == false`
/// means "we did something and cannot prove it was the right thing".
public struct FocusOutcome: Sendable, Equatable {
    public let tier: FocusTier
    public let verified: Bool
    public let reason: String
    public let host: String?
    public let tty: String?
    public let tmuxTarget: String?
    public let attachCommand: String?
}

/// Resolve a process id to the terminal window hosting it, raise it, and prove
/// the raise landed.
///
/// Latency, measured: warm calls 215–550 ms, first call in a process 1.0–2.3 s
/// because the Apple Events bridge has to warm up. See `warmUp()`.
///
/// Uses Automation (Apple Events) only. Accessibility is deliberately never
/// touched: on the spike machine it is denied, cannot be granted
/// non-interactively, and both denials arrive as bare error codes with no dialog,
/// so anything built on it fails invisibly.
public enum FocusResolver {

    // MARK: - Pure classification

    /// Emulators with a scriptable tty→window map. Everything else is Tier 2.
    ///
    /// Keyed by bundle name because the same app lives at different paths
    /// (Terminal is under /System/Applications/Utilities, iTerm2 wherever the
    /// user dropped it, GoLand under ~/Applications on this machine).
    private static let tierOneHosts: Set<String> = ["Terminal", "iTerm2", "iTerm"]

    /// Bundle path → tier. An unrecognised bundle defaults to `.appOnly`: we can
    /// always ask a running app to come forward, and claiming Tier 1 for an
    /// emulator whose scripting surface was never tested is how you ship a
    /// silently wrong target.
    public static func tier(forBundlePath path: String) -> FocusTier {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return tierOneHosts.contains(name) ? .windowAndTab : .appOnly
    }

    /// `ps -o tty=` prints `??` for a process with no controlling terminal and a
    /// short name otherwise — `ttys026` on this machine, verified against live
    /// processes. (FINDINGS.md writes it as `s007`; the running `ps` disagrees, and
    /// the fixtures follow `ps`.)
    static func normalizeTTY(psField: String) -> String? {
        let field = psField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !field.isEmpty, field != "??", field != "?" else { return nil }
        return field.hasPrefix("/dev/") ? field : "/dev/" + field
    }

    /// Pure: the three raw facts in, a tier and a user-facing reason out. Kept
    /// free of process calls so `selfCheckFailures()` can drive it with synthetic
    /// inputs instead of whatever happens to be running.
    public static func plan(
        pid: pid_t, psTTYField: String, hostBundlePath: String?, tmuxTarget: String?
    ) -> FocusPlan {
        func result(_ tier: FocusTier, _ reason: String, tty: String? = nil,
                    host: String? = nil, attach: String? = nil) -> FocusPlan {
            FocusPlan(pid: pid, tty: tty, hostBundlePath: host, tmuxTarget: tmuxTarget,
                      tier: tier, reason: reason, attachCommand: attach)
        }

        guard let tty = normalizeTTY(psField: psTTYField) else {
            return result(.impossible, "No controlling terminal — this session has no window to raise.")
        }

        // Detached tmux: the pane can be selected but there is no client window
        // behind it. Reported as detached, never as a guessed host — an unscoped
        // `list-clients` in the spike named a Terminal.app window belonging to an
        // unrelated session.
        if let target = tmuxTarget, hostBundlePath == nil {
            let session = String(target.prefix(while: { $0 != ":" }))
            return result(.impossible,
                          "tmux session \"\(session)\" is detached — attach it to bring this session on screen.",
                          tty: tty, attach: "tmux attach -t \(session)")
        }

        guard let host = hostBundlePath else {
            return result(.impossible,
                          "Could not identify the app that owns \(tty) — nothing to raise.",
                          tty: tty)
        }

        let name = ((host as NSString).lastPathComponent as NSString).deletingPathExtension
        switch tier(forBundlePath: host) {
        case .windowAndTab:
            let where_ = tmuxTarget.map { " (tmux \($0))" } ?? ""
            return result(.windowAndTab, "Raises the \(name) window and tab\(where_).",
                          tty: tty, host: host)
        case .appOnly:
            return result(.appOnly, "Raises \(name) — cannot target the tab.", tty: tty, host: host)
        case .impossible:
            return result(.impossible, "\(name) cannot be raised.", tty: tty, host: host)
        }
    }

    // MARK: - Resolution against the live system

    /// Ported from `spikes/focus/host-for-pid.sh`.
    ///
    /// **`TERM_PROGRAM` is deliberately not consulted anywhere in here.** Inside
    /// cmux it reports `ghostty` because cmux embeds libghostty, and Ghostty is
    /// not installed on this machine at all — the variable names a terminal
    /// *implementation*, not the app owning the window, so trusting it sends the
    /// raise to an app that does not exist. Walking the process tree is the only
    /// thing that was correct in every case tested. Do not "simplify" this back.
    public static func resolve(pid: pid_t) -> FocusPlan {
        let psTTY = run("/bin/ps", ["-o", "tty=", "-p", String(pid)]).out
        guard normalizeTTY(psField: psTTY) != nil else {
            return plan(pid: pid, psTTYField: psTTY, hostBundlePath: nil, tmuxTarget: nil)
        }
        let tty = normalizeTTY(psField: psTTY)!

        // tmux FIRST. A pane's parent chain dead-ends at the tmux server, whose
        // parent is launchd, so the tree walk below simply cannot find the host
        // from inside a pane.
        let tmuxTarget = tmuxPane(forTTY: tty)

        var host = bundleOwning(pid: pid)
        if let target = tmuxTarget, host == nil {
            // Resolve the host from the attached *client's* tty and walk that.
            // `-t <session>` is not optional: unscoped, this returned a client of
            // an unrelated session and reported a detached session as living in a
            // Terminal.app window.
            let session = String(target.prefix(while: { $0 != ":" }))
            if let clientTTY = tmuxClientTTY(session: session),
               let clientPID = firstPID(onTTY: clientTTY) {
                host = bundleOwning(pid: clientPID)
            }
        }
        return plan(pid: pid, psTTYField: psTTY, hostBundlePath: host, tmuxTarget: tmuxTarget)
    }

    /// Walk PPID until an ancestor's executable path sits inside an `.app` bundle.
    private static func bundleOwning(pid: pid_t) -> String? {
        var current = pid
        for _ in 0..<24 {
            let line = run("/bin/ps", ["-o", "ppid=,comm=", "-p", String(current)]).out
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let space = line.firstIndex(of: " ") else { return nil }
            let parent = pid_t(line[line.startIndex..<space]) ?? 0
            let command = line[space...].trimmingCharacters(in: .whitespaces)

            if let marker = command.range(of: ".app/Contents/MacOS/") {
                return String(command[command.startIndex..<marker.lowerBound]) + ".app"
            }
            guard parent > 1 else { return nil }
            current = parent
        }
        return nil
    }

    // MARK: - Acting, then verifying

    /// Resolve, dispatch, verify. `cachedTTY`, when supplied, is re-validated
    /// against the live pid first: **tty numbers are recycled within minutes of a
    /// window closing**, so acting on a stale cache raises a stranger's window.
    ///
    /// Blocking work runs off the caller's executor — a raise costs up to 550 ms
    /// warm and seconds cold.
    public static func focus(pid: pid_t, cachedTTY: String? = nil) async -> FocusOutcome {
        await Task.detached(priority: .userInitiated) { performFocus(pid: pid, cachedTTY: cachedTTY) }.value
    }

    static func performFocus(pid: pid_t, cachedTTY: String?) -> FocusOutcome {
        let plan = resolve(pid: pid)

        if let cached = cachedTTY, cached != plan.tty {
            return FocusOutcome(
                tier: .impossible, verified: false,
                reason: "This session is no longer on \(cached) — tty numbers are reused, so nothing was raised. Re-bind the session.",
                host: plan.hostName, tty: plan.tty, tmuxTarget: plan.tmuxTarget, attachCommand: nil
            )
        }

        func outcome(_ tier: FocusTier, verified: Bool, _ reason: String, tty: String? = plan.tty) -> FocusOutcome {
            FocusOutcome(tier: tier, verified: verified, reason: reason, host: plan.hostName,
                         tty: tty, tmuxTarget: plan.tmuxTarget, attachCommand: plan.attachCommand)
        }

        guard plan.tier != .impossible else {
            return outcome(.impossible, verified: false, plan.reason)
        }

        // tmux: bring the pane into view before raising anything, then raise the
        // CLIENT's window. A pane tty belongs to no window.
        var windowTTY = plan.tty
        if let target = plan.tmuxTarget {
            let window = target.contains(".") ? String(target[target.startIndex..<target.lastIndex(of: ".")!]) : target
            _ = tmux(["select-window", "-t", window])
            _ = tmux(["select-pane", "-t", target])
            let session = String(target.prefix(while: { $0 != ":" }))
            guard let clientTTY = tmuxClientTTY(session: session) else {
                // Client vanished between resolve and now.
                return outcome(.impossible, verified: false,
                               "tmux session \"\(session)\" has no attached client — nothing to raise.")
            }
            windowTTY = clientTTY
            if !tmuxPaneIsActive(target: target) {
                return outcome(plan.tier, verified: false,
                               "tmux would not select \(target) — the pane may have closed.")
            }
        }

        guard let hostPath = plan.hostBundlePath, let app = runningApp(bundlePath: hostPath) else {
            return outcome(.impossible, verified: false,
                           "\(plan.hostName ?? "The host app") is not running — nothing to raise.")
        }

        if plan.tier == .appOnly {
            // NSRunningApplication.activate first — no Automation grant needed and it
            // cannot launch anything — but it is NOT sufficient on its own.
            //
            // Measured: it silently fails from this app. macOS 14+ refuses one app
            // the right to activate another unless the caller is itself active, and
            // this app is `.accessory` with a `.nonactivatingPanel`, so it is never
            // active by design. The user saw exactly this: clicking a key reported
            // "cmux did not come forward — another app is holding focus", every time.
            //
            // `NSWorkspace.openApplication` is not subject to that restriction —
            // `open -a cmux` brings it forward from a background process, verified
            // against a Finder-frontmost baseline. It CAN launch an app, which is why
            // it stays behind the `runningApp(bundlePath:)` guard above: we only ever
            // reach here for an app already running, so it activates rather than
            // launches.
            app.activate(options: [])
            if waitForFrontmost(app) {
                return outcome(.appOnly, verified: true, plan.reason)
            }

            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            let bundleURL = URL(filePath: hostPath)
            let semaphore = DispatchSemaphore(value: 0)
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, _ in
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 2)

            let ok = waitForFrontmost(app)
            return outcome(.appOnly, verified: ok,
                           ok ? plan.reason : "\(plan.hostName ?? "The app") did not come forward — another app is holding focus.")
        }

        guard let tty = windowTTY, isSafeTTYPath(tty) else {
            return outcome(.impossible, verified: false, "Refusing to script an implausible tty path.")
        }

        let name = plan.hostName ?? ""
        let script = name == "Terminal" ? terminalRaiseScript(tty: tty) : itermRaiseScript(tty: tty)
        let raise = run("/usr/bin/osascript", ["-e", script])
        guard raise.status == 0, raise.out.hasPrefix("ok") else {
            return outcome(.impossible, verified: false,
                           "\(name) did not accept the raise (\(raise.out.isEmpty ? raise.err : raise.out)).")
        }

        // The requirement the spike exists for: never trust the return value.
        // Both wrong paths returned `ok` while a different session stayed current.
        let front = frontTTY(host: name)
        guard front == tty else {
            return outcome(.windowAndTab, verified: false,
                           "\(name) reported success but the front window is \(front ?? "unknown"), not \(tty).",
                           tty: tty)
        }
        return outcome(.windowAndTab, verified: true, plan.reason, tty: tty)
    }

    /// One harmless Apple Event to pay the 1.0–2.3 s bridge warm-up before the
    /// user's first click instead of during it.
    ///
    /// Not called at launch by default, on purpose: the first Apple Event to a
    /// given target app is what raises the one-time Automation prompt, and
    /// triggering that unasked writes a permanent decision into the user's TCC
    /// state. Call it once onboarding has explained why. Only ever touches apps
    /// already running.
    public static func warmUp() {
        for name in tierOneHosts where runningApp(named: name) != nil {
            _ = frontTTY(host: name)
            return
        }
    }

    // MARK: - AppleScript

    /// Verbatim from `spikes/focus/raise-terminal.applescript` (5/5).
    ///
    /// `windows` yields POSITIONAL references, so `set index of w to 1` makes `w`
    /// point at a *different* window. The id is captured before mutating and
    /// everything after is addressed through `window id <n>`. The first version
    /// read the id back after reordering and reported a window that did not own
    /// the requested tty — it raised correctly by luck and reported a lie.
    ///
    /// No `System Events → exists process` guard: `NSWorkspace` already
    /// established the app is running, and `tell application "Terminal"` LAUNCHES
    /// Terminal when it is not — that started Terminal on a closed machine during
    /// the spike.
    static func terminalRaiseScript(tty: String) -> String {
        """
        tell application "Terminal"
          set foundID to missing value
          set foundIdx to 0
          repeat with w in windows
            set wid to id of w
            set i to 0
            repeat with t in tabs of w
              set i to i + 1
              try
                if (tty of t) is "\(tty)" then
                  set foundID to wid
                  set foundIdx to i
                  exit repeat
                end if
              end try
            end repeat
            if foundID is not missing value then exit repeat
          end repeat
          if foundID is missing value then return "notfound"
          set selected of tab foundIdx of window id foundID to true
          set index of window id foundID to 1
          activate
          return "ok " & (foundID as text) & " " & (foundIdx as text)
        end tell
        """
    }

    /// Verbatim from `spikes/focus/raise-iterm.applescript` (10/10 after rewrite;
    /// 2/15 before). It looks redundant — three near-identical loops over the same
    /// `windows` collection — and every one of them is necessary.
    ///
    /// Six documented approaches fail in 3.6.11, all silently or misleadingly:
    /// `set current tab of window id N`, `set current session of tab M`, and
    /// `set frontmost of window id N` all error -10000 despite the sdef marking
    /// them rw; `set index of window id N to 1`, `select session K of tab M of
    /// window id N` and `close window 1` produce no error and no effect. Every
    /// specifier rooted at `window id N` is ignored.
    ///
    /// What works is `select` sent to a reference reached by iterating `windows`,
    /// applied outside-in, **re-finding the window after every mutation** because
    /// positional references invalidate on reorder — reusing one reference raised
    /// the wrong tab. `select <session>` alone only moves between splits of the
    /// current tab, so the tab needs its own pass. Do not collapse the loops.
    static func itermRaiseScript(tty: String) -> String {
        """
        tell application "iTerm2"
          set wid to missing value
          set ti to 0
          set si to 0
          repeat with w in windows
            set i to 0
            repeat with t in tabs of w
              set i to i + 1
              set j to 0
              repeat with s in sessions of t
                set j to j + 1
                if (tty of s) is "\(tty)" then
                  set wid to id of w
                  set ti to i
                  set si to j
                  exit repeat
                end if
              end repeat
              if wid is not missing value then exit repeat
            end repeat
            if wid is not missing value then exit repeat
          end repeat
          if wid is missing value then return "notfound"
          repeat with w in windows
            if (id of w) is wid then
              select w
              exit repeat
            end if
          end repeat
          repeat with w in windows
            if (id of w) is wid then
              select tab ti of w
              exit repeat
            end if
          end repeat
          repeat with w in windows
            if (id of w) is wid then
              select session si of tab ti of w
              exit repeat
            end if
          end repeat
          activate
          return "ok " & (wid as text) & " " & (ti as text) & " " & (si as text)
        end tell
        """
    }

    /// Reads back what is actually in front. The whole verification step.
    private static func frontTTY(host: String) -> String? {
        let script = host == "Terminal"
            ? "tell application \"Terminal\" to return tty of selected tab of front window"
            : "tell application \"iTerm2\" to return tty of current session of current window"
        let result = run("/usr/bin/osascript", ["-e", script])
        guard result.status == 0 else { return nil }
        let tty = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return tty.isEmpty ? nil : tty
    }

    // MARK: - NSWorkspace

    private static func runningApp(bundlePath: String) -> NSRunningApplication? {
        let wanted = URL(fileURLWithPath: bundlePath).resolvingSymlinksInPath().path
        let apps = NSWorkspace.shared.runningApplications
        if let exact = apps.first(where: { $0.bundleURL?.resolvingSymlinksInPath().path == wanted }) {
            return exact
        }
        // Same app, moved or reported via a different path.
        let name = (wanted as NSString).lastPathComponent
        return apps.first { ($0.bundleURL?.lastPathComponent) == name }
    }

    private static func runningApp(named name: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            ($0.bundleURL?.deletingPathExtension().lastPathComponent) == name
        }
    }

    /// App activation loses races: a determined foreground app can take focus
    /// straight back (Safari did, repeatedly, during the spike). Poll rather than
    /// assume, and report honestly when it did not win.
    private static func waitForFrontmost(_ app: NSRunningApplication) -> Bool {
        for _ in 0..<8 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                return true
            }
            usleep(100_000)
        }
        return false
    }

    // MARK: - tmux

    /// nil when tmux is not installed or no server is running — both are ordinary,
    /// not errors.
    private static func tmuxPane(forTTY tty: String) -> String? {
        guard let out = tmux(["list-panes", "-a", "-F", "#{pane_tty} #{session_name}:#{window_index}.#{pane_index}"])
        else { return nil }
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2, parts[0] == tty { return String(parts[1]) }
        }
        return nil
    }

    private static func tmuxClientTTY(session: String) -> String? {
        guard let out = tmux(["list-clients", "-t", session, "-F", "#{client_tty}"]) else { return nil }
        // Empty output with status 0 is the detached case.
        return out.split(separator: "\n").first.map(String.init)
    }

    private static func tmuxPaneIsActive(target: String) -> Bool {
        guard let out = tmux(["list-panes", "-a", "-F",
                              "#{window_active}#{pane_active} #{session_name}:#{window_index}.#{pane_index}"])
        else { return false }
        return out.split(separator: "\n").contains("11 " + target)
    }

    private static func firstPID(onTTY tty: String) -> pid_t? {
        let short = tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
        let out = run("/bin/ps", ["-t", short, "-o", "pid="]).out
        return out.split(whereSeparator: \.isWhitespace).first.flatMap { pid_t($0) }
    }

    /// tmux is a Homebrew binary, so PATH matters and a login shell's PATH is not
    /// ours. Probed rather than assumed; nil means "no tmux", which is fine.
    private static let tmuxPath: String? = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    private static func tmux(_ args: [String]) -> String? {
        guard let path = tmuxPath else { return nil }
        let result = run(path, args)
        return result.status == 0 ? result.out : nil
    }

    // MARK: - Process plumbing

    /// A tty path is interpolated into an AppleScript, so it gets checked rather
    /// than trusted, even though it came from `ps`.
    static func isSafeTTYPath(_ tty: String) -> Bool {
        guard tty.hasPrefix("/dev/tty"), tty.count <= 32 else { return false }
        return tty.dropFirst(5).allSatisfy { $0.isLetter || $0.isNumber }
    }

    private static func run(_ path: String, _ args: [String]) -> (status: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "", "\(error)") }
        // Drain before waiting: a full pipe buffer would deadlock the child.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
            String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: - Self check

    /// Drives the pure classification with synthetic inputs only. Deliberately
    /// depends on no live process: whether Terminal happens to be open is not
    /// something a self-check may be flaky about.
    public static func selfCheckFailures() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        let noTTY = plan(pid: 1, psTTYField: "??", hostBundlePath: nil, tmuxTarget: nil)
        check("?? tty is not tier 3", noTTY.tier == .impossible)
        check("?? tty kept a tty", noTTY.tty == nil)

        let cmux = plan(pid: 2, psTTYField: "ttys000", hostBundlePath: "/Applications/cmux.app", tmuxTarget: nil)
        check("cmux is not tier 2", cmux.tier == .appOnly)
        check("cmux tier 2 does not say the tab is untargetable",
              cmux.reason.lowercased().contains("cannot target the tab"))
        check("cmux host name lost", cmux.hostName == "cmux")
        check("tty not normalized", cmux.tty == "/dev/ttys000")

        let terminal = plan(pid: 3, psTTYField: "ttys026",
                            hostBundlePath: "/System/Applications/Utilities/Terminal.app", tmuxTarget: nil)
        check("Terminal.app is not tier 1", terminal.tier == .windowAndTab)

        let iterm = plan(pid: 4, psTTYField: "ttys001", hostBundlePath: "/Applications/iTerm.app", tmuxTarget: nil)
        check("iTerm2 is not tier 1", iterm.tier == .windowAndTab)

        // tmux hosted in a Tier 1 emulator stays Tier 1, pane and all.
        let hosted = plan(pid: 5, psTTYField: "ttys030",
                          hostBundlePath: "/System/Applications/Utilities/Terminal.app",
                          tmuxTarget: "vcmspike:1.1")
        check("hosted tmux pane is not tier 1", hosted.tier == .windowAndTab)

        // Detached: pane exists, no client. Must offer to attach, never guess a host.
        let detached = plan(pid: 6, psTTYField: "ttys011", hostBundlePath: nil, tmuxTarget: "probe:0.0")
        check("detached tmux is not tier 3", detached.tier == .impossible)
        check("detached tmux guessed a host", detached.hostBundlePath == nil)
        check("detached tmux offers no attach", detached.attachCommand == "tmux attach -t probe")
        check("detached tmux reason does not say detached", detached.reason.contains("detached"))

        let unknownHost = plan(pid: 7, psTTYField: "ttys009", hostBundlePath: nil, tmuxTarget: nil)
        check("unresolvable host is not tier 3", unknownHost.tier == .impossible)

        // An emulator nobody tested must degrade to app activation, never claim
        // Tier 1 and raise the wrong tab.
        check("unknown bundle claims tier 1",
              tier(forBundlePath: "/Applications/SomeFutureTerm.app") == .appOnly)
        check("unknown bundle plan claims tier 1",
              plan(pid: 8, psTTYField: "ttys004", hostBundlePath: "/Applications/SomeFutureTerm.app",
                   tmuxTarget: nil).tier == .appOnly)

        // Every tier must arrive with something to show the user.
        let samples = [noTTY, cmux, terminal, iterm, hosted, detached, unknownHost]
        for tier in FocusTier.allCases {
            check("no sample for tier \(tier.rawValue)", samples.contains { $0.tier == tier })
            check("tier \(tier.rawValue) unlabelled", !tier.label.isEmpty)
        }
        for sample in samples where sample.reason.isEmpty {
            failures.append("tier \(sample.tier.rawValue) plan has an empty reason")
        }

        // The tty is interpolated into AppleScript, so the guard has to hold.
        check("valid tty rejected", isSafeTTYPath("/dev/ttys026"))
        check("injection accepted", !isSafeTTYPath("/dev/ttys0\" & (do shell script \"id\") & \""))
        check("non-tty path accepted", !isSafeTTYPath("/etc/passwd"))
        check("?? accepted as a path", !isSafeTTYPath("??"))

        // Interpolation actually reaches the script, in both dialects.
        check("Terminal script drops the tty", terminalRaiseScript(tty: "/dev/ttys026").contains("\"/dev/ttys026\""))
        check("iTerm script drops the tty", itermRaiseScript(tty: "/dev/ttys026").contains("\"/dev/ttys026\""))
        // The three re-find loops are the only sequence that works in 3.6.11.
        check("iTerm script lost a re-find loop",
              itermRaiseScript(tty: "/dev/ttys026").components(separatedBy: "if (id of w) is wid then").count == 4)

        return failures
    }
}
