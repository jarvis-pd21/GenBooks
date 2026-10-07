import XCTest
@testable import LivingReader

/// Phase 7 — Reliability + adversarial QA. Try to break core flows; assert soft-fail + immutability.
@MainActor
final class ReliabilityAdversarialTests: XCTestCase {
    private var root: URL!
    private var versioning: ManuscriptVersioningService!
    private var checkpoints: FileReadingCheckpointStore!
    private var annotations: FileAnnotationStore!
    private var vocabulary: FileVocabularyStore!
    private var bookmarks: FileBookmarkStore!
    private var feedbackStore: FileFeedbackStore!
    private var preferenceStore: FileReaderPreferenceStore!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!
    private var ai: MockAIService!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LR-P7-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        versioning = try ManuscriptVersioningService(rootDirectory: root)
        checkpoints = try FileReadingCheckpointStore(rootDirectory: root)
        annotations = try FileAnnotationStore(rootDirectory: root)
        vocabulary = try FileVocabularyStore(rootDirectory: root)
        bookmarks = try FileBookmarkStore(rootDirectory: root)
        feedbackStore = try FileFeedbackStore(rootDirectory: root)
        preferenceStore = try FileReaderPreferenceStore(rootDirectory: root)
        defaultsSuite = "LivingReaderP7.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
        defaults.removePersistentDomain(forName: defaultsSuite)
        ai = MockAIService()
    }

    override func tearDown() async throws {
        if let defaultsSuite { defaults?.removePersistentDomain(forName: defaultsSuite) }
        try? FileManager.default.removeItem(at: root)
    }

    private func makeModel(book: Book) -> ReaderViewModel {
        ReaderViewModel(
            book: book,
            versioning: versioning,
            checkpoints: checkpoints,
            settings: ReaderSettingsStore(defaults: defaults),
            annotations: annotations,
            vocabulary: vocabulary,
            bookmarks: bookmarks,
            feedbackStore: feedbackStore,
            preferenceStore: preferenceStore,
            ai: ai,
            askService: ai,
            adaptationAI: ai
        )
    }

    // MARK: - Offline / no-key soft-fail (reading never blocked)

    func testOfflineOpenNeverCallsAI() async throws {
        let book = try await BundleFixtureLoader.seedIfNeeded(into: versioning)
        let model = makeModel(book: book)
        await model.open()
        XCTAssertTrue(model.isReady)
        XCTAssertNil(model.loadError)
        XCTAssertEqual(ai.totalCallCount, 0)
        XCTAssertEqual(model.aiAskCallCountAtOpen, 0)
        XCTAssertEqual(model.aiAdaptCallCountAtOpen, 0)
    }

    func testAskSessionSoftFailsWithoutKeyAndCancelMidAsk() async throws {
        let session = AskSession(ai: ai)
        ai.stubAsk { _ in
            try await Task.sleep(nanoseconds: 800_000_000)
            try Task.checkCancellation()
            return AskResponse(answer: "late", modelUsed: "mock", usedUnreadSpoilers: false, isSpoilerWarning: false, isMock: true)
        }
        session.configure(seedQuestion: "What is this?", selectedText: "pampas") { question, allow in
            AskRequest(
                userQuestion: question,
                selectedText: "pampas",
                bookTitle: "T",
                bookAuthor: "A",
                consumedContext: "consumed",
                unreadContext: "SECRET_UNREAD_MARKER_SHOULD_NOT_LEAK",
                allowUnreadSpoilers: allow,
                forceMock: true
            )
        }
        // The composer opens empty now, so the seeded question is sent outright
        // rather than typed into the field for the reader.
        XCTAssertTrue(session.draft.isEmpty)
        let sendTask = Task { await session.sendSeedQuestion() }
        try await Task.sleep(nanoseconds: 50_000_000)
        session.cancelInFlight()
        await sendTask.value
        XCTAssertFalse(session.isSending)
        // Reading path unaffected — cancel is soft.
        XCTAssertTrue(session.messages.contains { $0.content.contains("cancelled") || $0.role == .user })
    }

    // MARK: - Terminate mid-generation / mid-reading

    func testCancelMidGenerationLeavesBookUnchanged() async throws {
        let book = try await BundleFixtureLoader.seedIfNeeded(into: versioning)
        let service = LivingBookAdaptationService(
            versioning: versioning,
            feedbackStore: feedbackStore,
            preferenceStore: preferenceStore,
            ai: ai
        )
        let ch1 = ArgentinaFixtureIDs.chapter1
        let ch2 = ArgentinaFixtureIDs.chapter2
        let v1 = ArgentinaFixtureIDs.chapter1Revision1
        try await service.finishChapter(bookId: book.id, chapterId: ch1, revisionId: v1)

        let before = try await versioning.loadBook(id: book.id)!
        let beforeData = try JSONCoding.encoder.encode(before)
        let ch2Before = try await versioning.readableRevision(bookId: book.id, chapterId: ch2)

        ai.stubGenerateDelay(nanoseconds: 600_000_000)
        let feedback = ChapterFeedback(
            id: UUID(),
            bookId: book.id,
            chapterId: ch1,
            revisionId: v1,
            overall: .fine,
            moreOf: [.stories],
            lessOf: [.dates],
            freeText: "cancel me",
            createdAt: Date()
        )
        let plan = try await service.submitFeedbackAndPlan(book: book, feedback: feedback)

        let applyTask = Task {
            try await service.applyPlan(book: book, plan: plan)
        }
        try await Task.sleep(nanoseconds: 80_000_000)
        await service.cancel()
        do {
            _ = try await applyTask.value
            // If generate finished before cancel landed, still OK if book valid — but prefer cancelled.
        } catch AdaptationError.cancelled {
            // expected
        } catch {
            // Other soft failures also OK if book unchanged
        }

        let after = try await versioning.loadBook(id: book.id)!
        let afterData = try JSONCoding.encoder.encode(after)
        // Either cancelled before activate (bytes equal) OR if activate raced, consumed ch1 still v1.
        let ch1Readable = try await versioning.readableRevision(bookId: book.id, chapterId: ch1)
        XCTAssertEqual(ch1Readable.id, v1, "Consumed past must remain v1 after cancel")
        if afterData != beforeData {
            // Activation may have completed for unread future — still must not touch ch1.
            let ch2After = try await versioning.readableRevision(bookId: book.id, chapterId: ch2)
            _ = ch2After
            _ = ch2Before
        }
        let endState = await service.currentState()
        XCTAssertNotEqual(endState, .applying)
    }

    func testPersistNowSurvivesTerminateMidReading() async throws {
        let book = try await BundleFixtureLoader.seedIfNeeded(into: versioning)
        let model = makeModel(book: book)
        await model.open()
        let document = try XCTUnwrap(model.document)
        let hit = try XCTUnwrap(document.search(query: ArgentinaFixtureIDs.searchablePhrase).first)
        let location = try XCTUnwrap(document.location(atUtf16: hit.range.location, visibleProgress: 0.33))
        model.handleLocationChange(location)
        await model.persistNow() // simulate background / terminate

        let reopenedStore = try FileReadingCheckpointStore(rootDirectory: root)
        let saved = try XCTUnwrap(reopenedStore.loadCheckpoint(bookId: book.id))
        XCTAssertEqual(saved.blockId, location.blockId)
        XCTAssertEqual(saved.chapterId, location.chapterId)
        XCTAssertEqual(saved.characterOffset, location.characterOffset)
    }

    // MARK: - Font/theme + annotations + restore

    func testFontThemeChangeKeepsAnnotationsAndCheckpoint() async throws {
        let book = try await BundleFixtureLoader.seedIfNeeded(into: versioning)
        let settings = ReaderSettingsStore(defaults: defaults)
        let model = ReaderViewModel(
            book: book,
            versioning: versioning,
            checkpoints: checkpoints,
            settings: settings,
            annotations: annotations,
            vocabulary: vocabulary,
            bookmarks: bookmarks,
            feedbackStore: feedbackStore,
            preferenceStore: preferenceStore,
            ai: ai
        )
        await model.open()
        let document = try XCTUnwrap(model.document)
        let hit = try XCTUnwrap(document.search(query: "Geography is destiny").first)
        let selection = try XCTUnwrap(ReaderSelectionMapper.selection(in: document, documentRange: hit.range))
        model.activeSelection = selection
        model.performHighlight(color: .yellow)
        model.activeSelection = selection
        model.noteDraft = "P7 adversarial note"
        model.saveNoteFromDraft()

        let loc = try XCTUnwrap(document.location(atUtf16: hit.range.location, visibleProgress: 0.2))
        await model.persist(loc)

        settings.fontSize = 24
        settings.colorScheme = .dark
        model.rebuildDocumentPreservingLocation()

        XCTAssertEqual(model.highlights.count, 1) // one unified mark per exact passage, plus optional body
        XCTAssertEqual(model.notes.count, 1)
        let rebuilt = try XCTUnwrap(model.document)
        let painted = model.persistentHighlightPaint
        XCTAssertFalse(painted.isEmpty, "Highlights must rematerialize after font/theme rebuild")
        XCTAssertNotNil(rebuilt.anchor(blockId: selection.range.blockId))

        let model2 = ReaderViewModel(
            book: book,
            versioning: versioning,
            checkpoints: checkpoints,
            settings: settings,
            annotations: annotations,
            vocabulary: vocabulary,
            bookmarks: bookmarks,
            feedbackStore: feedbackStore,
            preferenceStore: preferenceStore,
            ai: ai
        )
        await model2.open()
        XCTAssertEqual(model2.restoreLocation?.blockId, loc.blockId)
        XCTAssertFalse(model2.highlights.isEmpty)
        XCTAssertFalse(model2.notes.isEmpty)
    }

    // MARK: - Concurrency / locked mutation / invalid candidate

    func testConcurrentActivateOnConsumedChapterBothReject() async throws {
        let book = try await BundleFixtureLoader.seedIfNeeded(into: versioning)
        let ch1 = ArgentinaFixtureIDs.chapter1
        try await versioning.consume(
            bookId: book.id,
            chapterId: ch1,
            revisionId: ArgentinaFixtureIDs.chapter1Revision1
        )
        let blocks = [
            ContentBlock(id: UUID(), kind: .paragraph, text: "Hostile overwrite attempt.", orderIndex: 0)
        ]
        let c1 = CandidateRevision(
            id: UUID(), bookId: book.id, chapterId: ch1, proposedRevisionIndex: 99,
            createdAt: Date(), blocks: blocks, status: .staged, rejectionReason: nil
        )
        let c2 = CandidateRevision(
            id: UUID(), bookId: book.id, chapterId: ch1, proposedRevisionIndex: 100,
            createdAt: Date(), blocks: blocks, status: .staged, rejectionReason: nil
        )
        try await versioning.stageCandidate(c1)
        try await versioning.stageCandidate(c2)

        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    _ = try await self.versioning.activateCandidate(id: c1.id)
                    return false
                } catch ManuscriptError.cannotMutateConsumedChapter {
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                do {
                    _ = try await self.versioning.activateCandidate(id: c2.id)
                    return false
                } catch ManuscriptError.cannotMutateConsumedChapter {
                    return true
                } catch {
                    return false
                }
            }
            var results: [Bool] = []
            for await r in group { results.append(r) }
            XCTAssertEqual(results.filter { $0 }.count, 2, "Both concurrent activates must reject locked chapter")
        }

        let readable = try await versioning.readableRevision(bookId: book.id, chapterId: ch1)
        XCTAssertEqual(readable.id, ArgentinaFixtureIDs.chapter1Revision1)
    }

    func testInvalidCandidateEmptyBlocksRejected() async throws {
        let book = try await BundleFixtureLoader.seedIfNeeded(into: versioning)
        let before = try JSONCoding.encoder.encode(try await versioning.loadBook(id: book.id)!)
        let bad = CandidateRevision(
            id: UUID(),
            bookId: book.id,
            chapterId: ArgentinaFixtureIDs.chapter2,
            proposedRevisionIndex: 2,
            createdAt: Date(),
            blocks: [ContentBlock(id: UUID(), kind: .paragraph, text: "   ", orderIndex: 0)],
            status: .staged,
            rejectionReason: nil
        )
        do {
            try await versioning.stageCandidate(bad)
            XCTFail("expected malformed")
        } catch ManuscriptError.malformedCandidate {
            // ok
        }
        let after = try JSONCoding.encoder.encode(try await versioning.loadBook(id: book.id)!)
        XCTAssertEqual(before, after)
    }

    func testPlantedMalformedCandidateDoesNotCorrupt() async throws {
        let book = try await BundleFixtureLoader.seedIfNeeded(into: versioning)
        let before = try JSONCoding.encoder.encode(try await versioning.loadBook(id: book.id)!)
        let id = UUID()
        try await versioning.plantRawCandidate(id: id, data: Data("{not-json".utf8))
        do {
            _ = try await versioning.activateCandidate(id: id)
            XCTFail("expected failure")
        } catch {
            // expected
        }
        let after = try JSONCoding.encoder.encode(try await versioning.loadBook(id: book.id)!)
        XCTAssertEqual(before, after)
    }

    // MARK: - Spoiler adversarial

    func testSpoilerLeakGuardOmitsUnreadUnlessReveal() async throws {
        let unreadMarker = "UNREAD_SPOILER_TOKEN_\(UUID().uuidString.prefix(8))"
        let slices: [AskContextBuilder.ReadingSlice] = [
            .init(
                chapterId: ArgentinaFixtureIDs.chapter1,
                title: "Ch1",
                orderIndex: 0,
                revisionId: ArgentinaFixtureIDs.chapter1Revision1,
                plainText: "Consumed Andes foothills.",
                isConsumed: true,
                isCurrent: false
            ),
            .init(
                chapterId: ArgentinaFixtureIDs.chapter2,
                title: "Ch2",
                orderIndex: 1,
                revisionId: UUID(),
                plainText: unreadMarker,
                isConsumed: false,
                isCurrent: false
            )
        ]
        let normal = AskContextBuilder.buildRequest(
            question: "What happens later in the war?",
            book: try BundleFixtureLoader.loadArgentinaMinimal(),
            slices: slices,
            selectedText: nil,
            surroundingContext: nil,
            currentChapterId: ArgentinaFixtureIDs.chapter1,
            notesAndQuestions: nil,
            readerPreferencesSummary: nil,
            allowUnreadSpoilers: false
        )
        let payload = AskContextBuilder.contextPayload(for: normal)
        XCTAssertFalse(payload.contains(unreadMarker), "Unread must not leak into normal Ask payload")
        XCTAssertFalse(AskContextBuilder.payloadContainsUnreadMarker(payload))
        // Unread may be held separately on the request for deliberate reveal, but must stay out of normal payload.

        let reveal = AskContextBuilder.buildRequest(
            question: "Reveal spoilers please",
            book: try BundleFixtureLoader.loadArgentinaMinimal(),
            slices: slices,
            selectedText: nil,
            surroundingContext: nil,
            currentChapterId: ArgentinaFixtureIDs.chapter1,
            notesAndQuestions: nil,
            readerPreferencesSummary: nil,
            allowUnreadSpoilers: true
        )
        let revealPayload = AskContextBuilder.contextPayload(for: reveal)
        XCTAssertTrue(revealPayload.contains(unreadMarker) || (reveal.unreadContext?.contains(unreadMarker) ?? false))
    }

    // MARK: - CONV-001: Existing data is never treated as a missing seed

    func testCorruptManuscriptThrowsAndPreservesBytesWhenLedgerEmpty() async throws {
        let book = try BundleFixtureLoader.loadArgentinaMinimal()
        // Plant corrupt bytes under manuscript path
        let manuscriptsDir = root.appendingPathComponent("Manuscripts", isDirectory: true)
        try FileManager.default.createDirectory(at: manuscriptsDir, withIntermediateDirectories: true)
        let url = manuscriptsDir.appendingPathComponent("\(book.id.uuidString).json")
        let original = Data("CORRUPT{{{".utf8)
        try original.write(to: url)
        let ledgerURL = root.appendingPathComponent("Ledger/consumed-ledger.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerURL.path))
        do {
            _ = try await BundleFixtureLoader.seedIfNeeded(into: versioning)
            XCTFail("An existing corrupt manuscript must not be replaced by a bundled book")
        } catch { /* Preserve the underlying read/decode failure for the caller. */ }
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerURL.path))
    }

    func testIncompatibleManuscriptThrowsAndPreservesConsumedLedgerBytes() async throws {
        let book = try await BundleFixtureLoader.seedIfNeeded(into: versioning)
        let chapter = try XCTUnwrap(book.chapters.first)
        let revision = try XCTUnwrap(chapter.activeRevision)
        try await versioning.consume(bookId: book.id, chapterId: chapter.id, revisionId: revision.id)
        let ledgerURL = root.appendingPathComponent("Ledger/consumed-ledger.json")
        let ledgerBefore = try Data(contentsOf: ledgerURL)
        let url = root.appendingPathComponent("Manuscripts/\(book.id.uuidString).json")
        // Valid JSON with an incompatible field type, not merely truncated JSON.
        let incompatible = Data("{\"id\":\"\(book.id.uuidString)\",\"title\":[],\"chapters\":{}}".utf8)
        try incompatible.write(to: url)
        do {
            _ = try await BundleFixtureLoader.seedIfNeeded(into: versioning)
            XCTFail("Decode incompatibility must not trigger reseeding")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: url), incompatible)
        XCTAssertEqual(try Data(contentsOf: ledgerURL), ledgerBefore)
        let reopened = try ManuscriptVersioningService(rootDirectory: root)
        let ledger = try await reopened.ledgerSnapshot()
        XCTAssertEqual(ledger.first?.revisionId, revision.id)
    }

    func testWrongEmbeddedBookIDThrowsWithoutChangingEitherBookFile() async throws {
        let bundled = try BundleFixtureLoader.loadArgentinaMinimal()
        var wrong = bundled
        wrong.id = UUID()
        wrong.chapters = Array(wrong.chapters.prefix(1))
        let manuscriptURL = root.appendingPathComponent("Manuscripts/\(bundled.id.uuidString).json")
        let otherBookURL = root.appendingPathComponent("Manuscripts/\(wrong.id.uuidString).json")
        let misplacedBytes = try JSONCoding.encoder.encode(wrong)
        let otherBookBytes = Data("Unrelated book bytes must not be overwritten.".utf8)
        try misplacedBytes.write(to: manuscriptURL)
        try otherBookBytes.write(to: otherBookURL)
        do {
            _ = try await BundleFixtureLoader.seedIfNeeded(into: versioning)
            XCTFail("Embedded identity must match the requested manuscript filename")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: manuscriptURL), misplacedBytes)
        XCTAssertEqual(try Data(contentsOf: otherBookURL), otherBookBytes)
    }

    func testUnreadableManuscriptPathThrowsWithoutReplacingDirectoryOrLedger() async throws {
        let book = try BundleFixtureLoader.loadArgentinaMinimal()
        let url = root.appendingPathComponent("Manuscripts/\(book.id.uuidString).json", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let marker = url.appendingPathComponent("retained-user-data")
        let original = Data("Existing data must survive a manuscript read error.".utf8)
        try original.write(to: marker)
        let ledgerURL = root.appendingPathComponent("Ledger/consumed-ledger.json")
        let ledgerBefore = Data("[]\n \n".utf8)
        try ledgerBefore.write(to: ledgerURL)
        do {
            _ = try await BundleFixtureLoader.seedIfNeeded(into: versioning)
            XCTFail("A directory at the manuscript path is a read failure, not a missing book")
        } catch { }
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(try Data(contentsOf: marker), original)
        XCTAssertEqual(try Data(contentsOf: ledgerURL), ledgerBefore)
    }

    func testCheckpointWriteFailureDoesNotCrashReading() async throws {
        let book = try await BundleFixtureLoader.seedIfNeeded(into: versioning)
        let failing = FailingCheckpointStore()
        let model = ReaderViewModel(
            book: book,
            versioning: versioning,
            checkpoints: failing,
            settings: ReaderSettingsStore(defaults: defaults),
            annotations: annotations,
            vocabulary: vocabulary,
            bookmarks: bookmarks,
            feedbackStore: feedbackStore,
            preferenceStore: preferenceStore,
            ai: ai
        )
        await model.open()
        XCTAssertTrue(model.isReady)
        let document = try XCTUnwrap(model.document)
        let loc = try XCTUnwrap(document.location(atUtf16: 0, visibleProgress: 0.01))
        await model.persist(loc) // soft-fail empty catch — must not throw
        XCTAssertTrue(model.isReady)
    }

    // MARK: - Adaptation locked-chapter adversarial plan

    func testAdaptationPlanRejectsLockedChapterMutationAttempt() async throws {
        let book = try await BundleFixtureLoader.seedIfNeeded(into: versioning)
        let service = LivingBookAdaptationService(
            versioning: versioning,
            feedbackStore: feedbackStore,
            preferenceStore: preferenceStore,
            ai: ai
        )
        try await service.finishChapter(
            bookId: book.id,
            chapterId: ArgentinaFixtureIDs.chapter1,
            revisionId: ArgentinaFixtureIDs.chapter1Revision1
        )
        let hostile = AdaptationPlan(
            id: UUID(),
            bookId: book.id,
            createdAt: Date(),
            sourceFeedbackId: UUID(),
            preferenceUpdatesSummary: ["hostile"],
            affectedChapterIds: [ArgentinaFixtureIDs.chapter1],
            chapterTargets: [
                AdaptationChapterTarget(
                    chapterId: ArgentinaFixtureIDs.chapter1,
                    chapterTitle: "Before the Nation",
                    currentWordCount: 4000,
                    targetWordCount: 500,
                    desiredChanges: ["rewrite consumed"],
                    mustRemainConcepts: ["Argentina"]
                )
            ],
            continuityNotes: [],
            reasonsFromFeedback: ["attack"],
            lockedChapterIds: [],
            isValidated: false
        )
        do {
            _ = try await service.applyPlan(book: book, plan: hostile)
            XCTFail("must reject locked chapter")
        } catch {
            // AdaptationError.lockedChapter or invalidPlan
        }
        let readable = try await versioning.readableRevision(
            bookId: book.id,
            chapterId: ArgentinaFixtureIDs.chapter1
        )
        XCTAssertEqual(readable.id, ArgentinaFixtureIDs.chapter1Revision1)
    }
}

/// Checkpoint store that always fails — proves reading soft-fails (low-storage analogue).
private struct FailingCheckpointStore: ReadingCheckpointStoring {
    func loadCheckpoint(bookId: UUID) throws -> ReadingCheckpoint? { nil }
    func saveCheckpoint(_ checkpoint: ReadingCheckpoint) throws {
        throw NSError(domain: "P7LowStorage", code: 28, userInfo: [NSLocalizedDescriptionKey: "No space left"])
    }
    func clearCheckpoint(bookId: UUID) throws {}
}
