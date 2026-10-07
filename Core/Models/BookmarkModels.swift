import Foundation

/// Deliberate named pin — separate from auto-resume checkpoints and from highlights/notes.
/// Location is semantic: chapter + revision + block + UTF-16 offset at the nearest word.
struct NamedBookmark: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var bookId: UUID
    var chapterId: UUID
    var chapterTitle: String
    var revisionId: UUID
    var blockId: UUID
    /// UTF-16 offset into the block's display text (start of nearest word).
    var utf16Offset: Int
    var title: String
    var snippet: String
    var createdAt: Date
    var updatedAt: Date

    func asReaderLocation(progress: Double = 0) -> ReaderLocation {
        ReaderLocation(
            chapterId: chapterId,
            blockId: blockId,
            characterOffset: utf16Offset,
            progress: progress
        )
    }

    static func defaultTitle(chapterTitle: String, snippet: String) -> String {
        let snip = snippet
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        let short: String
        if snip.count > 42 {
            short = String(snip.prefix(39)) + "…"
        } else {
            short = snip
        }
        if short.isEmpty { return chapterTitle }
        return "\(chapterTitle) · \(short)"
    }
}

enum BookmarkAnchorResolver {
    /// Word bases; combining marks stay attached to their complete source grapheme.
    private static let wordCharacters: CharacterSet = {
        var set = CharacterSet.letters
        set.formUnion(.decimalDigits)
        set.formUnion(CharacterSet(charactersIn: "'’"))
        // Foundation's letters set also includes marks, including emoji variation selectors.
        set.subtract(.nonBaseCharacters)
        return set
    }()

    /// Resolve a selection to a nearest-word UTF-16 offset within the selection's block.
    static func nearestWordPin(
        blockText: String,
        selectionStartUtf16: Int,
        selectedText: String
    ) -> (utf16Offset: Int, word: String, snippet: String) {
        let ns = blockText as NSString
        let length = ns.length
        guard length > 0 else {
            let fallback = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
            return (0, fallback, fallback)
        }

        let seed = min(max(0, selectionStartUtf16), length - 1)
        let snippetSeed = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = nearestWordRange(in: blockText, around: seed) else {
            // Punctuation/emoji-only blocks have no source word. Keep their pin on a
            // complete composed sequence, even if TextKit supplied a surrogate offset.
            let start = ns.rangeOfComposedCharacterSequence(at: seed).location
            return (start, "", snippetSeed)
        }
        let word = ns.substring(with: range)
        let snippet = snippetSeed.isEmpty ? word : snippetSeed
        return (range.location, word, snippet)
    }

    private static func nearestWordRange(in text: String, around location: Int) -> NSRange? {
        var nearest: NSRange?
        var nearestDistance = Int.max
        var wordStart: Int?
        var offset = 0

        func considerWord(endingAt end: Int) {
            guard let start = wordStart else { return }
            let distance = location < start ? start - location : max(0, location - (end - 1))
            // Preserve the original right-hand preference when two words are equally near.
            if distance <= nearestDistance {
                nearest = NSRange(location: start, length: end - start)
                nearestDistance = distance
            }
        }

        // Iterate complete graphemes, but retain their original UTF-16 source ranges.
        // No normalization or UTF-16-unit decoding can split astral letters or accents.
        for character in text {
            if isWordGrapheme(character) {
                if wordStart == nil { wordStart = offset }
            } else {
                considerWord(endingAt: offset)
                wordStart = nil
            }
            offset += String(character).utf16.count
        }
        considerWord(endingAt: offset)
        return nearest
    }

    private static func isWordGrapheme(_ character: Character) -> Bool {
        let scalars = character.unicodeScalars
        // A keycap's digit base does not turn the displayed emoji into a lexical word.
        guard !scalars.contains(where: { $0.value == 0x20E3 }) else { return false }
        return scalars.contains(where: wordCharacters.contains)
    }
}
