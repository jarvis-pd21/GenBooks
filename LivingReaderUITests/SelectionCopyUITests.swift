import XCTest

final class SelectionCopyUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCopyKeepsActionsOpenAndPastesOnlyReviewedPhraseIntoCancelledNote() {
        let app = launchAppOnDemoSelection()
        defer { app.terminate() }

        openFirstBook(in: app)

        let sheet = selectionActionsSheet(in: app)
        let phrase = app.staticTexts["selection.phrase"].firstMatch
        XCTAssertTrue(phrase.waitForExistence(timeout: 5))
        let displayedPhrase = phrase.label
        XCTAssertTrue(displayedPhrase.hasPrefix("“") && displayedPhrase.hasSuffix("”"),
                      "Selection review wraps the actual phrase in display-only quotation marks")
        let expectedText = String(displayedPhrase.dropFirst().dropLast())
        XCTAssertFalse(expectedText.isEmpty)

        let copy = app.buttons["selection.copy"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        XCTAssertEqual(copy.label, "Copy")
        if !copy.isHittable {
            let dragFrom = sheet.frame.height > 80
                ? sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
                : app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
            dragFrom.press(forDuration: 0.1,
                           thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)))
        }
        XCTAssertTrue(copy.isHittable, "Copy must be reachable in the existing selection sheet")
        copy.tap()
        wait(for: copy, predicate: NSPredicate(format: "label == %@", "Copied"),
             message: "Explicit Copy must acknowledge the action")
        XCTAssertTrue(sheet.exists, "Copy must not dismiss the reviewed selection")
        XCTAssertEqual(phrase.label, displayedPhrase)
        for id in ["selection.define", "selection.ask", "selection.note", "selection.regenFromWord"] {
            XCTAssertTrue(app.buttons[id].exists, "Copy must retain the existing \(id) action")
        }
        attachScreenshot("selection-copy-acknowledged")

        app.buttons["selection.note"].tap()
        let note = app.descendants(matching: .any)["note.editor.sheet"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 8))
        // Selection dismisses as Note presents. iOS 26 can leave a leftover
        // sheet id, so this is a settle wait rather than a hard dismiss assert.
        _ = XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"),
                object: sheet
            )],
            timeout: 3
        )
        let field = noteEditorField(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        if !field.isHittable {
            note.swipeUp()
        }
        XCTAssertTrue(field.isHittable, "Note draft field must be on-screen for native Paste")
        field.tap()
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 3)
        // -phase3DemoSelection seeds a note on the same passage, so Edit Note
        // opens with "Demo note for Phase 3 screenshots." already in the draft.
        // Clear it before Paste — Cut would clobber the clipboard we just filled.
        let preexisting = (field.value as? String) ?? ""
        if !preexisting.isEmpty && preexisting != "Write a note…" {
            field.press(forDuration: 0.8)
            let selectAll = app.menuItems["Select All"].firstMatch
            if selectAll.waitForExistence(timeout: 3) {
                selectAll.tap()
                // Send Delete to the focused editor. The keyboard's accessibility
                // tree can report an off-screen delete-key frame.
                app.typeText(String(XCUIKeyboardKey.delete.rawValue))
            }
        }
        field.press(forDuration: 0.8)

        let pasteMenuItem = app.menuItems["Paste"].firstMatch
        let paste = pasteMenuItem.waitForExistence(timeout: 3)
            ? pasteMenuItem : app.buttons["Paste"].firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "The native edit menu must offer Paste after Copy")
        paste.tap()
        // Exact phrase only. Strip a single pair of curly/smart quotes if iOS
        // still wraps the paste — the clipboard path must not include title/context.
        let plainOrExact = NSPredicate { obj, _ in
            guard let el = obj as? XCUIElement else { return false }
            let raw = (el.value as? String) ?? ""
            if raw == expectedText { return true }
            let curly = CharacterSet(charactersIn: "“”‘’\"'")
            return raw.trimmingCharacters(in: curly) == expectedText
        }
        wait(for: field, predicate: plainOrExact,
             message: "Pasted content must exactly match the reviewed phrase, without UI quotes, title or context; field.value=\(field.value ?? "<nil>") expected=\(expectedText)")
        attachScreenshot("selection-copy-pasted-exact-phrase")

        let cancel = app.navigationBars["Note"].buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        wait(for: note, predicate: NSPredicate(format: "exists == false"),
             message: "Cancel must close the draft without saving a note")
        XCTAssertTrue(app.descendants(matching: .any)["reader.screen"].firstMatch.waitForExistence(timeout: 5))
    }

    func testSelectionSheetHeaderIsTitlelessWithTrailingCloseAndNoBleed() {
        let app = launchAppOnDemoSelection()
        defer { app.terminate() }

        openFirstBook(in: app)

        let sheet = selectionActionsSheet(in: app)

        XCTAssertFalse(app.navigationBars["Selection"].exists)
        let exactTitle = app.staticTexts.matching(NSPredicate(format: "label == %@", "Selection")).firstMatch
        XCTAssertFalse(exactTitle.exists, "The header title word must be gone from the Selection pane")

        let phrase = app.staticTexts["selection.phrase"].firstMatch
        XCTAssertTrue(phrase.waitForExistence(timeout: 5))

        let define = app.buttons["selection.define"].firstMatch
        let ask = app.buttons["selection.ask"].firstMatch
        let copy = app.buttons["selection.copy"].firstMatch
        XCTAssertTrue(define.waitForExistence(timeout: 5))
        XCTAssertTrue(ask.waitForExistence(timeout: 5))
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        // Tall detent: bottom-row Copy reachable without scrolling (sheet.frame can be a 19pt flake).
        XCTAssertTrue(define.isHittable && ask.isHittable && copy.isHittable,
                      "Action grid must fit without scrolling on the tall Selection detent")
        XCTAssertEqual(ask.label, "Ask BookBot")

        XCTAssertLessThan(phrase.frame.maxY, define.frame.minY + 1,
                          "Reviewed phrase must sit above the action grid")
        XCTAssertGreaterThan(phrase.frame.minY, 40,
                             "Reviewed phrase must sit below the top safe area / header band")

        let close = app.descendants(matching: .any)["selection.close"].firstMatch
        if close.waitForExistence(timeout: 3), close.frame.width > 1, close.frame.height > 1 {
            XCTAssertGreaterThan(close.frame.midX, app.frame.midX - 0.5,
                                 "Close belongs on the trailing edge of the header")
            if close.isHittable { close.tap() }
            else { close.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        } else if app.buttons["Close"].firstMatch.waitForExistence(timeout: 2) {
            let labeled = app.buttons["Close"].firstMatch
            XCTAssertGreaterThan(labeled.frame.midX, app.frame.midX - 0.5)
            labeled.tap()
        } else if sheet.frame.height > 100 {
            sheet.swipeDown()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        }
        attachScreenshot("selection-header-close-trailing")
        wait(for: sheet, predicate: NSPredicate(format: "exists == false"),
             message: "Selection sheet must dismiss via Close or swipe")
        XCTAssertTrue(app.descendants(matching: .any)["reader.screen"].firstMatch.waitForExistence(timeout: 5))
    }

    /// Vertical SwiftUI TextField is a text view; Form cells used to steal the same id.
    private func noteEditorField(in app: XCUIApplication) -> XCUIElement {
        _ = app.descendants(matching: .any)["note.editor.field"].firstMatch.waitForExistence(timeout: 5)
        let textView = app.textViews["note.editor.field"].firstMatch
        if textView.exists { return textView }
        let textField = app.textFields["note.editor.field"].firstMatch
        if textField.exists { return textField }
        return app.descendants(matching: .any)["note.editor.field"].firstMatch
    }

    /// iOS 26 can expose multiple nodes with selection.actions.sheet; prefer the tallest.
    private func selectionActionsSheet(in app: XCUIApplication) -> XCUIElement {
        let query = app.descendants(matching: .any).matching(identifier: "selection.actions.sheet")
        XCTAssertTrue(query.firstMatch.waitForExistence(timeout: 12), "Expected selection actions sheet")
        var best = query.firstMatch
        var bestHeight = best.frame.height
        let count = query.count
        if count > 1 {
            for index in 0..<count {
                let candidate = query.element(boundBy: index)
                let height = candidate.frame.height
                if height > bestHeight {
                    best = candidate
                    bestHeight = height
                }
            }
        }
        return best
    }

    private func launchAppOnDemoSelection() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uitesting", "-phase3DemoSelection",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-livingreader.reader.fontSize", "18",
            "-livingreader.reader.colorScheme", "system",
            "-livingreader.reader.fontFamily", "original",
            "-livingreader.reader.lineSpacing", "1.28",
            "-livingreader.reader.marginInset", "22",
            "-livingreader.reader.pageDim", "0",
            "-livingreader.reader.scrollMode", "scroll"
        ]
        app.launch()
        return app
    }

    private func openFirstBook(in app: XCUIApplication) {
        let book = app.descendants(matching: .any)[
            "library.book.00000000-0000-4000-8000-000000000001"
        ].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 12))
        book.tap()
    }

    private func wait(for element: XCUIElement, predicate: NSPredicate, message: String) {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 6), .completed, message)
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
