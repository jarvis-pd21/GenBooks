import XCTest

/// Exercises only the explicitly requested synthetic PDF through production library/storage paths.
@MainActor
final class OriginalPDFReaderUITests: XCTestCase {
    private let bookID = "B79FB544-5B90-4C76-BC44-404099444001"
    private let noteID = "B79FB544-5B90-4C76-BC44-404099444006"
    private let noteBody = "Keep the table and its explanation together. My note stays attached to this passage."

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        _ = try UITestArtifactDirectory.require(sourceFile: #filePath)
    }

    override func tearDownWithError() throws { XCUIDevice.shared.orientation = .portrait }

    func testOriginalPagesNavigationSearchAndTextRoundTrip() throws {
        let app = launch(reset: true)
        defer { app.terminate() }
        openSample(app)
        assertPage(1, app: app)
        XCTAssertFalse(app.textViews["reader.textkit.text"].exists, "A preserved PDF opens as original pages by default")
        XCTAssertFalse(app.buttons["original.pdf.previous"].isEnabled)
        try capture("original-pdf-medium-table", app: app)

        app.buttons["original.pdf.next"].tap()
        assertPage(2, app: app)
        try capture("original-pdf-medium-diagram", app: app)
        app.buttons["original.pdf.contents"].tap()
        let practice = app.buttons.containing(.staticText, identifier: "Practice and footnotes").firstMatch
        XCTAssertTrue(practice.waitForExistence(timeout: 5), "Contents must use the PDF's real outline")
        practice.tap()
        assertPage(3, app: app)
        XCTAssertFalse(app.buttons["original.pdf.next"].isEnabled)

        app.buttons["original.pdf.search"].tap()
        let field = app.textFields["original.pdf.search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("retained")
        app.buttons["Search"].firstMatch.tap()
        let match = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "original.pdf.search.result.")).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: 10), "Search must find the fixture's source text")
        XCTAssertTrue(match.label.contains("PDF page 3"))
        try capture("original-pdf-medium-search", app: app)
        match.tap()
        assertPage(3, app: app)

        jump(to: 1, app: app)
        app.buttons["original.pdf.text"].tap()
        let text = app.textViews["reader.textkit.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 8))
        let textBefore = text.value as? String
        XCTAssertTrue(textBefore?.contains("This synthetic text edition keeps its own reading position") == true)
        app.buttons["reader.original.button"].tap()
        assertPage(1, app: app)
        app.buttons["original.pdf.next"].tap()
        assertPage(2, app: app)
        app.buttons["original.pdf.text"].tap()
        XCTAssertTrue(text.waitForExistence(timeout: 8))
        XCTAssertEqual(text.value as? String, textBefore, "Original-page navigation must not rewrite the text edition")
        app.buttons["reader.original.button"].tap()
        assertPage(2, app: app)
    }

    func testOriginalPageRestoresAfterBackgroundAndRelaunchWithoutReset() throws {
        let app = launch(reset: true)
        defer { app.terminate() }
        openSample(app)
        jump(to: 3, app: app)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.terminate()
        app.launchArguments.removeAll { $0 == "-reset-original-pdf-fixture" }
        app.launch()
        openSample(app)
        assertPage(3, app: app)
        try capture("original-pdf-medium-relaunch-page-three", app: app)
    }

    func testTextPlaceAfterContentsJumpAndFurtherScrollingSurvivesOriginalPages() throws {
        let app = launch(reset: true)
        defer { app.terminate() }
        openSample(app)
        showText(app)
        assertSeedNoteUnchanged(app)
        app.buttons["reader.toc.button"].tap()
        let chapter = app.buttons["reader.toc.chapter.B79FB544-5B90-4C76-BC44-404099445002"]
        XCTAssertTrue(chapter.waitForExistence(timeout: 5))
        chapter.tap()
        waitUntilGone(app.descendants(matching: .any)["reader.toc.sheet"])
        try assertScrolledTextRoundTrip(app, chapterTitle: "Following the practice diagram", artifactPrefix: "original-pdf-toc")
    }

    func testTextPlaceAfterCommittedSearchAndFurtherScrollingSurvivesOriginalPages() throws {
        let app = launch(reset: true)
        defer { app.terminate() }
        openSample(app)
        showText(app)
        assertSeedNoteUnchanged(app)
        app.buttons["reader.search.button"].tap()
        let scope = app.buttons["Whole book (Spoilers)"].firstMatch
        XCTAssertTrue(scope.waitForExistence(timeout: 5)); scope.tap()
        let field = app.textFields["reader.search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("Sapphire waypoint")
        app.buttons["reader.search.submit"].tap()
        let hit = app.buttons["reader.search.hit.0"]
        XCTAssertTrue(hit.waitForExistence(timeout: 8))
        XCTAssertTrue(hit.label.contains("Keeping a reading place"))
        hit.tap()
        let resume = app.buttons["reader.search.continue"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5)); resume.tap()
        waitUntilGone(app.descendants(matching: .any)["reader.search.sheet"])
        XCTAssertTrue(app.staticTexts["reader.search.status"].waitForExistence(timeout: 5))
        app.buttons["reader.search.clear"].tap()
        try assertScrolledTextRoundTrip(app, chapterTitle: "Keeping a reading place", artifactPrefix: "original-pdf-search")
    }

    func testDiagramControlsRemainReachableAfterRotationAndPinch() throws {
        let app = launch(reset: true)
        defer { app.terminate() }
        openSample(app)
        jump(to: 2, app: app)
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 8), .completed)
        assertPage(2, app: app)
        assertControlsReachable(app)
        try capture("original-pdf-medium-diagram-landscape", app: app)
        let pdf = app.descendants(matching: .any)["original.pdf.document"].firstMatch
        XCTAssertTrue(pdf.waitForExistence(timeout: 5))
        pdf.pinch(withScale: 1.5, velocity: 1)
        // The screenshot is the visual zoom evidence; an accessibility label alone cannot prove scale.
        XCTAssertTrue(pdf.exists)
        assertControlsReachable(app)
        try capture("original-pdf-medium-diagram-landscape-pinched", app: app)
        XCUIDevice.shared.orientation = .portrait
        let portrait = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.windows.firstMatch.frame.height > app.windows.firstMatch.frame.width
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [portrait], timeout: 8), .completed)
        assertControlsReachable(app)
        try capture("original-pdf-medium-diagram-returned-portrait", app: app)
    }

    private func launch(reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitesting", "-original-pdf-fixture", "-useMockAI",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-livingreader.reader.colorScheme", "light",
            "-livingreader.reader.scrollMode", "scroll",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryM"]
        if reset { app.launchArguments.append("-reset-original-pdf-fixture") }
        app.launch()
        return app
    }

    private func showText(_ app: XCUIApplication) {
        app.buttons["original.pdf.text"].tap()
        XCTAssertTrue(app.textViews["reader.textkit.text"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["reader.progress.label"].waitForExistence(timeout: 5))
    }

    private func assertScrolledTextRoundTrip(_ app: XCUIApplication, chapterTitle: String, artifactPrefix: String) throws {
        let currentChapter = app.staticTexts["reader.currentChapter"]
        let chapterChanged = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", chapterTitle), object: currentChapter)
        XCTAssertEqual(XCTWaiter.wait(for: [chapterChanged], timeout: 8), .completed)
        let progress = app.staticTexts["reader.progress.label"]
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        let jumpProgress = progress.label
        // Use the visible viewport: the UITextView's accessibility frame spans the whole book.
        for _ in 0..<3 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.70))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.31))
            start.press(forDuration: 0.08, thenDragTo: end)
        }
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", jumpProgress), object: progress)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 6), .completed,
            "The regression must advance beyond the explicit jump, not merely reopen its destination")
        let before = progress.label
        XCTAssertEqual(currentChapter.label, chapterTitle, "Long fixture chapters must keep this scroll within one chapter")
        try capture(artifactPrefix + "-text-before", app: app)
        app.buttons["reader.original.button"].tap()
        XCTAssertTrue(app.buttons["original.pdf.goToPage"].waitForExistence(timeout: 8))
        jump(to: 3, app: app)
        showText(app)
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", before), object: progress)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 8), .completed,
            "Text must restore the scrolled place, not the earlier TOC/search jump; expected \(before), got \(progress.label)")
        XCTAssertEqual(currentChapter.label, chapterTitle)
        XCTAssertNotEqual(progress.label, jumpProgress)
        try capture(artifactPrefix + "-text-after", app: app)
        assertSeedNoteUnchanged(app)
        XCTAssertEqual(progress.label, before, "Inspecting a retained note must not move the reading place")
    }

    private func assertSeedNoteUnchanged(_ app: XCUIApplication) {
        app.buttons["reader.more.button"].tap()
        let notes = app.buttons["reader.notes.button"]
        XCTAssertTrue(notes.waitForExistence(timeout: 5)); notes.tap()
        let row = app.descendants(matching: .any)["notes.row.\(noteID)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The same saved note identity must remain available")
        XCTAssertTrue(row.staticTexts[noteBody].exists, "Switching reader modes must preserve the note body")
        XCTAssertTrue(row.staticTexts["This synthetic text edition keeps its own reading position."].exists,
            "The note must retain its original selected passage")
        let done = app.navigationBars["Notes"].buttons["Done"]
        XCTAssertTrue(done.isHittable); done.tap()
        waitUntilGone(app.descendants(matching: .any)["notes.list"])
    }

    private func waitUntilGone(_ element: XCUIElement) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 6), .completed)
    }

    private func openSample(_ app: XCUIApplication) {
        let library = app.tabBars.buttons["Library"]
        XCTAssertTrue(library.waitForExistence(timeout: 15))
        library.tap()
        let book = app.buttons["library.book.\(bookID)"].firstMatch
        _ = book.waitForExistence(timeout: 8)
        for _ in 0..<8 {
            if book.exists && book.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(book.isHittable, "The synthetic book must be installed and visible in the library")
        book.tap()
        XCTAssertTrue(app.buttons["original.pdf.goToPage"].waitForExistence(timeout: 10))
    }

    private func assertPage(_ page: Int, app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let control = app.buttons["original.pdf.goToPage"]
        XCTAssertTrue(control.waitForExistence(timeout: 8), file: file, line: line)
        let expected = "PDF page \(page) of 3"
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: control)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 8), .completed, "Expected \(expected); got \(control.label)", file: file, line: line)
    }

    private func jump(to page: Int, app: XCUIApplication) {
        app.buttons["original.pdf.goToPage"].tap()
        let alert = app.alerts["Go to PDF page"].firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let input = alert.textFields.firstMatch
        input.tap()
        let existing = input.value as? String ?? ""
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count) + String(page))
        alert.buttons["Go"].firstMatch.tap()
        assertPage(page, app: app)
    }

    private func assertControlsReachable(_ app: XCUIApplication) {
        for identifier in ["original.pdf.goToPage", "original.pdf.text", "original.pdf.contents", "original.pdf.search"] {
            let control = app.buttons[identifier]
            XCTAssertTrue(control.isHittable, "\(identifier) must remain reachable")
            XCTAssertTrue(app.windows.firstMatch.frame.insetBy(dx: -1, dy: -1).contains(control.frame))
        }
    }

    private func capture(_ name: String, app: XCUIApplication) throws {
        let directory = try UITestArtifactDirectory.require(sourceFile: #filePath)
        // Capture the device screen; app-window capture can clip a rotated window.
        let screenshot = XCUIScreen.main.screenshot()
        try screenshot.pngRepresentation.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
