import Foundation

/// Stable IDs for the Argentina manuscript fixture (tests + seed).
enum ArgentinaFixtureIDs {
    static let book = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    static let edition = UUID(uuidString: "00000000-0000-4000-8000-0000000000e1")!
    static let chapter1 = UUID(uuidString: "00000000-0000-4000-8000-0000000000c1")!
    static let chapter2 = UUID(uuidString: "00000000-0000-4000-8000-0000000000c2")!
    static let chapter1Revision1 = UUID(uuidString: "00000000-0000-4000-8000-0000000000a1")!
    static let chapter2Revision1 = UUID(uuidString: "00000000-0000-4000-8000-0000000000a2")!
    static let block1Heading = UUID(uuidString: "00000000-0000-4000-8000-0000000000b1")!
    static let block1Body = UUID(uuidString: "00000000-0000-4000-8000-0000000000b2")!
    static let block1Quote = UUID(uuidString: "00000000-0000-4000-8000-0000000000b3")!
    static let block2Heading = UUID(uuidString: "00000000-0000-4000-8000-0000000000b4")!
    static let block2Body = UUID(uuidString: "00000000-0000-4000-8000-0000000000b5")!
    static let block1Body2 = UUID(uuidString: "00000000-0000-4000-8000-0000000000b6")!
    static let block1Body3 = UUID(uuidString: "00000000-0000-4000-8000-0000000000b7")!
    static let block2Body2 = UUID(uuidString: "00000000-0000-4000-8000-0000000000b8")!
    static let block2Quote = UUID(uuidString: "00000000-0000-4000-8000-0000000000b9")!

    /// Known searchable phrase present in the fixture quote block.
    static let searchablePhrase = "Geography is destiny only until people rewrite the map."

    /// Phase 6 expectations.
    static let expectedMinChapters = 20
    static let expectedMinPolishedChapters = 6
    static let expectedMinWordCount = 25_000
}
