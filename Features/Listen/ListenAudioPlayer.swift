import AVFoundation
import Foundation
import MediaPlayer

/// Playback surface for one narration part at a time.
///
/// A protocol so the Listen view model can be driven by a fake in unit tests —
/// no audio session, no simulator audio route, no waiting for real seconds.
@MainActor
protocol ListenAudioPlaying: AnyObject {
    var isPlaying: Bool { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    /// Called when the loaded part reaches its end.
    var onFinishedPart: (() -> Void)? { get set }
    /// Periodic playhead updates while playing (also fires after seeks).
    var onTimeChange: ((TimeInterval) -> Void)? { get set }

    func load(url: URL, startAt: TimeInterval, rate: Double) throws
    func play()
    func pause()
    func stop()
    func setRate(_ rate: Double)
    func seek(to time: TimeInterval)
    /// Publish lock-screen / Control Center metadata for the current part.
    func updateNowPlaying(
        title: String,
        chapterTitle: String,
        elapsedInChapter: TimeInterval,
        chapterDuration: TimeInterval,
        rate: Double,
        isPlaying: Bool
    )
    func clearNowPlaying()
}

/// `AVAudioPlayer`-backed narration playback with background audio + Now Playing.
///
/// One part is loaded at a time and the view model advances the playlist on
/// completion, which keeps "resume where I stopped" honest: a saved position is
/// a part index plus an offset inside that part.
@MainActor
final class AVListenAudioPlayer: ListenAudioPlaying {
    var onFinishedPart: (() -> Void)?
    var onTimeChange: ((TimeInterval) -> Void)?

    private var player: AVAudioPlayer?
    private let bridge = AudioPlayerDelegateBridge()
    private var didActivateSession = false
    private var didConfigureRemote = false
    private var tickTimer: Timer?
    private var nowPlayingTitle = "Listen"
    private var nowPlayingChapter = ""
    private var chapterElapsedBase: TimeInterval = 0
    private var chapterDurationHint: TimeInterval = 0

    /// Wired by the view model so lock-screen skip/play hit the same transport.
    var remotePlay: (() -> Void)?
    var remotePause: (() -> Void)?
    var remoteSkipForward: ((TimeInterval) -> Void)?
    var remoteSkipBackward: ((TimeInterval) -> Void)?
    var remoteSeekChapter: ((TimeInterval) -> Void)?

    init() {
        bridge.onFinish = { [weak self] _ in
            Task { @MainActor in
                self?.stopTicker()
                self?.onFinishedPart?()
            }
        }
    }

    var isPlaying: Bool { player?.isPlaying ?? false }
    var currentTime: TimeInterval { player?.currentTime ?? 0 }
    var duration: TimeInterval { player?.duration ?? 0 }

    func load(url: URL, startAt: TimeInterval, rate: Double) throws {
        player?.stop()
        stopTicker()
        let created = try AVAudioPlayer(contentsOf: url)
        created.delegate = bridge
        // `enableRate` must be set before preparing; `rate` only sticks afterwards.
        created.enableRate = true
        created.prepareToPlay()
        created.rate = Float(rate)
        if startAt > 0, startAt < created.duration {
            created.currentTime = startAt
        }
        player = created
        onTimeChange?(created.currentTime)
    }

    func play() {
        activateSessionIfNeeded()
        configureRemoteCommandsIfNeeded()
        player?.play()
        startTicker()
        pushNowPlayingPlaybackState(isPlaying: true)
    }

    func pause() {
        player?.pause()
        stopTicker()
        pushNowPlayingPlaybackState(isPlaying: false)
        onTimeChange?(currentTime)
    }

    func stop() {
        player?.stop()
        player = nil
        stopTicker()
        clearNowPlaying()
        deactivateSession()
    }

    func setRate(_ rate: Double) {
        player?.enableRate = true
        player?.rate = Float(rate)
        pushNowPlayingPlaybackState(isPlaying: isPlaying)
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        let clamped = min(max(0, time), max(0, player.duration - 0.05))
        player.currentTime = clamped
        onTimeChange?(clamped)
        pushNowPlayingPlaybackState(isPlaying: isPlaying)
    }

    func updateNowPlaying(
        title: String,
        chapterTitle: String,
        elapsedInChapter: TimeInterval,
        chapterDuration: TimeInterval,
        rate: Double,
        isPlaying: Bool
    ) {
        nowPlayingTitle = title
        nowPlayingChapter = chapterTitle
        chapterElapsedBase = max(0, elapsedInChapter - currentTime)
        chapterDurationHint = max(chapterDuration, currentTime)
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyAlbumTitle: chapterTitle,
            MPMediaItemPropertyArtist: "GenBooks",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, elapsedInChapter),
            MPMediaItemPropertyPlaybackDuration: max(chapterDurationHint, elapsedInChapter),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: rate
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        _ = info
    }

    func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// Spoken audio, so narration behaves like an audiobook: it keeps playing
    /// with the screen locked and respects the silent switch the way Books does.
    private func activateSessionIfNeeded() {
        guard !didActivateSession else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [])
        try? session.setActive(true)
        didActivateSession = true
    }

    private func deactivateSession() {
        guard didActivateSession else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        didActivateSession = false
    }

    private func configureRemoteCommandsIfNeeded() {
        guard !didConfigureRemote else { return }
        didConfigureRemote = true
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.remotePlay?() }
            return .success
        }
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.remotePause?() }
            return .success
        }
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.isPlaying { self.remotePause?() } else { self.remotePlay?() }
            }
            return .success
        }

        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.addTarget { [weak self] event in
            let seconds = (event as? MPSkipIntervalCommandEvent)?.interval ?? 30
            Task { @MainActor in self?.remoteSkipForward?(seconds) }
            return .success
        }
        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] event in
            let seconds = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            Task { @MainActor in self?.remoteSkipBackward?(seconds) }
            return .success
        }

        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let position = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in self?.remoteSeekChapter?(position.positionTime) }
            return .success
        }

        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }

    private func pushNowPlayingPlaybackState(isPlaying: Bool) {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        let elapsed = chapterElapsedBase + currentTime
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPMediaItemPropertyPlaybackDuration] = max(chapterDurationHint, elapsed)
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(player?.rate ?? 1) : 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func startTicker() {
        stopTicker()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                self.onTimeChange?(self.currentTime)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func stopTicker() {
        tickTimer?.invalidate()
        tickTimer = nil
    }
}

/// `AVAudioPlayerDelegate` conformance lives off the main-actor type so the
/// callback can hop to the main actor explicitly.
private final class AudioPlayerDelegateBridge: NSObject, AVAudioPlayerDelegate {
    var onFinish: (@Sendable (Bool) -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish?(flag)
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        onFinish?(false)
    }
}
