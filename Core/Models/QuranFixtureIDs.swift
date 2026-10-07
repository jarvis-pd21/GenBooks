import Foundation

/// Stable IDs for the bundled Pickthall Quran (tests + seed). Distinct from Argentina.
enum QuranFixtureIDs {
    static let book = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    static let edition = UUID(uuidString: "00000000-0000-4000-8000-0000000000e2")!
    static let expectedSurahCount = 114
    static let expectedVerseCount = 6_236
    static let fatihahOpening = "In the name of Allah, the Beneficent, the Merciful."
    static let ikhlasOpening = "Say: He is Allah, the One!"
}

enum BundledSeedIDs {
    static func isProtected(_ id: UUID) -> Bool {
        id == ArgentinaFixtureIDs.book || id == QuranFixtureIDs.book
    }
}
