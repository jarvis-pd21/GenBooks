import Foundation

/// Chronology entry for the Living Book timeline (library / TOC companion).
struct TimelineEvent: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var yearLabel: String
    var title: String
    var summary: String
    var relatedChapterId: UUID? = nil
    var orderIndex: Int
}
