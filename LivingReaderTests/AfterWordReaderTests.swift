import XCTest
@testable import LivingReader

@MainActor
final class AfterWordReaderTests: XCTestCase {
    private var root: URL!
    private var versioning: ManuscriptVersioningService!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LR-AfterWordReader-\(UUID().uuidString)", isDirectory: true)
        versioning = try ManuscriptVersioningService(rootDirectory: root)
        defaultsSuite = "LivingReaderAfterWord.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defaults.removePersistentDomain(forName: defaultsSuite)
    }

    override func tearDownWithError() throws {
        if let defaultsSuite { defaults?.removePersistentDomain(forName: defaultsSuite) }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testQuoteSelectionMapsInteriorWordBackToStoredStartWithoutAdvancingOffset() async throws {
        let quote = block("Geography is destiny only until people rewrite the map.", kind: .quote)
        let book = makeBook(chapterBlocks: [[quote]])
        try await versioning.saveBook(book)
        let model = try makeReader(book)
        await model.open()
        XCTAssertTrue(model.isReady)
        let document = try XCTUnwrap(model.document)
        let hit = try XCTUnwrap(document.search(query: "destiny").first)
        let selection = try XCTUnwrap(ReaderSelectionMapper.selection(
            in: document,
            documentRange: NSRange(location: hit.range.location + 2, length: 1)
        ))
        model.activeSelection = selection
        model.beginRegenerateFromWord()

        let anchor = try XCTUnwrap(model.wordAnchor)
        XCTAssertEqual(anchor.word, "destiny")
        XCTAssertEqual(anchor.blockId, quote.id)
        XCTAssertEqual(anchor.boundary, .afterWord)
        XCTAssertEqual(anchor.utf16OffsetInBlock, (quote.text as NSString).range(of: "destiny").location,
                       "Keep a stored-text word locator, not the rendered quote offset or a word-end offset")
        let split = try ChapterAnchorSplitter.split(blocks: [quote], blockId: anchor.blockId,
                                                   utf16OffsetInBlock: anchor.utf16OffsetInBlock,
                                                   boundary: anchor.effectiveBoundary)
        XCTAssertEqual(split.frozenPrefix.first?.text, "Geography is destiny ",
                       "Freeze the selected stored word without copying renderer-added quote marks")
        XCTAssertEqual(split.regenerableSuffix.first?.text, "only until people rewrite the map.")
        XCTAssertEqual(try model.effectiveWordAnchorForRegeneration(), anchor)
        XCTAssertTrue(model.showRegenerateFromWord)
    }

    func testFirstWordInQuoteIsAnAfterWordSelectionNotAChapterStart() async throws {
        let quote = block("Geography is destiny only until people rewrite the map.", kind: .quote)
        let book = makeBook(chapterBlocks: [[quote]])
        try await versioning.saveBook(book)
        let model = try makeReader(book)
        await model.open()
        let document = try XCTUnwrap(model.document)
        let hit = try XCTUnwrap(document.search(query: "Geography").first)
        XCTAssertEqual(hit.range.location, 1, "The renderer adds an opening quote before stored text")
        model.activeSelection = try XCTUnwrap(ReaderSelectionMapper.selection(in: document, documentRange: hit.range))
        model.beginRegenerateFromWord()

        let anchor = try XCTUnwrap(model.wordAnchor)
        XCTAssertEqual(anchor.word, "Geography")
        XCTAssertEqual(anchor.utf16OffsetInBlock, 0)
        XCTAssertEqual(anchor.boundary, .afterWord,
                       "Offset zero still means preserve the first selected word, not rewrite the whole chapter")
        let split = try ChapterAnchorSplitter.split(blocks: [quote], blockId: anchor.blockId,
                                                   utf16OffsetInBlock: anchor.utf16OffsetInBlock,
                                                   boundary: anchor.effectiveBoundary)
        XCTAssertEqual(split.frozenPrefix.first?.text, "Geography ")
        XCTAssertEqual(split.prefixWordCount, 1)
        XCTAssertFalse(model.wordRegenChapterLocked)
        XCTAssertEqual(try model.effectiveWordAnchorForRegeneration(), anchor)
    }

    func testMultiwordSelectionKeepsNearestStartWordAsTheInclusiveBoundary() async throws {
        let paragraph = block("Across the pampas settlements grew around old routes.")
        let book = makeBook(chapterBlocks: [[paragraph]])
        try await versioning.saveBook(book)
        let model = try makeReader(book)
        await model.open()
        let document = try XCTUnwrap(model.document)
        let hit = try XCTUnwrap(document.search(query: "pampas settlements grew").first)
        model.activeSelection = try XCTUnwrap(ReaderSelectionMapper.selection(in: document, documentRange: hit.range))
        model.beginRegenerateFromWord()

        let anchor = try XCTUnwrap(model.wordAnchor)
        XCTAssertEqual(anchor.word, "pampas")
        XCTAssertEqual(anchor.utf16OffsetInBlock, (paragraph.text as NSString).range(of: "pampas").location)
        XCTAssertEqual(anchor.boundary, .afterWord)
    }

    func testFinishedSelectionRedirectsBeforeFirstOrderedBlockIncludingLeadingImage() async throws {
        let finishedText = block("Finished history remains exactly as read.")
        let leadingImage = block("[Image] A map before the chapter begins.", kind: .imagePlaceholder, order: 0)
        let unreadText = block("Future words remain available for a complete rewrite.", order: 1)
        // Storage array order is intentionally different from manuscript order.
        let book = makeBook(chapterBlocks: [[finishedText], [unreadText, leadingImage]])
        try await versioning.saveBook(book)
        let firstChapter = book.chapters[0]
        let finishedRevision = try XCTUnwrap(firstChapter.activeRevision)
        try await versioning.consume(bookId: book.id, chapterId: firstChapter.id, revisionId: finishedRevision.id)
        let model = try makeReader(book)
        await model.open()
        let document = try XCTUnwrap(model.document)
        let hit = try XCTUnwrap(document.search(query: "history").first)
        model.activeSelection = try XCTUnwrap(ReaderSelectionMapper.selection(in: document, documentRange: hit.range))
        model.beginRegenerateFromWord()

        let selected = try XCTUnwrap(model.wordAnchor)
        let effective = try model.effectiveWordAnchorForRegeneration()
        XCTAssertTrue(model.wordRegenChapterLocked)
        XCTAssertEqual(selected.chapterId, firstChapter.id, "The sheet retains the selected finished chapter")
        XCTAssertEqual(selected.boundary, .afterWord)
        XCTAssertEqual(effective.chapterId, book.chapters[1].id)
        XCTAssertEqual(effective.blockId, leadingImage.id, "Do not silently freeze a leading image or first unread word")
        XCTAssertEqual(effective.utf16OffsetInBlock, 0)
        XCTAssertEqual(effective.boundary, .chapterStart)
        XCTAssertTrue(effective.word.isEmpty, "A synthetic chapter-start boundary is not a selected word")
        let unreadRevision = try XCTUnwrap(book.chapters[1].activeRevision)
        let split = try ChapterAnchorSplitter.split(blocks: unreadRevision.blocks, blockId: effective.blockId,
                                                   utf16OffsetInBlock: effective.utf16OffsetInBlock,
                                                   boundary: effective.effectiveBoundary)
        XCTAssertTrue(split.frozenPrefix.isEmpty)
        XCTAssertEqual(split.regenerableSuffix.map(\.id), [leadingImage.id, unreadText.id])
        XCTAssertTrue(model.canPreviewWordRegen)
        XCTAssertTrue(model.canApplyWordRegen)
        let pinned = try await versioning.retrieveConsumedRevision(bookId: book.id, chapterId: firstChapter.id)
        XCTAssertEqual(pinned?.id, finishedRevision.id)
        XCTAssertEqual(pinned?.blocks, finishedRevision.blocks)
    }

    private func makeReader(_ book: Book) throws -> ReaderViewModel {
        ReaderViewModel(
            book: book,
            versioning: versioning,
            checkpoints: try FileReadingCheckpointStore(rootDirectory: root),
            settings: ReaderSettingsStore(defaults: defaults),
            annotations: try FileAnnotationStore(rootDirectory: root),
            vocabulary: try FileVocabularyStore(rootDirectory: root),
            bookmarks: try FileBookmarkStore(rootDirectory: root),
            feedbackStore: try FileFeedbackStore(rootDirectory: root),
            preferenceStore: try FileReaderPreferenceStore(rootDirectory: root)
        )
    }

    private func block(_ text: String, kind: ContentBlockKind = .paragraph, order: Int = 0) -> ContentBlock {
        ContentBlock(id: UUID(), kind: kind, text: text, orderIndex: order)
    }

    private func makeBook(chapterBlocks: [[ContentBlock]]) -> Book {
        let bookId = UUID()
        let chapters = chapterBlocks.enumerated().map { index, blocks in
            let chapterId = UUID()
            let revision = ChapterRevision(id: UUID(), chapterId: chapterId, revisionIndex: 1,
                                           createdAt: Date(), blocks: blocks, isConsumed: false)
            return Chapter(id: chapterId, bookId: bookId, title: "Chapter \(index + 1)",
                           orderIndex: index, activeRevisionId: revision.id, revisions: [revision])
        }
        return Book(id: bookId, title: "After-word test book", author: "Test", chapters: chapters)
    }
}
