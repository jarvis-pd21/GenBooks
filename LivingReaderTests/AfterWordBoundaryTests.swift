import XCTest
@testable import LivingReader

/// "After this word" includes the selected word in the immutable past.
final class AfterWordBoundaryTests: XCTestCase {
    func testFirstWordAtOffsetZeroStaysFrozen() throws {
        let block = makeBlock("First second third.")
        for offset in [-10, 0] {
            let split = try split(block, offset: offset)
            XCTAssertEqual(split.frozenPrefix.map(\.text), ["First "])
            XCTAssertEqual(split.regenerableSuffix.map(\.text), ["second third."])
            XCTAssertEqual(split.prefixWordCount, 1)
            XCTAssertEqual(split.anchorWord, "First")
        }
    }

    func testInteriorWordFreezesThroughPunctuationAndNewline() throws {
        let block = makeBlock("First selected?!\n\tNext remains.")
        let split = try split(block, offset: 9)

        XCTAssertEqual(split.anchorWord, "selected")
        XCTAssertEqual(split.frozenPrefix.map(\.text), ["First selected?!\n\t"])
        XCTAssertEqual(split.regenerableSuffix.map(\.text), ["Next remains."])
        XCTAssertEqual(split.prefixWordCount, 2)
    }

    func testApostrophizedWordRemainsWhole() throws {
        for word in ["don't", "reader’s"] {
            let block = makeBlock("The \(word), next.")
            let split = try split(block, offset: 5)
            XCTAssertEqual(split.anchorWord, word)
            XCTAssertEqual(split.frozenPrefix.map(\.text), ["The \(word), "])
            XCTAssertEqual(split.regenerableSuffix.map(\.text), ["next."])
        }
    }

    func testLeadingWhitespaceFreezesWithFirstWord() throws {
        let block = makeBlock(" \n\t First second.")
        let split = try split(block, offset: 0)

        XCTAssertEqual(split.frozenPrefix.map(\.text), [" \n\t First "])
        XCTAssertEqual(split.regenerableSuffix.map(\.text), ["second."])
        XCTAssertEqual(split.frozenPrefix.first?.id, block.id)
    }

    func testLastWordAndTrailingSeparatorsLeaveNoSuffix() throws {
        let block = makeBlock("The final!…\n\t ")
        let split = try split(block, offset: 6)

        XCTAssertEqual(split.frozenPrefix, [block])
        XCTAssertTrue(split.regenerableSuffix.isEmpty)
        XCTAssertFalse(split.hasRegenerableSuffix)
        XCTAssertEqual(split.suffixWordCount, 0)
        XCTAssertNil(split.dividedBlockId)
    }

    func testEndAndOversizedOffsetsFreezeWholeBlock() throws {
        let block = makeBlock("First second 🚀")
        let length = (block.text as NSString).length
        for offset in [length, length + 1, Int.max] {
            let split = try split(block, offset: offset)
            XCTAssertEqual(split.frozenPrefix, [block])
            XCTAssertTrue(split.regenerableSuffix.isEmpty)
            XCTAssertNil(split.dividedBlockId)
        }
    }

    func testSplitPreservesExactBytesAndRetainsReadBlockIdentity() throws {
        let earlier = makeBlock("Earlier.", order: 4)
        let anchor = makeBlock("cafe\u{301},  next\nwords", order: 7)
        let later = makeBlock("Later.", order: 9)
        let split = try ChapterAnchorSplitter.split(
            blocks: [later, anchor, earlier],
            blockId: anchor.id,
            utf16OffsetInBlock: 1
        )
        let head = try XCTUnwrap(split.frozenPrefix.last)
        let tail = try XCTUnwrap(split.regenerableSuffix.first)

        XCTAssertEqual(Array((head.text + tail.text).utf8), Array(anchor.text.utf8))
        XCTAssertEqual(Array(head.text.utf8), Array("cafe\u{301},  ".utf8))
        XCTAssertEqual(split.frozenPrefix.map(\.id), [earlier.id, anchor.id])
        XCTAssertNotEqual(tail.id, anchor.id)
        XCTAssertEqual(split.regenerableSuffix.last?.id, later.id)
        XCTAssertEqual(split.dividedBlockId, anchor.id)
        XCTAssertEqual(split.frozenPrefix.map(\.orderIndex), [0, 1])
        XCTAssertEqual(split.regenerableSuffix.map(\.orderIndex), [0, 1])

        let assembled = ChapterAnchorSplitter.assemble(
            frozenPrefix: split.frozenPrefix,
            regenerated: split.regenerableSuffix
        )
        XCTAssertEqual(assembled.map(\.orderIndex), [0, 1, 2, 3])
        XCTAssertNoThrow(try ChapterAnchorSplitter.assertPrefixPreserved(split.frozenPrefix, in: assembled))
    }

    func testWordEndPreservesDecomposedAndAstralClusters() throws {
        // Anchor in the ASCII part: this tests the inclusive end, not nearest-word selection.
        for word in ["cafe\u{301}", "a𐐀"] {
            let block = makeBlock("\(word), next")
            let split = try split(block, offset: 0)
            let head = try XCTUnwrap(split.frozenPrefix.first)

            XCTAssertEqual(Array(head.text.utf8), Array("\(word), ".utf8))
            XCTAssertEqual(split.regenerableSuffix.map(\.text), ["next"])
            XCTAssertFalse(head.text.contains("\u{FFFD}"))
        }
    }

    func testWordlessEmojiPreservesWholeSelectedGrapheme() throws {
        let block = makeBlock("👩🏽‍🚀, \n🌕")
        // UTF-16 offset 3 is inside the skin-tone surrogate pair of the first grapheme.
        let split = try split(block, offset: 3)
        let head = try XCTUnwrap(split.frozenPrefix.first)
        let tail = try XCTUnwrap(split.regenerableSuffix.first)

        XCTAssertEqual(head.text, "👩🏽‍🚀, \n")
        XCTAssertEqual(tail.text, "🌕")
        XCTAssertEqual(Array((head.text + tail.text).utf8), Array(block.text.utf8))
        XCTAssertFalse(head.text.contains("\u{FFFD}"))
        XCTAssertFalse(tail.text.contains("\u{FFFD}"))
    }

    func testSelectedVisualIsAtomicAndLaterBlocksRemainFuture() throws {
        let image = makeBlock("A map of the coast.", kind: .imagePlaceholder)
        let later = makeBlock("Next passage.", order: 1)
        for offset in [0, 4] {
            let split = try ChapterAnchorSplitter.split(
                blocks: [image, later],
                blockId: image.id,
                utf16OffsetInBlock: offset
            )
            XCTAssertEqual(split.frozenPrefix, [image])
            XCTAssertEqual(split.regenerableSuffix.map(\.id), [later.id])
            XCTAssertEqual(split.prefixWordCount, 0)
            XCTAssertNil(split.dividedBlockId)
        }
    }

    func testChapterStartIncludesLeadingVisualsEvenWhenAnchorIsLater() throws {
        let image = makeBlock("Opening map.", kind: .imagePlaceholder, order: 3)
        let heading = makeBlock("Chapter title", kind: .heading, order: 6)
        let paragraph = makeBlock("First second.", order: 8)
        let split = try ChapterAnchorSplitter.split(
            blocks: [paragraph, image, heading],
            blockId: paragraph.id,
            utf16OffsetInBlock: 8,
            boundary: .chapterStart
        )

        XCTAssertTrue(split.frozenPrefix.isEmpty)
        XCTAssertEqual(split.regenerableSuffix.map(\.id), [image.id, heading.id, paragraph.id])
        XCTAssertEqual(split.regenerableSuffix.map(\.text), [image.text, heading.text, paragraph.text])
        XCTAssertEqual(split.regenerableSuffix.map(\.orderIndex), [0, 1, 2])
        XCTAssertEqual(split.suffixVisualCount, 1)
        XCTAssertEqual(split.prefixWordCount, 0)
        XCTAssertNil(split.dividedBlockId)
    }

    func testFollowingEmojiIsNotMistakenForWordPunctuation() throws {
        let block = makeBlock("First, 🚀 next")
        let split = try split(block, offset: 2)

        XCTAssertEqual(split.frozenPrefix.map(\.text), ["First, "])
        XCTAssertEqual(split.regenerableSuffix.map(\.text), ["🚀 next"])
    }

    private func makeBlock(
        _ text: String,
        kind: ContentBlockKind = .paragraph,
        order: Int = 0
    ) -> ContentBlock {
        ContentBlock(id: UUID(), kind: kind, text: text, orderIndex: order)
    }

    func testAdjacentEmojiIsNotExtendedIntoTheSelectedLexicalWord() throws {
        for emoji in ["❤️", "1️⃣", "👩🏽‍🚀"] {
            let block = makeBlock("a\(emoji) next")
            let split = try split(block, offset: 0)
            XCTAssertEqual(split.anchorWord, "a")
            XCTAssertEqual(split.frozenPrefix.map(\.text), ["a"])
            XCTAssertEqual(split.regenerableSuffix.map(\.text), ["\(emoji) next"])
            XCTAssertEqual(Array((split.frozenPrefix[0].text + split.regenerableSuffix[0].text).utf8),
                           Array(block.text.utf8))
        }
    }

    private func split(_ block: ContentBlock, offset: Int) throws -> ChapterAnchorSplit {
        try ChapterAnchorSplitter.split(
            blocks: [block],
            blockId: block.id,
            utf16OffsetInBlock: offset
        )
    }
}
