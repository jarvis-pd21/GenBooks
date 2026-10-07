import Foundation

/// What the Ask composer is doing with the microphone right now.
enum VoiceModePhase: Equatable, Sendable {
    case idle
    /// Permission / audio engine spin-up.
    case preparing
    /// Capturing. `latched` means the reader tapped (push-to-talk) rather than
    /// holding, so the mic stays open until they tap again.
    case listening(latched: Bool)
    /// Mic closed, waiting for the final transcript.
    case finishing
    /// A reply is being read back.
    case speaking
    case failed(String)
}

/// The push-to-talk / hold-to-talk rules, kept out of SwiftUI so they can be
/// tested without a mic, an audio session, or a simulator.
///
/// One control serves both gestures: a quick tap latches the mic open (tap again
/// to send), while a real hold keeps it open only while held and sends on
/// release. `holdThreshold` is what separates the two.
struct VoiceModeMachine: Equatable, Sendable {
    static let holdThreshold: TimeInterval = 0.35

    /// Work the machine wants its owner to perform. The machine itself never
    /// touches audio.
    enum Effect: Equatable, Sendable {
        case none
        case startListening
        case commitTranscript
        case discardTranscript
        case stopSpeaking
    }

    private(set) var phase: VoiceModePhase = .idle
    private(set) var partialTranscript = ""

    private var pressStartedAt: TimeInterval?
    private var latchedBeforePress = false

    var isPressed: Bool { pressStartedAt != nil }

    var isListening: Bool {
        switch phase {
        case .preparing, .listening: return true
        default: return false
        }
    }

    var isSpeaking: Bool { phase == .speaking }

    /// True while the mic control should read as "active" (recording or closing).
    var isCapturing: Bool {
        switch phase {
        case .preparing, .listening, .finishing: return true
        default: return false
        }
    }

    var failureMessage: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    /// Copy for the single status line under the composer.
    var statusText: String {
        switch phase {
        case .idle:
            return ""
        case .preparing:
            return "Getting the mic ready…"
        case .listening(let latched):
            return latched ? "Listening… tap the mic to send" : "Listening… release to send"
        case .finishing:
            return "Transcribing…"
        case .speaking:
            return "BookBot is speaking"
        case .failed(let message):
            return message
        }
    }

    // MARK: - Gesture input

    mutating func pressBegan(at time: TimeInterval) -> Effect {
        switch phase {
        case .idle, .failed:
            pressStartedAt = time
            latchedBeforePress = false
            partialTranscript = ""
            phase = .preparing
            return .startListening
        case .listening(let latched):
            pressStartedAt = time
            latchedBeforePress = latched
            return .none
        case .preparing, .finishing:
            return .none
        case .speaking:
            // Tapping the mic while a reply plays stops the reply; the next tap talks.
            phase = .idle
            return .stopSpeaking
        }
    }

    mutating func pressEnded(at time: TimeInterval, treatAsTap: Bool = false) -> Effect {
        guard let startedAt = pressStartedAt else { return .none }
        pressStartedAt = nil
        // Stub/UITest taps often exceed `holdThreshold` on the wall clock. The
        // caller marks those as taps so the first release latches instead of
        // hold-committing the instant StubVoiceDictation transcript.
        let wasHeld = treatAsTap ? false : (time - startedAt) >= Self.holdThreshold

        switch phase {
        case .preparing:
            // Mic is not open yet. Finger-up here becomes a latch once listening
            // starts (including UITest taps whose wall-clock duration exceeds
            // holdThreshold). Committing now would send an empty transcript.
            return .none
        case .listening:
            if wasHeld || latchedBeforePress {
                phase = .finishing
                return .commitTranscript
            }
            phase = .listening(latched: true)
            return .none
        default:
            return .none
        }
    }

    /// A Button action that arrived with the same finger as `pressChanged`.
    /// Turns an unlatched listen into a latch; no-ops otherwise.
    mutating func latchListening() {
        guard case .listening = phase else { return }
        phase = .listening(latched: true)
    }

    // MARK: - Capture callbacks

    mutating func listeningStarted() {
        guard phase == .preparing else { return }
        phase = .listening(latched: !isPressed)
    }

    mutating func partialReceived(_ text: String) {
        guard isListening else { return }
        partialTranscript = text
    }

    /// Final transcript arrived. Returns the text the composer should take,
    /// falling back to the last partial when the recognizer ends empty.
    mutating func commitFinished(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let final = trimmed.isEmpty ? fallback : trimmed
        partialTranscript = ""
        pressStartedAt = nil
        phase = .idle
        return final
    }

    mutating func failed(_ message: String) -> Effect {
        let wasCapturing = isCapturing
        partialTranscript = ""
        pressStartedAt = nil
        phase = .failed(message)
        return wasCapturing ? .discardTranscript : .none
    }

    mutating func cancel() -> Effect {
        partialTranscript = ""
        pressStartedAt = nil
        switch phase {
        case .preparing, .listening, .finishing:
            phase = .idle
            return .discardTranscript
        case .speaking:
            phase = .idle
            return .stopSpeaking
        case .idle, .failed:
            phase = .idle
            return .none
        }
    }

    mutating func speakingStarted() {
        guard !isCapturing else { return }
        phase = .speaking
    }

    mutating func speakingStopped() {
        guard phase == .speaking else { return }
        phase = .idle
    }

    /// Clears a stale failure so the next tap starts clean.
    mutating func clearFailure() {
        if case .failed = phase { phase = .idle }
    }
}
