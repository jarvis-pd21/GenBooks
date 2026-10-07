import XCTest
@testable import LivingReader

/// Highlight and Note were never two features: saving a note already writes a companion
/// highlight. These tests pin the read-time merge that makes one passage produce one row.
final class NoteRowMergeTests: XCTestCase {
    private let bookId = UUID()
    private let chapterId = UUID()
    private let revisionId = UUID()
    private let blockId = UUID()

    private func anchor(start: Int = 0, length: Int = 12) -> ContentRangeAnchor {
        ContentRangeAnchor(blockId: blockId, utf16Start: start, utf16Length: length)
    }

    private func highlight(
        id: UUID = UUID(),
        range: ContentRangeAnchor? = nil,
        text: String = "Before the Nation",
        color: HighlightColor = .yellow,
        note: String? = nil,
        createdAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> HighlightAnnotation {
        HighlightAnnotation(
            id: id,
            bookId: bookId,
            chapterId: chapterId,
            chapterTitle: "Before the Nation",
            revisionId: revisionId,
            range: range ?? anchor(),
            selectedText: text,
            color: color,
            note: note,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }

    private func note(
        id: UUID = UUID(),
        range: ContentRangeAnchor? = nil,
        text: String = "Before the Nation",
        body: String = "Remember this.",
        createdAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> NoteAnnotation {
        NoteAnnotation(
            id: id,
            bookId: bookId,
            chapterId: chapterId,
            chapterTitle: "Before the Nation",
            revisionId: revisionId,
            range: range ?? anchor(),
            selectedText: text,
            body: body,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }

    func testNotedPassageProducesOneRowCarryingTheNote() {
        // What `saveNoteFromDraft` writes: a note plus its companion highlight.
        let companion = highlight(color: .blue, note: "Remember this.")
        let rows = NoteRowBuilder.rows(highlights: [companion], notes: [note()])

        XCTAssertEqual(rows.count, 1, "One passage must not be listed twice")
        XCTAssertEqual(rows.first?.note, "Remember this.")
        XCTAssertTrue(rows.first?.hasNote == true)
    }

    func testPlainHighlightAndNoteOnTheSamePassageCollapseIntoTheNotedRow() {
        let plain = highlight(id: UUID(), note: nil)
        let companion = highlight(id: UUID(), color: .blue, note: "Margin thought.")

        let rows = NoteRowBuilder.rows(highlights: [plain, companion], notes: [])

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.id, companion.id, "The noted record owns the row, so the note survives")
        XCTAssertEqual(rows.first?.note, "Margin thought.")
    }

    func testNoteWithoutACompanionHighlightStillGetsARow() {
        // Notes written before companion highlights existed, and the Phase 3 demo seed.
        let rows = NoteRowBuilder.rows(highlights: [], notes: [note(body: "Legacy note.")])

        XCTAssertEqual(rows.count, 1, "Legacy notes must not disappear from the merged surface")
        XCTAssertEqual(rows.first?.note, "Legacy note.")
    }

    func testSeededDemoHighlightAndNoteMergeOntoOneRow() {
        // `LibraryViewModel.seedDemoAnnotations` reuses one range for both records.
        let seededHighlight = highlight(note: nil)
        let seededNote = note(body: "Demo note for Phase 3 screenshots.")

        let rows = NoteRowBuilder.rows(highlights: [seededHighlight], notes: [seededNote])

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.note, "Demo note for Phase 3 screenshots.")
    }

    func testDistinctPassagesStayDistinct() {
        let first = highlight(range: anchor(start: 0, length: 12), text: "first")
        let second = highlight(range: anchor(start: 40, length: 9), text: "second")

        let rows = NoteRowBuilder.rows(highlights: [first, second], notes: [])

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.selectedText)), ["first", "second"])
    }

    func testHighlightsOnDifferentRevisionsOfTheSameBlockStayDistinct() {
        var regenerated = highlight(text: "rewritten")
        regenerated.revisionId = UUID()

        let rows = NoteRowBuilder.rows(highlights: [highlight(), regenerated], notes: [])

        XCTAssertEqual(rows.count, 2, "A regenerated revision is a different passage")
    }

    func testRowsAreNewestFirstAndALaterNoteFloatsItsPassageUp() {
        let older = highlight(range: anchor(start: 0, length: 5), text: "older", createdAt: Date(timeIntervalSince1970: 1_000))
        let newer = highlight(range: anchor(start: 50, length: 5), text: "newer", createdAt: Date(timeIntervalSince1970: 2_000))
        let lateNote = note(range: anchor(start: 0, length: 5), text: "older", body: "Added later.", createdAt: Date(timeIntervalSince1970: 3_000))

        let rows = NoteRowBuilder.rows(highlights: [older, newer], notes: [lateNote])

        XCTAssertEqual(rows.map(\.selectedText), ["older", "newer"])
        XCTAssertEqual(rows.first?.note, "Added later.")
    }

    func testWhitespaceOnlyNoteIsNotTreatedAsANote() {
        let rows = NoteRowBuilder.rows(highlights: [highlight(note: "   \n ")], notes: [])

        XCTAssertEqual(rows.count, 1)
        XCTAssertFalse(rows.first?.hasNote == true, "A blank note must not earn a NOTE badge")
    }

    func testEmptyStoresProduceNoRows() {
        XCTAssertTrue(NoteRowBuilder.rows(highlights: [], notes: []).isEmpty)
    }

    func testColourOnlyNoteIsARowWithItsCategoryAndNoBody() {
        let mark = highlight(color: .green, note: nil)

        let rows = NoteRowBuilder.rows(highlights: [mark], notes: [])

        XCTAssertEqual(rows.count, 1, "A colour mark is a note with no words, not a second feature")
        XCTAssertEqual(rows.first?.color, .green)
        XCTAssertFalse(rows.first?.hasNote == true)
    }

    // MARK: - Editing target

    func testTargetFindsBothRecordsOnAnOverlappingSelection() {
        let existingHighlight = highlight(range: anchor(start: 10, length: 20), color: .pink, note: "Thought.")
        let existingNote = note(range: anchor(start: 10, length: 20), body: "Thought.")

        let target = NoteRowBuilder.target(
            highlights: [existingHighlight],
            notes: [existingNote],
            overlapping: anchor(start: 18, length: 3),
            chapterId: chapterId,
            revisionId: revisionId
        )

        XCTAssertEqual(target?.highlight?.id, existingHighlight.id, "Re-selecting part of a note must edit it, not stack a second mark")
        XCTAssertEqual(target?.note?.id, existingNote.id)
        XCTAssertEqual(target?.body, "Thought.")
        XCTAssertEqual(target?.color, .pink)
    }

    func testTargetFindsAColourMarkThatHasNoBodyYet() {
        let mark = highlight(range: anchor(start: 0, length: 12), color: .blue, note: nil)

        let target = NoteRowBuilder.target(
            highlights: [mark],
            notes: [],
            overlapping: anchor(start: 4, length: 2),
            chapterId: chapterId,
            revisionId: revisionId
        )

        XCTAssertEqual(target?.highlight?.id, mark.id)
        XCTAssertNil(target?.note)
        XCTAssertEqual(target?.body, "")
        XCTAssertEqual(target?.color, .blue, "Reopening a mark must preselect the colour it already has")
    }

    func testTargetIgnoresANonOverlappingSelection() {
        let elsewhere = highlight(range: anchor(start: 0, length: 5))

        XCTAssertNil(
            NoteRowBuilder.target(
                highlights: [elsewhere],
                notes: [],
                overlapping: anchor(start: 40, length: 5),
                chapterId: chapterId,
                revisionId: revisionId
            )
        )
    }

    func testTargetIgnoresAdjacentButNonTouchingRanges() {
        let earlier = highlight(range: anchor(start: 0, length: 5))

        XCTAssertNil(
            NoteRowBuilder.target(
                highlights: [earlier],
                notes: [],
                overlapping: anchor(start: 5, length: 4),
                chapterId: chapterId,
                revisionId: revisionId
            ),
            "A selection starting where a mark ends is a different passage"
        )
    }

    func testTargetIgnoresADifferentRevisionOfTheSameBlock() {
        var stale = highlight(range: anchor(start: 0, length: 12))
        stale.revisionId = UUID()

        XCTAssertNil(
            NoteRowBuilder.target(
                highlights: [stale],
                notes: [],
                overlapping: anchor(start: 0, length: 12),
                chapterId: chapterId,
                revisionId: revisionId
            )
        )
    }

    func testTargetIsNilWhenNothingIsMarked() {
        XCTAssertNil(
            NoteRowBuilder.target(
                highlights: [],
                notes: [],
                overlapping: anchor(),
                chapterId: chapterId,
                revisionId: revisionId
            )
        )
    }
}
