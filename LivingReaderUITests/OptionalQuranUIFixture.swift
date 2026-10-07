import Foundation
import XCTest

/// The UI runner does not contain app resources; check only this test's checkout.
/// This is not a fallback to another workspace or permission to read a personal book.
enum OptionalQuranUIFixture {
    static func isPresent() throws -> Bool {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let resource = root.appendingPathComponent("Resources/Fixtures/quran_pickthall.json")
            .standardizedFileURL.resolvingSymlinksInPath()
        guard resource.path.hasPrefix(root.path + "/Resources/Fixtures/") else {
            throw NSError(domain: "GenBooksUITestFixture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Optional resource must remain inside this checkout's Resources/Fixtures directory."])
        }
        return FileManager.default.fileExists(atPath: resource.path)
    }

    static func requirePresence() throws {
        guard try isPresent() else {
            throw XCTSkip("Optional Tanzil Pickthall edition is omitted from the public distribution; this edition-specific UI journey was not executed.")
        }
    }
}
