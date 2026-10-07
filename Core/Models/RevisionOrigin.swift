import Foundation

/// The selected prose word, not a furthest-read watermark. UTF-16 offsets are
/// measured before the app-owned trailing citation; end includes separators.
struct SourceWordCut: Codable, Equatable, Hashable, Sendable {
    let baseRevisionID: UUID
    let blockID: UUID
    let wordStartUTF16: Int
    let endUTF16: Int
    let word: String
}

/// Why a revision exists. Surfaced as the subtitle of a row in version history,
/// so browsing revisions reads like a document's revision list rather than a list of UUIDs.
struct RevisionOrigin: Codable, Equatable, Hashable, Sendable {
    enum Kind: String, Codable, Equatable, Hashable, Sendable {
        case authored
        case imported
        case generated
        case adaptation
        case regenerateFromChapter
        case regenerateFromWord
        case restore
    }

    var kind: Kind
    var summary: String
    /// Word the reader anchored on, for `regenerateFromWord`.
    var anchorWord: String?
    /// Words frozen through the selected word when this revision was written.
    var frozenPrefixWordCount: Int?
    /// Revision index this body was copied from, for `restore`.
    var restoredFromRevisionIndex: Int?
    /// Optional for legacy publication/restore; required for changed reviewed text.
    var sourceWordCut: SourceWordCut?

    init(
        kind: Kind,
        summary: String,
        anchorWord: String? = nil,
        frozenPrefixWordCount: Int? = nil,
        restoredFromRevisionIndex: Int? = nil,
        sourceWordCut: SourceWordCut? = nil
    ) {
        self.kind = kind
        self.summary = summary
        self.anchorWord = anchorWord
        self.frozenPrefixWordCount = frozenPrefixWordCount
        self.restoredFromRevisionIndex = restoredFromRevisionIndex
        self.sourceWordCut = sourceWordCut
    }

    static func regeneratedFromWord(
        word: String,
        request: String,
        frozenPrefixWordCount: Int
    ) -> RevisionOrigin {
        let trimmedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRequest = request.trimmingCharacters(in: .whitespacesAndNewlines)
        var summary = trimmedWord.isEmpty
            ? "Regenerated after your reading place"
            : "Regenerated after “\(trimmedWord)”"
        if !trimmedRequest.isEmpty {
            summary += " · \(trimmedRequest)"
        }
        return RevisionOrigin(
            kind: .regenerateFromWord,
            summary: summary,
            anchorWord: trimmedWord.isEmpty ? nil : trimmedWord,
            frozenPrefixWordCount: frozenPrefixWordCount
        )
    }

    static func restored(fromRevisionIndex index: Int) -> RevisionOrigin {
        RevisionOrigin(
            kind: .restore,
            summary: "Restored v\(index)",
            restoredFromRevisionIndex: index
        )
    }

    static func imported(source: String) -> RevisionOrigin {
        RevisionOrigin(kind: .imported, summary: "Imported from \(source)")
    }

    static func generated(style: String) -> RevisionOrigin {
        let trimmed = style.trimmingCharacters(in: .whitespacesAndNewlines)
        return RevisionOrigin(
            kind: .generated,
            summary: trimmed.isEmpty ? "Generated from your brief" : "Generated · \(trimmed)"
        )
    }

    static let adapted = RevisionOrigin(kind: .adaptation, summary: "Adapted from your feedback")

    static let regeneratedFromChapter = RevisionOrigin(
        kind: .regenerateFromChapter,
        summary: "Regenerated from this chapter"
    )
}
