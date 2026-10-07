import Foundation

/// Stable, semantic reading location — content block identity + offset within that block.
/// Not pixel- or viewport-based, so restore survives relaunch, Dynamic Type, and theme changes.
struct ReaderLocation: Equatable, Hashable, Sendable, Codable {
    var chapterId: UUID
    var blockId: UUID
    /// UTF-16 offset into the block's plain text (clamped on restore).
    var characterOffset: Int
    /// Fractional progress through the flattened document (0...1) for chrome only.
    var progress: Double
}

extension ReadingCheckpoint {
    func asLocation(progress: Double = 0) -> ReaderLocation? {
        guard let blockId else { return nil }
        return ReaderLocation(
            chapterId: chapterId,
            blockId: blockId,
            characterOffset: characterOffset,
            progress: progress
        )
    }

    static func from(location: ReaderLocation, bookId: UUID, id: UUID = UUID(), updatedAt: Date = Date()) -> ReadingCheckpoint {
        ReadingCheckpoint(
            id: id,
            bookId: bookId,
            chapterId: location.chapterId,
            blockId: location.blockId,
            characterOffset: location.characterOffset,
            updatedAt: updatedAt
        )
    }
}
