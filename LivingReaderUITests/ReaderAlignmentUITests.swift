import XCTest

final class ReaderAlignmentUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testJustifyToggleUpdatesReaderAndReopensWithoutChangingText() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uitesting", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-livingreader.reader.fontSize", "18",
            "-livingreader.reader.colorScheme", "light",
            "-livingreader.reader.fontFamily", "original",
            "-livingreader.reader.lineSpacing", "1.28",
            "-livingreader.reader.marginInset", "22",
            "-livingreader.reader.pageDim", "0",
            "-livingreader.reader.scrollMode", "scroll",
            "-livingreader.reader.justified", "NO"
        ]
        app.launch()
        let book = app.descendants(matching: .any)["library.book.00000000-0000-4000-8000-000000000001"].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 12))
        book.tap()
        let settings = app.buttons["reader.settings.button"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8))
        let chapterBefore = app.staticTexts["reader.currentChapter"].label
        let manuscriptBefore = app.textViews["reader.textkit.text"].value as? String
        XCTAssertFalse(manuscriptBefore?.isEmpty ?? true)
        screenshot("alignment-natural-reader", app: app)

        settings.tap()
        let toggle = revealAlignmentSwitch(app: app)
        XCTAssertEqual(toggle.value as? String, "0")
        tapSwitchControl(toggle)
        wait(for: toggle, predicate: "value == '1'")
        screenshot("alignment-settings-on", app: app)
        closeSettings(app: app)
        XCTAssertEqual(app.staticTexts["reader.currentChapter"].label, chapterBefore)
        XCTAssertEqual(app.textViews["reader.textkit.text"].value as? String, manuscriptBefore)
        screenshot("alignment-justified-reader", app: app)

        settings.tap()
        let reopened = revealAlignmentSwitch(app: app)
        XCTAssertEqual(reopened.value as? String, "1", "Reopening settings must retain the choice")
        tapSwitchControl(reopened)
        wait(for: reopened, predicate: "value == '0'")
        closeSettings(app: app)
        XCTAssertEqual(app.staticTexts["reader.currentChapter"].label, chapterBefore)
        XCTAssertEqual(app.textViews["reader.textkit.text"].value as? String, manuscriptBefore)
        screenshot("alignment-natural-restored", app: app)

        app.buttons["reader.toc.button"].tap()
        let chapter2 = app.buttons["reader.toc.chapter.00000000-0000-4000-8000-0000000000C2"]
        XCTAssertTrue(chapter2.waitForExistence(timeout: 6))
        chapter2.tap()
        wait(for: app.navigationBars["Contents"], predicate: "exists == false")
        wait(for: app.staticTexts["reader.currentChapter"], predicate: "label CONTAINS 'Independence Sparks'")
    }

    func testJustifiedBodyKeepsReadableMeasureAtAccessibilityXXXL() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uitesting", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
            "-livingreader.reader.fontSize", "32",
            "-livingreader.reader.colorScheme", "light",
            "-livingreader.reader.fontFamily", "original",
            "-livingreader.reader.lineSpacing", "1.28",
            "-livingreader.reader.marginInset", "22",
            "-livingreader.reader.pageDim", "0",
            "-livingreader.reader.scrollMode", "scroll",
            "-livingreader.reader.justified", "YES"
        ]
        app.launch()
        let book = app.descendants(matching: .any)["library.book.00000000-0000-4000-8000-000000000001"].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 12))
        book.tap()

        let body = app.textViews["reader.textkit.text"].firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 8))
        let viewport = app.windows.firstMatch.frame
        let bodyFrame = body.frame
        XCTAssertGreaterThan(bodyFrame.width, 280,
                             "Justified body text needs a usable reading measure at the largest configured size")
        XCTAssertGreaterThan(bodyFrame.height, 0)
        XCTAssertGreaterThanOrEqual(bodyFrame.minX, viewport.minX - 1,
                                    "Reader text must not overflow the leading edge")
        XCTAssertLessThanOrEqual(bodyFrame.maxX, viewport.maxX + 1,
                                 "Reader text must not overflow the trailing edge")
        XCTAssertGreaterThanOrEqual(bodyFrame.minY, viewport.minY - 1)
        XCTAssertLessThanOrEqual(bodyFrame.maxY, viewport.maxY + 1)
        XCTAssertTrue((body.value as? String)?.contains("Think of the land") ?? false,
                      "The full manuscript remains available after enabling justification")
        app.buttons["reader.settings.button"].tap()
        let toggle = revealAlignmentSwitch(app: app)
        XCTAssertEqual(toggle.value as? String, "1", "The high-size reader must actually use justified body text")
        closeSettings(app: app)
        screenshot("justified-reader-accessibility-xxxl", app: app)
    }

    private func revealAlignmentSwitch(app: XCUIApplication) -> XCUIElement {
        XCTAssertTrue(app.buttons["reader.settings.done"].waitForExistence(timeout: 6))
        let toggle = app.switches["reader.justified.toggle"].firstMatch
        for _ in 0..<3 {
            if toggle.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(toggle.isHittable)
        XCTAssertEqual(toggle.label, "Justify body text")
        return toggle
    }

    private func closeSettings(app: XCUIApplication) {
        app.buttons["reader.settings.done"].tap()
        wait(for: app.buttons["reader.settings.done"], predicate: "exists == false")
        XCTAssertTrue(app.textViews["reader.textkit.text"].waitForExistence(timeout: 6))
    }

    private func tapSwitchControl(_ toggle: XCUIElement) {
        // SwiftUI exposes the whole Form row as the switch's accessibility frame.
        // Target the visible trailing switch, not the label/empty row center.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    }

    private func wait(for element: XCUIElement, predicate: String) {
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: predicate), object: element
        )], timeout: 6)
        if result != .completed { screenshot("alignment-failure", app: XCUIApplication()) }
        XCTAssertEqual(result, .completed, "\(element.identifier): \(predicate)")
    }

    private func screenshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
