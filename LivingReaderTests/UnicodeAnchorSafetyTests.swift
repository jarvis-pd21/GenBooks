import XCTest
@testable import LivingReader

/// Unicode integrity is independent of the regeneration boundary policy. The
/// existing WordForward/AfterWord suites own the exact from/after-word contract.
final class UnicodeAnchorSafetyTests: XCTestCase {
    func testNearestWordPinHandlesEveryUTF16PositionInAstralLetterWords() {
        let word = "\u{10400}\u{10428}land"
        let text = "First \(word) last"
        let range = (text as NSString).range(of: word)
        for offset in range.location..<NSMaxRange(range) {
            let pin = BookmarkAnchorResolver.nearestWordPin(
                blockText: text, selectionStartUtf16: offset, selectedText: ""
            )
            XCTAssertEqual(pin.utf16Offset, range.location, "Offset \(offset)")
            XCTAssertEqual(Array(pin.word.utf8), Array(word.utf8), "Offset \(offset)")
            XCTAssertEqual(pin.snippet, word)
        }
    }

    func testNearestWordPinKeepsCombiningAccentsAndApostrophesByteExact() {
        for word in ["cafe\u{301}", "café", "l’e\u{301}te\u{301}", "don't", "𐐀’𐐨"] {
            let text = "Before \(word) after"
            let range = (text as NSString).range(of: word)
            for offset in range.location..<NSMaxRange(range) {
                let pin = BookmarkAnchorResolver.nearestWordPin(
                    blockText: text, selectionStartUtf16: offset, selectedText: "  chosen snippet\n"
                )
                XCTAssertEqual(pin.utf16Offset, range.location, "\(word), offset \(offset)")
                XCTAssertEqual(Array(pin.word.utf8), Array(word.utf8), "\(word), offset \(offset)")
                XCTAssertEqual(pin.snippet, "chosen snippet")
            }
        }
    }

    func testNearestWordPinFindsWordAfterZWJEmojiAndFlagAtEveryOffset() {
        for prefix in ["👨‍👩‍👧‍👦", "🇦🇷", "👩🏽‍🚀", "❤️", "1️⃣"] {
            let text = prefix + " word"
            for offset in 0..<(text as NSString).length {
                let pin = BookmarkAnchorResolver.nearestWordPin(
                    blockText: text, selectionStartUtf16: offset, selectedText: ""
                )
                XCTAssertEqual(pin.utf16Offset, prefix.utf16.count + 1, "\(prefix), offset \(offset)")
                XCTAssertEqual(pin.word, "word")
            }
        }
    }

    func testNearestWordPinEmojiOnlyFallbackNeverSplitsComposedSequenceOrInventsWord() {
        let graphemes = ["👨‍👩‍👧‍👦", "🇦🇷", "👩🏽‍🚀", "🙂", "❤️", "1️⃣"]
        let text = graphemes.joined()
        var start = 0
        for grapheme in graphemes {
            for offset in start..<(start + grapheme.utf16.count) {
                let pin = BookmarkAnchorResolver.nearestWordPin(
                    blockText: text, selectionStartUtf16: offset, selectedText: "  invented word  "
                )
                XCTAssertEqual(pin.utf16Offset, start, "Offset \(offset)")
                XCTAssertEqual(pin.word, "")
                XCTAssertEqual(pin.snippet, "invented word")
            }
            start += grapheme.utf16.count
        }
    }

    func testNearestWordPinPreservesASCIICharacterDistanceAndRightHandTies() {
        let cases: [(String, Int, Int, String)] = [
            ("Hello   world", 5, 0, "Hello"),
            ("Hello   world", 6, 8, "world"),
            ("Hello   world", 7, 8, "world"),
            ("longword...x", 8, 0, "longword"),
            ("longword...x", 9, 11, "x"),
            ("left,right", 4, 5, "right"),
            ("a\n\nb", 1, 0, "a"),
            ("a\n\nb", 2, 3, "b"),
            ("2026  ’test'", 8, 6, "’test'")
        ]
        for (text, offset, expectedOffset, expectedWord) in cases {
            let pin = BookmarkAnchorResolver.nearestWordPin(
                blockText: text, selectionStartUtf16: offset, selectedText: ""
            )
            XCTAssertEqual(pin.utf16Offset, expectedOffset, "\(text), offset \(offset)")
            XCTAssertEqual(pin.word, expectedWord, "\(text), offset \(offset)")
        }
    }

    func testNearestWordPinClampsExtremeOffsetsWithoutOverflow() {
        let text = "𐐀word last"
        for offset in [Int.min, -1, 0, 1] {
            let pin = BookmarkAnchorResolver.nearestWordPin(
                blockText: text, selectionStartUtf16: offset, selectedText: ""
            )
            XCTAssertEqual(pin.utf16Offset, 0)
            XCTAssertEqual(pin.word, "𐐀word")
        }
        for offset in [text.utf16.count, Int.max] {
            let pin = BookmarkAnchorResolver.nearestWordPin(
                blockText: text, selectionStartUtf16: offset, selectedText: ""
            )
            XCTAssertEqual(pin.utf16Offset, 7)
            XCTAssertEqual(pin.word, "last")
        }
        for offset in [Int.min, Int.max] {
            let pin = BookmarkAnchorResolver.nearestWordPin(
                blockText: "👨‍👩‍👧‍👦", selectionStartUtf16: offset, selectedText: ""
            )
            XCTAssertEqual(pin.utf16Offset, 0)
            XCTAssertEqual(pin.word, "")
            XCTAssertEqual(pin.snippet, "")
        }
    }

    func testNearestWordPinPunctuationOnlyKeepsSnippetButHasNoSourceWord() {
        let pin = BookmarkAnchorResolver.nearestWordPin(
            blockText: "!? …", selectionStartUtf16: 2, selectedText: "  selected\n"
        )
        XCTAssertEqual(pin.utf16Offset, 2)
        XCTAssertEqual(pin.word, "")
        XCTAssertEqual(pin.snippet, "selected")
    }

    func testNearestWordPinEmptyBlockPreservesExistingFallback() {
        for offset in [Int.min, 0, Int.max] {
            let pin = BookmarkAnchorResolver.nearestWordPin(
                blockText: "", selectionStartUtf16: offset, selectedText: "  selected\n"
            )
            XCTAssertEqual(pin.utf16Offset, 0)
            XCTAssertEqual(pin.word, "selected")
            XCTAssertEqual(pin.snippet, "selected")
        }
    }

    func testSplitInsideEveryAstralLetterCodeUnitUsesTheWholeWord() throws {
        let word = "𐐀𐐁"
        let text = "Read \(word) later."
        let block = ContentBlock(id: UUID(), kind: .paragraph, text: text, orderIndex: 0)
        let wordRange = (text as NSString).range(of: word)
        for offset in wordRange.location..<NSMaxRange(wordRange) {
            let split = try ChapterAnchorSplitter.split(blocks: [block], blockId: block.id, utf16OffsetInBlock: offset)
            let prefix = split.frozenPrefix.map(\.text).joined()
            let suffix = split.regenerableSuffix.map(\.text).joined()
            XCTAssertEqual(Array(split.anchorWord.utf8), Array(word.utf8), "UTF-16 offset \(offset)")
            // Main's from-word boundary and #39's after-word boundary both preserve
            // the whole lexical word. Neither may cut inside it or another word.
            XCTAssertTrue([wordRange.location, NSMaxRange(wordRange) + 1].contains(prefix.utf16.count))
            XCTAssertNotEqual(prefix.contains(word), suffix.contains(word), "The complete word belongs to one partition")
            XCTAssertEqual(Array((prefix + suffix).utf8), Array(text.utf8), "UTF-16 offset \(offset)")
        }
    }

    func testWordlessEmojiSplitAtEveryOffsetNeverCutsAComposedCharacter() throws {
        let text = "🧑🏽‍🚀🇦🇷👨‍👩‍👧‍👦"
        let block = ContentBlock(id: UUID(), kind: .paragraph, text: text, orderIndex: 0)
        var boundaries: Set<Int> = [0]
        var position = 0
        for character in text {
            position += String(character).utf16.count
            boundaries.insert(position)
        }
        for offset in -1...(text.utf16.count + 1) {
            let split = try ChapterAnchorSplitter.split(blocks: [block], blockId: block.id, utf16OffsetInBlock: offset)
            let prefix = split.frozenPrefix.map(\.text).joined()
            let suffix = split.regenerableSuffix.map(\.text).joined()
            XCTAssertTrue(boundaries.contains(prefix.utf16.count), "UTF-16 offset \(offset)")
            XCTAssertEqual(Array((prefix + suffix).utf8), Array(text.utf8), "UTF-16 offset \(offset)")
        }
    }

    func testPrefixGuardRejectsUnicodeNormalizationThatWouldShiftSavedOffsets() throws {
        for (source, replacement) in [("cafe\u{301}", "café"), ("café", "cafe\u{301}")] {
            XCTAssertEqual(source, replacement, "Swift canonical equivalence is not exact source preservation")
            XCTAssertNotEqual(Array(source.utf16), Array(replacement.utf16))
            let frozen = [ContentBlock(id: UUID(), kind: .paragraph, text: source, orderIndex: 0)]
            var changed = frozen
            changed[0].text = replacement
            XCTAssertThrowsError(try ChapterAnchorSplitter.assertPrefixPreserved(frozen, in: changed)) { error in
                XCTAssertEqual(error as? ChapterAnchorSplitError, .prefixMutated)
            }
            XCTAssertNoThrow(try ChapterAnchorSplitter.assertPrefixPreserved(frozen, in: frozen))
        }
    }

    func testApplyAndReopenPreservesExactUnicodePrefixAndOriginalRevision() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UnicodeAnchor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let versioning = try ManuscriptVersioningService(rootDirectory: root)
        let book = try BundleFixtureLoader.loadArgentinaMinimal()
        try await versioning.saveBook(book)
        let adaptation = LivingBookAdaptationService(
            versioning: versioning,
            feedbackStore: try FileFeedbackStore(rootDirectory: root),
            preferenceStore: try FileReaderPreferenceStore(rootDirectory: root),
            ai: MockAIService()
        )
        let frozenLead = "cafe\u{301} 𐐀𐐁 🧑🏽‍🚀 🇦🇷 "
        let opening = Array(repeating: "Argentina argued with itself about the port, the interior, and the price of bread.", count: 60)
            .joined(separator: " ")
        let closing = Array(repeating: "FUTURE_MARKER the pampas kept feeding an argument nobody won outright.", count: 40)
            .joined(separator: " ")
        let original = try await versioning.createRevision(
            bookId: book.id,
            chapterId: ArgentinaFixtureIDs.chapter2,
            blocks: [
                ContentBlock(id: UUID(), kind: .heading, text: "Independence", orderIndex: 0),
                ContentBlock(id: UUID(), kind: .paragraph, text: "\(frozenLead)\(opening) MIDPOINT \(closing)", orderIndex: 1),
                ContentBlock(id: UUID(), kind: .paragraph,
                             text: Array(repeating: "The nation practised democracy in fits and starts.", count: 30).joined(separator: " "),
                             orderIndex: 2)
            ]
        )
        let sourceBody = original.blocks[1]
        let markerRange = (sourceBody.text as NSString).range(of: "MIDPOINT")
        XCTAssertNotEqual(markerRange.location, NSNotFound)
        let anchor = RegenerationWordAnchor(
            bookId: book.id, chapterId: ArgentinaFixtureIDs.chapter2, chapterTitle: "Independence Sparks",
            revisionId: original.id, blockId: sourceBody.id, utf16OffsetInBlock: markerRange.location + 2,
            word: "MIDPOINT", createdAt: Date()
        )
        let split = try ChapterAnchorSplitter.split(
            blocks: original.blocks, blockId: sourceBody.id, utf16OffsetInBlock: anchor.utf16OffsetInBlock
        )
        XCTAssertFalse(split.frozenPrefix.map(\.text).joined().contains("FUTURE_MARKER"))
        let originalBytes = try JSONCoding.encoder.encode(original)
        let latestLoaded = try await versioning.loadBook(id: book.id)
        let latest = try XCTUnwrap(latestLoaded)
        let preview = try await adaptation.previewWordForwardRegeneration(
            book: latest, request: WordForwardRegenerationRequest(anchor: anchor, maxFollowOnChapters: 0)
        )
        _ = try await adaptation.applyWordForwardRegeneration(book: latest, preview: preview)

        let reopened = try ManuscriptVersioningService(rootDirectory: root)
        let reloaded = try await reopened.loadBook(id: book.id)
        let loaded = try XCTUnwrap(reloaded)
        let chapter = try XCTUnwrap(loaded.chapters.first { $0.id == anchor.chapterId })
        XCTAssertEqual(try JSONCoding.encoder.encode(XCTUnwrap(chapter.revision(id: original.id))), originalBytes)
        let active = try XCTUnwrap(chapter.activeRevision)
        XCTAssertNotEqual(active.id, original.id)
        let preserved = Array(active.blocks.prefix(split.frozenPrefix.count))
        XCTAssertEqual(preserved.map { Array($0.text.utf8) }, split.frozenPrefix.map { Array($0.text.utf8) })
        XCTAssertEqual(preserved.map(\.id), split.frozenPrefix.map(\.id))
        XCTAssertEqual(preserved.map(\.kind), split.frozenPrefix.map(\.kind))
        let preservedBody = try XCTUnwrap(preserved.first { $0.id == sourceBody.id })
        // Independent literal expectation: do not let the splitter's own output
        // mask normalization or lost Unicode text in both expected and actual.
        XCTAssertEqual(Array(preservedBody.text.utf8.prefix(frozenLead.utf8.count)), Array(frozenLead.utf8))
        XCTAssertGreaterThan(active.blocks.count, preserved.count)
    }
}
