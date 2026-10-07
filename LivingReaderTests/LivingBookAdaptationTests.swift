import XCTest
@testable import LivingReader

final class LivingBookAdaptationTests: XCTestCase {
    private var root: URL!
    private var versioning: ManuscriptVersioningService!
    private var feedbackStore: FileFeedbackStore!
    private var preferenceStore: FileReaderPreferenceStore!
    private var ai: MockAIService!
    private var service: LivingBookAdaptationService!
    private var book: Book!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LivingBookAdapt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        versioning = try ManuscriptVersioningService(rootDirectory: root)
        feedbackStore = try FileFeedbackStore(rootDirectory: root)
        preferenceStore = try FileReaderPreferenceStore(rootDirectory: root)
        ai = MockAIService()
        service = LivingBookAdaptationService(
            versioning: versioning,
            feedbackStore: feedbackStore,
            preferenceStore: preferenceStore,
            ai: ai
        )
        book = try BundleFixtureLoader.loadArgentinaMinimal()
        try await versioning.saveBook(book)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
        versioning = nil
        service = nil
        book = nil
        ai = nil
    }

    /// RDR-510 E2E: consume Ch1 v1 → Finish → feedback → plan → Apply → Ch2 changes; Ch1 remains v1.
    func testLivingBookLoop_ConsumeChapter1FinishFeedbackPlanApply_Chapter2Changes_Chapter1RemainsV1() async throws {
        let ch1 = ArgentinaFixtureIDs.chapter1
        let ch2 = ArgentinaFixtureIDs.chapter2
        let v1 = ArgentinaFixtureIDs.chapter1Revision1
        let ch2Before = try await versioning.readableRevision(bookId: book.id, chapterId: ch2)
        let ch2BeforeId = ch2Before.id
        let ch2BeforeText = ch2Before.blocks.map(\.text).joined(separator: "\n")

        // Finish Chapter 1 (transactional consume of exact v1)
        try await service.finishChapter(bookId: book.id, chapterId: ch1, revisionId: v1)
        let consumed = try await versioning.retrieveConsumedRevision(bookId: book.id, chapterId: ch1)
        XCTAssertEqual(consumed?.id, v1)

        let feedback = ChapterFeedback(
            id: UUID(),
            bookId: book.id,
            chapterId: ch1,
            revisionId: v1,
            overall: .fine,
            moreOf: [.stories, .placesIllVisit, .explanation],
            lessOf: [.repetition, .dates],
            freeText: "More traveler stories please",
            createdAt: Date()
        )

        let plan = try await service.submitFeedbackAndPlan(book: book, feedback: feedback)
        XCTAssertTrue(plan.isValidated)
        XCTAssertTrue(plan.lockedChapterIds.contains(ch1))
        XCTAssertFalse(plan.affectedChapterIds.contains(ch1), "Consumed chapter must not be in affected set")
        XCTAssertTrue(plan.affectedChapterIds.contains(ch2))
        XCTAssertFalse(plan.chapterTargets.isEmpty)

        // Stage 1 must not mutate book yet
        let midBook = try await versioning.loadBook(id: book.id)!
        let midCh2 = midBook.chapters.first { $0.id == ch2 }!
        XCTAssertEqual(midCh2.revisions.count, 1, "Plan must not mutate book before Apply")
        XCTAssertEqual(midCh2.activeRevisionId ?? ch2BeforeId, ch2BeforeId)

        let activated = try await service.applyPlan(book: book, plan: plan)
        XCTAssertFalse(activated.isEmpty)

        let ch2After = try await versioning.readableRevision(bookId: book.id, chapterId: ch2)
        XCTAssertNotEqual(ch2After.id, ch2BeforeId)
        let afterText = ch2After.blocks.map(\.text).joined(separator: "\n")
        XCTAssertTrue(afterText.contains("[Adapted]"), "Chapter 2 should show adapted content")
        XCTAssertNotEqual(afterText, ch2BeforeText)

        // Immutable past: Chapter 1 consumed revision remains exactly v1
        let ch1Readable = try await versioning.readableRevision(bookId: book.id, chapterId: ch1)
        XCTAssertEqual(ch1Readable.id, v1)
        XCTAssertEqual(ch1Readable.revisionIndex, 1)
        let ledger = try await versioning.ledgerSnapshot()
        XCTAssertEqual(ledger.first { $0.chapterId == ch1 }?.revisionId, v1)

        // Preferences updated through inspectable process
        let profile = try preferenceStore.load(bookId: book.id)
        XCTAssertFalse(profile.changeLog.isEmpty)
        XCTAssertGreaterThanOrEqual(profile.moreWeights[FeedbackMoreTopic.stories.rawValue] ?? 0, 0.65)

        // Feedback persisted
        let saved = try feedbackStore.loadAll(bookId: book.id)
        XCTAssertEqual(saved.first?.id, feedback.id)
    }

    /// RDR-511: Malformed generation cannot corrupt readable book.
    func testNewerRevisionDuringPlanGenerationIsKept() async throws {
        let chapterId = ArgentinaFixtureIDs.chapter2
        let preview = try await service.previewRegeneration(book: book, fromChapterId: chapterId, maxChapters: 1)
        let original = try await versioning.readableRevision(bookId: book.id, chapterId: chapterId)
        let versioning = self.versioning!
        let bookId = book.id
        ai.stubGenerate { request in
            _ = try await versioning.createRevision(
                bookId: bookId, chapterId: chapterId,
                blocks: [ContentBlock(id: UUID(), kind: .paragraph, text: "The newer revision must remain.", orderIndex: 0)]
            )
            return DeterministicAdaptationSynthesizer.generate(request)
        }
        do {
            _ = try await service.applyPlan(book: book, plan: preview.plan)
            XCTFail("Outdated plan generation must not publish")
        } catch ManuscriptError.staleRevision(let expected, let actual) {
            XCTAssertEqual(expected, original.id)
            let readable = try await versioning.readableRevision(bookId: bookId, chapterId: chapterId)
            XCTAssertEqual(actual, readable.id)
            XCTAssertEqual(readable.blocks.first?.text, "The newer revision must remain.")
        }
        let saved = try await versioning.loadBook(id: bookId)!
        let chapter = try XCTUnwrap(saved.chapters.first { $0.id == chapterId })
        XCTAssertEqual(chapter.revisions.count, 2)
        XCTAssertEqual(chapter.revisions.first, original)
        let phase = await service.currentState()
        XCTAssertEqual(phase, .failed)
    }

    func testMalformedGenerationDoesNotCorruptBook() async throws {
        let ch1 = ArgentinaFixtureIDs.chapter1
        let ch2 = ArgentinaFixtureIDs.chapter2
        let v1 = ArgentinaFixtureIDs.chapter1Revision1
        try await service.finishChapter(bookId: book.id, chapterId: ch1, revisionId: v1)

        let before = try await versioning.loadBook(id: book.id)!
        let beforeData = try JSONCoding.encoder.encode(before)

        let feedback = ChapterFeedback(
            id: UUID(),
            bookId: book.id,
            chapterId: ch1,
            revisionId: v1,
            overall: .needsImprovement,
            moreOf: [.economics],
            lessOf: [.names],
            freeText: "",
            createdAt: Date()
        )
        let plan = try await service.submitFeedbackAndPlan(book: book, feedback: feedback)
        ai.stubFailNextGenerate(true)

        do {
            _ = try await service.applyPlan(book: book, plan: plan)
            XCTFail("Expected malformed generation failure")
        } catch {
            // expected
        }

        let after = try await versioning.loadBook(id: book.id)!
        XCTAssertEqual(try JSONCoding.encoder.encode(after), beforeData)
        let ch2Readable = try await versioning.readableRevision(bookId: book.id, chapterId: ch2)
        XCTAssertEqual(ch2Readable.id, ArgentinaFixtureIDs.chapter2Revision1)
        let ch1Readable = try await versioning.retrieveConsumedRevision(bookId: book.id, chapterId: ch1)
        XCTAssertEqual(ch1Readable?.id, v1)
    }

    /// RDR-512: Cancel during planning leaves book unchanged.
    func testCancelDuringPlanningLeavesBookUnchanged() async throws {
        let ch1 = ArgentinaFixtureIDs.chapter1
        let v1 = ArgentinaFixtureIDs.chapter1Revision1
        try await service.finishChapter(bookId: book.id, chapterId: ch1, revisionId: v1)
        let before = try JSONCoding.encoder.encode(try await versioning.loadBook(id: book.id)!)

        await service.cancel()
        let stateAfterCancel = await service.currentState()
        XCTAssertEqual(stateAfterCancel, .cancelled)

        let after = try JSONCoding.encoder.encode(try await versioning.loadBook(id: book.id)!)
        XCTAssertEqual(after, before)
    }

    /// RDR-513: Reading / cold open works without AI (adapt counts stay 0).
    func testReadingWorksWithoutAI_ColdOpenAdaptCountZero() async throws {
        ai.resetCallCount()
        let loaded = try await versioning.loadBook(id: book.id)
        XCTAssertNotNil(loaded)
        let readable = try await versioning.readableRevision(bookId: book.id, chapterId: ArgentinaFixtureIDs.chapter1)
        XCTAssertFalse(readable.blocks.isEmpty)
        XCTAssertEqual(ai.adaptCallCount, 0)
        XCTAssertEqual(ai.askCallCount, 0)
    }

    /// RDR-514: Preference profile mutates only through inspectable engine.
    func testPreferenceProfileUpdatesOnlyViaInspectableProcess() throws {
        let feedback = ChapterFeedback(
            id: UUID(),
            bookId: book.id,
            chapterId: ArgentinaFixtureIDs.chapter1,
            revisionId: ArgentinaFixtureIDs.chapter1Revision1,
            overall: .excellent,
            moreOf: [.stories],
            lessOf: [.politicalDetail],
            freeText: "Love the voice",
            createdAt: Date()
        )
        let updated = try preferenceStore.applyFeedback(feedback)
        XCTAssertEqual(updated.changeLog.count, 1)
        XCTAssertEqual(updated.changeLog[0].feedbackId, feedback.id)
        XCTAssertFalse(updated.changeLog[0].details.isEmpty)
        XCTAssertEqual(updated.overallTone, "encourage_current_style")
        XCTAssertGreaterThanOrEqual(updated.moreWeights[FeedbackMoreTopic.stories.rawValue] ?? 0, 0.65)
    }

    /// RDR-515: Illegal / locked chapter in plan rejected; book unchanged.
    func testInvalidPlanWithLockedChapterRejected() async throws {
        let ch1 = ArgentinaFixtureIDs.chapter1
        let v1 = ArgentinaFixtureIDs.chapter1Revision1
        try await service.finishChapter(bookId: book.id, chapterId: ch1, revisionId: v1)
        let before = try JSONCoding.encoder.encode(try await versioning.loadBook(id: book.id)!)

        let badPlan = AdaptationPlan(
            id: UUID(),
            bookId: book.id,
            createdAt: Date(),
            sourceFeedbackId: UUID(),
            preferenceUpdatesSummary: [],
            affectedChapterIds: [ch1],
            chapterTargets: [
                AdaptationChapterTarget(
                    chapterId: ch1,
                    chapterTitle: "Before the Nation",
                    currentWordCount: 100,
                    targetWordCount: 120,
                    desiredChanges: ["Nope"],
                    mustRemainConcepts: ["nation"]
                )
            ],
            continuityNotes: [],
            reasonsFromFeedback: ["test"],
            lockedChapterIds: [ch1],
            isValidated: false
        )

        do {
            _ = try await service.applyPlan(book: book, plan: badPlan)
            XCTFail("Should reject locked chapter plan")
        } catch {
            // expected
        }
        let after = try JSONCoding.encoder.encode(try await versioning.loadBook(id: book.id)!)
        XCTAssertEqual(after, before)
    }

    /// Continuity / word-count sanity rejects bad generation without activating.
    func testWordCountAndContinuityGuardsRejectBadBlocks() async throws {
        let ch1 = ArgentinaFixtureIDs.chapter1
        let v1 = ArgentinaFixtureIDs.chapter1Revision1
        try await service.finishChapter(bookId: book.id, chapterId: ch1, revisionId: v1)
        let feedback = ChapterFeedback(
            id: UUID(),
            bookId: book.id,
            chapterId: ch1,
            revisionId: v1,
            overall: .fine,
            moreOf: [.stories],
            lessOf: [],
            freeText: "",
            createdAt: Date()
        )
        let plan = try await service.submitFeedbackAndPlan(book: book, feedback: feedback)
        let before = try JSONCoding.encoder.encode(try await versioning.loadBook(id: book.id)!)

        ai.stubGenerate { _ in
            [ContentBlock(id: UUID(), kind: .paragraph, text: "tiny", orderIndex: 0)]
        }
        do {
            _ = try await service.applyPlan(book: book, plan: plan)
            XCTFail("Expected word-count or continuity failure")
        } catch {
            // expected
        }
        let after = try JSONCoding.encoder.encode(try await versioning.loadBook(id: book.id)!)
        XCTAssertEqual(after, before)
    }

    func testApplyLengthPresetDefaultsToHalfAndScalesTargets() {
        XCTAssertEqual(AdaptationLengthPreset.applyDefault, .half)
        XCTAssertEqual(AdaptationLengthPreset.half.displayName, "Half-length")
        XCTAssertEqual(AdaptationLengthPreset.full.displayName, "Full")
        XCTAssertEqual(AdaptationLengthPreset.half.scaledWordCount(1000), 500)
        XCTAssertEqual(AdaptationLengthPreset.full.scaledWordCount(1000), 1000)
        XCTAssertEqual(AdaptationLengthPreset.half.impliedFullWordCount(fromScaled: 500), 1000)
        let chapterId = UUID()
        let sample = AdaptationPlan(
            id: UUID(),
            bookId: UUID(),
            createdAt: Date(),
            sourceFeedbackId: UUID(),
            preferenceUpdatesSummary: [],
            affectedChapterIds: [chapterId],
            chapterTargets: [
                AdaptationChapterTarget(
                    chapterId: chapterId,
                    chapterTitle: "Sample",
                    currentWordCount: 800,
                    targetWordCount: 400,
                    desiredChanges: [],
                    mustRemainConcepts: []
                )
            ],
            continuityNotes: [],
            reasonsFromFeedback: [],
            lockedChapterIds: [],
            isValidated: true,
            lengthPreset: .half
        )
        let retargeted = sample.retargeted(from: .half, to: .full)
        XCTAssertEqual(retargeted.resolvedLengthPreset, .full)
        XCTAssertEqual(retargeted.chapterTargets.first?.targetWordCount, 800)
    }

    func testSubmitFeedbackAndPlanHalfIsHalfOfFullTarget() async throws {
        let ch1 = ArgentinaFixtureIDs.chapter1
        let v1 = ArgentinaFixtureIDs.chapter1Revision1
        try await service.finishChapter(bookId: book.id, chapterId: ch1, revisionId: v1)
        let feedback = ChapterFeedback(
            id: UUID(),
            bookId: book.id,
            chapterId: ch1,
            revisionId: v1,
            overall: .fine,
            moreOf: [.stories],
            lessOf: [],
            freeText: "",
            createdAt: Date()
        )
        let full = try await service.submitFeedbackAndPlan(book: book, feedback: feedback, length: .full)
        await service.resetToIdle()
        let half = try await service.submitFeedbackAndPlan(book: book, feedback: feedback, length: .half)
        XCTAssertEqual(full.resolvedLengthPreset, .full)
        XCTAssertEqual(half.resolvedLengthPreset, .half)
        XCTAssertEqual(full.affectedChapterIds, half.affectedChapterIds)
        for (fullTarget, halfTarget) in zip(full.chapterTargets, half.chapterTargets) {
            XCTAssertEqual(fullTarget.chapterId, halfTarget.chapterId)
            XCTAssertEqual(
                halfTarget.targetWordCount,
                AdaptationLengthPreset.half.scaledWordCount(fullTarget.targetWordCount)
            )
        }
    }

    func testPreviewRegenerationHalfScalesTargetsWithoutTimeGuardrail() async throws {
        let chapterId = ArgentinaFixtureIDs.chapter2
        let full = try await service.previewRegeneration(
            book: book,
            fromChapterId: chapterId,
            maxChapters: 1,
            length: .full
        )
        await service.resetToIdle()
        let half = try await service.previewRegeneration(
            book: book,
            fromChapterId: chapterId,
            maxChapters: 1,
            length: .half
        )
        XCTAssertEqual(full.plan.resolvedLengthPreset, .full)
        XCTAssertEqual(half.plan.resolvedLengthPreset, .half)
        let fullWC = try XCTUnwrap(full.plan.chapterTargets.first?.targetWordCount)
        let halfWC = try XCTUnwrap(half.plan.chapterTargets.first?.targetWordCount)
        XCTAssertEqual(halfWC, AdaptationLengthPreset.half.scaledWordCount(fullWC))
        XCTAssertLessThan(half.plannedRemaining.remainingMinutes, full.plannedRemaining.remainingMinutes)
    }
}
