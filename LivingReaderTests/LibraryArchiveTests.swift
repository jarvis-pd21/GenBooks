import XCTest
@testable import LivingReader

@MainActor
final class LibraryArchiveTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryArchiveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testPreferenceRoundTripPreservesOtherArchivedIdentities() throws {
        let store = LibraryVisibilityStore(rootDirectory: directory)
        let first = UUID(), second = UUID()
        XCTAssertTrue(try store.loadArchivedIDs().isEmpty)
        XCTAssertEqual(try store.setArchived(true, bookID: first), [first])
        XCTAssertEqual(try store.setArchived(true, bookID: second), [first, second])
        let reopened = LibraryVisibilityStore(rootDirectory: directory)
        XCTAssertEqual(try reopened.loadArchivedIDs(), [first, second])
        XCTAssertEqual(try reopened.setArchived(false, bookID: first), [second])
    }

    func testMalformedPreferencesAreNeverReplacedByAnAction() throws {
        let store = LibraryVisibilityStore(rootDirectory: directory)
        let original = Data("not valid archive preferences".utf8)
        try original.write(to: store.fileURL)
        XCTAssertThrowsError(try store.loadArchivedIDs())
        XCTAssertThrowsError(try store.setArchived(true, bookID: UUID()))
        XCTAssertThrowsError(try store.setArchived(false, bookID: UUID()))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
    }

    func testArchivedBundledBookStaysHiddenAfterReloadAndRelaunch() async throws {
        let model = await loadedModel()
        let id = ArgentinaFixtureIDs.book
        XCTAssertTrue(model.visibleBooks.contains { $0.id == id })
        let allIDs = Set(model.books.map(\.id))
        model.archiveBook(id: id)
        XCTAssertFalse(model.visibleBooks.contains { $0.id == id })
        XCTAssertTrue(model.archivedBooks.contains { $0.id == id })
        XCTAssertEqual(Set(model.books.map(\.id)), allIDs, "Notebook retains the full catalog")
        await model.reloadBooks()
        XCTAssertFalse(model.visibleBooks.contains { $0.id == id })
        let reopened = await loadedModel()
        XCTAssertFalse(reopened.visibleBooks.contains { $0.id == id }, "Fixture seeding must not unarchive it")
        XCTAssertTrue(reopened.archivedBooks.contains { $0.id == id })
        reopened.restoreBook(id: id)
        XCTAssertTrue(reopened.visibleBooks.contains { $0.id == id })
        XCTAssertFalse(reopened.archivedBooks.contains { $0.id == id })
    }

    func testArchiveAndRestoreOnlyWriteVisibilityPreferences() async throws {
        let model = await loadedModel()
        let id = ArgentinaFixtureIDs.book
        let before = try fileSnapshot()
        model.archiveBook(id: id)
        XCTAssertEqual(try fileSnapshot(), before,
                       "Manuscripts, notes, checkpoints, history and audio bytes must remain untouched")
        model.restoreBook(id: id)
        XCTAssertEqual(try fileSnapshot(), before)
        XCTAssertEqual(model.aiAdaptCallCount, 0)
    }

    func testArchiveFailureLeavesVisibleBookAndCanRetryAfterRepair() async throws {
        let model = await loadedModel()
        let id = ArgentinaFixtureIDs.book
        let store = LibraryVisibilityStore(rootDirectory: directory)
        let broken = Data("corrupt preferences".utf8)
        try broken.write(to: store.fileURL)
        model.archiveBook(id: id)
        XCTAssertTrue(model.visibleBooks.contains { $0.id == id })
        XCTAssertFalse(model.archivedBooks.contains { $0.id == id })
        XCTAssertNotNil(model.archiveError)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), broken)
        try Data("[]".utf8).write(to: store.fileURL)
        model.archiveBook(id: id)
        XCTAssertTrue(model.archivedBooks.contains { $0.id == id })
        XCTAssertNil(model.archiveError)
    }

    func testRestoreFailureKeepsArchivedEntryAndCanRetryAfterRepair() async throws {
        let model = await loadedModel()
        let id = ArgentinaFixtureIDs.book
        let store = LibraryVisibilityStore(rootDirectory: directory)
        model.archiveBook(id: id)
        let original = try Data(contentsOf: store.fileURL)
        let broken = Data("corrupt preferences".utf8)
        try broken.write(to: store.fileURL)
        model.restoreBook(id: id)
        XCTAssertTrue(model.archivedBooks.contains { $0.id == id })
        XCTAssertFalse(model.visibleBooks.contains { $0.id == id })
        XCTAssertNotNil(model.archiveError)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), broken)
        try original.write(to: store.fileURL)
        model.restoreBook(id: id)
        XCTAssertTrue(model.visibleBooks.contains { $0.id == id })
        XCTAssertNil(model.archiveError)
    }

    func testLoadingMalformedArchiveDoesNotHideOrRewriteAnyBook() async throws {
        let store = LibraryVisibilityStore(rootDirectory: directory)
        let broken = Data("corrupt preferences".utf8)
        try broken.write(to: store.fileURL)
        let model = await loadedModel()
        XCTAssertNil(model.loadError, "An archive preference error must not block readable books")
        XCTAssertEqual(model.visibleBooks, model.books)
        XCTAssertFalse(model.canChangeArchive)
        XCTAssertNotNil(model.archiveError)
        model.archiveBook(id: ArgentinaFixtureIDs.book)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), broken)
        XCTAssertTrue(model.archivedBooks.isEmpty)
    }

    func testUnknownBookCannotBeSilentlyAddedToArchive() async throws {
        let model = await loadedModel()
        model.archiveBook(id: UUID())
        XCTAssertTrue(model.archivedBookIDs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            LibraryVisibilityStore(rootDirectory: directory).fileURL.path))
    }

    private func loadedModel() async -> LibraryViewModel {
        let model = LibraryViewModel(ai: MockAIService(), rootDirectory: directory)
        await model.load()
        XCTAssertNil(model.loadError)
        XCTAssertFalse(model.books.isEmpty)
        return model
    }

    private func fileSnapshot() throws -> [String: Data] {
        let urls = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])!
        var snapshot: [String: Data] = [:]
        for case let url as URL in urls {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
                  url.lastPathComponent != "LibraryVisibility.json" else { continue }
            snapshot[String(url.path.dropFirst(directory.path.count))] = try Data(contentsOf: url)
        }
        return snapshot
    }
}
