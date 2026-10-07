import Foundation

/// One chapter's contribution to the running story state.
///
/// Entries for consumed chapters are immutable. A merge preserves them verbatim
/// so the past a reader already read can never be re-narrated underneath them.
struct ContinuityEntry: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var chapterId: UUID
    var chapterTitle: String
    var chapterOrderIndex: Int
    /// Pins the entry to the exact revision text it was derived from.
    var revisionId: UUID
    /// Short prose summary of what this chapter established.
    var digest: String
    var establishedFacts: [String]
    var openThreads: [String]
    /// Mirrors the consumed ledger. Once true, the entry is never rewritten.
    var isConsumed: Bool
    var recordedAt: Date

    static let maxDigestCharacters = 480
}

/// Running continuity for one book, ordered by chapter position.
struct ContinuityState: Codable, Equatable, Hashable, Sendable {
    var bookId: UUID
    /// At most one entry per chapter, sorted by `chapterOrderIndex`.
    var timeline: [ContinuityEntry]
    /// Threads opened but not yet resolved anywhere in the timeline.
    var carriedThreads: [String]
    var updatedAt: Date

    static let maxCarriedThreads = 24

    static func empty(bookId: UUID, at date: Date = Date()) -> ContinuityState {
        ContinuityState(bookId: bookId, timeline: [], carriedThreads: [], updatedAt: date)
    }

    func entry(chapterId: UUID) -> ContinuityEntry? {
        timeline.first { $0.chapterId == chapterId }
    }

    var consumedEntries: [ContinuityEntry] {
        timeline.filter(\.isConsumed)
    }

    var unreadEntries: [ContinuityEntry] {
        timeline.filter { !$0.isConsumed }
    }
}

/// Incremental continuity update produced after a chapter is generated or adapted.
struct ContinuityDelta: Codable, Equatable, Hashable, Sendable {
    var bookId: UUID
    var entries: [ContinuityEntry]
    var resolvedThreads: [String]
    var newThreads: [String]

    init(
        bookId: UUID,
        entries: [ContinuityEntry],
        resolvedThreads: [String] = [],
        newThreads: [String] = []
    ) {
        self.bookId = bookId
        self.entries = entries
        self.resolvedThreads = resolvedThreads
        self.newThreads = newThreads
    }
}

/// Inspectable outcome of merging a delta, so callers can see what a merge refused.
struct ContinuityMergeResult: Equatable, Sendable {
    var state: ContinuityState
    var appendedChapterIds: [UUID]
    var updatedChapterIds: [UUID]
    /// Delta entries dropped because that chapter's consumed entry is immutable.
    var preservedConsumedChapterIds: [UUID]
}
