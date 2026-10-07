import Foundation

/// Splits chapter prose into synthesis-sized pieces.
///
/// TTS requests have to be bounded, but a cut in the middle of a sentence is
/// audible: the narrator drops pitch, pauses, then restarts mid-clause. So the
/// chunker only ever cuts at sentence (or, failing that, word) boundaries, and
/// measures in UTF-16 units because that is what the reader layer, annotations
/// and bookmarks already speak.
enum ListenChunker {
    /// Sentence-aligned chunks, each at most `plan.maximumChunkUTF16` units
    /// long, closing once a chunk passes `plan.preferredChunkUTF16`.
    static func chunks(for text: String, plan: ListenPlan = .current) -> [ListenChunk] {
        let source = text as NSString
        guard source.length > 0 else { return [] }

        let preferred = max(1, min(plan.preferredChunkUTF16, plan.maximumChunkUTF16))
        let maximum = max(preferred, plan.maximumChunkUTF16)

        var pieces: [NSRange] = []
        var current: NSRange?

        for sentence in sentenceRanges(in: source) {
            for unit in splitOversized(sentence, in: source, maximum: maximum) {
                if var open = current {
                    if open.length + unit.length > maximum {
                        pieces.append(open)
                        current = unit
                    } else {
                        open.length += unit.length
                        current = open
                    }
                } else {
                    current = unit
                }
                // Measured after trimming, so a chunk's spoken text — not its
                // trailing whitespace — is what clears the preferred size.
                if let open = current, trimming(open, in: source).length >= preferred {
                    pieces.append(open)
                    current = nil
                }
            }
        }
        if let open = current {
            pieces.append(open)
        }

        var chunks: [ListenChunk] = []
        for range in pieces {
            let trimmed = trimming(range, in: source)
            guard trimmed.length > 0 else { continue }
            chunks.append(
                ListenChunk(
                    index: chunks.count,
                    text: source.substring(with: trimmed),
                    utf16Start: trimmed.location,
                    utf16Length: trimmed.length
                )
            )
        }
        return chunks
    }

    /// Contiguous sentence ranges covering the whole string.
    ///
    /// Each range carries its own trailing whitespace so consecutive ranges can
    /// be merged into a chunk without re-deriving offsets.
    static func sentenceRanges(in source: NSString) -> [NSRange] {
        guard source.length > 0 else { return [] }
        var ranges: [NSRange] = []
        var start = 0
        var index = 0

        while index < source.length {
            let scalar = source.character(at: index)
            if isParagraphBreak(scalar) {
                let end = consumeWhitespace(from: index, in: source)
                ranges.append(NSRange(location: start, length: end - start))
                start = end
                index = end
                continue
            }
            if isSentenceTerminator(scalar) {
                var end = index + 1
                // Keep closing quotes/brackets with the sentence they end.
                while end < source.length, isSentenceCloser(source.character(at: end)) {
                    end += 1
                }
                let hasBreak = end >= source.length || isWhitespace(source.character(at: end))
                if hasBreak, !isAbbreviation(endingAt: index, in: source) {
                    end = consumeWhitespace(from: end, in: source)
                    ranges.append(NSRange(location: start, length: end - start))
                    start = end
                    index = end
                    continue
                }
            }
            index += 1
        }
        if start < source.length {
            ranges.append(NSRange(location: start, length: source.length - start))
        }
        return ranges
    }

    /// Narration text for one revision: prose only, in reading order.
    ///
    /// Image placeholders are skipped (there is nothing to say), and every other
    /// block is read in full — this is a faithful reading, not a digest.
    static func narrationText(for blocks: [ContentBlock]) -> String {
        blocks
            .sorted { $0.orderIndex < $1.orderIndex }
            .filter { $0.kind != .imagePlaceholder }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    // MARK: - Boundary helpers

    private static func splitOversized(
        _ range: NSRange,
        in source: NSString,
        maximum: Int
    ) -> [NSRange] {
        guard range.length > maximum else { return [range] }
        var parts: [NSRange] = []
        var location = range.location
        let end = range.location + range.length

        while location < end {
            let remaining = end - location
            if remaining <= maximum {
                parts.append(NSRange(location: location, length: remaining))
                break
            }
            let hardLimit = location + maximum
            var cut = hardLimit
            // Walk back to the last word gap so a forced cut still lands between words.
            while cut > location, !isWhitespace(source.character(at: cut - 1)) {
                cut -= 1
            }
            if cut <= location {
                cut = hardLimit
            }
            parts.append(NSRange(location: location, length: cut - location))
            location = cut
        }
        return parts
    }

    private static func trimming(_ range: NSRange, in source: NSString) -> NSRange {
        var start = range.location
        var end = range.location + range.length
        while start < end, isWhitespace(source.character(at: start)) {
            start += 1
        }
        while end > start, isWhitespace(source.character(at: end - 1)) {
            end -= 1
        }
        return NSRange(location: start, length: end - start)
    }

    private static func consumeWhitespace(from index: Int, in source: NSString) -> Int {
        var end = index
        while end < source.length, isWhitespace(source.character(at: end)) {
            end += 1
        }
        return end
    }

    private static func isWhitespace(_ scalar: unichar) -> Bool {
        scalar == 0x20 || scalar == 0x09 || scalar == 0x0A || scalar == 0x0D || scalar == 0x00A0
    }

    private static func isParagraphBreak(_ scalar: unichar) -> Bool {
        scalar == 0x0A || scalar == 0x0D || scalar == 0x2029
    }

    private static func isSentenceTerminator(_ scalar: unichar) -> Bool {
        scalar == 0x2E // .
            || scalar == 0x21 // !
            || scalar == 0x3F // ?
            || scalar == 0x2026 // …
    }

    private static func isSentenceCloser(_ scalar: unichar) -> Bool {
        scalar == 0x22 // "
            || scalar == 0x27 // '
            || scalar == 0x2019 // ’
            || scalar == 0x201D // ”
            || scalar == 0x29 // )
            || scalar == 0x5D // ]
            || scalar == 0xBB // »
    }

    /// Titles, initials and ordinals end in a period without ending a sentence.
    /// Argentine prose is full of "Gral. Belgrano" and "Sr. Rosas".
    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "sra", "srta", "st", "gen", "gral",
        "col", "capt", "cap", "lt", "sgt", "no", "nos", "vs", "etc", "ca", "cf",
        "ed", "eds", "vol", "vols", "p", "pp", "fig", "figs", "jr", "km", "kg",
        "approx", "dept", "ave", "av", "ap", "trans", "ibid", "op"
    ]

    private static func isAbbreviation(endingAt terminator: Int, in source: NSString) -> Bool {
        guard source.character(at: terminator) == 0x2E else { return false }
        var start = terminator
        while start > 0, isWordCharacter(source.character(at: start - 1)) {
            start -= 1
        }
        let word = source.substring(with: NSRange(location: start, length: terminator - start))
        if word.isEmpty { return false }
        // A single capital is an initial ("J. D. Perón"), not a full stop.
        if word.count == 1, word.uppercased() == word { return true }
        return abbreviations.contains(word.lowercased())
    }

    private static func isWordCharacter(_ scalar: unichar) -> Bool {
        (scalar >= 0x41 && scalar <= 0x5A)
            || (scalar >= 0x61 && scalar <= 0x7A)
            || (scalar >= 0x30 && scalar <= 0x39)
            || scalar > 0x7F // accented letters — keep "Güemes" whole
    }
}

/// Builds a `ListenDocument` from a readable chapter revision.
enum ListenDocumentBuilder {
    static func build(
        bookId: UUID,
        chapterId: UUID,
        chapterTitle: String,
        revision: ChapterRevision,
        voice: ListenVoice,
        plan: ListenPlan = .current
    ) -> ListenDocument {
        let text = ListenChunker.narrationText(for: revision.blocks)
        return ListenDocument(
            bookId: bookId,
            chapterId: chapterId,
            chapterTitle: chapterTitle,
            revisionId: revision.id,
            voice: voice,
            plan: plan,
            chunks: ListenChunker.chunks(for: text, plan: plan)
        )
    }
}
