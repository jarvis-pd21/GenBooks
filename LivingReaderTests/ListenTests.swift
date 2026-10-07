import XCTest
@testable import LivingReader

/// Deterministic speech stand-in: no network, counts calls, can fail on demand.
private final class StubSpeechSynthesizer: SpeechSynthesizing, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [SpeechSynthesisRequest] = []
    var error: ListenError?
    var payload: Data

    init(payload: Data = StubSpeechSynthesizer.fakeMP3(), error: ListenError? = nil) {
        self.payload = payload
        self.error = error
    }

    var requests: [SpeechSynthesisRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    var callCount: Int { requests.count }

    func synthesize(_ request: SpeechSynthesisRequest) async throws -> Data {
        lock.lock()
        _requests.append(request)
        lock.unlock()
        if let error { throw error }
        return payload
    }

    /// MPEG frame sync + enough bytes to clear the cache's sanity floor.
    static func fakeMP3(byteCount: Int = 800) -> Data {
        var data = Data([0xFF, 0xFB, 0x90, 0x00])
        data.append(Data(repeating: 0x42, count: max(0, byteCount - 4)))
        return data
    }
}

@MainActor
private final class FakeListenPlayer: ListenAudioPlaying {
    var onFinishedPart: (() -> Void)?
    var onTimeChange: ((TimeInterval) -> Void)?
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 30
    var loadedURLs: [URL] = []
    var loadedOffsets: [TimeInterval] = []
    var rate: Double = 1.0
    var stopCount = 0
    var seekCount = 0
    var lastNowPlayingTitle: String?

    func load(url: URL, startAt: TimeInterval, rate: Double) throws {
        loadedURLs.append(url)
        loadedOffsets.append(startAt)
        self.rate = rate
        currentTime = startAt
        onTimeChange?(currentTime)
    }

    func play() { isPlaying = true }
    func pause() { isPlaying = false }

    func stop() {
        isPlaying = false
        stopCount += 1
    }

    func setRate(_ rate: Double) { self.rate = rate }

    func seek(to time: TimeInterval) {
        seekCount += 1
        currentTime = min(max(0, time), duration)
        onTimeChange?(currentTime)
    }

    func updateNowPlaying(
        title: String,
        chapterTitle: String,
        elapsedInChapter: TimeInterval,
        chapterDuration: TimeInterval,
        rate: Double,
        isPlaying: Bool
    ) {
        lastNowPlayingTitle = title
    }

    func clearNowPlaying() {
        lastNowPlayingTitle = nil
    }

    func finishPart() {
        isPlaying = false
        currentTime = 0
        onFinishedPart?()
    }
}

@MainActor
final class ListenTests: XCTestCase {
    private var tempRoot: URL!
    private var versioning: ManuscriptVersioningService!
    private var checkpoints: FileReadingCheckpointStore!
    private var cache: FileListenAudioCache!
    private var progressStore: FileListenProgressStore!
    private var keyStore: InMemoryAPIKeyStore!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LR-Listen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        versioning = try ManuscriptVersioningService(rootDirectory: tempRoot)
        checkpoints = try FileReadingCheckpointStore(rootDirectory: tempRoot)
        cache = FileListenAudioCache(rootDirectory: tempRoot)
        progressStore = FileListenProgressStore(rootDirectory: tempRoot)
        keyStore = InMemoryAPIKeyStore()
        defaultsSuite = "LivingReaderListen.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
        defaults.removePersistentDomain(forName: defaultsSuite)
        MockURLProtocol.reset()
    }

    override func tearDownWithError() throws {
        MockURLProtocol.reset()
        if let defaultsSuite {
            defaults?.removePersistentDomain(forName: defaultsSuite)
        }
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - Chunking

    func testChunksStayWithinMaximumAndEndOnSentenceBoundaries() {
        let sentence = "The pampas stretched past the last fence line and the riders kept going. "
        let text = String(repeating: sentence, count: 60)
        let chunks = ListenChunker.chunks(for: text)

        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(
                (chunk.text as NSString).length,
                ListenPlan.current.maximumChunkUTF16,
                "chunk \(chunk.index) exceeded the safe UTF-16 ceiling"
            )
            XCTAssertTrue(chunk.text.hasSuffix("."), "chunk \(chunk.index) cut mid-sentence")
        }
        // Every chunk but the last should have passed the preferred size.
        for chunk in chunks.dropLast() {
            XCTAssertGreaterThanOrEqual((chunk.text as NSString).length, ListenPlan.current.preferredChunkUTF16)
        }
    }

    func testChunkingKeepsEveryWordInOrder() {
        let text = """
        Rivers carried the first trade. Oral memory held the maps that ink never did.

        By 1810 the criollo elite argued in Buenos Aires while the interior waited.
        Güemes held the north with gauchos who owned their own horses. What followed
        was neither tidy nor inevitable.
        """
        let chunks = ListenChunker.chunks(for: text)
        let rejoined = chunks.map(\.text).joined(separator: " ")

        let original = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let narrated = rejoined.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        XCTAssertEqual(narrated, original, "narration must read every word, in order")

        // Offsets must march forward through the source text.
        var previousEnd = 0
        for chunk in chunks {
            XCTAssertGreaterThanOrEqual(chunk.utf16Start, previousEnd)
            previousEnd = chunk.utf16Start + chunk.utf16Length
        }
        XCTAssertLessThanOrEqual(previousEnd, (text as NSString).length)
    }

    func testAbbreviationsAndInitialsDoNotEndASentence() {
        let text = "Gral. Belgrano crossed the river. J. D. Perón came much later. Sr. Rosas ruled first."
        let ranges = ListenChunker.sentenceRanges(in: text as NSString)
        let sentences = ranges.map { (text as NSString).substring(with: $0).trimmingCharacters(in: .whitespaces) }

        XCTAssertEqual(sentences.count, 3, "abbreviations and initials must not split a sentence")
        XCTAssertEqual(sentences.first, "Gral. Belgrano crossed the river.")
        XCTAssertTrue(sentences.contains("J. D. Perón came much later."))
    }

    func testOversizedSentenceSplitsAtWordBoundaries() {
        // One sentence, no interior punctuation, far past the ceiling.
        let text = String(repeating: "corrientes ", count: 400) + "fin."
        let chunks = ListenChunker.chunks(for: text)

        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            XCTAssertLessThanOrEqual((chunk.text as NSString).length, ListenPlan.current.maximumChunkUTF16)
            let words = chunk.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            for word in words {
                XCTAssertTrue(
                    word == "corrientes" || word == "fin.",
                    "forced cut landed mid-word: “\(word)”"
                )
            }
        }
        let rejoined = chunks.map(\.text).joined(separator: " ")
        XCTAssertEqual(
            rejoined.split(whereSeparator: { $0.isWhitespace }).count,
            text.split(whereSeparator: { $0.isWhitespace }).count
        )
    }

    func testChunkOffsetsAreUTF16SafeAroundNonBMPCharacters() {
        let text = "Primera parte 🇦🇷 del relato. Segunda parte del relato."
        let source = text as NSString
        let chunks = ListenChunker.chunks(for: text)

        for chunk in chunks {
            let range = NSRange(location: chunk.utf16Start, length: chunk.utf16Length)
            XCTAssertEqual(source.substring(with: range), chunk.text)
        }
    }

    func testNarrationTextSkipsImagePlaceholdersAndKeepsOrder() {
        let blocks = [
            ContentBlock(id: UUID(), kind: .heading, text: "Before the Nation", orderIndex: 0),
            ContentBlock(id: UUID(), kind: .imagePlaceholder, text: "map of the litoral", orderIndex: 1),
            ContentBlock(id: UUID(), kind: .paragraph, text: "Rivers carried the first trade.", orderIndex: 2)
        ]
        let text = ListenChunker.narrationText(for: blocks)

        XCTAssertEqual(text, "Before the Nation\n\nRivers carried the first trade.")
        XCTAssertFalse(text.contains("map of the litoral"))
    }

    func testEmptyChapterProducesNoChunks() {
        XCTAssertTrue(ListenChunker.chunks(for: "").isEmpty)
        XCTAssertTrue(ListenChunker.chunks(for: "   \n\n  ").isEmpty)
    }

    // MARK: - Cache identity / revision isolation

    func testCacheKeyChangesWithRevisionVoiceAndPlan() {
        let base = makeDocument(revisionId: UUID(), voice: .marin)
        let newRevision = makeDocument(revisionId: UUID(), voice: .marin, chapterId: base.chapterId)
        let otherVoice = base.with(voice: .cedar)
        var otherPlan = base
        otherPlan.plan.instructions += " Read a little faster."

        XCTAssertNotEqual(base.cacheKey, newRevision.cacheKey)
        XCTAssertNotEqual(base.cacheKey.storageKey, otherVoice.cacheKey.storageKey)
        XCTAssertNotEqual(base.cacheKey.storageKey, otherPlan.cacheKey.storageKey)
        XCTAssertTrue(base.cacheKey.storageKey.hasPrefix(base.revisionId.uuidString))
        // Fingerprints must be stable across calls so cache paths survive relaunches.
        XCTAssertEqual(ListenPlan.current.fingerprint, ListenPlan.current.fingerprint)
    }

    func testAudioFromOldRevisionIsNeverServedForNewRevision() async throws {
        let chapterId = UUID()
        let oldRevision = makeDocument(revisionId: UUID(), voice: .marin, chapterId: chapterId)
        let speech = StubSpeechSynthesizer()
        let provider = ListenAudioProvider(cache: cache, speech: speech)

        for index in oldRevision.chunks.indices {
            _ = try await provider.audioURL(for: oldRevision, chunkIndex: index)
        }
        XCTAssertTrue(provider.isFullyDownloaded(oldRevision))

        // Living adaptation rewrites the chapter: same book, same chapter, new revision.
        let newRevision = makeDocument(revisionId: UUID(), voice: .marin, chapterId: chapterId)
        XCTAssertEqual(provider.cachedChunkCount(for: newRevision), 0)
        XCTAssertNil(provider.cachedURL(for: newRevision, chunkIndex: 0))
        XCTAssertFalse(provider.isFullyDownloaded(newRevision))
        // The consumed past keeps its audio.
        XCTAssertNotNil(provider.cachedURL(for: oldRevision, chunkIndex: 0))
    }

    func testSwitchingVoiceRequiresItsOwnAudio() async throws {
        let marin = makeDocument(revisionId: UUID(), voice: .marin)
        let speech = StubSpeechSynthesizer()
        let provider = ListenAudioProvider(cache: cache, speech: speech)
        _ = try await provider.audioURL(for: marin, chunkIndex: 0)

        let cedar = marin.with(voice: .cedar)
        XCTAssertNil(provider.cachedURL(for: cedar, chunkIndex: 0))
        XCTAssertNotNil(provider.cachedURL(for: marin, chunkIndex: 0))
        XCTAssertEqual(speech.requests.first?.voice, .marin)
    }

    func testCachedChapterPlaysWithoutSynthesizerAndSynthesizesOnce() async throws {
        let document = makeDocument(revisionId: UUID(), voice: .marin)
        let speech = StubSpeechSynthesizer()
        let online = ListenAudioProvider(cache: cache, speech: speech)

        _ = try await online.audioURL(for: document, chunkIndex: 0)
        _ = try await online.audioURL(for: document, chunkIndex: 0)
        XCTAssertEqual(speech.callCount, 1, "a cached part must not be re-synthesized")

        // Offline / no key: already-downloaded audio still resolves.
        let offline = ListenAudioProvider(cache: cache, speech: nil)
        XCTAssertNotNil(offline.cachedURL(for: document, chunkIndex: 0))
        let url = try await offline.audioURL(for: document, chunkIndex: 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testMissingKeyIsSoftFailureAndNothingIsCached() async {
        let document = makeDocument(revisionId: UUID(), voice: .marin)
        let provider = ListenAudioProvider(cache: cache, speech: nil)
        do {
            _ = try await provider.audioURL(for: document, chunkIndex: 0)
            XCTFail("expected missingAPIKey")
        } catch let error as ListenError {
            XCTAssertEqual(error, .missingAPIKey)
            XCTAssertTrue(error.isSoftFailure)
            XCTAssertEqual(provider.cachedChunkCount(for: document), 0)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testMalformedAudioIsRejectedAndNotCached() async {
        let document = makeDocument(revisionId: UUID(), voice: .marin)
        let speech = StubSpeechSynthesizer(payload: Data("{\"error\":\"nope\"}".utf8))
        let provider = ListenAudioProvider(cache: cache, speech: speech)
        do {
            _ = try await provider.audioURL(for: document, chunkIndex: 0)
            XCTFail("expected malformedAudio")
        } catch let error as ListenError {
            XCTAssertEqual(error, .malformedAudio)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertNil(provider.cachedURL(for: document, chunkIndex: 0))
        XCTAssertFalse(ListenAudioValidator.looksLikeMP3(Data(repeating: 0xFF, count: 8)))
        XCTAssertTrue(ListenAudioValidator.looksLikeMP3(StubSpeechSynthesizer.fakeMP3()))
    }

    func testRemovingDownloadDeletesOnlyThatRevisionAndVoice() async throws {
        let chapterId = UUID()
        let marin = makeDocument(revisionId: UUID(), voice: .marin, chapterId: chapterId)
        let cedar = marin.with(voice: .cedar)
        let provider = ListenAudioProvider(cache: cache, speech: StubSpeechSynthesizer())
        _ = try await provider.audioURL(for: marin, chunkIndex: 0)
        _ = try await provider.audioURL(for: cedar, chunkIndex: 0)

        try cache.removeAudio(for: marin.cacheKey)
        XCTAssertNil(provider.cachedURL(for: marin, chunkIndex: 0))
        XCTAssertNotNil(provider.cachedURL(for: cedar, chunkIndex: 0))
    }

    func testManifestTracksCompletedParts() async throws {
        let document = makeDocument(revisionId: UUID(), voice: .marin)
        let provider = ListenAudioProvider(cache: cache, speech: StubSpeechSynthesizer())
        for index in document.chunks.indices {
            _ = try await provider.audioURL(for: document, chunkIndex: index)
        }
        let manifest = try XCTUnwrap(cache.manifest(for: document.cacheKey))
        XCTAssertEqual(manifest.chunkCount, document.chunkCount)
        XCTAssertEqual(manifest.completedChunkIndices, Array(document.chunks.indices))
        XCTAssertTrue(manifest.isComplete)
        XCTAssertEqual(manifest.key.revisionId, document.revisionId)
    }

    // MARK: - Error mapping (OpenAI speech endpoint)

    func testSpeechClientMapsHTTPFailuresToSoftListenErrors() async throws {
        try keyStore.saveAPIKey("sk-test-listen")
        let cases: [(Int, String, ListenError)] = [
            (401, "{\"error\":{\"message\":\"Incorrect API key\"}}", .invalidAPIKey),
            (403, "{}", .invalidAPIKey),
            (404, "{\"error\":{\"message\":\"model not found\"}}", .modelUnavailable("gpt-4o-mini-tts")),
            (429, "{\"error\":{\"message\":\"Rate limit reached\"}}", .rateLimited),
            (500, "{\"error\":{\"message\":\"server error\"}}", .httpStatus(500, "server error"))
        ]
        for (status, body, expected) in cases {
            MockURLProtocol.requestHandler = { request in
                XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (response, Data(body.utf8))
            }
            do {
                _ = try await speechClient().synthesize(sampleRequest())
                XCTFail("expected failure for HTTP \(status)")
            } catch let error as ListenError {
                XCTAssertEqual(error, expected, "HTTP \(status) mapped incorrectly")
                XCTAssertNotNil(error.errorDescription)
            }
        }
    }

    func testSpeechClientMapsTransportFailures() async throws {
        try keyStore.saveAPIKey("sk-test-listen")
        let cases: [(URLError.Code, ListenError)] = [
            (.notConnectedToInternet, .offline),
            (.networkConnectionLost, .offline),
            (.timedOut, .timedOut),
            (.cancelled, .cancelled)
        ]
        for (code, expected) in cases {
            MockURLProtocol.requestHandler = { _ in throw URLError(code) }
            do {
                _ = try await speechClient().synthesize(sampleRequest())
                XCTFail("expected failure for \(code)")
            } catch let error as ListenError {
                XCTAssertEqual(error, expected)
            }
        }
    }

    func testSpeechClientWithoutKeyNeverCallsNetwork() async {
        MockURLProtocol.requestHandler = { _ in
            XCTFail("no key must mean no request")
            throw URLError(.badServerResponse)
        }
        do {
            _ = try await speechClient().synthesize(sampleRequest())
            XCTFail("expected missingAPIKey")
        } catch let error as ListenError {
            XCTAssertEqual(error, .missingAPIKey)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testSpeechRequestUsesAudiobookRecipeAndNeverLogsKey() async throws {
        try keyStore.saveAPIKey("sk-test-listen")
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, StubSpeechSynthesizer.fakeMP3())
        }
        let data = try await speechClient().synthesize(sampleRequest(voice: .cedar))
        XCTAssertTrue(ListenAudioValidator.looksLikeMP3(data))

        let request = try XCTUnwrap(MockURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/audio/speech")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "gpt-4o-mini-tts")
        XCTAssertEqual(json["voice"] as? String, "cedar")
        XCTAssertEqual(json["response_format"] as? String, "mp3")
        let instructions = try XCTUnwrap(json["instructions"] as? String)
        XCTAssertTrue(instructions.contains("word for word"))
        XCTAssertTrue(instructions.contains("Never summarize"))
        XCTAssertTrue(instructions.lowercased().contains("spanish"))
    }

    func testSpeechClientRejectsNonAudioSuccessBody() async throws {
        try keyStore.saveAPIKey("sk-test-listen")
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("not audio".utf8))
        }
        do {
            _ = try await speechClient().synthesize(sampleRequest())
            XCTFail("expected malformedAudio")
        } catch let error as ListenError {
            XCTAssertEqual(error, .malformedAudio)
        }
    }

    // MARK: - Listen never disturbs reading

    func testListeningNeverMovesReadingPlaceOrConsumesChapters() async throws {
        let book = try await BundleFixtureLoader.seedIfNeeded(into: versioning)
        let reader = try await makeReaderViewModel(book: book)
        let chapterId = try XCTUnwrap(reader.orderedChapterIds.first)

        let checkpointBefore = try checkpoints.loadCheckpoint(bookId: book.id)
        let ledgerBefore = try await versioning.ledgerSnapshot()
        let locationBefore = reader.currentLocation

        let player = FakeListenPlayer()
        let listen = makeListenViewModel(reader: reader, book: book, player: player, speech: StubSpeechSynthesizer())
        listen.open(chapterId: chapterId)
        XCTAssertGreaterThan(listen.partCount, 1)

        listen.togglePlayPause()
        await listen.awaitGeneration()
        XCTAssertTrue(player.isPlaying)
        player.finishPart()
        listen.skipPart(by: 1)
        listen.close()

        let ledgerAfter = try await versioning.ledgerSnapshot()
        XCTAssertEqual(try checkpoints.loadCheckpoint(bookId: book.id)?.id, checkpointBefore?.id)
        XCTAssertEqual(try checkpoints.loadCheckpoint(bookId: book.id)?.blockId, checkpointBefore?.blockId)
        XCTAssertEqual(ledgerAfter.count, ledgerBefore.count)
        XCTAssertEqual(reader.currentLocation, locationBefore)
        XCTAssertTrue(reader.consumedChapterIds.isEmpty)

        // Reading revisions are untouched by narration.
        let revision = try await versioning.readableRevision(bookId: book.id, chapterId: chapterId)
        XCTAssertEqual(revision.id, listen.document?.revisionId)
    }

    func testDownloadedChapterPlaysOfflineAndResumesWhereItStopped() async throws {
        let book = try await BundleFixtureLoader.seedIfNeeded(into: versioning)
        let reader = try await makeReaderViewModel(book: book)
        let chapterId = try XCTUnwrap(reader.orderedChapterIds.first)
        let speech = StubSpeechSynthesizer()

        let listen = makeListenViewModel(reader: reader, book: book, player: FakeListenPlayer(), speech: speech)
        listen.open(chapterId: chapterId)
        listen.downloadChapter()
        await listen.awaitGeneration()

        XCTAssertTrue(listen.isFullyDownloaded)
        XCTAssertEqual(listen.downloadedPartCount, listen.partCount)
        XCTAssertEqual(speech.callCount, listen.partCount)
        XCTAssertEqual(listen.availabilityLabel, "Downloaded — plays offline")

        listen.skipPart(by: 3)
        let stoppedAt = listen.currentPartIndex
        listen.close()

        // A fresh session with no synthesizer at all (offline, no key) resumes.
        let offlineListen = makeListenViewModel(reader: reader, book: book, player: FakeListenPlayer(), speech: nil)
        offlineListen.open(chapterId: chapterId)
        XCTAssertEqual(offlineListen.currentPartIndex, stoppedAt)
        XCTAssertTrue(offlineListen.canPlayCurrentPart)
        offlineListen.togglePlayPause()
        XCTAssertTrue(offlineListen.isPlaying)
        XCTAssertNil(offlineListen.errorMessage)
    }

    func testResumePointIsIgnoredAfterChapterIsRegenerated() throws {
        let chapterId = UUID()
        let bookId = UUID()
        let original = makeDocument(revisionId: UUID(), voice: .marin, chapterId: chapterId, bookId: bookId)
        let progress = ListenProgress(
            bookId: bookId,
            chapterId: chapterId,
            revisionId: original.revisionId,
            voice: .marin,
            chunkIndex: 0,
            offsetSeconds: 12
        )
        try progressStore.save(progress)

        XCTAssertTrue(progress.canResume(original))
        // Voice is not part of resume identity — the place in the prose is the same.
        XCTAssertTrue(progress.canResume(original.with(voice: .cedar)))

        let regenerated = makeDocument(revisionId: UUID(), voice: .marin, chapterId: chapterId, bookId: bookId)
        XCTAssertFalse(progress.canResume(regenerated), "a rewritten chapter must not resume into stale audio")

        let loaded = try XCTUnwrap(progressStore.progress(bookId: bookId, chapterId: chapterId))
        XCTAssertEqual(loaded.offsetSeconds, 12)
        XCTAssertEqual(loaded.revisionId, original.revisionId)
    }

    func testListenProgressIsStoredApartFromReadingCheckpoints() throws {
        let bookId = UUID()
        let chapterId = UUID()
        try checkpoints.saveCheckpoint(
            ReadingCheckpoint(
                id: UUID(),
                bookId: bookId,
                chapterId: chapterId,
                blockId: UUID(),
                characterOffset: 240,
                updatedAt: Date()
            )
        )
        try progressStore.save(
            ListenProgress(
                bookId: bookId,
                chapterId: chapterId,
                revisionId: UUID(),
                voice: .cedar,
                chunkIndex: 4,
                offsetSeconds: 31
            )
        )

        XCTAssertEqual(try checkpoints.loadCheckpoint(bookId: bookId)?.characterOffset, 240)
        XCTAssertEqual(try progressStore.progress(bookId: bookId, chapterId: chapterId)?.chunkIndex, 4)

        try progressStore.clear(bookId: bookId, chapterId: chapterId)
        XCTAssertNil(try progressStore.progress(bookId: bookId, chapterId: chapterId))
        XCTAssertEqual(try checkpoints.loadCheckpoint(bookId: bookId)?.characterOffset, 240)
    }

    func testListenSoftFailsWithoutAPIKeyAndKeepsCachedPartsPlayable() async throws {
        let book = try await BundleFixtureLoader.seedIfNeeded(into: versioning)
        let reader = try await makeReaderViewModel(book: book)
        let chapterId = try XCTUnwrap(reader.orderedChapterIds.first)

        let listen = makeListenViewModel(
            reader: reader,
            book: book,
            player: FakeListenPlayer(),
            speech: StubSpeechSynthesizer(),
            hasAPIKey: false
        )
        listen.open(chapterId: chapterId)
        XCTAssertFalse(listen.canSynthesize)

        listen.downloadChapter()
        await listen.awaitGeneration()
        XCTAssertEqual(listen.phase, .needsAudio)
        XCTAssertEqual(listen.downloadedPartCount, 0)
        XCTAssertEqual(listen.errorMessage, ListenError.missingAPIKey.localizedDescription)

        listen.togglePlayPause()
        XCTAssertFalse(listen.isPlaying)
        XCTAssertNotNil(listen.errorMessage)
    }

    func testSynthesisFailureMidChapterKeepsEarlierPartsPlayable() async throws {
        let document = makeDocument(revisionId: UUID(), voice: .marin)
        let speech = StubSpeechSynthesizer()
        let provider = ListenAudioProvider(cache: cache, speech: speech)
        _ = try await provider.audioURL(for: document, chunkIndex: 0)

        speech.error = .rateLimited
        do {
            _ = try await provider.audioURL(for: document, chunkIndex: 1)
            XCTFail("expected rateLimited")
        } catch let error as ListenError {
            XCTAssertEqual(error, .rateLimited)
        }
        XCTAssertNotNil(provider.cachedURL(for: document, chunkIndex: 0))
        XCTAssertNil(provider.cachedURL(for: document, chunkIndex: 1))
    }

    // MARK: - Audiobook UX (seek / prefetch / word sync)

    func testRemoveDownloadRejectsChangedVoiceAndRemovesOnlyReviewedAudio() async throws {
        let book = try await BundleFixtureLoader.seedIfNeeded(into: versioning)
        let reader = try await makeReaderViewModel(book: book)
        let chapterId = try XCTUnwrap(reader.orderedChapterIds.first)
        let listen = makeListenViewModel(reader: reader, book: book, player: FakeListenPlayer(), speech: StubSpeechSynthesizer())
        listen.open(chapterId: chapterId)
        listen.downloadChapter()
        await listen.awaitGeneration()
        let target = try XCTUnwrap(listen.document)
        XCTAssertTrue(listen.isFullyDownloaded)
        listen.select(voice: .cedar)
        listen.removeDownload(matching: target.cacheKey)
        XCTAssertNotNil(listen.errorMessage)
        listen.select(voice: target.voice)
        XCTAssertTrue(listen.isFullyDownloaded, "A stale confirmation must not remove the earlier voice")
        listen.removeDownload(matching: target.cacheKey)
        XCTAssertFalse(listen.isFullyDownloaded)
        XCTAssertEqual(reader.book, book, "Audio removal cannot mutate the manuscript")
    }

    func testBrowsingListenAndVoicesDoesNotGenerateUntilPlayOrDownload() async throws {
        let book = try await BundleFixtureLoader.seedIfNeeded(into: versioning)
        let reader = try await makeReaderViewModel(book: book)
        let chapterId = try XCTUnwrap(reader.orderedChapterIds.first)
        let speech = StubSpeechSynthesizer()
        let listen = makeListenViewModel(reader: reader, book: book, player: FakeListenPlayer(), speech: speech)
        listen.open(chapterId: chapterId)
        await listen.awaitGeneration()
        listen.open(chapterId: chapterId)
        listen.select(voice: .cedar)
        listen.skipPart(by: 1)
        listen.skipChapter(by: 1)
        await listen.awaitGeneration()
        XCTAssertEqual(speech.callCount, 0, "Viewing audio controls is not permission to buy narration")
        XCTAssertFalse(listen.isGenerating)
        listen.downloadChapter()
        await listen.awaitGeneration()
        XCTAssertGreaterThan(speech.callCount, 0, "The deliberate Download action must still work")
    }

    func testSkipSecondsUsesCachedAudioOnlyAndNeverBlocksOnSynthesis() async throws {
        let document = makeDocument(revisionId: UUID(), voice: .marin)
        let speech = StubSpeechSynthesizer()
        let provider = ListenAudioProvider(cache: cache, speech: speech)
        _ = try await provider.audioURL(for: document, chunkIndex: 0)

        let player = FakeListenPlayer()
        player.duration = 20
        let services = ListenServices(cache: cache, progress: progressStore, speech: speech, hasAPIKey: { true })
        let listen = ListenViewModel(
            bookId: document.bookId,
            services: services,
            player: player,
            documentProvider: { _, _ in document },
            chapterOrderProvider: { [document.chapterId] }
        )
        listen.open(chapterId: document.chapterId)
        await listen.awaitGeneration()
        listen.cancelDownload()
        XCTAssertNotNil(provider.cachedURL(for: document, chunkIndex: 0))

        listen.togglePlayPause()
        listen.skipSeconds(5)
        XCTAssertNotEqual(listen.phase, .preparing, "skip must never block on making narration")
        XCTAssertTrue(
            listen.phase == .playing
                || listen.phase == .readyToPlay
                || listen.phase == .paused
                || listen.phase == .needsAudio
        )
    }

    func testWordTimingEstimatesHighlightAndLocateOffset() {
        let text = "Buenos Aires grew beside the river."
        let words = ListenWordTiming.words(in: text)
        XCTAssertEqual(words.map { $0.text }, ["Buenos", "Aires", "grew", "beside", "the", "river."])
        XCTAssertEqual(ListenWordTiming.wordIndex(atProgress: 0, words: words), 0)
        XCTAssertEqual(ListenWordTiming.wordIndex(atProgress: 0.99, words: words), words.count - 1)

        let document = makeDocument(revisionId: UUID(), voice: .marin)
        let mid = document.chunks[0].utf16Start + min(10, document.chunks[0].utf16Length - 1)
        let located = ListenWordTiming.locate(utf16Offset: mid, in: document)
        XCTAssertEqual(located?.chunkIndex, 0)
        XCTAssertNotNil(located?.localUTF16)
    }

    func testOpenFromWordStartsAtLocatedChunk() async throws {
        let book = try await BundleFixtureLoader.seedIfNeeded(into: versioning)
        let reader = try await makeReaderViewModel(book: book)
        let chapterId = try XCTUnwrap(reader.orderedChapterIds.first)
        let doc = try XCTUnwrap(reader.makeListenDocument(chapterId: chapterId, voice: .marin))
        let targetChunk = min(1, max(0, doc.chunkCount - 1))
        let offset = doc.chunks[targetChunk].utf16Start

        let player = FakeListenPlayer()
        let listen = makeListenViewModel(reader: reader, book: book, player: player, speech: StubSpeechSynthesizer())
        listen.openFromWord(chapterId: chapterId, narrationUTF16Offset: offset)
        await listen.awaitGeneration()
        XCTAssertEqual(listen.currentPartIndex, targetChunk)
        XCTAssertTrue(listen.isPlaying || listen.canPlayCurrentPart)
    }

    func testFormatClockAndResumeHint() async throws {
        XCTAssertEqual(ListenViewModel.formatClock(65), "1:05")
        XCTAssertEqual(ListenViewModel.formatClock(0), "0:00")
        let book = try await BundleFixtureLoader.seedIfNeeded(into: versioning)
        let reader = try await makeReaderViewModel(book: book)
        let chapterId = try XCTUnwrap(reader.orderedChapterIds.first)
        let listen = makeListenViewModel(reader: reader, book: book, player: FakeListenPlayer(), speech: StubSpeechSynthesizer())
        listen.open(chapterId: chapterId)
        listen.downloadChapter()
        await listen.awaitGeneration()
        listen.skipPart(by: 1)
        listen.close()
        let resumed = makeListenViewModel(reader: reader, book: book, player: FakeListenPlayer(), speech: nil)
        resumed.open(chapterId: chapterId)
        XCTAssertNotNil(resumed.resumeHint)
        XCTAssertTrue(resumed.didRestoreResume)
    }

    // MARK: - Helpers

    private func speechClient() -> OpenAISpeechClient {
        let store = keyStore!
        return OpenAISpeechClient(
            apiKeyProvider: { try store.loadAPIKey() },
            session: MockURLProtocol.makeSession(),
            timeout: 2
        )
    }

    private func sampleRequest(voice: ListenVoice = .marin) -> SpeechSynthesisRequest {
        SpeechSynthesisRequest(text: "Rivers carried the first trade.", voice: voice)
    }

    /// Two-chunk document built from prose, so cache tests exercise real chunking.
    private func makeDocument(
        revisionId: UUID,
        voice: ListenVoice,
        chapterId: UUID = UUID(),
        bookId: UUID = UUID()
    ) -> ListenDocument {
        let sentence = "The riders crossed the shallow ford before the rain arrived from the south. "
        let text = String(repeating: sentence, count: 30)
        return ListenDocument(
            bookId: bookId,
            chapterId: chapterId,
            chapterTitle: "Before the Nation",
            revisionId: revisionId,
            voice: voice,
            plan: .current,
            chunks: ListenChunker.chunks(for: text)
        )
    }

    private func makeReaderViewModel(book: Book) async throws -> ReaderViewModel {
        let model = ReaderViewModel(
            book: book,
            versioning: versioning,
            checkpoints: checkpoints,
            settings: ReaderSettingsStore(defaults: defaults),
            annotations: try FileAnnotationStore(rootDirectory: tempRoot),
            vocabulary: try FileVocabularyStore(rootDirectory: tempRoot),
            bookmarks: try FileBookmarkStore(rootDirectory: tempRoot),
            feedbackStore: try FileFeedbackStore(rootDirectory: tempRoot),
            preferenceStore: try FileReaderPreferenceStore(rootDirectory: tempRoot)
        )
        await model.open()
        return model
    }

    private func makeListenViewModel(
        reader: ReaderViewModel,
        book: Book,
        player: FakeListenPlayer,
        speech: (any SpeechSynthesizing)?,
        hasAPIKey: Bool = true
    ) -> ListenViewModel {
        let services = ListenServices(
            cache: cache,
            progress: progressStore,
            speech: speech,
            hasAPIKey: { hasAPIKey }
        )
        return ListenViewModel(
            bookId: book.id,
            services: services,
            player: player,
            documentProvider: { chapterId, voice in
                reader.makeListenDocument(chapterId: chapterId, voice: voice)
            },
            chapterOrderProvider: { reader.orderedChapterIds }
        )
    }
}
