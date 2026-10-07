import XCTest
@testable import LivingReader

/// RDR-945 — Make Living from a Canon import reuses the existing adapt/regen Apply
/// loop. Consumed past stays byte-for-byte; kind flips Canon → Living only after Apply.
final class MakeLivingFromCanonTests: XCTestCase {
    private var root: URL!
    private var versioning: ManuscriptVersioningService!
    private var feedbackStore: FileFeedbackStore!
    private var preferenceStore: FileReaderPreferenceStore!
    private var ai: MockAIService!
    private var adaptation: LivingBookAdaptationService!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakeLiving-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        versioning = try ManuscriptVersioningService(rootDirectory: root)
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
        adaptation = nil
        ai = nil
    }

    func testPromoteFlipsKindWithoutRewritingChapters() throws {
        let book = try makeCanonBook()
        let before = try JSONCoding.encoder.encode(book.chapters)
        XCTAssertTrue(book.isCanonImport)
        XCTAssertEqual(book.libraryKindLabel, "CANON")

        let living = book.promotedToLivingFromCanon()
        XCTAssertFalse(living.isCanonImport)
        XCTAssertTrue(living.isLivingFromCanon)
        XCTAssertFalse(living.canMakeLivingFromCanon, "Living cannot recurse — Make Living stays Canon-only")
        XCTAssertEqual(living.libraryKindLabel, "A LIVING BOOK")
        XCTAssertEqual(living.edition?.label, "Living")
        XCTAssertEqual(living.subtitle, "Living · from Canon")
        XCTAssertEqual(living.coverAccent, "imported", "No new cover assets — keep the imported treatment")
        XCTAssertEqual(try JSONCoding.encoder.encode(living.chapters), before)
        XCTAssertTrue(living.provenanceNotes.contains { $0.contains("Made Living from Canon") })
    }

    func testLivingEditionWinsEvenIfSubtitleMentionsCanon() throws {
        var book = try makeCanonBook()
        var edition = try XCTUnwrap(book.edition)
        edition.label = "Living"
        book.edition = edition
        book.subtitle = "Living · from Canon"
        XCTAssertFalse(book.isCanonImport)
        XCTAssertTrue(book.isLivingFromCanon)
    }

    func testFriendEPUBImportStaysCanonUntilPromote() throws {
        let url = try BundleFixtureLoader.urlForFriendCanonEPUB()
        let prepared = try CanonFileIngest.prepare(from: url)
        let book = try ManuscriptImporter.importPlainText(
            text: prepared.plainText,
            title: prepared.title,
            author: prepared.author,
            sourceKind: prepared.sourceKind
        )
        XCTAssertTrue(book.isCanonImport)
        XCTAssertFalse(book.isLivingFromCanon)
        let living = book.promotedToLivingFromCanon()
        XCTAssertEqual(living.title, book.title)
        XCTAssertEqual(living.chapters.map(\.id), book.chapters.map(\.id))
        XCTAssertEqual(
            living.chapters.flatMap(\.revisions).map(\.id),
            book.chapters.flatMap(\.revisions).map(\.id)
        )
    }

    func testPreviewDoesNotFlipCanonKindOrMutateBodies() async throws {
        let book = try makeCanonBook()
        try await versioning.saveBook(book)
        let cut = book.chapters.sorted { $0.orderIndex < $1.orderIndex }[1]
        let before = try JSONCoding.encoder.encode(try await versioning.loadBook(id: book.id)!)

        _ = try await adaptation.previewRegeneration(book: book, fromChapterId: cut.id, maxChapters: 1)

        let after = try await versioning.loadBook(id: book.id)!
        XCTAssertTrue(after.isCanonImport)
        XCTAssertEqual(try JSONCoding.encoder.encode(after), before)
        XCTAssertEqual(ai.adaptCallCount, 0, "Preview must not generate")
    }

    func testApplyFromCanonUsesExistingRegenAndLeavesConsumedPast() async throws {
        let book = try makeCanonBook()
        try await versioning.saveBook(book)
        let ordered = book.chapters.sorted { $0.orderIndex < $1.orderIndex }
        let ch1 = ordered[0]
        let ch2 = ordered[1]
        let ch1Rev = try XCTUnwrap(ch1.activeRevisionId)
        try await versioning.consume(bookId: book.id, chapterId: ch1.id, revisionId: ch1Rev)
        let beforeCh1 = try await versioning.retrieveConsumedRevision(bookId: book.id, chapterId: ch1.id)
        let beforeCh1Data = try JSONCoding.encoder.encode(try XCTUnwrap(beforeCh1))
        let beforeCh1Readable = try await versioning.readableRevision(bookId: book.id, chapterId: ch1.id)

        let preview = try await adaptation.previewRegeneration(
            book: book,
            fromChapterId: ch2.id,
            preferences: .default,
            maxChapters: 1,
            length: .half
        )
        XCTAssertEqual(preview.plan.resolvedLengthPreset, .half)
        XCTAssertFalse(preview.plan.affectedChapterIds.contains(ch1.id))
        XCTAssertTrue(preview.plan.lockedChapterIds.contains(ch1.id))

        ai.resetCallCount()
        _ = try await adaptation.applyRegeneration(book: book, preview: preview)
        XCTAssertGreaterThan(ai.adaptCallCount, 0)

        let afterCh1 = try await versioning.retrieveConsumedRevision(bookId: book.id, chapterId: ch1.id)
        XCTAssertEqual(try JSONCoding.encoder.encode(try XCTUnwrap(afterCh1)), beforeCh1Data)
        let readableCh1 = try await versioning.readableRevision(bookId: book.id, chapterId: ch1.id)
        XCTAssertEqual(readableCh1.id, beforeCh1Readable.id)
        XCTAssertEqual(readableCh1.blocks.map(\.text), beforeCh1Readable.blocks.map(\.text))

        let latest = try await versioning.loadBook(id: book.id)!
        XCTAssertFalse(latest.isCanonImport)
        XCTAssertTrue(latest.isLivingFromCanon)
        XCTAssertEqual(latest.libraryKindLabel, "A LIVING BOOK")
        XCTAssertEqual(latest.subtitle, "Living · from Canon")

        let readableCh2 = try await versioning.readableRevision(bookId: book.id, chapterId: ch2.id)
        XCTAssertNotEqual(readableCh2.id, ch2.activeRevisionId)
        XCTAssertGreaterThan(readableCh2.revisionIndex, 1)
    }

    func testQuranSeedIsNotEligibleForMakeLiving() throws {
        try OptionalQuranFixture.requirePresence()
        let quran = try BundleFixtureLoader.loadQuranPickthall()
        XCTAssertFalse(quran.isCanonImport)
        XCTAssertFalse(quran.canMakeLivingFromCanon)
        XCTAssertFalse(quran.promotedToLivingFromCanon().canMakeLivingFromCanon)
    }

    func testProtectedOptionalBookIdentityDoesNotOfferMakeLivingEvenWhenMarkedCanon() {
        let protected = Book(id: QuranFixtureIDs.book, title: "Protected sample metadata",
                             author: "Fixture", coverAccent: "imported", chapters: [])
        XCTAssertTrue(protected.isCanonImport)
        XCTAssertFalse(protected.canMakeLivingFromCanon)
    }

    func testPromoteHelperIsNoOpOnAlreadyLivingBook() async throws {
        let argentina = try BundleFixtureLoader.loadArgentinaMinimal()
        try await versioning.saveBook(argentina)
        let before = try JSONCoding.encoder.encode(argentina)
        let result = try await adaptation.promoteCanonImportToLivingIfNeeded(bookId: argentina.id)
        XCTAssertEqual(result?.id, argentina.id)
        XCTAssertFalse(result?.isCanonImport ?? true)
        let reloaded = try await versioning.loadBook(id: argentina.id)
        XCTAssertEqual(try JSONCoding.encoder.encode(try XCTUnwrap(reloaded)), before)
    }

    private func makeCanonBook() throws -> Book {
        let filler = Array(repeating: "plaza river light bargain cattle stones evening", count: 40)
            .joined(separator: " ")
        return try ManuscriptImporter.importPlainText(
            text: """
            # River Light
            The plaza kept the river's last light on the stones. \(filler)

            # Interior Bargain
            Cattle walked toward a price they did not set. \(filler)
            """,
            title: "Plaza Evening",
            author: "A Friend",
            sourceKind: .epubExtract
        )
    }
}
