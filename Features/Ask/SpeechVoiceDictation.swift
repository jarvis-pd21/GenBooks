import AVFoundation
import Foundation
import Speech

/// Real microphone capture for talking to BookBot: `AVAudioEngine` taps feed an
/// `SFSpeechRecognizer` buffer request, and the running transcription is handed
/// back so the composer can show words as they land.
///
/// On-device recognition is requested whenever the device supports it, which
/// keeps a reading question off the network the same way Define does.
@MainActor
final class SpeechVoiceDictation: VoiceDictating {
    /// How long to wait for the recognizer to flush a final result after the
    /// mic closes. Past this the best partial is used instead of stalling.
    private static let finalResultGrace: TimeInterval = 1.5

    private let engine = AVAudioEngine()
    private let recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var bestTranscript = ""
    private var didStartEngine = false
    private var didActivateSession = false
    private var captureID = UUID()

    init(locale: Locale = .current) {
        recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
    }

    func requestPermission() async -> VoiceDictationPermission {
        guard let recognizer else { return .unavailable }

        let speechStatus = await Self.requestSpeechAuthorization()
        guard !Task.isCancelled else { return .notDetermined }
        switch speechStatus {
        case .authorized:
            break
        case .notDetermined:
            return .notDetermined
        default:
            return .speechDenied
        }

        guard await Self.requestMicrophonePermission() else { return .microphoneDenied }
        guard recognizer.isAvailable else { return .unavailable }
        return .granted
    }

    func startListening(onPartial: @escaping @Sendable (String) -> Void) async throws {
        await cancelListening()
        try Task.checkCancellation()
        let id = captureID

        guard let recognizer, recognizer.isAvailable else {
            throw VoiceDictationError.unavailable
        }

        try activateSession()

        let bufferRequest = SFSpeechAudioBufferRecognitionRequest()
        bufferRequest.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            bufferRequest.requiresOnDeviceRecognition = true
        }
        request = bufferRequest
        bestTranscript = ""

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            deactivateSession()
            throw VoiceDictationError.captureFailed("no microphone input")
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            bufferRequest.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
            didStartEngine = true
        } catch {
            input.removeTap(onBus: 0)
            request = nil
            deactivateSession()
            throw VoiceDictationError.captureFailed(error.localizedDescription)
        }

        task = recognizer.recognitionTask(with: bufferRequest) { [weak self] result, error in
            // The handler is not main-actor isolated, so only Sendable values
            // cross the hop.
            let transcript = result?.bestTranscription.formattedString
            let isFinished = error != nil || result?.isFinal == true
            guard let self else { return }
            Task { @MainActor in
                guard self.captureID == id else { return }
                if let transcript {
                    self.bestTranscript = transcript
                    onPartial(transcript)
                }
                if isFinished {
                    self.releaseTask()
                }
            }
        }
    }

    func stopListening() async -> String {
        guard didStartEngine || request != nil else { return "" }
        let id = captureID
        request?.endAudio()
        teardownAudio()

        await Self.waitForFinalResult {
            self.captureID == id && self.task != nil
        }
        guard captureID == id else { return "" }
        guard !Task.isCancelled else {
            await cancelListening()
            return ""
        }
        let transcript = bestTranscript
        captureID = UUID()
        task?.cancel()
        releaseTask()
        deactivateSession()
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancelListening() async {
        captureID = UUID()
        request?.endAudio()
        task?.cancel()
        teardownAudio()
        releaseTask()
        bestTranscript = ""
        deactivateSession()
    }

    /// Cancellation exits the wait immediately; suppressing a cancelled sleep
    /// would busy-spin on the main actor until the grace deadline.
    static func waitForFinalResult(while isPending: () -> Bool) async {
        let deadline = Date().addingTimeInterval(finalResultGrace)
        while !Task.isCancelled, isPending(), Date() < deadline {
            do { try await Task.sleep(nanoseconds: 100_000_000) }
            catch { return }
        }
    }

    // MARK: - Audio session

    /// `playAndRecord` rather than `record` so a spoken reply can follow the
    /// question without tearing the session down and back up.
    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .spokenAudio,
                options: [.duckOthers, .defaultToSpeaker, .allowBluetooth]
            )
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            didActivateSession = true
        } catch {
            throw VoiceDictationError.captureFailed(error.localizedDescription)
        }
    }

    private func deactivateSession() {
        guard didActivateSession else { return }
        didActivateSession = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func teardownAudio() {
        if didStartEngine {
            engine.stop()
            didStartEngine = false
        }
        engine.inputNode.removeTap(onBus: 0)
    }

    private func releaseTask() {
        task = nil
        request = nil
    }

    // MARK: - Permissions

    private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .notDetermined else { return status }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { updated in
                continuation.resume(returning: updated)
            }
        }
    }

    private static func requestMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }
}

enum AskVoiceFactory {
    @MainActor
    static func makeDictation(processInfo: ProcessInfo = .processInfo) -> any VoiceDictating {
        VoiceDictationResolver.prefersStub(processInfo: processInfo)
            ? StubVoiceDictation()
            : SpeechVoiceDictation()
    }

    /// Answers are spoken by default, so an automated run gets no speaker at
    /// all: a UI suite must not read mock answers out of the machine running
    /// it. Returning nil also hides the speak affordances, which is what the
    /// Ask sheet keys off.
    @MainActor
    static func makeReplySpeaker(
        services: ListenServices?,
        processInfo: ProcessInfo = .processInfo
    ) -> BookBotReplySpeaker? {
        guard !VoiceDictationResolver.prefersStub(processInfo: processInfo) else { return nil }
        return BookBotReplySpeaker(services: services)
    }
}
