import Foundation

/// Bundled human-readable foundations also used to generate the public documentation.
struct FoundationsContent: Decodable, Sendable {
    let version: Int
    let mission: String
    let vision: String
    let sections: [Section]

    struct Section: Decodable, Identifiable, Sendable {
        let id: String
        let title: String
        let summary: String
        let paragraphs: [String]
        let bullets: [String]
        let references: [Reference]
    }
    struct Reference: Decodable, Sendable {
        let title: String
        let url: URL
    }

    static func load(bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: "foundations", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}
