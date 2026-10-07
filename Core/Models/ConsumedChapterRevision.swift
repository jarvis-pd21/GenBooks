import Foundation

/// Permanent ledger entry: the exact revision identity the reader consumed for a chapter.
/// Once written, identity fields must never change (immutable consumed past).
struct ConsumedChapterRevision: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var bookId: UUID
    var chapterId: UUID
    /// Exact ChapterRevision.id that was read — permanently pinned.
    var revisionId: UUID
    var revisionIndex: Int
    var consumedAt: Date
}
