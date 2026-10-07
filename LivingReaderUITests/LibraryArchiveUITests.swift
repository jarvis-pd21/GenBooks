import XCTest

final class LibraryArchiveUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testArchiveAndRestoreAreVisibleAndPersistAcrossRelaunch() {
        let id = "00000000-0000-4000-8000-000000000001"
        let app = XCUIApplication()
        app.launchArguments = ["-uitesting", "-useMockAI", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        defer { app.terminate() }
        app.launch()
        let archiveEntry = app.buttons["library.archive.button"].firstMatch
        XCTAssertTrue(archiveEntry.waitForExistence(timeout: 15))
        // A previous interrupted fixture run may have left this reversible action
        // applied. Recover through the actual Archive UI, never mutate its store.
        if !app.buttons["library.book.\(id)"].firstMatch.exists {
            archiveEntry.tap()
            let restore = app.buttons["library.archive.restore.\(id)"].firstMatch
            XCTAssertTrue(restore.waitForExistence(timeout: 8))
            restore.tap()
            app.buttons["library.archive.done"].firstMatch.tap()
        }
        let more = app.buttons["library.book.more.\(id)"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 8))
        XCTAssertTrue(more.isHittable)
        more.tap()
        let archive = app.buttons["library.book.archive.\(id)"].firstMatch
        XCTAssertTrue(archive.waitForExistence(timeout: 5))
        archive.tap()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                               object: app.buttons["library.book.\(id)"].firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
        XCTAssertFalse(app.descendants(matching: .any)["reader.screen"].firstMatch.exists,
                       "The card menu must not accidentally open the reader")
        app.terminate()
        app.launch()
        XCTAssertTrue(archiveEntry.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["library.book.\(id)"].firstMatch.exists)
        archiveEntry.tap()
        let restore = app.buttons["library.archive.restore.\(id)"].firstMatch
        XCTAssertTrue(restore.waitForExistence(timeout: 8))
        XCTAssertTrue(restore.isHittable)
        let archived = XCTAttachment(screenshot: app.screenshot())
        archived.name = "library-archive-restorable"
        archived.lifetime = .keepAlways
        add(archived)
        restore.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: restore)], timeout: 5), .completed)
        app.buttons["library.archive.done"].firstMatch.tap()
        let book = app.buttons["library.book.\(id)"].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 8))
        book.tap()
        XCTAssertTrue(app.descendants(matching: .any)["reader.screen"].firstMatch.waitForExistence(timeout: 8))
    }
}
