import XCTest

final class PagesNavigationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testArgentinaFirstChapterCanTurnForwardAndBackwardOnPagesLaunch() {
        verifyPageTurns(launchMode: "pages")
    }

    func testArgentinaFirstChapterCanTurnAfterSwitchingFromScroll() {
        verifyPageTurns(launchMode: "scroll")
    }

    // Covers navigation and control reachability, not glyph-level page boundaries.
    // Full manuscript accessibility values cannot prove every line is visible.
    func testGeorgiaMaximumBodySizeKeepsPageControlsReachableAtAccessibilityXXXL() {
        XCUIDevice.shared.orientation = .portrait
        verifyPageTurns(launchMode: "pages", fontFamily: "georgia", fontSize: "32",
                        accessibilityXXXL: true)
    }

    func testPageSwipePriorityPreservesEdgeButtonAndScrollNavigation() {
        let app = verifyPageTurns(launchMode: "pages")
        let library = app.descendants(matching: .any)["library.screen"].firstMatch
        let book = app.descendants(matching: .any)["library.book.00000000-0000-4000-8000-000000000001"].firstMatch
        let text = app.textViews["reader.textkit.text"]
        let window = app.windows.firstMatch

        // The screen-edge Back remains distinct from an in-page previous-page swipe.
        let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.55))
        let across = window.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.55))
        edge.press(forDuration: 0.01, thenDragTo: across, withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(library.waitForExistence(timeout: 8))

        book.tap()
        XCTAssertTrue(text.waitForExistence(timeout: 8))
        let back = app.navigationBars.buttons["Library"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 6))
        back.tap()
        XCTAssertTrue(library.waitForExistence(timeout: 8))

        // Reenter and switch to Scroll after the page dependency has existed.
        // A content-wide horizontal Back is not supported by the fresh Scroll
        // baseline either; verify vertical reading and screen-edge Back here.
        book.tap()
        XCTAssertTrue(text.waitForExistence(timeout: 8))
        app.buttons["reader.settings.button"].tap()
        let scroll = app.buttons["reader.scrollMode.scroll"].firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 6))
        scroll.tap()
        app.buttons["reader.settings.done"].tap()
        wait(for: app.buttons["reader.settings.done"], predicate: "exists == false", app: app)
        wait(for: app.buttons["reader.page.status"], predicate: "exists == false", app: app)
        let progress = app.staticTexts["reader.progress.label"].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 6))
        let beforeScroll = progress.label
        text.swipeUp()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@", beforeScroll), object: progress
        )], timeout: 8), .completed, "Vertical scrolling must update the reading position")
        XCTAssertTrue(text.exists)
        edge.press(forDuration: 0.01, thenDragTo: across, withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(library.waitForExistence(timeout: 8))
    }

    @discardableResult
    private func verifyPageTurns(launchMode: String, fontFamily: String = "original",
                                 fontSize: String = "18", accessibilityXXXL: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uitesting", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-livingreader.reader.fontSize", fontSize,
            "-livingreader.reader.colorScheme", "system",
            "-livingreader.reader.fontFamily", fontFamily,
            "-livingreader.reader.lineSpacing", "1.28",
            "-livingreader.reader.marginInset", "22",
            "-livingreader.reader.pageDim", "0",
            "-livingreader.reader.scrollMode", launchMode
        ]
        if accessibilityXXXL {
            app.launchArguments += [
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
            ]
        }
        app.launch()
        let book = app.descendants(matching: .any)["library.book.00000000-0000-4000-8000-000000000001"].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 12))
        book.tap()
        let contents = app.buttons["reader.toc.button"]
        XCTAssertTrue(contents.waitForExistence(timeout: 8))
        contents.tap()
        let chapter = app.buttons["reader.toc.chapter.00000000-0000-4000-8000-0000000000C1"]
        XCTAssertTrue(chapter.waitForExistence(timeout: 6))
        chapter.tap()
        wait(for: app.navigationBars["Contents"], predicate: "exists == false", app: app)
        XCTAssertTrue(app.staticTexts["reader.currentChapter"].label.contains("Before the Nation"))

        if launchMode == "scroll" {
            app.buttons["reader.settings.button"].tap()
            var pages = app.buttons["reader.scrollMode.pages"].firstMatch
            if !pages.waitForExistence(timeout: 2) {
                pages = app.descendants(matching: .any)["reader.scrollMode.picker"].buttons["Pages"].firstMatch
            }
            XCTAssertTrue(pages.waitForExistence(timeout: 6))
            pages.tap()
            app.buttons["reader.settings.done"].tap()
            wait(for: app.buttons["reader.settings.done"], predicate: "exists == false", app: app)
        }

        let status = app.buttons["reader.page.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 6))
        let next = app.buttons["reader.page.next"]
        wait(for: next, predicate: "enabled == true", app: app)
        let firstPage = status.label
        XCTAssertTrue(firstPage.hasPrefix("Page 1 of "), firstPage)
        XCTAssertFalse(firstPage.hasPrefix("Page 1 of 1."), "Argentina C1 cannot fit on one page")
        let text = app.textViews["reader.textkit.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        if accessibilityXXXL {
            let viewport = app.windows.firstMatch.frame.insetBy(dx: -1, dy: -1)
            XCTAssertGreaterThan(text.frame.width, 280, "Georgia needs a usable reading measure")
            XCTAssertGreaterThan(text.frame.height, 200, "Page chrome must leave room for the text")
            XCTAssertTrue(viewport.contains(text.frame), "The page must remain a screen-sized viewport")
            XCTAssertTrue(status.isHittable && viewport.contains(status.frame))
            XCTAssertTrue(next.isHittable && viewport.contains(next.frame))
        }
        let startText = text.value as? String
        XCTAssertFalse(startText?.isEmpty ?? true, "Expected real manuscript text, not two absent values")
        next.tap()
        wait(for: status, predicate: "label BEGINSWITH 'Page 2 of '", app: app)
        XCTAssertEqual(app.staticTexts["reader.currentChapter"].label, "Before the Nation")
        let previous = app.buttons["reader.page.prev"]
        XCTAssertTrue(previous.isEnabled)
        if accessibilityXXXL {
            XCTAssertTrue(previous.isHittable && app.windows.firstMatch.frame.contains(previous.frame),
                          "Previous must stay fully reachable with large page controls")
        }
        screenshot("pages-advanced-\(launchMode)", app: app)
        previous.tap()
        // TextKit refines its whole-book height estimate while laying out text.
        // Returning to page 1 is required; an immutable estimated total is not.
        wait(for: status, predicate: "label BEGINSWITH 'Page 1 of '", app: app)
        XCTAssertEqual(text.value as? String, startText, "Page turns must not change the manuscript")
        XCTAssertFalse(previous.isEnabled)
        screenshot("pages-returned-\(launchMode)", app: app)

        swipeInsideText(text, forward: true)
        wait(for: status, predicate: "label BEGINSWITH 'Page 2 of '", app: app)
        swipeInsideText(text, forward: false)
        wait(for: status, predicate: "label BEGINSWITH 'Page 1 of '", app: app)
        XCTAssertFalse(previous.isEnabled)
        XCTAssertTrue(next.isEnabled)
        XCTAssertEqual(text.value as? String, startText)
        screenshot("pages-swipes-returned-\(launchMode)", app: app)
        return app
    }

    private func swipeInsideText(_ text: XCUIElement, forward: Bool) {
        // Stay clear of iOS's screen-edge Back gesture; exercise the reader's
        // own horizontal page recognizers rather than navigation-stack dismissal.
        let start = text.coordinate(withNormalizedOffset: CGVector(dx: forward ? 0.75 : 0.30, dy: 0.55))
        let end = text.coordinate(withNormalizedOffset: CGVector(dx: forward ? 0.30 : 0.75, dy: 0.55))
        start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
    }

    private func wait(for element: XCUIElement, predicate: String, app: XCUIApplication) {
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: predicate), object: element
        )], timeout: 8)
        if result != .completed { screenshot("pages-failure", app: app) }
        let label = element.exists ? element.label : "<absent>"
        XCTAssertEqual(result, .completed, "\(element.identifier): \(predicate); label=\(label)")
    }

    private func screenshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
