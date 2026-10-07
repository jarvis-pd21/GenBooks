import XCTest
@testable import LivingReader

final class APIKeySettingsUsabilityTests: XCTestCase {
    func testBlankSaveLeavesPreviouslySavedKeyUntouched() throws {
        let store = InMemoryAPIKeyStore(key: "offline-fixture-key")
        for draft in ["", " ", "\n\t "] {
            XCTAssertFalse(APIKeySettingsActions.canSave(draft))
            XCTAssertFalse(try APIKeySettingsActions.saveDraft(draft, to: store))
            XCTAssertEqual(try store.loadAPIKey(), "offline-fixture-key")
        }
    }

    func testBlankSaveNeverCallsStorage() throws {
        let store = RejectedWriteStore()
        XCTAssertFalse(try APIKeySettingsActions.saveDraft("  ", to: store))
    }

    func testNonemptySaveTrimsOnlyOuterWhitespace() throws {
        let store = InMemoryAPIKeyStore()
        XCTAssertTrue(APIKeySettingsActions.canSave("  offline-fixture-key\n"))
        XCTAssertTrue(try APIKeySettingsActions.saveDraft("  offline-fixture-key\n", to: store))
        XCTAssertEqual(try store.loadAPIKey(), "offline-fixture-key")
    }

    func testWriteFailureIsNotReportedAsSuccessfulSave() {
        XCTAssertThrowsError(try APIKeySettingsActions.saveDraft("offline-fixture-key", to: RejectedWriteStore()))
    }
}

private struct RejectedWriteStore: APIKeyStoring {
    enum WriteError: Error { case fixtureFailure }
    func loadAPIKey() throws -> String? { nil }
    func saveAPIKey(_ key: String?) throws { throw WriteError.fixtureFailure }
}
