import XCTest

final class AppStoreReadinessUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitesting", "-useMockAI", "-AppleLanguages", "(en)",
                               "-AppleLocale", "en_US", "-livingreader.reader.colorScheme", "light"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 20))
        app.tabBars.buttons["Library"].tap()
        return app
    }

    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<8 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }

    private func tapSwitchControl(_ toggle: XCUIElement) {
        // SwiftUI exposes the whole Form row as the switch's accessibility frame.
        // Target the visible trailing switch, not the label/empty row center.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    }

    private func capture(_ name: String, app: XCUIApplication) throws {
        let dir = try UITestArtifactDirectory.require(sourceFile: #filePath)
        try app.screenshot().pngRepresentation.write(to: dir.appendingPathComponent(name + ".png"))
    }

    func testPrivacyControlsRequireAnExplicitChoiceAndPersistRevocation() throws {
        let app = launch()
        defer { app.terminate() }
        app.buttons["library.settings.button"].tap()
        app.buttons["settings.bookbot"].tap()
        let permission = app.switches["ai.settings.sharing.allowed"]
        reveal(permission, app: app)
        XCTAssertEqual(permission.value as? String, "0", "A fresh install must not infer permission from a key.")
        tapSwitchControl(permission)
        let consentAlert = app.alerts["Allow sharing with OpenAI?"].firstMatch
        XCTAssertTrue(consentAlert.waitForExistence(timeout: 5))
        try capture("release-openai-permission", app: app)
        // iOS can expose the same SwiftUI alert action as nested accessibility buttons.
        consentAlert.buttons.matching(identifier: "ai.settings.sharing.cancel").firstMatch.tap()
        XCTAssertEqual(permission.value as? String, "0")
        tapSwitchControl(permission)
        XCTAssertTrue(consentAlert.waitForExistence(timeout: 5))
        consentAlert.buttons.matching(identifier: "ai.settings.sharing.confirm").firstMatch.tap()
        XCTAssertEqual(permission.value as? String, "1")
        tapSwitchControl(permission)
        XCTAssertEqual(permission.value as? String, "0")
        app.terminate()
        app.launch()
        app.tabBars.buttons["Library"].tap()
        app.buttons["library.settings.button"].tap()
        app.buttons["settings.bookbot"].tap()
        reveal(permission, app: app)
        XCTAssertEqual(permission.value as? String, "0", "Revocation must survive a new launch.")
    }

    func testPrivacyAndSupportAreReadableInsideSettings() throws {
        let app = launch()
        defer { app.terminate() }
        try capture("release-library", app: app)
        app.buttons["library.settings.button"].tap()
        let privacy = app.buttons["settings.privacy"]
        reveal(privacy, app: app)
        privacy.tap()
        XCTAssertTrue(app.navigationBars["Privacy Policy"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "This policy covers the native GenBooks iPhone app")).firstMatch.exists)
        try capture("release-privacy", app: app)
        app.navigationBars["Privacy Policy"].buttons.element(boundBy: 0).tap()
        let support = app.buttons["settings.support"]
        reveal(support, app: app)
        support.tap()
        XCTAssertTrue(app.navigationBars["Help & Support"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Email jarvis@agi-jarvis.com.")).firstMatch.exists)
        try capture("release-support", app: app)
        app.navigationBars["Help & Support"].buttons.element(boundBy: 0).tap()
        let notices = app.buttons["settings.notices"]
        reveal(notices, app: app)
        notices.tap()
        XCTAssertTrue(app.navigationBars["Open-source notices"].waitForExistence(timeout: 5))
        let noticeText = app.staticTexts["notices.content"]
        XCTAssertTrue(noticeText.waitForExistence(timeout: 5))
        XCTAssertTrue(noticeText.label.contains("SwiftSoup"))
        XCTAssertTrue(noticeText.label.contains("Copyright (c) 2016-2025 Nabil Chatbi (Swift port)"),
                      "The distributed app must contain SwiftSoup's copyright notice.")
        try capture("release-open-source-notices", app: app)
    }
}
