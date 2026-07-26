import Foundation

/// Adds and removes this app's hook entries in `~/.claude/settings.json`.
///
/// This is the only code in the project that writes a file the user did not create
/// and cannot easily repair, and a half-written settings file stops their Claude
/// Code from starting. So the rules here are not preferences:
///
/// - **Append to `hooks.<Event>[]`, never replace.** The M0 spike proved additive
///   merging works — the machine's existing `PreToolUse` hook and the spike's both
///   ran on every Bash call, and the user's own rewriting still worked.
/// - **Never run without consent.** `plan(_:)` computes the change and returns it as
///   a diff; `apply(_:)` is a separate call. Nothing here is invoked at startup.
/// - **Back up, then write atomically.** `.atomic` is a write to a temp sibling
///   followed by `rename(2)`, so the real file is never observed half-written.
/// - **Idempotent, and reversible.** Installing twice adds nothing; uninstalling
///   removes our entries and nothing else.
///
/// Every entry is a `command` hook with `async: true`, from gap G5: hooks block the
/// state transition they fire on, and a wedged listener slowing down somebody's
/// agent is a worse failure than a stale colour on a key. `async` is a real
/// optional boolean on the CLI's command-hook schema in 2.1.220 — checked against
/// the binary's own zod definition, not the docs. `SessionStart` had to be a
/// `command` hook anyway (gap G1: `http` receives zero SessionStart events), and it
/// is the only place `CLAUDE_PID` comes from.
public struct ClaudeHookInstaller: Sendable {
    public enum Action: Sendable, Equatable {
        case install
        case uninstall
    }

    public enum PlanError: Error, CustomStringConvertible {
        /// Includes a settings file with comments: Claude Code reads its own config
        /// as JSONC, we do not, and rewriting one would silently delete the user's
        /// comments. Refusing is the safe direction.
        case malformedJSON(URL)
        case notAnObject(URL)
        /// Something under `hooks` is not shaped the way the schema says. We stop
        /// rather than "fix" it, because overwriting it would destroy user config.
        case unexpectedShape(String)

        public var description: String {
            switch self {
            case .malformedJSON(let url):
                "\(url.path) is not plain JSON (comments and trailing commas are not handled) — refusing to rewrite it"
            case .notAnObject(let url):
                "\(url.path) does not contain a JSON object at the top level"
            case .unexpectedShape(let detail):
                "unexpected shape in settings: \(detail)"
            }
        }
    }

    /// Everything the consent UI (task 030) needs to show, and everything `apply`
    /// needs to act. Computing it touches nothing.
    public struct Plan: Sendable {
        public let action: Action
        public let settingsURL: URL
        public let backupURL: URL
        public let forwarderURL: URL
        public let spoolDirectory: URL
        public let events: [String]
        /// Line diff of the file as it will be written against the file as it is.
        /// Empty when `isNoOp`.
        public let diff: String
        /// True when the settings tree is already exactly as we want it. `apply`
        /// returns immediately, writing nothing and backing up nothing.
        public let isNoOp: Bool
        /// True when applying will also re-indent and key-sort the rest of the file.
        /// Semantically identical, visibly different — say so before writing.
        public let reformatsFile: Bool
        public let newContents: Data
    }

    // MARK: - Paths

    public static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("VirtualCodexMicro", isDirectory: true)
    }()

    public static let defaultSettingsURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".claude/settings.json")

    /// The forwarder CANNOT live in Application Support, and this is a bug that
    /// shipped and had to be found by running it.
    ///
    /// Claude Code invokes a command hook through a shell, so a command string
    /// containing a space is split: `~/Library/Application Support/...` becomes an
    /// attempt to run `~/Library/Application` with `Support/...` as an argument. It
    /// fails, and because these are `async: true` hooks the failure is discarded —
    /// no error anywhere, no events, nothing to debug. The installer's own check
    /// passed the whole time because it invoked the script via `/bin/sh` directly,
    /// which works fine; only Claude Code's own invocation path breaks.
    ///
    /// So: a dedicated whitespace-free directory of our own. Not `~/.claude/hooks`,
    /// which is the user's, and not Application Support, which has the space. The
    /// spool stays in Application Support — nothing but our own code opens it.
    public static let forwarderDirectory = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".virtual-codex-micro", isDirectory: true)

    public static let defaultForwarderURL = forwarderDirectory
        .appendingPathComponent("claude-hook.sh")

    /// Paths we used to install to and must still clean up on uninstall, or an
    /// upgrade leaves a dead hook entry pointing at a script nobody removes.
    public static let legacyForwarderURLs: [URL] = [
        supportDirectory.appendingPathComponent("claude-hook.sh")
    ]

    /// A command hook's path must survive being handed to a shell. Whitespace is
    /// the failure we hit; the quoting characters would break the same way.
    public static func isShellSafe(_ url: URL) -> Bool {
        let path = url.path
        return !path.isEmpty && !path.contains(where: { $0.isWhitespace })
            && !path.contains("'") && !path.contains("\"")
    }

    // MARK: - What we subscribe to

    /// The eleven events with a disposition worth registering, out of the CLI's 31.
    /// Registering the other twenty would spawn a process per render event for
    /// nothing.
    ///
    /// `StopFailure` and `PostToolUseFailure` are here despite being **unverified** —
    /// neither fired in 12 spike sessions. Registering them costs nothing and is the
    /// only way the red key ever gets evidence.
    public static let subscribedEvents = [
        "SessionStart",       // command-only (G1); source of CLAUDE_PID
        "SessionEnd",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "PostToolBatch",
        "PermissionRequest",  // the amber key, 1ms, unconditional
        "Stop",
        "StopFailure",        // unverified
        "PostToolUseFailure", // unverified
        "Notification",       // filtered to idle_prompt by the receiver
    ]

    /// One hook entry. Deliberately three keys and no more: every key here is one
    /// the 2.1.220 schema declares, and an unrecognised key risks the whole settings
    /// file failing to load — which would break the user's CLI, not just our panel.
    static func hookEntry(forwarderPath: String) -> JSONValue {
        .object([
            "type": .string("command"),
            "command": .string(forwarderPath),
            "async": .bool(true),
        ])
    }

    // MARK: - Planning

    public static func plan(
        _ action: Action,
        settingsURL: URL = defaultSettingsURL,
        forwarderURL: URL = defaultForwarderURL,
        spoolDirectory: URL = ClaudeHookSource.defaultSpoolDirectory
    ) throws -> Plan {
        let originalBytes = try? Data(contentsOf: settingsURL)
        let original: JSONValue
        if let originalBytes, !originalBytes.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }) {
            guard let parsed = JSONValue.parse(originalBytes) else {
                throw PlanError.malformedJSON(settingsURL)
            }
            guard parsed.objectValue != nil else { throw PlanError.notAnObject(settingsURL) }
            original = parsed
        } else {
            original = .object([:])
        }

        let forwarderPath = forwarderURL.path
        var updated: JSONValue = switch action {
        case .install: try installing(into: original, forwarderPath: forwarderPath)
        case .uninstall: try uninstalling(from: original, forwarderPath: forwarderPath)
        }
        // Sweep paths we used to install to, whichever direction we are going.
        // Uninstall keyed only off the CURRENT forwarder path, so moving the install
        // location — which we had to do, because the old one contained a space and
        // silently broke every hook — orphaned every entry from the previous
        // version: settings pointing at a script that no longer exists, invisible
        // because async hooks discard their failures. Install sweeps too, so an
        // upgrade repairs itself instead of stacking a second set of entries.
        for legacy in Self.legacyForwarderURLs where legacy.path != forwarderPath {
            updated = try uninstalling(from: updated, forwarderPath: legacy.path)
        }

        let canonicalOriginal = try original.canonicalData()
        let canonicalUpdated = try updated.canonicalData()
        // "Nothing to do" must mean the whole installation is intact, not just that
        // the settings file matches. Computing it from JSON alone produced a state
        // where settings referenced a forwarder that had never been written — every
        // hook pointing at a missing script, install declining to fix it because the
        // config "already looked right", and async hooks swallowing the failure. For
        // an install, the script existing and being executable is part of the goal.
        let forwarderReady: Bool = {
            guard action == .install else { return true }
            guard FileManager.default.isExecutableFile(atPath: forwarderPath) else { return false }
            return true
        }()
        let isNoOp = updated == original && forwarderReady

        return Plan(
            action: action,
            settingsURL: settingsURL,
            backupURL: settingsURL.appendingPathExtension("vcm-backup"),
            forwarderURL: forwarderURL,
            spoolDirectory: spoolDirectory,
            events: subscribedEvents,
            diff: isNoOp ? "" : lineDiff(text(canonicalOriginal), text(canonicalUpdated)),
            isNoOp: isNoOp,
            reformatsFile: !isNoOp && originalBytes != nil && originalBytes != canonicalOriginal,
            newContents: canonicalUpdated
        )
    }

    /// Appends our group to every subscribed event, leaving anything already there
    /// untouched. Idempotent by looking for our own forwarder path — no marker key,
    /// because an extra key in a hook object is a schema risk we do not need to run.
    static func installing(into root: JSONValue, forwarderPath: String) throws -> JSONValue {
        guard var top = root.objectValue else { throw PlanError.unexpectedShape("root is not an object") }
        var hooks: [String: JSONValue]
        switch top["hooks"] {
        case nil: hooks = [:]
        case .some(let value):
            guard let object = value.objectValue else {
                throw PlanError.unexpectedShape("`hooks` is not an object")
            }
            hooks = object
        }

        let entry = hookEntry(forwarderPath: forwarderPath)
        for event in subscribedEvents {
            var groups: [JSONValue]
            switch hooks[event] {
            case nil: groups = []
            case .some(let value):
                guard let array = value.arrayValue else {
                    throw PlanError.unexpectedShape("`hooks.\(event)` is not an array")
                }
                groups = array
            }
            if !groups.contains(where: { group(_: $0, contains: forwarderPath) }) {
                // A group of our own with no matcher, appended after whatever the
                // user already has. Their entries keep firing; ours fires too.
                groups.append(.object(["hooks": .array([entry])]))
            }
            hooks[event] = .array(groups)
        }

        top["hooks"] = .object(hooks)
        return .object(top)
    }

    /// Removes every hook entry whose command is our forwarder, drops the groups and
    /// event arrays that existed only for us, and touches nothing else. Groups and
    /// entries we did not add are copied through verbatim, including shapes we do not
    /// understand.
    ///
    /// One documented asymmetry: an *empty* `hooks` object is pruned, so a file that
    /// started with a literal `"hooks": {}` comes back without the key. Semantically
    /// identical to Claude Code, and the alternative is leaving litter behind.
    static func uninstalling(from root: JSONValue, forwarderPath: String) throws -> JSONValue {
        guard var top = root.objectValue else { throw PlanError.unexpectedShape("root is not an object") }
        guard let existing = top["hooks"] else { return root }
        guard var hooks = existing.objectValue else {
            throw PlanError.unexpectedShape("`hooks` is not an object")
        }

        for event in hooks.keys.sorted() {
            guard let groups = hooks[event]?.arrayValue else { continue }
            var kept: [JSONValue] = []
            for group in groups {
                guard let object = group.objectValue, let entries = object["hooks"]?.arrayValue else {
                    kept.append(group)
                    continue
                }
                let remaining = entries.filter { $0["command"]?.stringValue != forwarderPath }
                if remaining.count == entries.count {
                    kept.append(group)
                } else if !remaining.isEmpty {
                    var rebuilt = object
                    rebuilt["hooks"] = .array(remaining)
                    kept.append(.object(rebuilt))
                }
                // remaining.isEmpty: the group held nothing but our entry, so it goes.
            }
            hooks[event] = kept.isEmpty ? nil : .array(kept)
        }

        top["hooks"] = hooks.isEmpty ? nil : .object(hooks)
        return .object(top)
    }

    private static func group(_ group: JSONValue, contains forwarderPath: String) -> Bool {
        group["hooks"]?.arrayValue?.contains { $0["command"]?.stringValue == forwarderPath } ?? false
    }

    // MARK: - Applying

    /// Writes the plan. The only function in this type that changes anything on disk,
    /// and it must be reached through explicit user consent.
    /// True when this plan's forwarder is the real installed one. The self-check
    /// asserts its own plans are NOT, so a fixture plan can never reach into the
    /// live install again.
    public static func targetsLiveInstall(_ plan: Plan) -> Bool {
        plan.forwarderURL.path == defaultForwarderURL.path
    }

    public static func apply(_ plan: Plan) throws {
        guard !plan.isNoOp else { return }
        let fm = FileManager.default
        try fm.createDirectory(
            at: plan.settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        // Back up before anything else. This is the recovery path if the CLI ever
        // rejects what we wrote.
        var mode: NSNumber?
        if let existing = try? Data(contentsOf: plan.settingsURL) {
            mode = (try? fm.attributesOfItem(atPath: plan.settingsURL.path))?[.posixPermissions] as? NSNumber
            try existing.write(to: plan.backupURL, options: .atomic)
        }

        if plan.action == .install {
            try installForwarder(at: plan.forwarderURL, spoolDirectory: plan.spoolDirectory)
        }

        try plan.newContents.write(to: plan.settingsURL, options: .atomic)

        // The rename behind `.atomic` brings default permissions with it, and this
        // file is mode 600. Put the original mode back.
        if let mode {
            try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: plan.settingsURL.path)
        }

        if plan.action == .uninstall {
            try? fm.removeItem(at: plan.forwarderURL)
            // Derive the directory FROM THE PLAN, and only remove it when it is
            // actually empty.
            //
            // The previous version did `removeItem(at: Self.forwarderDirectory)` —
            // the hard-coded real path, ignoring plan.forwarderURL, and recursive
            // despite a comment claiming it only removed an empty directory. Since
            // selfCheckFailures() applies two fixture uninstalls, simply RUNNING THE
            // SELF-CHECK deleted the user's live forwarder while leaving all eleven
            // settings.json entries pointing at it. `async: true` discards the
            // resulting exit 127, so the breakage was completely silent: their
            // Claude Code kept working and only our panel went dark — with
            // needsInput dying hardest, because a pending prompt writes nothing to
            // the transcript for the tailer to fall back on.
            let directory = plan.forwarderURL.deletingLastPathComponent()
            let remaining = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? ["not-empty"]
            if remaining.isEmpty {
                try? fm.removeItem(at: directory)
            }
        }
        // Legacy scripts go on both paths: leaving an executable behind that
        // nothing references is litter in the user's home directory.
        for legacy in Self.legacyForwarderURLs where legacy.path != plan.forwarderURL.path {
            try? fm.removeItem(at: legacy)
        }
    }

    /// The forwarder. Writes one file into the spool and exits — it never talks to
    /// our process, so the panel being wedged, slow or absent cannot delay anybody's
    /// session.
    static func installForwarder(at url: URL, spoolDirectory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: spoolDirectory, withIntermediateDirectories: true)
        let script = forwarderScript(spoolDirectory: spoolDirectory)
        try Data(script.utf8).write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: url.path)
    }

    static func forwarderScript(spoolDirectory: URL) -> String {
        // Single-quoted with ' escaped, so a home directory containing a quote,
        // a `$` or a backtick cannot become shell code.
        let quoted = "'" + spoolDirectory.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return """
        #!/bin/sh
        # Installed by Virtual Codex Micro. Its uninstaller deletes this file.
        #
        # Reads one Claude Code hook payload on stdin and drops it in the app's spool
        # directory. The settings entry sets "async": true so the CLI does not wait on
        # this, and the script itself does one mkdir, one write and one rename.
        #
        # Always exits 0: a hook exiting non-zero can block the transition it fired on,
        # and exit code 2 is a blocking error the model is told about.
        d=\(quoted)
        mkdir -p "$d" 2>/dev/null || exit 0
        f=$(mktemp "$d/tmp.XXXXXXXX" 2>/dev/null) || exit 0
        # First line is the environment the JSON payload does not carry. CLAUDE_PID is
        # the CLI process itself, which is what liveness polling and window focus need.
        {
          printf 'vcm\\tpid=%s\\tterm=%s\\tentry=%s\\n' "${CLAUDE_PID:-}" "${TERM_PROGRAM:-}" "${CLAUDE_CODE_ENTRYPOINT:-}"
          cat
        } > "$f" 2>/dev/null
        # Rename last. The receiver reads only *.json, so it never sees a partial write.
        mv -f "$f" "$f.json" 2>/dev/null || rm -f "$f" 2>/dev/null
        exit 0

        """
    }

    // MARK: - Diff

    private static func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    /// Line diff for the consent dialog. Both sides are canonically serialized
    /// first, so what shows up is the change and not the reformatting.
    // ponytail: O(n*m) LCS over a file that is a few hundred lines. Reach for a
    // real diff library if settings.json ever gets big, which it will not.
    static func lineDiff(_ before: String, _ after: String, context: Int = 2) -> String {
        let a = before.components(separatedBy: "\n")
        let b = after.components(separatedBy: "\n")

        var lcs = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }

        var script: [String] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                script.append("  " + a[i]); i += 1; j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                script.append("- " + a[i]); i += 1
            } else {
                script.append("+ " + b[j]); j += 1
            }
        }
        while i < a.count { script.append("- " + a[i]); i += 1 }
        while j < b.count { script.append("+ " + b[j]); j += 1 }

        // Collapse long untouched stretches, or the dialog shows the file instead of
        // the change.
        var folded: [String] = []
        var index = 0
        while index < script.count {
            guard script[index].hasPrefix("  ") else {
                folded.append(script[index]); index += 1; continue
            }
            var end = index
            while end < script.count, script[end].hasPrefix("  ") { end += 1 }
            let run = script[index..<end]
            if run.count > context * 2 + 1 {
                folded += run.prefix(context)
                folded.append("  … \(run.count - context * 2) unchanged lines")
                folded += run.suffix(context)
            } else {
                folded += run
            }
            index = end
        }
        return folded.joined(separator: "\n")
    }
}

// MARK: - Self check

extension ClaudeHookInstaller {
    /// Fixture-only. Never given a real path, and `ClaudeHookSource.selfCheckFailures`
    /// verifies the real `~/.claude/settings.json` is byte-identical afterwards.
    static func selfCheckFailures(in fixtures: URL) -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: fixtures, withIntermediateDirectories: true)
        } catch {
            return ["installer fixture directory: \(error)"]
        }

        let forwarder = fixtures.appendingPathComponent("claude-hook.sh")
        let spool = fixtures.appendingPathComponent("spool", isDirectory: true)

        func planning(_ action: Action, _ settings: URL) throws -> Plan {
            try plan(action, settingsURL: settings, forwarderURL: forwarder, spoolDirectory: spool)
        }

        // SessionStart is not optional and not an http hook. G1: http received zero
        // SessionStart events across three single-variable runs.
        check("SessionStart must be subscribed", subscribedEvents.contains("SessionStart"))
        check("PermissionRequest must be subscribed", subscribedEvents.contains("PermissionRequest"))
        check("Notification is subscribed for idle_prompt", subscribedEvents.contains("Notification"))
        for event in subscribedEvents {
            check(
                "subscribed event '\(event)' has no disposition",
                ClaudeHookSource.dispositions[event] != nil
            )
        }
        let entry = hookEntry(forwarderPath: forwarder.path)
        check("hook entries are command type", entry["type"]?.stringValue == "command")
        check("hook entries are async", entry["async"] == .bool(true))
        check("hook entries carry no http url", entry["url"] == nil)

        // The user's real shape: one PreToolUse group with a matcher and their own
        // command. It must survive install untouched.
        let userHook = JSONValue.object([
            "model": .string("opus[1m]"),
            "hooks": .object([
                "PreToolUse": .array([.object([
                    "matcher": .string("Bash"),
                    "hooks": .array([.object([
                        "type": .string("command"),
                        "command": .string("/Users/someone/.claude/hooks/rtk-rewrite.sh"),
                    ])]),
                ])]),
            ]),
        ])

        let settings = fixtures.appendingPathComponent("settings.json")
        do {
            let fixtureBytes = try userHook.canonicalData()
            try fixtureBytes.write(to: settings)
            try fm.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: settings.path)

            // Install once.
            let first = try planning(.install, settings)
            check("install is not a no-op on a fresh file", !first.isNoOp)
            check("install diff mentions the forwarder", first.diff.contains(forwarder.path))
            check("install diff has additions", first.diff.contains("\n+ ") || first.diff.hasPrefix("+ "))
            check("a canonical fixture is not reformatted", !first.reformatsFile)
            try apply(first)

            guard let installed = JSONValue.parse(try Data(contentsOf: settings)) else {
                return failures + ["installed settings did not parse"]
            }
            for event in subscribedEvents {
                let groups = installed["hooks"]?[event]?.arrayValue ?? []
                let ours = groups.filter { group($0, contains: forwarder.path) }
                check("exactly one of our groups under \(event), found \(ours.count)", ours.count == 1)
            }
            // The user's own entry, byte-identical, still first in the array.
            let preToolUse = installed["hooks"]?["PreToolUse"]?.arrayValue ?? []
            check("PreToolUse has the user's group and ours", preToolUse.count == 2)
            check(
                "the user's PreToolUse group is untouched",
                preToolUse.first == userHook["hooks"]?["PreToolUse"]?.arrayValue?.first
            )
            check("unrelated settings keys survive", installed["model"]?.stringValue == "opus[1m]")
            check("a backup was written", fm.fileExists(atPath: first.backupURL.path))
            check("the forwarder script is installed", fm.fileExists(atPath: forwarder.path))
            check(
                "the forwarder is executable",
                fm.isExecutableFile(atPath: forwarder.path)
            )
            check(
                "settings permissions are preserved",
                ((try? fm.attributesOfItem(atPath: settings.path))?[.posixPermissions] as? NSNumber)?.intValue == 0o600
            )

            // Install twice: nothing added, nothing written.
            let bytesAfterFirst = try Data(contentsOf: settings)
            let second = try planning(.install, settings)
            check("a second install is a no-op", second.isNoOp)
            check("a no-op plan has an empty diff", second.diff.isEmpty)
            try apply(second)
            check("a second install changed the file", try Data(contentsOf: settings) == bytesAfterFirst)

            // Uninstall restores the fixture exactly.
            let removal = try planning(.uninstall, settings)
            check("uninstall is not a no-op after installing", !removal.isNoOp)
            check("uninstall diff has removals", removal.diff.contains("\n- ") || removal.diff.hasPrefix("- "))
            try apply(removal)
            check("uninstall restores the fixture byte-for-byte", try Data(contentsOf: settings) == fixtureBytes)
            check("uninstall removes the forwarder", !fm.fileExists(atPath: forwarder.path))
            let repeated = try planning(.uninstall, settings)
            check("a second uninstall is a no-op", repeated.isNoOp)
        } catch {
            failures.append("install/uninstall round trip threw: \(error)")
        }

        // A settings file that does not exist yet.
        let fresh = fixtures.appendingPathComponent("fresh.json")
        do {
            let created = try planning(.install, fresh)
            check("install into a missing file is not a no-op", !created.isNoOp)
            check("a missing file is not reported as reformatted", !created.reformatsFile)
            try apply(created)
            let root = JSONValue.parse(try Data(contentsOf: fresh))
            check("a created file has our hooks", root?["hooks"]?["Stop"] != nil)
            try apply(try planning(.uninstall, fresh))
            check("uninstall empties the hooks key", JSONValue.parse(try Data(contentsOf: fresh))?["hooks"] == nil)
        } catch {
            failures.append("install into a missing file threw: \(error)")
        }

        // Malformed and JSONC settings are refused, and left alone. Claude Code
        // reads its config as JSONC; we do not, so a file with comments must never
        // be rewritten by us.
        for (label, contents) in [
            "truncated": "{\"hooks\": ",
            "jsonc comment": "{\n  // keep this\n  \"model\": \"opus\"\n}",
            "single quotes": "{'model': 'opus'}",
            "top-level array": "[]",
        ] {
            let bad = fixtures.appendingPathComponent("bad-\(label.replacingOccurrences(of: " ", with: "-")).json")
            do {
                try Data(contents.utf8).write(to: bad)
                _ = try planning(.install, bad)
                failures.append("'\(label)' settings should be refused")
            } catch is PlanError {
                check(
                    "'\(label)' settings must be left untouched",
                    (try? String(contentsOf: bad, encoding: .utf8)) == contents
                )
            } catch {
                failures.append("'\(label)' settings threw the wrong error: \(error)")
            }
        }

        // Foundation's parser tolerates one trailing comma, so such a file is not
        // refused — it is accepted and rewritten without it. Semantically identical
        // for Claude Code, and `reformatsFile` warns the consent UI that the file
        // will look different afterwards.
        let lenient = fixtures.appendingPathComponent("trailing-comma.json")
        do {
            try Data(#"{"model": "opus",}"#.utf8).write(to: lenient)
            let tolerated = try planning(.install, lenient)
            check("a trailing comma is tolerated, not refused", !tolerated.isNoOp)
            check("rewriting a non-canonical file is flagged", tolerated.reformatsFile)
        } catch {
            failures.append("a trailing comma should not throw: \(error)")
        }

        // A `hooks` value we do not understand is a stop, not something to overwrite.
        let alien = fixtures.appendingPathComponent("alien.json")
        do {
            try Data(#"{"hooks": "surprise"}"#.utf8).write(to: alien)
            _ = try planning(.install, alien)
            failures.append("a non-object `hooks` should be refused")
        } catch is PlanError {
        } catch {
            failures.append("a non-object `hooks` threw the wrong error: \(error)")
        }

        // The forwarder must not let a hostile path escape into shell code, and must
        // always exit 0 whatever happens.
        let awkward = URL(fileURLWithPath: "/tmp/it's $(rm -rf /)/`x`")
        let script = forwarderScript(spoolDirectory: awkward)
        check("forwarder quotes the spool path", script.contains(#"d='/tmp/it'\''s $(rm -rf /)/`x`'"#))
        check("forwarder ends by exiting 0", script.hasSuffix("exit 0\n"))
        check("forwarder never uses a non-zero exit", !script.contains("exit 1") && !script.contains("exit 2"))

        // The forwarder's metadata line and `HookEvent.parse` are a contract between
        // shell `printf` and Swift. If they ever drift, CLAUDE_PID silently vanishes
        // and both focus and liveness stop working with nothing looking broken. One
        // `/bin/sh` spawn, in the self-check only.
        do {
            let liveSpool = fixtures.appendingPathComponent("live-spool", isDirectory: true)
            let liveForwarder = fixtures.appendingPathComponent("live-hook.sh")
            try installForwarder(at: liveForwarder, spoolDirectory: liveSpool)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [liveForwarder.path]
            process.environment = [
                "CLAUDE_PID": "4242", "TERM_PROGRAM": "ghostty",
                "CLAUDE_CODE_ENTRYPOINT": "cli", "PATH": "/usr/bin:/bin",
            ]
            let stdin = Pipe()
            process.standardInput = stdin
            try process.run()
            stdin.fileHandleForWriting.write(Data(
                #"{"hook_event_name":"PermissionRequest","session_id":"abc","tool_name":"Bash"}"#.utf8
            ))
            try stdin.fileHandleForWriting.close()
            process.waitUntilExit()

            check("the forwarder exits 0", process.terminationStatus == 0)
            let received = ClaudeHookSource.drain(directory: liveSpool)
            check("the forwarder delivered one event, got \(received.count)", received.count == 1)
            check("the delivered event is needsInput", received.first?.outcome == .state(.needsInput))
            check("the delivered event carries CLAUDE_PID", received.first?.claudePID == 4242)
            check("the delivered event carries TERM_PROGRAM", received.first?.termProgram == "ghostty")
        } catch {
            failures.append("forwarder round trip threw: \(error)")
        }

        // The diff is a diff, not a dump.
        let long = (1...20).map(String.init)
        let folded = lineDiff(long.joined(separator: "\n"), (long + ["X"]).joined(separator: "\n"))
        check("diff marks the insertion", folded.contains("+ X"))
        check("diff folds untouched lines", folded.contains("unchanged lines"))
        check("folding keeps the diff shorter than the file", folded.split(separator: "\n").count < long.count)
        check("identical input diffs to context only", !lineDiff("a\nb", "a\nb").contains("+"))

        return failures
    }
}
