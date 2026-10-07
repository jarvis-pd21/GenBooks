import XCTest

final class SavedMarksLifecycleUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testNoteCreateEditCancelDeleteAndReopenWithoutChangingBook() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uitesting", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-livingreader.reader.scrollMode", "scroll"]
        defer { app.terminate() }
        app.launch()
        let marker = "Lifecycle \(UUID().uuidString.prefix(8))"
        try importOwnedBook(app, title: marker)
        let text = app.textViews["reader.textkit.text"].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        let originalBook = try XCTUnwrap(text.value as? String)
        text.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.42)).press(forDuration: 1.1)
        XCTAssertTrue(app.buttons["selection.note"].waitForExistence(timeout: 8))
        app.buttons["selection.note"].tap()
        XCTAssertTrue(app.buttons["note.editor.save"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["note.editor.delete"].exists, "A new unsaved note has nothing to delete")
        let expand = app.buttons["note.editor.passage.expand"].firstMatch
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(expand.frame.height, 44, "Full passage needs a real 44-point control, not outer spacing")
        XCTAssertGreaterThanOrEqual(expand.frame.width, 44)
        let field = editableNote(app)
        field.tap()
        field.typeText(marker + " saved note")
        app.buttons["note.editor.save"].tap()
        assertEditorClosed(app)

        openNotebookNotesAfterRelaunch(app)
        let saved = app.staticTexts[marker + " saved note"].firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 8), "A saved note must reopen from Notebook")
        saved.tap()
        let editorDelete = app.buttons["note.editor.delete"].firstMatch
        XCTAssertTrue(editorDelete.waitForExistence(timeout: 8))
        XCTAssertTrue(editorDelete.isHittable, "Delete must sit in the editor chrome with Cancel/Update, not below the fold")
        replaceNote(app, with: marker + " discarded draft")
        app.buttons["note.editor.cancel"].tap()
        assertEditorClosed(app)
        XCTAssertTrue(saved.waitForExistence(timeout: 5), "Cancel must retain the previous saved body")
        saved.tap()
        XCTAssertEqual(editableNote(app).value as? String, marker + " saved note")
        replaceNote(app, with: marker + " updated note")
        app.buttons["note.editor.color.green"].tap()
        app.buttons["note.editor.save"].tap()
        assertEditorClosed(app)

        openNotebookNotesAfterRelaunch(app)
        let updated = app.staticTexts[marker + " updated note"].firstMatch
        XCTAssertTrue(updated.waitForExistence(timeout: 8))
        updated.tap()
        let delete = app.buttons["note.editor.delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 8))
        XCTAssertTrue(delete.isHittable, "Delete must be tappable without scrolling the editor")
        delete.tap()
        XCTAssertTrue(app.buttons["Keep Note"].waitForExistence(timeout: 5))
        screenshot("note-delete-confirmation", app: app)
        app.buttons["Keep Note"].tap()
        XCTAssertTrue(app.buttons["note.editor.save"].exists, "Cancel deletion keeps the editor and saved note")
        app.buttons["note.editor.cancel"].tap()
        assertEditorClosed(app)
        XCTAssertTrue(updated.waitForExistence(timeout: 5))
        updated.tap()
        XCTAssertTrue(delete.waitForExistence(timeout: 8))
        XCTAssertTrue(delete.isHittable)
        delete.tap()
        // Alert confirm shares the VoiceOver name "Delete Note" with the
        // toolbar control; exclude the editor identifier so we tap confirm.
        let confirmation = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Delete Note", "note.editor.delete")).firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.tap()
        assertEditorClosed(app)
        XCTAssertFalse(updated.exists)
        openNotebookNotesAfterRelaunch(app)
        XCTAssertFalse(updated.exists, "Confirmed deletion persists across relaunch")

        app.tabBars.buttons["Library"].tap()
        let book = app.staticTexts[marker].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 8))
        if !book.isHittable { app.swipeUp() }
        book.tap()
        XCTAssertTrue(text.waitForExistence(timeout: 8))
        XCTAssertEqual(text.value as? String, originalBook, "Only the test-created note, never book content, was deleted")
        screenshot("note-deleted-reader-preserved", app: app)
    }

    func testWordsVisibleDeleteCancelAndConfirmPersistWithoutHiddenSwipe() {
        let app = XCUIApplication()
        // This flag explicitly creates the deterministic F3 test word. No user word is targeted.
        app.launchArguments = ["-uitesting", "-phase3SeedAnnotations", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        defer { app.terminate() }
        app.launch()
        waitForLibrary(app)
        app.tabBars.buttons["Notebook"].tap()
        let id = "00000000-0000-4000-8000-0000000000F3"
        let row = app.descendants(matching: .any)["vocab.row.\(id)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        let known = app.buttons["vocab.known.\(id)"].firstMatch
        XCTAssertTrue(known.isHittable)
        if known.label == "Mark unlearned" { known.tap() }
        XCTAssertEqual(known.label, "Mark known")
        known.tap()
        XCTAssertEqual(known.label, "Mark unlearned")
        known.tap()
        XCTAssertEqual(known.label, "Mark known")
        let delete = app.buttons["vocab.delete.\(id)"].firstMatch
        XCTAssertTrue(delete.isHittable, "Deletion must be discoverable without a swipe gesture")
        XCTAssertGreaterThanOrEqual(delete.frame.height, 44)
        delete.tap()
        XCTAssertTrue(app.buttons["Keep Word"].waitForExistence(timeout: 5))
        app.buttons["Keep Word"].tap()
        XCTAssertTrue(row.exists)
        screenshot("word-visible-delete-cancelled", app: app)
        delete.tap()
        XCTAssertTrue(app.buttons["Delete Word"].waitForExistence(timeout: 5))
        app.buttons["Delete Word"].tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)

        app.terminate()
        app.launchArguments.removeAll { $0 == "-phase3SeedAnnotations" }
        app.launch()
        waitForLibrary(app)
        app.tabBars.buttons["Notebook"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["vocab.list"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(row.exists, "The deleted test word must not return after relaunch")
    }

    private func importOwnedBook(_ app: XCUIApplication, title: String) throws {
        waitForLibrary(app)
        app.buttons["library.create.button"].tap()
        let textView = app.textViews["create.import.paste"].firstMatch
        let textField = app.textFields["create.import.paste"].firstMatch
        XCTAssertTrue(textView.waitForExistence(timeout: 5) || textField.waitForExistence(timeout: 5))
        let paste = textView.exists ? textView : textField
        if !paste.isHittable { app.swipeUp() }
        paste.tap()
        let paragraph = "Readers can save a thought and return to the words later. A quiet library keeps every passage unchanged while personal notes can be edited or removed. This is only a test book for checking saved notes."
        paste.typeText("# \(title)\n" + Array(repeating: paragraph, count: 6).joined(separator: "\n\n"))
        let submit = app.buttons["create.import.submit"].firstMatch
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        XCTAssertTrue(submit.isEnabled)
        submit.tap()
        XCTAssertTrue(app.descendants(matching: .any)["reader.screen"].firstMatch.waitForExistence(timeout: 15))
    }

    private func openNotebookNotesAfterRelaunch(_ app: XCUIApplication) {
        app.terminate()
        app.launch()
        waitForLibrary(app)
        app.tabBars.buttons["Notebook"].tap()
        let notes = app.buttons["notebook.filter.notes"].firstMatch
        XCTAssertTrue(notes.waitForExistence(timeout: 5))
        notes.tap()
    }

    private func waitForLibrary(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["library.book.00000000-0000-4000-8000-000000000001"].firstMatch.waitForExistence(timeout: 15))
    }

    private func editableNote(_ app: XCUIApplication) -> XCUIElement {
        let field = app.descendants(matching: .any)["note.editor.field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        return field
    }

    private func replaceNote(_ app: XCUIApplication, with body: String) {
        let field = editableNote(app)
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.95)).tap()
        let existing = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count) + body)
        XCTAssertEqual(field.value as? String, body)
    }

    private func assertEditorClosed(_ app: XCUIApplication) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                            object: app.buttons["note.editor.save"].firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 8), .completed)
    }

    private func screenshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
