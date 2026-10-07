import XCTest

final class ReaderTypefaceUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testGeorgiaIsSelectableInExistingPickerAndReaderRemainsNavigable() {
        let app = launchReader()
        let settings = app.buttons["reader.settings.button"]
        let chapterBefore = app.staticTexts["reader.currentChapter"].label
        let manuscriptBefore = app.textViews["reader.textkit.text"].value as? String
        XCTAssertFalse(manuscriptBefore?.isEmpty ?? true)
        settings.tap()

        let picker = fontPicker(in: app)
        wait(for: picker, predicate: "value == 'Original'")
        openFontChoices(in: app)
        screenshot("georgia-menu-options", app: app)
        app.buttons["Georgia"].tap()
        wait(for: picker, predicate: "value == 'Georgia'")
        screenshot("georgia-picker", app: app)
        app.buttons["reader.settings.done"].tap()
        wait(for: app.buttons["reader.settings.done"], predicate: "exists == false")
        XCTAssertTrue(app.textViews["reader.textkit.text"].waitForExistence(timeout: 6))
        XCTAssertEqual(app.staticTexts["reader.currentChapter"].label, chapterBefore)
        XCTAssertEqual(app.textViews["reader.textkit.text"].value as? String, manuscriptBefore)
        screenshot("georgia-reader", app: app)

        settings.tap()
        wait(for: fontPicker(in: app), predicate: "value == 'Georgia'")
        openFontChoices(in: app)
        app.buttons["Original"].tap()
        wait(for: picker, predicate: "value == 'Original'")
        app.buttons["reader.settings.done"].tap()
        wait(for: app.buttons["reader.settings.done"], predicate: "exists == false")
        XCTAssertEqual(app.staticTexts["reader.currentChapter"].label, chapterBefore)
        XCTAssertEqual(app.textViews["reader.textkit.text"].value as? String, manuscriptBefore)

        app.buttons["reader.toc.button"].tap()
        let chapter2 = app.buttons["reader.toc.chapter.00000000-0000-4000-8000-0000000000C2"]
        XCTAssertTrue(chapter2.waitForExistence(timeout: 6))
        chapter2.tap()
        wait(for: app.navigationBars["Contents"], predicate: "exists == false")
        wait(for: app.staticTexts["reader.currentChapter"], predicate: "label CONTAINS 'Independence Sparks'")
    }

    func testGeorgiaMenuRemainsSelectableAtAccessibilityXXXL() {
        let app = launchReader(accessibilityXXXL: true)
        app.buttons["reader.settings.button"].tap()
        let picker = fontPicker(in: app)
        XCTAssertFalse(app.segmentedControls["reader.font.family"].exists,
                       "Typeface choices must not be squeezed into a segmented control")
        wait(for: picker, predicate: "value == 'Original'")
        openFontChoices(in: app)
        screenshot("georgia-menu-accessibility-xxxl", app: app)
        app.buttons["Georgia"].tap()
        wait(for: picker, predicate: "value == 'Georgia'")
        screenshot("georgia-selected-accessibility-xxxl", app: app)
        app.buttons["reader.settings.done"].tap()
        wait(for: app.buttons["reader.settings.done"], predicate: "exists == false")
    }

    func testGeorgiaReaderBodyKeepsReadableMeasureAtAccessibilityXXXL() {
        let app = launchReader(accessibilityXXXL: true, fontSize: "32")
        app.buttons["reader.settings.button"].tap()
        let picker = fontPicker(in: app)
        wait(for: picker, predicate: "value == 'Original'")
        openFontChoices(in: app)
        app.buttons["Georgia"].tap()
        wait(for: picker, predicate: "value == 'Georgia'")
        app.buttons["reader.settings.done"].tap()
        wait(for: app.buttons["reader.settings.done"], predicate: "exists == false")

        let body = app.textViews["reader.textkit.text"].firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 6))
        let viewport = app.windows.firstMatch.frame
        let bodyFrame = body.frame
        XCTAssertGreaterThan(bodyFrame.width, 280,
                             "Georgia needs a usable text measure at the largest configured size")
        XCTAssertGreaterThan(bodyFrame.height, 0)
        XCTAssertGreaterThanOrEqual(bodyFrame.minX, viewport.minX - 1,
                                    "Reader text must not overflow the leading edge")
        XCTAssertLessThanOrEqual(bodyFrame.maxX, viewport.maxX + 1,
                                 "Reader text must not overflow the trailing edge")
        XCTAssertGreaterThanOrEqual(bodyFrame.minY, viewport.minY - 1)
        XCTAssertLessThanOrEqual(bodyFrame.maxY, viewport.maxY + 1)
        XCTAssertTrue((body.value as? String)?.contains("Think of the land") ?? false,
                      "The full manuscript remains available after the Georgia switch")
        screenshot("georgia-reader-accessibility-xxxl", app: app)
    }

    private func launchReader(accessibilityXXXL: Bool = false, fontSize: String = "18") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uitesting", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-livingreader.reader.fontSize", fontSize,
            "-livingreader.reader.colorScheme", "system",
            "-livingreader.reader.fontFamily", "original",
            "-livingreader.reader.lineSpacing", "1.28",
            "-livingreader.reader.marginInset", "22",
            "-livingreader.reader.pageDim", "0",
            "-livingreader.reader.scrollMode", "scroll"
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
        XCTAssertTrue(app.buttons["reader.settings.button"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.textViews["reader.textkit.text"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["reader.currentChapter"].waitForExistence(timeout: 6))
        return app
    }

    private func fontPicker(in app: XCUIApplication) -> XCUIElement {
        XCTAssertTrue(app.buttons["reader.settings.done"].waitForExistence(timeout: 6))
        let picker = app.buttons["reader.font.family"]
        reveal(picker, in: app)
        XCTAssertTrue(picker.waitForExistence(timeout: 6))
        wait(for: picker, predicate: "hittable == true")
        return picker
    }

    private func openFontChoices(in app: XCUIApplication) {
        fontPicker(in: app).tap()
        for label in ["Original", "Serif", "Sans", "Georgia"] {
            let choice = app.buttons[label]
            XCTAssertTrue(choice.waitForExistence(timeout: 6), "Missing native typeface menu choice: \(label)")
            wait(for: choice, predicate: "hittable == true")
        }
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<4 {
            if element.exists && element.isHittable { return }
            let lists = app.collectionViews.allElementsBoundByIndex
                + app.tables.allElementsBoundByIndex + app.scrollViews.allElementsBoundByIndex
            guard let list = lists.first(where: { $0.isHittable }) else { return }
            if element.exists && element.frame.minY < list.frame.minY {
                list.swipeDown()
            } else {
                list.swipeUp()
            }
        }
    }

    private func wait(for element: XCUIElement, predicate: String) {
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: predicate), object: element
        )], timeout: 6)
        if result != .completed { screenshot("typeface-failure", app: XCUIApplication()) }
        XCTAssertEqual(result, .completed, "\(element.identifier): \(predicate)")
    }

    private func screenshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
