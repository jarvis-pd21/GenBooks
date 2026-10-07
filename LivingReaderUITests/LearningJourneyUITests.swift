import XCTest

final class LearningJourneyUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ id: UUID, large: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uitesting", "-useMockAI", "-learningTestID", id.uuidString,
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-livingreader.reader.colorScheme", "light",
            "-UIPreferredContentSizeCategoryName", large ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL"
        ]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Learning"].waitForExistence(timeout: 20))
        app.tabBars.buttons["Learning"].tap()
        return app
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, limit: Int = 80) {
        for _ in 0..<limit {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable, "Expected reachable control: \(element)")
    }

    private func back(from title: String, in app: XCUIApplication) {
        let bar = app.navigationBars[title]
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        let button = bar.buttons.element(boundBy: 0)
        XCTAssertTrue(button.isHittable)
        button.tap()
    }

    private func capture(_ name: String, app: XCUIApplication) throws {
        let directory = try UITestArtifactDirectory.require(sourceFile: #filePath)
        let shot = app.screenshot()
        try shot.pngRepresentation.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testOfflineReadingCheckAndReopen() throws {
        let id = UUID()
        var app = launch(id)
        defer { app.terminate() }
        let read = app.buttons["learning.next.read"]
        XCTAssertTrue(read.waitForExistence(timeout: 10))
        read.tap()
        let finish = app.buttons["learning.finish"]
        reveal(finish, in: app)
        finish.tap()
        let marked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Marked read"), object: finish)
        XCTAssertEqual(XCTWaiter.wait(for: [marked], timeout: 5), .completed)
        let question = app.buttons["learning.tryCheck"]
        reveal(question, in: app)
        question.tap()
        let choice = app.buttons["learning.choice.c"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        reveal(choice, in: app)
        choice.tap()
        let save = app.buttons["learning.answer.save"]
        reveal(save, in: app)
        save.tap()
        let result = app.staticTexts["learning.answer.result"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        reveal(result, in: app)
        XCTAssertTrue(result.label.contains("Correct on this question"))
        XCTAssertTrue(app.staticTexts["Check score unchanged"].exists,
                      "Immediate lesson practice must not award delayed-check points")
        try capture("learning-saved-immediate-answer", app: app)
        app.buttons["learning.check.close"].tap()
        app.terminate()

        app = launch(id)
        let collection = app.buttons["learning.concepts"]
        reveal(collection, in: app)
        collection.tap()
        let concept = app.buttons["learning.concept.models"]
        XCTAssertTrue(concept.waitForExistence(timeout: 5))
        concept.tap()
        let evidence = app.staticTexts["learning.concept.evidence"]
        reveal(evidence, in: app)
        XCTAssertEqual(evidence.label, "Answered a check correctly")
        XCTAssertTrue(app.staticTexts["No help reported"].exists)
        try capture("learning-retained-evidence", app: app)
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 5))
    }

    func testLargeTextDefinitionsAndSkipNeverAwardEvidence() throws {
        let id = UUID()
        var app = launch(id, large: true)
        defer { app.terminate() }
        let collection = app.buttons["learning.concepts"]
        reveal(collection, in: app)
        collection.tap()
        let concept = app.buttons["learning.concept.models"]
        XCTAssertTrue(concept.waitForExistence(timeout: 5))
        reveal(concept, in: app)
        concept.tap()
        let check = app.buttons["learning.concept.check"]
        reveal(check, in: app)
        check.tap()
        let close = app.buttons["learning.check.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        let evidence = app.staticTexts["learning.concept.evidence"]
        reveal(evidence, in: app)
        XCTAssertEqual(evidence.label, "Not checked yet")
        back(from: "Concept", in: app)
        back(from: "Concepts", in: app)
        let foundations = app.buttons["learning.foundations"]
        reveal(foundations, in: app)
        foundations.tap()
        let retained = app.buttons["foundations.section.retained-knowledge"]
        reveal(retained, in: app)
        retained.tap()
        XCTAssertTrue(app.navigationBars["Retained knowledge"].waitForExistence(timeout: 5))
        try capture("learning-definitions-accessibility", app: app)
        back(from: "Retained knowledge", in: app)
        XCTAssertTrue(app.navigationBars["Foundations"].waitForExistence(timeout: 5))

        // A question display is an exposure, not a saved answer or earned evidence.
        app.terminate()
        app = launch(id, large: true)
        let reopenedCollection = app.buttons["learning.concepts"]
        reveal(reopenedCollection, in: app)
        reopenedCollection.tap()
        let reopenedConcept = app.buttons["learning.concept.models"]
        reveal(reopenedConcept, in: app)
        reopenedConcept.tap()
        let reopenedEvidence = app.staticTexts["learning.concept.evidence"]
        reveal(reopenedEvidence, in: app)
        XCTAssertEqual(reopenedEvidence.label, "Not checked yet")
    }
}
