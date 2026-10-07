import AVFoundation
import Foundation

/// Reads a BookBot reply aloud.
///
/// The narration path Listen already owns comes first: `SpeechSynthesizing`
/// renders the reply with the same narrator voice the reader picked for
/// chapters, and `ListenAudioPlaying` plays it. With no Keychain key — the
/// Simulator default — it falls back to on-device `AVSpeechSynthesizer`, so
/// voice mode still answers out loud with nothing configured.
@MainActor
final class BookBotReplySpeaker {
    /// Replies can run long; only the head is narrated so a reader who asked a
    /// quick question isn't held hostage by a paragraph.
    static let maximumSpokenCharacters = 1_200

    /// Fires on every start/stop so the composer can show a speaking state.
    var onSpeakingChange: ((Bool) -> Void)?

    private(set) var isSpeaking = false

    private let speech: (any SpeechSynthesizing)?
    private let hasAPIKey: () -> Bool
    private let voice: ListenVoice
    private let player: any ListenAudioPlaying
    private let onDevice: AVSpeechSynthesizer
    private let onDeviceBridge = OnDeviceSpeechBridge()
    private var synthesisTask: Task<Void, Never>?
    private var temporaryAudioURL: URL?

    init(
        services: ListenServices?,
        voice: ListenVoice = .default,
        player: (any ListenAudioPlaying)? = nil,
        onDevice: AVSpeechSynthesizer = AVSpeechSynthesizer()
    ) {
        self.speech = services?.speech
        self.hasAPIKey = services?.hasAPIKey ?? { false }
        self.voice = voice
        self.player = player ?? ReplyAudioPlayer()
        self.onDevice = onDevice

        onDeviceBridge.onFinish = { [weak self] in
            Task { @MainActor in self?.finishSpeaking() }
        }
        self.onDevice.delegate = onDeviceBridge
        self.player.onFinishedPart = { [weak self] in
            self?.finishSpeaking()
        }
    }

    func speak(_ text: String) {
        let spoken = Self.spokenText(from: text)
        guard !spoken.isEmpty else { return }
        stop()
        beginSpeaking()

        guard let speech, hasAPIKey() else {
            speakOnDevice(spoken)
            return
        }

        synthesisTask = Task { [weak self] in
            guard let self else { return }
            let request = SpeechSynthesisRequest(text: spoken, voice: self.voice)
            let data = try? await speech.synthesize(request)
            guard !Task.isCancelled else { return }
            if let data, ListenAudioValidator.looksLikeMP3(data), self.play(data) {
                return
            }
            // Narration is best-effort: a rejected key, a rate limit, or a
            // truncated body still gets the reader an answer out loud.
            self.speakOnDevice(spoken)
        }
    }

    func stop() {
        synthesisTask?.cancel()
        synthesisTask = nil
        if onDevice.isSpeaking {
            onDevice.stopSpeaking(at: .immediate)
        }
        player.stop()
        cleanupTemporaryAudio()
        if isSpeaking {
            isSpeaking = false
            onSpeakingChange?(false)
        }
    }

    // MARK: - Playback

    private func play(_ data: Data) -> Bool {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bookbot-reply-\(UUID().uuidString).mp3")
        do {
            try data.write(to: url, options: .atomic)
            activatePlaybackSession()
            try player.load(url: url, startAt: 0, rate: 1.0)
        } catch {
            try? FileManager.default.removeItem(at: url)
            return false
        }
        cleanupTemporaryAudio()
        temporaryAudioURL = url
        player.play()
        return true
    }

    private func speakOnDevice(_ text: String) {
        activatePlaybackSession()
        beginSpeaking()
        onDevice.speak(AVSpeechUtterance(string: text))
    }

    private func activatePlaybackSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [])
        try? session.setActive(true)
    }

    private func beginSpeaking() {
        guard !isSpeaking else { return }
        isSpeaking = true
        onSpeakingChange?(true)
    }

    private func finishSpeaking() {
        cleanupTemporaryAudio()
        guard isSpeaking else { return }
        isSpeaking = false
        onSpeakingChange?(false)
    }

    private func cleanupTemporaryAudio() {
        guard let temporaryAudioURL else { return }
        self.temporaryAudioURL = nil
        try? FileManager.default.removeItem(at: temporaryAudioURL)
    }

    /// Reply text is prose meant for the eye; strip the few markers BookBot uses
    /// so they aren't read out as punctuation, and cap the length.
    static func spokenText(from text: String) -> String {
        var stripped = text
        for marker in ["**", "__", "`", "#"] {
            stripped = stripped.replacingOccurrences(of: marker, with: "")
        }
        stripped = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard stripped.count > maximumSpokenCharacters else { return stripped }
        let cut = stripped.index(stripped.startIndex, offsetBy: maximumSpokenCharacters)
        let head = String(stripped[..<cut])
        // Prefer to stop on a sentence so the cut doesn't sound like a dropout.
        if let lastStop = head.lastIndex(where: { ".!?".contains($0) }) {
            return String(head[...lastStop])
        }
        return head
    }
}

/// Playback for a spoken reply.
///
/// It satisfies the same `ListenAudioPlaying` contract the narration player
/// does — so a fake can drive it in tests — but deliberately claims neither Now
/// Playing nor the remote command centre: an answer to a question is not an
/// audiobook and must not take over the lock screen from Listen.
@MainActor
private final class ReplyAudioPlayer: ListenAudioPlaying {
    var onFinishedPart: (() -> Void)?
    var onTimeChange: ((TimeInterval) -> Void)?

    private var player: AVAudioPlayer?
    private let bridge = ReplyPlayerDelegateBridge()

    init() {
        bridge.onFinish = { [weak self] in
            Task { @MainActor in self?.onFinishedPart?() }
        }
    }

    var isPlaying: Bool { player?.isPlaying ?? false }
    var currentTime: TimeInterval { player?.currentTime ?? 0 }
    var duration: TimeInterval { player?.duration ?? 0 }

    func load(url: URL, startAt: TimeInterval, rate: Double) throws {
        player?.stop()
        let created = try AVAudioPlayer(contentsOf: url)
        created.delegate = bridge
        created.enableRate = true
        created.prepareToPlay()
        created.rate = Float(rate)
        player = created
    }

    func play() { player?.play() }
    func pause() { player?.pause() }

    func stop() {
        player?.stop()
        player = nil
    }

    func setRate(_ rate: Double) {
        player?.enableRate = true
        player?.rate = Float(rate)
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(0, time), max(0, player.duration - 0.05))
    }

    func updateNowPlaying(
        title: String,
        chapterTitle: String,
        elapsedInChapter: TimeInterval,
        chapterDuration: TimeInterval,
        rate: Double,
        isPlaying: Bool
    ) {}

    func clearNowPlaying() {}
}

private final class ReplyPlayerDelegateBridge: NSObject, AVAudioPlayerDelegate {
    var onFinish: (@Sendable () -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish?()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        onFinish?()
    }
}

/// `AVSpeechSynthesizerDelegate` conformance lives off the main-actor type so
/// the callbacks can hop to the main actor explicitly.
private final class OnDeviceSpeechBridge: NSObject, AVSpeechSynthesizerDelegate {
    var onFinish: (@Sendable () -> Void)?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onFinish?()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        onFinish?()
    }
}
