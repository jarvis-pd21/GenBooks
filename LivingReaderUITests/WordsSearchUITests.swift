import XCTest

final class WordsSearchUITests: XCTestCase {
    private let argentinaID = "00000000-0000-4000-8000-000000000001"
    private let missingQuery = "zzzz-no-saved-word-79831"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testNotebookWordsClearSearchRecoversLearnedPhraseAfterRelaunch() {
        let app = launchApp(demoSelection: true)
        defer { app.terminate() }
        let phrase = learnArgentinaSelection(in: app)

        // Reopen the app through its normal entry point: the saved word must be
        // file-backed, not merely retained in the reader's current view state.
        app.terminate()
        app.launchArguments.removeAll { $0 == "-phase3DemoSelection" }
        app.launch()
        waitForLibrary(in: app)
        let notebook = app.tabBars.buttons["Notebook"].firstMatch
        XCTAssertTrue(notebook.waitForExistence(timeout: 6))
        notebook.tap()
        XCTAssertTrue(app.descendants(matching: .any)["notebook.screen"].firstMatch.waitForExistence(timeout: 6))

        XCTAssertFalse(app.textFields["vocab.search"].exists, "Notebook must keep its single host-owned search field")
        assertSavedWordSurvivesSearch(in: app, phrase: phrase, screenshot: "words-notebook-no-matches",
                                     searchID: "notebook.search", clearID: "notebook.search.clear")
        XCTAssertFalse(app.textFields["vocab.search"].exists, "Clearing must not create a second Words search field")
        attachScreenshot("words-notebook-recovered", app: app)
    }

    func testReaderWordsClearSearchPreservesSavedRowAndOpenSourceAction() {
        let app = launchApp(demoSelection: true)
        defer { app.terminate() }
        let phrase = learnArgentinaSelection(in: app)
        openReaderWords(in: app)

        let rowID = assertSavedWordSurvivesSearch(in: app, phrase: phrase, screenshot: "words-reader-no-matches")
        attachScreenshot("words-reader-recovered", app: app)

        // Each action retains its own identifier inside the accessible row.
        // Target this exact saved entry, not another visible word's Open button.
        let entryID = String(rowID.dropFirst("vocab.row.".count))
        let open = app.buttons["vocab.open.\(entryID)"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5), "Clearing the query must retain the row's source action")
        open.tap()
        waitForAbsence(app.textFields["vocab.search"].firstMatch,
                       message: "Open must dismiss Words and return to its source in the reader")
        XCTAssertTrue(app.descendants(matching: .any)["reader.textkit.text"].firstMatch.waitForExistence(timeout: 6))
    }

    func testBookWithoutLearnedWordsDistinguishesEmptyLibraryFromEmptySearch() {
        let app = launchApp(additionalArguments: ["-importTestEPUB"])
        defer { app.terminate() }
        // A fresh original Plaza Evening import has its own identity and no words.
        // This keeps the generic empty-state journey independent of optional books.
        openReaderWords(in: app)

        let empty = app.staticTexts["vocab.empty"].firstMatch
        XCTAssertTrue(empty.waitForExistence(timeout: 6))
        XCTAssertEqual(empty.label, "No words yet — select text in the reader and tap Add to Words.")
        XCTAssertFalse(app.staticTexts["vocab.search.empty"].exists)
        XCTAssertFalse(app.buttons["vocab.search.clear"].exists)

        let search = app.textFields["vocab.search"].firstMatch
        search.tap()
        search.typeText("   ")
        XCTAssertTrue(empty.exists, "Whitespace alone is not an active search")
        XCTAssertFalse(app.buttons["vocab.search.clear"].exists)
        search.typeText(missingQuery)

        assertNoMatches(in: app)
        attachScreenshot("words-empty-book-no-matches", app: app)
        app.buttons["vocab.search.clear"].firstMatch.tap()
        XCTAssertTrue(empty.waitForExistence(timeout: 5), "Clear must restore the genuine no-words guidance")
        XCTAssertFalse(app.staticTexts["vocab.search.empty"].exists)
        XCTAssertFalse(app.buttons["vocab.search.clear"].exists)
        XCTAssertEqual(search.value as? String, "", "Clear must empty the query, not replace it with placeholder text")
        attachScreenshot("words-empty-book-cleared", app: app)
    }

    func testReaderWordsAtAccessibilityXXXLRecoversAboveKeyboardAndOpensSavedSourceChapter() {
        // A stable saved entry makes recovery independent of random Learn IDs
        // and avoids exercising selection chrome in this layout regression.
        let app = launchApp(additionalArguments: [
            "-phase3SeedAnnotations",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        defer { app.terminate() }
        openBook(argentinaID, in: app)

        // Start away from the word's source so Open must navigate, not merely
        // dismiss the sheet while leaving the reader at the same chapter.
        app.buttons["reader.toc.button"].tap()
        let chapter2 = app.buttons["reader.toc.chapter.00000000-0000-4000-8000-0000000000C2"]
        XCTAssertTrue(chapter2.waitForExistence(timeout: 6))
        chapter2.tap()
        waitForAbsence(app.navigationBars["Contents"], message: "Choosing a chapter must close Contents")
        let chapter = app.staticTexts["reader.currentChapter"].firstMatch
        waitForChapter("Independence Sparks", element: chapter)
        openReaderWords(in: app)

        let entryID = "00000000-0000-4000-8000-0000000000F3"
        let row = app.descendants(matching: .any)["vocab.row.\(entryID)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6))
        XCTAssertTrue(row.staticTexts["destiny"].exists)
        let search = app.textFields["vocab.search"].firstMatch
        search.tap()
        search.typeText(missingQuery)
        assertNoMatches(in: app)
        XCTAssertFalse(row.exists)

        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        let clear = app.buttons["vocab.search.clear"].firstMatch
        let reachable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: clear)
        XCTAssertEqual(XCTWaiter.wait(for: [reachable], timeout: 6), .completed)
        XCTAssertTrue(app.frame.contains(clear.frame), "Clear must be fully onscreen at the largest text size")
        XCTAssertGreaterThanOrEqual(clear.frame.height, 44, "Clear must retain a full-size touch target")
        XCTAssertLessThanOrEqual(clear.frame.maxY, keyboard.frame.minY,
                                 "Recovery must be visible above the live keyboard without an extra dismissal")
        attachScreenshot("words-xxxl-no-matches-keyboard", app: app)
        clear.tap()

        waitForAbsence(keyboard, message: "One Clear tap must dismiss the keyboard")
        XCTAssertEqual(search.value as? String, "")
        XCTAssertTrue(row.waitForExistence(timeout: 6), "Clear must restore the same saved entry identity")
        XCTAssertTrue(row.staticTexts["destiny"].exists)
        XCTAssertFalse(app.staticTexts["vocab.empty"].exists)
        XCTAssertFalse(app.staticTexts["vocab.search.empty"].exists)
        XCTAssertFalse(clear.exists)
        attachScreenshot("words-xxxl-recovered", app: app)

        let open = app.buttons["vocab.open.\(entryID)"].firstMatch
        // The restored row is taller at XXXL; ordinary list scrolling may be
        // needed to reveal its own source action, but never to reach Clear.
        for _ in 0..<4 {
            if open.exists && open.isHittable { break }
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(open.exists && open.isHittable, "The recovered word must retain its reachable Open action")
        open.tap()
        waitForAbsence(search, message: "Open must dismiss Words")
        waitForChapter("Before the Nation", element: chapter)
        XCTAssertTrue(app.textViews["reader.textkit.text"].firstMatch.exists)
        attachScreenshot("words-xxxl-source-chapter", app: app)
    }

    @discardableResult
    private func assertSavedWordSurvivesSearch(in app: XCUIApplication, phrase: String, screenshot: String,
                                             searchID: String = "vocab.search",
                                             clearID: String = "vocab.search.clear") -> String {
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "vocab.row.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6), "Learn must create a saved Words row")
        let rowID = row.identifier
        XCTAssertTrue(app.staticTexts[phrase].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["vocab.empty"].exists)

        let search = app.textFields[searchID].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("   ")
        XCTAssertTrue(app.descendants(matching: .any)[rowID].firstMatch.exists,
                      "Whitespace-only search must retain saved words")
        XCTAssertFalse(app.buttons[clearID].exists)
        search.typeText(missingQuery)
        assertNoMatches(in: app, clearID: clearID)
        XCTAssertFalse(app.descendants(matching: .any)[rowID].firstMatch.exists,
                       "An unmatched saved row should be filtered, not displayed")
        attachScreenshot(screenshot, app: app)

        let clear = app.buttons[clearID].firstMatch
        XCTAssertGreaterThanOrEqual(clear.frame.height, 44, "Clear must retain a full-size touch target")
        clear.tap()
        waitForAbsence(app.keyboards.firstMatch, message: "Clear must dismiss the search keyboard")
        XCTAssertTrue(app.descendants(matching: .any)[rowID].firstMatch.waitForExistence(timeout: 5),
                      "Clear must restore the same saved entry, not recreate it")
        XCTAssertTrue(app.staticTexts[phrase].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["vocab.empty"].exists)
        XCTAssertFalse(app.staticTexts["vocab.search.empty"].exists)
        XCTAssertFalse(app.buttons[clearID].exists)
        XCTAssertEqual(search.value as? String, "", "Clear must empty the query, not replace it with placeholder text")
        return rowID
    }

    private func assertNoMatches(in app: XCUIApplication, clearID: String = "vocab.search.clear") {
        let noMatches = app.staticTexts["vocab.search.empty"].firstMatch
        XCTAssertTrue(noMatches.waitForExistence(timeout: 5))
        XCTAssertEqual(noMatches.label, "No matching words")
        XCTAssertFalse(app.staticTexts["vocab.empty"].exists,
                       "An unsuccessful query must not claim that no words have been learned")
        XCTAssertTrue(app.buttons[clearID].firstMatch.waitForExistence(timeout: 5))
    }

    private func learnArgentinaSelection(in app: XCUIApplication) -> String {
        openBook(argentinaID, in: app)
        let sheet = app.descendants(matching: .any)["selection.actions.sheet"].firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 8))
        let displayed = app.staticTexts["selection.phrase"].firstMatch
        XCTAssertTrue(displayed.waitForExistence(timeout: 5))
        let quoted = displayed.label
        XCTAssertTrue(quoted.hasPrefix("“") && quoted.hasSuffix("”"))
        let phrase = String(quoted.dropFirst().dropLast())
        XCTAssertFalse(phrase.isEmpty)
        app.buttons["selection.learn"].firstMatch.tap()
        waitForAbsence(sheet, message: "Learn must save the word and close the selection sheet")
        return phrase
    }

    private func openReaderWords(in app: XCUIApplication) {
        let more = app.buttons["reader.more.button"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 6))
        more.tap()
        XCTAssertTrue(app.descendants(matching: .any)["reader.overflow.sheet"].firstMatch.waitForExistence(timeout: 5))
        let words = app.buttons["reader.vocab.button"].firstMatch
        XCTAssertTrue(words.waitForExistence(timeout: 5))
        words.tap()
        XCTAssertTrue(app.textFields["vocab.search"].firstMatch.waitForExistence(timeout: 6))
    }

    private func launchApp(demoSelection: Bool = false, additionalArguments: [String] = []) -> XCUIApplication {
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
        if demoSelection { app.launchArguments.append("-phase3DemoSelection") }
        app.launchArguments += additionalArguments
        app.launch()
        if additionalArguments.contains("-importTestEPUB") {
            XCTAssertTrue(app.descendants(matching: .any)["reader.screen"].firstMatch.waitForExistence(timeout: 18))
        } else {
            waitForLibrary(in: app)
        }
        return app
    }

    private func waitForLibrary(in app: XCUIApplication) {
        XCTAssertTrue(app.descendants(matching: .any)["library.screen"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["library.book.\(argentinaID)"].firstMatch.waitForExistence(timeout: 12))
    }

    private func openBook(_ id: String, in app: XCUIApplication) {
        let book = app.descendants(matching: .any)["library.book.\(id)"].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 8))
        book.tap()
        XCTAssertTrue(app.descendants(matching: .any)["reader.textkit.text"].firstMatch.waitForExistence(timeout: 10))
    }

    private func waitForAbsence(_ element: XCUIElement, message: String) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 8), .completed, message)
    }

    private func waitForChapter(_ title: String, element: XCUIElement) {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", title), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 8), .completed)
    }

    private func attachScreenshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
