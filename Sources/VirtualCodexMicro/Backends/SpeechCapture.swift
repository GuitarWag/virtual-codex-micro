import AVFoundation
import Foundation
import Speech

/// Hold-to-record prompt capture for the push-to-talk command key.
///
/// Scope is deliberately one thing: hold the key, speak, release, get a
/// transcript string that the owner dispatches as `AgentCommand.sendPrompt`. No
/// voice commands, no wake word, no settings surface. Task 035 is the lowest
/// item on the board and was demoted out of the PRD's P1 precisely because it is
/// orthogonal to the state-trustworthiness thesis.
///
/// **On-device recognition is a privacy constraint, not a latency tuning knob.**
/// The user dictates prompts about their own private code. Every other thing
/// this app does stays on the machine — it reads transcripts on disk, watches
/// hook events over a local socket, and talks to a PTY it owns. Streaming the
/// user's voice to Apple's speech servers is a materially different posture, and
/// one the user never opted into by pressing a microphone key. So
/// `requiresOnDeviceRecognition` is set to `true` and, when on-device
/// recognition is not available for the current locale, capture **fails with a
/// stated reason** rather than quietly falling back to server-based recognition.
/// There is no fallback path in this file, by design.
///
/// ## Info.plist requirement (Scripts/bundle.sh)
///
/// The bundle script currently writes `NSAppleEventsUsageDescription` only. Both
/// of the following keys are mandatory: requesting either authorization without
/// its usage string is a hard crash on first request, not a declined prompt.
///
///   NSMicrophoneUsageDescription
///   NSSpeechRecognitionUsageDescription
///
/// Exact strings are in `SpeechCapture.requiredInfoPlistStrings`, which
/// `selfCheckFailures()` keeps non-empty so the pair can never drift into being
/// documented as blank.

// MARK: - Reported state

/// What the push-to-talk key shows. The key must look like it is recording, not
/// inert — that is the whole reason this is an enum with a description rather
/// than a `Bool isRecording`.
public enum SpeechCaptureState: Sendable, Equatable {
    case idle
    /// Waiting on the microphone / speech-recognition prompts. First press only.
    case requestingAuthorization
    case recording
    /// Key released, waiting for the recognizer's final result.
    case transcribing
    /// Carries a sentence fit to show a human. Never empty.
    case failed(reason: String)

    /// Non-empty for every case. `selfCheckFailures()` asserts it.
    public var label: String {
        switch self {
        case .idle: "Push to talk"
        case .requestingAuthorization: "Waiting for permission…"
        case .recording: "Recording…"
        case .transcribing: "Transcribing…"
        case .failed(let reason): reason
        }
    }

    public var isRecording: Bool { self == .recording }
    /// Recording or transcribing: the key should read as busy for both.
    public var isActive: Bool { self == .recording || self == .transcribing }

    public var failureReason: String? {
        if case .failed(let reason) = self { return reason } else { return nil }
    }
}

// MARK: - Readiness (the injectable half)

/// Every authorization and capability fact the state machine needs, as a value.
/// This is the injection point: `selfCheckFailures()` drives every branch —
/// denied, restricted, on-device unavailable — with synthetic values and no
/// microphone, no audio session and no recognizer.
public struct SpeechCaptureReadiness: Sendable, Equatable {

    /// TCC has four outcomes and all four need different handling. `restricted`
    /// is folded in as its own case rather than lumped with `denied` because the
    /// user cannot fix it in System Settings — it is MDM policy, and telling
    /// them to go flip a switch that is greyed out is a worse answer than saying
    /// it is blocked by policy.
    public enum Grant: Sendable, Equatable, CaseIterable {
        case notDetermined
        case granted
        case denied
        case restricted
    }

    public var speech: Grant
    public var microphone: Grant
    /// `SFSpeechRecognizer.supportsOnDeviceRecognition` for `localeIdentifier`.
    /// False also covers "no recognizer exists for this locale at all".
    public var onDeviceAvailable: Bool
    public var localeIdentifier: String

    public init(speech: Grant, microphone: Grant, onDeviceAvailable: Bool, localeIdentifier: String) {
        self.speech = speech
        self.microphone = microphone
        self.onDeviceAvailable = onDeviceAvailable
        self.localeIdentifier = localeIdentifier
    }

    /// Why capture cannot proceed at all, or `nil` when it can (possibly after
    /// asking). Never returns an empty string.
    ///
    /// On-device availability is checked *before* authorization on purpose:
    /// prompting someone for their microphone and then refusing to use it is
    /// rude, and the refusal is not their fault.
    public var blockingReason: String? {
        if !onDeviceAvailable {
            return "On-device speech recognition is unavailable for \(localeIdentifier). "
                + "Push to talk will not send your voice to Apple's servers, so it stays off. "
                + "Adding the language under System Settings › Keyboard › Dictation enables it."
        }
        if let reason = Self.grantFailure(microphone, subject: "Microphone access") { return reason }
        if let reason = Self.grantFailure(speech, subject: "Speech recognition") { return reason }
        return nil
    }

    /// True when a press must show `.requestingAuthorization` before recording.
    public var needsAuthorization: Bool {
        speech == .notDetermined || microphone == .notDetermined
    }

    public var canRecord: Bool { blockingReason == nil && !needsAuthorization }

    private static func grantFailure(_ grant: Grant, subject: String) -> String? {
        switch grant {
        case .granted, .notDetermined:
            return nil
        case .denied:
            return "\(subject) is denied. Allow it for Virtual Codex Micro in "
                + "System Settings › Privacy & Security to use push to talk."
        case .restricted:
            return "\(subject) is restricted by device policy, so push to talk cannot run."
        }
    }
}

// MARK: - Pure state machine

/// The whole hold-to-record lifecycle with no audio hardware in it. Kept a value
/// type so the self-check can replay press/release orderings that are awkward to
/// produce by hand — notably releasing the key while the permission dialog is
/// still up.
public struct SpeechCaptureMachine: Sendable {

    public enum Event: Sendable, Equatable {
        /// Key down. Carries readiness read at press time.
        case press(SpeechCaptureReadiness)
        /// The authorization prompts came back. Carries re-read readiness.
        case authorizationResolved(SpeechCaptureReadiness)
        /// Key up.
        case release
        /// Recognizer's final text. May legitimately be empty or whitespace.
        case transcript(String)
        /// Recognizer or audio engine gave up mid-stream.
        case failure(reason: String)
    }

    public private(set) var state: SpeechCaptureState = .idle

    public init() {}

    /// Applies `event` and returns the prompt to dispatch as `.sendPrompt`, or
    /// `nil`.
    ///
    /// Never returns an empty or whitespace-only string. Sending a coding agent
    /// an empty prompt is worse than doing nothing: it burns a turn, and on a
    /// session mid-approval it can answer a prompt the user never saw.
    @discardableResult
    public mutating func apply(_ event: Event) -> String? {
        switch event {
        case .press(let readiness):
            if let reason = readiness.blockingReason {
                // Includes the on-device-unavailable case. No server fallback.
                state = .failed(reason: reason)
            } else if readiness.needsAuthorization {
                state = .requestingAuthorization
            } else {
                state = .recording
            }
            return nil

        case .authorizationResolved(let readiness):
            // The only state a grant can act on. Anything else means the key was
            // already released (`.release` drives `.requestingAuthorization` to
            // `.idle`), the press failed, or this is a stale callback — so a late
            // grant can never start recording with nobody holding the key.
            guard state == .requestingAuthorization else { return nil }
            if let reason = readiness.blockingReason {
                state = .failed(reason: reason)
            } else if readiness.needsAuthorization {
                // Prompt dismissed without an answer. Not a denial; not a grant.
                state = .failed(reason: "Push to talk needs microphone and speech-recognition access. "
                    + "Hold the key again to be asked.")
            } else {
                state = .recording
            }
            return nil

        case .release:
            switch state {
            case .recording:
                state = .transcribing
            case .requestingAuthorization:
                state = .idle
            case .idle, .transcribing, .failed:
                break
            }
            return nil

        case .transcript(let text):
            // Only meaningful while we are waiting for one. A result arriving in
            // `.recording` means the recognizer finalized early; take it and end.
            guard state == .transcribing || state == .recording else { return nil }
            state = .idle
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Released too fast to capture anything, or silence: no prompt.
            return trimmed.isEmpty ? nil : trimmed

        case .failure(let reason):
            // A reason is mandatory; a blank failure would render an empty key.
            state = .failed(reason: reason.isEmpty ? "Speech recognition failed." : reason)
            return nil
        }
    }
}

// MARK: - Live capture

/// Drives `SpeechCaptureMachine` against a real microphone.
///
/// `ObservableObject` to match `PanelModel`'s convention, so the push-to-talk key
/// can bind to `state` directly.
@MainActor
public final class SpeechCapture: ObservableObject {

    /// Exact keys and strings `Scripts/bundle.sh` must add to Info.plist. Not
    /// read at runtime — it is the single place the strings live so the script
    /// and this file cannot disagree silently.
    public static let requiredInfoPlistStrings: [String: String] = [
        "NSMicrophoneUsageDescription":
            "Virtual Codex Micro records your voice only while you hold the push-to-talk key, "
            + "so you can dictate a prompt to an agent session.",
        "NSSpeechRecognitionUsageDescription":
            "Virtual Codex Micro transcribes held-key recordings on this Mac to turn them into "
            + "agent prompts. Speech recognition runs on-device and audio is never sent to Apple.",
    ]

    @Published public private(set) var state: SpeechCaptureState = .idle

    private var machine = SpeechCaptureMachine()
    private let locale: Locale
    private let onPrompt: @MainActor (String) -> Void

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var transcript = ""
    /// Bounds `.transcribing` so a recognizer that never finalizes cannot leave
    /// the key spinning forever.
    private var finalizeTimeout: Task<Void, Never>?

    public init(locale: Locale = Locale.current, onPrompt: @escaping @MainActor (String) -> Void) {
        self.locale = locale
        self.onPrompt = onPrompt
    }

    /// Key down.
    public func press() {
        guard !state.isActive else { return }
        let readiness = Self.readiness(locale: locale)
        machine.apply(.press(readiness))
        state = machine.state

        switch state {
        case .requestingAuthorization:
            Task { [weak self] in
                guard let self else { return }
                await Self.requestAuthorizations()
                self.machine.apply(.authorizationResolved(Self.readiness(locale: self.locale)))
                self.state = self.machine.state
                if self.state == .recording { self.startAudio() }
            }
        case .recording:
            startAudio()
        default:
            break
        }
    }

    /// Key up. The final transcript arrives asynchronously and is handed to
    /// `onPrompt` only if it is not empty.
    public func release() {
        let wasRecording = state == .recording
        machine.apply(.release)
        state = machine.state
        guard wasRecording else {
            // Released during the permission prompt, or never started. A
            // duplicate release while already transcribing must not tear down
            // the recognition that is still flushing.
            if state != .transcribing { stopAudio() }
            return
        }
        // Stop capturing but let the recognizer flush what it already has.
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        finalizeTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.finish(with: self?.transcript ?? "")
        }
    }

    // MARK: Audio

    private func startAudio() {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            fail("Speech recognition is unavailable for \(locale.identifier).")
            return
        }
        self.recognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        // The constraint. See the file comment: no server fallback exists.
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        self.request = request
        transcript = ""

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            fail("No microphone input is available.")
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Pull Sendable values out here: SFSpeechRecognitionResult and Error
            // are not Sendable, so nothing but String/Bool crosses to the actor.
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failure = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let text { self.transcript = text }
                if let failure {
                    // A failure after the audio ended is only fatal if we have
                    // nothing to show — otherwise keep the partial text.
                    if self.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.fail(failure)
                    } else {
                        self.finish(with: self.transcript)
                    }
                } else if isFinal {
                    self.finish(with: text ?? self.transcript)
                }
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            fail("Could not start audio capture: \(error.localizedDescription)")
        }
    }

    private func stopAudio() {
        finalizeTimeout?.cancel()
        finalizeTimeout = nil
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        task?.cancel()
        task = nil
        request = nil
    }

    private func finish(with text: String) {
        let prompt = machine.apply(.transcript(text))
        state = machine.state
        stopAudio()
        transcript = ""
        if let prompt { onPrompt(prompt) }
    }

    private func fail(_ reason: String) {
        machine.apply(.failure(reason: reason))
        state = machine.state
        stopAudio()
        transcript = ""
    }

    // MARK: Authorization

    /// Reads both TCC statuses plus on-device support. Pure lookup, no prompting.
    public static func readiness(locale: Locale) -> SpeechCaptureReadiness {
        SpeechCaptureReadiness(
            speech: grant(SFSpeechRecognizer.authorizationStatus()),
            microphone: grant(AVCaptureDevice.authorizationStatus(for: .audio)),
            onDeviceAvailable: SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition ?? false,
            localeIdentifier: locale.identifier
        )
    }

    /// Requests both. Microphone first: it is the one the user is more likely to
    /// refuse, and asking for speech recognition after a mic denial is noise.
    private static func requestAuthorizations() async {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
            }
        }
    }

    private static func grant(_ status: SFSpeechRecognizerAuthorizationStatus) -> SpeechCaptureReadiness.Grant {
        switch status {
        case .notDetermined: .notDetermined
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .denied
        }
    }

    private static func grant(_ status: AVAuthorizationStatus) -> SpeechCaptureReadiness.Grant {
        switch status {
        case .notDetermined: .notDetermined
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .denied
        }
    }

    // MARK: - Self check

    /// Empty when healthy. Drives the pure machine only — no audio session, no
    /// recognizer, no microphone. Wire into `SelfCheck` with:
    ///
    ///     failures += SpeechCapture.selfCheckFailures().map { "speech: \($0)" }
    public static func selfCheckFailures() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        func readiness(
            speech: SpeechCaptureReadiness.Grant = .granted,
            mic: SpeechCaptureReadiness.Grant = .granted,
            onDevice: Bool = true
        ) -> SpeechCaptureReadiness {
            SpeechCaptureReadiness(
                speech: speech, microphone: mic, onDeviceAvailable: onDevice, localeIdentifier: "en_US"
            )
        }

        // Every state must be able to describe itself, or the key renders blank.
        let states: [SpeechCaptureState] = [
            .idle, .requestingAuthorization, .recording, .transcribing, .failed(reason: "x"),
        ]
        for state in states where state.label.isEmpty {
            failures.append("state \(state) has an empty label")
        }
        check("failed(\"\") would render an empty key", {
            var machine = SpeechCaptureMachine()
            machine.apply(.failure(reason: ""))
            return !(machine.state.failureReason ?? "").isEmpty
        }())

        // Press, release, nothing captured: no prompt rather than an empty one.
        for text in ["", "   ", "\n\t "] {
            var machine = SpeechCaptureMachine()
            machine.apply(.press(readiness()))
            machine.apply(.release)
            let prompt = machine.apply(.transcript(text))
            if prompt != nil { failures.append("empty transcript \(text.debugDescription) produced a prompt") }
            if machine.state != .idle { failures.append("empty transcript left state \(machine.state)") }
        }

        // A real transcript does dispatch, trimmed.
        var happy = SpeechCaptureMachine()
        happy.apply(.press(readiness()))
        check("granted press did not record", happy.state == .recording)
        happy.apply(.release)
        check("release did not transcribe", happy.state == .transcribing)
        check("transcript not trimmed and dispatched",
              happy.apply(.transcript("  fix the failing test\n")) == "fix the failing test")
        check("finished capture did not return to idle", happy.state == .idle)

        // Denied and restricted: a usable reason, and never a recording state.
        for grant in [SpeechCaptureReadiness.Grant.denied, .restricted] {
            for readinessValue in [readiness(speech: grant), readiness(mic: grant)] {
                guard let reason = readinessValue.blockingReason, !reason.isEmpty else {
                    failures.append("\(grant) authorization has no user-facing reason")
                    continue
                }
                var machine = SpeechCaptureMachine()
                machine.apply(.press(readinessValue))
                if machine.state.isActive {
                    failures.append("\(grant) authorization still entered \(machine.state)")
                }
                if machine.state.failureReason != reason {
                    failures.append("\(grant) authorization did not surface its reason")
                }
                // And no transcript can sneak out of a failed press.
                if machine.apply(.transcript("hello")) != nil {
                    failures.append("\(grant) authorization still dispatched a prompt")
                }
            }
        }

        // On-device unavailable must fail, not fall back to the server.
        let offline = readiness(onDevice: false)
        check("on-device unavailable is not blocking", offline.blockingReason != nil)
        check("on-device unavailable can record", !offline.canRecord)
        var noDevice = SpeechCaptureMachine()
        noDevice.apply(.press(offline))
        check("on-device unavailable started recording anyway", !noDevice.state.isActive)
        check("on-device unavailable did not explain itself",
              noDevice.state.failureReason?.isEmpty == false)
        // Checked before authorization, so a not-determined mic must not turn
        // this into a permission prompt.
        check("on-device unavailable asked for permission instead of failing",
              SpeechCaptureReadiness(speech: .notDetermined, microphone: .notDetermined,
                                     onDeviceAvailable: false, localeIdentifier: "en_US")
                  .blockingReason != nil)

        // Release before authorization resolves: never stuck in recording.
        var early = SpeechCaptureMachine()
        early.apply(.press(readiness(speech: .notDetermined, mic: .notDetermined)))
        check("not-determined press did not request authorization",
              early.state == .requestingAuthorization)
        early.apply(.release)
        check("release during authorization left state \(early.state)", early.state == .idle)
        early.apply(.authorizationResolved(readiness()))
        check("late grant after release started recording with nobody holding",
              early.state != .recording)
        check("late grant after release is not idle", early.state == .idle)
        // And nothing can be dispatched out of that tail.
        check("late grant after release dispatched a prompt",
              early.apply(.transcript("stray words")) == nil)

        // Still held when the grant lands: that one does record.
        var held = SpeechCaptureMachine()
        held.apply(.press(readiness(speech: .notDetermined, mic: .notDetermined)))
        held.apply(.authorizationResolved(readiness()))
        check("grant while held did not start recording", held.state == .recording)

        // Denial arriving from the prompt is a failure with a reason.
        var refused = SpeechCaptureMachine()
        refused.apply(.press(readiness(mic: .notDetermined)))
        refused.apply(.authorizationResolved(readiness(mic: .denied)))
        check("denial from the prompt did not fail", refused.state.failureReason?.isEmpty == false)
        check("denial from the prompt still recording", !refused.state.isActive)

        // Dismissed prompt: neither granted nor denied, must not hang or record.
        var dismissed = SpeechCaptureMachine()
        dismissed.apply(.press(readiness(mic: .notDetermined)))
        dismissed.apply(.authorizationResolved(readiness(mic: .notDetermined)))
        check("dismissed prompt left the machine waiting",
              dismissed.state != .requestingAuthorization)
        check("dismissed prompt did not explain itself",
              dismissed.state.failureReason?.isEmpty == false)

        // Mid-stream recognizer failure: reason kept, no prompt, and a later
        // press recovers instead of staying failed forever.
        var broken = SpeechCaptureMachine()
        broken.apply(.press(readiness()))
        broken.apply(.failure(reason: "Recognition stopped."))
        check("mid-stream failure lost its reason", broken.state.failureReason == "Recognition stopped.")
        check("mid-stream failure dispatched a prompt", broken.apply(.transcript("half a")) == nil)
        broken.apply(.press(readiness()))
        check("a failed key cannot be pressed again", broken.state == .recording)

        // The Info.plist pair. Missing either one crashes on first request.
        for key in ["NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription"] {
            if (requiredInfoPlistStrings[key] ?? "").isEmpty {
                failures.append("no usage string documented for \(key)")
            }
        }

        return failures
    }
}
