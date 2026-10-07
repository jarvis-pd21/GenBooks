import XCTest

final class NotebookSearchUITests: XCTestCase {
    // The Phase 3 seed stores a colour mark and a note at the same passage.
    // NoteRowBuilder chooses the noted record's UUID for the single Notes row.
    private let noteRowID = "notes.row.00000000-0000-4000-8000-0000000000F2"
    private let wordRowID = "vocab.row.00000000-0000-4000-8000-0000000000F3"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testNotesNoMatchesCanClearSearchAndRestoreSameMergedRow() {
        let app = openNotebookNotes()
        let note = row(noteRowID, in: app)
        let search = searchField(in: app)
        replaceQuery(in: search, with: "zzNotebookNoMatch48271")

        XCTAssertTrue(app.staticTexts["No matching notes"].waitForExistence(timeout: 5))
        XCTAssertFalse(note.exists, "The unmatched row must not remain in filtered results")
        XCTAssertFalse(app.staticTexts["No notes yet"].exists, "Saved notes must not be described as absent")
        XCTAssertFalse(app.staticTexts["Select text while reading and choose Note. Pick a colour, and write words only if you want to."].exists,
                       "A failed search is not first-use onboarding")
        let clear = clearButton(in: app)
        XCTAssertTrue(clear.waitForExistence(timeout: 5), "The no-results screen needs a direct recovery action")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3), "Exercise Clear search while typing")
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.exists)
        XCTAssertGreaterThanOrEqual(clear.frame.height, 44)
        XCTAssertLessThanOrEqual(clear.frame.maxY + 8, tabs.frame.minY,
                                 "The entire Clear search button must sit above the tab bar")
        attachScreenshot("notebook-notes-no-matches", app: app)

        clear.tap()
        XCTAssertTrue(note.waitForExistence(timeout: 5), "Clearing search must restore the same merged Notes row UUID")
        assertSearchCleared(search)
        assertKeyboardDismissed(app)
        XCTAssertFalse(app.staticTexts["No matching notes"].exists)
        XCTAssertFalse(clear.exists)
        assertConsolidatedNotes(app)
        attachScreenshot("notebook-notes-search-recovered", app: app)
    }

    func testNotesSearchMatchesBodyPassageAndColourAndIgnoresWhitespace() {
        let app = openNotebookNotes()
        let search = searchField(in: app)
        let note = row(noteRowID, in: app)

        // The same merged row carries the note body, selected passage and yellow
        // category; all three stay searchable without a separate Highlights tab.
        for query in [" dEmO nOtE ", " gEoGrApHy ", " yElLoW ", " "] {
            replaceQuery(in: search, with: query)
            XCTAssertTrue(note.waitForExistence(timeout: 5), "Search must retain the same note for query: \(query)")
            XCTAssertFalse(clearButton(in: app).exists)
            XCTAssertFalse(app.staticTexts["No matching notes"].exists)
            XCTAssertFalse(app.staticTexts["No notes yet"].exists)
        }
        assertConsolidatedNotes(app)
        attachScreenshot("notebook-whitespace-keeps-merged-note", app: app)
    }

    func testWordsAndNotesShareOneSearchAndKeepQueryAcrossFilters() {
        let app = openNotebookNotes()
        let search = searchField(in: app)
        let query = "zzNotebookNoMatch48271"
        replaceQuery(in: search, with: query)
        XCTAssertTrue(app.staticTexts["No matching notes"].waitForExistence(timeout: 5))

        select("words", in: app)
        XCTAssertEqual(searchField(in: app).value as? String, query,
                       "Switching to Words must retain the Notebook query")
        XCTAssertFalse(row(wordRowID, in: app).exists)
        XCTAssertFalse(app.textFields["vocab.search"].exists, "Words must use the host search field")
        XCTAssertEqual(app.textFields.count, 1, "Notebook must expose one search field in Words")

        select("notes", in: app)
        XCTAssertEqual(searchField(in: app).value as? String, query)
        XCTAssertTrue(app.staticTexts["No matching notes"].waitForExistence(timeout: 5))
        XCTAssertFalse(row(noteRowID, in: app).exists)
        clearButton(in: app).tap()
        XCTAssertTrue(row(noteRowID, in: app).waitForExistence(timeout: 5))
        assertSearchCleared(searchField(in: app))
        assertKeyboardDismissed(app)

        select("words", in: app)
        assertSearchCleared(searchField(in: app))
        XCTAssertTrue(row(wordRowID, in: app).waitForExistence(timeout: 5),
                      "Clearing Notes search must also restore the same saved word through the shared query")
        XCTAssertEqual(app.textFields.count, 1)
        select("notes", in: app)
        XCTAssertTrue(row(noteRowID, in: app).waitForExistence(timeout: 5))
        assertConsolidatedNotes(app)
        attachScreenshot("notebook-shared-search-cleared", app: app)
    }

    func testWordsEmptyAndNoResultsStayDistinctAtAccessibilityXXXL() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uitesting", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["library.book.00000000-0000-4000-8000-000000000001"]
            .firstMatch.waitForExistence(timeout: 12))

        let notebook = app.tabBars.buttons["Notebook"].firstMatch
        XCTAssertTrue(notebook.waitForExistence(timeout: 6))
        notebook.tap()
        XCTAssertTrue(app.descendants(matching: .any)["notebook.screen"].firstMatch.waitForExistence(timeout: 6))

        select("words", in: app)
        removeSavedWordsIfNeeded(from: app)
        let search = app.textFields["notebook.search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))

        let empty = app.descendants(matching: .any)["vocab.empty"].firstMatch
        XCTAssertTrue(empty.waitForExistence(timeout: 6))
        XCTAssertEqual(empty.label, "No words yet — select text in the reader and tap Add to Words.")
        XCTAssertFalse(app.staticTexts["No matching words"].exists,
                       "The first-use empty state must not look like a failed search")

        search.tap()
        search.typeText("zzNotebookWordsNoMatchXXXL")
        let noResults = app.descendants(matching: .any)["vocab.search.empty"].firstMatch
        XCTAssertTrue(noResults.waitForExistence(timeout: 6))
        XCTAssertEqual(noResults.label, "No matching words")
        XCTAssertFalse(empty.exists, "A query with no matches must not claim that Words has never been used")

        let clear = app.buttons["notebook.search.clear"].firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        let viewport = app.windows.firstMatch.frame
        // The tab bar stays visible while typing, and the recovery action must
        // remain above it even when the keyboard compresses the viewport.
        let reachable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: clear)
        XCTAssertEqual(XCTWaiter.wait(for: [reachable], timeout: 6), .completed,
                       "Clear search must remain reachable at the largest text size")
        attachScreenshot("notebook-words-xxxl-no-matches", app: app)
        XCTAssertTrue(viewport.contains(clear.frame), "The recovery action must be fully onscreen")
        XCTAssertTrue(tabs.exists, "Notebook tabs remain available while the search keyboard is active")
        XCTAssertLessThanOrEqual(noResults.frame.maxY + 8, tabs.frame.minY,
                                 "No-results guidance must stay above the tab bar")
        XCTAssertLessThanOrEqual(clear.frame.maxY + 8, tabs.frame.minY,
                                 "Clear search must stay above the tab bar")

        clear.tap()
        XCTAssertTrue(empty.waitForExistence(timeout: 6), "Clearing must restore the genuine no-words guidance")
        XCTAssertFalse(noResults.exists)
        XCTAssertFalse(clear.exists)
        XCTAssertEqual(search.value as? String, "", "Clear must empty the shared Notebook query")
        XCTAssertTrue(tabs.waitForExistence(timeout: 6), "Dismissing the keyboard must restore the tab bar")
        attachScreenshot("notebook-words-xxxl-empty", app: app)
    }

    private func openNotebookNotes() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uitesting", "-phase3SeedAnnotations",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["library.book.00000000-0000-4000-8000-000000000001"].waitForExistence(timeout: 12),
                      "Wait for the shared library model before opening Notebook")
        let notebook = app.tabBars.buttons["Notebook"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 5))
        notebook.tap()
        select("notes", in: app)
        XCTAssertTrue(row(noteRowID, in: app).waitForExistence(timeout: 8),
                      "The seeded saved passage must appear as one merged Notes row before searching")
        XCTAssertTrue(searchField(in: app).waitForExistence(timeout: 5))
        assertConsolidatedNotes(app)
        return app
    }

    private func assertConsolidatedNotes(_ app: XCUIApplication) {
        XCTAssertFalse(app.buttons["notebook.filter.highlights"].exists)
        XCTAssertFalse(app.buttons["Highlights"].exists, "Colour marks and written notes share the Notes filter")
        XCTAssertFalse(row("notes.row.00000000-0000-4000-8000-0000000000F1", in: app).exists,
                       "The seed's colour record must not duplicate its noted passage")
    }

    /// Earlier Notebook tests seed a saved word in the shared simulator store.
    /// Remove only those test rows so this first-use assertion remains isolated
    /// when the suite runs as one process rather than after an app reinstall.
    private func removeSavedWordsIfNeeded(from app: XCUIApplication) {
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", "vocab.delete.")
        for _ in 0..<8 {
            let delete = app.buttons.matching(predicate).firstMatch
            guard delete.waitForExistence(timeout: 1) else { return }
            // The definition and source can span several screens at XXXL.
            // Reach the actual action rather than assuming one swipe suffices.
            for _ in 0..<12 {
                if delete.isHittable && deleteIsFullyVisible(delete, in: app) { break }
                if app.tables.firstMatch.exists {
                    app.tables.firstMatch.swipeUp()
                } else if app.collectionViews.firstMatch.exists {
                    app.collectionViews.firstMatch.swipeUp()
                } else {
                    XCTFail("A saved word exists but its delete action is not reachable")
                    return
                }
            }
            XCTAssertTrue(delete.isHittable, "A seeded word's delete action must be reachable for test isolation")
            XCTAssertTrue(deleteIsFullyVisible(delete, in: app),
                          "The entire Delete action must be visible above the native tab bar")
            // firstMatch is a live query: after deletion it can resolve to the
            // next saved word. Bind the visible action before changing the list.
            let deleteID = delete.identifier
            let exactDelete = app.buttons[deleteID]
            attachScreenshot("notebook-seeded-word-delete-reachable", app: app)
            exactDelete.tap()
            let alert = app.alerts.firstMatch
            XCTAssertTrue(alert.waitForExistence(timeout: 3))
            alert.buttons["Delete Word"].tap()
            let alertDismissed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: alert
            )
            XCTAssertEqual(XCTWaiter.wait(for: [alertDismissed], timeout: 3), .completed,
                           "Confirming deletion must dismiss the confirmation alert")
            let exactWordRemoved = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: exactDelete
            )
            XCTAssertEqual(XCTWaiter.wait(for: [exactWordRemoved], timeout: 3), .completed,
                           "The selected seeded word should be removed before the empty-state check")
        }
    }

    private func deleteIsFullyVisible(_ delete: XCUIElement, in app: XCUIApplication) -> Bool {
        guard delete.exists else { return false }
        let viewport = app.windows.firstMatch.frame
        guard viewport.contains(delete.frame) else { return false }
        let tabs = app.tabBars.firstMatch
        if tabs.exists && !tabs.frame.isEmpty && viewport.intersects(tabs.frame) {
            return delete.frame.maxY <= tabs.frame.minY
        }
        return true
    }

    private func select(_ kind: String, in app: XCUIApplication) {
        let identified = app.buttons["notebook.filter.\(kind)"].firstMatch
        if identified.exists && identified.isHittable {
            identified.tap()
            return
        }
        // At accessibility text sizes the collection picker is a menu. Its
        // choices become reachable only after opening the picker itself.
        let collection = app.buttons["notebook.collection"].firstMatch
        if collection.exists && collection.isHittable { collection.tap() }
        let filter = identified.exists ? identified : app.buttons[kind.capitalized].firstMatch
        guard filter.waitForExistence(timeout: 5) else {
            attachScreenshot("notebook-missing-filter", app: app)
            XCTFail("Notebook filter not exposed: \(app.debugDescription)")
            return
        }
        filter.tap()
    }

    private func row(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    // The Notebook container can propagate notebook.screen to direct controls.
    // Use the visible filter label and sole search field in that case; stored
    // rows keep their UUID identifiers inside the List.
    private func searchField(in app: XCUIApplication) -> XCUIElement {
        let identified = app.textFields["notebook.search"]
        return identified.exists ? identified : app.textFields.firstMatch
    }

    private func clearButton(in app: XCUIApplication) -> XCUIElement {
        let identified = app.buttons["notebook.search.clear"]
        return identified.exists ? identified : app.buttons["Clear search"]
    }

    private func replaceQuery(in field: XCUIElement, with text: String) {
        field.tap()
        let existing = field.value as? String ?? ""
        if !existing.isEmpty && existing != "Search Notebook" {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        field.typeText(text)
    }

    private func assertSearchCleared(_ field: XCUIElement) {
        let value = field.value as? String ?? ""
        XCTAssertTrue(value.isEmpty || value == "Search Notebook", "Search should be empty, not \(value)")
    }

    private func assertKeyboardDismissed(_ app: XCUIApplication) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed,
                       "Clear search must dismiss the keyboard so recovered notes are readable")
    }

    private func attachScreenshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
