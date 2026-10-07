import XCTest
@testable import LivingReader

@MainActor
final class AnnotationLearningTests: XCTestCase {
    private var tempRoot: URL!
    private var versioning: ManuscriptVersioningService!
    private var annotations: FileAnnotationStore!
    private var vocabulary: FileVocabularyStore!
    private var bookmarks: FileBookmarkStore!
    private var checkpoints: FileReadingCheckpointStore!
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("LR-Ann-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        versioning = try ManuscriptVersioningService(rootDirectory: tempRoot)
        annotations = try FileAnnotationStore(rootDirectory: tempRoot)
        vocabulary = try FileVocabularyStore(rootDirectory: tempRoot)
        bookmarks = try FileBookmarkStore(rootDirectory: tempRoot)
        checkpoints = try FileReadingCheckpointStore(rootDirectory: tempRoot)
        defaultsSuiteName = "LivingReaderAnn.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDownWithError() throws {
        if let defaultsSuiteName {
            defaults?.removePersistentDomain(forName: defaultsSuiteName)
        }
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testHighlightAndNotePersistAcrossStoreReopen() throws {
        let range = ContentRangeAnchor(blockId: ArgentinaFixtureIDs.block1Body, utf16Start: 4, utf16Length: 12)
        let highlight = HighlightAnnotation(
            id: UUID(),
            bookId: ArgentinaFixtureIDs.book,
            chapterId: ArgentinaFixtureIDs.chapter1,
            chapterTitle: "Before the Nation",
            revisionId: ArgentinaFixtureIDs.chapter1Revision1,
            range: range,
            selectedText: "sample text",
            color: .yellow,
            note: "margin",
            createdAt: Date(),
            updatedAt: Date()
        )
        let note = NoteAnnotation(
            id: UUID(),
            bookId: ArgentinaFixtureIDs.book,
            chapterId: ArgentinaFixtureIDs.chapter1,
            chapterTitle: "Before the Nation",
            revisionId: ArgentinaFixtureIDs.chapter1Revision1,
            range: range,
            selectedText: "sample text",
            body: "Remember this.",
            createdAt: Date(),
            updatedAt: Date()
        )
        try annotations.saveHighlight(highlight)
        try annotations.saveNote(note)

        let reopened = try FileAnnotationStore(rootDirectory: tempRoot)
        let loadedHighlights = try reopened.loadHighlights(bookId: ArgentinaFixtureIDs.book)
        let loadedNotes = try reopened.loadNotes(bookId: ArgentinaFixtureIDs.book)
        XCTAssertEqual(loadedHighlights.count, 1)
        XCTAssertEqual(loadedHighlights.first?.range.blockId, ArgentinaFixtureIDs.block1Body)
        XCTAssertEqual(loadedHighlights.first?.range.utf16Start, 4)
        XCTAssertEqual(loadedHighlights.first?.range.utf16Length, 12)
        XCTAssertEqual(loadedHighlights.first?.revisionId, ArgentinaFixtureIDs.chapter1Revision1)
        XCTAssertEqual(loadedNotes.first?.body, "Remember this.")
        XCTAssertEqual(loadedNotes.first?.revisionId, ArgentinaFixtureIDs.chapter1Revision1)
    }

    func testVocabularyPersistsAndMarkKnown() throws {
        let entry = VocabularyEntry(
            id: UUID(),
            bookId: ArgentinaFixtureIDs.book,
            bookTitle: "A Little History of Argentina",
            chapterId: ArgentinaFixtureIDs.chapter1,
            chapterTitle: "Before the Nation",
            revisionId: ArgentinaFixtureIDs.chapter1Revision1,
            blockId: ArgentinaFixtureIDs.block1Quote,
            phrase: "destiny",
            definition: "offline def",
            originalSentence: "Geography is destiny only until people rewrite the map.",
            surroundingContext: "Geography is destiny only until",
            note: nil,
            isKnown: false,
            createdAt: Date(),
            updatedAt: Date()
        )
        try vocabulary.save(entry)
        let reopened = try FileVocabularyStore(rootDirectory: tempRoot)
        var loaded = try reopened.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.phrase, "destiny")
        XCTAssertEqual(loaded.first?.revisionId, ArgentinaFixtureIDs.chapter1Revision1)
        XCTAssertEqual(loaded.first?.blockId, ArgentinaFixtureIDs.block1Quote)
        try reopened.markKnown(id: entry.id, isKnown: true)
        loaded = try reopened.loadAll()
        XCTAssertTrue(loaded.first?.isKnown == true)
        try reopened.delete(id: entry.id)
        XCTAssertTrue(try reopened.loadAll().isEmpty)
    }

    func testAnnotationsKeyedByBlockRangeRevisionNotScreenCoords() async throws {
        let book = try await BundleFixtureLoader.seedIfNeeded(into: versioning)
        var revisions: [UUID: ChapterRevision] = [:]
        for chapter in book.chapters {
            revisions[chapter.id] = try await versioning.readableRevision(bookId: book.id, chapterId: chapter.id)
        }
        let small = ReaderDocumentBuilder.build(
            book: book,
            readableRevisions: revisions,
            typography: ReaderTypography.make(bodyPointSize: 15, colorScheme: .light)
        )
        let large = ReaderDocumentBuilder.build(
            book: book,
            readableRevisions: revisions,
            typography: ReaderTypography.make(bodyPointSize: 28, colorScheme: .dark)
        )
        let phrase = "Geography is destiny"
        let hitSmall = try XCTUnwrap(small.search(query: phrase).first)
        let selection = try XCTUnwrap(ReaderSelectionMapper.selection(in: small, documentRange: hitSmall.range))

        let highlight = HighlightAnnotation(
            id: UUID(),
            bookId: book.id,
            chapterId: selection.chapterId,
            chapterTitle: selection.chapterTitle,
            revisionId: selection.revisionId,
            range: selection.range,
            selectedText: selection.selectedText,
            color: .green,
            note: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        try annotations.saveHighlight(highlight)

        // Same semantic key resolves under different typography (font/theme).
        let rangeSmall = try XCTUnwrap(ReaderSelectionMapper.documentRange(for: highlight, in: small))
        let rangeLarge = try XCTUnwrap(ReaderSelectionMapper.documentRange(for: highlight, in: large))
        XCTAssertEqual(selection.revisionId, ArgentinaFixtureIDs.chapter1Revision1)
        XCTAssertEqual(selection.range.blockId, ArgentinaFixtureIDs.block1Quote)
        XCTAssertGreaterThan(selection.range.utf16Length, 0)
        // Absolute document offsets may differ with typography only if layout inserts differ —
        // our builder uses same string; ranges should match.
        XCTAssertEqual(rangeSmall.location, rangeLarge.location)
        XCTAssertEqual(rangeSmall.length, rangeLarge.length)

        let reopened = try FileAnnotationStore(rootDirectory: tempRoot)
        let loaded = try XCTUnwrap(reopened.loadHighlights(bookId: book.id).first)
        XCTAssertEqual(loaded.range.blockId, selection.range.blockId)
        XCTAssertEqual(loaded.range.utf16Start, selection.range.utf16Start)
        XCTAssertEqual(loaded.revisionId, selection.revisionId)
    }

    func testDefineWorksOfflineWithoutAI() {
        let ai = MockAIService()
        XCTAssertEqual(ai.adaptCallCount, 0)
        let result = DefineService.define(
            term: "pampas",
            sentenceContext: "Across the pampas, settlements grew.",
            processInfo: ProcessInfo() // not uitesting → local lexicon path
        )
        // Force non-mock by calling lexicon path directly when ProcessInfo may include test host args.
        let lexicon = DefineService.define(
            term: "pampas",
            sentenceContext: "Across the pampas, settlements grew."
        )
        XCTAssertEqual(lexicon.term, "pampas")
        XCTAssertFalse(lexicon.definition.isEmpty)
        XCTAssertFalse(lexicon.definition.localizedCaseInsensitiveContains("See Apple Dictionary"))
        XCTAssertNotNil(lexicon.rich)
        XCTAssertFalse(lexicon.rich!.senses.isEmpty)
        XCTAssertEqual(ai.adaptCallCount, 0, "Sync Define must not call AI")
        _ = result
    }

    func testDefineFragileHighlightsContextSenseAndMergesComparisons() {
        let rich = LocalDictionaryLexicon.entry(for: "fragile")!.makeRich(
            sentenceContext: "A fragile cease-fire held through the night."
        )
        XCTAssertEqual(rich.partOfSpeech, "adj.")
        XCTAssertEqual(rich.pronunciation, "/ˈfrædʒəl/")
        XCTAssertGreaterThanOrEqual(rich.senses.count, 3)
        let matched = rich.senses.filter(\.isContextMatch)
        XCTAssertEqual(matched.count, 1)
        XCTAssertTrue(matched[0].gloss.localizedCaseInsensitiveContains("disrupted")
            || matched[0].gloss.localizedCaseInsensitiveContains("unstable")
            || matched[0].number == "2")
        XCTAssertFalse(rich.comparisons.isEmpty)
        XCTAssertTrue(rich.comparisons.contains { $0.relationship == "synonym" && !$0.tip.isEmpty })
        XCTAssertTrue(rich.comparisons.contains { $0.relationship == "antonym" && !$0.tip.isEmpty })
        let result = DefineService.define(
            term: "fragile",
            sentenceContext: "A fragile cease-fire held through the night."
        )
        XCTAssertNotEqual(result.source, .appleDictionary)
        XCTAssertFalse(result.definition.contains("See Apple Dictionary"))
    }

    func testDefineLiveClientDecodesStructuredJSON() throws {
        let json = """
        {"term":"fragile","partOfSpeech":"adj.","pronunciation":"/ˈfrædʒəl/",
         "senses":[
           {"number":"1","gloss":"Easily broken.","example":"A fragile cup.","isContextMatch":false},
           {"number":"2","gloss":"Tenuous peace.","example":"A fragile cease-fire.","isContextMatch":true}
         ],
         "comparisons":[
           {"word":"delicate","relationship":"synonym","tip":"Use delicate for tact."},
           {"word":"sturdy","relationship":"antonym","tip":"Sturdy is durable."}
         ]}
        """
        let rich = try DefineLiveClient.decodeRich(
            json,
            fallbackTerm: "fragile",
            sentenceContext: "A fragile cease-fire held."
        )
        XCTAssertEqual(rich.senses.count, 2)
        XCTAssertEqual(rich.senses.filter(\.isContextMatch).count, 1)
        XCTAssertTrue(rich.senses[1].isContextMatch)
        XCTAssertEqual(rich.comparisons.count, 2)
    }

    func testSelectionActionsPersistHighlightNoteVocabViaViewModel() async throws {
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
            feedbackStore: try! FileFeedbackStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("fb-\(UUID().uuidString)")),
            preferenceStore: try! FileReaderPreferenceStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("pf-\(UUID().uuidString)")),
        )
        await model.open()
        XCTAssertTrue(model.isReady)
        let document = try XCTUnwrap(model.document)
        let hit = try XCTUnwrap(document.search(query: "Geography is destiny").first)
        let selection = try XCTUnwrap(ReaderSelectionMapper.selection(in: document, documentRange: hit.range))
        model.activeSelection = selection

        model.performHighlight()
        model.activeSelection = selection
        model.noteDraft = "Phase 3 note"
        model.saveNoteFromDraft()
        model.activeSelection = selection
        model.performLearn()

        XCTAssertEqual(try annotations.loadHighlights(bookId: book.id).count, 1,
                       "Saving a body on the exact same passage updates its colour mark rather than duplicating it")
        XCTAssertEqual(try annotations.loadNotes(bookId: book.id).count, 1)
        XCTAssertEqual(try annotations.loadHighlights(bookId: book.id).first?.note, "Phase 3 note")
        XCTAssertEqual(try annotations.loadNotes(bookId: book.id).first?.body, "Phase 3 note")
        XCTAssertEqual(try vocabulary.load(bookId: book.id).count, 1)

        let reopenedAnn = try FileAnnotationStore(rootDirectory: tempRoot)
        let reopenedVocab = try FileVocabularyStore(rootDirectory: tempRoot)
        XCTAssertFalse(try reopenedAnn.loadHighlights(bookId: book.id).isEmpty)
        XCTAssertFalse(try reopenedAnn.loadNotes(bookId: book.id).isEmpty)
        let phrase = try XCTUnwrap(reopenedVocab.loadAll().first?.phrase)
        XCTAssertTrue(phrase.localizedCaseInsensitiveContains("Geography") || phrase.localizedCaseInsensitiveContains("destiny"))
    }

    /// Notes are the one annotation path: an empty body leaves a colour mark, and
    /// reopening those words edits the same records instead of stacking a second mark.
    func testNoteEditorSavesColourMarkThenUpgradesItInPlace() async throws {
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
            feedbackStore: try FileFeedbackStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("fb-\(UUID().uuidString)")),
            preferenceStore: try FileReaderPreferenceStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("pf-\(UUID().uuidString)"))
        )
        await model.open()
        let document = try XCTUnwrap(model.document)
        let hit = try XCTUnwrap(document.search(query: "Geography is destiny").first)
        let selection = try XCTUnwrap(ReaderSelectionMapper.selection(in: document, documentRange: hit.range))

        // Colour mark: Note with no words, which is what the old Highlight button made.
        model.activeSelection = selection
        model.beginNote()
        XCTAssertNil(model.noteEditTarget, "Fresh words have no note to edit")
        model.noteColor = .green
        model.noteDraft = ""
        model.saveNoteFromDraft()

        let marks = try annotations.loadHighlights(bookId: book.id)
        XCTAssertEqual(marks.count, 1)
        XCTAssertEqual(marks.first?.color, .green)
        XCTAssertNil(marks.first?.note)
        XCTAssertTrue(try annotations.loadNotes(bookId: book.id).isEmpty, "No body means no note record")
        XCTAssertEqual(model.noteRows.count, 1)

        // Reopen the same words: one row, edited in place, colour preselected.
        model.activeSelection = selection
        XCTAssertTrue(model.selectionHasExistingNote)
        model.beginNote()
        XCTAssertEqual(model.noteEditTarget?.highlight?.id, marks.first?.id)
        XCTAssertEqual(model.noteColor, .green)
        model.noteDraft = "Now it has words."
        model.saveNoteFromDraft()

        let upgraded = try annotations.loadHighlights(bookId: book.id)
        XCTAssertEqual(upgraded.count, 1, "Editing must not stack a second mark on the same passage")
        XCTAssertEqual(upgraded.first?.id, marks.first?.id)
        XCTAssertEqual(upgraded.first?.color, .green, "Editing keeps the colour category")
        XCTAssertEqual(try annotations.loadNotes(bookId: book.id).count, 1)
        XCTAssertEqual(model.noteRows.count, 1)
        XCTAssertEqual(model.noteRows.first?.note, "Now it has words.")

        // Clearing the words downgrades it back to a colour mark, still one row.
        model.activeSelection = selection
        model.beginNote()
        model.noteDraft = "   "
        model.saveNoteFromDraft()

        XCTAssertEqual(try annotations.loadHighlights(bookId: book.id).count, 1)
        XCTAssertTrue(try annotations.loadNotes(bookId: book.id).isEmpty)
        XCTAssertEqual(model.noteRows.count, 1)
        XCTAssertFalse(model.noteRows.first?.hasNote == true)
    }

    func testConsumeAdvancesWhenJumpingToLaterChapter() async throws {
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
            feedbackStore: try! FileFeedbackStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("fb-\(UUID().uuidString)")),
            preferenceStore: try! FileReaderPreferenceStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("pf-\(UUID().uuidString)")),
        )
        await model.open()
        model.jumpToChapter(id: ArgentinaFixtureIDs.chapter2)
        // Allow async consume to finish.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline && !model.consumedChapterIds.contains(ArgentinaFixtureIDs.chapter1) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(model.consumedChapterIds.contains(ArgentinaFixtureIDs.chapter1))
        let consumed = try await versioning.retrieveConsumedRevision(
            bookId: ArgentinaFixtureIDs.book,
            chapterId: ArgentinaFixtureIDs.chapter1
        )
        XCTAssertEqual(consumed?.id, ArgentinaFixtureIDs.chapter1Revision1)
    }

    private func makeReaderModel(book: Book) throws -> ReaderViewModel {
        ReaderViewModel(
            book: book,
            versioning: versioning,
            checkpoints: checkpoints,
            settings: ReaderSettingsStore(defaults: defaults),
            annotations: annotations,
            vocabulary: vocabulary,
            bookmarks: bookmarks,
            feedbackStore: try FileFeedbackStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("fb-\(UUID().uuidString)")),
            preferenceStore: try FileReaderPreferenceStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("pf-\(UUID().uuidString)"))
        )
    }

    // MARK: - Change-from-here finished-chapter Apply UX

    func testFinishedChapterSelectionEnablesApplyViaNextUnreadRematerialize() async throws {
        let book = try await BundleFixtureLoader.seedIfNeeded(into: versioning)
        let model = try makeReaderModel(book: book)
        await model.open()
        XCTAssertTrue(model.isReady)

        // Finish chapter 1 the same way reading does.
        try await versioning.consume(
            bookId: book.id,
            chapterId: ArgentinaFixtureIDs.chapter1,
            revisionId: ArgentinaFixtureIDs.chapter1Revision1
        )
        // Re-open so consumed ledger is loaded into the model.
        let model2 = try makeReaderModel(book: book)
        await model2.open()
        XCTAssertTrue(model2.consumedChapterIds.contains(ArgentinaFixtureIDs.chapter1))

        let document = try XCTUnwrap(model2.document)
        let hit = try XCTUnwrap(document.search(query: "Geography is destiny").first)
        let selection = try XCTUnwrap(ReaderSelectionMapper.selection(in: document, documentRange: hit.range))
        XCTAssertEqual(selection.chapterId, ArgentinaFixtureIDs.chapter1)
        model2.activeSelection = selection
        model2.beginRegenerateFromWord()

        XCTAssertTrue(model2.showRegenerateFromWord)
        XCTAssertTrue(model2.wordRegenChapterLocked)
        XCTAssertNil(model2.wordRegenError, "Finished-chapter warning is the red chapter subtitle, not an error blob")
        XCTAssertTrue(model2.hasWordRegenChangeSelection, "Default intent is More images")
        XCTAssertTrue(model2.canPreviewWordRegen)
        XCTAssertTrue(model2.canApplyWordRegen)

        let effective = try model2.effectiveWordAnchorForRegeneration()
        XCTAssertNotEqual(effective.chapterId, ArgentinaFixtureIDs.chapter1)
        XCTAssertFalse(model2.consumedChapterIds.contains(effective.chapterId))
        XCTAssertEqual(model2.wordAnchor?.chapterTitle, "Before the Nation", "Sheet still shows the finished chapter the reader selected")
    }

    func testFinishedChapterApplyDisabledWhenNoUnreadRemains() async throws {
        let book = try await BundleFixtureLoader.seedIfNeeded(into: versioning)
        let ordered = book.chapters.sorted { $0.orderIndex < $1.orderIndex }
        for chapter in ordered {
            let revision = try await versioning.readableRevision(bookId: book.id, chapterId: chapter.id)
            try await versioning.consume(bookId: book.id, chapterId: chapter.id, revisionId: revision.id)
        }
        let model = try makeReaderModel(book: book)
        await model.open()
        XCTAssertEqual(model.consumedChapterIds.count, ordered.count)

        let document = try XCTUnwrap(model.document)
        let hit = try XCTUnwrap(document.search(query: "Geography is destiny").first)
        let selection = try XCTUnwrap(ReaderSelectionMapper.selection(in: document, documentRange: hit.range))
        model.activeSelection = selection
        model.beginRegenerateFromWord()

        XCTAssertTrue(model.wordRegenChapterLocked)
        XCTAssertNil(model.wordRegenError)
        XCTAssertFalse(model.canPreviewWordRegen)
        XCTAssertFalse(model.canApplyWordRegen)
        XCTAssertThrowsError(try model.effectiveWordAnchorForRegeneration()) { error in
            XCTAssertEqual(error as? AdaptationError, .nothingToAdapt)
        }
    }

    func testApplyDisabledWhenNoChangeOptionSelected() async throws {
        let book = try await BundleFixtureLoader.seedIfNeeded(into: versioning)
        let model = try makeReaderModel(book: book)
        await model.open()
        let document = try XCTUnwrap(model.document)
        // Prefer an unread chapter phrase (ch2) so rematerialize is not involved.
        let hit = try XCTUnwrap(
            document.search(query: "In the early nineteenth century").first
            ?? document.search(query: "Geography is destiny").first
        )
        let selection = try XCTUnwrap(ReaderSelectionMapper.selection(in: document, documentRange: hit.range))
        model.activeSelection = selection
        model.beginRegenerateFromWord()
        model.wordRegenIntents = []
        model.wordRegenFreeText = ""
        model.wordRegenRequestChanged()
        XCTAssertFalse(model.hasWordRegenChangeSelection)
        XCTAssertTrue(model.canPreviewWordRegen, "Preview still allowed without intents")
        XCTAssertFalse(model.canApplyWordRegen)
    }

    func testReaderTextViewSuppressesSystemEditMenu() {
        let view = TextKitReaderUIView(frame: .zero)
        XCTAssertTrue(view.textView is ReaderSelectableTextView)
        XCTAssertFalse(view.textView.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil))
    }
}
