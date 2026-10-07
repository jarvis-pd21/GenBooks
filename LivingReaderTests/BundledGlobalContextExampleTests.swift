import XCTest
@testable import LivingReader

final class BundledGlobalContextExampleTests: XCTestCase {
    private var root: URL!
    private var versioning: ManuscriptVersioningService!
    private var feedbackStore: FileFeedbackStore!
    private var preferences: FileReaderPreferenceStore!
    private var book: Book!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LR-BundledExample-\(UUID().uuidString)", isDirectory: true)
        versioning = try ManuscriptVersioningService(rootDirectory: root)
        feedbackStore = try FileFeedbackStore(rootDirectory: root)
        preferences = try FileReaderPreferenceStore(rootDirectory: root)
        book = try BundleFixtureLoader.loadArgentinaMinimal()
        try await versioning.saveBook(book)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testPlanIsExplicitAndDoesNotMutateManuscriptBeforeApply() async throws {
        let example = try await prepare()
        let service = makeService(example)
        let feedback = makeFeedback()
        try await service.finishChapter(bookId: book.id, chapterId: feedback.chapterId,
                                        revisionId: feedback.revisionId)
        let before = try manuscriptBytes()
        let plan = try await service.submitFeedbackAndPlan(book: book, feedback: feedback)

        XCTAssertEqual(try manuscriptBytes(), before)
        XCTAssertTrue(plan.isValidated)
        XCTAssertEqual(plan.affectedChapterIds, [ArgentinaFixtureIDs.chapter2])
        XCTAssertEqual(plan.chapterTargets.count, 1)
        XCTAssertTrue(plan.lockedChapterIds.contains(ArgentinaFixtureIDs.chapter1))
        XCTAssertTrue(plan.reasonsFromFeedback.contains { $0.contains("Bundled local example") })
        XCTAssertTrue(plan.reasonsFromFeedback.contains { $0.contains("does not interpret") })
        XCTAssertTrue(plan.reasonsFromFeedback.contains { $0.contains("not a new fact-checked") })
        XCTAssertEqual(plan.continuityNotes, [BundledGlobalContextExample.prompt])
        XCTAssertEqual(try feedbackStore.loadAll(bookId: book.id), [feedback])
        XCTAssertFalse(try preferences.load(bookId: book.id).changeLog.isEmpty)
    }

    func testApplyPreservesEveryOriginalBlockAndConsumedPastAndCanRestore() async throws {
        let (service, plan) = try await reviewedPlan()
        let before = try await loadedBook()
        let baseline = try await versioning.readableRevision(bookId: book.id, chapterId: ArgentinaFixtureIDs.chapter2)
        let past = try await versioning.retrieveConsumedRevision(bookId: book.id, chapterId: ArgentinaFixtureIDs.chapter1)
        let revisions = try await service.applyPlan(book: book, plan: plan)
        let updated = try XCTUnwrap(revisions.first)
        XCTAssertEqual(revisions.count, 1)
        XCTAssertEqual(updated.chapterId, ArgentinaFixtureIDs.chapter2)
        XCTAssertNotEqual(updated.id, baseline.id)
        XCTAssertEqual(Array(updated.blocks.prefix(baseline.blocks.count)), baseline.blocks,
                       "Existing IDs, kinds, text and order must remain byte-for-byte equivalent")
        XCTAssertEqual(updated.blocks.count, baseline.blocks.count + 2)
        let added = Array(updated.blocks.suffix(2))
        XCTAssertEqual(added.map(\.kind), [.heading, .callout])
        XCTAssertEqual(added.map(\.text), [BundledGlobalContextExample.heading, BundledGlobalContextExample.prompt])
        let lastOrder = try XCTUnwrap(baseline.blocks.map(\.orderIndex).max())
        XCTAssertEqual(added.map(\.orderIndex), [lastOrder + 1, lastOrder + 2])
        XCTAssertEqual(Set(updated.blocks.map(\.id)).count, updated.blocks.count)

        let after = try await loadedBook()
        XCTAssertEqual(after.chapters.filter { $0.id != ArgentinaFixtureIDs.chapter2 },
                       before.chapters.filter { $0.id != ArgentinaFixtureIDs.chapter2 })
        let pastAfter = try await versioning.retrieveConsumedRevision(bookId: book.id, chapterId: ArgentinaFixtureIDs.chapter1)
        XCTAssertEqual(pastAfter, past)
        let history = try await versioning.listChapterVersions(bookId: book.id, chapterId: ArgentinaFixtureIDs.chapter2)
        XCTAssertEqual(history.count, 2)
        XCTAssertTrue(history.contains { $0.revisionId == baseline.id })
        XCTAssertTrue(history.contains { $0.revisionId == updated.id && $0.isActive })

        let restored = try await versioning.restoreRevision(bookId: book.id, chapterId: ArgentinaFixtureIDs.chapter2,
                                                            sourceRevisionId: baseline.id)
        XCTAssertEqual(restored.blocks.map(\.text), baseline.blocks.map(\.text))
        XCTAssertEqual(restored.blocks.map(\.kind), baseline.blocks.map(\.kind))
        XCTAssertEqual(restored.blocks.map(\.orderIndex), baseline.blocks.map(\.orderIndex))
        let afterRestore = try await loadedBook()
        let savedChapter = try XCTUnwrap(afterRestore.chapters.first { $0.id == ArgentinaFixtureIDs.chapter2 })
        XCTAssertEqual(savedChapter.revisions.count, 3)
        XCTAssertEqual(savedChapter.revision(id: baseline.id), baseline)
        XCTAssertEqual(savedChapter.revision(id: updated.id)?.blocks, updated.blocks)
        XCTAssertEqual(savedChapter.revision(id: updated.id)?.revisionIndex, updated.revisionIndex)
    }

    func testSameProseNewerRevisionAfterPreviewIsNotOverwritten() async throws {
        let (service, plan) = try await reviewedPlan()
        let baseline = try await versioning.readableRevision(bookId: book.id, chapterId: ArgentinaFixtureIDs.chapter2)
        let newer = try await versioning.createRevision(bookId: book.id, chapterId: baseline.chapterId,
            blocks: baseline.blocks, at: Date(timeIntervalSince1970: 1_800_000_000))
        let before = try manuscriptBytes()
        await assertRejected { _ = try await service.applyPlan(book: self.book, plan: plan) }
        XCTAssertEqual(try manuscriptBytes(), before)
        let readable = try await versioning.readableRevision(bookId: book.id, chapterId: baseline.chapterId)
        XCTAssertEqual(readable, newer)
    }

    func testTargetConsumedAfterPreviewIsNotChanged() async throws {
        let (service, plan) = try await reviewedPlan()
        let baseline = try await versioning.readableRevision(bookId: book.id, chapterId: ArgentinaFixtureIDs.chapter2)
        try await versioning.consume(bookId: book.id, chapterId: baseline.chapterId, revisionId: baseline.id)
        let before = try manuscriptBytes()
        await assertRejected { _ = try await service.applyPlan(book: self.book, plan: plan) }
        XCTAssertEqual(try manuscriptBytes(), before)
        let pinned = try await versioning.retrieveConsumedRevision(bookId: book.id, chapterId: baseline.chapterId)
        XCTAssertEqual(pinned?.id, baseline.id)
        XCTAssertEqual(pinned?.blocks, baseline.blocks)
    }

    func testDuplicateExampleCannotBeAddedAgain() async throws {
        let (service, plan) = try await reviewedPlan()
        _ = try await service.applyPlan(book: book, plan: plan)
        let before = try manuscriptBytes()
        await assertRejected { _ = try await self.prepare() }
        XCTAssertEqual(try manuscriptBytes(), before)
    }

    func testNonArgentinaBookIsRejectedWithoutMutation() async throws {
        var other = book!
        other.id = UUID()
        other.chapters = other.chapters.map { chapter in
            var chapter = chapter
            chapter.bookId = other.id
            return chapter
        }
        try await versioning.saveBook(other)
        let saved = try await versioning.loadBook(id: other.id)
        await assertRejected {
            _ = try await BundledGlobalContextExample.prepare(book: other, after: ArgentinaFixtureIDs.chapter1,
                                                              versioning: self.versioning)
        }
        let after = try await versioning.loadBook(id: other.id)
        XCTAssertEqual(after, saved)
    }

    func testCanonBookIsRejectedEvenWhenOnlyPersistedBookChanged() async throws {
        var canon = book!
        canon.coverAccent = "imported"
        await assertRejected {
            _ = try await BundledGlobalContextExample.prepare(book: canon, after: ArgentinaFixtureIDs.chapter1,
                                                              versioning: self.versioning)
        }
        try await versioning.saveBook(canon)
        let before = try manuscriptBytes()
        await assertRejected { _ = try await self.prepare() }
        XCTAssertEqual(try manuscriptBytes(), before)
    }

    func testNextOutlineChapterIsRejectedRatherThanSkipped() async throws {
        let index = try XCTUnwrap(book.chapters.firstIndex { $0.id == ArgentinaFixtureIDs.chapter2 })
        book.chapters[index].manuscriptStatus = .outline
        try await versioning.saveBook(book)
        let before = try manuscriptBytes()
        await assertRejected { _ = try await self.prepare() }
        XCTAssertEqual(try manuscriptBytes(), before)
    }

    func testLastChapterHasNoExampleTarget() async throws {
        let last = try XCTUnwrap(book.chapters.max { $0.orderIndex < $1.orderIndex })
        let before = try manuscriptBytes()
        await assertRejected { _ = try await self.prepare(after: last.id) }
        XCTAssertEqual(try manuscriptBytes(), before)
    }

    func testTargetsOnlyFutureChapterAndSkipsConsumedFuture() async throws {
        let ordered = book.chapters.sorted { $0.orderIndex < $1.orderIndex }
        let consumed = ordered[2]
        let revision = try XCTUnwrap(consumed.activeRevision)
        try await versioning.consume(bookId: book.id, chapterId: consumed.id, revisionId: revision.id)
        // Chapter 1 remains unconsumed, but must not be selected after Chapter 2 feedback.
        let example = try await prepare(after: ordered[1].id)
        let service = makeService(example)
        let feedback = makeFeedback(chapter: ordered[1])
        try await service.finishChapter(bookId: book.id, chapterId: feedback.chapterId, revisionId: feedback.revisionId)
        let plan = try await service.submitFeedbackAndPlan(book: book, feedback: feedback)
        XCTAssertEqual(plan.affectedChapterIds, [ordered[3].id])
        XCTAssertEqual(plan.chapterTargets.count, 1)
        XCTAssertFalse(plan.affectedChapterIds.contains(ordered[0].id))
        XCTAssertFalse(plan.affectedChapterIds.contains(consumed.id))
    }

    func testGenerationRejectsAPlanFromAnotherExampleInstance() async throws {
        let first = try await prepare()
        let second = try await prepare()
        let service = makeService(first)
        let feedback = makeFeedback()
        try await service.finishChapter(bookId: book.id, chapterId: feedback.chapterId, revisionId: feedback.revisionId)
        let plan = try await service.submitFeedbackAndPlan(book: book, feedback: feedback)
        let target = try XCTUnwrap(plan.chapterTargets.first)
        let revision = try await versioning.readableRevision(bookId: book.id, chapterId: target.chapterId)
        let request = AdaptationGenerateRequest(book: book, plan: plan, chapterId: target.chapterId,
            chapterTitle: target.chapterTitle, currentPlainText: revision.blocks.map(\.text).joined(separator: "\n"),
            target: target, profile: try preferences.load(bookId: book.id), continuityNotes: plan.continuityNotes)
        let before = try manuscriptBytes()
        await assertRejected { _ = try await second.generateAdaptedChapter(request) }
        XCTAssertEqual(try manuscriptBytes(), before)
    }

    @MainActor
    func testCancellingBundledPlanInvalidatesItWithoutFallingBackToAI() async throws {
        let defaultsName = "LR-BundledCancel-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let checkpoints = try FileReadingCheckpointStore(rootDirectory: root)
        let chapter = try XCTUnwrap(book.chapters.first { $0.id == ArgentinaFixtureIDs.chapter1 })
        let block = try XCTUnwrap(chapter.activeRevision?.blocks.first)
        try checkpoints.saveCheckpoint(ReadingCheckpoint(id: UUID(), bookId: book.id, chapterId: chapter.id,
                                                         blockId: block.id, characterOffset: 0, updatedAt: Date()))
        let originalAI = MockAIService()
        let reader = ReaderViewModel(book: book, versioning: versioning, checkpoints: checkpoints,
            settings: ReaderSettingsStore(defaults: defaults), annotations: try FileAnnotationStore(rootDirectory: root),
            vocabulary: try FileVocabularyStore(rootDirectory: root), bookmarks: try FileBookmarkStore(rootDirectory: root),
            feedbackStore: feedbackStore, preferenceStore: preferences, ai: originalAI, adaptationAI: originalAI)
        await reader.open()
        reader.beginFinishChapter()
        await reader.submitFeedbackAndBuildPlan(useBundledExample: true)
        XCTAssertEqual(reader.adaptationState, .planReady)
        XCTAssertNotNil(reader.adaptationPlan)
        let before = try manuscriptBytes()
        let targetBefore = try await versioning.readableRevision(bookId: book.id, chapterId: ArgentinaFixtureIDs.chapter2)

        await reader.cancelAdaptation()
        XCTAssertNil(reader.adaptationPlan, "Cancellation must invalidate the bundled plan, not just forget its provider")
        await reader.applyAdaptationPlan()

        XCTAssertEqual(originalAI.totalCallCount, 0, "A cancelled bundled plan must never fall through to the original AI")
        XCTAssertEqual(reader.adaptationState, .cancelled)
        XCTAssertNil(reader.adaptationPlan)
        XCTAssertEqual(try manuscriptBytes(), before)
        let targetAfter = try await versioning.readableRevision(bookId: book.id, chapterId: ArgentinaFixtureIDs.chapter2)
        XCTAssertEqual(targetAfter, targetBefore)
    }

    @MainActor
    func testReaderRoutesBundledPlanAndApplyWithoutCallingInjectedAI() async throws {
        let defaultsName = "LR-BundledExample-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let checkpoints = try FileReadingCheckpointStore(rootDirectory: root)
        let chapter = try XCTUnwrap(book.chapters.first { $0.id == ArgentinaFixtureIDs.chapter1 })
        let block = try XCTUnwrap(chapter.activeRevision?.blocks.first)
        try checkpoints.saveCheckpoint(ReadingCheckpoint(id: UUID(), bookId: book.id, chapterId: chapter.id,
                                                         blockId: block.id, characterOffset: 0, updatedAt: Date()))
        let originalAI = MockAIService()
        let reader = ReaderViewModel(book: book, versioning: versioning, checkpoints: checkpoints,
            settings: ReaderSettingsStore(defaults: defaults), annotations: try FileAnnotationStore(rootDirectory: root),
            vocabulary: try FileVocabularyStore(rootDirectory: root), bookmarks: try FileBookmarkStore(rootDirectory: root),
            feedbackStore: feedbackStore, preferenceStore: preferences, ai: originalAI, adaptationAI: originalAI)
        await reader.open()
        XCTAssertTrue(reader.isReady)
        reader.beginFinishChapter()
        await reader.submitFeedbackAndBuildPlan(useBundledExample: true)
        XCTAssertNil(reader.adaptationError)
        XCTAssertEqual(reader.adaptationState, .planReady)
        XCTAssertEqual(originalAI.totalCallCount, 0)
        let reviewed = try XCTUnwrap(reader.adaptationPlan)
        let baseline = try await versioning.readableRevision(bookId: book.id, chapterId: ArgentinaFixtureIDs.chapter2)
        XCTAssertTrue(reader.isBundledAdaptationPlan)
        XCTAssertEqual(reader.applyLengthPreset, .full)
        XCTAssertEqual(reviewed.resolvedLengthPreset, .full)
        let expectedWords = AdaptationPlanValidator.wordCount(of: baseline.blocks)
            + AdaptationPlanValidator.wordCount(of: BundledGlobalContextExample.heading)
            + AdaptationPlanValidator.wordCount(of: BundledGlobalContextExample.prompt)
        XCTAssertEqual(reviewed.chapterTargets.first?.targetWordCount, expectedWords)
        reader.applyLengthPreset = .half
        reader.adaptationLengthChanged()
        XCTAssertEqual(reader.applyLengthPreset, .full)
        XCTAssertEqual(reader.adaptationPlan, reviewed,
                       "The fixed bundled example cannot silently become a half-length plan")
        await reader.applyAdaptationPlan()
        XCTAssertNil(reader.adaptationError)
        XCTAssertEqual(reader.adaptationState, .applied)
        XCTAssertEqual(originalAI.totalCallCount, 0)
        let revision = try await versioning.readableRevision(bookId: book.id, chapterId: ArgentinaFixtureIDs.chapter2)
        XCTAssertEqual(Array(revision.blocks.prefix(baseline.blocks.count)), baseline.blocks)
        XCTAssertEqual(revision.blocks.last?.text, BundledGlobalContextExample.prompt)
    }

    private func prepare(after chapterID: UUID = ArgentinaFixtureIDs.chapter1) async throws -> BundledGlobalContextExample {
        try await BundledGlobalContextExample.prepare(book: book, after: chapterID, versioning: versioning)
    }

    private func makeService(_ example: BundledGlobalContextExample) -> LivingBookAdaptationService {
        LivingBookAdaptationService(versioning: versioning, feedbackStore: feedbackStore,
                                   preferenceStore: preferences, ai: example)
    }

    private func makeFeedback(chapter: Chapter? = nil) -> ChapterFeedback {
        let chapter = chapter ?? book.chapters.first { $0.id == ArgentinaFixtureIDs.chapter1 }!
        return ChapterFeedback(id: UUID(), bookId: book.id, chapterId: chapter.id, revisionId: chapter.activeRevision!.id,
            overall: .fine, moreOf: [.globalContext, .stories], lessOf: [.repetition],
            freeText: "This feedback is saved, not interpreted by the fixed example.",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    private func reviewedPlan() async throws -> (LivingBookAdaptationService, AdaptationPlan) {
        let example = try await prepare()
        let service = makeService(example)
        let feedback = makeFeedback()
        try await service.finishChapter(bookId: book.id, chapterId: feedback.chapterId, revisionId: feedback.revisionId)
        return (service, try await service.submitFeedbackAndPlan(book: book, feedback: feedback))
    }

    private func loadedBook() async throws -> Book {
        let loaded = try await versioning.loadBook(id: book.id)
        return try XCTUnwrap(loaded)
    }

    private func manuscriptBytes() throws -> Data {
        try Data(contentsOf: root.appendingPathComponent("Manuscripts/\(book.id.uuidString).json"))
    }

    private func assertRejected(file: StaticString = #filePath, line: UInt = #line,
                                _ operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected bundled example request to be rejected", file: file, line: line)
        } catch { }
    }
}
