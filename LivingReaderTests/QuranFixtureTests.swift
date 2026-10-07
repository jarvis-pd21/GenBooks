import XCTest
@testable import LivingReader

/// Friend-demo Quran seed: authentic Pickthall 1930, bundled offline, seed-preserve.
final class QuranFixtureTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try OptionalQuranFixture.requirePresence()
    }

    func testPickthallFixtureDecodesFull114Surahs() throws {
        let book = try BundleFixtureLoader.loadQuranPickthall()
        XCTAssertEqual(book.id, QuranFixtureIDs.book)
        XCTAssertEqual(book.title, "The Quran")
        XCTAssertEqual(book.subtitle, "Pickthall translation (1930)")
        XCTAssertEqual(book.author, "Mohammed Marmaduke Pickthall")
        XCTAssertEqual(book.coverAccent, "quran-night")
        XCTAssertEqual(book.edition?.id, QuranFixtureIDs.edition)
        XCTAssertEqual(book.chapters.count, QuranFixtureIDs.expectedSurahCount)
        XCTAssertEqual(book.polishedChapterCount, QuranFixtureIDs.expectedSurahCount)
        XCTAssertEqual(book.outlineChapterCount, 0)
        XCTAssertNotEqual(book.id, ArgentinaFixtureIDs.book)

        let verseBlocks = book.chapters.flatMap { $0.activeRevision?.blocks ?? [] }.filter { $0.kind == .paragraph }
        XCTAssertEqual(verseBlocks.count, QuranFixtureIDs.expectedVerseCount)

        let joined = verseBlocks.map(\.text).joined(separator: "\n")
        XCTAssertTrue(joined.contains(QuranFixtureIDs.fatihahOpening))
        XCTAssertTrue(joined.contains(QuranFixtureIDs.ikhlasOpening))
        XCTAssertTrue(joined.contains("Allah! There is no deity save Him, the Alive, the Eternal."))
        XCTAssertFalse(joined.lowercased().contains("lorem"))
        XCTAssertFalse(joined.contains("[Adapted]"))
    }

    func testProvenanceAttributesPublicDomainPickthall() throws {
        let book = try BundleFixtureLoader.loadQuranPickthall()
        let notes = book.provenanceNotes.joined(separator: " ").lowercased()
        XCTAssertTrue(notes.contains("pickthall"))
        XCTAssertTrue(notes.contains("1930"))
        XCTAssertTrue(notes.contains("public domain"))
        XCTAssertTrue(notes.contains("tanzil"))
        XCTAssertTrue(notes.contains("not an ai-generated"))
        XCTAssertTrue(notes.contains("yusuf ali"))
        XCTAssertTrue(book.synopsis?.contains("English translation") == true)
    }

    func testEmptyLibrarySeedsArgentinaThenQuranWithoutTouchingUserBooks() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuranSeed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = try ManuscriptVersioningService(rootDirectory: root)
        let user = try ManuscriptImporter.importPlainText(
            text: "# Custom\nA user book that must survive seed.",
            title: "My Notes",
            author: "Reader",
            sourceKind: .pastedText
        )
        try await service.saveBook(user)
        let userBefore = try JSONCoding.encoder.encode(try await service.loadBook(id: user.id)!)

        let argentina = try await BundleFixtureLoader.seedIfNeeded(into: service)
        XCTAssertEqual(argentina.id, ArgentinaFixtureIDs.book)
        XCTAssertEqual(argentina.title, "A Little History of Argentina")

        let quran = try await service.loadBook(id: QuranFixtureIDs.book)
        XCTAssertEqual(quran?.title, "The Quran")
        XCTAssertEqual(quran?.chapters.count, 114)

        let listed = try await service.listBooks()
        XCTAssertEqual(Set(listed.map(\.id)), [ArgentinaFixtureIDs.book, QuranFixtureIDs.book, user.id])

        let userAfter = try JSONCoding.encoder.encode(try await service.loadBook(id: user.id)!)
        XCTAssertEqual(userBefore, userAfter)

        let manuscripts = root.appendingPathComponent("Manuscripts/\(user.id.uuidString).json")
        let bytes = try Data(contentsOf: manuscripts)
        _ = try await BundleFixtureLoader.seedIfNeeded(into: service)
        XCTAssertEqual(try Data(contentsOf: manuscripts), bytes)
    }

    func testQuranSeedPreservesExistingChaptersAndDoesNotRewriteBytes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuranPreserve-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = try ManuscriptVersioningService(rootDirectory: root)
        var existing = try BundleFixtureLoader.loadQuranPickthall()
        existing.title = "Reader-retained Quran title"
        existing.chapters[0].title = "Reader-retained Fatihah"
        try await service.saveBook(existing)
        let url = root.appendingPathComponent("Manuscripts/\(existing.id.uuidString).json")
        let before = try Data(contentsOf: url)

        let returned = try await BundleFixtureLoader.seedBookIfNeeded(try BundleFixtureLoader.loadQuranPickthall(), into: service)
        XCTAssertEqual(returned.title, "Reader-retained Quran title")
        XCTAssertEqual(returned.chapters[0].title, "Reader-retained Fatihah")
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testCreateDoesNotOverwriteQuranAndArgentinaStaysFirst() async throws {
        let quran = try BundleFixtureLoader.loadQuranPickthall()
        let argentina = try BundleFixtureLoader.loadArgentinaMinimal()
        let imported = try ManuscriptImporter.importPlainText(
            text: "# Plaza\nCreated after the seeds.",
            title: "Plaza Notes",
            author: "Test Author",
            sourceKind: .pastedText
        )
        let sorted = LibraryBookOrdering.sorted([imported, quran, argentina])
        XCTAssertEqual(sorted.map(\.id), [argentina.id, quran.id, imported.id])
        XCTAssertTrue(BundledSeedIDs.isProtected(quran.id))
        XCTAssertTrue(BundledSeedIDs.isProtected(argentina.id))
        XCTAssertFalse(BundledSeedIDs.isProtected(imported.id))
    }

    func testIncompleteQuranSeedExpandsToFull114WithoutTouchingArgentinaOrUserBooks() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuranExpand-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = try ManuscriptVersioningService(rootDirectory: root)

        // Simulate an old install that only seeded Al-Fatihah.
        var stub = try BundleFixtureLoader.loadQuranPickthall()
        stub.chapters = Array(stub.chapters.prefix(1))
        XCTAssertEqual(stub.chapters.count, 1)
        try await service.saveBook(stub)

        let argentinaBefore = try BundleFixtureLoader.loadArgentinaMinimal()
        try await service.saveBook(argentinaBefore)
        let argentinaBytes = try JSONCoding.encoder.encode(try await service.loadBook(id: ArgentinaFixtureIDs.book)!)

        let user = try ManuscriptImporter.importPlainText(
            text: "# Friend paste\nKeep this book.",
            title: "Friend Notes",
            author: "Friend",
            sourceKind: .pastedText
        )
        try await service.saveBook(user)
        let userBytes = try JSONCoding.encoder.encode(try await service.loadBook(id: user.id)!)

        _ = try await BundleFixtureLoader.seedIfNeeded(into: service)

        let quranOptional = try await service.loadBook(id: QuranFixtureIDs.book)
        let quran = try XCTUnwrap(quranOptional)
        XCTAssertEqual(quran.chapters.count, QuranFixtureIDs.expectedSurahCount)
        let verses = quran.chapters.flatMap { $0.activeRevision?.blocks ?? [] }.filter { $0.kind == .paragraph }
        XCTAssertEqual(verses.count, QuranFixtureIDs.expectedVerseCount)
        XCTAssertEqual(quran.chapters.first?.title, "1. The Opening")
        XCTAssertEqual(quran.chapters.last?.title, "114. Mankind")

        let argentinaOptional = try await service.loadBook(id: ArgentinaFixtureIDs.book)
        let userOptional = try await service.loadBook(id: user.id)
        let argentinaAfter = try XCTUnwrap(argentinaOptional)
        let userAfter = try XCTUnwrap(userOptional)
        XCTAssertEqual(try JSONCoding.encoder.encode(argentinaAfter), argentinaBytes)
        XCTAssertEqual(try JSONCoding.encoder.encode(userAfter), userBytes)
    }

    @MainActor
    func testReaderOpenBuildsFullQuranDocumentFromInMemoryChapters() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuranOpen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = try ManuscriptVersioningService(rootDirectory: root)
        let book = try await BundleFixtureLoader.seedBookIfNeeded(
            try BundleFixtureLoader.loadQuranPickthall(),
            into: service
        )
        XCTAssertEqual(book.chapters.count, 114)

        let defaultsSuite = "LivingReaderTests.QuranOpen.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let settings = ReaderSettingsStore(defaults: defaults)
        let model = ReaderViewModel(
            book: book,
            versioning: service,
            checkpoints: try FileReadingCheckpointStore(rootDirectory: root),
            settings: settings,
            annotations: try FileAnnotationStore(rootDirectory: root),
            vocabulary: try FileVocabularyStore(rootDirectory: root),
            bookmarks: try FileBookmarkStore(rootDirectory: root),
            feedbackStore: try FileFeedbackStore(rootDirectory: root),
            preferenceStore: try FileReaderPreferenceStore(rootDirectory: root)
        )
        await model.open()
        XCTAssertTrue(model.isReady)
        XCTAssertEqual(model.chapters.count, 114)
        let doc = try XCTUnwrap(model.document)
        XCTAssertEqual(doc.chapterStarts.count, 114)
        XCTAssertGreaterThan(doc.attributedText.length, 100_000)
        XCTAssertTrue(doc.attributedText.string.contains(QuranFixtureIDs.fatihahOpening))
        XCTAssertTrue(doc.attributedText.string.contains(QuranFixtureIDs.ikhlasOpening))
    }
}
