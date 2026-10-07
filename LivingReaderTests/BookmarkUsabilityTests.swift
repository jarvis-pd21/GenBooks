import XCTest
@testable import LivingReader

@MainActor
final class BookmarkUsabilityTests: XCTestCase {
    private var directory: URL!
    private var files: FileBookmarkStore!
    private var store: BookmarkFailureStore!
    private var item: NamedBookmark!
    private var model: BookmarkListModel!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookmarkUsability-\(UUID().uuidString)", isDirectory: true)
        files = try FileBookmarkStore(rootDirectory: directory)
        store = BookmarkFailureStore(files)
        item = NamedBookmark(id: UUID(), bookId: UUID(), chapterId: UUID(), chapterTitle: "The pampas",
                             revisionId: UUID(), blockId: UUID(), utf16Offset: 11,
                             title: "Landscape", snippet: "Grasslands and rivers", createdAt: Date(), updatedAt: Date())
        try files.saveBookmark(item)
        model = BookmarkListModel(store: store, bookId: item.bookId)
        model.reload()
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testSearchDistinguishesNoResultsAndClearsBackToSavedBookmarks() {
        model.query = "not-a-bookmark"
        XCTAssertTrue(model.hasQuery)
        XCTAssertTrue(model.filtered.isEmpty)
        XCTAssertEqual(model.items.count, 1)
        model.query = ""
        XCTAssertFalse(model.hasQuery)
        XCTAssertEqual(model.filtered.map(\.id), [item.id])
        model.query = "  RIVERS  "
        XCTAssertEqual(model.filtered.map(\.id), [item.id])
        model.query = "PAMPAS"
        XCTAssertEqual(model.filtered.map(\.id), [item.id])
    }

    func testBlankRenameCannotSaveAndCancelLeavesStoredTitleUntouched() throws {
        model.beginRename(item)
        XCTAssertFalse(model.hasRenameChanges)
        model.renameDraft = " \n "
        XCTAssertFalse(model.canSaveRename)
        XCTAssertFalse(model.saveRename())
        XCTAssertNotNil(model.renameTarget)
        XCTAssertTrue(model.hasRenameChanges)
        model.cancelRename()
        XCTAssertNil(model.renameTarget)
        XCTAssertEqual(try files.loadBookmarks(bookId: item.bookId).first?.title, "Landscape")
    }

    func testFailedRenameKeepsDraftAndTargetThenRetryPersistsAcrossReopen() throws {
        model.beginRename(item)
        model.renameDraft = "River crossing"
        store.failWrites = true
        XCTAssertFalse(model.saveRename())
        XCTAssertEqual(model.renameTarget?.id, item.id)
        XCTAssertEqual(model.renameDraft, "River crossing")
        XCTAssertTrue(model.errorMessage?.contains("Couldn’t rename") == true)
        XCTAssertEqual(try files.loadBookmarks(bookId: item.bookId).first?.title, "Landscape")
        store.failWrites = false
        XCTAssertTrue(model.saveRename())
        XCTAssertNil(model.renameTarget)
        XCTAssertNil(model.errorMessage)
        let reopened = try FileBookmarkStore(rootDirectory: directory)
        let saved = try XCTUnwrap(reopened.loadBookmarks(bookId: item.bookId).first)
        XCTAssertEqual(saved.title, "River crossing")
        XCTAssertEqual(saved.blockId, item.blockId)
        XCTAssertEqual(saved.utf16Offset, item.utf16Offset)
    }

    func testDeleteNeedsConfirmationAndCancellationPreservesBookmark() throws {
        model.deleteTarget = item
        XCTAssertEqual(try files.loadBookmarks(bookId: item.bookId).count, 1)
        model.deleteTarget = nil
        XCTAssertFalse(model.confirmDelete())
        XCTAssertEqual(try files.loadBookmarks(bookId: item.bookId).count, 1)
    }

    func testDeleteFailureIsVisibleAndRetryRemovesOnlySelectedBookmark() throws {
        var other = item!
        other.id = UUID()
        other.title = "Second saved place"
        try files.saveBookmark(other)
        model.reload()
        store.failWrites = true
        model.deleteTarget = item
        XCTAssertFalse(model.confirmDelete())
        XCTAssertEqual(model.items.count, 2)
        XCTAssertTrue(model.errorMessage?.contains("Couldn’t delete") == true)
        store.failWrites = false
        model.deleteTarget = item
        XCTAssertTrue(model.confirmDelete())
        let reopened = try FileBookmarkStore(rootDirectory: directory)
        XCTAssertEqual(try reopened.loadBookmarks(bookId: item.bookId).map(\.id), [other.id])
    }

    func testLoadFailureRemainsVisibleUntilSuccessfulReload() {
        store.failReads = true
        model.reload()
        XCTAssertTrue(model.errorMessage?.contains("Couldn’t load") == true)
        store.failReads = false
        model.reload()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.items.map(\.id), [item.id])
    }
}

private final class BookmarkFailureStore: BookmarkStoring, @unchecked Sendable {
    let underlying: FileBookmarkStore
    var failReads = false
    var failWrites = false
    init(_ underlying: FileBookmarkStore) { self.underlying = underlying }
    private func check(_ shouldFail: Bool) throws {
        if shouldFail { throw CocoaError(.fileWriteOutOfSpace) }
    }
    func loadBookmarks(bookId: UUID) throws -> [NamedBookmark] {
        try check(failReads)
        return try underlying.loadBookmarks(bookId: bookId)
    }
    func loadAllBookmarks() throws -> [NamedBookmark] {
        try check(failReads)
        return try underlying.loadAllBookmarks()
    }
    func saveBookmark(_ bookmark: NamedBookmark) throws {
        try check(failWrites)
        try underlying.saveBookmark(bookmark)
    }
    func deleteBookmark(id: UUID, bookId: UUID) throws {
        try check(failWrites)
        try underlying.deleteBookmark(id: id, bookId: bookId)
    }
    func renameBookmark(id: UUID, bookId: UUID, title: String) throws {
        try check(failWrites)
        try underlying.renameBookmark(id: id, bookId: bookId, title: title)
    }
}

final class VersionHistoryUsabilityTests: XCTestCase {
    func testSameNamedChaptersKeepSeparateRevisionGroups() {
        let firstID = UUID(), secondID = UUID()
        let entries = [entry(firstID, 1), entry(secondID, 3), entry(firstID, 2), entry(secondID, 1)]
        let groups = ChapterVersionGroup.groups(entries)
        XCTAssertEqual(groups.map(\.id), [firstID, secondID])
        XCTAssertEqual(groups.map(\.chapterTitle), ["Introduction", "Introduction"])
        XCTAssertEqual(groups[0].rows.map(\.revisionIndex), [2, 1])
        XCTAssertEqual(groups[1].rows.map(\.revisionIndex), [3, 1])
        XCTAssertTrue(groups[0].rows.allSatisfy { $0.chapterId == firstID })
        XCTAssertTrue(groups[1].rows.allSatisfy { $0.chapterId == secondID })
    }

    func testEmptyHistoryHasNoPhantomChapterGroup() {
        XCTAssertTrue(ChapterVersionGroup.groups([]).isEmpty)
    }

    private func entry(_ chapter: UUID, _ index: Int) -> ChapterVersionEntry {
        ChapterVersionEntry(chapterId: chapter, chapterTitle: "Introduction", revisionId: UUID(),
                            revisionIndex: index, createdAt: Date(), isActive: index == 3,
                            isConsumedLocked: false, proseWordCount: 20, visualBlockCount: 0,
                            previewSnippet: "Sample revision")
    }
}
