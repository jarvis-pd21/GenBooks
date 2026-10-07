import Foundation

/// Optional edition metadata for a manuscript seed or localized cut.
struct BookEdition: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var bookId: UUID
    var label: String
    var localeIdentifier: String
}
