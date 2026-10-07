import Foundation

/// Outcome of asking for the two permissions voice mode needs.
enum VoiceDictationPermission: String, Equatable, Sendable {
    case notDetermined
    case granted
    case microphoneDenied
    case speechDenied
    /// No recognizer for this locale, or the device can't transcribe.
    case unavailable
}

/// Voice is optional chrome: every failure here has recovery copy and leaves
/// typing, Ask, and reading untouched.
enum VoiceDictationError: Error, Equatable, LocalizedError, Sendable {
    case microphoneDenied
    case speechDenied
    case unavailable
    case nothingHeard
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone access is off. Turn it on in Settings → GenBooks to talk to BookBot — you can still type."
        case .speechDenied:
            return "Speech recognition is off. Turn it on in Settings → GenBooks to talk to BookBot — you can still type."
        case .unavailable:
            return "Voice isn’t available on this device right now. You can still type your question."
        case .nothingHeard:
            return "Didn’t catch that. Hold the mic and speak, or type instead."
        case .captureFailed(let reason):
            return "Voice stopped: \(reason). You can still type your question."
        }
    }

    /// Reading and typed Ask are never blocked by a voice failure.
    var isSoftFailure: Bool { true }

    static func forPermission(_ permission: VoiceDictationPermission) -> VoiceDictationError? {
        switch permission {
        case .granted, .notDetermined: return nil
        case .microphoneDenied: return .microphoneDenied
        case .speechDenied: return .speechDenied
        case .unavailable: return .unavailable
        }
    }
}

/// Microphone capture plus speech-to-text, behind a protocol so the Ask
/// composer can be driven by a deterministic stub in tests (no mic, no
/// permission dialog, no simulator audio route).
protocol VoiceDictating: AnyObject, Sendable {
    /// Asks for microphone + speech recognition. Safe to call repeatedly.
    func requestPermission() async -> VoiceDictationPermission

    /// Begins capture. `onPartial` fires with the running transcript.
    func startListening(onPartial: @escaping @Sendable (String) -> Void) async throws

    /// Ends capture and returns the best transcript heard (empty when silent).
    func stopListening() async -> String

    /// Ends capture and throws the transcript away.
    func cancelListening() async
}

/// Chooses stub vs real capture. UI tests must never open a permission dialog
/// or reach the audio hardware.
enum VoiceDictationResolver {
    static let stubArguments = ["-uitesting", "-mockVoice", "-stubVoice"]

    static func prefersStub(arguments: [String]) -> Bool {
        arguments.contains { stubArguments.contains($0) }
    }

    static func prefersStub(processInfo: ProcessInfo = .processInfo) -> Bool {
        prefersStub(arguments: processInfo.arguments)
    }
}

/// Deterministic dictation for UI tests and previews.
actor StubVoiceDictation: VoiceDictating {
    static let defaultPhrase = "What does this passage mean in context?"

    private let phrase: String
    private let permission: VoiceDictationPermission
    private var isCapturing = false

    init(phrase: String = StubVoiceDictation.defaultPhrase, permission: VoiceDictationPermission = .granted) {
        self.phrase = phrase
        self.permission = permission
    }

    func requestPermission() async -> VoiceDictationPermission { permission }

    func startListening(onPartial: @escaping @Sendable (String) -> Void) async throws {
        if let error = VoiceDictationError.forPermission(permission) { throw error }
        isCapturing = true
        // Yield so a UITest tap's finger-up can clear `pressStartedAt` before
        // `listeningStarted` runs — otherwise a >holdThreshold tap looks like a
        // hold and commits the instant the stub opens, hiding Listening.
        try await Task.sleep(nanoseconds: 120_000_000)
        guard isCapturing else { return }
        // One partial so the composer's live-transcript path is exercised.
        onPartial(Self.firstWords(of: phrase))
    }

    func stopListening() async -> String {
        let wasCapturing = isCapturing
        isCapturing = false
        return wasCapturing ? phrase : ""
    }

    func cancelListening() async {
        isCapturing = false
    }

    private static func firstWords(of text: String, count: Int = 3) -> String {
        text.split(separator: " ").prefix(count).joined(separator: " ")
    }
}
