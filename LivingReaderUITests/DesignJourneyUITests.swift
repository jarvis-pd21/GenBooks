import XCTest

final class DesignJourneyUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ id: UUID = UUID(), appearance: String = "light", large: Bool = false,
                        tab: String = "Learning") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uitesting", "-useMockAI", "-learningTestID", id.uuidString,
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-livingreader.reader.colorScheme", appearance,
            "-UIPreferredContentSizeCategoryName", large ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL"
        ]
        app.launch()
        let destination = app.tabBars.buttons[tab]
        XCTAssertTrue(destination.waitForExistence(timeout: 20))
        destination.tap()
        XCTAssertTrue(app.navigationBars[tab].waitForExistence(timeout: 10))
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

    private func openModelsConcept(in app: XCUIApplication) {
        let collection = app.buttons["learning.concepts"]
        reveal(collection, in: app)
        collection.tap()
        XCTAssertTrue(app.navigationBars["Concepts"].waitForExistence(timeout: 5))
        let models = app.buttons["learning.concept.models"]
        reveal(models, in: app)
        models.tap()
        XCTAssertTrue(app.navigationBars["Concept"].waitForExistence(timeout: 5))
    }

    private func openRetainedKnowledge(in app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["Foundations"].waitForExistence(timeout: 5))
        let retained = app.buttons["foundations.section.retained-knowledge"]
        reveal(retained, in: app)
        retained.tap()
        XCTAssertTrue(app.navigationBars["Retained knowledge"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["foundations.detail.retained-knowledge"].firstMatch.exists)
    }

    func testSharedSettingsFoundationsAndBookBotRoutes() throws {
        let app = launch(tab: "Library")
        defer { app.terminate() }
        let settings = app.buttons["library.settings.button"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertTrue(settings.isHittable)
        try capture("design-library", app: app)
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let foundations = app.buttons["settings.foundations"]
        reveal(foundations, in: app)
        foundations.tap()
        XCTAssertTrue(app.navigationBars["Foundations"].waitForExistence(timeout: 5))
        try capture("design-settings-foundations", app: app)
        openRetainedKnowledge(in: app)
        try capture("design-settings-retained-knowledge", app: app)
        back(from: "Retained knowledge", in: app)
        XCTAssertTrue(app.navigationBars["Foundations"].waitForExistence(timeout: 5))
        let science = app.buttons["foundations.section.learning-science"]
        reveal(science, in: app)
        science.tap()
        XCTAssertTrue(app.navigationBars["Learning science and this design"].waitForExistence(timeout: 5))
        let retrieval = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@",
            "Retrieval practice can help learning as well as observe it.")).firstMatch
        XCTAssertTrue(retrieval.exists)
        try capture("design-settings-learning-science", app: app)
        let source = app.descendants(matching: .any)["Retrieval practice — Roediger and Karpicke (2006)"].firstMatch
        reveal(source, in: app)
        XCTAssertTrue(source.isHittable)
        try capture("design-settings-learning-science-sources", app: app)
        back(from: "Learning science and this design", in: app)
        XCTAssertTrue(app.navigationBars["Foundations"].waitForExistence(timeout: 5))
        back(from: "Foundations", in: app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))

        let bookBot = app.buttons["settings.bookbot"]
        // Settings may retain its earlier scroll offset after navigating back.
        if !bookBot.isHittable { app.swipeDown() }
        reveal(bookBot, in: app)
        bookBot.tap()
        XCTAssertTrue(app.navigationBars["BookBot"].waitForExistence(timeout: 5))
        let askModel = app.descendants(matching: .any)["ai.settings.askModel"].firstMatch
        let generationModel = app.descendants(matching: .any)["ai.settings.generationModel"].firstMatch
        reveal(askModel, in: app)
        XCTAssertTrue(askModel.isHittable)
        reveal(generationModel, in: app)
        XCTAssertTrue(generationModel.isHittable)
        // This journey opens settings without changing provider preferences or credentials.
        try capture("design-settings-bookbot", app: app)
        back(from: "BookBot", in: app)
        let done = app.navigationBars["Settings"].buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 5))
    }

    func testLearningTabRetainsConceptNavigation() throws {
        let app = launch()
        defer { app.terminate() }
        openModelsConcept(in: app)
        app.tabBars.buttons["Notebook"].tap()
        XCTAssertTrue(app.navigationBars["Notebook"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Learning"].tap()
        XCTAssertTrue(app.navigationBars["Concept"].waitForExistence(timeout: 5),
                      "Returning to Learning should retain the open concept")
        let practice = app.buttons["learning.concept.check"]
        reveal(practice, in: app)
        XCTAssertTrue(practice.isHittable)
        try capture("design-retained-concept-navigation", app: app)
        back(from: "Concept", in: app)
        XCTAssertTrue(app.navigationBars["Concepts"].waitForExistence(timeout: 5))
    }

    func testNewPhysicsScoreExplainsEligibilityWithoutInventingEvidence() throws {
        let id = UUID()
        var app = launch(id)
        defer { app.terminate() }
        let score = app.buttons["learning.score"]
        reveal(score, in: app)
        score.tap()
        XCTAssertTrue(app.navigationBars["Check score"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["0 / 100"].exists)
        XCTAssertTrue(app.staticTexts["0 correct · 0 of 10 with a counted answer"].exists)
        XCTAssertTrue(app.staticTexts["A record of ten fixed question results, not a percentage of physics you know."].exists)
        let eligibility = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@",
            "Only designated review checks can count:")).firstMatch
        reveal(eligibility, in: app)
        XCTAssertTrue(eligibility.label.contains("24 hours"))
        XCTAssertTrue(eligibility.label.contains("If this question was shown before, seven days"))
        try capture("design-score-rules", app: app)
        back(from: "Check score", in: app)
        openModelsConcept(in: app)
        let practice = app.buttons["learning.concept.check"]
        reveal(practice, in: app)
        practice.tap()
        XCTAssertTrue(app.navigationBars["Review check"].waitForExistence(timeout: 5))
        let practiceOnly = app.staticTexts["Practice only"]
        reveal(practiceOnly, in: app)
        let reason = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@",
            "there is no recorded teaching or feedback exposure")).firstMatch
        reveal(reason, in: app)
        XCTAssertTrue(reason.label.hasPrefix("No score change:"))
        let save = app.buttons["learning.answer.save"]
        reveal(save, in: app)
        XCTAssertFalse(save.isEnabled, "An unanswered check cannot be submitted")
        try capture("design-practice-eligibility", app: app)
        app.buttons["learning.check.close"].tap()
        let evidence = app.staticTexts["learning.concept.evidence"]
        reveal(evidence, in: app)
        XCTAssertEqual(evidence.label, "Not checked yet")

        // Reopening proves a displayed-and-skipped question does not persist points.
        app.terminate()
        app = launch(id)
        let reopenedScore = app.buttons["learning.score"]
        reveal(reopenedScore, in: app)
        reopenedScore.tap()
        XCTAssertTrue(app.staticTexts["0 / 100"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["0 correct · 0 of 10 with a counted answer"].exists)
    }

    func testLightStandardLearningScreens() throws {
        try runVisualJourney(appearance: "light", large: false)
    }

    func testDarkStandardLearningScreens() throws {
        try runVisualJourney(appearance: "dark", large: false)
    }

    func testLightAccessibilityLearningScreens() throws {
        try runVisualJourney(appearance: "light", large: true)
    }

    func testDarkAccessibilityLearningScreens() throws {
        try runVisualJourney(appearance: "dark", large: true)
    }

    private func runVisualJourney(appearance: String, large: Bool) throws {
        let app = launch(appearance: appearance, large: large)
        defer { app.terminate() }
        let prefix = "design-\(appearance)-\(large ? "accessibility-xxxl" : "standard-l")"
        let read = app.buttons["learning.next.read"]
        XCTAssertTrue(read.waitForExistence(timeout: 10))
        try capture(prefix + "-learning", app: app)
        reveal(read, in: app)
        read.tap()
        XCTAssertTrue(app.navigationBars["Physics"].waitForExistence(timeout: 5))
        try capture(prefix + "-lesson", app: app)

        // Walk the actual full-length reading to its optional question controls.
        let check = app.buttons["learning.tryCheck"]
        reveal(check, in: app)
        XCTAssertTrue(app.buttons["learning.finish"].exists)
        check.tap()
        XCTAssertTrue(app.navigationBars["Optional question"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["learning.choice.c"].waitForExistence(timeout: 5))
        try capture(prefix + "-check", app: app)
        let choice = app.buttons["learning.choice.c"]
        reveal(choice, in: app)
        choice.tap()
        let save = app.buttons["learning.answer.save"]
        reveal(save, in: app)
        XCTAssertTrue(save.isEnabled)
        XCTAssertTrue(save.isHittable)
        try capture(prefix + "-check-controls", app: app)
        let skip = app.buttons["learning.check.close"]
        XCTAssertTrue(skip.isHittable)
        skip.tap()
        back(from: "Physics", in: app)

        openModelsConcept(in: app)
        try capture(prefix + "-concept", app: app)
        let conceptCheck = app.buttons["learning.concept.check"]
        reveal(conceptCheck, in: app)
        XCTAssertTrue(conceptCheck.isHittable)
        let evidence = app.staticTexts["learning.concept.evidence"]
        reveal(evidence, in: app)
        XCTAssertEqual(evidence.label, "Not checked yet", "Selecting and skipping must not save an answer")
        try capture(prefix + "-concept-evidence", app: app)
        back(from: "Concept", in: app)
        back(from: "Concepts", in: app)
        let foundations = app.buttons["learning.foundations"]
        reveal(foundations, in: app)
        foundations.tap()
        openRetainedKnowledge(in: app)
        try capture(prefix + "-foundations-detail", app: app)
        back(from: "Retained knowledge", in: app)
        XCTAssertTrue(app.navigationBars["Foundations"].waitForExistence(timeout: 5))
    }
}
