import Foundation
import SwiftUI

/// Drives voice mode for the Ask composer: one mic control that works as
/// push-to-talk (tap to open, tap to send) or hold-to-talk (hold, release to
/// send), plus reading BookBot's replies back.
///
/// The gesture rules live in `VoiceModeMachine` so they're testable without a
/// mic. This type only performs the effects the machine asks for and republishes
/// state for SwiftUI. Every failure is soft: the composer keeps working.
@MainActor
final class AskVoiceController: ObservableObject {
    static let speakRepliesDefaultsKey = "livingreader.bookbot.speakReplies"

    @Published private(set) var phase: VoiceModePhase = .idle
    @Published private(set) var partialTranscript = ""

    /// Read every answer aloud. **On by default** — BookBot answers out loud
    /// whether the question was spoken or typed. Sticky once the reader
    /// changes it, so an explicit opt-out is never overridden.
    @Published var speakRepliesAloud: Bool {
        didSet {
            guard speakRepliesAloud != oldValue else { return }
            defaults.set(speakRepliesAloud, forKey: Self.speakRepliesDefaultsKey)
            if !speakRepliesAloud { stopSpeaking() }
        }
    }

    /// Which reply is being read aloud, so only that bubble shows a stop button.
    @Published private(set) var speakingMessageID: UUID?

    /// Handed the finished transcript so the composer can ask it.
    var onTranscript: ((String) -> Void)?

    private var machine = VoiceModeMachine()
    private let dictation: any VoiceDictating
    private let speaker: BookBotReplySpeaker?
    private let defaults: UserDefaults
    private let clock: () -> TimeInterval
    /// Stub/UITest path: first finger-up latches even when the tap lasted longer
    /// than `holdThreshold` (XCUITest `tap()` routinely does).
    private let latchSlowTaps: Bool
    /// `pressChanged` already handled this finger; a trailing Button action is
    /// the same tap, not "tap again to send".
    private var coalescedButtonAction = false
    private var captureTask: Task<Void, Never>?
    private var captureID = UUID()
    private var cleanupTask: Task<Void, Never>?
    private var lastSpokenMessageID: UUID?
    /// UITest/VoiceOver taps fire Button.action and then LongPress onPressingChanged;
    /// ignore the trailing press so it cannot instant-commit a just-latched capture.
    private var ignorePressUntil: TimeInterval = 0

    init(
        dictation: any VoiceDictating,
        speaker: BookBotReplySpeaker?,
        defaults: UserDefaults = .standard,
        clock: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate },
        latchSlowTaps: Bool? = nil
    ) {
        self.dictation = dictation
        self.speaker = speaker
        self.defaults = defaults
        self.clock = clock
        self.latchSlowTaps = latchSlowTaps ?? VoiceDictationResolver.prefersStub()
        // Absent key means "never chosen", which takes the on-by-default; a
        // stored `false` is a real opt-out and stays honoured.
        self.speakRepliesAloud = defaults.object(forKey: Self.speakRepliesDefaultsKey) as? Bool ?? true
        speaker?.onSpeakingChange = { [weak self] speaking in
            guard let self else { return }
            if speaking {
                self.machine.speakingStarted()
            } else {
                self.machine.speakingStopped()
                self.speakingMessageID = nil
            }
            self.publish()
        }
    }

    // MARK: - Derived state

    var statusText: String { machine.statusText }
    var isCapturing: Bool { machine.isCapturing }
    var isSpeaking: Bool { machine.isSpeaking }
    var failureMessage: String? { machine.failureMessage }
    var canSpeakReplies: Bool { speaker != nil }

    var micAccessibilityLabel: String {
        machine.isCapturing ? "Stop listening" : "Hold to talk to BookBot"
    }

    // MARK: - Gesture input

    /// A discrete activation: taps, VoiceOver, and UI-test `tap()` all land here.
    func tapped() {
        if coalescedButtonAction {
            coalescedButtonAction = false
            // Same finger as `pressChanged`. Don't treat this as "tap to send".
            if latchSlowTaps {
                machine.latchListening()
                publish()
            }
            return
        }
        let now = clock()
        // Cover the LongPress onPressingChanged that SwiftUI often emits after a tap.
        ignorePressUntil = now + VoiceModeMachine.holdThreshold + 0.15
        apply(machine.pressBegan(at: now))
        apply(machine.pressEnded(at: now, treatAsTap: latchSlowTaps))
    }

    /// Continuous press tracking for hold-to-talk. A trailing Button `tapped()`
    /// from the same finger is coalesced so it cannot hold-commit + re-open.
    func pressChanged(_ isPressing: Bool) {
        let now = clock()
        if now < ignorePressUntil { return }
        if isPressing {
            coalescedButtonAction = true
            apply(machine.pressBegan(at: now))
        } else {
            apply(machine.pressEnded(at: now, treatAsTap: latchSlowTaps))
            Task { @MainActor [weak self] in
                self?.coalescedButtonAction = false
            }
        }
    }

    func cancel() {
        apply(machine.cancel())
    }

    func dismissFailure() {
        machine.clearFailure()
        publish()
    }

    // MARK: - Speaking replies

    /// Called when a new message lands. Answers are spoken by default; soft
    /// failures are not — recovery copy is for reading, not listening.
    func speakLatestReplyIfNeeded(_ message: AskMessage?) {
        guard let message, message.role == .assistant, !message.isSoftFailure else { return }
        guard speakRepliesAloud else { return }
        guard lastSpokenMessageID != message.id else { return }
        speak(message)
    }

    /// Explicit "read this one to me" from a reply's speaker button.
    ///
    /// `speak` restarts the speaker, which reports a stop before its start, so
    /// the owning id is recorded after the call rather than before it.
    func speak(_ message: AskMessage) {
        guard let speaker else { return }
        lastSpokenMessageID = message.id
        speaker.speak(message.content)
        speakingMessageID = message.id
    }

    func isReadingAloud(_ message: AskMessage) -> Bool {
        machine.isSpeaking && speakingMessageID == message.id
    }

    func stopSpeaking() {
        speaker?.stop()
        machine.speakingStopped()
        speakingMessageID = nil
        publish()
    }

    /// Sheet is closing: nothing keeps running behind it.
    func shutDown() {
        captureID = UUID()
        captureTask?.cancel()
        captureTask = nil
        speaker?.stop()
        let dictation = self.dictation
        cleanupTask = Task { await dictation.cancelListening() }
        machine = VoiceModeMachine()
        lastSpokenMessageID = nil
        speakingMessageID = nil
        publish()
    }

    // MARK: - Effects

    private func apply(_ effect: VoiceModeMachine.Effect) {
        switch effect {
        case .none:
            break
        case .startListening:
            speaker?.stop()
            speakingMessageID = nil
            captureTask?.cancel()
            captureID = UUID()
            let id = captureID
            captureTask = Task { [weak self] in await self?.beginCapture(id: id) }
        case .commitTranscript:
            captureTask?.cancel()
            let id = captureID
            captureTask = Task { [weak self] in await self?.commitCapture(id: id) }
        case .discardTranscript:
            captureID = UUID()
            captureTask?.cancel()
            captureTask = nil
            let dictation = self.dictation
            cleanupTask = Task { await dictation.cancelListening() }
        case .stopSpeaking:
            speaker?.stop()
            speakingMessageID = nil
        }
        publish()
    }

    private func beginCapture(id: UUID) async {
        await cleanupTask?.value
        guard captureID == id, !Task.isCancelled else { return }
        let outcome = await dictation.requestPermission()
        guard captureID == id, !Task.isCancelled else { return }
        if let error = VoiceDictationError.forPermission(outcome) {
            fail(error)
            return
        }
        guard outcome == .granted else {
            // Still undetermined after a prompt: leave the composer typed-only.
            fail(.unavailable)
            return
        }
        do {
            try await dictation.startListening { [weak self] partial in
                Task { @MainActor in
                    guard let self, self.captureID == id else { return }
                    self.receive(partial: partial)
                }
            }
            guard captureID == id, !Task.isCancelled else {
                // A late start after closing must not leave the microphone open.
                // Never cancel a newer capture that now owns the controller.
                if !machine.isCapturing { await dictation.cancelListening() }
                return
            }
            machine.listeningStarted()
            publish()
        } catch let error as VoiceDictationError {
            guard captureID == id, !Task.isCancelled else { return }
            fail(error)
        } catch {
            guard captureID == id, !Task.isCancelled else { return }
            fail(.captureFailed(error.localizedDescription))
        }
    }

    private func commitCapture(id: UUID) async {
        let heard = await dictation.stopListening()
        guard captureID == id, !Task.isCancelled else { return }
        let transcript = machine.commitFinished(heard)
        publish()
        guard !transcript.isEmpty else {
            fail(.nothingHeard)
            return
        }
        onTranscript?(transcript)
    }

    private func receive(partial: String) {
        machine.partialReceived(partial)
        publish()
    }

    private func fail(_ error: VoiceDictationError) {
        apply(machine.failed(error.errorDescription ?? "Voice is unavailable."))
    }

    private func publish() {
        phase = machine.phase
        partialTranscript = machine.partialTranscript
    }
}
