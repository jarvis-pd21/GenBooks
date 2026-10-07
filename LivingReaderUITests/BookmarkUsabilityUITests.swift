import XCTest

final class BookmarkUsabilityUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testVisibleActionsRenameCancelDeleteAndReopen() throws {
        let app = makeApp()
        defer { app.terminate() }
        app.launch()
        openArgentina(app)
        let create = app.buttons["selection.bookmark"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        create.tap()
        openBookmarks(app)
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "bookmarks.row.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        let rowID = row.identifier
        let actionsID = rowID.replacingOccurrences(of: "bookmarks.row.", with: "bookmarks.actions.")
        let actions = app.buttons[actionsID].firstMatch
        XCTAssertTrue(actions.isHittable, "Rename and Delete are discoverable without a swipe")
        XCTAssertGreaterThanOrEqual(actions.frame.width, 44)
        actions.tap()
        app.buttons["Rename"].firstMatch.tap()
        let field = app.textFields["bookmarks.rename.field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 6))
        clearRenameField(field, in: app)
        let save = app.buttons["bookmarks.rename.save"].firstMatch
        XCTAssertFalse(save.isEnabled, "A blank title cannot silently appear saved")
        let title = "Usability saved place"
        field.typeText(title)
        XCTAssertEqual(field.value as? String, title)
        app.buttons["bookmarks.rename.cancel"].firstMatch.tap()
        let keep = app.buttons["Keep editing"].firstMatch
        XCTAssertTrue(keep.waitForExistence(timeout: 5))
        keep.tap()
        XCTAssertEqual(field.value as? String, title, "Keep editing must preserve the draft")
        save.tap()
        XCTAssertTrue(app.buttons[rowID].firstMatch.waitForExistence(timeout: 6))
        screenshot("bookmarks-visible-actions-and-renamed-row", app)

        app.terminate()
        app.launchArguments.removeAll { $0 == "-phase3DemoSelection" }
        app.launch()
        openArgentina(app)
        openBookmarks(app)
        let reopened = app.buttons[rowID].firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 8))
        XCTAssertTrue(reopened.label.contains(title))

        app.buttons[actionsID].firstMatch.tap()
        app.buttons["Delete bookmark"].firstMatch.tap()
        let alert = app.alerts["Delete bookmark?"].firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(reopened.exists)
        app.buttons[actionsID].firstMatch.tap()
        app.buttons["Delete bookmark"].firstMatch.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        // iOS exposes the same alert action as nested accessibility buttons.
        // Both identify this confirmed action; select its first native match.
        alert.buttons["bookmarks.delete.confirm"].firstMatch.tap()
        assertAbsent(reopened)
        app.terminate()
        app.launch()
        openArgentina(app)
        openBookmarks(app)
        XCTAssertFalse(app.buttons[rowID].firstMatch.exists, "Deletion must survive reopening")
    }

    func testBookmarksNoResultsCanClearSearchAtLargeText() throws {
        let app = makeApp()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        defer { app.terminate() }
        app.launch()
        openArgentina(app)
        let create = app.buttons["selection.bookmark"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        create.tap()
        openBookmarks(app)
        let search = app.searchFields.firstMatch
        if !search.isHittable { app.swipeDown() }
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("zzzz-no-saved-bookmark-zzzz")
        let clear = app.buttons["bookmarks.search.clear"].firstMatch
        for _ in 0..<3 where !clear.isHittable { app.swipeUp() }
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        XCTAssertTrue(clear.isHittable)
        XCTAssertFalse(app.staticTexts["bookmarks.empty"].exists)
        screenshot("bookmarks-large-text-search-recovery", app)
        clear.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "bookmarks.row.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
    }

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitesting", "-phase3DemoSelection", "-AppleLanguages", "(en)",
                               "-AppleLocale", "en_US", "-livingreader.reader.scrollMode", "scroll"]
        return app
    }

    private func clearRenameField(_ field: XCUIElement, in app: XCUIApplication) {
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        // The first keyboard animation can move the caret after our tap. Use
        // the settled field's current trailing position and re-read its value;
        // never treat an attempted batch of deletes as proof that it is empty.
        for _ in 0..<3 {
            let remaining = field.value as? String ?? ""
            if remaining.isEmpty || remaining == "Bookmark title" { break }
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.90)).tap()
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: remaining.utf16.count))
        }
        let remaining = field.value as? String ?? ""
        XCTAssertTrue(remaining.isEmpty || remaining == "Bookmark title",
                      "The real title field must be empty before checking disabled Save; remaining: \(remaining)")
    }

    private func openArgentina(_ app: XCUIApplication) {
        let book = app.buttons["library.book.00000000-0000-4000-8000-000000000001"].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 15))
        book.tap()
    }

    private func openBookmarks(_ app: XCUIApplication) {
        let more = app.buttons["reader.more.button"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 8))
        // The reader remains in the hierarchy during selection-sheet dismissal.
        // Wait until it actually accepts taps before requesting the next sheet.
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: more)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 6), .completed)
        more.tap()
        let bookmarks = app.buttons["reader.bookmarks.button"].firstMatch
        XCTAssertTrue(bookmarks.waitForExistence(timeout: 6))
        bookmarks.tap()
        XCTAssertTrue(app.descendants(matching: .any)["bookmarks.list"].firstMatch.waitForExistence(timeout: 8))
    }

    private func assertAbsent(_ element: XCUIElement) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 6), .completed)
    }

    private func screenshot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
