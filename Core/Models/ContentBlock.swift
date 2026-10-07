import Foundation

enum ContentBlockKind: String, Codable, Equatable, Hashable, Sendable {
    case paragraph
    case heading
    case quote
    case callout
    case imagePlaceholder
}

struct ContentBlock: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var kind: ContentBlockKind
    var text: String
    var orderIndex: Int
}
