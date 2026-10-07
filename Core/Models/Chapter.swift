import Foundation

enum ChapterManuscriptStatus: String, Codable, Equatable, Hashable, Sendable {
    /// Fully authored prose ready for first-run reading.
    case polished
    /// Structured outline / beats; expandable via Living Book adaptation / authoring.
    case outline
}

struct Chapter: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var bookId: UUID
    var title: String
    var orderIndex: Int
    /// Revision currently surfaced for *unread* reading. Ignored when consumed ledger pins past.
    var activeRevisionId: UUID? = nil
    /// Append-only revision history. Never delete a revision that appears in the consumed ledger.
    var revisions: [ChapterRevision]
    /// polished = ship-quality prose; outline = structured future chapter awaiting expansion.
    var manuscriptStatus: ChapterManuscriptStatus? = .polished
    /// Era / chronology anchors for outline chapters and TOC context.
    var eraLabel: String? = nil
    /// Short outline beats preserved even after expansion (for regenerators).
    var outlineBeats: [String]? = nil
    var sourceGrounding: SourceGroundingRequirement? = nil

    func revision(id: UUID) -> ChapterRevision? {
        revisions.first { $0.id == id }
    }

    var activeRevision: ChapterRevision? {
        if let activeRevisionId, let match = revision(id: activeRevisionId) {
            return match
        }
        return revisions.max(by: { $0.revisionIndex < $1.revisionIndex })
    }

    var isOutlineStub: Bool {
        (manuscriptStatus ?? .polished) == .outline
    }
}
