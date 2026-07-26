// ptyspike.swift — throwaway harness for T-VCMPLAN1-001 (M0 gate: PTY control of an owned agent session).
//
// BUILD (deliberately NOT part of Package.swift — spikes/ is outside Sources/VirtualCodexMicro,
// so SwiftPM never sees this file and the app build is unaffected):
//
//     swiftc -O -o /tmp/ptyspike spikes/pty/ptyspike.swift
//
// RUN:
//     /tmp/ptyspike <mode> [args...]
//
// Modes:
//     sh-basic            /bin/sh, write "echo hello" immediately after spawn, expect "hello" back
//     race <n>            n rounds of: spawn /bin/sh, write before it can have exec'd, check echo lands
//     vi                  spawn vi on a temp file, type immediately (mid-render), :wq, verify file bytes
//     noise <cmd...>       run cmd under a pty, dump escape-sequence statistics of the raw stream
//     prompt              run the fake-approval TUI stand-in (approval_stub.py), test detection + answer
//     crash <sig|exit>    child dies; report what the master fd and waitpid() say
//     orphan <cmd...>      spawn cmd under a pty then _exit(0) at once; prints child pid for an outside check
//     hangup <cmd...>      spawn cmd, close the master fd, report whether the child dies on its own
//     run <cmd...>         plain: spawn, stream output to stdout with a hard timeout, print exit status
//
// Every mode has a hard timeout. Nothing here waits forever.
//
// VERDICT (full writeup belongs in FINDINGS.md): RELIABLE WITH CAVEATS.
//   - Injection is deterministic: 30/30 rounds landed, including bytes written before the child
//     exec'd, and including into a mid-render full-screen TUI (vi test, verified on disk).
//   - Reading state back out of a TUI byte stream is NOT reliable: text written out of screen order
//     is invisible to substring matching, and one prompt yields ~60 identical hits that never
//     un-fire. Needs an embedded terminal emulator, or a structured channel instead.
//   - A child that enters raw mode with tcsetattr(TCSAFLUSH) silently DISCARDS input queued before
//     that call (mode `prompt --raw-when=flush --early` reproduces it). Never fire-and-forget an
//     accept keystroke.
//   - Use forkpty, not openpty + Foundation.Process: the latter gives no controlling terminal, so
//     closing the master does not hang up and every child is a guaranteed orphan (mode
//     `openpty-ctty`).
//   - Teardown must killpg + SIGKILL with a timeout. The pty hangup handles most cases but lost one
//     child in 66 runs, and never reaches SIGHUP-ignoring grandchildren.
//   - You must drain the master continuously or the child blocks in write() and looks hung.

import Darwin
import Foundation

// MARK: - pty plumbing

struct Child {
    let pid: pid_t
    let master: Int32
}

/// forkpty() + execvp(). The child gets a real controlling terminal (forkpty does setsid +
/// TIOCSCTTY for us), which openpty()+Foundation.Process does NOT — see FINDINGS.md.
func spawnPTY(_ argv: [String], cols: UInt16 = 100, rows: UInt16 = 30) -> Child {
    // Build the C argv BEFORE fork: no malloc between fork and exec.
    var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
    cargs.append(nil)
    setenv("TERM", "xterm-256color", 1)
    setenv("LINES", String(rows), 1)
    setenv("COLUMNS", String(cols), 1)

    var master: Int32 = -1
    var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
    let pid = forkpty(&master, nil, nil, &ws)
    if pid == 0 {
        execvp(cargs[0]!, &cargs)
        _exit(127) // exec failed
    }
    precondition(pid > 0, "forkpty failed: \(String(cString: strerror(errno)))")
    for p in cargs where p != nil { free(p) }
    return Child(pid: pid, master: master)
}

enum ReadEnd {
    case matched, timedOut, eof(errnoValue: Int32)
}

/// Reads from the master until `stop(buffer)` is true, or the deadline passes, or the pty hangs up.
/// Appends everything read to `sink`.
func pump(_ fd: Int32, deadline: Date, sink: inout [UInt8], stop: ([UInt8]) -> Bool = { _ in false }) -> ReadEnd {
    var buf = [UInt8](repeating: 0, count: 8192)
    while true {
        if stop(sink) { return .matched }
        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 { return .timedOut }
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let pr = poll(&pfd, 1, Int32(min(remaining * 1000, 1000)))
        if pr < 0 { if errno == EINTR { continue }; return .eof(errnoValue: errno) }
        if pr == 0 { continue }
        let n = read(fd, &buf, buf.count)
        if n > 0 {
            sink.append(contentsOf: buf[0..<n])
        } else if n == 0 {
            return .eof(errnoValue: 0)
        } else {
            if errno == EINTR || errno == EAGAIN { continue }
            return .eof(errnoValue: errno) // EIO on macOS = the slave side closed
        }
    }
}

func writeAll(_ fd: Int32, _ s: String) -> Int {
    let bytes = Array(s.utf8)
    var off = 0
    while off < bytes.count {
        let n = bytes[off...].withUnsafeBufferPointer { write(fd, $0.baseAddress!, $0.count) }
        if n <= 0 { if errno == EINTR { continue }; return -1 }
        off += n
    }
    return off
}

struct Wait { let raw: Int32
    var exited: Bool { (raw & 0x7f) == 0 }
    var exitCode: Int32 { (raw >> 8) & 0xff }
    var signalled: Bool { (raw & 0x7f) != 0 && (raw & 0x7f) != 0x7f }
    var signal: Int32 { raw & 0x7f }
    var describe: String {
        if exited { return "exited(\(exitCode))" }
        if signalled { return "signalled(SIG\(signalName(signal)))" }
        return "raw(\(raw))"
    }
}

func signalName(_ s: Int32) -> String {
    switch s {
    case SIGSEGV: return "SEGV"; case SIGHUP: return "HUP"; case SIGTERM: return "TERM"
    case SIGKILL: return "KILL"; case SIGPIPE: return "PIPE"; case SIGABRT: return "ABRT"
    default: return "NUM\(s)"
    }
}

/// waitpid with a deadline, so a wedged child can never wedge the harness.
func reap(_ pid: pid_t, timeout: TimeInterval) -> Wait? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        var status: Int32 = 0
        let r = waitpid(pid, &status, WNOHANG)
        if r == pid { return Wait(raw: status) }
        if r < 0 { return nil }
        usleep(10_000)
    }
    return nil
}

func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

// MARK: - escape-sequence analysis

struct Noise {
    var totalBytes = 0
    var printableBytes = 0
    var csiCount = 0        // ESC [ ...
    var oscCount = 0        // ESC ] ... BEL/ST
    var otherEsc = 0
    var cursorMoves = 0     // CUP/CUU/CUD/CUF/CUB/HVP
    var eraseOps = 0        // ED/EL
    var altScreenEnter = 0  // ESC [ ? 1049 h
    var altScreenLeave = 0  // ESC [ ? 1049 l
    var carriageReturns = 0
    var reads = 0
}

/// Strips ANSI escapes and returns (plainText, stats). Deliberately naive — that is the point:
/// this is exactly the "just grep the stream" approach we are trying to evaluate.
func analyze(_ bytes: [UInt8], reads: Int = 0) -> (plain: String, noise: Noise) {
    var n = Noise(); n.totalBytes = bytes.count; n.reads = reads
    var out = [UInt8]()
    var i = 0
    while i < bytes.count {
        let b = bytes[i]
        if b == 0x1b { // ESC
            if i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "[") {
                n.csiCount += 1
                var j = i + 2
                var params = [UInt8]()
                while j < bytes.count, bytes[j] < 0x40 || bytes[j] > 0x7e { params.append(bytes[j]); j += 1 }
                let final = j < bytes.count ? bytes[j] : 0
                let p = String(decoding: params, as: UTF8.self)
                switch Character(UnicodeScalar(final == 0 ? 0x20 : final)) {
                case "H", "f", "A", "B", "C", "D", "G", "d": n.cursorMoves += 1
                case "J", "K": n.eraseOps += 1
                case "h" where p == "?1049": n.altScreenEnter += 1
                case "l" where p == "?1049": n.altScreenLeave += 1
                default: break
                }
                i = j + 1
                continue
            } else if i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "]") {
                n.oscCount += 1
                var j = i + 2
                while j < bytes.count, bytes[j] != 0x07, !(bytes[j] == 0x1b && j + 1 < bytes.count && bytes[j + 1] == 0x5c) { j += 1 }
                i = (j < bytes.count && bytes[j] == 0x07) ? j + 1 : j + 2
                continue
            } else {
                n.otherEsc += 1; i += 2; continue
            }
        }
        if b == 0x0d { n.carriageReturns += 1 }
        if b >= 0x20 || b == 0x0a || b == 0x09 { n.printableBytes += 1; out.append(b) }
        i += 1
    }
    return (String(decoding: out, as: UTF8.self), n)
}

func report(_ n: Noise) {
    print("""
      bytes=\(n.totalBytes) printable=\(n.printableBytes) (\(n.totalBytes == 0 ? 0 : n.printableBytes * 100 / n.totalBytes)%) reads=\(n.reads)
      CSI=\(n.csiCount) OSC=\(n.oscCount) otherESC=\(n.otherEsc) cursorMoves=\(n.cursorMoves) erase=\(n.eraseOps) CR=\(n.carriageReturns)
      altScreen enter=\(n.altScreenEnter) leave=\(n.altScreenLeave)
    """)
}

// MARK: - modes

let args = Array(CommandLine.arguments.dropFirst())
guard let mode = args.first else { print("usage: ptyspike <mode> [args]"); exit(2) }
let rest = Array(args.dropFirst())

func ok(_ c: Bool) -> String { c ? "PASS" : "FAIL" }

switch mode {

// 1. Cheapest possible proof the mechanism works at all.
case "sh-basic":
    let c = spawnPTY(["/bin/sh"])
    // Both lines written before the child can even have exec'd. printf with a format arg so
    // "hello" can only appear in sh's OUTPUT, not in the pty's echo of our input.
    _ = writeAll(c.master, "printf '%s\\n' hello\nexit\n")
    var sink = [UInt8]()
    let end = pump(c.master, deadline: Date().addingTimeInterval(3), sink: &sink)
    let w = reap(c.pid, timeout: 2)
    close(c.master)
    let text = String(decoding: sink, as: UTF8.self)
    print("read end: \(end) \(errnoName(end))")
    print("raw: \(text.debugDescription)")
    print("waitpid: \(w?.describe ?? "TIMED OUT")")
    print("\(ok(text.contains("hello\r\n"))) sh-basic: command injected at t=0 executed, output read back")

// 2. Does input written before the child has drawn anything survive? Repeat to catch flakiness.
case "race":
    let rounds = Int(rest.first ?? "20") ?? 20
    var passes = 0
    var firstByteDelays = [Double]()
    for i in 0..<rounds {
        let c = spawnPTY(["/bin/sh"])
        let t0 = Date()
        // zero delay: the child has not exec'd yet, let alone printed a prompt.
        // printf with a format arg, so the needle "R<i>-ok" can only come from sh's OUTPUT,
        // never from the pty's echo of our own input.
        _ = writeAll(c.master, "printf 'R\(i)-%s\\n' ok\n")
        var sink = [UInt8]()
        let end = pump(c.master, deadline: Date().addingTimeInterval(5), sink: &sink) {
            String(decoding: $0, as: UTF8.self).contains("R\(i)-ok\r\n")
        }
        if case .matched = end { passes += 1; firstByteDelays.append(Date().timeIntervalSince(t0)) }
        else { print("  round \(i) \(end) raw=\(String(decoding: sink, as: UTF8.self).debugDescription)") }
        _ = writeAll(c.master, "exit\n")
        _ = reap(c.pid, timeout: 2)
        close(c.master)
    }
    let avg = firstByteDelays.isEmpty ? 0 : firstByteDelays.reduce(0, +) / Double(firstByteDelays.count)
    let worst = firstByteDelays.max() ?? 0
    print(String(format: "%@ race: %d/%d rounds landed. spawn→echo avg %.1fms worst %.1fms",
                 ok(passes == rounds), passes, rounds, avg * 1000, worst * 1000))

// 3. Full-screen TUI, alternate screen, redraws. Type immediately, verify the effect on disk.
case "vi":
    let path = "/tmp/ptyspike-vi-\(getpid()).txt"
    try? FileManager.default.removeItem(atPath: path)
    let c = spawnPTY(["/usr/bin/vi", "-u", "NONE", path])
    // Zero-delay injection: vi has not drawn its screen yet (probably not even exec'd).
    _ = writeAll(c.master, "iinjected-mid-render\u{1b}")
    var sink = [UInt8]()
    _ = pump(c.master, deadline: Date().addingTimeInterval(2), sink: &sink) {
        String(decoding: $0, as: UTF8.self).contains("injected-mid-render")
    }
    _ = writeAll(c.master, ":wq\r")
    // Drain to EOF FIRST. Calling waitpid() while not reading the master deadlocks: the pty
    // buffer fills, the child blocks in write(), and it can never reach exit(). See FINDINGS.md.
    _ = pump(c.master, deadline: Date().addingTimeInterval(5), sink: &sink)
    let w = reap(c.pid, timeout: 3)
    close(c.master)
    let onDisk = (try? String(contentsOfFile: path, encoding: .utf8)) ?? "<no file>"
    let (plain, noise) = analyze(sink)
    print("waitpid: \(w?.describe ?? "TIMED OUT")")
    report(noise)
    print("file on disk: \(onDisk.debugDescription)")
    print("naive-stripped screen text contains the typed string: \(plain.contains("injected-mid-render"))")
    print("\(ok(onDisk.trimmingCharacters(in: .whitespacesAndNewlines) == "injected-mid-render")) vi: keystrokes landed during render")

// 4. What does a redrawing TUI's byte stream actually look like?
case "noise":
    guard !rest.isEmpty else { print("noise <cmd...>"); exit(2) }
    let secs = Double(ProcessInfo.processInfo.environment["SPIKE_SECS"] ?? "3") ?? 3
    let c = spawnPTY(rest)
    var sink = [UInt8]()
    var reads = 0
    let deadline = Date().addingTimeInterval(secs)
    // count reads by pumping in small slices
    while Date() < deadline {
        let before = sink.count
        _ = pump(c.master, deadline: min(deadline, Date().addingTimeInterval(0.05)), sink: &sink)
        if sink.count > before { reads += 1 }
    }
    _ = writeAll(c.master, "q")             // top/less quit
    _ = writeAll(c.master, "\u{03}")        // then SIGINT via the line discipline
    let w = reap(c.pid, timeout: 2)
    if w == nil { kill(c.pid, SIGKILL); _ = reap(c.pid, timeout: 1) }
    close(c.master)
    let (plain, noise) = analyze(sink, reads: reads)
    print("cmd: \(rest.joined(separator: " "))  ran \(secs)s  waitpid=\(w?.describe ?? "killed")")
    report(noise)
    print("--- first 400 chars of naive-stripped text ---")
    print(String(plain.prefix(400)))

// 5. The real question: can a pending-approval prompt be detected from the stream, and answered?
// prompt <stubPath> [--raw-when=drain|flush|now] [--early]
//   --early: inject the answer at t=0, before the child has drawn anything, to test whether
//            input queued during a render survives the child's tcsetattr().
case "prompt":
    let stub = rest.first ?? "spikes/pty/approval_stub.py"
    let early = rest.contains("--early")
    let stubArgs = rest.dropFirst().filter { $0.hasPrefix("--raw-when=") }
    let c = spawnPTY(["/usr/bin/env", "python3", stub] + stubArgs)
    var sink = [UInt8]()
    let needle = "Do you want to proceed?"
    var detectedAt: Date?
    let t0 = Date()
    if early { _ = writeAll(c.master, "1\r") }
    let end = pump(c.master, deadline: Date().addingTimeInterval(6), sink: &sink) { b in
        if String(decoding: b, as: UTF8.self).contains(needle) { detectedAt = Date(); return true }
        return false
    }
    let rawDetect = detectedAt != nil
    print("mode: \(early ? "EARLY injection (answer written at t=0)" : "reactive (answer written after detection)"), stubArgs=\(stubArgs.joined(separator: " "))")
    // Also try detection on the naively-stripped text, and on a per-frame basis.
    let (plainSoFar, _) = analyze(sink)
    print("raw-stream substring match for \(needle.debugDescription): \(rawDetect) (\(end))")
    print("stripped-text substring match: \(plainSoFar.contains(needle))")
    if let d = detectedAt { print(String(format: "detect latency from spawn: %.0fms", d.timeIntervalSince(t0) * 1000)) }
    // The second question the prompt asks is split by a cursor move mid-sentence.
    let split = "Apply this patch"
    print("split-across-escapes needle \(split.debugDescription): raw=\(String(decoding: sink, as: UTF8.self).contains(split)) stripped=\(plainSoFar.contains(split))")
    // Answer it: option "1" then Enter, the same shape as a Claude Code approval.
    if !early { _ = writeAll(c.master, "1\r") }
    _ = pump(c.master, deadline: Date().addingTimeInterval(8), sink: &sink) {
        String(decoding: $0, as: UTF8.self).contains("ANSWER=")
    }
    let w = reap(c.pid, timeout: 3)
    if w == nil { kill(c.pid, SIGKILL) }
    close(c.master)
    let (plain, noise) = analyze(sink)
    report(noise)
    let answered = plain.contains("ANSWER=1")
    print("stub reported: \(plain.split(separator: "\n").filter { $0.contains("ANSWER=") }.joined())")
    print("\(ok(rawDetect)) prompt: pending approval visible in raw stream")
    print("\(ok(answered)) prompt: injected answer accepted")

// 6. Child crash / non-zero exit.
case "crash":
    let what = rest.first ?? "segv"
    let script: String
    switch what {
    case "segv": script = "kill -SEGV $$"
    case "exit": script = "exit 3"
    case "wedge": script = "trap '' TERM INT; while :; do sleep 1; done"
    default: script = what
    }
    let c = spawnPTY(["/bin/sh", "-c", script])
    var sink = [UInt8]()
    let end = pump(c.master, deadline: Date().addingTimeInterval(3), sink: &sink)
    let w = reap(c.pid, timeout: 3)
    print("case=\(what) readEnd=\(end) errnoName=\(errnoName(end)) waitpid=\(w?.describe ?? "TIMED OUT (still running)")")
    print("child still alive after read end: \(alive(c.pid))")
    if w == nil { kill(c.pid, SIGKILL); _ = reap(c.pid, timeout: 1); print("escalated to SIGKILL: reaped=\(alive(c.pid) == false)") }
    close(c.master)

// 7. Parent dies without cleaning up. Prints the pid so a shell can check from outside.
case "orphan":
    let cmd = rest.isEmpty ? ["/bin/sh", "-c", "sleep 300"] : rest
    let c = spawnPTY(cmd)
    // SPIKE_DELAY_MS: how long the parent lives before _exit(0). 0 = exit before the child has
    // finished setsid()/TIOCSCTTY, which changes the outcome. See FINDINGS.md.
    let delayMS = UInt32(ProcessInfo.processInfo.environment["SPIKE_DELAY_MS"] ?? "0") ?? 0
    print("child_pid=\(c.pid) parent_pid=\(getpid()) delay=\(delayMS)ms — parent will _exit(0) WITHOUT killing the child")
    fflush(stdout)
    if delayMS > 0 { usleep(delayMS * 1000) }
    _exit(0) // hardest case: no atexit, no deinit, no signal handler

// 8. Same, but we close the master fd (pty hangup) and see if that is enough.
case "hangup":
    let cmd = rest.isEmpty ? ["/bin/sh", "-c", "sleep 300"] : rest
    let c = spawnPTY(cmd)
    usleep(300_000)
    print("child_pid=\(c.pid); closing master fd now")
    close(c.master)
    let w = reap(c.pid, timeout: 3)
    print("waitpid after master close: \(w?.describe ?? "TIMED OUT — child survived the hangup")")
    print("alive: \(alive(c.pid))")
    if w == nil { kill(c.pid, SIGKILL); _ = reap(c.pid, timeout: 1) }

// 9. Generic: run something under a pty with a hard timeout, stream it, report exit.
case "run":
    guard !rest.isEmpty else { print("run <cmd...>"); exit(2) }
    let secs = Double(ProcessInfo.processInfo.environment["SPIKE_SECS"] ?? "20") ?? 20
    let c = spawnPTY(rest)
    var sink = [UInt8]()
    let end = pump(c.master, deadline: Date().addingTimeInterval(secs), sink: &sink)
    var w = reap(c.pid, timeout: 2)
    if w == nil { kill(c.pid, SIGKILL); w = reap(c.pid, timeout: 2) }
    close(c.master)
    let (plain, noise) = analyze(sink)
    print("cmd: \(rest.joined(separator: " "))  readEnd=\(end) waitpid=\(w?.describe ?? "unreaped")")
    report(noise)
    print("--- stripped output ---")
    print(plain)

// 10. The OTHER spawn path: openpty() + Foundation.Process. Simpler Swift, but Process gives no
//     hook to call setsid()/TIOCSCTTY, so the child gets a tty on fd 0/1/2 without it being its
//     CONTROLLING terminal. Compare the session/tty columns and the hangup behaviour with forkpty.
case "openpty-ctty":
    var m: Int32 = 0, s: Int32 = 0
    var ws = winsize(ws_row: 30, ws_col: 100, ws_xpixel: 0, ws_ypixel: 0)
    guard openpty(&m, &s, nil, nil, &ws) == 0 else { print("openpty failed"); exit(1) }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", rest.first ?? "tty; ps -o pid,ppid,pgid,sess,tty,stat,command -p $$; sleep 300"]
    let slave = FileHandle(fileDescriptor: s, closeOnDealloc: false)
    p.standardInput = slave; p.standardOutput = slave; p.standardError = slave
    try! p.run()
    close(s) // parent must drop the slave, else EOF never arrives
    var sink = [UInt8]()
    _ = pump(m, deadline: Date().addingTimeInterval(1.5), sink: &sink)
    print("--- child's own view of its tty (via openpty + Foundation.Process) ---")
    print(analyze(sink).plain)
    print("closing master fd; does the child get SIGHUP?")
    close(m)
    let w = reap(p.processIdentifier, timeout: 3)
    print("waitpid: \(w?.describe ?? "TIMED OUT — child SURVIVED the hangup")")
    print("alive: \(alive(p.processIdentifier))")
    if w == nil { kill(p.processIdentifier, SIGKILL); _ = reap(p.processIdentifier, timeout: 1) }

default:
    print("unknown mode \(mode)")
    exit(2)
}

func errnoName(_ e: ReadEnd) -> String {
    guard case .eof(let v) = e else { return "-" }
    switch v {
    case 0: return "clean EOF"
    case EIO: return "EIO (slave side gone — normal pty child-exit signal)"
    default: return String(cString: strerror(v))
    }
}
