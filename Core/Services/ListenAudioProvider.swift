import Foundation

/// Resolves narration audio one chunk at a time: cache first, network only for
/// what is missing.
///
/// Chunks are synthesized sequentially by the caller rather than in parallel, so
/// a chapter that fails halfway still leaves every finished part playable and the
/// next attempt resumes instead of restarting.
final class ListenAudioProvider: Sendable {
    let cache: any ListenAudioCaching
    /// Nil when no API key is available — cached chapters still play.
    let speech: (any SpeechSynthesizing)?

    init(cache: any ListenAudioCaching, speech: (any SpeechSynthesizing)?) {
        self.cache = cache
        self.speech = speech
    }

    var canSynthesize: Bool { speech != nil }

    func cachedURL(for document: ListenDocument, chunkIndex: Int) -> URL? {
        cache.cachedAudioURL(for: document.cacheKey, chunkIndex: chunkIndex)
    }

    func cachedChunkCount(for document: ListenDocument) -> Int {
        cache.cachedChunkCount(for: document)
    }

    func isFullyDownloaded(_ document: ListenDocument) -> Bool {
        cache.isFullyDownloaded(document)
    }

    /// Cached audio for this chunk, synthesizing it first if needed.
    func audioURL(for document: ListenDocument, chunkIndex: Int) async throws -> URL {
        guard let chunk = document.chunk(at: chunkIndex) else {
            throw ListenError.emptyChapter
        }
        if let cached = cachedURL(for: document, chunkIndex: chunkIndex) {
            return cached
        }
        guard let speech else { throw ListenError.missingAPIKey }

        let data = try await speech.synthesize(
            SpeechSynthesisRequest(text: chunk.text, voice: document.voice, plan: document.plan)
        )
        guard ListenAudioValidator.looksLikeMP3(data) else {
            throw ListenError.malformedAudio
        }
        let key = document.cacheKey
        let url: URL
        do {
            url = try cache.store(data, for: key, chunkIndex: chunkIndex)
        } catch {
            throw ListenError.storageFailed(error.localizedDescription)
        }
        updateManifest(for: document)
        return url
    }

    /// Best-effort bookkeeping. The audio files are the source of truth, so the
    /// manifest is recomputed from what is actually on disk rather than patched
    /// in place — a lost write or a file deleted behind our back self-heals, and
    /// a failed manifest write never stops playback.
    private func updateManifest(for document: ListenDocument) {
        let key = document.cacheKey
        let completed = document.chunks.indices.filter {
            cache.cachedAudioURL(for: key, chunkIndex: $0) != nil
        }
        let manifest = ListenManifest(
            key: key,
            chapterTitle: document.chapterTitle,
            chunkCount: document.chunkCount,
            completedChunkIndices: Array(completed),
            createdAt: cache.manifest(for: key)?.createdAt ?? Date(),
            updatedAt: Date()
        )
        try? cache.saveManifest(manifest)
    }
}
