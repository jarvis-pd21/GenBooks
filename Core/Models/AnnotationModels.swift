import Foundation

/// Semantic range within a content block (UTF-16 offsets into the block's *display* text).
/// Never keyed by screen coordinates — survives font/theme/relaunch and unread future regeneration
/// when tied to the exact chapter revision id.
struct ContentRangeAnchor: Codable, Equatable, Hashable, Sendable {
    var blockId: UUID
    var utf16Start: Int
    var utf16Length: Int

    var nsRange: NSRange { NSRange(location: utf16Start, length: utf16Length) }

    func clamped(toBlockLength length: Int) -> ContentRangeAnchor {
        guard length > 0 else {
            return ContentRangeAnchor(blockId: blockId, utf16Start: 0, utf16Length: 0)
        }
        let start = min(max(0, utf16Start), length - 1)
        let end = min(max(start + 1, utf16Start + max(utf16Length, 1)), length)
        return ContentRangeAnchor(blockId: blockId, utf16Start: start, utf16Length: end - start)
    }
}

/// Colour category a note tags its passage with. Stored on the highlight record, so the
/// raw values are part of the on-disk format — add cases, never rename them.
enum HighlightColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case yellow
    case green
    case blue
    case pink

    static let `default`: HighlightColor = .yellow

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .blue: return "Blue"
        case .pink: return "Pink"
        }
    }
}

struct HighlightAnnotation: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var bookId: UUID
    var chapterId: UUID
    var chapterTitle: String
    var revisionId: UUID
    var range: ContentRangeAnchor
    var selectedText: String
    var color: HighlightColor
    var note: String?
    var createdAt: Date
    var updatedAt: Date
}

struct NoteAnnotation: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var bookId: UUID
    var chapterId: UUID
    var chapterTitle: String
    var revisionId: UUID
    var range: ContentRangeAnchor
    var selectedText: String
    var body: String
    var createdAt: Date
    var updatedAt: Date
}

/// One note on one passage. **Notes** is the product surface — there is no separate
/// Highlight feature. A note carries a colour category on the passage and, optionally, the
/// reader's own words; a note with an empty body is a colour mark and nothing more.
///
/// Storage still keeps a `HighlightAnnotation` (the coloured range) beside an optional
/// `NoteAnnotation` (the body), which is why this row is assembled from both.
struct NoteRow: Identifiable, Equatable, Hashable, Sendable {
    var id: UUID
    var bookId: UUID
    var chapterId: UUID
    var chapterTitle: String
    var revisionId: UUID
    var range: ContentRangeAnchor
    var selectedText: String
    var color: HighlightColor
    var note: String?
    var createdAt: Date

    var hasNote: Bool {
        guard let note else { return false }
        return !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func matches(_ highlight: HighlightAnnotation) -> Bool {
        bookId == highlight.bookId && chapterId == highlight.chapterId
            && revisionId == highlight.revisionId && range == highlight.range
    }

    func matches(_ note: NoteAnnotation) -> Bool {
        bookId == note.bookId && chapterId == note.chapterId
            && revisionId == note.revisionId && range == note.range
    }
}

/// Passage identity: semantic, never screen coordinates, so a highlight and the note
/// written over the same words collapse into one row.
private struct NotePassageKey: Hashable {
    var bookId: UUID
    var chapterId: UUID
    var revisionId: UUID
    var blockId: UUID
    var utf16Start: Int
    var utf16Length: Int

    init(_ highlight: HighlightAnnotation) {
        bookId = highlight.bookId
        chapterId = highlight.chapterId
        revisionId = highlight.revisionId
        blockId = highlight.range.blockId
        utf16Start = highlight.range.utf16Start
        utf16Length = highlight.range.utf16Length
    }

    init(_ note: NoteAnnotation) {
        bookId = note.bookId
        chapterId = note.chapterId
        revisionId = note.revisionId
        blockId = note.range.blockId
        utf16Start = note.range.utf16Start
        utf16Length = note.range.utf16Length
    }
}

/// Stored records behind a note the reader is editing. Either half may be missing: a
/// colour mark has no body yet, and a legacy note has no companion highlight.
struct NoteEditTarget: Equatable, Sendable {
    var highlight: HighlightAnnotation?
    var note: NoteAnnotation?

    var body: String { note?.body ?? highlight?.note ?? "" }
    var color: HighlightColor { highlight?.color ?? .default }

    /// Use the saved passage, not a smaller word reselected inside it.
    var row: NoteRow? {
        if let highlight {
            return NoteRow(id: highlight.id, bookId: highlight.bookId,
                           chapterId: highlight.chapterId, chapterTitle: highlight.chapterTitle,
                           revisionId: highlight.revisionId, range: highlight.range,
                           selectedText: highlight.selectedText, color: highlight.color,
                           note: body, createdAt: highlight.createdAt)
        }
        if let note {
            return NoteRow(id: note.id, bookId: note.bookId,
                           chapterId: note.chapterId, chapterTitle: note.chapterTitle,
                           revisionId: note.revisionId, range: note.range,
                           selectedText: note.selectedText, color: .default,
                           note: note.body, createdAt: note.createdAt)
        }
        return nil
    }
}

enum NoteRowBuilder {
    /// Assemble one note row per passage, newest first.
    ///
    /// Reads both stores so passages recorded before this consolidation — a bare highlight,
    /// or a note without its companion highlight — still surface. No migration and no
    /// writes: stored records are left exactly as they are.
    static func rows(highlights: [HighlightAnnotation], notes: [NoteAnnotation]) -> [NoteRow] {
        var byPassage: [NotePassageKey: NoteRow] = [:]

        for highlight in highlights {
            let key = NotePassageKey(highlight)
            let candidate = NoteRow(
                id: highlight.id,
                bookId: highlight.bookId,
                chapterId: highlight.chapterId,
                chapterTitle: highlight.chapterTitle,
                revisionId: highlight.revisionId,
                range: highlight.range,
                selectedText: highlight.selectedText,
                color: highlight.color,
                note: highlight.note,
                createdAt: highlight.createdAt
            )
            byPassage[key] = merge(existing: byPassage[key], candidate: candidate)
        }

        for note in notes {
            let key = NotePassageKey(note)
            let candidate = NoteRow(
                id: note.id,
                bookId: note.bookId,
                chapterId: note.chapterId,
                chapterTitle: note.chapterTitle,
                revisionId: note.revisionId,
                range: note.range,
                selectedText: note.selectedText,
                // The colour lives on the saved mark; a newer body must not
                // silently replace that category with the legacy blue fallback.
                color: byPassage[key]?.color ?? .blue,
                note: note.body,
                createdAt: note.createdAt
            )
            byPassage[key] = merge(existing: byPassage[key], candidate: candidate)
        }

        return byPassage.values.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// The stored records behind one passage, so editing updates them in place instead of
    /// stacking a second mark on the same words.
    static func target(
        highlights: [HighlightAnnotation],
        notes: [NoteAnnotation],
        overlapping range: ContentRangeAnchor,
        chapterId: UUID,
        revisionId: UUID
    ) -> NoteEditTarget? {
        func overlaps(_ other: ContentRangeAnchor) -> Bool {
            guard other.blockId == range.blockId else { return false }
            let lhsEnd = range.utf16Start + max(range.utf16Length, 1)
            let rhsEnd = other.utf16Start + max(other.utf16Length, 1)
            return range.utf16Start < rhsEnd && other.utf16Start < lhsEnd
        }

        let highlight = highlights.first {
            $0.chapterId == chapterId && $0.revisionId == revisionId && overlaps($0.range)
        }
        let note = notes.first { candidate in
            candidate.chapterId == chapterId && candidate.revisionId == revisionId
                && (highlight.map { $0.range == candidate.range } ?? overlaps(candidate.range))
        }
        guard highlight != nil || note != nil else { return nil }
        return NoteEditTarget(highlight: highlight, note: note)
    }

    /// A noted row wins the passage, so the note survives the merge and the row keeps a
    /// stable id. Timestamps keep the newest contribution so a late note floats the row up.
    private static func merge(existing: NoteRow?, candidate: NoteRow) -> NoteRow {
        guard let existing else { return candidate }
        var winner = existing
        if !existing.hasNote && candidate.hasNote {
            winner = candidate
        } else if existing.hasNote && candidate.hasNote && candidate.createdAt > existing.createdAt {
            winner = candidate
        }
        winner.createdAt = max(existing.createdAt, candidate.createdAt)
        if winner.selectedText.isEmpty {
            winner.selectedText = existing.selectedText.isEmpty ? candidate.selectedText : existing.selectedText
        }
        return winner
    }
}

struct VocabularyEntry: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var bookId: UUID
    var bookTitle: String
    var chapterId: UUID
    var chapterTitle: String
    var revisionId: UUID
    var blockId: UUID
    var phrase: String
    var definition: String
    var originalSentence: String
    var surroundingContext: String
    var note: String?
    var isKnown: Bool
    var createdAt: Date
    var updatedAt: Date
}

/// Transient selection mapped to manuscript identity for action chrome.
struct ReaderTextSelection: Equatable, Sendable {
    var selectedText: String
    var chapterId: UUID
    var chapterTitle: String
    var revisionId: UUID
    var range: ContentRangeAnchor
    var originalSentence: String
    var surroundingContext: String
    var documentUtf16Range: NSRange
}
