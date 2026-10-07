import XCTest
import UIKit
@testable import LivingReader

/// In-process reader policy and selection tests, not proof of the system popup's
/// appearance on an Apple Intelligence-capable device.
@MainActor
final class ReaderWritingToolsTests: XCTestCase {
    func testConfiguredReaderDisablesWritingToolsOnSupportedSystems() throws {
        guard #available(iOS 18.0, *) else {
            throw XCTSkip("Writing Tools is unavailable before iOS 18.")
        }
        let reader = TextKitReaderUIView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        XCTAssertEqual(reader.textView.writingToolsBehavior, .none)
        reader.apply(document: document())
        reader.apply(scrollMode: .pages)
        XCTAssertEqual(reader.textView.writingToolsBehavior, .none)
        reader.apply(scrollMode: .scroll)
        reader.apply(document: document())
        XCTAssertEqual(reader.textView.writingToolsBehavior, .none,
                       "Rendering or switching reading modes must not restore a system Writing Tools menu")
    }

    func testReaderRemainsSelectableReadOnlyAndUsesItsExistingDelegate() {
        let reader = TextKitReaderUIView(frame: .zero)
        XCTAssertFalse(reader.textView.isEditable)
        XCTAssertTrue(reader.textView.isSelectable)
        XCTAssertTrue(reader.textView.isUserInteractionEnabled)
        XCTAssertTrue(reader.textView.delegate === reader)
        XCTAssertEqual(reader.textView.accessibilityLabel, "Book text")
        XCTAssertEqual(reader.textView.accessibilityIdentifier, "reader.textkit.text")
        XCTAssertFalse(reader.textView.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil),
                       "The system menu stays suppressed; Copy belongs to the app's selection sheet")
    }

    func testUnicodeSelectionStillReportsExactUTF16RangeAndClearsNormally() throws {
        let reader = TextKitReaderUIView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let document = document()
        reader.apply(document: document)
        var reported: NSRange?
        reader.onSelectionChanged = { reported = $0 }
        for phrase in ["🇦🇷", "👩🏽‍💻", "cafe\u{301}", "العربية", "👩🏽‍💻 cafe\u{301} العربية"] {
            let range = (document.attributedText.string as NSString).range(of: phrase)
            XCTAssertNotEqual(range.location, NSNotFound)
            reader.textView.selectedRange = range
            reader.textViewDidChangeSelection(reader.textView)
            XCTAssertEqual(reader.textView.selectedRange, range)
            XCTAssertEqual(reported, range)
            let nativeRange = try XCTUnwrap(reader.textView.selectedTextRange)
            let nativeText = try XCTUnwrap(reader.textView.text(in: nativeRange))
            XCTAssertEqual(Array(nativeText.utf8), Array(phrase.utf8), "Native selection must not split or normalize Unicode")
            let selection = try XCTUnwrap(ReaderSelectionMapper.selection(in: document, documentRange: range))
            XCTAssertEqual(selection.documentUtf16Range, range)
            XCTAssertEqual(Array(selection.selectedText.utf8), Array(phrase.utf8))
            XCTAssertEqual(selection.range.blockId, document.anchors[0].block.id)
            XCTAssertNil(reader.textView.editMenu(for: nativeRange, suggestedActions: []))
        }
        reader.textView.selectedRange = NSRange(location: 0, length: 0)
        reader.textViewDidChangeSelection(reader.textView)
        XCTAssertNil(reported)
        XCTAssertEqual(reader.textView.attributedText.string, document.attributedText.string)
    }

    func testAppCopyKeepsExactNativeSelectionWithoutMutatingManuscript() throws {
        let reader = TextKitReaderUIView(frame: .zero)
        let document = document()
        reader.apply(document: document)
        let phrase = "👩🏽‍💻 cafe\u{301} العربية"
        let range = (document.attributedText.string as NSString).range(of: phrase)
        reader.textView.selectedRange = range
        let selection = try XCTUnwrap(ReaderSelectionMapper.selection(in: document, documentRange: reader.textView.selectedRange))
        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        XCTAssertTrue(SelectionClipboard.copy(selection.selectedText, to: pasteboard))
        XCTAssertEqual(Array(try XCTUnwrap(pasteboard.string).utf8), Array(phrase.utf8))
        XCTAssertEqual(reader.textView.selectedRange, range)
        XCTAssertEqual(reader.textView.attributedText.string, document.attributedText.string)
        XCTAssertFalse(reader.textView.isEditable)
        XCTAssertTrue(reader.textView.isSelectable)
    }

    private func document() -> ReaderDocument {
        let text = "Before 🇦🇷 👩🏽‍💻 cafe\u{301} العربية after."
        let chapterID = UUID()
        let block = ContentBlock(id: UUID(), kind: .paragraph, text: text, orderIndex: 0)
        return ReaderDocument(bookId: UUID(), title: "Authored selection fixture", author: "Fixture",
            attributedText: NSAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: 20)]),
            anchors: [.init(chapterId: chapterID, chapterTitle: "Unicode", chapterOrderIndex: 1,
                            revisionId: UUID(), block: block, utf16Range: 0..<(text as NSString).length)],
            chapterStarts: [(chapterId: chapterID, title: "Unicode", utf16Location: 0)])
    }
}
