import Foundation
import XCTest

/// Presence only: absent optional content may skip a content-specific check.
/// A present unreadable or malformed edition still reaches the normal decoder and fails.
enum OptionalQuranFixture {
    static func isPresent() throws -> Bool {
        if Bundle.main.url(forResource: "quran_pickthall", withExtension: "json", subdirectory: "Fixtures") != nil
            || Bundle.main.url(forResource: "quran_pickthall", withExtension: "json") != nil { return true }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let resource = root.appendingPathComponent("Resources/Fixtures/quran_pickthall.json")
            .standardizedFileURL.resolvingSymlinksInPath()
        guard resource.path.hasPrefix(root.path + "/Resources/Fixtures/") else {
            throw NSError(domain: "GenBooksTestFixture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Optional resource must remain inside this checkout's Resources/Fixtures directory."])
        }
        return FileManager.default.fileExists(atPath: resource.path)
    }

    static func requirePresence() throws {
        guard try isPresent() else {
            throw XCTSkip("Optional Tanzil Pickthall edition is omitted from the public distribution; no translation-content assertion was executed.")
        }
    }
}
