import XCTest

@MainActor
final class ReaderOrientationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    func testUnlockedReaderRotatesAndLandscapeLockHoldsUntilUnlocked() {
        let app = launchReader()
        assertOrientation(app, landscape: false)
        openOrientationSettings(app)
        XCTAssertEqual(lockSwitch(app).value as? String, "0", "Each reader session starts unlocked")
        dismissSettings(app)

        XCUIDevice.shared.orientation = .landscapeLeft
        assertOrientation(app, landscape: true)
        keepScreenshot("orientation-unlocked-landscape-left", app: app)
        XCUIDevice.shared.orientation = .landscapeRight
        assertOrientation(app, landscape: true)

        setLock(true, in: app)
        XCUIDevice.shared.orientation = .portrait
        assertDoesNotRotate(app, toLandscape: false)
        keepScreenshot("orientation-locked-landscape", app: app)

        setLock(false, in: app)
        // A fresh physical change also covers iOS deferring geometry requests
        // until Reading settings has finished dismissing.
        XCUIDevice.shared.orientation = .landscapeLeft
        XCUIDevice.shared.orientation = .portrait
        assertOrientation(app, landscape: false)
        XCTAssertTrue(app.textViews["reader.textkit.text"].exists)
        keepScreenshot("orientation-unlocked-portrait", app: app)
    }

    func testPortraitLockIsReleasedAfterLeavingReaderAndRelaunching() {
        let app = launchReader()
        setLock(true, in: app)
        XCUIDevice.shared.orientation = .landscapeLeft
        assertDoesNotRotate(app, toLandscape: true)
        keepScreenshot("orientation-locked-portrait", app: app)

        let back = app.navigationBars.buttons["Library"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Reader retains its standard Library back button")
        back.tap()
        XCTAssertTrue(app.descendants(matching: .any)["library.screen"].firstMatch.waitForExistence(timeout: 6))
        assertOrientation(app, landscape: false)
        XCUIDevice.shared.orientation = .portrait
        openArgentina(app)
        openOrientationSettings(app)
        XCTAssertEqual(lockSwitch(app).value as? String, "0", "Leaving a reader releases its session lock")
        dismissSettings(app)

        setLock(true, in: app)
        app.terminate()
        app.launch()
        openArgentina(app)
        openOrientationSettings(app)
        XCTAssertEqual(lockSwitch(app).value as? String, "0", "Orientation lock must not persist across app launches")
        keepScreenshot("orientation-new-session-unlocked", app: app)
        dismissSettings(app)
        XCUIDevice.shared.orientation = .landscapeRight
        assertOrientation(app, landscape: true)
    }

    func testAccessibilityXXXLOrientationLockRestoresAfterLeavingReader() {
        let app = launchReader(accessibilityXXXL: true)
        assertOrientation(app, landscape: false)

        openOrientationSettings(app)
        let control = lockSwitch(app)
        let status = app.staticTexts["reader.orientation.status"].firstMatch
        XCTAssertEqual(control.value as? String, "0")
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.isHittable, "Orientation status must remain readable at Accessibility XXXL")

        control.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(control.value as? String, "1")
        XCTAssertEqual(status.label, "Locked in portrait")
        XCTAssertFalse(app.descendants(matching: .any)["reader.orientation.notice"].firstMatch.exists)
        XCTAssertTrue(app.buttons["reader.settings.done"].isHittable,
                      "Reading settings must keep its close action reachable at Accessibility XXXL")
        dismissSettings(app)

        let back = app.navigationBars.buttons["Library"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(app.descendants(matching: .any)["library.screen"].firstMatch.waitForExistence(timeout: 6))
        assertOrientation(app, landscape: false)

        openArgentina(app)
        openOrientationSettings(app)
        XCTAssertEqual(lockSwitch(app).value as? String, "0",
                       "Leaving the reader must restore an unlocked session at Accessibility XXXL")
        XCTAssertEqual(status.label, "Reader rotation unlocked")
        dismissSettings(app)
    }

    private func launchReader(accessibilityXXXL: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uitesting", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-livingreader.reader.fontSize", "18",
            "-livingreader.reader.colorScheme", "system",
            "-livingreader.reader.fontFamily", "original",
            "-livingreader.reader.lineSpacing", "1.28",
            "-livingreader.reader.marginInset", "22",
            "-livingreader.reader.pageDim", "0",
            "-livingreader.reader.wordsPerMinute", "230",
            "-livingreader.reader.scrollMode", "scroll",
            "-livingreader.reader.searchScope", "readSoFar"
        ]
        if accessibilityXXXL {
            app.launchArguments += [
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
            ]
        }
        app.launch()
        openArgentina(app)
        return app
    }

    private func openArgentina(_ app: XCUIApplication) {
        XCTAssertTrue(app.descendants(matching: .any)["library.screen"].firstMatch.waitForExistence(timeout: 12))
        let book = app.descendants(matching: .any)["library.book.00000000-0000-4000-8000-000000000001"].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 8))
        book.tap()
        XCTAssertTrue(app.textViews["reader.textkit.text"].waitForExistence(timeout: 8))
    }

    private func openOrientationSettings(_ app: XCUIApplication) {
        let settings = app.buttons["reader.settings.button"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        let sheet = app.descendants(matching: .any)["reader.settings.sheet"].firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        let control = lockSwitch(app)
        for _ in 0..<7 {
            if control.exists && control.isHittable { break }
            sheet.swipeUp()
        }
        XCTAssertTrue(control.exists && control.isHittable, "Orientation control must be reachable in Reading settings")
        XCTAssertTrue(control.isEnabled)
    }

    private func lockSwitch(_ app: XCUIApplication) -> XCUIElement {
        app.switches["reader.orientation.toggle"].firstMatch
    }

    private func setLock(_ enabled: Bool, in app: XCUIApplication) {
        openOrientationSettings(app)
        let control = lockSwitch(app)
        if control.value as? String != (enabled ? "1" : "0") {
            // SwiftUI exposes the whole row as the switch. Its center is the
            // label; the trailing native control is the actual toggle target.
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        XCTAssertEqual(control.value as? String, enabled ? "1" : "0")
        XCTAssertFalse(app.descendants(matching: .any)["reader.orientation.notice"].firstMatch.exists,
                       "Successful orientation changes must not show an error notice")
        dismissSettings(app)
    }

    private func dismissSettings(_ app: XCUIApplication) {
        let done = app.buttons["reader.settings.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.descendants(matching: .any)["reader.settings.sheet"].firstMatch
        )
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 6), .completed)
        XCTAssertTrue(app.textViews["reader.textkit.text"].waitForExistence(timeout: 5))
    }

    private func assertOrientation(_ app: XCUIApplication, landscape: Bool,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let frameMatches = NSPredicate { _, _ in
            let frame = app.windows.firstMatch.frame
            return landscape ? frame.width > frame.height : frame.height > frame.width
        }
        let expectation = XCTNSPredicateExpectation(predicate: frameMatches, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 6), .completed,
                       "The real application window must adopt the requested orientation", file: file, line: line)
    }

    private func assertDoesNotRotate(_ app: XCUIApplication, toLandscape: Bool,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let unwantedFrame = NSPredicate { _, _ in
            let frame = app.windows.firstMatch.frame
            return toLandscape ? frame.width > frame.height : frame.height > frame.width
        }
        let rotation = XCTNSPredicateExpectation(predicate: unwantedFrame, object: app)
        rotation.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [rotation], timeout: 2), .completed,
                       "A locked reader must retain its application-window orientation", file: file, line: line)
    }

    private func keepScreenshot(_ name: String, app: XCUIApplication) {
        // Screen capture preserves the entire rotated scene; application
        // captures can crop landscape windows to stale portrait bounds.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
