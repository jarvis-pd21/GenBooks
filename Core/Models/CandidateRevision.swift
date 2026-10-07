import Foundation

enum CandidateStatus: String, Codable, Equatable, Hashable, Sendable {
    case staged
    case rejected
    case activated
}

/// Staged AI/generated revision awaiting validation + atomic activation.
struct CandidateRevision: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var bookId: UUID
    var chapterId: UUID
    var proposedRevisionIndex: Int
    var createdAt: Date
    var blocks: [ContentBlock]
    var status: CandidateStatus
    var rejectionReason: String?
    /// Carried onto the activated revision so version history can explain the change.
    var origin: RevisionOrigin? = nil
    var sourceReview: SourceReviewReceipt? = nil
}
