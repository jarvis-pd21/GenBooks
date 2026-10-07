import XCTest
@testable import LivingReader

final class Wave2GenerativeTests: XCTestCase {
    private var root: URL!
    private var versioning: ManuscriptVersioningService!
    private var book: Book!
    private var feedbackStore: FileFeedbackStore!
    private var preferenceStore: FileReaderPreferenceStore!
    private var ai: MockAIService!
    private var adaptation: LivingBookAdaptationService!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Wave2Gen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        versioning = try ManuscriptVersioningService(rootDirectory: root)
        book = try BundleFixtureLoader.loadArgentinaMinimal()
        try await versioning.saveBook(book)
        feedbackStore = try FileFeedbackStore(rootDirectory: root)
        preferenceStore = try FileReaderPreferenceStore(rootDirectory: root)
        ai = MockAIService()
        adaptation = LivingBookAdaptationService(
            versioning: versioning,
            feedbackStore: feedbackStore,
            preferenceStore: preferenceStore,
            ai: ai
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
        versioning = nil
        book = nil
        adaptation = nil
        ai = nil
    }

    func testRestorePriorRevisionCreatesNewTipWithoutMutatingSourceOrLedger() async throws {
        let chapterId = ArgentinaFixtureIDs.chapter2
        let v1 = try await versioning.readableRevision(bookId: book.id, chapterId: chapterId)
        let v1BlocksFingerprint = try JSONCoding.encoder.encode(v1.blocks)

        let v2 = try await versioning.createRevision(
            bookId: book.id,
            chapterId: chapterId,
            blocks: [
                ContentBlock(id: UUID(), kind: .heading, text: "Independence Sparks v2", orderIndex: 0),
                ContentBlock(id: UUID(), kind: .paragraph, text: "A rewritten future chapter for restore tests.", orderIndex: 1)
            ]
        )
        XCTAssertNotEqual(v2.id, v1.id)

        let history = try await versioning.listChapterVersions(bookId: book.id, chapterId: chapterId)
        XCTAssertGreaterThanOrEqual(history.count, 2)
        XCTAssertTrue(history.contains { $0.revisionId == v1.id })
        XCTAssertTrue(history.contains { $0.revisionId == v2.id && $0.isActive })

        let restored = try await versioning.restoreRevision(
            bookId: book.id,
            chapterId: chapterId,
            sourceRevisionId: v1.id
        )
        XCTAssertNotEqual(restored.id, v1.id, "Restore must append a new revision tip")
        XCTAssertEqual(restored.blocks.map(\.text), v1.blocks.map(\.text))
        XCTAssertNotEqual(Set(restored.blocks.map(\.id)), Set(v1.blocks.map(\.id)), "Copied blocks get new IDs")

        let reloaded = try await versioning.loadBook(id: book.id)!
        let chapter = reloaded.chapters.first { $0.id == chapterId }!
        XCTAssertEqual(chapter.revisions.count, 3)
        XCTAssertEqual(chapter.activeRevisionId, restored.id)

        let sourceStill = chapter.revision(id: v1.id)!
        XCTAssertEqual(try JSONCoding.encoder.encode(sourceStill.blocks), v1BlocksFingerprint)
        let ledgerCount = try await versioning.ledgerSnapshot().count
        XCTAssertEqual(ledgerCount, 0)
    }

    func testRestoreRejectedForConsumedChapterLeavesLedgerAndBodiesIntact() async throws {
        let chapterId = ArgentinaFixtureIDs.chapter1
        let v1Id = ArgentinaFixtureIDs.chapter1Revision1
        try await versioning.consume(bookId: book.id, chapterId: chapterId, revisionId: v1Id)

        _ = try await versioning.createRevision(
            bookId: book.id,
            chapterId: chapterId,
            blocks: [ContentBlock(id: UUID(), kind: .paragraph, text: "Future-only revision", orderIndex: 0)]
        )
        let history = try await versioning.listChapterVersions(bookId: book.id, chapterId: chapterId)
        XCTAssertFalse(history.isEmpty)
        XCTAssertTrue(
            history.allSatisfy(\.isConsumedLocked),
            "A consumed chapter is wholly read-only; alternate rows must not expose Restore"
        )

        let before = try await versioning.loadBook(id: book.id)!
        let beforeData = try JSONCoding.encoder.encode(before)
        let ledgerBefore = try JSONCoding.encoder.encode(try await versioning.ledgerSnapshot())

        do {
            _ = try await versioning.restoreRevision(
                bookId: book.id,
                chapterId: chapterId,
                sourceRevisionId: v1Id
            )
            XCTFail("Expected cannotMutateConsumedChapter")
        } catch ManuscriptError.cannotMutateConsumedChapter(let id) {
            XCTAssertEqual(id, chapterId)
        }

        let after = try await versioning.loadBook(id: book.id)!
        XCTAssertEqual(try JSONCoding.encoder.encode(after), beforeData)
        let ledgerAfter = try JSONCoding.encoder.encode(try await versioning.ledgerSnapshot())
        XCTAssertEqual(ledgerAfter, ledgerBefore)

        let consumed = try await versioning.retrieveConsumedRevision(bookId: book.id, chapterId: chapterId)
        XCTAssertEqual(consumed?.id, v1Id)
    }

    func testReadingTimeEstimatorWordsAndVisualWeight() throws {
        let prefs = ReadingTimePreferences(wordsPerMinute: 200, secondsPerVisual: 30, toleranceFraction: 0.2)
        let blocks = [
            ContentBlock(id: UUID(), kind: .paragraph, text: Array(repeating: "word", count: 400).joined(separator: " "), orderIndex: 0),
            ContentBlock(id: UUID(), kind: .imagePlaceholder, text: "map", orderIndex: 1),
            ContentBlock(id: UUID(), kind: .imagePlaceholder, text: "portrait", orderIndex: 2)
        ]
        let estimate = ReadingTimeEstimator.estimate(blocks: blocks, preferences: prefs)
        XCTAssertEqual(estimate.proseWordCount, 400)
        XCTAssertEqual(estimate.visualBlockCount, 2)
        XCTAssertEqual(estimate.proseMinutes, 2.0, accuracy: 0.001)
        XCTAssertEqual(estimate.visualMinutes, 1.0, accuracy: 0.001)
        XCTAssertEqual(estimate.remainingMinutes, 3.0, accuracy: 0.001)
        XCTAssertFalse(estimate.displayLabel.contains("page"))
    }

    func testReadingTimeGuardrailEnforcedOnRegenPlan() async throws {
        let chapterId = ArgentinaFixtureIDs.chapter2
        let prefs = ReadingTimePreferences.default
        let current = try await versioning.readableRevision(bookId: book.id, chapterId: chapterId)
        let baseline = ReadingTimeEstimator.estimate(blocks: current.blocks, preferences: prefs)
        let hostile = AdaptationPlan(
            id: UUID(),
            bookId: book.id,
            createdAt: Date(),
            sourceFeedbackId: UUID(),
            preferenceUpdatesSummary: ["hostile"],
            affectedChapterIds: [chapterId],
            chapterTargets: [
                AdaptationChapterTarget(
                    chapterId: chapterId,
                    chapterTitle: "Ch2",
                    currentWordCount: baseline.proseWordCount,
                    targetWordCount: max(5000, baseline.proseWordCount * 20),
                    desiredChanges: ["inflate"],
                    mustRemainConcepts: ["Argentina"]
                )
            ],
            continuityNotes: [],
            reasonsFromFeedback: ["test"],
            lockedChapterIds: [],
            isValidated: true,
            readingTimeBaselineMinutes: baseline.remainingMinutes
        )

        do {
            _ = try await adaptation.applyPlan(book: book, plan: hostile)
            XCTFail("Expected readingTimeGuardrailFailed")
        } catch AdaptationError.readingTimeGuardrailFailed {
            // expected
        } catch {
            XCTFail("Unexpected error \(error)")
        }

        let unchanged = try await versioning.loadBook(id: book.id)!
        XCTAssertEqual(
            unchanged.chapters.first { $0.id == chapterId }?.revisions.count,
            book.chapters.first { $0.id == chapterId }?.revisions.count
        )
    }

    func testRegenerateFromHerePreviewAndApplyPreservesTimeAndLocks() async throws {
        let ch1 = ArgentinaFixtureIDs.chapter1
        let ch1Rev = ArgentinaFixtureIDs.chapter1Revision1
        try await versioning.consume(bookId: book.id, chapterId: ch1, revisionId: ch1Rev)

        let ordered = book.chapters.sorted { $0.orderIndex < $1.orderIndex }
        guard let cut = ordered.first(where: { $0.id == ArgentinaFixtureIDs.chapter2 }) ?? ordered.dropFirst().first else {
            return XCTFail("Need a cut chapter")
        }

        let beforeCh1 = try await versioning.retrieveConsumedRevision(bookId: book.id, chapterId: ch1)
        let beforeCh1Data = try JSONCoding.encoder.encode(beforeCh1)

        let preview = try await adaptation.previewRegeneration(
            book: book,
            fromChapterId: cut.id,
            preferences: .default,
            maxChapters: 2
        )
        XCTAssertEqual(preview.cut.chapterId, cut.id)
        XCTAssertFalse(preview.regeneratingChapters.contains { $0.id == ch1 })
        XCTAssertGreaterThan(preview.baselineRemaining.remainingMinutes, 0)
        XCTAssertNotNil(preview.plan.readingTimeBaselineMinutes)
        XCTAssertFalse(preview.plan.affectedChapterIds.contains(ch1))
        XCTAssertEqual(preview.regeneratingChapters.map(\.id), preview.plan.affectedChapterIds)
        XCTAssertNoThrow(
            try ReadingTimeGuardrail.assertPreservesRemainingTime(
                baseline: preview.baselineRemaining,
                planned: preview.plannedRemaining,
                preferences: .default
            ),
            "Baseline and projected labels must compare the same full remaining range"
        )

        let activated = try await adaptation.applyRegeneration(book: book, preview: preview)
        XCTAssertFalse(activated.isEmpty)

        let afterCh1 = try await versioning.retrieveConsumedRevision(bookId: book.id, chapterId: ch1)
        XCTAssertEqual(try JSONCoding.encoder.encode(afterCh1), beforeCh1Data)
        let readableCh1 = try await versioning.readableRevision(bookId: book.id, chapterId: ch1)
        XCTAssertEqual(readableCh1.id, ch1Rev)

        for target in preview.plan.chapterTargets {
            let readable = try await versioning.readableRevision(bookId: book.id, chapterId: target.chapterId)
            XCTAssertTrue(
                readable.blocks.contains { $0.text.localizedCaseInsensitiveContains("adapted") }
                || readable.revisionIndex > 1
            )
        }
    }

    func testRegenerationRejectsConsumedCutInsteadOfSilentlyMovingBoundary() async throws {
        let chapterId = ArgentinaFixtureIDs.chapter1
        try await versioning.consume(
            bookId: book.id,
            chapterId: chapterId,
            revisionId: ArgentinaFixtureIDs.chapter1Revision1
        )

        do {
            _ = try await adaptation.previewRegeneration(
                book: book,
                fromChapterId: chapterId
            )
            XCTFail("A locked cut must not silently shift to a later chapter")
        } catch AdaptationError.lockedChapter(let id) {
            XCTAssertEqual(id, chapterId)
        }
    }

    func testActualGeneratedReadingTimeIsCheckedBeforeActivation() async throws {
        let chapterId = ArgentinaFixtureIDs.chapter2
        let before = try await versioning.loadBook(id: book.id)!
        let beforeRevisionCount = before.chapters.first { $0.id == chapterId }!.revisions.count
        let preview = try await adaptation.previewRegeneration(
            book: book,
            fromChapterId: chapterId,
            preferences: ReadingTimePreferences(
                wordsPerMinute: 180,
                secondsPerVisual: 15,
                toleranceFraction: 0.20
            ),
            maxChapters: 1
        )

        ai.stubGenerate { request in
            let required = request.target.mustRemainConcepts.joined(separator: " ")
            let desiredCount = max(10, Int(Double(request.target.targetWordCount) * 0.55))
            let requiredCount = AdaptationPlanValidator.wordCount(of: required)
            let filler = Array(repeating: "filler", count: max(0, desiredCount - requiredCount))
                .joined(separator: " ")
            return [
                ContentBlock(
                    id: UUID(),
                    kind: .paragraph,
                    text: "\(required) \(filler)",
                    orderIndex: 0
                )
            ]
        }

        do {
            _ = try await adaptation.applyRegeneration(book: book, preview: preview)
            XCTFail("Generated output outside the time band must not activate")
        } catch AdaptationError.readingTimeGuardrailFailed {
            // expected
        }

        let after = try await versioning.loadBook(id: book.id)!
        XCTAssertEqual(
            after.chapters.first { $0.id == chapterId }!.revisions.count,
            beforeRevisionCount
        )
    }

    func testRegenerationPreservesVisualPlaceholdersAndActualTime() async throws {
        let chapterId = ArgentinaFixtureIDs.chapter2
        let visualText = "Map of the Río de la Plata trade routes"
        let source = try await versioning.createRevision(
            bookId: book.id,
            chapterId: chapterId,
            blocks: [
                ContentBlock(id: UUID(), kind: .heading, text: "Independence", orderIndex: 0),
                ContentBlock(
                    id: UUID(),
                    kind: .paragraph,
                    text: Array(repeating: "Argentina changed through conflict and negotiation.", count: 80)
                        .joined(separator: " "),
                    orderIndex: 1
                ),
                ContentBlock(id: UUID(), kind: .imagePlaceholder, text: visualText, orderIndex: 2)
            ]
        )
        let latest = try await versioning.loadBook(id: book.id)!
        let preview = try await adaptation.previewRegeneration(
            book: latest,
            fromChapterId: chapterId,
            preferences: .default,
            maxChapters: 1
        )

        _ = try await adaptation.applyRegeneration(book: latest, preview: preview)
        let regenerated = try await versioning.readableRevision(bookId: book.id, chapterId: chapterId)
        let visuals = regenerated.blocks.filter { $0.kind == .imagePlaceholder }
        XCTAssertEqual(visuals.map(\.text), [visualText])
        XCTAssertNotEqual(visuals.first?.id, source.blocks.last?.id)
        XCTAssertNoThrow(
            try ReadingTimeGuardrail.assertPreservesRemainingTime(
                baseline: ReadingTimeEstimator.estimate(blocks: source.blocks),
                planned: ReadingTimeEstimator.estimate(blocks: regenerated.blocks),
                preferences: .default
            )
        )
    }

    func testRegeneratedUnreadTextRemainsOutOfNormalAskPayload() throws {
        let marker = "REGENERATED_UNREAD_SPOILER_\(UUID().uuidString)"
        let slices: [AskContextBuilder.ReadingSlice] = [
            .init(
                chapterId: ArgentinaFixtureIDs.chapter1,
                title: "Consumed",
                orderIndex: 0,
                revisionId: ArgentinaFixtureIDs.chapter1Revision1,
                plainText: "Safe consumed context",
                isConsumed: true,
                isCurrent: true
            ),
            .init(
                chapterId: ArgentinaFixtureIDs.chapter2,
                title: "Regenerated future",
                orderIndex: 1,
                revisionId: UUID(),
                plainText: marker,
                isConsumed: false,
                isCurrent: false
            )
        ]
        let request = AskContextBuilder.buildRequest(
            question: "Explain what I have read",
            book: book,
            slices: slices,
            selectedText: nil,
            surroundingContext: nil,
            currentChapterId: ArgentinaFixtureIDs.chapter1,
            notesAndQuestions: nil,
            readerPreferencesSummary: nil,
            allowUnreadSpoilers: false
        )

        XCTAssertFalse(AskContextBuilder.contextPayload(for: request).contains(marker))
    }

    func testTargetWordCountPreservesMinutesWithVisuals() {
        let prefs = ReadingTimePreferences(wordsPerMinute: 240, secondsPerVisual: 60, toleranceFraction: 0.2)
        let baseline = ReadingTimeEstimate(
            proseWordCount: 480,
            visualBlockCount: 2,
            wordsPerMinute: 240,
            secondsPerVisual: 60
        )
        XCTAssertEqual(baseline.remainingMinutes, 4.0, accuracy: 0.001)
        let target = ReadingTimeEstimator.targetWordCount(
            preservingMinutes: baseline,
            plannedVisualCount: 2,
            preferences: prefs
        )
        XCTAssertEqual(target, 480)
        let planned = ReadingTimeEstimate(
            proseWordCount: target,
            visualBlockCount: 2,
            wordsPerMinute: 240,
            secondsPerVisual: 60
        )
        XCTAssertNoThrow(
            try ReadingTimeGuardrail.assertPreservesRemainingTime(
                baseline: baseline,
                planned: planned,
                preferences: prefs
            )
        )
    }
}
