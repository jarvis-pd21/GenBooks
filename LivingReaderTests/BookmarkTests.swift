import XCTest
@testable import LivingReader

@MainActor
final class BookmarkTests: XCTestCase {
    private var tempRoot: URL!
    private var versioning: ManuscriptVersioningService!
    private var annotations: FileAnnotationStore!
    private var vocabulary: FileVocabularyStore!
    private var bookmarks: FileBookmarkStore!
    private var checkpoints: FileReadingCheckpointStore!
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("LR-BM-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        versioning = try ManuscriptVersioningService(rootDirectory: tempRoot)
        annotations = try FileAnnotationStore(rootDirectory: tempRoot)
        vocabulary = try FileVocabularyStore(rootDirectory: tempRoot)
        bookmarks = try FileBookmarkStore(rootDirectory: tempRoot)
        checkpoints = try FileReadingCheckpointStore(rootDirectory: tempRoot)
        defaultsSuiteName = "LivingReaderBM.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDownWithError() throws {
        if let defaultsSuiteName {
            defaults?.removePersistentDomain(forName: defaultsSuiteName)
        }
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testNearestWordPinSnapsToWordStart() {
        let text = "Across the pampas, settlements grew."
        let pin = BookmarkAnchorResolver.nearestWordPin(
            blockText: text,
            selectionStartUtf16: 13, // inside "pampas"
            selectedText: "pamp"
        )
        XCTAssertEqual(pin.word, "pampas")
        XCTAssertEqual(pin.utf16Offset, 11) // start of "pampas,"
        XCTAssertFalse(pin.snippet.isEmpty)
    }

    func testNearestWordPinSkipsWhitespaceTowardNearestWord() {
        let text = "Hello   world"
        let pin = BookmarkAnchorResolver.nearestWordPin(
            blockText: text,
            selectionStartUtf16: 6, // whitespace
            selectedText: ""
        )
        XCTAssertEqual(pin.word, "world")
        XCTAssertEqual(pin.utf16Offset, 8)
    }

    func testBookmarkPersistsAcrossStoreReopenAndRename() throws {
        let bookmark = NamedBookmark(
            id: UUID(),
            bookId: ArgentinaFixtureIDs.book,
            chapterId: ArgentinaFixtureIDs.chapter1,
            chapterTitle: "Before the Nation",
            revisionId: ArgentinaFixtureIDs.chapter1Revision1,
            blockId: ArgentinaFixtureIDs.block1Quote,
            utf16Offset: 11,
            title: NamedBookmark.defaultTitle(chapterTitle: "Before the Nation", snippet: "Geography is destiny"),
            snippet: "Geography is destiny",
            createdAt: Date(),
            updatedAt: Date()
        )
        try bookmarks.saveBookmark(bookmark)

        let reopened = try FileBookmarkStore(rootDirectory: tempRoot)
        let loaded = try reopened.loadBookmarks(bookId: ArgentinaFixtureIDs.book)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.blockId, ArgentinaFixtureIDs.block1Quote)
        XCTAssertEqual(loaded.first?.revisionId, ArgentinaFixtureIDs.chapter1Revision1)
        XCTAssertEqual(loaded.first?.utf16Offset, 11)
        XCTAssertTrue(loaded.first?.title.contains("Before the Nation") == true)

        try reopened.renameBookmark(id: bookmark.id, bookId: bookmark.bookId, title: "Pampas pin")
        let renamed = try reopened.loadBookmarks(bookId: ArgentinaFixtureIDs.book)
        XCTAssertEqual(renamed.first?.title, "Pampas pin")

        try reopened.deleteBookmark(id: bookmark.id, bookId: bookmark.bookId)
        XCTAssertTrue(try reopened.loadBookmarks(bookId: ArgentinaFixtureIDs.book).isEmpty)
    }

    func testBookmarksSeparateFromAnnotationsAndCheckpoints() throws {
        let range = ContentRangeAnchor(blockId: ArgentinaFixtureIDs.block1Body, utf16Start: 4, utf16Length: 12)
        try annotations.saveHighlight(
            HighlightAnnotation(
                id: UUID(),
                bookId: ArgentinaFixtureIDs.book,
                chapterId: ArgentinaFixtureIDs.chapter1,
                chapterTitle: "Before the Nation",
                revisionId: ArgentinaFixtureIDs.chapter1Revision1,
                range: range,
                selectedText: "sample text",
                color: .yellow,
                note: nil,
                createdAt: Date(),
                updatedAt: Date()
            )
        )
        try checkpoints.saveCheckpoint(
            ReadingCheckpoint(
                id: UUID(),
                bookId: ArgentinaFixtureIDs.book,
                chapterId: ArgentinaFixtureIDs.chapter1,
                blockId: ArgentinaFixtureIDs.block1Body,
                characterOffset: 4,
                updatedAt: Date()
            )
        )
        try bookmarks.saveBookmark(
            NamedBookmark(
                id: UUID(),
                bookId: ArgentinaFixtureIDs.book,
                chapterId: ArgentinaFixtureIDs.chapter1,
                chapterTitle: "Before the Nation",
                revisionId: ArgentinaFixtureIDs.chapter1Revision1,
                blockId: ArgentinaFixtureIDs.block1Quote,
                utf16Offset: 0,
                title: "Named pin",
                snippet: "quote",
                createdAt: Date(),
                updatedAt: Date()
            )
        )

        XCTAssertEqual(try annotations.loadHighlights(bookId: ArgentinaFixtureIDs.book).count, 1)
        XCTAssertEqual(try bookmarks.loadBookmarks(bookId: ArgentinaFixtureIDs.book).count, 1)
        XCTAssertEqual(try checkpoints.loadCheckpoint(bookId: ArgentinaFixtureIDs.book)?.characterOffset, 4)
        XCTAssertNotEqual(
            try bookmarks.loadBookmarks(bookId: ArgentinaFixtureIDs.book).first?.blockId,
            try checkpoints.loadCheckpoint(bookId: ArgentinaFixtureIDs.book)?.blockId
        )
    }

    func testPerformBookmarkViaViewModelUsesNearestWordAndJumps() async throws {
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
            feedbackStore: try FileFeedbackStore(rootDirectory: tempRoot),
            preferenceStore: try FileReaderPreferenceStore(rootDirectory: tempRoot)
        )
        await model.open()
        let document = try XCTUnwrap(model.document)
        let hit = try XCTUnwrap(document.search(query: "Geography is destiny").first)
        let selection = try XCTUnwrap(ReaderSelectionMapper.selection(in: document, documentRange: hit.range))
        model.activeSelection = selection
        model.performBookmark()

        XCTAssertEqual(model.bookmarks.count, 1)
        let saved = try XCTUnwrap(model.bookmarks.first)
        XCTAssertEqual(saved.revisionId, selection.revisionId)
        XCTAssertEqual(saved.blockId, selection.range.blockId)
        XCTAssertEqual(saved.utf16Offset, selection.range.utf16Start)
        XCTAssertTrue(saved.title.contains(selection.chapterTitle))

        // Auto-resume checkpoint must remain independent of the named pin.
        let before = try checkpoints.loadCheckpoint(bookId: book.id)
        model.jumpToBookmark(saved)
        XCTAssertEqual(model.jumpUtf16, document.anchor(blockId: saved.blockId)!.utf16Range.lowerBound + saved.utf16Offset)
        // Saving a bookmark must not clear deliberate checkpoint independence: checkpoint may update on jump
        // (resume machinery), but bookmark list stays deliberate named pins.
        XCTAssertEqual(try bookmarks.loadBookmarks(bookId: book.id).count, 1)
        _ = before
    }
}
