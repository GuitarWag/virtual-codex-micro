import Darwin
import Foundation
import os

private let log = Logger(subsystem: "com.virtualcodexmicro.app", category: "owned")

// MARK: - Why this file looks like this
//
// Owned sessions run a **visible TUI** under our own pseudo-terminal, and every
// keystroke we inject is gated on a `PermissionRequest` hook event. That decision
// is settled (PLAN.md, "Decisions taken after the spikes"); what follows are the
// M0 spike's measured constraints, each of which is a correctness requirement
// rather than a style choice:
//
// 1. **`forkpty`, not `openpty` + Foundation `Process`** (spike test 8). `Process`
//    offers no hook between fork and exec, so the pty never becomes the child's
//    *controlling* terminal: job control, `SIGWINCH`, `^C` and hangup-on-close all
//    stop working and every child is a guaranteed orphan.
// 2. **The master fd is drained continuously** for the child's whole life (test 3).
//    A `vi` child that filled the pty buffer while the parent was not reading
//    blocked in `write()` forever; the session merely looks hung.
// 3. **Teardown is `killpg` then `SIGKILL` on a timeout** (tests 6, 7). The pty
//    hangup is not cleanup: one child in 66 survived it, and SIGHUP-ignoring
//    grandchildren — MCP servers, language servers, node workers, exactly what an
//    agent CLI spawns — survive every time while keeping the child's PGID.
// 4. **The byte stream is never parsed for state** (test 4). A prompt written
//    across a redraw boundary is invisible to substring matching, and a match is
//    sticky: one unanswered prompt produced 60 hits that persisted after the
//    prompt was gone. State comes from hooks. `recentOutput` exists so the bytes
//    have somewhere to go and so a future terminal view can render them — reading
//    a colour out of it is the bug this comment exists to prevent.
// 5. **Nothing is injected blind** (test 5). A child entering raw mode with
//    `TCSAFLUSH` silently discards input queued before that call, so an accept
//    keystroke is only safe once a `PermissionRequest` has told us the dialog is
//    up — which it does 1 ms after the dialog is painted.

// MARK: - Exit status

/// How a child ended. `waitpid` separates these cleanly (spike test 6), so
/// "the session died" and "the session failed" do not have to share a state.
public enum PTYExit: Sendable, Equatable {
    case running
    /// Ran to completion. `code == 0` is a clean quit; non-zero is a *failure*.
    case exited(code: Int32)
    /// Killed by a fatal signal nobody asked for — SIGSEGV, SIGBUS, SIGILL. The
    /// session *died*.
    case crashed(signal: Int32)
    /// Killed by our own teardown. Not a crash and not an error; we did it.
    case terminatedByUs(signal: Int32)
    /// `waitpid` says `ECHILD`: no longer our child and we never saw it end. We do
    /// not know how it went, so nothing may be asserted about it.
    case vanished

    public var isRunning: Bool { self == .running }

    public var describe: String {
        switch self {
        case .running: "running"
        case .exited(0): "exited cleanly"
        case .exited(let code): "failed: exited \(code)"
        case .crashed(let signal): "died: fatal SIG\(PTYExit.name(signal))"
        case .terminatedByUs(let signal): "terminated by us (SIG\(PTYExit.name(signal)))"
        case .vanished: "vanished: reaped by something else, outcome unknown"
        }
    }

    static func name(_ signal: Int32) -> String {
        switch signal {
        case SIGHUP: "HUP"; case SIGINT: "INT"; case SIGQUIT: "QUIT"
        case SIGILL: "ILL"; case SIGABRT: "ABRT"; case SIGBUS: "BUS"
        case SIGSEGV: "SEGV"; case SIGPIPE: "PIPE"; case SIGTERM: "TERM"
        case SIGKILL: "KILL"; default: "NUM\(signal)"
        }
    }

    /// `wait(2)` status word → us. The bit layout is the same one the spike's
    /// harness decoded.
    static func decode(_ status: Int32, weAskedFor: Bool) -> PTYExit {
        if status & 0x7f == 0 { return .exited(code: (status >> 8) & 0xff) }
        let signal = status & 0x7f
        guard signal != 0x7f else { return .running } // stopped, not exited
        return weAskedFor ? .terminatedByUs(signal: signal) : .crashed(signal: signal)
    }
}

public enum PTYSpawnError: Error, CustomStringConvertible, Equatable {
    case executableNotFound(String)
    case forkFailed(String)

    public var description: String {
        switch self {
        case .executableNotFound(let name): "no executable named '\(name)' on PATH"
        case .forkFailed(let why): "forkpty failed: \(why)"
        }
    }
}

// MARK: - The child

/// One process running under a pseudo-terminal we own, with a reader draining the
/// master for as long as it lives.
///
/// A `final class` with **every** mutable field inside one `OSAllocatedUnfairLock`.
/// The producers are a Dispatch read source and whichever thread calls `write`;
/// neither is an async context, so an actor here would buy a `Task` hop per read and
/// scramble the arrival order of the bytes for nothing.
///
/// `@unchecked` covers exactly one thing the compiler cannot see: `DispatchSourceRead`
/// carries no `Sendable` conformance. Every other stored property is either a `let` of
/// a `Sendable` type or lives behind the lock.
public final class PTYChild: @unchecked Sendable {

    /// Serialises `forkpty` across concurrent spawns. Two reasons, both about the
    /// M2 target of six children: `forkpty` is not documented thread-safe, and a
    /// fork racing another spawn can inherit a master fd that is not yet
    /// `FD_CLOEXEC`, which would keep that pty open in a stranger's child and stop
    /// EOF from ever arriving.
    private static let spawnLock = NSLock()

    private struct Shared: Sendable {
        var tail = Data()
        var bytesRead = 0
        var sawEOF = false
        var exit: PTYExit = .running
        var masterClosed = false
        var weAskedForTermination = false
        var writeFailures = 0
    }

    public let pid: pid_t
    /// pgid. `forkpty` calls `setsid()` in the child, so the child is a session and
    /// process-group leader and its pgid equals its pid — which is why
    /// `killpg(pid, …)` reaches grandchildren that ignored SIGHUP.
    public var processGroup: pid_t { pid }
    public let startedAt: Date
    /// From `sysctl`, not from us: the pair (pid, boot-relative start time) is what
    /// makes a recorded pid safe to kill later. Pids are recycled; start times are
    /// not.
    public let identity: (start: TimeInterval, comm: String)?

    private let master: Int32
    private let tailLimit: Int
    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    private let queue: DispatchQueue
    private let drain: DispatchSourceRead

    // MARK: Spawn

    /// `forkpty` + `execve`.
    ///
    /// Everything the child needs is C memory built *before* the fork: between fork
    /// and exec only async-signal-safe calls are legal, and a Swift allocation there
    /// can deadlock on a lock the forked thread does not hold.
    public static func spawn(
        executable: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        columns: UInt16 = 120,
        rows: UInt16 = 32,
        tailLimit: Int = 256 * 1024
    ) throws -> PTYChild {
        guard let resolved = resolve(executable) else {
            throw PTYSpawnError.executableNotFound(executable)
        }

        var env = ProcessInfo.processInfo.environment
        // A TUI needs to know it is on a terminal and how big it is. Passed as an
        // explicit envp rather than `setenv`, which would mutate *our* environment
        // and race every other spawn.
        env["TERM"] = env["TERM"] ?? "xterm-256color"
        env["LINES"] = String(rows)
        env["COLUMNS"] = String(columns)
        for (key, value) in environment { env[key] = value }

        let path = cString(resolved)
        var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map(cString) + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = env.map { cString("\($0.key)=\($0.value)") } + [nil]
        let cwd = workingDirectory.map(cString)
        defer {
            free(path)
            cwd.map { free($0) }
            for pointer in argv + envp { free(pointer) }
        }

        // The child inherits the forking thread's signal mask and dispositions.
        // Dispatch blocks signals on its worker threads and Foundation sets SIGPIPE
        // to ignore, either of which would be inherited by an agent CLI and its own
        // children. Both sets are built here so the child only has to install them.
        var unblockAll = sigset_t()
        sigemptyset(&unblockAll)

        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        var master: Int32 = -1

        spawnLock.lock()
        let pid: pid_t = argv.withUnsafeMutableBufferPointer { argvBuffer in
            envp.withUnsafeMutableBufferPointer { envpBuffer in
                let pid = forkpty(&master, nil, nil, &size)
                if pid == 0 {
                    sigprocmask(SIG_SETMASK, &unblockAll, nil)
                    signal(SIGPIPE, SIG_DFL)
                    if let cwd { _ = chdir(cwd) }
                    execve(path, argvBuffer.baseAddress!, envpBuffer.baseAddress!)
                    _exit(127) // exec failed; 127 is the shell's convention
                }
                if pid > 0 {
                    // Before the lock is released, so the next fork cannot inherit
                    // this master and hold the pty open behind our back.
                    _ = fcntl(master, F_SETFD, FD_CLOEXEC)
                    _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL, 0) | O_NONBLOCK)
                }
                return pid
            }
        }
        spawnLock.unlock()

        guard pid > 0 else {
            throw PTYSpawnError.forkFailed(String(cString: strerror(errno)))
        }
        log.debug("spawned pty child \(pid) for \(resolved, privacy: .public)")
        return PTYChild(pid: pid, master: master, tailLimit: tailLimit)
    }

    private init(pid: pid_t, master: Int32, tailLimit: Int) {
        self.pid = pid
        self.master = master
        self.tailLimit = max(4096, tailLimit)
        startedAt = Date()
        identity = PTYChild.processIdentity(pid)
        queue = DispatchQueue(label: "com.virtualcodexmicro.pty.\(pid)")
        drain = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)

        let fd = master
        drain.setCancelHandler { [shared] in
            shared.withLock { $0.masterClosed = true }
            close(fd)
        }
        drain.setEventHandler { [weak self] in self?.readAvailable() }
        drain.activate()
    }

    /// Cancels the drain (which closes the master) and makes sure the process group
    /// cannot outlive us unnoticed. Non-blocking on purpose: a `deinit` that waits
    /// on `waitpid` would stall whichever thread released the last reference.
    ///
    /// This is a backstop, not the teardown path — call `terminate` for that. The
    /// stray-record file plus `OwnedSession.sweepStrays` is what covers the case
    /// where the whole app dies before either runs.
    deinit {
        let alreadyDone = shared.withLock { $0.weAskedForTermination || !$0.exit.isRunning }
        if !alreadyDone {
            log.error("pty child \(self.pid) released without terminate(); killing its group")
            _ = killpg(pid, SIGKILL)
            _ = kill(pid, SIGKILL)
            var status: Int32 = 0
            _ = waitpid(pid, &status, WNOHANG)
        }
        drain.cancel()
    }

    // MARK: Reading

    /// The whole reason a reader exists: the child blocks in `write()` when the pty
    /// buffer fills, and a blocked child looks exactly like a hung one.
    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                read(master, raw.baseAddress, raw.count)
            }
            if count > 0 {
                let chunk = Data(buffer[0 ..< count])
                shared.withLock { state in
                    state.bytesRead += chunk.count
                    state.tail.append(chunk)
                    let excess = state.tail.count - tailLimit
                    if excess > 0 { state.tail.removeFirst(excess) }
                }
                continue
            }
            if count == 0 { break } // clean EOF
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return } // drained, keep watching
            break // EIO on Darwin: the slave side is gone
        }
        shared.withLock { $0.sawEOF = true }
        _ = status() // the exit is usually available the moment the pty hangs up
        drain.cancel()
    }

    /// The last `tailLimit` bytes the child wrote, escape sequences and all.
    ///
    /// **Never infer state from this** (spike test 4). It is here so the bytes have a
    /// destination, so a terminal view can render the session, and so the self check
    /// can prove the drain works.
    public var recentOutput: Data { shared.withLock { $0.tail } }
    public var recentOutputText: String { String(decoding: recentOutput, as: UTF8.self) }
    /// Total bytes drained, which is larger than `recentOutput.count` once the tail
    /// has wrapped.
    public var bytesRead: Int { shared.withLock { $0.bytesRead } }
    public var sawEOF: Bool { shared.withLock { $0.sawEOF } }
    public var writeFailures: Int { shared.withLock { $0.writeFailures } }

    // MARK: Writing

    /// Writes to the master. Non-blocking with a bounded retry: a full pty input
    /// buffer must never stall the caller, and a write we could not finish has to be
    /// reported rather than assumed.
    ///
    /// This is the *only* way bytes reach the child, and every caller in
    /// `OwnedSession` is gated on a `PermissionRequest` first.
    @discardableResult
    public func write(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var offset = 0
        let deadline = Date().addingTimeInterval(0.25)
        while offset < bytes.count {
            let remaining = Array(bytes[offset...])
            let wrote: Int = shared.withLock { state in
                guard !state.masterClosed else { return -2 }
                return remaining.withUnsafeBufferPointer { buffer in
                    Darwin.write(master, buffer.baseAddress!, buffer.count)
                }
            }
            if wrote == -2 { break }
            if wrote > 0 { offset += wrote; continue }
            if errno == EINTR { continue }
            if (errno == EAGAIN || errno == EWOULDBLOCK), Date() < deadline {
                usleep(2000)
                continue
            }
            break
        }
        let complete = offset == bytes.count
        if !complete { shared.withLock { $0.writeFailures += 1 } }
        return complete
    }

    // MARK: Size

    /// `TIOCSWINSZ` on the master; the kernel delivers `SIGWINCH` to the child's
    /// foreground process group, which only works because `forkpty` made this pty
    /// the controlling terminal.
    ///
    /// **Untested against a real agent TUI** — the spike never resized anything (its
    /// "not tested" list says so). Ink-based TUIs redraw on `SIGWINCH`, so the
    /// expected failure is a garbled frame until the next redraw, not a lost
    /// session. Kept because without it a resize is impossible rather than ugly.
    @discardableResult
    public func resize(columns: UInt16, rows: UInt16) -> Bool {
        let fd = master
        return shared.withLock { state in
            guard !state.masterClosed else { return false }
            return PTYChild.setSize(fd, columns: columns, rows: rows)
        }
    }

    private static func setSize(_ fd: Int32, columns: UInt16, rows: UInt16) -> Bool {
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        return ioctl(fd, TIOCSWINSZ, &size) == 0
    }

    // MARK: Status and teardown

    /// Non-blocking. Caches the first real answer, so asking twice cannot turn a
    /// known exit into `.vanished`.
    public func status() -> PTYExit {
        let cached = shared.withLock { $0.exit }
        if !cached.isRunning { return cached }

        var raw: Int32 = 0
        let result = waitpid(pid, &raw, WNOHANG)
        if result == 0 { return .running }
        // Both branches below CHECK-AND-SET rather than plain assign, because the
        // `waitpid` above happens outside the lock. Two threads can both pass the
        // cache check while the child is still running; one then reaps the real
        // status and the other gets ECHILD. Whoever wrote last used to win, so a
        // loser's `.vanished` could overwrite a winner's real exit code — which
        // surfaced as a flaky "concurrent child N did not exit cleanly: vanished,
        // outcome unknown" under six concurrent children, the case no spike covered.
        // A real answer must never be downgraded to "outcome unknown".
        if result < 0 {
            guard errno == ECHILD else { return .running }
            return shared.withLock {
                if $0.exit.isRunning { $0.exit = .vanished }
                return $0.exit
            }
        }
        let asked = shared.withLock { $0.weAskedForTermination }
        let decoded = PTYExit.decode(raw, weAskedFor: asked)
        guard !decoded.isRunning else { return decoded }
        return shared.withLock {
            if $0.exit.isRunning { $0.exit = decoded }
            return $0.exit
        }
    }

    /// Cheap liveness for gap G3: no hook fires when a session is `SIGKILL`ed, so
    /// somebody has to ask the kernel.
    public var liveness: Liveness {
        if !status().isRunning { return .dead }
        return PTYChild.isAlive(pid) ? .alive : .dead
    }

    /// `EPERM` means the process exists and merely is not ours to signal — reading it
    /// as "gone" would make every root-owned or reparented process look dead.
    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// `killpg` then `SIGKILL` on a timeout, then close the pty — in that order.
    ///
    /// - The group, not the pid: SIGHUP-ignoring grandchildren keep the child's PGID
    ///   and are otherwise left running (spike test 7).
    /// - `killpg` can fail with `ESRCH` in the sliver before the child's `setsid()`
    ///   lands, so each signal is also sent to the pid directly. Measured: the race
    ///   is real.
    /// - The pty is closed **last**. Closing first would stop the drain, and a child
    ///   mid-render then blocks in `write()` and can never reach its own exit path
    ///   (spike test 3).
    /// - The pty hangup is not part of the plan. It leaked one child in 66 runs.
    @discardableResult
    public func terminate(
        grace: TimeInterval = 2.0,
        killGrace: TimeInterval = 1.0,
        graceful: Bool = false
    ) -> PTYExit {
        shared.withLock { $0.weAskedForTermination = true }
        defer { drain.cancel() }

        if !status().isRunning { return status() }

        // SIGKILL directly, and deliberately NOT SIGTERM first.
        //
        // The PTY spike recommended SIGTERM then SIGKILL, and against /bin/sh that
        // is right. Against a real `claude` it is measurably wrong: the needsInput
        // spike found SIGTERM-then-SIGKILL NEVER reaped it (5/5 within 3s+3s),
        // because the CLI catches SIGTERM and keeps running, and a SIGKILL sent
        // afterwards leaves it wedged in macOS `E` (exiting) state — controlling
        // terminal already dropped — where waitpid never returns it. SIGKILL alone
        // reaped in 0.1s (3/3), producing a clean zombie.
        //
        // A panel that opens and closes owned sessions all day would otherwise
        // accumulate unreapable children for its whole lifetime. `graceful` exists
        // for the rare caller that genuinely wants the child to run its own exit
        // path, and accepts that teardown then cannot be confirmed.
        if graceful {
            send(SIGTERM)
            if let settled = wait(until: Date().addingTimeInterval(grace)) { return settled }
            log.notice("pty child \(self.pid) ignored SIGTERM; escalating to SIGKILL")
        }
        send(SIGKILL)
        if let settled = wait(until: Date().addingTimeInterval(killGrace)) { return settled }

        // Never block forever. An unreaped child is a leak we report, not a hang.
        log.error("pty child \(self.pid) survived SIGKILL within the grace period")
        return .running
    }

    private func send(_ signal: Int32) {
        if killpg(processGroup, signal) != 0 { _ = kill(pid, signal) }
    }

    private func wait(until deadline: Date) -> PTYExit? {
        while Date() < deadline {
            let current = status()
            if !current.isRunning { return current }
            usleep(5000)
        }
        let final = status()
        return final.isRunning ? nil : final
    }

    // MARK: C plumbing

    private static func cString(_ string: String) -> UnsafeMutablePointer<CChar> {
        string.withCString { strdup($0)! }
    }

    /// PATH resolution in the parent, so `execve` gets an absolute path and a
    /// missing binary is a thrown error instead of an exit code 127 five
    /// milliseconds later.
    static func resolve(_ executable: String) -> String? {
        if executable.contains("/") {
            return access(executable, X_OK) == 0 ? executable : nil
        }
        let path = ProcessInfo.processInfo.environment["PATH"]
            ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        for directory in path.split(separator: ":") where !directory.isEmpty {
            let candidate = "\(directory)/\(executable)"
            if access(candidate, X_OK) == 0 { return candidate }
        }
        return nil
    }

    /// (start time, command name) for a pid, straight from the kernel. Pids are
    /// recycled within minutes — the focus spike found the same about tty numbers —
    /// so a recorded pid is only safe to signal if this pair still matches.
    static func processIdentity(_ pid: pid_t) -> (start: TimeInterval, comm: String)? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else {
            return nil
        }
        let started = info.kp_proc.p_starttime
        let comm = withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return (Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000, comm)
    }
}

// MARK: - Owned session

/// A `claude` session the app spawned, supervised and may type into.
///
/// An actor because the two things that talk to it are asynchronous and unrelated:
/// the hook pump delivering `PermissionRequest`/`PostToolUse`, and the command keys
/// dispatching an action that then waits for one of those events. The waiting is a
/// poll loop over `Task.sleep`, which releases the actor at every suspension — so a
/// confirming event can land *while* an action is waiting for it. That property is
/// load-bearing; a lock-based wait here would deadlock against its own confirmation.
public actor OwnedSession {

    // MARK: Configuration

    /// The bytes we send for each answer. **A calibration knob, not a constant** — but
    /// no longer a guess, and deliberately containing no option number at all.
    ///
    /// The needsInput spike drove the real interactive TUI and captured the dialog:
    ///
    ///     ❯1. Yes
    ///      2. Yes, and don't ask again for: /bin/echo vcm-amber-probe *
    ///      3. No
    ///
    /// so `3` rejected *that* prompt. A prompt with a different option list puts "No"
    /// somewhere else, and on an approval dialog answering the wrong option is the
    /// worst failure available. `answer(_:suggestions:keys:)` explains why the payload
    /// cannot supply the index either. So both answers are layout-free:
    ///
    /// - `approve` is Return, which takes whichever option the CLI has **already**
    ///   selected — the plain "Yes" above, the one that grants nothing beyond this
    ///   call. It is also the keystroke the spike's `allow` run actually approved with.
    /// - `reject` is ESC, witnessed to cancel on both reject affordances and
    ///   independent of the option list.
    ///
    /// Still exactly one keystroke on approve, with no trailing Return, and now for
    /// two reasons rather than one: a stray Return would answer whatever dialog comes
    /// next, and here Return *is* the answer. A missing confirmation only lands in
    /// `.unconfirmed` and greys the key, which is the recoverable failure.
    public struct Keystrokes: Sendable, Equatable {
        public var approve: String
        public var reject: String
        public var submit: String

        public init(approve: String = "\r", reject: String = "\u{1b}", submit: String = "\r") {
            self.approve = approve
            self.reject = reject
            self.submit = submit
        }
    }

    public struct Configuration: Sendable {
        public var executable: String
        /// Our own hook file, passed as `--settings`. The hook spike's best find:
        /// full hook coverage with **zero writes** to the user's
        /// `~/.claude/settings.json`, which removes the consent problem for the half
        /// of the product that can act. Precedence is `user < project < local < flag
        /// < policy`, and this loads as `flag`, so the user's own hooks still run.
        public var settingsURL: URL
        public var workingDirectory: String?
        /// `--effort`: low, medium, high, xhigh, max.
        public var effort: String?
        public var extraArguments: [String]
        public var columns: UInt16
        public var rows: UInt16
        public var keys: Keystrokes
        /// How long an injected answer gets to be confirmed by a hook event before
        /// the action is recorded as unconfirmed and the key goes `unknown`.
        ///
        /// 5 s against measured hook latencies of 6–31 ms is not a latency budget —
        /// it is the window in which the *dialog closing* becomes observable. There
        /// is no event between `PermissionRequest` and the `PostToolUse` that fires
        /// when the approved tool finishes, so approving a slow `Bash` call cannot be
        /// confirmed inside any fixed window. The honest consequence is a key that
        /// goes grey and self-heals the moment the next hook arrives; the alternative
        /// is claiming an approval landed when the keystroke may have been discarded.
        /// Tune it once someone has measured a real session.
        public var confirmationWindow: TimeInterval

        public init(
            executable: String = "claude",
            settingsURL: URL = OwnedSession.defaultSettingsURL,
            workingDirectory: String? = nil,
            effort: String? = nil,
            extraArguments: [String] = [],
            columns: UInt16 = 120,
            rows: UInt16 = 32,
            keys: Keystrokes = Keystrokes(),
            confirmationWindow: TimeInterval = 5
        ) {
            self.executable = executable
            self.settingsURL = settingsURL
            self.workingDirectory = workingDirectory
            self.effort = effort
            self.extraArguments = extraArguments
            self.columns = columns
            self.rows = rows
            self.keys = keys
            self.confirmationWindow = confirmationWindow
        }
    }

    /// What the CLI accepts for `--effort`, in dial order. The dial sends a step
    /// index; anything outside the range is clamped rather than rejected, because a
    /// dial that silently does nothing at its extremes reads as broken.
    public static let effortLevels = ["low", "medium", "high", "xhigh", "max"]

    /// Readings from the session's own process, distinct from `claude.hooks`
    /// because the provenance differs and the tooltip says which source spoke. A
    /// forced `unknown` after an unconfirmed action must not be attributed to a hook
    /// that never fired.
    ///
    /// Register it before recording, or `StateEngine` rejects the reading as coming
    /// from an unknown source:
    ///
    ///     engine.register(OwnedSession.stateSource)
    public static let stateSource = StateSource(
        id: "claude.owned",
        confidence: .reported,
        reportableStates: [.running, .complete, .needsInput, .error, .unknown],
        stalenessThreshold: 15
    )

    // MARK: Pending permission

    /// The dialog we know is on screen, from `PermissionRequest` — which arrives
    /// 1 ms after it is painted, carries `tool_name`, `tool_input` and the exact
    /// `permission_suggestions` the dialog offers, and is unconditional. This is the
    /// entire licence to inject: without it we would be guessing, and a child using
    /// `TCSAFLUSH` discards guesses without a trace.
    public struct PendingPermission: Sendable, Equatable {
        public let toolName: String?
        public let toolInput: JSONValue?
        public let suggestions: JSONValue?
        /// When the hook fired, not when we read it.
        public let at: Date

        /// One line for the amber key's tooltip: what we are about to approve.
        public var summary: String {
            let tool = toolName ?? "a tool"
            if let command = toolInput?["command"]?.stringValue { return "\(tool): \(command)" }
            if let path = toolInput?["file_path"]?.stringValue { return "\(tool): \(path)" }
            return tool
        }
    }

    /// The bytes for one answer, or the reason there are none.
    public enum PermissionAnswer: Sendable, Equatable {
        case type(String)
        /// We will not type into this dialog, and why. A disabled key is acceptable;
        /// answering the wrong option is not.
        case refuse(String)
    }

    /// What to type to answer a dialog, derived from the dialog's own payload.
    ///
    /// **No option index is derived, because `permission_suggestions` does not carry
    /// one.** Witnessed in `spikes/needsinput` (`capture-allow/stream.txt` against the
    /// payload in `FINDINGS.md`): a **three**-option prompt — Yes / "Yes, and don't ask
    /// again for: …" / No — arrived with a `permission_suggestions` array of exactly
    /// **one** element, the `addRules` rule behind option 2. The array enumerates the
    /// rules the dialog offers to persist, not the options and not their order, so its
    /// count is not the option count and nothing in it locates "No". Deriving
    /// `2 + suggestions.count` from that single sample would be the same bet the
    /// hard-coded `3` was, in a costume, and it would be wrong in the one direction
    /// that matters: option 2 is a *broader* approval than option 1.
    ///
    /// So the payload does not choose the keystroke. What it does is act as a tripwire
    /// on the reasoning above: every suggestion measured is an object carrying
    /// `behavior: "allow"`, and anything else — a non-array, a non-object entry, a
    /// missing behavior, a `deny` suggestion — is a dialog shaped differently from the
    /// one this was checked against, so approve refuses instead of typing into it.
    ///
    /// Reject is offered either way. ESC cancels regardless of layout, it is the
    /// affordance the dialog itself advertises, and cancelling is the safe direction —
    /// the same asymmetry `verdict(for:from:)` is built on.
    static func answer(
        _ kind: InFlight.Kind, suggestions: JSONValue?, keys: Keystrokes
    ) -> PermissionAnswer {
        switch kind {
        case .reject:
            return .type(keys.reject)
        case .prompt:
            return .type(keys.submit)
        case .approve:
            if let problem = unmeasuredDialog(suggestions) { return .refuse(problem) }
            return .type(keys.approve)
        }
    }

    /// Why this payload is not the shape the approve keystroke was measured against, or
    /// `nil` when it is. Absent, null and empty all pass: a dialog with no rule to
    /// persist is the plain two-option Yes/No, which is the simpler case rather than a
    /// stranger one, and Return still takes its pre-selected option.
    static func unmeasuredDialog(_ suggestions: JSONValue?) -> String? {
        switch suggestions {
        case nil, .null:
            return nil
        case .array(let entries):
            for entry in entries {
                guard let fields = entry.objectValue else {
                    return "a permission_suggestions entry is not an object, so this dialog is not the shape approve was measured against"
                }
                guard let behavior = fields["behavior"]?.stringValue else {
                    return "a permission_suggestions entry carries no behavior, so we cannot tell what this dialog is offering"
                }
                guard behavior == "allow" else {
                    return "permission_suggestions offers behavior '\(behavior)', which no measured dialog did — refusing to approve rather than guess an option"
                }
            }
            return nil
        default:
            return "permission_suggestions is not an array, so we cannot tell what this dialog is offering"
        }
    }

    /// What became of a dispatched command.
    ///
    /// Reuses `ActivityEntry.ActionOutcome` rather than inventing a second
    /// vocabulary: the log's wording for an unconfirmed action is already the
    /// deliverable and is already asserted on, so this cannot drift away from what
    /// the user reads.
    public struct ActionReport: Sendable, Equatable {
        public let command: AgentCommand
        public let outcome: ActivityEntry.ActionOutcome
        /// Non-nil when the outcome itself dictates a state. `.unknown` for anything
        /// that went unconfirmed — we typed into the session and nothing witnessed
        /// it, so "we lost track" is the only truthful colour.
        public let forcedState: AgentState?

        /// **The one thing the UI may treat as success.** True only for a real
        /// confirming event. An unconfirmed reject must never reach a user as done,
        /// so no other case answers yes.
        public var isDone: Bool {
            if case .confirmed = outcome { return true }
            return false
        }

        /// The sentence shown in the activity strip and the key's tooltip, rendered
        /// by `ActivityEntry` so both surfaces tell one story.
        public var description: String {
            ActivityEntry(at: Date(), event: .action(command, outcome)).description
        }
    }

    // MARK: State

    /// The `--session-id` we generate, so identity is ours from the first byte and
    /// every hook event can be attributed without guessing.
    public let sessionID: String
    public private(set) var configuration: Configuration
    private var child: PTYChild?
    private var pending: PendingPermission?
    private var recordURL: URL?
    /// Set while an injected answer is waiting to be confirmed. `Task.sleep` in the
    /// wait loop releases the actor, so `noteHook` can fill this in from underneath.
    private var inFlight: InFlight?

    struct InFlight: Sendable {
        let kind: Kind
        let toolName: String?
        let injectedAt: Date
        var verdict: ActivityEntry.ActionOutcome?

        enum Kind: String, Sendable {
            case approve, reject, prompt
        }
    }

    public init(sessionID: String = UUID().uuidString, configuration: Configuration = Configuration()) {
        self.sessionID = sessionID
        self.configuration = configuration
    }

    // MARK: Lifecycle

    public var isRunning: Bool { child?.status().isRunning ?? false }
    public var pid: pid_t? { child?.pid }
    public var pendingPermission: PendingPermission? { pending }
    public var exitStatus: PTYExit { child?.status() ?? .running }
    public var liveness: Liveness { child?.liveness ?? .unknown }
    /// Raw TUI bytes for a terminal view. Not a state source — see the header.
    public var recentOutput: Data { child?.recentOutput ?? Data() }

    /// Spawns the session. Writes our hook settings file first if it is missing, so
    /// hook coverage never depends on the user having consented to anything.
    @discardableResult
    public func start() throws -> pid_t {
        guard child == nil else { return child!.pid }
        try Self.ensureSettings(at: configuration.settingsURL)

        var arguments = [
            "--settings", configuration.settingsURL.path,
            "--session-id", sessionID,
        ]
        if let effort = configuration.effort { arguments += ["--effort", effort] }
        arguments += configuration.extraArguments

        let spawned = try PTYChild.spawn(
            executable: configuration.executable,
            arguments: arguments,
            workingDirectory: configuration.workingDirectory,
            columns: configuration.columns,
            rows: configuration.rows
        )
        child = spawned
        recordURL = try? Self.writeRecord(for: spawned, sessionID: sessionID)
        log.notice("owned session \(self.sessionID, privacy: .public) running as pid \(spawned.pid)")
        return spawned.pid
    }

    /// `killpg` then `SIGKILL`, then forget the stray record. Synchronous on
    /// purpose: app quit has to be able to run this without an executor to hop to.
    @discardableResult
    public func stop(grace: TimeInterval = 2.0) -> PTYExit {
        // No child: either `start()` was never called or `stop()` already ran. Either
        // way there is nothing we can say about a process, which is what `.vanished`
        // means.
        guard let child else { return .vanished }
        let outcome = child.terminate(grace: grace)
        if let recordURL { try? FileManager.default.removeItem(at: recordURL) }
        recordURL = nil
        pending = nil
        inFlight = nil
        return outcome
    }

    @discardableResult
    public func resize(columns: UInt16, rows: UInt16) -> Bool {
        configuration.columns = columns
        configuration.rows = rows
        return child?.resize(columns: columns, rows: rows) ?? false
    }

    /// A reading for the engine derived from the process itself, or `nil` when the
    /// process has nothing to add. This is where "session died" and "session failed"
    /// stop being the same thing.
    ///
    /// A clean `exit(0)` returns `nil` deliberately: the hook stream's `SessionEnd`
    /// closes the slot, and a session the user quit is not an error.
    public func processReading() -> (state: AgentState, reason: String)? {
        guard let child else { return nil }
        switch child.status() {
        case .running, .exited(0), .terminatedByUs:
            return nil
        case .exited(let code):
            return (.error, "session failed: the CLI exited \(code)")
        case .crashed(let signal):
            return (.error, "session died: killed by SIG\(PTYExit.name(signal))")
        case .vanished:
            return (.unknown, "the CLI process was reaped by something else; outcome unknown")
        }
    }

    // MARK: Hook ingestion

    /// Feed every hook event here. Two jobs: track whether a permission dialog is
    /// open (the injection gate), and witness the confirmation of an action in
    /// flight.
    ///
    /// Events for other sessions and from subagents are dropped — a `SubagentStop`
    /// landed 3.8 s after the main `Stop` in the spike with the same `session_id`
    /// (gap G4), and letting it close a real dialog would unlatch the gate while the
    /// dialog was still on screen.
    @discardableResult
    public func noteHook(_ event: HookEvent) -> Bool {
        guard event.sessionID == sessionID else { return false }
        if let agentID = event.agentID, !agentID.isEmpty { return false }

        if let flight = inFlight, flight.verdict == nil {
            inFlight?.verdict = Self.verdict(for: flight, from: event)
        }

        switch event.name {
        case "PermissionRequest":
            pending = PendingPermission(
                toolName: event.toolName,
                toolInput: event.toolInput,
                suggestions: event.permissionSuggestions,
                at: event.observedAt
            )
        case "PostToolUse", "PostToolUseFailure", "PostToolBatch",
             "PermissionDenied", "Stop", "StopFailure", "UserPromptSubmit", "SessionEnd":
            pending = nil
        default:
            break
        }
        return true
    }

    /// The reject path's only witness, and it does not come from a hook.
    ///
    /// Rejecting a prompt emits no hook event at all (witnessed, `spikes/needsinput`),
    /// so nothing in `noteHook` can ever close the gate after one and `pending` would
    /// stay set for the life of the session — meaning the next `approve()` would type
    /// Return into whatever happened to be on screen. That is precisely the blind
    /// injection the gate exists to prevent, so the transcript's witness has to reach
    /// it: feed `ClaudeTranscriptSource.Reading.promptClearedAt` here.
    ///
    /// Strictly newer, for the same reason `StateEngine.clearNeedsInput` compares
    /// times: the marker stays inside the tailer's window for the next 80 records, so
    /// an old one must never close a dialog that opened after it.
    @discardableResult
    public func notePromptCleared(at time: Date) -> Bool {
        guard let dialog = pending, dialog.at < time else { return false }
        pending = nil
        return true
    }

    /// Which events count as confirmation, and the one case where an event proves
    /// the *opposite* of what we asked for.
    ///
    /// **Approval and rejection are not symmetric, and pretending otherwise is the
    /// failure this function exists to prevent.** An approval has a real witness:
    /// `PostToolUse` means the tool ran. A rejection has none — `PermissionDenied`
    /// never fired across 12 spike sessions (gap G6), so it is registered and
    /// believed if it ever arrives, and nothing else is accepted in its place.
    /// `Stop` after a reject would prove only that the turn ended, so treating it as
    /// confirmation would be exactly the guess the plan forbids.
    static func verdict(for flight: InFlight, from event: HookEvent) -> ActivityEntry.ActionOutcome? {
        let sameTool = flight.toolName != nil && event.toolName == flight.toolName

        switch flight.kind {
        case .approve:
            // The dialog closed and the turn moved on: the keystroke landed.
            if ["PostToolUse", "PostToolUseFailure", "PostToolBatch", "Stop", "StopFailure"]
                .contains(event.name) {
                return .confirmed(by: event.name)
            }
            if event.name == "PermissionDenied", sameTool {
                return .failed("PermissionDenied arrived for \(flight.toolName ?? "the tool") — the approval did not land")
            }
        case .reject:
            if event.name == "PermissionDenied" {
                return .confirmed(by: event.name)
            }
            // The worst outcome there is: we typed a rejection and the tool ran
            // anyway. Say so loudly instead of letting the window quietly expire.
            if ["PostToolUse", "PostToolUseFailure"].contains(event.name), sameTool {
                return .failed("\(event.name) says \(flight.toolName ?? "the tool") ran anyway — the rejection did not land")
            }
        case .prompt:
            if event.name == "UserPromptSubmit" { return .confirmed(by: event.name) }
        }
        return nil
    }

    // MARK: Commands

    /// The whole command surface behind one call, so wiring the keys (task 025) does
    /// not have to branch. `focus` and `newSession` belong to other owners and are
    /// reported as such rather than silently ignored.
    public func dispatch(_ command: AgentCommand) async -> ActionReport {
        switch command {
        case .approve:
            return await answerPermission(.approve, command: command)
        case .reject:
            return await answerPermission(.reject, command: command)
        case .sendPrompt(let text):
            return await send(prompt: text)
        case .setEffort(let step):
            return setEffort(step: step)
        case .focus:
            return ActionReport(command: command, outcome: .failed("focus is the window layer's job, not the pty's"), forcedState: nil)
        case .newSession:
            return ActionReport(command: command, outcome: .failed("a new session is a new OwnedSession, not a command on this one"), forcedState: nil)
        }
    }

    public func approve() async -> ActionReport { await dispatch(.approve) }
    public func reject() async -> ActionReport { await dispatch(.reject) }

    /// The gate. No `PermissionRequest`, no keystroke — not a retry, not a guess, not
    /// a fire-and-forget. A child that entered raw mode with `TCSAFLUSH` throws away
    /// anything queued before that call, silently, so an ungated write is
    /// indistinguishable from a working one.
    private func answerPermission(
        _ kind: InFlight.Kind,
        command: AgentCommand
    ) async -> ActionReport {
        guard let child, child.status().isRunning else {
            return ActionReport(
                command: command,
                outcome: .failed("the session is not running (\(exitStatus.describe))"),
                forcedState: processReading()?.state
            )
        }
        guard let dialog = pending else {
            return ActionReport(
                command: command,
                outcome: .failed("no permission prompt is open — nothing to answer"),
                forcedState: nil
            )
        }
        // Two presses, two keystrokes, and the second one answers whatever dialog
        // comes next. `pending` stays set until a hook closes it, so the in-flight
        // answer is the only thing that can stop a double injection.
        guard inFlight == nil else {
            return ActionReport(
                command: command,
                outcome: .failed("an answer is already waiting to be confirmed"),
                forcedState: nil
            )
        }

        // Derived from this dialog's payload, never from an option number. A payload we
        // cannot read disables approve instead of typing a digit into it.
        let keys: String
        switch Self.answer(kind, suggestions: dialog.suggestions, keys: configuration.keys) {
        case .type(let bytes):
            keys = bytes
        case .refuse(let why):
            return ActionReport(command: command, outcome: .failed(why), forcedState: nil)
        }

        inFlight = InFlight(kind: kind, toolName: dialog.toolName, injectedAt: Date(), verdict: nil)
        guard child.write(keys) else {
            inFlight = nil
            return ActionReport(
                command: command,
                outcome: .failed("the pty would not accept the keystroke"),
                forcedState: .unknown
            )
        }
        return await settle(command: command)
    }

    private func send(prompt text: String) async -> ActionReport {
        guard let child, child.status().isRunning else {
            return ActionReport(command: .sendPrompt(text), outcome: .failed("the session is not running"), forcedState: processReading()?.state)
        }
        guard pending == nil else {
            return ActionReport(
                command: .sendPrompt(text),
                outcome: .failed("a permission prompt is open; answer it before typing"),
                forcedState: nil
            )
        }
        inFlight = InFlight(kind: .prompt, toolName: nil, injectedAt: Date(), verdict: nil)
        guard child.write(text + configuration.keys.submit) else {
            inFlight = nil
            return ActionReport(command: .sendPrompt(text), outcome: .failed("the pty would not accept the prompt"), forcedState: .unknown)
        }
        return await settle(command: .sendPrompt(text))
    }

    /// `/effort <level>`. Fire and forget by necessity: no hook event witnesses an
    /// effort change (`ConfigChange` never fired in the spike), so this reports
    /// `.sent` and claims nothing more. Never `.confirmed`.
    private func setEffort(step: Int) -> ActionReport {
        let command = AgentCommand.setEffort(step)
        let level = Self.effortLevels[min(max(step, 0), Self.effortLevels.count - 1)]
        guard let child, child.status().isRunning else {
            return ActionReport(command: command, outcome: .failed("the session is not running"), forcedState: processReading()?.state)
        }
        guard pending == nil else {
            return ActionReport(command: command, outcome: .failed("a permission prompt is open; answer it before changing effort"), forcedState: nil)
        }
        guard child.write("/effort \(level)" + configuration.keys.submit) else {
            return ActionReport(command: command, outcome: .failed("the pty would not accept the slash command"), forcedState: .unknown)
        }
        return ActionReport(command: command, outcome: .sent, forcedState: nil)
    }

    /// Waits for `noteHook` to file a verdict, up to `confirmationWindow`.
    ///
    /// `Task.sleep` rather than a lock: it suspends and *releases* the actor, which
    /// is the only reason a confirming event can be processed while this is waiting.
    ///
    /// Sleep/wake is handled here by omission and on purpose. The deadline is wall
    /// clock, so a machine that sleeps through the window wakes up with the window
    /// already expired and the action recorded as unconfirmed — the safe direction.
    /// A monotonic clock that paused with the machine would instead keep waiting for
    /// an event that was delivered, or never sent, hours ago.
    private func settle(command: AgentCommand) async -> ActionReport {
        let deadline = Date().addingTimeInterval(configuration.confirmationWindow)
        while Date() < deadline {
            if let verdict = inFlight?.verdict {
                let injectedAt = inFlight?.injectedAt ?? Date()
                inFlight = nil
                if case .failed = verdict {
                    // A contradicted action is as uncertain as an unwitnessed one.
                    return ActionReport(command: command, outcome: verdict, forcedState: .unknown)
                }
                log.notice("owned \(self.sessionID, privacy: .public): action confirmed after \(Date().timeIntervalSince(injectedAt))s")
                return ActionReport(command: command, outcome: verdict, forcedState: nil)
            }
            try? await Task.sleep(for: .milliseconds(20))
        }

        // Nothing witnessed it. This is the reject path the plan calls out: there is
        // no proven signal that a rejection landed, so the action is recorded as
        // unconfirmed and the key goes grey. It must never be reported as done.
        let waited = Date().timeIntervalSince(inFlight?.injectedAt ?? deadline)
        inFlight = nil
        log.notice("owned \(self.sessionID, privacy: .public): action UNCONFIRMED after \(waited)s")
        return ActionReport(
            command: command,
            outcome: .unconfirmed(after: waited),
            forcedState: .unknown
        )
    }
}

// MARK: - Our own settings file

public extension OwnedSession {
    /// `--settings` target. Ours, under Application Support, never the user's.
    static let defaultSettingsURL = ClaudeHookInstaller.supportDirectory
        .appendingPathComponent("owned-settings.json")

    /// A *separate* forwarder from the one the installer puts in the user's
    /// settings, sharing the same spool. If the user uninstalls the observed-session
    /// hooks, `ClaudeHookInstaller.apply` deletes its own forwarder — and owned
    /// sessions would go blind with it, including the amber key, if they shared one
    /// script.
    static let forwarderURL = ClaudeHookInstaller.supportDirectory
        .appendingPathComponent("claude-hook-owned.sh")

    /// Writes the hook settings file and the forwarder it points at. Idempotent;
    /// touches nothing in `~/.claude`.
    static func ensureSettings(
        at url: URL = defaultSettingsURL,
        forwarderURL: URL = OwnedSession.forwarderURL,
        spoolDirectory: URL = ClaudeHookSource.defaultSpoolDirectory
    ) throws {
        let tree = try ClaudeHookInstaller.installing(into: .object([:]), forwarderPath: forwarderURL.path)
        let bytes = try tree.canonicalData()
        try ClaudeHookInstaller.installForwarder(at: forwarderURL, spoolDirectory: spoolDirectory)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if (try? Data(contentsOf: url)) == bytes { return }
        try bytes.write(to: url, options: .atomic)
    }
}

// MARK: - Strays

public extension OwnedSession {
    /// What a startup sweep found. Identified as needed by the spike and never
    /// built: if the app crashes, `killpg` never runs and the session plus its
    /// SIGHUP-ignoring grandchildren keep running with a pty nobody is draining.
    struct StraySweep: Sendable, Equatable {
        public var killed: [pid_t] = []
        /// Records whose pid is gone, or whose pid was recycled into somebody
        /// else's process. Deleted, never signalled.
        public var expired: Int = 0
        /// Records belonging to another live instance of this app. Left alone.
        public var foreign: Int = 0
        public var unreadable: Int = 0

        public var summary: String {
            "swept owned sessions: killed \(killed.count), expired \(expired), foreign \(foreign), unreadable \(unreadable)"
        }
    }

    static var recordDirectory: URL {
        ClaudeHookInstaller.supportDirectory.appendingPathComponent("owned-sessions", isDirectory: true)
    }

    /// One file per live owned session, deleted by `stop()`. Anything still here at
    /// launch was left by a crash.
    ///
    /// `start` is the kernel's start time for the pid. Pids are recycled within
    /// minutes, so without it a sweep can `killpg` a stranger's process group —
    /// the same class of bug the focus spike found with recycled tty numbers.
    static func writeRecord(for child: PTYChild, sessionID: String, in directory: URL = recordDirectory) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(sessionID).json")
        var fields: [String: JSONValue] = [
            "session_id": .string(sessionID),
            "pid": .int(Int(child.pid)),
            "owner_pid": .int(Int(getpid())),
            "spawned_at": .double(child.startedAt.timeIntervalSince1970),
        ]
        if let identity = child.identity {
            fields["start"] = .double(identity.start)
            fields["comm"] = .string(identity.comm)
        }
        try JSONValue.object(fields).canonicalData().write(to: url, options: .atomic)
        return url
    }

    /// Kill anything a previous run left behind, then clear the records.
    ///
    /// Call once at launch, before binding slots:
    ///
    ///     log.record(ActivityEntry(at: Date(), event: .note(OwnedSession.sweepStrays().summary)))
    @discardableResult
    static func sweepStrays(in directory: URL = recordDirectory, grace: TimeInterval = 1.0) -> StraySweep {
        var sweep = StraySweep()
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return sweep
        }

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let record = JSONValue.parse(data),
                  let pid = record["pid"]?.intValue.map(pid_t.init)
            else {
                sweep.unreadable += 1
                try? fm.removeItem(at: file)
                continue
            }

            // Another instance of the app is running and owns this child. Not ours
            // to kill, and not ours to forget either.
            if let owner = record["owner_pid"]?.intValue.map(pid_t.init),
               owner != getpid(), PTYChild.isAlive(owner) {
                sweep.foreign += 1
                continue
            }

            let identity = PTYChild.processIdentity(pid)
            let recordedStart = record["start"]
            let matches: Bool = switch (identity, recordedStart) {
            case (nil, _):
                false // the pid is gone
            case (let live?, .some(.double(let start))):
                abs(live.start - start) < 0.001
            case (.some, _):
                false // no recorded start time: refuse to signal on a bare pid
            }

            guard matches else {
                sweep.expired += 1
                try? fm.removeItem(at: file)
                continue
            }

            // SIGKILL directly, same reasoning as `terminate()`: the needsInput spike
            // measured SIGTERM-then-SIGKILL never reaping a real `claude` (5/5),
            // because it catches SIGTERM and a later SIGKILL wedges it in macOS `E`
            // state. I fixed that in terminate() and missed it here.
            //
            // It matters more in the sweep than in terminate(): a stray is by
            // definition already orphaned to launchd, so nothing will ever reap it if
            // it wedges. And there is no graceful case to preserve — a stray from a
            // previous crash has no exit path worth running.
            //
            // This also removes a grace loop whose timing made the check flaky under
            // load: with SIGTERM first, whether the stray died before the deadline
            // depended on machine load rather than on the code being right.
            if killpg(pid, SIGKILL) != 0 { _ = kill(pid, SIGKILL) }
            let deadline = Date().addingTimeInterval(grace)
            while Date() < deadline, PTYChild.isAlive(pid) { usleep(20_000) }
            // Not our child, so `waitpid` cannot reap it — its parent is `launchd`
            // now, which will.
            sweep.killed.append(pid)
            try? fm.removeItem(at: file)
        }

        if !sweep.killed.isEmpty || sweep.expired > 0 {
            log.notice("\(sweep.summary, privacy: .public)")
        }
        return sweep
    }
}

// MARK: - Self check

public extension OwnedSession {
    /// Human-readable failures, empty when healthy. Wire into `SelfCheck` with:
    ///
    ///     failures += OwnedSession.selfCheckFailures().map { "owned: \($0)" }
    ///
    /// Spawns `/bin/sh`, never `claude`: a real agent session costs seconds and
    /// tokens, and every mechanism worth asserting on — injection at t=0, the
    /// continuous drain, `killpg` reaching a grandchild, `waitpid` telling a crash
    /// from a failure, the unconfirmed-reject path — is a property of the pty and the
    /// gate, not of the program on the other end.
    ///
    /// Every wait has a deadline. Nothing here can hang the self check.
    static func selfCheckFailures() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }
        /// Polls instead of sleeping a fixed time, so a fast machine is fast and a
        /// loaded one still passes.
        func until(_ seconds: TimeInterval, _ ready: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if ready() { return true }
                usleep(5000)
            }
            return ready()
        }

        let realSettings = ClaudeHookInstaller.defaultSettingsURL
        let realBefore = try? Data(contentsOf: realSettings)

        // 1. The mechanism, cheapest possible proof: a command written before the
        //    child can have exec'd still runs, and we read its output back.
        //    `printf` with a format argument, so "vcm-ok" can only come from the
        //    child's output and never from the pty's echo of our own input.
        do {
            let child = try PTYChild.spawn(executable: "/bin/sh")
            check("resize on a live child failed", child.resize(columns: 100, rows: 40))
            check("injection at t=0 was refused", child.write("printf '%s\\n' vcm-ok\nexit 0\n"))
            check(
                "a command injected at t=0 produced no output",
                until(5) { child.recentOutputText.contains("vcm-ok") }
            )
            check("child did not exit cleanly: \(child.status().describe)", until(5) { child.status() == .exited(code: 0) })
            check("EOF was never observed on the master", child.sawEOF)
            check("resize after the pty hung up must fail, not lie", !child.resize(columns: 80, rows: 24))
            _ = child.terminate(grace: 0.2)
        } catch {
            failures.append("spawning /bin/sh threw: \(error)")
        }

        // 2. The continuous drain. 400 KB is far past any pty buffer, so a child
        //    writing it deadlocks in write() the moment the reader stops — which is
        //    how the spike's `vi` run first appeared to hang. The tail is capped, so
        //    this also proves the cap does not lose the byte count.
        do {
            let child = try PTYChild.spawn(
                executable: "/bin/sh",
                arguments: ["-c", "yes vcm-drain | head -c 400000; exit 0"],
                tailLimit: 64 * 1024
            )
            let finished = until(20) { !child.status().isRunning }
            check("a child writing 400KB never finished — the drain deadlocked", finished)
            check("child writing 400KB exited badly: \(child.status().describe)", child.status() == .exited(code: 0))
            check("drained \(child.bytesRead) bytes of 400000", child.bytesRead >= 400_000)
            check("the tail is not bounded: \(child.recentOutput.count) bytes", child.recentOutput.count <= 64 * 1024 + 16 * 1024)
            check("the bounded tail lost the content", child.recentOutputText.contains("vcm-drain"))
            _ = child.terminate(grace: 0.2)
        } catch {
            failures.append("drain check threw: \(error)")
        }

        // 3. Teardown reaches a grandchild that ignores SIGTERM. This is the shape of
        //    every MCP server, language server and node worker an agent CLI spawns:
        //    it keeps the child's PGID, so killpg is what gets it and the pty hangup
        //    never would.
        do {
            let script = """
            trap '' TERM
            ( trap '' TERM; while :; do sleep 1; done ) &
            echo "VCMGC=$!"
            while :; do sleep 1; done
            """
            let child = try PTYChild.spawn(executable: "/bin/sh", arguments: ["-c", script])
            var grandchild: pid_t = 0
            let announced = until(5) {
                let text = child.recentOutputText
                guard let marker = text.range(of: "VCMGC=") else { return false }
                let digits = text[marker.upperBound...].prefix { $0.isNumber }
                grandchild = pid_t(digits) ?? 0
                return grandchild > 0
            }
            check("the grandchild never announced its pid", announced)
            check("the grandchild is not running", grandchild > 0 && PTYChild.isAlive(grandchild))

            let outcome = child.terminate(grace: 0.3, killGrace: 2.0)
            check("a SIGTERM-ignoring child was not escalated to SIGKILL on the graceful path: \(outcome.describe)",
                  outcome == .terminatedByUs(signal: SIGKILL))
            check(
                "the grandchild survived teardown — killpg did not reach the process group",
                grandchild > 0 && until(3) { !PTYChild.isAlive(grandchild) }
            )
        } catch {
            failures.append("teardown check threw: \(error)")
        }

        // 4. waitpid separates a clean non-zero exit from a fatal signal, so
        //    "the session failed" and "the session died" can be different states.
        do {
            let failed = try PTYChild.spawn(executable: "/bin/sh", arguments: ["-c", "exit 3"])
            check("a non-zero exit was not read back as exited(3): \(failed.status().describe)",
                  until(5) { failed.status() == .exited(code: 3) })
            check("exited(3) does not read as a failure: '\(failed.status().describe)'",
                  failed.status().describe.contains("failed"))

            let died = try PTYChild.spawn(executable: "/bin/sh", arguments: ["-c", "kill -SEGV $$"])
            check("a fatal signal was not read back as crashed(SIGSEGV): \(died.status().describe)",
                  until(5) { died.status() == .crashed(signal: SIGSEGV) })
            check("crashed does not read as death: '\(died.status().describe)'",
                  died.status().describe.contains("died"))
            check("a crash and a non-zero exit are the same value", failed.status() != died.status())
            for child in [failed, died] { _ = child.terminate(grace: 0.1) }
        } catch {
            failures.append("exit-status check threw: \(error)")
        }

        // 5. Six concurrent children — the M2 target, and untested by the spike,
        //    which used one everywhere. Each gets its own needle so a crossed pty
        //    would show up as a missing or duplicated match rather than as nothing.
        do {
            var children: [PTYChild] = []
            for _ in 0 ..< 6 {
                children.append(try PTYChild.spawn(
                    executable: "/bin/sh",
                    arguments: ["-c", "read line; printf 'sixof%s\\n' \"$line\"; exit 0"]
                ))
            }
            for (index, child) in children.enumerated() {
                check("concurrent child \(index) refused input", child.write("c\(index)\n"))
            }
            for (index, child) in children.enumerated() {
                check(
                    "concurrent child \(index) produced no output of its own",
                    until(10) { child.recentOutputText.contains("sixofc\(index)") }
                )
                check("concurrent child \(index) did not exit cleanly: \(child.status().describe)",
                      until(10) { child.status() == .exited(code: 0) })
            }
            // Every pty is distinct: no child may see another's needle.
            for (index, child) in children.enumerated() {
                let text = child.recentOutputText
                for other in 0 ..< children.count where other != index {
                    check("child \(index) saw child \(other)'s output — the masters are crossed",
                          !text.contains("sixofc\(other)"))
                }
            }
            for child in children { _ = child.terminate(grace: 0.1) }
        } catch {
            failures.append("concurrency check threw: \(error)")
        }

        // 6. The gate and the confirmation paths. /bin/sh stands in for the agent:
        //    what is being asserted is that a keystroke is only ever written when a
        //    PermissionRequest says a dialog is open, and what happens when nothing
        //    confirms it.
        let fixtures = FileManager.default.temporaryDirectory
            .appendingPathComponent("vcm-owned-selfcheck-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixtures) }

        failures += gateFailures(fixtures: fixtures)

        // 7. Our settings file gives full hook coverage and never touches the user's.
        do {
            let settings = fixtures.appendingPathComponent("owned-settings.json")
            let forwarder = fixtures.appendingPathComponent("claude-hook-owned.sh")
            let spool = fixtures.appendingPathComponent("spool", isDirectory: true)
            try ensureSettings(at: settings, forwarderURL: forwarder, spoolDirectory: spool)
            let tree = JSONValue.parse(try Data(contentsOf: settings))
            for event in ClaudeHookInstaller.subscribedEvents {
                check("owned settings do not subscribe to \(event)", tree?["hooks"]?[event] != nil)
            }
            check("owned settings point at our own forwarder",
                  tree?["hooks"]?["PermissionRequest"]?.arrayValue?.first?["hooks"]?
                      .arrayValue?.first?["command"]?.stringValue == forwarder.path)
            check("the owned forwarder is not executable", FileManager.default.isExecutableFile(atPath: forwarder.path))
            let bytes = try Data(contentsOf: settings)
            try ensureSettings(at: settings, forwarderURL: forwarder, spoolDirectory: spool)
            check("writing owned settings twice changed the file", try Data(contentsOf: settings) == bytes)
            check("the owned forwarder must not be the installer's own file",
                  OwnedSession.forwarderURL != ClaudeHookInstaller.defaultForwarderURL)
        } catch {
            failures.append("owned settings threw: \(error)")
        }

        // 8. The stray sweep. A record whose pid is recycled must never be
        //    signalled, and one whose owner is alive is somebody else's business.
        do {
            let records = fixtures.appendingPathComponent("records", isDirectory: true)
            let victim = try PTYChild.spawn(executable: "/bin/sh", arguments: ["-c", "trap '' TERM; while :; do sleep 1; done"])
            let record = try writeRecord(for: victim, sessionID: "sweep-me", in: records)
            check("the record was not written", FileManager.default.fileExists(atPath: record.path))

            // A record for a pid that is alive but is NOT the process we recorded:
            // same pid, wrong start time. Killing this would kill a stranger.
            let recycled = records.appendingPathComponent("recycled.json")
            try JSONValue.object([
                "session_id": .string("recycled"),
                "pid": .int(Int(getpid())),
                "owner_pid": .int(Int(getpid())),
                "start": .double(1),
            ]).canonicalData().write(to: recycled)

            // A record owned by a live process that is not us: left alone entirely.
            let foreign = records.appendingPathComponent("foreign.json")
            try JSONValue.object([
                "session_id": .string("foreign"),
                "pid": .int(Int(victim.pid)),
                "owner_pid": .int(1), // launchd, always alive, never us
                "start": .double(victim.identity?.start ?? 0),
            ]).canonicalData().write(to: foreign)

            try Data("not json".utf8).write(to: records.appendingPathComponent("junk.json"))

            let sweep = sweepStrays(in: records, grace: 0.3)
            check("the sweep did not kill the stray: \(sweep.summary)", sweep.killed == [victim.pid])
            check("the stray survived the sweep", until(3) { !PTYChild.isAlive(victim.pid) })
            check("a recycled pid was signalled, not expired: \(sweep.summary)", sweep.expired == 1)
            check("the self check killed itself", PTYChild.isAlive(getpid()))
            check("a foreign record was claimed: \(sweep.summary)", sweep.foreign == 1)
            check("unreadable records were not counted: \(sweep.summary)", sweep.unreadable == 1)
            check("a foreign record was deleted", FileManager.default.fileExists(atPath: foreign.path))
            check("swept records were not cleared", !FileManager.default.fileExists(atPath: record.path))
            check("a second sweep found something", sweepStrays(in: records, grace: 0.1).killed.isEmpty)
            check("sweeping a directory that does not exist is not safe",
                  sweepStrays(in: fixtures.appendingPathComponent("nope")) == StraySweep())
            _ = victim.terminate(grace: 0.1)
        } catch {
            failures.append("stray sweep threw: \(error)")
        }

        // 9. The state source is one the engine will accept, and it can say the one
        //    thing an unconfirmed action needs it to say.
        var engine = StateEngine(sources: [stateSource])
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        check(
            "the engine rejects a forced unknown from claude.owned",
            engine.record(.unknown, for: "s", from: stateSource.id, observedAt: t0) == .accepted
        )
        check("a forced unknown does not resolve to unknown", engine.resolve("s", at: t0).state == .unknown)
        check("claude.owned must not be able to claim unassigned",
              !stateSource.reportableStates.contains(.unassigned))
        check("claude.owned must outrank transcript inference",
              stateSource.confidence > StateSource.claudeTranscript.confidence)

        // 10. Keystroke derivation (task 044). Pure, so it runs without a pty.
        //
        // The "three-option" payload is the real one from spikes/needsinput: three
        // options on screen (Yes / Yes-and-don't-ask / No) and exactly ONE suggestion.
        // That mismatch is the finding — a count cannot be an index — so what is
        // asserted is that neither answer contains an option number at all.
        let threeOption = JSONValue.array([.object([
            "type": .string("addRules"), "behavior": .string("allow"),
            "destination": .string("localSettings"),
            "rules": .array([.object([
                "toolName": .string("Bash"),
                "ruleContent": .string("/bin/echo vcm-amber-probe *"),
            ])]),
        ])])
        // Nothing to persist: the plain two-option Yes/No dialog.
        let twoOption = JSONValue.array([])
        let keys = Keystrokes()

        for (label, payload) in [("three-option", threeOption), ("two-option", twoOption)] {
            check("approve refused the \(label) payload",
                  answer(.approve, suggestions: payload, keys: keys) == .type(keys.approve))
            check("reject refused the \(label) payload",
                  answer(.reject, suggestions: payload, keys: keys) == .type(keys.reject))
        }
        check("approve refused a dialog with no suggestions field",
              answer(.approve, suggestions: nil, keys: keys) == .type(keys.approve))
        check("approve refused a null suggestions field",
              answer(.approve, suggestions: .null, keys: keys) == .type(keys.approve))

        // The whole point: no digit, and exactly one keystroke, so nothing can select
        // an option by position and nothing carries a trailing Return.
        for (label, bytes) in [("approve", keys.approve), ("reject", keys.reject)] {
            check("\(label) contains an option number", !bytes.contains(where: \.isNumber))
            check("\(label) is not a single keystroke", bytes.count == 1)
        }
        check("approve must be Return, which takes the dialog's own pre-selected option",
              keys.approve == "\r")
        check("reject must be ESC, which cancels regardless of the option list",
              keys.reject == "\u{1b}")

        // Payloads we cannot interpret: refuse, never guess. A deny suggestion counts —
        // no measured dialog carried one, so we do not know what its options are.
        let uninterpretable: [(String, JSONValue)] = [
            ("an entry that is not an object", .array([.string("allow")])),
            ("an entry with no behavior", .array([.object(["type": .string("addRules")])])),
            ("a deny suggestion", .array([.object(["behavior": .string("deny")])])),
            ("an unknown behavior", .array([.object(["behavior": .string("ask")])])),
            ("a bare object instead of an array", .object(["behavior": .string("allow")])),
            ("a string", .string("allow")),
            ("a number", .int(3)),
        ]
        for (label, payload) in uninterpretable {
            if case .refuse(let why) = answer(.approve, suggestions: payload, keys: keys) {
                check("refusing \(label) says nothing useful", why.count > 20)
            } else {
                failures.append("approve typed into \(label)")
            }
            // ESC still cancels whatever this is, and cancelling is the safe direction.
            check("reject was refused for \(label)",
                  answer(.reject, suggestions: payload, keys: keys) == .type(keys.reject))
        }

        // Effort levels are the CLI's own, and the dial cannot fall off either end.
        check("effort levels are not the CLI's list",
              effortLevels == ["low", "medium", "high", "xhigh", "max"])

        let after = try? Data(contentsOf: realSettings)
        check("the self check must not touch the real ~/.claude/settings.json", realBefore == after)

        return failures
    }

    /// A session whose "agent" is `/bin/sh`. Keystrokes land in a shell that ignores
    /// them, which is exactly right: what is under test is *when* we write, not what
    /// reads it.
    private static func gateSession(fixtures: URL, window: TimeInterval) -> OwnedSession {
        OwnedSession(
            sessionID: "11111111-2222-3333-4444-555555555555",
            configuration: Configuration(
                executable: "/bin/sh",
                settingsURL: fixtures.appendingPathComponent("gate-settings.json"),
                confirmationWindow: window
            )
        )
    }

    /// Split out because the gate is the part of this file that is actually about
    /// the product rather than about Unix, and because it needs to bridge one async
    /// boundary — kept in one place rather than sprinkled.
    private static func gateFailures(fixtures: URL) -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        /// The self check is synchronous (no XCTest on a CLT-only toolchain), and
        /// `OwnedSession` is an actor. Blocking the calling thread on a semaphore is
        /// safe here because nothing inside the actor needs the main actor, and the
        /// timeout means a bug cannot hang startup.
        func blocking<T: Sendable>(_ label: String, _ body: @escaping @Sendable () async -> T) -> T? {
            let box = OSAllocatedUnfairLock<T?>(initialState: nil)
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                let value = await body()
                box.withLock { $0 = value }
                done.signal()
            }
            if done.wait(timeout: .now() + 30) == .timedOut {
                failures.append("'\(label)' did not finish within 30s")
                return nil
            }
            return box.withLock { $0 }
        }

        let sessionID = "11111111-2222-3333-4444-555555555555"

        /// A real `HookEvent`, built the way the forwarder delivers one so the parse
        /// path is exercised rather than bypassed.
        func hook(
            _ name: String,
            tool: String? = nil,
            session: String = sessionID,
            agentID: String? = nil,
            suggestions: JSONValue = .array([.object(["behavior": .string("allow")])])
        ) -> HookEvent? {
            var payload: [String: JSONValue] = [
                "hook_event_name": .string(name),
                "session_id": .string(session),
                "permission_mode": .string("default"),
            ]
            if let tool {
                payload["tool_name"] = .string(tool)
                payload["tool_input"] = .object(["command": .string("/bin/rm -rf build")])
                payload["permission_suggestions"] = suggestions
            }
            if let agentID { payload["agent_id"] = .string(agentID) }
            guard let body = try? JSONValue.object(payload).canonicalData() else { return nil }
            return HookEvent.parse(body, observedAt: Date())
        }

        guard let request = hook("PermissionRequest", tool: "Bash"),
              let postToolUse = hook("PostToolUse", tool: "Bash"),
              let denied = hook("PermissionDenied", tool: "Bash"),
              let otherSession = hook("PermissionRequest", tool: "Bash", session: "someone-else"),
              let subagent = hook("PermissionRequest", tool: "Bash", agentID: "sub-1"),
              // A dialog whose payload we cannot read: approve must type nothing.
              let strange = hook(
                  "PermissionRequest", tool: "Bash",
                  suggestions: .array([.object(["behavior": .string("deny")])])
              )
        else { return failures + ["could not build the hook fixtures"] }

        // The gate: nothing is written until a PermissionRequest says a dialog is up,
        // and events for other sessions or from subagents do not open the gate.
        let gate = blocking("gate") { () -> [String] in
            var problems: [String] = []
            let owned = gateSession(fixtures: fixtures, window: 0.1)
            let child: PTYChild
            do {
                child = try PTYChild.spawn(executable: "/bin/sh")
            } catch {
                return ["gate fixture could not spawn /bin/sh: \(error)"]
            }
            await owned.adoptForSelfCheck(child)

            let ungated = await owned.approve()
            if case .failed = ungated.outcome {} else {
                problems.append("approve with no PermissionRequest produced \(ungated.outcome)")
            }
            if ungated.isDone { problems.append("an ungated approve reported done") }
            if child.bytesRead > 0 || child.writeFailures > 0 {
                problems.append("an ungated approve wrote to the pty")
            }

            if await owned.noteHook(otherSession) { problems.append("another session's event was accepted") }
            if await owned.noteHook(subagent) { problems.append("a subagent event was accepted") }
            if await owned.pendingPermission != nil {
                problems.append("a foreign or subagent event opened the injection gate")
            }

            _ = await owned.noteHook(request)
            guard let dialog = await owned.pendingPermission else {
                _ = child.terminate(grace: 0.1)
                return problems + ["PermissionRequest did not open the gate"]
            }
            if dialog.toolName != "Bash" { problems.append("the gate lost the tool name") }
            if !dialog.summary.contains("/bin/rm -rf build") {
                problems.append("the gate lost the command it is about to approve: '\(dialog.summary)'")
            }

            // THE REJECT PATH. Nothing confirms it, because nothing ever does:
            // PermissionDenied did not fire once across 12 spike sessions.
            let rejected = await owned.reject()
            if case .unconfirmed = rejected.outcome {} else {
                problems.append("an unwitnessed reject produced \(rejected.outcome)")
            }
            if rejected.forcedState != .unknown {
                problems.append("an unconfirmed reject did not drive the session to unknown")
            }
            if rejected.isDone { problems.append("an unconfirmed reject reported itself as done") }
            let text = rejected.description.lowercased()
            if !text.contains("unconfirmed") { problems.append("an unconfirmed reject does not say so: '\(text)'") }
            for claim in ["success", "succeeded", "confirmed by", "delivered", "applied", "done", "complete"] {
                if text.contains(claim) { problems.append("an unconfirmed reject claims '\(claim)': '\(text)'") }
            }
            if child.bytesRead == 0 { problems.append("a gated reject wrote nothing to the pty") }

            _ = child.terminate(grace: 0.1)
            return problems
        }
        failures += gate ?? []

        // Task 044 end to end: a dialog whose payload we cannot interpret gets NO
        // keystroke on approve, and ESC still works. The digit this replaced would have
        // been typed into it blind.
        let unreadable = blocking("unreadable payload") { () -> [String] in
            var problems: [String] = []
            let owned = gateSession(fixtures: fixtures, window: 0.1)
            guard let child = try? PTYChild.spawn(executable: "/bin/sh") else {
                return ["unreadable-payload fixture could not spawn /bin/sh"]
            }
            await owned.adoptForSelfCheck(child)
            _ = await owned.noteHook(strange)

            let report = await owned.approve()
            if case .failed(let why) = report.outcome {
                if !why.contains("behavior") { problems.append("the refusal does not name the payload: '\(why)'") }
            } else {
                problems.append("approve on an unreadable payload produced \(report.outcome)")
            }
            if report.isDone { problems.append("a refused approve reported done") }
            if child.bytesRead > 0 || child.writeFailures > 0 {
                problems.append("a refused approve wrote to the pty anyway")
            }
            // The asymmetry: cancelling is safe whatever the payload says.
            let rejected = await owned.reject()
            if case .failed = rejected.outcome { problems.append("reject was refused for an unreadable payload") }
            if child.bytesRead == 0 { problems.append("a gated reject wrote nothing to the pty") }
            _ = child.terminate(grace: 0.1)
            return problems
        }
        failures += unreadable ?? []

        // Task 043's other half. A rejection fires no hook, so `pending` would stay set
        // for the life of the session and the next approve would type into whatever is
        // on screen. The transcript's witness is the only thing that can close it.
        let gateAfterRejection = blocking("gate after rejection") { () -> [String] in
            var problems: [String] = []
            let owned = gateSession(fixtures: fixtures, window: 0.1)
            guard let child = try? PTYChild.spawn(executable: "/bin/sh") else {
                return ["rejection-gate fixture could not spawn /bin/sh"]
            }
            await owned.adoptForSelfCheck(child)
            _ = await owned.noteHook(request)
            if await owned.pendingPermission == nil { return problems + ["the gate did not open"] }

            // A marker older than the dialog is a leftover in the tail window, not this
            // dialog's rejection.
            if await owned.notePromptCleared(at: request.observedAt.addingTimeInterval(-1)) {
                problems.append("a stale rejection marker closed the gate")
            }
            if await owned.pendingPermission == nil {
                problems.append("a stale rejection marker cleared the pending dialog")
            }
            if await !owned.notePromptCleared(at: request.observedAt.addingTimeInterval(1)) {
                problems.append("a witnessed rejection did not close the gate")
            }
            if await owned.pendingPermission != nil {
                problems.append("the pending dialog survived a witnessed rejection")
            }
            let after = await owned.approve()
            if case .failed(let why) = after.outcome {
                if !why.contains("no permission prompt") {
                    problems.append("approve after a rejection failed for the wrong reason: '\(why)'")
                }
            } else {
                problems.append("approve after a witnessed rejection produced \(after.outcome)")
            }
            if child.bytesRead > 0 { problems.append("approve after a rejection typed into the session blind") }
            _ = child.terminate(grace: 0.1)
            return problems
        }
        failures += gateAfterRejection ?? []

        // A second press while the first answer is still in flight must not inject a
        // second keystroke: the dialog is already answered, so the extra key lands in
        // whatever comes next. `pending` cannot catch this — no hook has closed it
        // yet — so the in-flight guard is the only thing standing there.
        let doubled = blocking("double answer") { () -> [String] in
            var problems: [String] = []
            let owned = gateSession(fixtures: fixtures, window: 0.4)
            guard let child = try? PTYChild.spawn(executable: "/bin/sh") else {
                return ["double-answer fixture could not spawn /bin/sh"]
            }
            await owned.adoptForSelfCheck(child)
            _ = await owned.noteHook(request)

            let first = Task.detached { await owned.approve() }
            try? await Task.sleep(for: .milliseconds(60))
            let bytesAfterFirst = child.bytesRead
            let second = await owned.approve()
            if case .failed(let why) = second.outcome {
                if !why.contains("already") {
                    problems.append("a doubled answer was refused for the wrong reason: '\(why)'")
                }
            } else {
                problems.append("a second answer while one was in flight produced \(second.outcome)")
            }
            if second.isDone { problems.append("a refused second answer reported done") }
            if child.bytesRead != bytesAfterFirst {
                problems.append("a second answer wrote a second keystroke into the dialog")
            }
            _ = await first.value
            _ = child.terminate(grace: 0.1)
            return problems
        }
        failures += doubled ?? []

        // A reject that PermissionDenied does confirm, and an approve that
        // PostToolUse confirms. The confirming event is delivered while the action
        // is waiting, which only works because the wait releases the actor.
        for (label, confirming, command) in [
            ("reject", denied, AgentCommand.reject),
            ("approve", postToolUse, AgentCommand.approve),
        ] {
            let result = blocking("confirmed \(label)") { () -> [String] in
                var problems: [String] = []
                let owned = gateSession(fixtures: fixtures, window: 5)
                guard let child = try? PTYChild.spawn(executable: "/bin/sh") else {
                    return ["confirmed-\(label) fixture could not spawn /bin/sh"]
                }
                await owned.adoptForSelfCheck(child)
                _ = await owned.noteHook(request)

                let deliver = Task.detached {
                    try? await Task.sleep(for: .milliseconds(60))
                    _ = await owned.noteHook(confirming)
                }
                let report = await owned.dispatch(command)
                _ = await deliver.value

                if case .confirmed(let by) = report.outcome {
                    if by != confirming.name { problems.append("\(label) named the wrong witness: \(by)") }
                } else {
                    problems.append("a confirmed \(label) produced \(report.outcome)")
                }
                if !report.isDone { problems.append("a confirmed \(label) did not report done") }
                if report.forcedState != nil { problems.append("a confirmed \(label) forced a state anyway") }
                if await owned.pendingPermission != nil {
                    problems.append("\(label): the confirming event left the gate open")
                }
                _ = child.terminate(grace: 0.1)
                return problems
            }
            failures += result ?? []
        }

        // The worst case worth naming: we injected a rejection and the tool ran
        // anyway. That must not be an outcome the UI can read as "handled".
        let contradicted = blocking("contradicted reject") { () -> [String] in
            var problems: [String] = []
            let owned = gateSession(fixtures: fixtures, window: 5)
            guard let child = try? PTYChild.spawn(executable: "/bin/sh") else {
                return ["contradiction fixture could not spawn /bin/sh"]
            }
            await owned.adoptForSelfCheck(child)
            _ = await owned.noteHook(request)
            let deliver = Task.detached {
                try? await Task.sleep(for: .milliseconds(60))
                _ = await owned.noteHook(postToolUse)
            }
            let report = await owned.reject()
            _ = await deliver.value

            if case .failed(let why) = report.outcome {
                if !why.contains("ran anyway") { problems.append("a contradicted reject does not say the tool ran: '\(why)'") }
            } else {
                problems.append("a reject contradicted by PostToolUse produced \(report.outcome)")
            }
            if report.isDone { problems.append("a contradicted reject reported done") }
            if report.forcedState != .unknown { problems.append("a contradicted reject did not go to unknown") }
            _ = child.terminate(grace: 0.1)
            return problems
        }
        failures += contradicted ?? []

        // A dead session refuses everything and says why, rather than writing into a
        // closed fd and reporting success.
        let dead = blocking("dead session") { () -> [String] in
            var problems: [String] = []
            let owned = gateSession(fixtures: fixtures, window: 0.1)
            guard let child = try? PTYChild.spawn(executable: "/bin/sh", arguments: ["-c", "exit 4"]) else {
                return ["dead fixture could not spawn /bin/sh"]
            }
            await owned.adoptForSelfCheck(child)
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, child.status().isRunning { usleep(5000) }
            _ = await owned.noteHook(request)

            let report = await owned.approve()
            if case .failed = report.outcome {} else {
                problems.append("approve on a dead session produced \(report.outcome)")
            }
            if report.isDone { problems.append("approve on a dead session reported done") }
            if let reading = await owned.processReading() {
                if reading.state != .error { problems.append("exit 4 is not an error state") }
                if !reading.reason.contains("failed") { problems.append("exit 4 does not read as a failure: '\(reading.reason)'") }
            } else {
                problems.append("a session that exited 4 offered no reading")
            }
            return problems
        }
        failures += dead ?? []

        return failures
    }

    /// Self-check seam: attach a `/bin/sh` stand-in instead of spawning `claude`.
    /// Not a general entry point — `start()` is the only way a real session begins,
    /// and adopting a child here skips the stray record on purpose so a self-check
    /// run cannot leave one behind for the next launch to act on.
    internal func adoptForSelfCheck(_ child: PTYChild) {
        self.child = child
    }
}
