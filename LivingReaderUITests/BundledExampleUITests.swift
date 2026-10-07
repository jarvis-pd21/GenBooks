import XCTest

final class BundledExampleUITests: XCTestCase {
    private let heading = "The wider world — bundled example"
    private let source = "Source: Bundled local example — no AI request."
    private let prompt = "As you read this chapter, ask what connects its local story to the wider world. Which people, goods or ideas move across borders? Who gains from those connections, and who bears their costs? Look for the chapter’s own evidence before drawing a comparison. Separate outside pressures from choices made locally: a connection can help explain events without making their outcome inevitable. These are reading questions, not additional historical claims."

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    // This test writes one revision. Run it against a fresh donor test container;
    // -uitesting intentionally does not erase the user's saved manuscript.
    // Cancel and Apply share one test so their proof is not test-order dependent.
    func testExplicitBundledExampleCanBeReviewedCancelledAndApplied() throws {
        let app = launchFeedback()
        reviewBundledExample(app, inspectExactPrompt: true)
        app.buttons["adapt.plan.cancel"].tap()
        waitUntilGone(app.descendants(matching: .any)["adapt.plan.sheet"])

        searchForExample(app)
        XCTAssertTrue(app.staticTexts["No matches"].waitForExistence(timeout: 6),
                      "Cancelling the plan must not append the bundled example")
        XCTAssertFalse(app.buttons["reader.search.hit.0"].exists)
        keepScreenshot("bundled-example-cancel-no-manuscript-change")
        app.buttons["reader.search.done"].tap()

        // Reopen the existing feedback demo through a fresh process, retaining
        // the same manuscript so Cancel's result is the next Apply's baseline.
        app.terminate()
        app.launch()
        openArgentina(app)
        reviewBundledExample(app, inspectExactPrompt: false)
        let apply = app.buttons["adapt.plan.apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        XCTAssertTrue(apply.isEnabled)
        apply.tap()
        waitUntilGone(app.descendants(matching: .any)["adapt.plan.sheet"])
        XCTAssertFalse(app.staticTexts["adapt.plan.error"].exists)

        // The normal Contents route still opens the named future chapter.
        let contents = app.buttons["reader.toc.button"]
        XCTAssertTrue(contents.waitForExistence(timeout: 6))
        contents.tap()
        let chapter = app.buttons["reader.toc.chapter.00000000-0000-4000-8000-0000000000C2"]
        XCTAssertTrue(chapter.waitForExistence(timeout: 6))
        let chapterTitle = chapter.label.replacingOccurrences(of: ", current chapter", with: "")
        chapter.tap()
        waitUntilGone(app.descendants(matching: .any)["reader.toc.sheet"])

        searchForExample(app)
        let hit = app.buttons["reader.search.hit.0"]
        XCTAssertTrue(hit.waitForExistence(timeout: 8), "Apply must publish searchable bundled text")
        XCTAssertTrue(hit.label.contains(heading))
        XCTAssertTrue(hit.label.contains(chapterTitle), "Only the named future chapter receives the example")
        XCTAssertFalse(app.buttons["reader.search.hit.1"].exists, "The fixed heading is appended only once")
        hit.tap()
        let resume = app.buttons["reader.search.continue"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        resume.tap()
        XCTAssertTrue(app.staticTexts["reader.search.status"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["reader.textkit.text"].exists)
        keepScreenshot("bundled-example-search-return")
        app.buttons["reader.search.clear"].tap()
        // Use the visible reading area: the whole-book UITextView accessibility
        // frame can extend far beyond the screen used by element.swipeUp().
        for index in 1...3 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.27))
            start.press(forDuration: 0.05, thenDragTo: end)
            keepScreenshot("bundled-example-reader-forward-\(index)")
        }
    }

    func testBundledExampleSourceProofAndCancelStayReachableAtAccessibilityXXXL() throws {
        let app = launchFeedback(additionalArguments: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        let feedback = app.descendants(matching: .any)["feedback.sheet"]
        let example = app.buttons["feedback.bundledExample"]
        reveal(example, in: feedback)
        example.tap()

        let plan = app.descendants(matching: .any)["adapt.plan.sheet"]
        XCTAssertTrue(plan.waitForExistence(timeout: 8))
        let sourceText = app.staticTexts[source].firstMatch
        for _ in 0..<8 {
            if sourceText.exists && sourceText.isHittable { break }
            plan.swipeUp()
        }
        XCTAssertTrue(sourceText.waitForExistence(timeout: 5),
                      "The bundled source disclosure must remain present at the largest text size")
        XCTAssertTrue(sourceText.isHittable,
                      "The bundled source disclosure must remain reachable at the largest text size")
        XCTAssertTrue(app.frame.contains(sourceText.frame),
                      "The bundled source disclosure must stay fully onscreen at the largest text size")
        keepScreenshot("bundled-example-xxxl-source-proof")

        // After inspecting the large-text preview, the reader must still
        // be able to decline it without applying the proposed adaptation.
        let cancel = app.buttons["adapt.plan.cancel"]
        XCTAssertEqual(cancel.label, "Not now")
        XCTAssertTrue(cancel.isEnabled && cancel.isHittable)
        XCTAssertTrue(app.frame.contains(cancel.frame),
                      "The complete cancellation control must stay onscreen")
        cancel.tap()
        waitUntilGone(plan)
        XCTAssertFalse(app.buttons["adapt.plan.apply"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["reader.textkit.text"].firstMatch
            .waitForExistence(timeout: 8), "Not now must return to the readable manuscript")

        // Prove the underlying reader responds, not just that its sheet vanished.
        let contents = app.buttons["reader.toc.button"]
        XCTAssertTrue(contents.waitForExistence(timeout: 5))
        XCTAssertTrue(contents.isHittable)
        contents.tap()
        XCTAssertTrue(app.navigationBars["Contents"].waitForExistence(timeout: 5))
        keepScreenshot("bundled-example-xxxl-cancel-reader-recovered")
        app.buttons["reader.toc.done"].tap()
        waitUntilGone(app.navigationBars["Contents"])
    }

    private func launchFeedback(additionalArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uitesting", "-phase5AdaptationDemo",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-livingreader.reader.fontSize", "18",
            "-livingreader.reader.colorScheme", "system",
            "-livingreader.reader.fontFamily", "original",
            "-livingreader.reader.lineSpacing", "1.28",
            "-livingreader.reader.marginInset", "22",
            "-livingreader.reader.pageDim", "0",
            "-livingreader.reader.wordsPerMinute", "230",
            "-livingreader.reader.scrollMode", "scroll",
            "-livingreader.reader.searchScope", "readSoFar"
        ] + additionalArguments
        app.launch()
        openArgentina(app)
        return app
    }

    private func openArgentina(_ app: XCUIApplication) {
        let book = app.descendants(matching: .any)["library.book.00000000-0000-4000-8000-000000000001"]
        XCTAssertTrue(book.waitForExistence(timeout: 12))
        book.tap()
        XCTAssertTrue(app.descendants(matching: .any)["feedback.sheet"].waitForExistence(timeout: 12))
    }

    private func reviewBundledExample(_ app: XCUIApplication, inspectExactPrompt: Bool) {
        let feedback = app.descendants(matching: .any)["feedback.sheet"]
        let example = app.buttons["feedback.bundledExample"]
        reveal(example, in: feedback)
        keepScreenshot("bundled-example-explicit-feedback-choice")
        example.tap()
        let plan = app.descendants(matching: .any)["adapt.plan.sheet"]
        XCTAssertTrue(plan.waitForExistence(timeout: 8), "Explicit bundled choice should open the real plan")
        XCTAssertFalse(app.staticTexts["feedback.error"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["adapt.apply.length"].exists,
                       "A fixed append-only example must not offer a misleading Half/Full control")
        XCTAssertTrue(app.staticTexts[source].waitForExistence(timeout: 5),
                      "The plan must name the bundled source rather than claim live AI")
        if inspectExactPrompt {
            let exactPrompt = app.staticTexts.matching(NSPredicate(format: "label == %@", prompt)).firstMatch
            reveal(exactPrompt, in: plan)
            XCTAssertTrue(exactPrompt.isHittable, "The complete fixed reading prompt must be reviewable before Apply")
            keepScreenshot("bundled-example-plan-exact-reading-prompt")
        }
    }

    private func searchForExample(_ app: XCUIApplication) {
        let search = app.buttons["reader.search.button"]
        XCTAssertTrue(search.waitForExistence(timeout: 6))
        search.tap()
        let wholeBook = app.buttons["Whole book (Spoilers)"]
        XCTAssertTrue(wholeBook.waitForExistence(timeout: 5))
        wholeBook.tap()
        let field = app.textFields["reader.search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(heading)
        app.buttons["reader.search.submit"].tap()
    }

    private func reveal(_ element: XCUIElement, in container: XCUIElement) {
        for _ in 0..<7 {
            if element.exists && element.isHittable { break }
            container.swipeUp()
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        XCTAssertTrue(element.isHittable)
    }

    private func waitUntilGone(_ element: XCUIElement) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 10), .completed)
    }

    private func keepScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
