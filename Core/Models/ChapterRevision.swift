import Foundation

struct ChapterRevision: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var chapterId: UUID
    var revisionIndex: Int
    var createdAt: Date
    var blocks: [ContentBlock]
    /// Soft flag mirrored from ledger for convenience; ledger is source of truth once consumed.
    var isConsumed: Bool
    /// Why this revision exists. Absent on manuscripts authored before version provenance existed.
    var origin: RevisionOrigin? = nil
    var sourceReview: SourceReviewReceipt? = nil
}
