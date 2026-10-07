import XCTest
@testable import LivingReader

@MainActor
final class LibraryCreateResumeTests: XCTestCase {
    private var root: URL!
    private var drafts: FileCreateBookDraftStore!
    private var versioning: ManuscriptVersioningService!
    private var model: LibraryViewModel!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!
    private var modelPrefs: AIModelPreferenceStore!
    private var ai: MockAIService!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryCreateResume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        drafts = try FileCreateBookDraftStore(rootDirectory: root)
        versioning = try ManuscriptVersioningService(rootDirectory: root)
        ai = MockAIService()
        model = LibraryViewModel(ai: ai, rootDirectory: root)
        defaultsSuite = "LibraryCreateResumeTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
        modelPrefs = AIModelPreferenceStore(defaults: defaults)
    }

    override func tearDownWithError() throws {
        defaults?.removePersistentDomain(forName: defaultsSuite)
        try? FileManager.default.removeItem(at: root)
    }

    func testContinueWritingIsOfferedOnlyForMatchingSavedGenerateDrafts() async throws {
        let resumable = makeDraft()
        var importDraft = makeDraft()
        importDraft.path = .importManuscript
        let noDraftID = UUID()
        let orphanDraft = makeDraft()
        try drafts.save(resumable)
        try drafts.save(importDraft)
        try drafts.save(orphanDraft)
        for id in [resumable.id, importDraft.id, noDraftID] {
            try await saveShelfBook(id: id)
        }

        await model.load()

        XCTAssertNil(model.loadError)
        XCTAssertEqual(model.resumableBookIDs, Set([resumable.id]))
        XCTAssertNil(model.makeCreateViewModel(modelPrefs: modelPrefs, resumingBookID: importDraft.id))
        XCTAssertNil(model.makeCreateViewModel(modelPrefs: modelPrefs, resumingBookID: orphanDraft.id))
        XCTAssertEqual(ai.totalCallCount, 0)
    }

    func testContinueWritingReloadsExactMatchingDraftIntoGenerateSheet() async throws {
        var selected = makeDraft()
        let other = makeDraft() // Same title, different identity: never choose the newest by title.
        try drafts.save(selected)
        try drafts.save(other)
        try await saveShelfBook(id: selected.id)
        try await saveShelfBook(id: other.id)
        await model.load()
        let originalBooks = model.books

        selected.topic = "The saved topic changed after the shelf loaded"
        selected.referenceStyles = ["Reference one", "Reference two"]
        selected.outlineTitles = ["River", "Port"]
        selected.researchNotes = "Retain the original research."
        selected.profileCards = [CreateProfileCard(title: "Voice", body: "Warm and precise")]
        try drafts.save(selected)
        let expected = try XCTUnwrap(drafts.load(id: selected.id))

        let resumed = try XCTUnwrap(model.makeCreateViewModel(
            modelPrefs: modelPrefs, resumingBookID: selected.id
        ))

        XCTAssertEqual(resumed.draft, expected)
        XCTAssertEqual(resumed.tab, .generateBook)
        XCTAssertEqual(resumed.step, .form)
        XCTAssertEqual(resumed.referenceStylesText, "Reference one, Reference two")
        XCTAssertEqual(model.books, originalBooks, "Opening Create does not rewrite the shelf book")
        XCTAssertEqual(ai.totalCallCount, 0)
    }

    func testNewBookStaysBlankDespiteSavedGenerationDraft() async throws {
        let saved = makeDraft()
        try drafts.save(saved)
        try await saveShelfBook(id: saved.id)
        await model.load()

        let first = try XCTUnwrap(model.makeCreateViewModel(modelPrefs: modelPrefs))
        let second = try XCTUnwrap(model.makeCreateViewModel(modelPrefs: modelPrefs))

        XCTAssertNotEqual(first.draft.id, saved.id)
        XCTAssertNotEqual(first.draft.id, second.draft.id)
        XCTAssertEqual(first.draft.path, .importManuscript)
        XCTAssertEqual(first.tab, .existingBooks)
        XCTAssertEqual(first.draft.title, "")
        XCTAssertEqual(first.draft.topic, "")
        XCTAssertTrue(first.draft.outlineTitles.isEmpty)
        XCTAssertNotNil(try drafts.load(id: saved.id))
    }

    func testRemovedDraftCannotReopenAsBlankOrAnotherDraft() async throws {
        let removed = makeDraft()
        let other = makeDraft()
        try drafts.save(removed)
        try drafts.save(other)
        try await saveShelfBook(id: removed.id)
        try await saveShelfBook(id: other.id)
        await model.load()
        XCTAssertTrue(model.resumableBookIDs.contains(removed.id))
        try drafts.delete(id: removed.id)

        XCTAssertNil(model.makeCreateViewModel(modelPrefs: modelPrefs, resumingBookID: removed.id))
        XCTAssertNotNil(model.createError)
        XCTAssertNil(model.loadError, "A missing draft must not replace the readable shelf with an error")
        XCTAssertFalse(model.resumableBookIDs.contains(removed.id))
        await model.reloadBooks()
        XCTAssertEqual(model.resumableBookIDs, Set([other.id]))
    }

    func testMalformedDraftDoesNotHideReadableBooksOrOfferResume() async throws {
        let malformed = makeDraft()
        try await saveShelfBook(id: malformed.id)
        let file = drafts.directory.appendingPathComponent("\(malformed.id.uuidString).json")
        try Data("not a saved draft".utf8).write(to: file)

        await model.load()

        XCTAssertNil(model.loadError)
        XCTAssertTrue(model.books.contains { $0.id == malformed.id })
        XCTAssertFalse(model.resumableBookIDs.contains(malformed.id))
        XCTAssertNil(model.makeCreateViewModel(modelPrefs: modelPrefs, resumingBookID: malformed.id))
        XCTAssertNotNil(model.createError)
    }

    func testOldCreateCompletionCannotDismissNewUnsavedDraft() async throws {
        await model.load()
        let first = try XCTUnwrap(model.makeCreateViewModel(modelPrefs: modelPrefs))
        let second = try XCTUnwrap(model.makeCreateViewModel(modelPrefs: modelPrefs))
        second.draft.title = "Do not lose this unsaved title"
        var presentation = LibraryCreatePresentation()
        let firstID = presentation.present(first)
        XCTAssertTrue(presentation.dismiss(id: firstID))
        let secondID = presentation.present(second)

        XCTAssertFalse(presentation.dismiss(id: firstID))
        XCTAssertEqual(presentation.item?.id, secondID)
        XCTAssertEqual(presentation.item?.model.draft.title, second.draft.title)
        XCTAssertFalse(presentation.canOpenCompletedBook(id: firstID))
    }

    func testNewPresentationDuringDismissalDelayInvalidatesOldNavigation() async throws {
        await model.load()
        let first = try XCTUnwrap(model.makeCreateViewModel(modelPrefs: modelPrefs))
        let second = try XCTUnwrap(model.makeCreateViewModel(modelPrefs: modelPrefs))
        var presentation = LibraryCreatePresentation()
        let firstID = presentation.present(first)
        XCTAssertTrue(presentation.dismiss(id: firstID))
        XCTAssertTrue(presentation.canOpenCompletedBook(id: firstID))
        let secondID = presentation.present(second)
        XCTAssertTrue(presentation.dismiss(id: secondID))
        XCTAssertFalse(presentation.canOpenCompletedBook(id: firstID))
    }

    func testCompletionOfAlreadyClosedSheetCannotStartNavigation() async throws {
        await model.load()
        let first = try XCTUnwrap(model.makeCreateViewModel(modelPrefs: modelPrefs))
        var presentation = LibraryCreatePresentation()
        let firstID = presentation.present(first)
        presentation.item = nil // SwiftUI interactive dismissal.
        XCTAssertFalse(presentation.dismiss(id: firstID), "Completion must dismiss its own active sheet before navigating")
    }

    func testStartupMalformedManuscriptKeepsReadablePeerAndOnlyHealthyResume() async throws {
        let healthyDraft = makeDraft()
        let damagedDraft = makeDraft()
        try drafts.save(healthyDraft)
        try drafts.save(damagedDraft)
        let healthy = try await saveReadableBook(id: healthyDraft.id)
        let healthyBytes = try Data(contentsOf: manuscriptURL(healthy.id))
        try await saveShelfBook(id: damagedDraft.id)
        let damaged = try writeDamagedFile(manuscriptURL(damagedDraft.id), bytes: Data("{broken manuscript".utf8))
        await model.load()
        XCTAssertNil(model.loadError)
        XCTAssertTrue(model.didLoadOffline)
        XCTAssertTrue(model.books.contains { $0.id == healthy.id })
        XCTAssertFalse(model.books.contains { $0.id == damagedDraft.id })
        XCTAssertEqual(model.resumableBookIDs, Set([healthy.id]))
        assertIssue(filename: damaged.url.lastPathComponent, bookID: damagedDraft.id)
        XCTAssertNil(model.makeCreateViewModel(modelPrefs: modelPrefs, resumingBookID: damagedDraft.id))
        let resumed = try XCTUnwrap(model.makeCreateViewModel(modelPrefs: modelPrefs, resumingBookID: healthy.id))
        XCTAssertEqual(resumed.draft.id, healthy.id)
        try await assertReadable(healthy)
        XCTAssertEqual(try Data(contentsOf: manuscriptURL(healthy.id)), healthyBytes)
        try assertUnchanged(damaged)
        XCTAssertEqual(ai.totalCallCount, 0)
    }

    func testCorruptArgentinaDoesNotSuppressAvailablePeerOrHealthyUserBook() async throws {
        try await assertBundledCorruptionRecovery([ArgentinaFixtureIDs.book])
    }

    func testCorruptQuranDoesNotSuppressArgentinaOrHealthyUserBook() async throws {
        try await assertBundledCorruptionRecovery([QuranFixtureIDs.book])
    }

    func testBothCorruptBundledBooksDoNotSuppressHealthyUserBook() async throws {
        try await assertBundledCorruptionRecovery([ArgentinaFixtureIDs.book, QuranFixtureIDs.book])
    }

    func testMissingArgentinaWithConsumedHistoryStaysAbsentAndReportsRecovery() async throws {
        try await assertMissingConsumedBundledBook(try BundleFixtureLoader.loadArgentinaMinimal())
    }

    func testMissingQuranWithConsumedHistoryStaysAbsentAndReportsRecovery() async throws {
        try OptionalQuranFixture.requirePresence()
        try await assertMissingConsumedBundledBook(try BundleFixtureLoader.loadQuranPickthall())
    }

    func testFilenameIdentityMismatchAndUnaddressableJSONAreReportedWithoutRenaming() async throws {
        let healthy = try await saveReadableBook(id: UUID())
        let wrongID = UUID()
        let orphanID = UUID()
        let payload = Book(id: orphanID, title: "Wrong filename", author: "Fixture", chapters: [])
        let mismatched = try writeDamagedFile(manuscriptURL(wrongID), bytes: JSONCoding.encoder.encode(payload))
        let unaddressable = try writeDamagedFile(root.appendingPathComponent("Manuscripts/backup-\(orphanID.uuidString).json"), bytes: JSONCoding.encoder.encode(payload))
        var orphanDraft = makeDraft(); orphanDraft.id = orphanID
        try drafts.save(orphanDraft)
        await model.load()
        XCTAssertNil(model.loadError)
        assertIssue(filename: mismatched.url.lastPathComponent, bookID: wrongID)
        assertIssue(filename: unaddressable.url.lastPathComponent, bookID: nil)
        XCTAssertFalse(model.books.contains { [wrongID, orphanID].contains($0.id) })
        XCTAssertFalse(model.resumableBookIDs.contains(orphanID))
        XCTAssertNil(model.makeCreateViewModel(modelPrefs: modelPrefs, resumingBookID: orphanID))
        let store = try FileManuscriptStore(directory: root.appendingPathComponent("Manuscripts"))
        XCTAssertThrowsError(try store.loadBook(id: wrongID))
        XCTAssertThrowsError(try store.listBookSummaries(), "The existing strict summaries API must remain strict")
        let snapshot = try store.loadLibrarySnapshot()
        let repeated = try store.loadLibrarySnapshot()
        XCTAssertEqual(snapshot.books.map(\.id), repeated.books.map(\.id))
        XCTAssertEqual(snapshot.issues.map(\.filename), snapshot.issues.map(\.filename).sorted())
        XCTAssertEqual(Set(snapshot.issues.map(\.filename)), Set([mismatched.url.lastPathComponent, unaddressable.url.lastPathComponent]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: manuscriptURL(orphanID).path))
        try await assertReadable(healthy)
        try assertUnchanged(mismatched)
        try assertUnchanged(unaddressable)
        XCTAssertEqual(ai.totalCallCount, 0)
    }

    func testAllUnavailableShelfHasExplicitPerFileIssuesAndNoResumeOrProgress() async throws {
        var unavailableDraft = makeDraft(); unavailableDraft.id = ArgentinaFixtureIDs.book
        try drafts.save(unavailableDraft)
        let argentina = try writeDamagedFile(manuscriptURL(ArgentinaFixtureIDs.book), bytes: Data("bad Argentina".utf8))
        let quran = try writeDamagedFile(manuscriptURL(QuranFixtureIDs.book), bytes: Data("bad Quran".utf8))
        await model.load()
        XCTAssertNil(model.loadError, "Per-file unavailability is not a global store failure")
        XCTAssertTrue(model.books.isEmpty)
        XCTAssertTrue(model.resumableBookIDs.isEmpty)
        XCTAssertTrue(model.progressByBookId.isEmpty)
        XCTAssertTrue(model.chapterLabelByBookId.isEmpty)
        XCTAssertTrue(model.minutesLeftByBookId.isEmpty)
        assertIssue(filename: argentina.url.lastPathComponent, bookID: ArgentinaFixtureIDs.book)
        assertIssue(filename: quran.url.lastPathComponent, bookID: QuranFixtureIDs.book)
        XCTAssertNil(model.makeCreateViewModel(modelPrefs: modelPrefs, resumingBookID: ArgentinaFixtureIDs.book))
        try assertUnchanged(argentina)
        try assertUnchanged(quran)
        XCTAssertEqual(ai.totalCallCount, 0)
    }

    func testHealthyToCorruptReloadRemovesCachedCardThenRepairAndFreshLoadClearIssues() async throws {
        let savedDraft = makeDraft()
        try drafts.save(savedDraft)
        let healthy = try await saveReadableBook(id: savedDraft.id)
        let original = try Data(contentsOf: manuscriptURL(healthy.id))
        await model.load()
        XCTAssertTrue(model.resumableBookIDs.contains(healthy.id))
        XCTAssertNotNil(model.progressByBookId[healthy.id])
        let damaged = try writeDamagedFile(manuscriptURL(healthy.id), bytes: Data("not JSON anymore".utf8))
        await model.reloadBooks()
        XCTAssertNil(model.loadError)
        XCTAssertFalse(model.books.contains { $0.id == healthy.id })
        XCTAssertFalse(model.resumableBookIDs.contains(healthy.id))
        XCTAssertNil(model.progressByBookId[healthy.id])
        XCTAssertNil(model.chapterLabelByBookId[healthy.id])
        XCTAssertNil(model.minutesLeftByBookId[healthy.id])
        assertIssue(filename: damaged.url.lastPathComponent, bookID: healthy.id)
        XCTAssertNil(model.makeCreateViewModel(modelPrefs: modelPrefs, resumingBookID: healthy.id))
        try assertUnchanged(damaged)

        // Restore only this test-owned fixture, not an application repair action.
        try AtomicFileWriter.writeAtomically(original, to: damaged.url)
        model.loadError = "A stale prior store error"
        await model.reloadBooks()
        XCTAssertNil(model.loadError)
        XCTAssertTrue(model.loadIssues.isEmpty)
        XCTAssertTrue(model.resumableBookIDs.contains(healthy.id))
        try await assertReadable(healthy)
        await model.load()
        XCTAssertNil(model.loadError)
        XCTAssertTrue(model.loadIssues.isEmpty)
        XCTAssertTrue(model.books.contains { $0.id == healthy.id })
        XCTAssertTrue(model.resumableBookIDs.contains(healthy.id))
        let reopened = LibraryViewModel(ai: ai, rootDirectory: root)
        await reopened.load()
        XCTAssertNil(reopened.loadError)
        XCTAssertTrue(reopened.loadIssues.isEmpty)
        XCTAssertTrue(reopened.resumableBookIDs.contains(healthy.id))
        XCTAssertEqual(try Data(contentsOf: manuscriptURL(healthy.id)), original)
        XCTAssertEqual(ai.totalCallCount, 0)
    }

    func testRepairOfBundledCorruptionClearsBootstrapIssueOnReload() async throws {
        let original = try BundleFixtureLoader.loadArgentinaMinimal()
        let originalBytes = try JSONCoding.encoder.encode(original)
        let damaged = try writeDamagedFile(manuscriptURL(original.id), bytes: Data("damaged bundled book".utf8))
        await model.load()
        assertIssue(filename: damaged.url.lastPathComponent, bookID: original.id)
        try assertUnchanged(damaged)
        try AtomicFileWriter.writeAtomically(originalBytes, to: damaged.url)
        await model.reloadBooks()
        XCTAssertNil(model.loadError)
        XCTAssertTrue(model.loadIssues.isEmpty, "A successful reread clears the stored bootstrap warning")
        XCTAssertTrue(model.books.contains { $0.id == original.id })
        await model.load()
        XCTAssertNil(model.loadError)
        XCTAssertTrue(model.loadIssues.isEmpty)
        XCTAssertEqual(try Data(contentsOf: damaged.url), originalBytes)
        XCTAssertEqual(ai.totalCallCount, 0)
    }

    func testDirectoryEnumerationFailureClearsSelectableCacheAndRecoveryClearsGlobalError() async throws {
        let savedDraft = makeDraft()
        try drafts.save(savedDraft)
        let healthy = try await saveReadableBook(id: savedDraft.id)
        await model.load()
        XCTAssertTrue(model.resumableBookIDs.contains(healthy.id))
        let directory = root.appendingPathComponent("Manuscripts", isDirectory: false)
        let preserved = root.appendingPathComponent("PreservedTestManuscripts", isDirectory: true)
        try FileManager.default.moveItem(at: directory, to: preserved)
        try Data("A regular file cannot be enumerated as a manuscript directory".utf8).write(to: directory)
        await model.reloadBooks()
        XCTAssertNotNil(model.loadError)
        XCTAssertTrue(model.books.isEmpty)
        XCTAssertTrue(model.resumableBookIDs.isEmpty)
        XCTAssertTrue(model.progressByBookId.isEmpty)
        XCTAssertTrue(model.chapterLabelByBookId.isEmpty)
        XCTAssertTrue(model.minutesLeftByBookId.isEmpty)
        XCTAssertNil(model.makeCreateViewModel(modelPrefs: modelPrefs, resumingBookID: healthy.id))
        let failedStartup = LibraryViewModel(ai: ai, rootDirectory: root)
        await failedStartup.load()
        XCTAssertNotNil(failedStartup.loadError)
        XCTAssertTrue(failedStartup.books.isEmpty)
        XCTAssertTrue(failedStartup.resumableBookIDs.isEmpty)

        try FileManager.default.removeItem(at: directory) // This test's regular-file obstacle only.
        try FileManager.default.moveItem(at: preserved, to: directory)
        await model.reloadBooks()
        XCTAssertNil(model.loadError)
        XCTAssertTrue(model.loadIssues.isEmpty)
        XCTAssertTrue(model.resumableBookIDs.contains(healthy.id))
        try await assertReadable(healthy)
        await failedStartup.load()
        XCTAssertNil(failedStartup.loadError)
        XCTAssertTrue(failedStartup.books.contains { $0.id == healthy.id })
        XCTAssertEqual(ai.totalCallCount, 0)
    }

    func testFailedPartialQuranExpansionRetainsIssueUntilMissingChaptersAreRestored() async throws {
        try OptionalQuranFixture.requirePresence()
        try await versioning.saveBook(BundleFixtureLoader.loadArgentinaMinimal())
        let fullQuran = try BundleFixtureLoader.loadQuranPickthall()
        var partialQuran = fullQuran
        partialQuran.chapters = [try XCTUnwrap(fullQuran.chapters.first)]
        try await versioning.saveBook(partialQuran)
        let partial = try writeDamagedFile(manuscriptURL(fullQuran.id), bytes: JSONCoding.encoder.encode(partialQuran))
        let directory = root.appendingPathComponent("Manuscripts", isDirectory: true)
        let permissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions])
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: directory.path) }

        await model.load()

        XCTAssertNil(model.loadError)
        let loadedPartial = try XCTUnwrap(model.books.first { $0.id == fullQuran.id })
        XCTAssertEqual(loadedPartial.chapters.map(\.id), partialQuran.chapters.map(\.id))
        assertIssue(filename: partial.url.lastPathComponent, bookID: fullQuran.id)
        XCTAssertEqual(model.loadIssues.first { $0.bookID == fullQuran.id }?.expectedChapterIDs,
                       Set(fullQuran.chapters.map(\.id)))
        try await assertReadable(partialQuran)
        try assertUnchanged(partial)

        // Restoring writability alone does not mean the failed expansion succeeded.
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: directory.path)
        await model.reloadBooks()
        assertIssue(filename: partial.url.lastPathComponent, bookID: fullQuran.id)
        try assertUnchanged(partial)
        let completeBytes = try JSONCoding.encoder.encode(fullQuran)
        try AtomicFileWriter.writeAtomically(completeBytes, to: partial.url)
        await model.reloadBooks()
        XCTAssertNil(model.loadError)
        XCTAssertTrue(model.loadIssues.isEmpty)
        XCTAssertEqual(model.books.first { $0.id == fullQuran.id }?.chapters.map(\.id), fullQuran.chapters.map(\.id))
        XCTAssertEqual(try Data(contentsOf: partial.url), completeBytes)
        XCTAssertEqual(ai.totalCallCount, 0)
    }

    private struct PreservedManuscript {
        let url: URL
        let bytes: Data
        let modificationDate: Date?
    }

    private func manuscriptURL(_ id: UUID) -> URL {
        root.appendingPathComponent("Manuscripts/\(id.uuidString).json")
    }

    private func writeDamagedFile(_ url: URL, bytes: Data) throws -> PreservedManuscript {
        try AtomicFileWriter.writeAtomically(bytes, to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_234_567_890)], ofItemAtPath: url.path)
        let date = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        return PreservedManuscript(url: url, bytes: bytes, modificationDate: date)
    }

    private func assertUnchanged(_ file: PreservedManuscript, file sourceFile: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try Data(contentsOf: file.url), file.bytes, file: sourceFile, line: line)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.url.path)[.modificationDate] as? Date,
                       file.modificationDate, file: sourceFile, line: line)
    }

    private func assertIssue(filename: String, bookID: UUID?, file: StaticString = #filePath, line: UInt = #line) {
        let issues = model.loadIssues.filter { $0.filename == filename }
        XCTAssertEqual(issues.count, 1, "One explicit issue per unavailable file", file: file, line: line)
        XCTAssertEqual(issues.first?.bookID, bookID, file: file, line: line)
        XCTAssertFalse(issues.first?.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true, file: file, line: line)
    }

    private func assertReadable(_ book: Book, file: StaticString = #filePath, line: UInt = #line) async throws {
        let service = try XCTUnwrap(model.versioning, file: file, line: line)
        let chapter = try XCTUnwrap(book.chapters.first, file: file, line: line)
        let expected = try XCTUnwrap(chapter.activeRevision, file: file, line: line)
        let actual = try await service.readableRevision(bookId: book.id, chapterId: chapter.id)
        XCTAssertEqual(actual, expected, file: file, line: line)
        XCTAssertFalse(actual.blocks.isEmpty, file: file, line: line)
    }

    private func saveReadableBook(id: UUID) async throws -> Book {
        let chapterID = UUID()
        let revision = ChapterRevision(id: UUID(), chapterId: chapterID, revisionIndex: 1,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            blocks: [ContentBlock(id: UUID(), kind: .paragraph,
                text: "This healthy chapter remains readable offline while a different saved manuscript needs recovery.", orderIndex: 0)], isConsumed: false)
        let chapter = Chapter(id: chapterID, bookId: id, title: "A readable chapter", orderIndex: 0,
            activeRevisionId: revision.id, revisions: [revision])
        let book = Book(id: id, title: "Healthy user book", author: "Fixture", chapters: [chapter])
        try await versioning.saveBook(book)
        return book
    }

    private func assertBundledCorruptionRecovery(_ damagedIDs: [UUID]) async throws {
        let savedDraft = makeDraft()
        try drafts.save(savedDraft)
        let healthy = try await saveReadableBook(id: savedDraft.id)
        let damaged = try damagedIDs.map { try writeDamagedFile(manuscriptURL($0), bytes: Data("broken bundled \($0.uuidString)".utf8)) }
        await model.load()
        XCTAssertNil(model.loadError)
        XCTAssertTrue(model.resumableBookIDs.contains(healthy.id))
        try await assertReadable(healthy)
        let availableSeeds = [ArgentinaFixtureIDs.book] + (try OptionalQuranFixture.isPresent() ? [QuranFixtureIDs.book] : [])
        for id in [ArgentinaFixtureIDs.book, QuranFixtureIDs.book] {
            XCTAssertEqual(model.books.contains { $0.id == id }, availableSeeds.contains(id) && !damagedIDs.contains(id))
        }
        for file in damaged {
            assertIssue(filename: file.url.lastPathComponent, bookID: UUID(uuidString: file.url.deletingPathExtension().lastPathComponent))
            try assertUnchanged(file)
        }
        XCTAssertEqual(ai.totalCallCount, 0)
    }

    private func assertMissingConsumedBundledBook(_ bundled: Book) async throws {
        let savedDraft = makeDraft()
        try drafts.save(savedDraft)
        let healthy = try await saveReadableBook(id: savedDraft.id)
        try await versioning.saveBook(bundled)
        let chapter = try XCTUnwrap(bundled.chapters.first)
        let revision = try XCTUnwrap(chapter.activeRevision)
        try await versioning.consume(bookId: bundled.id, chapterId: chapter.id, revisionId: revision.id)
        let ledgerURL = root.appendingPathComponent("Ledger/consumed-ledger.json")
        let ledgerBytes = try Data(contentsOf: ledgerURL)
        let missingURL = manuscriptURL(bundled.id)
        try FileManager.default.removeItem(at: missingURL) // Simulated absence of this test-owned fixture.
        await model.load()
        await model.reloadBooks()
        XCTAssertNil(model.loadError)
        XCTAssertFalse(model.books.contains { $0.id == bundled.id })
        XCTAssertFalse(model.resumableBookIDs.contains(bundled.id))
        assertIssue(filename: missingURL.lastPathComponent, bookID: bundled.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingURL.path), "Recorded history forbids reseeding")
        let otherID = bundled.id == ArgentinaFixtureIDs.book ? QuranFixtureIDs.book : ArgentinaFixtureIDs.book
        let optionalSeedPresent = try OptionalQuranFixture.isPresent()
        if otherID == ArgentinaFixtureIDs.book || optionalSeedPresent {
            XCTAssertTrue(model.books.contains { $0.id == otherID })
        }
        XCTAssertTrue(model.resumableBookIDs.contains(healthy.id))
        try await assertReadable(healthy)
        XCTAssertEqual(try Data(contentsOf: ledgerURL), ledgerBytes)
        XCTAssertEqual(ai.totalCallCount, 0)
    }

    private func makeDraft() -> CreateBookDraft {
        var draft = CreateBookDraft.blank()
        draft.path = .generate
        draft.title = "Shared title"
        draft.topic = "A river history"
        draft.length = .short
        return draft
    }

    private func saveShelfBook(id: UUID) async throws {
        let book = Book(id: id, title: "Shared title", author: "GenBooks", chapters: [])
        try await versioning.saveBook(book)
    }
}
