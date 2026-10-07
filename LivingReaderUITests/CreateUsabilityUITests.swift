import XCTest

final class CreateUsabilityUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testClosingUnsubmittedTextOffersKeepEditingAndExplicitDiscard() {
        let app = launch()
        defer { app.terminate() }
        app.buttons["library.create.button"].tap()
        let title = app.textFields["create.import.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        title.tap()
        title.typeText("My unsaved book title")
        app.buttons["create.close"].tap()
        XCTAssertTrue(app.buttons["Keep editing"].waitForExistence(timeout: 5))
        app.buttons["Keep editing"].tap()
        XCTAssertEqual(title.value as? String, "My unsaved book title")
        app.buttons["create.close"].tap()
        XCTAssertTrue(app.buttons["Discard changes"].waitForExistence(timeout: 5))
        app.buttons["Discard changes"].tap()
        XCTAssertTrue(app.buttons["library.create.button"].waitForExistence(timeout: 8))
        app.buttons["library.create.button"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        XCTAssertNotEqual(title.value as? String, "My unsaved book title")
    }

    func testEPUBInstructionsScrollAndCloseAtAccessibilityTextSize() {
        let app = launch(largeText: true)
        defer { app.terminate() }
        app.buttons["library.create.button"].tap()
        let help = app.buttons["create.import.epub.help"].firstMatch
        XCTAssertTrue(help.waitForExistence(timeout: 8))
        for _ in 0..<5 { if help.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(help.isHittable)
        help.tap()
        let last = app.staticTexts["Or tap Choose EPUB here. DRM-protected files are refused."].firstMatch
        XCTAssertTrue(last.waitForExistence(timeout: 8))
        // Hittable alone also accepts a partially clipped paragraph. Prove the
        // final instruction can be brought fully above the sheet's bottom edge.
        for _ in 0..<6 {
            if last.isHittable && last.frame.maxY < app.frame.maxY - 40 { break }
            app.swipeUp()
        }
        XCTAssertTrue(last.isHittable)
        XCTAssertLessThan(last.frame.maxY, app.frame.maxY - 40)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "epub-instructions-accessibility"
        shot.lifetime = .keepAlways
        add(shot)
        let done = app.buttons["create.import.epub.help.done"].firstMatch
        XCTAssertTrue(done.isHittable)
        done.tap()
        XCTAssertTrue(app.buttons["create.close"].waitForExistence(timeout: 5))
    }

    private func launch(largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitesting", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-UIPreferredContentSizeCategoryName", largeText ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL"]
        app.launch()
        XCTAssertTrue(app.buttons["library.create.button"].waitForExistence(timeout: 15))
        return app
    }
}
