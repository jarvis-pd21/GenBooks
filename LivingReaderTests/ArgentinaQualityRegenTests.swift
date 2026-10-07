import XCTest
@testable import LivingReader

/// RDR-914: autonomous Argentina quality feedback → PE-wired plan/generate.
final class ArgentinaQualityRegenTests: XCTestCase {
    private var root: URL!
    private var versioning: ManuscriptVersioningService!
    private var feedbackStore: FileFeedbackStore!
    private var preferenceStore: FileReaderPreferenceStore!
    private var packets: FilePEPacketStore!
    private var ai: MockAIService!
    private var service: LivingBookAdaptationService!
    private var book: Book!

    private let ch1 = ArgentinaFixtureIDs.chapter1
    private let ch2 = ArgentinaFixtureIDs.chapter2
    private let v1 = ArgentinaFixtureIDs.chapter1Revision1

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArgentinaQualityRegen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        packets = try FilePEPacketStore(rootDirectory: root)
        versioning = try ManuscriptVersioningService(rootDirectory: root, packets: packets)
        feedbackStore = try FileFeedbackStore(rootDirectory: root)
        preferenceStore = try FileReaderPreferenceStore(rootDirectory: root)
        ai = MockAIService()
        service = LivingBookAdaptationService(
            versioning: versioning,
            feedbackStore: feedbackStore,
            preferenceStore: preferenceStore,
            ai: ai,
            packets: packets
        )
        book = try BundleFixtureLoader.loadArgentinaMinimal()
        try await versioning.saveBook(book)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
        versioning = nil
        feedbackStore = nil
        preferenceStore = nil
        packets = nil
        ai = nil
        service = nil
        book = nil
    }

    /// Preset answers the existing feedback Q&A — no new topics or chrome.
    func testQualityPresetUsesExistingFeedbackEnums() {
        let feedback = ArgentinaQualityRegen.makeFeedback(
            bookId: book.id,
            chapterId: ch1,
            revisionId: v1
        )
        XCTAssertEqual(feedback.overall, .excellent)
        XCTAssertEqual(Set(feedback.moreOf), Set([.stories, .placesIllVisit, .explanation]))
        XCTAssertEqual(Set(feedback.lessOf), Set([.dates, .repetition]))
        XCTAssertTrue(feedback.freeText.localizedCaseInsensitiveContains("historical"))
        XCTAssertTrue(feedback.freeText.localizedCaseInsensitiveContains("concrete"))
        XCTAssertFalse(feedback.freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        for topic in feedback.moreOf {
            XCTAssertTrue(FeedbackMoreTopic.allCases.contains(topic))
        }
        for topic in feedback.lessOf {
            XCTAssertTrue(FeedbackLessTopic.allCases.contains(topic))
        }
        XCTAssertEqual(ArgentinaQualityRegen.launchArgument, "-argentinaQualityRegen")
    }

    /// Generation stays Astra; Ask stays Luna. Live path needs the Keychain key;
    /// tests use Mock / deterministic (same soft-fail the resolver uses when empty).
    func testGenerationStaysAstraAndAskStaysLuna() {
        XCTAssertEqual(OpenAIModelOption.defaultGeneration, .gpt6Astra)
        XCTAssertEqual(OpenAIModelOption.defaultGeneration.rawValue, "gpt-6-astra")
        XCTAssertEqual(OpenAIModelOption.defaultAsk, .gpt56Luna)
        XCTAssertEqual(OpenAIModelOption.defaultAsk.rawValue, "gpt-5.6-luna")
    }

    /// RDR-914: load Argentina → quality preset → plan/apply with PE packets.
    /// Consumed past stays v1; unread chapters get gated new revisions.
    func testAutonomousQualityRegenAdaptsUnreadAndLeavesConsumedPastIntact() async throws {
        let ch2Before = try await versioning.readableRevision(bookId: book.id, chapterId: ch2)
        let ch2BeforeId = ch2Before.id
        let ch2BeforeText = ch2Before.blocks.map(\.text).joined(separator: "\n")

        let result = try await ArgentinaQualityRegen.run(
            book: book,
            versioning: versioning,
            service: service
        )

        XCTAssertFalse(result.sourceWasAlreadyConsumed)
        XCTAssertEqual(result.consumedChapterId, ch1)
        XCTAssertEqual(result.consumedRevisionId, v1)
        XCTAssertTrue(result.plan.isValidated)
        XCTAssertTrue(result.plan.lockedChapterIds.contains(ch1))
        XCTAssertFalse(result.plan.affectedChapterIds.contains(ch1))
        XCTAssertTrue(result.plan.affectedChapterIds.contains(ch2))
        XCTAssertFalse(result.activatedRevisions.isEmpty)

        let reasons = result.plan.reasonsFromFeedback.joined(separator: " ")
        XCTAssertTrue(reasons.contains("Excellent"))
        XCTAssertTrue(reasons.localizedCaseInsensitiveContains("Stories"))
        XCTAssertTrue(reasons.localizedCaseInsensitiveContains("Dates"))
        XCTAssertTrue(result.plan.chapterTargets.contains { target in
            target.desiredChanges.contains { $0.localizedCaseInsensitiveContains("stories") }
        })

        let ch1Readable = try await versioning.readableRevision(bookId: book.id, chapterId: ch1)
        XCTAssertEqual(ch1Readable.id, v1)
        XCTAssertEqual(ch1Readable.revisionIndex, 1)
        let consumed = try await versioning.retrieveConsumedRevision(bookId: book.id, chapterId: ch1)
        XCTAssertEqual(consumed?.id, v1)

        let ch2After = try await versioning.readableRevision(bookId: book.id, chapterId: ch2)
        XCTAssertNotEqual(ch2After.id, ch2BeforeId)
        let afterText = ch2After.blocks.map(\.text).joined(separator: "\n")
        XCTAssertTrue(afterText.contains("[Adapted]"))
        XCTAssertNotEqual(afterText, ch2BeforeText)

        let saved = try feedbackStore.loadAll(bookId: book.id)
        XCTAssertEqual(saved.first?.id, result.feedback.id)
        XCTAssertEqual(saved.first?.overall, .excellent)

        let profile = try preferenceStore.load(bookId: book.id)
        XCTAssertEqual(profile.overallTone, "encourage_current_style")
        XCTAssertGreaterThanOrEqual(profile.moreWeights[FeedbackMoreTopic.stories.rawValue] ?? 0, 0.65)
        XCTAssertFalse(profile.changeLog.isEmpty)

        let planRequest = try XCTUnwrap(ai.lastPlanRequest)
        XCTAssertNotNil(planRequest.packet, "Quality regen must hand PE packets to Astra plan")
        XCTAssertEqual(planRequest.packet?.brief?.bookId, book.id)
        XCTAssertTrue(
            planRequest.packet?.continuity.consumedEntries.contains { $0.chapterId == ch1 } == true,
            "Plan packet must carry the consumed chapter as immutable continuity"
        )

        let generateRequest = try XCTUnwrap(ai.lastGenerateRequest)
        XCTAssertNotNil(generateRequest.packet)
        XCTAssertEqual(ai.askCallCount, 0, "Ask/Luna must stay off the quality-regen path")

        let continuity = try packets.loadContinuity(bookId: book.id)
        let consumedEntry = try XCTUnwrap(continuity.entry(chapterId: ch1))
        XCTAssertTrue(consumedEntry.isConsumed)
        XCTAssertEqual(consumedEntry.revisionId, v1)
        if let adapted = result.activatedRevisions.first {
            let unreadEntry = try XCTUnwrap(continuity.entry(chapterId: adapted.chapterId))
            XCTAssertEqual(unreadEntry.revisionId, adapted.id)
            XCTAssertFalse(unreadEntry.isConsumed)
        }
    }

    /// Re-running against an already-finished chapter must not rewrite it.
    func testAlreadyConsumedSourceIsNotRefinished() async throws {
        try await service.finishChapter(bookId: book.id, chapterId: ch1, revisionId: v1)
        let firstResult = try await ArgentinaQualityRegen.run(
            book: book,
            versioning: versioning,
            service: service
        )
        XCTAssertTrue(firstResult.sourceWasAlreadyConsumed)
        XCTAssertEqual(firstResult.consumedRevisionId, v1)

        let consumed = try await versioning.retrieveConsumedRevision(bookId: book.id, chapterId: ch1)
        XCTAssertEqual(consumed?.id, v1)
        let ch1Readable = try await versioning.readableRevision(bookId: book.id, chapterId: ch1)
        XCTAssertEqual(ch1Readable.id, v1)
    }

    /// Fact gate still rejects unverified essential claims on this path.
    func testUnverifiedEssentialClaimOnQualityPathLeavesBookUnchanged() async throws {
        let planned = try await ArgentinaQualityRegen.plan(
            book: book,
            versioning: versioning,
            service: service
        )
        let before = try JSONCoding.encoder.encode(try await versioning.loadBook(id: book.id)!)
        let continuityBefore = try packets.loadContinuity(bookId: book.id)

        ai.stubGeneratedPacket { request in
            GeneratedChapter(
                blocks: [],
                proposedClaims: [
                    FactClaim(
                        id: FactClaim.stableId(
                            chapterId: request.chapterId,
                            statement: "Perón nationalised the railways in 1948."
                        ),
                        chapterId: request.chapterId,
                        statement: "Perón nationalised the railways in 1948.",
                        importance: .essential,
                        status: .unverified,
                        evidenceIds: ["ev-rail"]
                    )
                ],
                proposedEvidence: [
                    FactEvidenceItem(
                        id: "ev-rail",
                        sourceLabel: "Fixture source",
                        digest: "Ferrocarriles Argentinos founding decree."
                    )
                ]
            )
        }

        do {
            _ = try await service.applyPlan(book: book, plan: planned.plan)
            XCTFail("Quality regen Apply should still be blocked by the fact gate")
        } catch let error as PEGateError {
            guard case .unverifiedEssentialClaim = error else {
                return XCTFail("Expected unverifiedEssentialClaim, got \(error)")
            }
        }

        let after = try JSONCoding.encoder.encode(try await versioning.loadBook(id: book.id)!)
        XCTAssertEqual(after, before)
        let consumedAfter = try await versioning.retrieveConsumedRevision(bookId: book.id, chapterId: ch1)
        XCTAssertEqual(consumedAfter?.id, v1)
        let ch2Readable = try await versioning.readableRevision(bookId: book.id, chapterId: ch2)
        XCTAssertEqual(ch2Readable.id, ArgentinaFixtureIDs.chapter2Revision1)
        XCTAssertTrue(try packets.loadFactChecklist(bookId: book.id).claims.isEmpty)
        XCTAssertEqual(
            try packets.loadContinuity(bookId: book.id).timeline.map(\.revisionId),
            continuityBefore.timeline.map(\.revisionId)
        )
    }

    /// Reading-time guardrails still fire on a quality plan that carries a baseline.
    func testReadingTimeGuardrailStillRejectsImpossibleQualityPlan() async throws {
        let planned = try await ArgentinaQualityRegen.plan(
            book: book,
            versioning: versioning,
            service: service
        )
        let firstTarget = try XCTUnwrap(planned.plan.chapterTargets.first)
        let current = try await versioning.readableRevision(bookId: book.id, chapterId: firstTarget.chapterId)
        let baseline = ReadingTimeEstimator.estimate(blocks: current.blocks, preferences: .default)

        var hostile = planned.plan
        hostile.readingTimeBaselineMinutes = baseline.remainingMinutes
        hostile.readingTimePreferences = .default
        hostile.chapterTargets = hostile.chapterTargets.map { target in
            var inflated = target
            inflated.targetWordCount = max(5000, target.currentWordCount * 20)
            return inflated
        }
        let before = try JSONCoding.encoder.encode(try await versioning.loadBook(id: book.id)!)

        do {
            _ = try await service.applyPlan(book: book, plan: hostile)
            XCTFail("Inflated remaining-time target must fail the guardrail")
        } catch let error as AdaptationError {
            guard case .readingTimeGuardrailFailed = error else {
                return XCTFail("Expected readingTimeGuardrailFailed, got \(error)")
            }
        }

        let after = try JSONCoding.encoder.encode(try await versioning.loadBook(id: book.id)!)
        XCTAssertEqual(after, before)
        let consumedAfter = try await versioning.retrieveConsumedRevision(bookId: book.id, chapterId: ch1)
        XCTAssertEqual(consumedAfter?.id, v1)
    }
}
