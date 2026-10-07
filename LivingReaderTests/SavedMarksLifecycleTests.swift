import XCTest
@testable import LivingReader

final class SavedMarksLifecycleTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SavedMarksTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    private func row() -> NoteRow {
        NoteRow(id: UUID(), bookId: UUID(), chapterId: UUID(), chapterTitle: "A saved passage",
                revisionId: UUID(), range: ContentRangeAnchor(blockId: UUID(), utf16Start: 4, utf16Length: 12),
                selectedText: "A full passage", color: .yellow, note: nil, createdAt: Date())
    }

    func testSaveEditClearBodyDeleteAndReopenAreOneNoteLifecycle() throws {
        let store = try FileAnnotationStore(rootDirectory: root)
        let passage = row()
        let manuscript = root.appendingPathComponent("unchanged-consumed-manuscript.json")
        let manuscriptBytes = Data("Immutable reader text and history".utf8)
        try manuscriptBytes.write(to: manuscript)

        try store.saveNotePassage(passage, body: "", color: .green)
        XCTAssertEqual(try store.loadHighlights(bookId: passage.bookId).count, 1)
        XCTAssertTrue(try store.loadNotes(bookId: passage.bookId).isEmpty)
        try store.saveNotePassage(passage, body: "  Remember this.  ", color: .pink)
        let reopened = try FileAnnotationStore(rootDirectory: root)
        let highlight = try XCTUnwrap(reopened.loadHighlights(bookId: passage.bookId).first)
        let note = try XCTUnwrap(reopened.loadNotes(bookId: passage.bookId).first)
        XCTAssertEqual(highlight.id, passage.id)
        XCTAssertEqual(highlight.color, .pink)
        XCTAssertEqual(highlight.note, "Remember this.")
        XCTAssertEqual(note.body, "Remember this.")

        try reopened.saveNotePassage(passage, body: "Updated thought", color: .blue)
        XCTAssertEqual(try reopened.loadNotes(bookId: passage.bookId).first?.id, note.id)
        XCTAssertEqual(try reopened.loadNotes(bookId: passage.bookId).count, 1)
        try reopened.saveNotePassage(passage, body: " \n ", color: .green)
        XCTAssertTrue(try reopened.loadNotes(bookId: passage.bookId).isEmpty)
        XCTAssertNil(try reopened.loadHighlights(bookId: passage.bookId).first?.note)
        try reopened.deleteNotePassage(passage)
        let finalStore = try FileAnnotationStore(rootDirectory: root)
        XCTAssertTrue(try finalStore.loadHighlights(bookId: passage.bookId).isEmpty)
        XCTAssertTrue(try finalStore.loadNotes(bookId: passage.bookId).isEmpty)
        XCTAssertEqual(try Data(contentsOf: manuscript), manuscriptBytes)
    }

    func testDeleteRemovesBothLegacyHalvesAndExactDuplicatesButNotOverlappingNotes() throws {
        let store = try FileAnnotationStore(rootDirectory: root)
        let passage = row()
        try store.saveNotePassage(passage, body: "Target", color: .yellow)
        var duplicate = try XCTUnwrap(store.loadHighlights(bookId: passage.bookId).first)
        duplicate.id = UUID()
        try store.saveHighlight(duplicate)
        var neighbour = passage
        neighbour.id = UUID()
        neighbour.range.utf16Start += 1
        neighbour.selectedText = "Overlapping but separate"
        try store.saveNotePassage(neighbour, body: "Keep neighbour", color: .green)
        var otherRevision = passage
        otherRevision.id = UUID()
        otherRevision.revisionId = UUID()
        try store.saveNotePassage(otherRevision, body: "Keep revision", color: .pink)
        try store.deleteNotePassage(passage)
        let reopened = try FileAnnotationStore(rootDirectory: root)
        XCTAssertEqual(try reopened.loadHighlights(bookId: passage.bookId).count, 2)
        XCTAssertEqual(Set(try reopened.loadNotes(bookId: passage.bookId).map(\.body)), ["Keep neighbour", "Keep revision"])
    }

    func testLegacyBodyOnlyNoteCanBeEditedAndDeletedWithoutChangingItsRange() throws {
        let store = try FileAnnotationStore(rootDirectory: root)
        let passage = row()
        let note = NoteAnnotation(id: passage.id, bookId: passage.bookId, chapterId: passage.chapterId,
                                  chapterTitle: passage.chapterTitle, revisionId: passage.revisionId,
                                  range: passage.range, selectedText: passage.selectedText,
                                  body: "Legacy body", createdAt: passage.createdAt, updatedAt: Date())
        try store.saveNote(note)
        let target = try XCTUnwrap(NoteEditTarget(highlight: nil, note: note).row)
        XCTAssertEqual(target.range, passage.range)
        try store.saveNotePassage(target, body: "Edited legacy", color: .green)
        XCTAssertEqual(try store.loadNotes(bookId: passage.bookId).first?.id, note.id)
        try store.deleteNotePassage(target)
        XCTAssertTrue(try store.loadAllHighlights().isEmpty)
        XCTAssertTrue(try store.loadAllNotes().isEmpty)
    }

    func testSamePassageIdentifiersInTwoBooksStayDistinctAndDeleteIsBookScoped() throws {
        let store = try FileAnnotationStore(rootDirectory: root)
        let first = row()
        var second = first
        second.bookId = UUID()
        try store.saveNotePassage(first, body: "First book", color: .green)
        try store.saveNotePassage(second, body: "Second book", color: .blue)
        let rows = NoteRowBuilder.rows(highlights: try store.loadAllHighlights(), notes: try store.loadAllNotes())
        XCTAssertEqual(rows.count, 2)
        try store.deleteNotePassage(first)
        XCTAssertEqual(try store.loadNotes(bookId: second.bookId).first?.body, "Second book")
    }

    func testSelectingInsideColourMarkDoesNotBorrowDifferentOverlappingNoteBody() throws {
        let store = try FileAnnotationStore(rootDirectory: root)
        let passage = row()
        try store.saveNotePassage(passage, body: "", color: .green)
        let separate = NoteAnnotation(id: UUID(), bookId: passage.bookId, chapterId: passage.chapterId,
                                     chapterTitle: passage.chapterTitle, revisionId: passage.revisionId,
                                     range: ContentRangeAnchor(blockId: passage.range.blockId, utf16Start: 5, utf16Length: 3),
                                     selectedText: "other", body: "Different note", createdAt: Date(), updatedAt: Date())
        try store.saveNote(separate)
        let target = try XCTUnwrap(NoteRowBuilder.target(
            highlights: try store.loadHighlights(bookId: passage.bookId), notes: try store.loadNotes(bookId: passage.bookId),
            overlapping: separate.range, chapterId: passage.chapterId, revisionId: passage.revisionId))
        XCTAssertNil(target.note)
        XCTAssertEqual(target.row?.range, passage.range)
        XCTAssertEqual(target.body, "")
    }

    func testMalformedAnnotationPayloadRefusesSaveAndDeleteWithoutReplacingBytes() throws {
        let store = try FileAnnotationStore(rootDirectory: root)
        let passage = row()
        let path = store.directory.appendingPathComponent("\(passage.bookId.uuidString).json")
        let bytes = Data("test-created malformed annotation payload".utf8)
        try bytes.write(to: path)
        XCTAssertThrowsError(try store.saveNotePassage(passage, body: "Do not replace", color: .pink))
        XCTAssertThrowsError(try store.deleteNotePassage(passage))
        XCTAssertEqual(try Data(contentsOf: path), bytes)
    }

    func testWordsKnownAndDeletePersistAndPreserveOtherWord() throws {
        let store = try FileVocabularyStore(rootDirectory: root)
        let first = word("First"), second = word("Second")
        try store.save(first)
        try store.save(second)
        try store.markKnown(id: first.id, isKnown: true)
        let reopened = try FileVocabularyStore(rootDirectory: root)
        XCTAssertTrue(try XCTUnwrap(reopened.loadAll().first { $0.id == first.id }).isKnown)
        try reopened.markKnown(id: first.id, isKnown: false)
        try reopened.delete(id: first.id)
        XCTAssertEqual(try FileVocabularyStore(rootDirectory: root).loadAll(), [second])
    }

    func testMalformedWordsRefusesKnownAndDeleteWithoutReplacingBytes() throws {
        let store = try FileVocabularyStore(rootDirectory: root)
        let file = store.directory.appendingPathComponent("vocabulary.json")
        let bytes = Data("test-created malformed vocabulary payload".utf8)
        try bytes.write(to: file)
        XCTAssertThrowsError(try store.markKnown(id: UUID(), isKnown: true))
        XCTAssertThrowsError(try store.delete(id: UUID()))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testNewerLegacyBodyKeepsItsCompanionMarksChosenColor() throws {
        let passage = row()
        let highlight = HighlightAnnotation(id: UUID(), bookId: passage.bookId, chapterId: passage.chapterId,
                                            chapterTitle: passage.chapterTitle, revisionId: passage.revisionId,
                                            range: passage.range, selectedText: passage.selectedText,
                                            color: .green, note: nil, createdAt: Date(timeIntervalSince1970: 1000),
                                            updatedAt: Date(timeIntervalSince1970: 1000))
        let note = NoteAnnotation(id: UUID(), bookId: passage.bookId, chapterId: passage.chapterId,
                                  chapterTitle: passage.chapterTitle, revisionId: passage.revisionId,
                                  range: passage.range, selectedText: passage.selectedText, body: "Added later",
                                  createdAt: Date(timeIntervalSince1970: 2000), updatedAt: Date(timeIntervalSince1970: 2000))
        let merged = try XCTUnwrap(NoteRowBuilder.rows(highlights: [highlight], notes: [note]).first)
        XCTAssertEqual(merged.color, .green)
        XCTAssertEqual(merged.note, "Added later")
        XCTAssertEqual(merged.id, note.id)
    }

    @MainActor
    func testReaderSaveFailureKeepsEditorDraftAndDoesNotReplaceDamagedPayload() async throws {
        let (model, annotations) = try await readerModel()
        model.beginNote()
        model.noteDraft = "Do not lose this typed thought"
        let file = annotations.directory.appendingPathComponent("\(model.book.id.uuidString).json")
        let bytes = Data("deliberately malformed test annotations".utf8)
        try bytes.write(to: file)
        XCTAssertThrowsError(try model.saveNoteFromEditor())
        XCTAssertTrue(model.showNoteEditor)
        XCTAssertEqual(model.noteDraft, "Do not lose this typed thought")
        XCTAssertNil(model.noteEditTarget)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    @MainActor
    func testReaderDeleteFailureRetainsEditorAndTargetThenCanRetrySuccessfully() async throws {
        let (model, annotations) = try await readerModel()
        model.beginNote()
        model.noteDraft = "Saved before failure"
        try model.saveNoteFromEditor()
        model.beginNote()
        let target = try XCTUnwrap(model.noteEditTarget)
        let file = annotations.directory.appendingPathComponent("\(model.book.id.uuidString).json")
        let savedBytes = try Data(contentsOf: file)
        let brokenBytes = Data("deliberately malformed test annotations".utf8)
        try brokenBytes.write(to: file)
        XCTAssertThrowsError(try model.deleteEditingNote())
        XCTAssertTrue(model.showNoteEditor)
        XCTAssertEqual(model.noteEditTarget, target)
        XCTAssertEqual(model.noteDraft, "Saved before failure")
        XCTAssertEqual(try Data(contentsOf: file), brokenBytes)
        // Repair only this test-owned fixture, then exercise the user's Retry path.
        try savedBytes.write(to: file)
        try model.deleteEditingNote()
        XCTAssertFalse(model.showNoteEditor)
        XCTAssertNil(model.noteEditTarget)
        XCTAssertTrue(try annotations.loadAllHighlights().isEmpty)
        XCTAssertTrue(try annotations.loadAllNotes().isEmpty)
    }

    @MainActor
    private func readerModel() async throws -> (ReaderViewModel, FileAnnotationStore) {
        let versioning = try ManuscriptVersioningService(rootDirectory: root)
        let book = try await BundleFixtureLoader.seedIfNeeded(into: versioning)
        let annotations = try FileAnnotationStore(rootDirectory: root)
        let suiteName = "SavedMarksReaderTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let model = ReaderViewModel(
            book: book, versioning: versioning,
            checkpoints: try FileReadingCheckpointStore(rootDirectory: root),
            settings: ReaderSettingsStore(defaults: defaults), annotations: annotations,
            vocabulary: try FileVocabularyStore(rootDirectory: root),
            bookmarks: try FileBookmarkStore(rootDirectory: root),
            feedbackStore: try FileFeedbackStore(directory: root.appendingPathComponent("Feedback")),
            preferenceStore: try FileReaderPreferenceStore(directory: root.appendingPathComponent("Preferences"))
        )
        await model.open()
        let document = try XCTUnwrap(model.document)
        let hit = try XCTUnwrap(document.search(query: "Geography is destiny").first)
        model.activeSelection = try XCTUnwrap(ReaderSelectionMapper.selection(in: document, documentRange: hit.range))
        return (model, annotations)
    }

    private func word(_ phrase: String) -> VocabularyEntry {
        VocabularyEntry(id: UUID(), bookId: UUID(), bookTitle: "Test book", chapterId: UUID(), chapterTitle: "Test chapter",
                        revisionId: UUID(), blockId: UUID(), phrase: phrase, definition: "Definition", originalSentence: phrase,
                        surroundingContext: "", note: nil, isKnown: false,
                        createdAt: Date(timeIntervalSince1970: 1_000), updatedAt: Date(timeIntervalSince1970: 1_000))
    }
}
