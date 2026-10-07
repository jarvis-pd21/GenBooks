import Foundation

/// Autonomous quality-regen answers for the existing Chapter Feedback Q&A
/// (Finish → Feedback → Plan → Apply). Not a Create/New Book wizard.
///
/// Live overnight path uses the same Keychain key as Ask/adapt:
/// generation rides `gpt-6-astra`, Ask stays `gpt-5.6-luna`. Missing key
/// soft-fails into the deterministic synthesizer (tests use Mock).
enum ArgentinaQualityRegen {
    /// Hidden Manager / UITest launch argument. No always-visible chrome.
    static let launchArgument = "-argentinaQualityRegen"

    /// Sensible defaults tuned to the existing feedback enums.
    enum Preset {
        static let overall: FeedbackOverallRating = .excellent
        static let moreOf: [FeedbackMoreTopic] = [.stories, .placesIllVisit, .explanation]
        static let lessOf: [FeedbackLessTopic] = [.dates, .repetition]
        static let freeText = """
        Please tell clearer historical stories with concrete people, scenes, and \
        sensory detail — less dry chronology or list-like recitation.
        """
    }

    struct Result: Sendable {
        var feedback: ChapterFeedback
        var plan: AdaptationPlan
        var activatedRevisions: [ChapterRevision]
        var consumedChapterId: UUID
        var consumedRevisionId: UUID
        var sourceWasAlreadyConsumed: Bool
    }

    static func makeFeedback(
        bookId: UUID,
        chapterId: UUID,
        revisionId: UUID,
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) -> ChapterFeedback {
        ChapterFeedback(
            id: id,
            bookId: bookId,
            chapterId: chapterId,
            revisionId: revisionId,
            overall: Preset.overall,
            moreOf: Preset.moreOf,
            lessOf: Preset.lessOf,
            freeText: Preset.freeText,
            createdAt: createdAt
        )
    }

    /// Overnight-safe loop: consume the first unread source chapter if needed,
    /// submit the quality preset, then Apply via `LivingBookAdaptationService`
    /// (PE packets + fact gate already on that path).
    static func run(
        book: Book,
        versioning: ManuscriptVersioningService,
        service: LivingBookAdaptationService
    ) async throws -> Result {
        let prepared = try await prepareSource(
            book: book,
            versioning: versioning,
            service: service
        )
        let plan = try await service.submitFeedbackAndPlan(book: book, feedback: prepared.feedback)
        let activated = try await service.applyPlan(book: book, plan: plan)
        return Result(
            feedback: prepared.feedback,
            plan: plan,
            activatedRevisions: activated,
            consumedChapterId: prepared.chapterId,
            consumedRevisionId: prepared.revisionId,
            sourceWasAlreadyConsumed: prepared.alreadyConsumed
        )
    }

    /// Stage 1 only — tests can stub generation / fact-gate failures before Apply.
    static func plan(
        book: Book,
        versioning: ManuscriptVersioningService,
        service: LivingBookAdaptationService
    ) async throws -> (feedback: ChapterFeedback, plan: AdaptationPlan, alreadyConsumed: Bool) {
        let prepared = try await prepareSource(
            book: book,
            versioning: versioning,
            service: service
        )
        let plan = try await service.submitFeedbackAndPlan(book: book, feedback: prepared.feedback)
        return (prepared.feedback, plan, prepared.alreadyConsumed)
    }

    // MARK: - Source chapter

    private struct PreparedSource {
        var chapterId: UUID
        var revisionId: UUID
        var feedback: ChapterFeedback
        var alreadyConsumed: Bool
    }

    /// Feedback is always for a finished chapter. Use the latest consumed
    /// chapter when the ledger already has one; otherwise Finish chapter 1.
    private static func prepareSource(
        book: Book,
        versioning: ManuscriptVersioningService,
        service: LivingBookAdaptationService
    ) async throws -> PreparedSource {
        let ordered = book.chapters.sorted { $0.orderIndex < $1.orderIndex }
        let ledger = try await versioning.ledgerSnapshot()
        let consumed = ledger.filter { $0.bookId == book.id }

        if let latest = consumed.max(by: { lhs, rhs in
            if lhs.consumedAt != rhs.consumedAt { return lhs.consumedAt < rhs.consumedAt }
            let lhsOrder = ordered.first { $0.id == lhs.chapterId }?.orderIndex ?? 0
            let rhsOrder = ordered.first { $0.id == rhs.chapterId }?.orderIndex ?? 0
            return lhsOrder < rhsOrder
        }) {
            return PreparedSource(
                chapterId: latest.chapterId,
                revisionId: latest.revisionId,
                feedback: makeFeedback(
                    bookId: book.id,
                    chapterId: latest.chapterId,
                    revisionId: latest.revisionId
                ),
                alreadyConsumed: true
            )
        }

        guard let first = ordered.first else {
            throw AdaptationError.nothingToAdapt
        }
        let revision = try await versioning.readableRevision(bookId: book.id, chapterId: first.id)
        try await service.finishChapter(bookId: book.id, chapterId: first.id, revisionId: revision.id)
        return PreparedSource(
            chapterId: first.id,
            revisionId: revision.id,
            feedback: makeFeedback(
                bookId: book.id,
                chapterId: first.id,
                revisionId: revision.id
            ),
            alreadyConsumed: false
        )
    }
}
