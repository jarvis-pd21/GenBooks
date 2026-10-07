import XCTest

final class NotebookContentUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLongSavedNoteCanScrollToItsEndingInNotebookAfterRelaunch() throws {
        let artifacts = try artifactsDirectory()
        let app = XCUIApplication()
        app.launchArguments = [
            "-uitesting", "-phase3DemoSelection",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
            "-livingreader.reader.scrollMode", "scroll"
        ]
        defer { app.terminate() }
        app.launch()
        let bookID = "library.book.00000000-0000-4000-8000-000000000001"
        let book = app.buttons[bookID].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 15))
        book.tap()
        XCTAssertTrue(app.descendants(matching: .any)["selection.actions.sheet"].firstMatch
            .waitForExistence(timeout: 10))
        let noteAction = app.buttons["selection.note"].firstMatch
        XCTAssertTrue(noteAction.waitForExistence(timeout: 5))
        noteAction.tap()

        let field = app.descendants(matching: .any)["note.editor.field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8), "Use the actual editable note field")
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.90)).tap()
        let existing = field.value as? String ?? ""
        if !existing.isEmpty && existing != "Write a note…" {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        let ending = "NOTE END: all lines remain readable."
        let lines = (1...36).map { String(format: "Notebook line %02d", $0) } + [ending]
        let body = lines.joined(separator: "\n")
        field.typeText(body)
        XCTAssertEqual(field.value as? String, body, "Save the complete authored note through its real editor")
        let save = app.buttons["note.editor.save"].firstMatch
        XCTAssertTrue(save.isHittable)
        save.tap()
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.descendants(matching: .any)["note.editor.sheet"].firstMatch
        )
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 8), .completed)

        // Reopen persisted annotations rather than relying on the editor's state.
        app.terminate()
        app.launchArguments.removeAll { $0 == "-phase3DemoSelection" }
        app.launch()
        XCTAssertTrue(app.buttons[bookID].firstMatch.waitForExistence(timeout: 15))
        app.tabBars.buttons["Notebook"].firstMatch.tap()
        let notes = app.buttons.matching(NSPredicate(format: "label == %@", "Notes")).firstMatch
        XCTAssertTrue(notes.waitForExistence(timeout: 6))
        notes.tap()
        let renderedNote = app.staticTexts.matching(NSPredicate(format: "label == %@", body)).firstMatch
        XCTAssertTrue(renderedNote.waitForExistence(timeout: 8))
        XCTAssertFalse(app.keyboards.firstMatch.exists)

        // A truncated Text can still expose its complete accessibility label.
        // Geometry must also accommodate the explicit lines, not just four rows.
        XCTAssertGreaterThan(renderedNote.frame.height, CGFloat(lines.count * 16),
                             "The complete note must have rendered height, not a four-line preview")
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        let list = app.descendants(matching: .any)["notes.list"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        let initialBottom = renderedNote.frame.maxY
        XCTAssertGreaterThan(initialBottom, tabs.frame.minY,
                             "The fixture must require scrolling to reach its ending")
        try screenshot("notebook-long-note-start", app: app, directory: artifacts)

        for _ in 0..<8 {
            if renderedNote.frame.maxY <= tabs.frame.minY - 8 { break }
            list.swipeUp()
        }
        let finalFrame = renderedNote.frame
        try screenshot("notebook-long-note-ending", app: app, directory: artifacts)
        XCTAssertLessThan(finalFrame.maxY, initialBottom - 40, "Scrolling must move the saved note")
        XCTAssertLessThanOrEqual(finalFrame.maxY, tabs.frame.minY - 8,
                                "The final line must be above, not behind, the tab bar")
        XCTAssertGreaterThan(finalFrame.maxY - 24, list.frame.minY,
                             "The ending must remain inside the visible list, not scroll past it")
        XCTAssertTrue(renderedNote.label.hasSuffix(ending))
    }

    private func artifactsDirectory() throws -> URL {
        try UITestArtifactDirectory.require(sourceFile: #filePath)
    }

    private func screenshot(_ name: String, app: XCUIApplication, directory: URL) throws {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try shot.pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
    }
}
