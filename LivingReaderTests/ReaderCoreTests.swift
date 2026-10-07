import XCTest
@testable import LivingReader

@MainActor
final class ReaderCoreTests: XCTestCase {
    private var tempRoot: URL!
    private var versioning: ManuscriptVersioningService!
    private var checkpoints: FileReadingCheckpointStore!
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("LR-Reader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        versioning = try ManuscriptVersioningService(rootDirectory: tempRoot)
        checkpoints = try FileReadingCheckpointStore(rootDirectory: tempRoot)
        defaultsSuiteName = "LivingReaderTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDownWithError() throws {
        if let defaultsSuiteName {
            defaults?.removePersistentDomain(forName: defaultsSuiteName)
        }
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testDocumentBuildsContinuousFlowWithChapterBoundaries() async throws {
        let book = try await BundleFixtureLoader.seedIfNeeded(into: versioning)
        var revisions: [UUID: ChapterRevision] = [:]
        for chapter in book.chapters {
            revisions[chapter.id] = try await versioning.readableRevision(bookId: book.id, chapterId: chapter.id)
        }
        let doc = ReaderDocumentBuilder.build(
            book: book,
            readableRevisions: revisions,
            typography: ReaderTypography.make(bodyPointSize: 19, colorScheme: .dark)
        )
        XCTAssertGreaterThan(doc.length, 100)
        XCTAssertGreaterThanOrEqual(doc.chapterStarts.count, 2)
        XCTAssertEqual(doc.chapterStarts[0].title, "Before the Nation")
        XCTAssertEqual(doc.chapterStarts[1].title, "Independence Sparks")
        XCTAssertGreaterThanOrEqual(doc.anchors.count, 5)
        // Chapter 2 starts after chapter 1 content
        XCTAssertGreaterThan(doc.chapterStarts[1].utf16Location, doc.chapterStarts[0].utf16Location)
    }

    func testSearchFindsKnownFixtureText() async throws {
        let book = try await BundleFixtureLoader.seedIfNeeded(into: versioning)
        var revisions: [UUID: ChapterRevision] = [:]
        for chapter in book.chapters {
            revisions[chapter.id] = try await versioning.readableRevision(bookId: book.id, chapterId: chapter.id)
        }
        let doc = ReaderDocumentBuilder.build(
            book: book,
            readableRevisions: revisions,
            typography: ReaderTypography.make(bodyPointSize: 19, colorScheme: .dark)
        )
        let hits = doc.search(query: ArgentinaFixtureIDs.searchablePhrase)
        XCTAssertFalse(hits.isEmpty, "Expected to find fixture quote")
        XCTAssertEqual(hits.first?.chapterId, ArgentinaFixtureIDs.chapter1)
        XCTAssertEqual(hits.first?.blockId, ArgentinaFixtureIDs.block1Quote)
    }

    func testPositionSaveAndRestoreExactBlockOffset() throws {
        let location = ReaderLocation(
            chapterId: ArgentinaFixtureIDs.chapter1,
            blockId: ArgentinaFixtureIDs.block1Body,
            characterOffset: 37,
            progress: 0.22
        )
        let checkpoint = ReadingCheckpoint.from(location: location, bookId: ArgentinaFixtureIDs.book)
        try checkpoints.saveCheckpoint(checkpoint)

        let reopened = try FileReadingCheckpointStore(rootDirectory: tempRoot)
        let loaded = try reopened.loadCheckpoint(bookId: ArgentinaFixtureIDs.book)
        XCTAssertEqual(loaded?.blockId, ArgentinaFixtureIDs.block1Body)
        XCTAssertEqual(loaded?.chapterId, ArgentinaFixtureIDs.chapter1)
        XCTAssertEqual(loaded?.characterOffset, 37)
        XCTAssertEqual(loaded?.asLocation()?.blockId, location.blockId)
    }

    func testLocationRoundTripThroughDocument() async throws {
        let book = try await BundleFixtureLoader.seedIfNeeded(into: versioning)
        var revisions: [UUID: ChapterRevision] = [:]
        for chapter in book.chapters {
            revisions[chapter.id] = try await versioning.readableRevision(bookId: book.id, chapterId: chapter.id)
        }
        let doc = ReaderDocumentBuilder.build(
            book: book,
            readableRevisions: revisions,
            typography: ReaderTypography.make(bodyPointSize: 19, colorScheme: .dark)
        )
        let target = ReaderLocation(
            chapterId: ArgentinaFixtureIDs.chapter2,
            blockId: ArgentinaFixtureIDs.block2Body,
            characterOffset: 12,
            progress: 0.5
        )
        let utf16 = try XCTUnwrap(doc.utf16Location(for: target))
        let restored = try XCTUnwrap(doc.location(atUtf16: utf16, visibleProgress: 0.5))
        XCTAssertEqual(restored.blockId, target.blockId)
        XCTAssertEqual(restored.chapterId, target.chapterId)
        XCTAssertEqual(restored.characterOffset, target.characterOffset)
    }

    func testDocumentProgressIsUtf16FractionNotAnArbitraryViewport() async throws {
        let book = try await BundleFixtureLoader.seedIfNeeded(into: versioning)
        var revisions: [UUID: ChapterRevision] = [:]
        for chapter in book.chapters {
            revisions[chapter.id] = try await versioning.readableRevision(bookId: book.id, chapterId: chapter.id)
        }
        let doc = ReaderDocumentBuilder.build(
            book: book,
            readableRevisions: revisions,
            typography: ReaderTypography.make(bodyPointSize: 19, colorScheme: .dark)
        )
        XCTAssertGreaterThan(doc.length, 2)
        let mid = doc.length / 2
        XCTAssertEqual(doc.progressFraction(atUtf16: mid), Double(mid) / Double(doc.length - 1), accuracy: 0.0001)
        XCTAssertEqual(doc.utf16Location(forProgress: 0), 0)
        XCTAssertEqual(doc.utf16Location(forProgress: 1), doc.length - 1)

        let fromFraction = try XCTUnwrap(doc.location(atUtf16: mid))
        XCTAssertEqual(fromFraction.progress, doc.progressFraction(atUtf16: mid), accuracy: 0.0001)
        // An explicit viewport override must not become the default.
        let overridden = try XCTUnwrap(doc.location(atUtf16: mid, visibleProgress: 0.99))
        XCTAssertEqual(overridden.progress, 0.99, accuracy: 0.0001)
        XCTAssertEqual(overridden.blockId, fromFraction.blockId)
    }

    func testThemeAndFontSettingsPersist() {
        let store = ReaderSettingsStore(defaults: defaults)
        store.fontSize = 24
        store.colorScheme = .light

        let reopened = ReaderSettingsStore(defaults: defaults)
        XCTAssertEqual(reopened.fontSize, 24)
        XCTAssertEqual(reopened.colorScheme, .light)
        XCTAssertEqual(reopened.swiftUIColorScheme, .light)
    }

    func testTOCChapterJumpLocation() async throws {
        let book = try await BundleFixtureLoader.seedIfNeeded(into: versioning)
        var revisions: [UUID: ChapterRevision] = [:]
        for chapter in book.chapters {
            revisions[chapter.id] = try await versioning.readableRevision(bookId: book.id, chapterId: chapter.id)
        }
        let doc = ReaderDocumentBuilder.build(
            book: book,
            readableRevisions: revisions,
            typography: ReaderTypography.make(bodyPointSize: 19, colorScheme: .dark)
        )
        let chapter2Start = try XCTUnwrap(doc.chapterStarts.first { $0.chapterId == ArgentinaFixtureIDs.chapter2 })
        let location = try XCTUnwrap(doc.location(atUtf16: chapter2Start.utf16Location, visibleProgress: 0.6))
        XCTAssertEqual(location.chapterId, ArgentinaFixtureIDs.chapter2)
        XCTAssertEqual(location.blockId, ArgentinaFixtureIDs.block2Heading)
    }

    func testOfflineOpenMockAICallCountZero() async throws {
        let ai = MockAIService()
        // Bump call count via adapt, then open() must reset and stay at 0 (AI not on critical path).
        _ = try await ai.adaptChapter(chapterId: UUID(), promptContext: "warmup")
        XCTAssertEqual(ai.adaptCallCount, 1)
        let book = try await BundleFixtureLoader.seedIfNeeded(into: versioning)
        let settings = ReaderSettingsStore(defaults: defaults)
        let annotations = try FileAnnotationStore(rootDirectory: tempRoot)
        let vocabulary = try FileVocabularyStore(rootDirectory: tempRoot)
        let model = ReaderViewModel(
            book: book,
            versioning: versioning,
            checkpoints: checkpoints,
            settings: settings,
            annotations: annotations,
            vocabulary: vocabulary,
            bookmarks: try FileBookmarkStore(rootDirectory: tempRoot),
            feedbackStore: try! FileFeedbackStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("fb-\(UUID().uuidString)")),
            preferenceStore: try! FileReaderPreferenceStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("pf-\(UUID().uuidString)")),
            ai: ai
        )
        await model.open()
        XCTAssertEqual(model.aiAdaptCallCountAtOpen, 0)
        XCTAssertTrue(model.isReady)
        XCTAssertNotNil(model.document)
        XCTAssertNil(model.loadError)
    }

    func testReaderOpenRestoresSavedCheckpoint() async throws {
        let book = try await BundleFixtureLoader.seedIfNeeded(into: versioning)
        let saved = ReadingCheckpoint(
            id: UUID(),
            bookId: book.id,
            chapterId: ArgentinaFixtureIDs.chapter2,
            blockId: ArgentinaFixtureIDs.block2Body,
            characterOffset: 8,
            updatedAt: Date()
        )
        try checkpoints.saveCheckpoint(saved)

        let settings = ReaderSettingsStore(defaults: defaults)
        let annotations = try FileAnnotationStore(rootDirectory: tempRoot)
        let vocabulary = try FileVocabularyStore(rootDirectory: tempRoot)
        let model = ReaderViewModel(
            book: book,
            versioning: versioning,
            checkpoints: checkpoints,
            settings: settings,
            annotations: annotations,
            vocabulary: vocabulary,
            bookmarks: try FileBookmarkStore(rootDirectory: tempRoot),
            feedbackStore: try! FileFeedbackStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("fb-\(UUID().uuidString)")),
            preferenceStore: try! FileReaderPreferenceStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("pf-\(UUID().uuidString)")),
        )
        await model.open()
        XCTAssertEqual(model.restoreLocation?.blockId, ArgentinaFixtureIDs.block2Body)
        XCTAssertEqual(model.restoreLocation?.characterOffset, 8)
        XCTAssertEqual(model.restoreLocation?.chapterId, ArgentinaFixtureIDs.chapter2)
    }
}
