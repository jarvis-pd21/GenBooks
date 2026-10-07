import Foundation

enum ReaderSelectionMapper {
    /// Maps a document UTF-16 selection into stable block/revision identity.
    /// Multi-block selections are clamped to the primary (start) block for MVP stability.
    static func selection(
        in document: ReaderDocument,
        documentRange: NSRange
    ) -> ReaderTextSelection? {
        guard documentRange.length > 0,
              documentRange.location >= 0,
              NSMaxRange(documentRange) <= document.length,
              let anchor = document.anchor(containingUtf16Location: documentRange.location)
        else { return nil }

        let blockStart = anchor.utf16Range.lowerBound
        let blockEnd = anchor.utf16Range.upperBound
        let selStart = max(documentRange.location, blockStart)
        let selEnd = min(NSMaxRange(documentRange), blockEnd)
        guard selEnd > selStart else { return nil }

        let withinStart = selStart - blockStart
        let withinLength = selEnd - selStart
        let range = ContentRangeAnchor(
            blockId: anchor.block.id,
            utf16Start: withinStart,
            utf16Length: withinLength
        )

        let full = document.attributedText.string as NSString
        let selected = full.substring(with: NSRange(location: selStart, length: withinLength))
        let sentence = sentenceContaining(in: full, around: NSRange(location: selStart, length: withinLength))
        let contextStart = max(blockStart, selStart - 48)
        let contextEnd = min(blockEnd, selEnd + 48)
        let surrounding = full.substring(with: NSRange(location: contextStart, length: contextEnd - contextStart))
            .replacingOccurrences(of: "\n", with: " ")

        return ReaderTextSelection(
            selectedText: selected,
            chapterId: anchor.chapterId,
            chapterTitle: anchor.chapterTitle,
            revisionId: anchor.revisionId,
            range: range,
            originalSentence: sentence,
            surroundingContext: surrounding,
            documentUtf16Range: NSRange(location: selStart, length: withinLength)
        )
    }

    static func documentRange(
        for highlight: HighlightAnnotation,
        in document: ReaderDocument
    ) -> NSRange? {
        documentRange(blockId: highlight.range.blockId, range: highlight.range, in: document)
    }

    static func documentRange(
        for note: NoteAnnotation,
        in document: ReaderDocument
    ) -> NSRange? {
        documentRange(blockId: note.range.blockId, range: note.range, in: document)
    }

    static func documentRange(
        blockId: UUID,
        range: ContentRangeAnchor,
        in document: ReaderDocument
    ) -> NSRange? {
        guard let anchor = document.anchor(blockId: blockId) else { return nil }
        // Prefer matching revision when present in document anchors.
        let blockLen = anchor.utf16Range.count
        let clamped = range.clamped(toBlockLength: blockLen)
        let loc = anchor.utf16Range.lowerBound + clamped.utf16Start
        let len = clamped.utf16Length
        guard loc >= 0, loc + len <= document.length else { return nil }
        return NSRange(location: loc, length: len)
    }

    private static func sentenceContaining(in full: NSString, around range: NSRange) -> String {
        let delimiters = CharacterSet(charactersIn: ".!?\n")
        var start = range.location
        while start > 0 {
            let scalar = full.character(at: start - 1)
            if let uni = UnicodeScalar(scalar), delimiters.contains(uni) { break }
            start -= 1
            if range.location - start > 280 { break }
        }
        var end = NSMaxRange(range)
        while end < full.length {
            let scalar = full.character(at: end)
            if let uni = UnicodeScalar(scalar), delimiters.contains(uni) {
                end += 1
                break
            }
            end += 1
            if end - NSMaxRange(range) > 280 { break }
        }
        return full.substring(with: NSRange(location: start, length: end - start))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
