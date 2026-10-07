import XCTest
import UIKit
@testable import LivingReader

@MainActor
final class SelectionClipboardTests: XCTestCase {
    func testCopiesExactUnicodeAndMultilineSelection() {
        withIsolatedPasteboard { pasteboard in
            let selectedText = "San Martín — cafe\u{301} 🇦🇷\n家族 👨‍👩‍👧‍👦\nالعالم"

            XCTAssertTrue(SelectionClipboard.copy(selectedText, to: pasteboard))
            XCTAssertEqual(pasteboard.string, selectedText)
            // String equality alone ignores some Unicode normalization differences.
            XCTAssertEqual(pasteboard.string.map { Array($0.utf8) }, Array(selectedText.utf8))
        }
    }

    func testPreservesLeadingTrailingAndWhitespaceOnlySelections() {
        withIsolatedPasteboard { pasteboard in
            for selectedText in [" \tselected passage\n\n ", " \t\n"] {
                XCTAssertTrue(SelectionClipboard.copy(selectedText, to: pasteboard))
                XCTAssertEqual(pasteboard.string, selectedText, "Copy must not trim the selection")
            }
        }
    }

    func testDoesNotAddDisplayQuotesOrChapterContext() {
        withIsolatedPasteboard { pasteboard in
            let selectedText = "Geography is destiny"

            XCTAssertTrue(SelectionClipboard.copy(selectedText, to: pasteboard))
            XCTAssertEqual(pasteboard.string, selectedText)
            XCTAssertNotEqual(pasteboard.string, "“\(selectedText)”")
            XCTAssertEqual(pasteboard.numberOfItems, 1)
        }
    }

    func testRepeatCopyReplacesPreviousClipboardItem() {
        withIsolatedPasteboard { pasteboard in
            pasteboard.string = "previous clipboard content"

            XCTAssertTrue(SelectionClipboard.copy("First selection", to: pasteboard))
            XCTAssertTrue(SelectionClipboard.copy("Second selection", to: pasteboard))
            XCTAssertEqual(pasteboard.string, "Second selection")
            XCTAssertEqual(pasteboard.numberOfItems, 1, "Copy replaces rather than appends")
        }
    }

    func testEmptySelectionLeavesClipboardUntouched() {
        withIsolatedPasteboard { pasteboard in
            pasteboard.string = "previous clipboard content"
            let previousChangeCount = pasteboard.changeCount

            XCTAssertFalse(SelectionClipboard.copy("", to: pasteboard))
            XCTAssertEqual(pasteboard.string, "previous clipboard content")
            XCTAssertEqual(pasteboard.changeCount, previousChangeCount)
        }
    }

    private func withIsolatedPasteboard(_ assertions: (UIPasteboard) -> Void) {
        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        assertions(pasteboard)
    }
}

final class SelectionPreviewTests: XCTestCase {
    func testShortSelectionIsShownWhole() {
        XCTAssertEqual(SelectionPreview.truncated("Geography is destiny"), "Geography is destiny")
    }

    func testLongSelectionIsCutOnAWordBoundaryAndElided() {
        let selected = "At the edge of night, the lanterns flickered softly. Footsteps followed the path toward the square."
        let preview = SelectionPreview.truncated(selected, budget: 24)

        XCTAssertEqual(preview, "At the edge of night…")
        XCTAssertTrue(preview.hasSuffix("…"))
        XCTAssertFalse(preview.dropLast().hasSuffix(" "), "No dangling space before the ellipsis")
    }

    func testTrailingPunctuationIsDroppedBeforeTheEllipsis() {
        XCTAssertEqual(
            SelectionPreview.truncated("The riverbanks, the rooftops, shimmer in the dusk", budget: 30),
            "The riverbanks, the rooftops…"
        )
    }

    func testCollapsesNewlinesAndRunsOfWhitespace() {
        XCTAssertEqual(
            SelectionPreview.truncated("  Geography\n\nis   destiny \t"),
            "Geography is destiny"
        )
    }

    func testSingleWordLongerThanBudgetIsCutHard() {
        let preview = SelectionPreview.truncated(String(repeating: "a", count: 80), budget: 12)

        XCTAssertEqual(preview, String(repeating: "a", count: 12) + "…")
    }

    func testEmptySelectionPreviewIsEmpty() {
        XCTAssertEqual(SelectionPreview.truncated(""), "")
        XCTAssertEqual(SelectionPreview.truncated("   \n "), "")
    }

    func testDefaultBudgetKeepsThePreviewToOneShortLine() {
        let preview = SelectionPreview.truncated(
            "Beyond the railway, houses faced the river, the evening market, and the narrow road beside the old bridge"
        )

        XCTAssertLessThanOrEqual(preview.count, SelectionPreview.characterBudget + 1)
        XCTAssertTrue(preview.hasSuffix("…"))
    }
}
