import Foundation
import SwiftUI

/// Owns the Listen sheet's state: which chapter is loaded, which parts exist on
/// device, and what the player is doing.
///
/// It reads chapters through a provider closure and writes only to the Listen
/// stores. Listening never moves the reading checkpoint, never marks a chapter
/// consumed, and never mutates a revision — the reader's place is exactly where
/// they left it when the sheet closes.
@MainActor
final class ListenViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// Nothing playable on device yet for this chapter revision.
        case needsAudio
        case preparing
        case readyToPlay
        case playing
        case paused
        case finishedChapter
        case failed
    }

    /// Spotify-like skip defaults (Overcast asymmetry: recover 15, jump 30).
    static let rewindSeconds: TimeInterval = 15
    static let forwardSeconds: TimeInterval = 30

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var document: ListenDocument?
    @Published private(set) var chapterTitle: String = ""
    @Published private(set) var currentPartIndex: Int = 0
    @Published private(set) var downloadedPartCount: Int = 0
    @Published private(set) var isGenerating = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var voice: ListenVoice
    @Published private(set) var speed: ListenSpeed
    /// Playhead inside the current part.
    @Published private(set) var partElapsed: TimeInterval = 0
    @Published private(set) var partDuration: TimeInterval = 0
    /// Estimated chapter timeline (sum of known part durations; unknowns use average).
    @Published private(set) var chapterElapsed: TimeInterval = 0
    @Published private(set) var chapterDuration: TimeInterval = 0
    /// Warm highlight of the word currently being narrated (chunk-local UTF-16).
    @Published private(set) var highlightedWord: ListenWordTiming.WordSpan?
    /// True when a saved resume point was restored for this open.
    @Published private(set) var didRestoreResume = false

    private let bookId: UUID
    private let provider: ListenAudioProvider
    private let progressStore: any ListenProgressStoring
    private let hasAPIKey: @Sendable () -> Bool
    private let player: any ListenAudioPlaying
    private let documentProvider: @MainActor (UUID, ListenVoice) -> ListenDocument?
    private let chapterOrderProvider: @MainActor () -> [UUID]
    private let chapterTitleProvider: @MainActor (UUID) -> String

    private var chapterId: UUID?
    private var generateTask: Task<Void, Never>?
    /// Distinguishes the current synthesis run from a cancelled one that is still
    /// unwinding, so a stale run can't clear the new run's state.
    private var generationToken = 0
    /// Offset inside the current part that playback should start from.
    private var pendingStartOffset: TimeInterval = 0
    /// Measured durations for parts we've actually loaded (source of truth for seek math).
    private var knownPartDurations: [Int: TimeInterval] = [:]
    private var chapterTitlesCache: [UUID: String] = [:]

    init(
        bookId: UUID,
        services: ListenServices,
        player: (any ListenAudioPlaying)? = nil,
        voice: ListenVoice = .default,
        speed: ListenSpeed = .default,
        documentProvider: @escaping @MainActor (UUID, ListenVoice) -> ListenDocument?,
        chapterOrderProvider: @escaping @MainActor () -> [UUID],
        chapterTitleProvider: @escaping @MainActor (UUID) -> String = { _ in "" }
    ) {
        self.bookId = bookId
        self.provider = ListenAudioProvider(cache: services.cache, speech: services.speech)
        self.progressStore = services.progress
        self.hasAPIKey = services.hasAPIKey
        self.player = player ?? AVListenAudioPlayer()
        self.voice = voice
        self.speed = speed
        self.documentProvider = documentProvider
        self.chapterOrderProvider = chapterOrderProvider
        self.chapterTitleProvider = chapterTitleProvider

        self.player.onFinishedPart = { [weak self] in
            self?.handlePartFinished()
        }
        self.player.onTimeChange = { [weak self] time in
            self?.handleTimeChange(time)
        }
        wireRemoteCommandsIfPossible()
    }

    // MARK: - Derived copy

    var partCount: Int { document?.chunkCount ?? 0 }

    /// Narration can be made only with a synthesizer *and* a key. Checked live so
    /// adding a key in Reading settings enables Listen without a relaunch.
    var canSynthesize: Bool { provider.canSynthesize && hasAPIKey() }

    var isFullyDownloaded: Bool {
        guard let document else { return false }
        return provider.isFullyDownloaded(document)
    }

    var partLabel: String {
        guard partCount > 0 else { return "Nothing to narrate yet" }
        return "Part \(min(currentPartIndex + 1, partCount)) of \(partCount)"
    }

    var availabilityLabel: String {
        guard partCount > 0 else { return "" }
        if isFullyDownloaded { return "Downloaded — plays offline" }
        if isGenerating { return "Making narration… \(downloadedPartCount) of \(partCount) parts ready" }
        if downloadedPartCount == 0 { return "Not downloaded yet" }
        return "\(downloadedPartCount) of \(partCount) parts downloaded"
    }

    var downloadProgress: Double {
        guard partCount > 0 else { return 0 }
        return Double(downloadedPartCount) / Double(partCount)
    }

    var isPlaying: Bool { phase == .playing }

    var canPlayCurrentPart: Bool {
        guard let document else { return false }
        return provider.cachedURL(for: document, chunkIndex: currentPartIndex) != nil
    }

    var hasPreviousChapter: Bool { neighbourChapterId(offset: -1) != nil }
    var hasNextChapter: Bool { neighbourChapterId(offset: 1) != nil }

    var chapterProgress: Double {
        guard chapterDuration > 0 else { return 0 }
        return min(1, max(0, chapterElapsed / chapterDuration))
    }

    var elapsedLabel: String { Self.formatClock(chapterElapsed) }
    var remainingLabel: String {
        let left = max(0, chapterDuration - chapterElapsed)
        return "−\(Self.formatClock(left))"
    }

    var resumeHint: String? {
        guard didRestoreResume, partCount > 0 else { return nil }
        if chapterElapsed > 1 {
            return "Resume · \(elapsedLabel) in"
        }
        if currentPartIndex > 0 {
            return "Resume · part \(currentPartIndex + 1)"
        }
        return "Resume where you left off"
    }

    var chapterText: String {
        document?.chunks.map(\.text).joined(separator: "\n\n") ?? ""
    }

    var currentChunkText: String {
        document?.chunk(at: currentPartIndex)?.text ?? ""
    }

    var chapterList: [(id: UUID, title: String, isCurrent: Bool)] {
        let order = chapterOrderProvider()
        var rows: [(id: UUID, title: String, isCurrent: Bool)] = []
        rows.reserveCapacity(order.count)
        for id in order {
            let title: String
            if let cached = chapterTitlesCache[id], !cached.isEmpty {
                title = cached
            } else {
                let fetched = chapterTitleProvider(id)
                if !fetched.isEmpty { chapterTitlesCache[id] = fetched }
                title = fetched.isEmpty ? "Chapter" : fetched
            }
            rows.append((id, title, id == chapterId))
        }
        return rows
    }

    // MARK: - Lifecycle

    /// Loads a chapter for listening. Safe to call every time the sheet appears.
    func open(chapterId: UUID?) {
        guard let chapterId else {
            document = nil
            phase = .failed
            errorMessage = ListenError.emptyChapter.localizedDescription
            return
        }
        if self.chapterId == chapterId, document != nil {
            refreshAvailability()
            return
        }
        load(chapterId: chapterId, resumeFromSavedProgress: true)
    }

    /// Start narration at a tapped/long-pressed word in the readable revision.
    func openFromWord(chapterId: UUID, narrationUTF16Offset: Int) {
        load(chapterId: chapterId, resumeFromSavedProgress: false)
        guard let document else { return }
        if let located = ListenWordTiming.locate(utf16Offset: narrationUTF16Offset, in: document) {
            currentPartIndex = located.chunkIndex
            let chunkText = document.chunk(at: located.chunkIndex)?.text ?? ""
            let progress = ListenWordTiming.progress(forUTF16Offset: located.localUTF16, in: chunkText)
            // Prefer a measured duration; otherwise start at chunk beginning and
            // refine once audio loads (seekSeconds path uses known durations).
            if let duration = knownPartDurations[located.chunkIndex], duration > 0 {
                pendingStartOffset = progress * duration
            } else {
                pendingStartOffset = 0
                // Stash proportional seek for after first load of this part.
                pendingProportionalSeek = progress
            }
        }
        didRestoreResume = false
        refreshAvailability()
        startOrResume()
    }

    private var pendingProportionalSeek: Double?

    /// Records the resume point without stopping audio — backgrounding the app
    /// keeps an audiobook playing.
    func persistResumePoint() {
        saveProgress()
        refreshNowPlaying()
    }

    /// Stops audio and records where listening stopped. Reading state untouched.
    /// Call when leaving the reader entirely — not when dismissing the Listen sheet.
    func close() {
        generateTask?.cancel()
        generateTask = nil
        isGenerating = false
        saveProgress()
        player.stop()
        highlightedWord = nil
        if phase == .playing || phase == .paused { phase = .paused }
    }

    // MARK: - Transport

    func togglePlayPause() {
        guard document != nil else { return }
        if phase == .playing {
            pause()
        } else {
            startOrResume()
        }
    }

    func pause() {
        player.pause()
        phase = .paused
        saveProgress()
        refreshNowPlaying()
    }

    /// Skip within the chapter by whole parts — never blocks on synthesis.
    func skipPart(by delta: Int) {
        guard document != nil, partCount > 0 else { return }
        let wasPlaying = phase == .playing
        let target = min(max(0, currentPartIndex + delta), partCount - 1)
        currentPartIndex = target
        pendingStartOffset = 0
        pendingProportionalSeek = nil
        saveProgressOffsetZero()
        recomputeChapterTimeline()
        if wasPlaying {
            playCachedOrSoftFail(autoplay: true)
        } else {
            phase = canPlayCurrentPart ? .readyToPlay : .needsAudio
        }
        startPrefetchIfNeeded(autoplayFirstAt: nil)
        updateHighlight(for: partElapsed)
    }

    /// Spotify-like ±seconds. Seeks only through cached audio — never waits on TTS.
    func skipSeconds(_ delta: TimeInterval) {
        guard document != nil, partCount > 0 else { return }
        let wasPlaying = phase == .playing
        let targetElapsed = max(0, chapterElapsed + delta)
        guard let landing = resolveCachedLanding(forChapterElapsed: targetElapsed) else {
            errorMessage = ListenError.notDownloaded.localizedDescription
            startPrefetchIfNeeded(autoplayFirstAt: nil)
            return
        }
        currentPartIndex = landing.partIndex
        pendingStartOffset = landing.offsetInPart
        pendingProportionalSeek = nil
        partElapsed = landing.offsetInPart
        recomputeChapterTimeline()
        saveProgress()

        guard canPlayCurrentPart, let document else {
            phase = .needsAudio
            startPrefetchIfNeeded(autoplayFirstAt: nil)
            refreshNowPlaying()
            return
        }
        if wasPlaying {
            playCachedOrSoftFail(autoplay: true)
        } else if let url = provider.cachedURL(for: document, chunkIndex: currentPartIndex) {
            do {
                try player.load(url: url, startAt: pendingStartOffset, rate: speed.rawValue)
                knownPartDurations[currentPartIndex] = player.duration
                partDuration = player.duration
                partElapsed = player.currentTime
                pendingStartOffset = 0
                if phase != .paused { phase = .readyToPlay }
                recomputeChapterTimeline()
                updateHighlight(for: partElapsed)
            } catch {
                errorMessage = ListenError.malformedAudio.localizedDescription
            }
        }
        refreshNowPlaying()
    }

    func seekChapter(to elapsed: TimeInterval) {
        let delta = elapsed - chapterElapsed
        skipSeconds(delta)
    }

    func skipChapter(by delta: Int) {
        guard let target = neighbourChapterId(offset: delta) else { return }
        let wasPlaying = phase == .playing
        generateTask?.cancel()
        generateTask = nil
        isGenerating = false
        saveProgress()
        // Keep session active while hopping chapters mid-play.
        if !wasPlaying {
            player.stop()
        } else {
            player.pause()
        }
        knownPartDurations.removeAll()
        load(chapterId: target, resumeFromSavedProgress: false)
        startPrefetchIfNeeded(autoplayFirstAt: wasPlaying ? 0 : nil)
        if wasPlaying { startOrResume() }
    }

    func jumpToChapter(_ id: UUID) {
        guard id != chapterId else { return }
        let wasPlaying = phase == .playing
        generateTask?.cancel()
        generateTask = nil
        isGenerating = false
        saveProgress()
        if wasPlaying { player.pause() } else { player.stop() }
        knownPartDurations.removeAll()
        load(chapterId: id, resumeFromSavedProgress: true)
        startPrefetchIfNeeded(autoplayFirstAt: wasPlaying ? pendingStartOffset : nil)
        if wasPlaying { startOrResume() }
    }

    func select(voice newVoice: ListenVoice) {
        guard newVoice != voice else { return }
        let wasPlaying = phase == .playing
        let offset = player.currentTime
        generateTask?.cancel()
        generateTask = nil
        isGenerating = false
        player.stop()
        voice = newVoice
        knownPartDurations.removeAll()
        // Same prose, new narrator: keep the reader's part, drop the offset only
        // if the new voice has nothing cached to resume into.
        guard let chapterId else { return }
        let keptIndex = currentPartIndex
        load(chapterId: chapterId, resumeFromSavedProgress: false)
        currentPartIndex = min(keptIndex, max(0, partCount - 1))
        pendingStartOffset = canPlayCurrentPart ? offset : 0
        phase = canPlayCurrentPart ? .readyToPlay : .needsAudio
        startPrefetchIfNeeded(autoplayFirstAt: nil)
        if wasPlaying { startOrResume() }
    }

    func select(speed newSpeed: ListenSpeed) {
        speed = newSpeed
        player.setRate(newSpeed.rawValue)
        refreshNowPlaying()
    }

    // MARK: - Audio production

    /// Synthesize every missing part of this chapter, in order, so a partial
    /// download is still useful and a retry resumes.
    func downloadChapter() {
        guard let document else { return }
        guard canSynthesize else {
            errorMessage = ListenError.missingAPIKey.localizedDescription
            phase = .needsAudio
            return
        }
        guard !isGenerating else { return }
        startGeneration(document: document, from: 0, autoplayFirstAt: nil)
    }

    func cancelDownload() {
        generateTask?.cancel()
        generateTask = nil
        isGenerating = false
        refreshAvailability()
    }

    /// Frees the device copy of this chapter revision's narration.
    func removeDownload(matching expectedKey: ListenCacheKey? = nil) {
        guard let document else { return }
        guard expectedKey == nil || expectedKey == document.cacheKey else {
            errorMessage = "The chapter or voice changed. Open Remove download again to review the current audio."
            return
        }
        generateTask?.cancel()
        generateTask = nil
        isGenerating = false
        player.stop()
        do {
            try provider.cache.removeAudio(for: document.cacheKey)
            try? progressStore.clear(bookId: bookId, chapterId: document.chapterId)
            currentPartIndex = 0
            pendingStartOffset = 0
            knownPartDurations.removeAll()
            errorMessage = nil
        } catch {
            errorMessage = ListenError.storageFailed(error.localizedDescription).localizedDescription
        }
        refreshAvailability()
        recomputeChapterTimeline()
        phase = .needsAudio
    }

    /// Test seam: await any in-flight synthesis instead of sleeping.
    func awaitGeneration() async {
        await generateTask?.value
    }

    func refreshAvailability() {
        guard let document else {
            downloadedPartCount = 0
            return
        }
        downloadedPartCount = provider.cachedChunkCount(for: document)
        if phase == .idle || phase == .needsAudio || phase == .readyToPlay {
            phase = canPlayCurrentPart ? .readyToPlay : .needsAudio
        }
        recomputeChapterTimeline()
    }

    // MARK: - Internals

    private func load(chapterId: UUID, resumeFromSavedProgress: Bool) {
        self.chapterId = chapterId
        errorMessage = nil
        pendingStartOffset = 0
        pendingProportionalSeek = nil
        currentPartIndex = 0
        didRestoreResume = false
        highlightedWord = nil
        partElapsed = 0
        partDuration = 0

        let resolved = documentProvider(chapterId, voice)
        guard let doc = resolved, !doc.isEmpty else {
            document = nil
            chapterTitle = resolved?.chapterTitle ?? chapterTitle
            downloadedPartCount = 0
            phase = .failed
            errorMessage = ListenError.emptyChapter.localizedDescription
            return
        }
        document = doc
        chapterTitle = doc.chapterTitle
        chapterTitlesCache[chapterId] = doc.chapterTitle
        downloadedPartCount = provider.cachedChunkCount(for: doc)

        if resumeFromSavedProgress,
           let saved = try? progressStore.progress(bookId: bookId, chapterId: chapterId),
           saved.canResume(doc) {
            currentPartIndex = saved.chunkIndex
            pendingStartOffset = saved.offsetSeconds
            partElapsed = saved.offsetSeconds
            didRestoreResume = saved.chunkIndex > 0 || saved.offsetSeconds > 0.5
        }
        phase = canPlayCurrentPart ? .readyToPlay : .needsAudio
        recomputeChapterTimeline()
    }

    private func startOrResume() {
        guard let document else { return }
        errorMessage = nil
        if let url = provider.cachedURL(for: document, chunkIndex: currentPartIndex) {
            play(url: url, at: pendingStartOffset)
            // Keep filling the rest of the chapter while listening.
            startPrefetchIfNeeded(autoplayFirstAt: nil)
            return
        }
        guard canSynthesize else {
            phase = .needsAudio
            errorMessage = ListenError.missingAPIKey.localizedDescription
            return
        }
        phase = .preparing
        startGeneration(document: document, from: currentPartIndex, autoplayFirstAt: pendingStartOffset)
    }

    /// Fill missing narration only after playback or an explicit download.
    /// Browsing Listen, chapters or voices must not make a paid request.
    private func startPrefetchIfNeeded(autoplayFirstAt offset: TimeInterval?) {
        guard let document else { return }
        guard phase == .playing || phase == .paused || offset != nil else { return }
        guard canSynthesize else { return }
        guard !isGenerating else { return }
        let start = (0..<document.chunkCount).first {
            provider.cachedURL(for: document, chunkIndex: $0) == nil
        }
        guard let start else {
            // Current chapter complete — soft-prefetch next only while listening,
            // so a plain Download doesn't spend quota on the following chapter.
            if phase == .playing || phase == .paused {
                prefetchNeighbourChapter()
            }
            return
        }
        startGeneration(document: document, from: start, autoplayFirstAt: offset)
    }

    private func prefetchNeighbourChapter() {
        guard canSynthesize else { return }
        guard let nextId = neighbourChapterId(offset: 1) else { return }
        guard let nextDoc = documentProvider(nextId, voice), !nextDoc.isEmpty else { return }
        guard !provider.isFullyDownloaded(nextDoc) else { return }
        guard !isGenerating else { return }
        let start = (0..<nextDoc.chunkCount).first {
            provider.cachedURL(for: nextDoc, chunkIndex: $0) == nil
        } ?? 0
        // Prefetch into the next chapter's cache without changing the UI document.
        startGeneration(document: nextDoc, from: start, autoplayFirstAt: nil, updateUIDocument: false)
    }

    private func playCachedOrSoftFail(autoplay: Bool) {
        guard let document else { return }
        if let url = provider.cachedURL(for: document, chunkIndex: currentPartIndex) {
            if autoplay {
                play(url: url, at: pendingStartOffset)
            }
            return
        }
        // Do not enter preparing for a skip — soft-fail and prefetch.
        player.pause()
        phase = .needsAudio
        errorMessage = ListenError.notDownloaded.localizedDescription
        startPrefetchIfNeeded(autoplayFirstAt: nil)
    }

    private func play(url: URL, at offset: TimeInterval) {
        do {
            try player.load(url: url, startAt: offset, rate: speed.rawValue)
            knownPartDurations[currentPartIndex] = player.duration
            partDuration = player.duration
            partElapsed = offset
            if let proportional = pendingProportionalSeek, player.duration > 0 {
                let seekTo = proportional * player.duration
                player.seek(to: seekTo)
                partElapsed = seekTo
                pendingProportionalSeek = nil
            }
            pendingStartOffset = 0
            recomputeChapterTimeline()
            player.play()
            phase = .playing
            updateHighlight(for: partElapsed)
            refreshNowPlaying()
        } catch {
            phase = .failed
            errorMessage = ListenError.malformedAudio.localizedDescription
        }
    }

    private func startGeneration(
        document: ListenDocument,
        from startIndex: Int,
        autoplayFirstAt offset: TimeInterval?,
        updateUIDocument: Bool = true
    ) {
        generateTask?.cancel()
        generationToken += 1
        let token = generationToken
        isGenerating = true
        if updateUIDocument {
            errorMessage = nil
        }
        generateTask = Task { [weak self] in
            guard let self else { return }
            var index = startIndex
            while index < document.chunkCount {
                if Task.isCancelled { break }
                do {
                    let url = try await self.provider.audioURL(for: document, chunkIndex: index)
                    if Task.isCancelled { break }
                    if updateUIDocument, self.document?.cacheKey == document.cacheKey {
                        self.downloadedPartCount = self.provider.cachedChunkCount(for: document)
                        self.recomputeChapterTimeline()
                    }
                    if updateUIDocument,
                       index == startIndex,
                       let offset,
                       self.document?.cacheKey == document.cacheKey {
                        self.play(url: url, at: offset)
                    }
                } catch is CancellationError {
                    break
                } catch {
                    if token == self.generationToken, updateUIDocument {
                        self.presentGenerationFailure(error)
                    }
                    break
                }
                index += 1
            }
            guard token == self.generationToken else { return }
            self.isGenerating = false
            self.generateTask = nil
            if updateUIDocument, self.phase == .preparing {
                self.phase = self.canPlayCurrentPart ? .readyToPlay : .needsAudio
            }
            // After finishing current chapter audio, quietly start the next while listening.
            if updateUIDocument, self.isFullyDownloaded,
               self.phase == .playing || self.phase == .paused {
                self.prefetchNeighbourChapter()
            }
        }
    }

    private func presentGenerationFailure(_ error: Error) {
        let listenError = (error as? ListenError) ?? .underlying(error.localizedDescription)
        errorMessage = listenError.localizedDescription
        // Parts already on device keep playing — a synthesis failure is never fatal.
        if phase != .playing {
            phase = canPlayCurrentPart ? .readyToPlay : .failed
        }
    }

    private func handlePartFinished() {
        guard let document else { return }
        let next = currentPartIndex + 1
        guard next < document.chunkCount else {
            phase = .finishedChapter
            partElapsed = partDuration
            recomputeChapterTimeline()
            saveProgressOffsetZero()
            refreshNowPlaying()
            return
        }
        currentPartIndex = next
        pendingStartOffset = 0
        pendingProportionalSeek = nil
        saveProgressOffsetZero()
        if let url = provider.cachedURL(for: document, chunkIndex: next) {
            play(url: url, at: 0)
        } else if canSynthesize {
            // End of cached runway — prepare next part (user hit natural end, not skip).
            phase = .preparing
            startGeneration(document: document, from: next, autoplayFirstAt: 0)
        } else {
            phase = .needsAudio
            errorMessage = ListenError.notDownloaded.localizedDescription
        }
    }

    private func handleTimeChange(_ time: TimeInterval) {
        partElapsed = time
        if player.duration > 0 {
            knownPartDurations[currentPartIndex] = player.duration
            partDuration = player.duration
        }
        recomputeChapterTimeline()
        updateHighlight(for: time)
        // Lightweight Now Playing elapsed sync — rate already set; OS interpolates.
        refreshNowPlaying()
        if Int(time * 4) % 8 == 0 {
            saveProgress()
        }
    }

    private func updateHighlight(for time: TimeInterval) {
        let text = currentChunkText
        let words = ListenWordTiming.words(in: text)
        let duration = max(partDuration, 0.001)
        let progress = min(max(time / duration, 0), 1)
        if let index = ListenWordTiming.wordIndex(atProgress: progress, words: words) {
            highlightedWord = words[index]
        } else {
            highlightedWord = nil
        }
    }

    private func neighbourChapterId(offset: Int) -> UUID? {
        guard let chapterId else { return nil }
        let order = chapterOrderProvider()
        guard let index = order.firstIndex(of: chapterId) else { return nil }
        let target = index + offset
        guard order.indices.contains(target) else { return nil }
        return order[target]
    }

    private func saveProgress() {
        persistProgress(offset: player.currentTime > 0 ? player.currentTime : partElapsed)
    }

    private func saveProgressOffsetZero() {
        persistProgress(offset: 0)
    }

    private func persistProgress(offset: TimeInterval) {
        guard let document else { return }
        let progress = ListenProgress(
            bookId: bookId,
            chapterId: document.chapterId,
            revisionId: document.revisionId,
            voice: document.voice,
            chunkIndex: currentPartIndex,
            offsetSeconds: max(0, offset)
        )
        // Soft-fail: a failed resume write must not interrupt listening.
        try? progressStore.save(progress)
    }

    private func estimatedPartDuration(_ index: Int) -> TimeInterval {
        if let known = knownPartDurations[index], known > 0 { return known }
        let knownValues = knownPartDurations.values.filter { $0 > 0 }
        if let avg = knownValues.isEmpty ? nil : knownValues.reduce(0, +) / Double(knownValues.count) {
            return avg
        }
        // ~2.5 minutes of speech per preferred chunk as a cold estimate.
        return 150
    }

    private func recomputeChapterTimeline() {
        guard partCount > 0 else {
            chapterElapsed = 0
            chapterDuration = 0
            return
        }
        var total: TimeInterval = 0
        var elapsed: TimeInterval = 0
        for index in 0..<partCount {
            let duration = estimatedPartDuration(index)
            if index < currentPartIndex {
                elapsed += duration
            } else if index == currentPartIndex {
                elapsed += min(partElapsed, duration)
            }
            total += duration
        }
        chapterElapsed = elapsed
        chapterDuration = total
    }

    /// Landing inside contiguous *cached* audio for a chapter-elapsed target.
    private func resolveCachedLanding(forChapterElapsed target: TimeInterval) -> (partIndex: Int, offsetInPart: TimeInterval)? {
        guard let document, partCount > 0 else { return nil }
        var cursor: TimeInterval = 0
        var lastCached: (Int, TimeInterval)?
        for index in 0..<partCount {
            guard provider.cachedURL(for: document, chunkIndex: index) != nil else {
                // Gap in cache — stop at last cached landing.
                break
            }
            let duration = estimatedPartDuration(index)
            let start = cursor
            let end = cursor + duration
            if target <= end || index == partCount - 1 {
                let offset = min(max(0, target - start), max(0, duration - 0.05))
                return (index, offset)
            }
            lastCached = (index, max(0, duration - 0.05))
            cursor = end
        }
        return lastCached.map { ($0.0, $0.1) }
    }

    private func refreshNowPlaying() {
        player.updateNowPlaying(
            title: chapterTitle.isEmpty ? "Listen" : chapterTitle,
            chapterTitle: partLabel,
            elapsedInChapter: chapterElapsed,
            chapterDuration: chapterDuration,
            rate: speed.rawValue,
            isPlaying: phase == .playing
        )
    }

    private func wireRemoteCommandsIfPossible() {
        guard let av = player as? AVListenAudioPlayer else { return }
        av.remotePlay = { [weak self] in self?.startOrResume() }
        av.remotePause = { [weak self] in self?.pause() }
        av.remoteSkipForward = { [weak self] seconds in self?.skipSeconds(seconds) }
        av.remoteSkipBackward = { [weak self] seconds in self?.skipSeconds(-seconds) }
        av.remoteSeekChapter = { [weak self] elapsed in self?.seekChapter(to: elapsed) }
    }

    static func formatClock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
