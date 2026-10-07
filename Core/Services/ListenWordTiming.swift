import Foundation

/// Maps playback position ↔ prose without vendor word-timestamps.
///
/// OpenAI `gpt-4o-mini-tts` returns MP3 only, so karaoke sync is estimated from
/// character-weighted progress inside the playing chunk. Good enough for a warm
/// highlight; not a claim of phoneme alignment.
enum ListenWordTiming {
    struct WordSpan: Equatable, Sendable {
        var utf16Start: Int
        var utf16Length: Int
        var text: String
    }

    /// Word spans inside one chunk's text (local UTF-16 offsets).
    static func words(in text: String) -> [WordSpan] {
        let source = text as NSString
        guard source.length > 0 else { return [] }
        var spans: [WordSpan] = []
        var index = 0
        while index < source.length {
            while index < source.length, isSeparator(source.character(at: index)) {
                index += 1
            }
            guard index < source.length else { break }
            let start = index
            while index < source.length, !isSeparator(source.character(at: index)) {
                index += 1
            }
            let length = index - start
            guard length > 0 else { continue }
            spans.append(
                WordSpan(
                    utf16Start: start,
                    utf16Length: length,
                    text: source.substring(with: NSRange(location: start, length: length))
                )
            )
        }
        return spans
    }

    /// Which word is speaking at `progress` ∈ [0, 1], weighted by character length.
    static func wordIndex(atProgress progress: Double, words: [WordSpan]) -> Int? {
        guard !words.isEmpty else { return nil }
        let total = words.reduce(0) { $0 + max(1, $1.utf16Length) }
        guard total > 0 else { return 0 }
        let clamped = min(max(progress, 0), 0.999_999)
        let target = Int((clamped * Double(total)).rounded(.down))
        var cursor = 0
        for (index, word) in words.enumerated() {
            cursor += max(1, word.utf16Length)
            if target < cursor { return index }
        }
        return words.count - 1
    }

    /// Fractional offset (0…1) for a UTF-16 point inside a chunk — used to seek
    /// into audio when true timestamps are unavailable.
    static func progress(forUTF16Offset offset: Int, in text: String) -> Double {
        let length = (text as NSString).length
        guard length > 0 else { return 0 }
        let clamped = min(max(0, offset), length)
        return Double(clamped) / Double(length)
    }

    /// Absolute narration UTF-16 offset for a block selection, matching
    /// `ListenChunker.narrationText` joining rules.
    static func narrationUTF16Offset(
        blocks: [ContentBlock],
        blockId: UUID,
        utf16InBlock: Int
    ) -> Int? {
        let ordered = blocks
            .sorted { $0.orderIndex < $1.orderIndex }
            .filter { $0.kind != .imagePlaceholder }
        var cursor = 0
        for (index, block) in ordered.enumerated() {
            let trimmed = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let piece = trimmed as NSString
            if block.id == blockId {
                let local = min(max(0, utf16InBlock), piece.length)
                return cursor + local
            }
            cursor += piece.length
            if index < ordered.count - 1 {
                // narrationText joins with "\n\n"
                cursor += 2
            }
        }
        return nil
    }

    /// Chunk + local UTF-16 offset for an absolute narration offset.
    static func locate(utf16Offset: Int, in document: ListenDocument) -> (chunkIndex: Int, localUTF16: Int)? {
        guard !document.chunks.isEmpty else { return nil }
        for chunk in document.chunks {
            let end = chunk.utf16Start + chunk.utf16Length
            if utf16Offset >= chunk.utf16Start && utf16Offset < end {
                return (chunk.index, utf16Offset - chunk.utf16Start)
            }
        }
        if let last = document.chunks.last, utf16Offset >= last.utf16Start {
            return (last.index, min(max(0, utf16Offset - last.utf16Start), last.utf16Length))
        }
        return (0, 0)
    }

    private static func isSeparator(_ scalar: unichar) -> Bool {
        scalar == 0x20 || scalar == 0x09 || scalar == 0x0A || scalar == 0x0D
            || scalar == 0x00A0 || scalar == 0x2029
    }
}
