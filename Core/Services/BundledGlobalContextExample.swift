import Foundation

/// A fixed local reading prompt, selected explicitly instead of the AI backend.
/// It uses the existing Plan/Apply gates, but never calls a model or a network.
struct BundledGlobalContextExample: AIService {
    static let heading = "The wider world — bundled example"
    static let prompt = "As you read this chapter, ask what connects its local story to the wider world. Which people, goods or ideas move across borders? Who gains from those connections, and who bears their costs? Look for the chapter’s own evidence before drawing a comparison. Separate outside pressures from choices made locally: a connection can help explain events without making their outcome inevitable. These are reading questions, not additional historical claims."

    private let versioning: ManuscriptVersioningService
    private let chapter: Chapter
    private let baseline: ChapterRevision
    private let supplement: [ContentBlock]
    private let planID = UUID()

    static func prepare(book: Book, after chapterID: UUID,
                        versioning: ManuscriptVersioningService) async throws -> Self {
        let seed = try BundleFixtureLoader.loadArgentinaMinimal()
        guard book.id == seed.id, !book.isCanonImport,
              let currentBook = try await versioning.loadBook(id: book.id), !currentBook.isCanonImport,
              let finished = currentBook.chapters.first(where: { $0.id == chapterID }),
              seed.chapters.contains(where: { $0.id == chapterID }) else {
            throw AdaptationError.invalidPlan("This bundled example is only for the Argentina living book.")
        }
        // Future means after the feedback chapter, not an earlier unconsumed gap.
        for chapter in currentBook.chapters.sorted(by: { $0.orderIndex < $1.orderIndex })
            where chapter.orderIndex > finished.orderIndex {
            if try await versioning.isChapterConsumed(bookId: book.id, chapterId: chapter.id) { continue }
            guard seed.chapters.contains(where: { $0.id == chapter.id }), !chapter.isOutlineStub else {
                throw AdaptationError.invalidPlan("The next future chapter needs authored prose before this example can be added.")
            }
            let baseline = try await versioning.readableRevision(bookId: book.id, chapterId: chapter.id)
            guard !baseline.blocks.contains(where: { $0.text == heading || $0.text == prompt }) else {
                throw AdaptationError.invalidPlan("The next future chapter already contains this bundled example.")
            }
            let lastOrder = baseline.blocks.map(\.orderIndex).max() ?? -1
            guard lastOrder <= Int.max - 2 else {
                throw AdaptationError.invalidPlan("This chapter cannot accept additional blocks.")
            }
            return Self(versioning: versioning, chapter: chapter, baseline: baseline, supplement: [
                ContentBlock(id: UUID(), kind: .heading, text: heading, orderIndex: lastOrder + 1),
                ContentBlock(id: UUID(), kind: .callout, text: prompt, orderIndex: lastOrder + 2)
            ])
        }
        throw AdaptationError.nothingToAdapt
    }

    func makeAdaptationPlan(_ request: AdaptationPlanRequest) async throws -> AdaptationPlan {
        try await assertBaselineUnchanged(bookID: request.book.id)
        guard request.book.id == chapter.bookId,
              !request.lockedChapterIds.contains(chapter.id),
              request.unreadChapters.contains(where: { $0.id == chapter.id && $0.plainText == plainText }) else {
            throw AdaptationError.invalidPlan("The bundled example’s target changed. Review a new example.")
        }
        let words = AdaptationPlanValidator.wordCount(of: baseline.blocks)
        return AdaptationPlan(
            id: planID, bookId: request.book.id, createdAt: Date(), sourceFeedbackId: request.feedback.id,
            preferenceUpdatesSummary: request.profile.changeLog.last?.details ?? [],
            affectedChapterIds: [chapter.id],
            chapterTargets: [AdaptationChapterTarget(
                chapterId: chapter.id, chapterTitle: chapter.title,
                currentWordCount: words,
                targetWordCount: words + AdaptationPlanValidator.wordCount(of: supplement),
                desiredChanges: ["Keep all existing text and formatting; append the fixed wider-world reading prompt shown below."],
                mustRemainConcepts: []
            )],
            continuityNotes: [Self.prompt],
            reasonsFromFeedback: [
                "Source: Bundled local example — no AI request.",
                "Your feedback and preferences are saved normally. This fixed example does not interpret your choices or free text.",
                "Only the named future chapter changes after Apply. The extra reading prompt adds words; it is not a new fact-checked history passage."
            ],
            lockedChapterIds: request.lockedChapterIds, isValidated: false
        )
    }

    func generateAdaptedChapter(_ request: AdaptationGenerateRequest) async throws -> [ContentBlock] {
        guard request.book.id == chapter.bookId, request.chapterId == chapter.id,
              request.plan.id == planID, request.plan.affectedChapterIds == [chapter.id],
              request.currentPlainText == plainText else {
            throw AdaptationError.invalidPlan("The bundled example does not match this plan. Review it again.")
        }
        // Also reject a newer revision with identical prose, before the existing
        // publication-time expectedRevisionId guard checks for changes in flight.
        try await assertBaselineUnchanged(bookID: request.book.id)
        return baseline.blocks + supplement
    }

    private var plainText: String { baseline.blocks.map(\.text).joined(separator: "\n") }

    private func assertBaselineUnchanged(bookID: UUID) async throws {
        guard bookID == chapter.bookId,
              let currentBook = try await versioning.loadBook(id: bookID), !currentBook.isCanonImport else {
            throw AdaptationError.invalidPlan("The bundled example is unavailable for this book.")
        }
        if try await versioning.isChapterConsumed(bookId: bookID, chapterId: chapter.id) {
            throw AdaptationError.lockedChapter(chapter.id)
        }
        let current = try await versioning.readableRevision(bookId: bookID, chapterId: chapter.id)
        guard current.id == baseline.id else {
            throw ManuscriptError.staleRevision(expected: baseline.id, actual: current.id)
        }
        guard current == baseline else {
            throw AdaptationError.invalidPlan("The bundled example’s baseline changed. Review it again.")
        }
    }

    func adaptChapter(chapterId: UUID, promptContext: String) async throws -> ChapterRevision {
        throw AdaptationError.invalidPlan("Bundled examples require explicit Plan and Apply.")
    }

    func ask(_ request: AskRequest) async throws -> AskResponse {
        throw AdaptationError.invalidPlan("Bundled examples do not answer questions.")
    }
}
