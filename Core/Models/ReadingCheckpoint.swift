import Foundation

struct ReadingCheckpoint: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var bookId: UUID
    var chapterId: UUID
    var blockId: UUID?
    var characterOffset: Int
    var updatedAt: Date
}
