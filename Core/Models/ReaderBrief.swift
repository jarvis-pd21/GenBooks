import Foundation

/// Compact reading contract handed to the Astra generation model.
///
/// A brief is a *projection* of `ReaderPreferenceProfile`, never a second
/// preference store: `ReaderPreferenceEngine` remains the only sanctioned
/// mutator of reader taste. Rebuild with `ReaderBrief.make(book:profile:)`
/// whenever the profile changes.
struct ReaderBrief: Codable, Equatable, Hashable, Sendable {
    var bookId: UUID
    var bookTitle: String
    var bookAuthor: String
    /// Carried verbatim from `ReaderPreferenceProfile.overallTone`.
    var voice: String
    var moreOfEmphasis: [String]
    var lessOfEmphasis: [String]
    var readerNotes: [String]
    /// Standing rules the generation model may never trade away.
    var nonNegotiables: [String]
    var updatedAt: Date
    /// Provenance back to the profile this brief was derived from.
    var sourceProfileUpdatedAt: Date

    /// Weight at or above which a topic is worth spending prompt budget on.
    static let emphasisThreshold: Double = 0.65
    static let maxReaderNotes = 5

    static let standingNonNegotiables = [
        "Never rewrite or contradict a consumed chapter",
        "Keep the reader's expected remaining reading time",
        "Every essential claim must name evidence that exists in the checklist"
    ]

    static func make(book: Book, profile: ReaderPreferenceProfile, at date: Date = Date()) -> ReaderBrief {
        ReaderBrief(
            bookId: book.id,
            bookTitle: book.title,
            bookAuthor: book.author,
            voice: profile.overallTone,
            moreOfEmphasis: emphasised(profile.moreWeights),
            lessOfEmphasis: emphasised(profile.lessWeights),
            readerNotes: Array(profile.freeTextNotes.suffix(maxReaderNotes)),
            nonNegotiables: standingNonNegotiables,
            updatedAt: date,
            sourceProfileUpdatedAt: profile.updatedAt
        )
    }

    /// True when the brief no longer reflects the sanctioned preference profile.
    /// Compared at whole-second resolution, which is what both sides are stored at.
    func isStale(against profile: ReaderPreferenceProfile) -> Bool {
        bookId != profile.bookId
            || Int(sourceProfileUpdatedAt.timeIntervalSince1970) != Int(profile.updatedAt.timeIntervalSince1970)
    }

    private static func emphasised(_ weights: [String: Double]) -> [String] {
        weights
            .filter { $0.value >= emphasisThreshold }
            .sorted { lhs, rhs in
                lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
            }
            .map(\.key)
    }
}
