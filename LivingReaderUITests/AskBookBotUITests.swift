import XCTest

/// Ask BookBot chrome: the renamed control, the empty composer, the tap-to-ask
/// bubbles, and voice mode driven by the stub dictation seam.
final class AskBookBotUITests: XCTestCase {
    private static let argentinaBookID = "library.book.00000000-0000-4000-8000-000000000001"
    private static let placeholder = "Ask BookBot…"
    private static let stubPhrase = "What does this passage mean in context?"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Rename
    //
    // The label is owned here on every surface that carries it. The selection
    // sheet's header bleed and Close placement belong to the Selection-chrome
    // work and are deliberately not asserted, so that fix can land either side
    // of this one.

    func testSelectionGridCellIsNeverJustTheBotName() {
        let app = launchApp(extraArguments: ["-phase3DemoSelection"])
        defer { app.terminate() }
        openArgentina(app)

        XCTAssertTrue(
            app.descendants(matching: .any)["selection.actions.sheet"].waitForExistence(timeout: 14),
            "Expected the selection actions sheet"
        )
        let ask = app.buttons["selection.ask"].firstMatch
        XCTAssertTrue(ask.waitForExistence(timeout: 6))
        XCTAssertTrue(ask.isHittable, "The renamed cell must stay tappable in the two-up grid")

        let label = ask.label.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertNotEqual(label.lowercased(), "bookbot", "The bare bot name is what the rename removes")
        XCTAssertEqual(label, "Ask BookBot")
        attach(app, "ask-rename-selection-grid")
    }

    func testAskEntryAndSheetTitleReadAskBookBot() {
        let app = launchApp()
        defer { app.terminate() }
        openArgentina(app)
        openAskFromOverflow(app)

        XCTAssertTrue(app.navigationBars["Ask BookBot"].waitForExistence(timeout: 8))
        XCTAssertFalse(
            app.navigationBars["BookBot"].exists,
            "The bare bot name is what the rename removes"
        )
        attach(app, "ask-bookbot-title")
    }

    func testSelectionAskOpensTheAskSheet() {
        let app = launchApp(extraArguments: ["-phase3DemoSelection", "-useMockAI"])
        defer { app.terminate() }
        openArgentina(app)

        XCTAssertTrue(
            app.descendants(matching: .any)["selection.actions.sheet"].waitForExistence(timeout: 14)
        )
        let ask = app.buttons["selection.ask"].firstMatch
        XCTAssertTrue(ask.waitForExistence(timeout: 6))
        ask.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["ask.sheet"].waitForExistence(timeout: 12),
            "Selection → Ask BookBot must open the chat sheet"
        )
        // A selection keeps its pinned Asking-about line (identifier on the
        // banner, not the decorative quote glyph whose system label is "Lyrics").
        let context = app.descendants(matching: .any)["ask.context"].firstMatch
        XCTAssertTrue(
            context.waitForExistence(timeout: 6),
            "A selection must pin an Asking-about context line"
        )
        XCTAssertTrue(context.label.contains("Asking about"), "Context line: \(context.label)")
    }

    // MARK: - Empty composer + tap-to-ask bubbles

    func testAskSheetOpensEmptyWithTapToAskBubbles() {
        let app = launchApp()
        defer { app.terminate() }
        openArgentina(app)
        openAskFromOverflow(app)

        let input = app.descendants(matching: .any)["ask.input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        let value = (input.value as? String) ?? ""
        XCTAssertFalse(
            value.contains("What does this mean in context"),
            "The composer must open empty, not pre-filled with a question to delete"
        )
        XCTAssertTrue(
            value.isEmpty || value == Self.placeholder,
            "Composer should show only its placeholder, got “\(value)”"
        )

        XCTAssertTrue(app.descendants(matching: .any)["ask.empty"].waitForExistence(timeout: 6))
        let label = app.staticTexts["ask.suggestions.label"].firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 6))
        XCTAssertEqual(label.label, "Tap to ask:")

        XCTAssertGreaterThanOrEqual(suggestionBubbles(app).count, 2, "Expected clickable prompt bubbles")
        attach(app, "ask-empty-suggestions")
    }

    func testCloseSitsOnTheTrailingSide() {
        let app = launchApp()
        defer { app.terminate() }
        openArgentina(app)
        openAskFromOverflow(app)

        let navigationBar = app.navigationBars["Ask BookBot"].firstMatch
        XCTAssertTrue(navigationBar.waitForExistence(timeout: 8))
        let close = app.buttons["ask.close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 6))
        XCTAssertGreaterThan(
            close.frame.midX,
            navigationBar.frame.midX,
            "Close belongs in the trailing corner a reader reaches for"
        )

        close.tap()
        XCTAssertTrue(app.descendants(matching: .any)["reader.screen"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["reader.textkit.text"].waitForExistence(timeout: 6))
    }

    func testTappingABubbleAsksImmediately() {
        let app = launchApp(extraArguments: ["-useMockAI"])
        defer { app.terminate() }
        openArgentina(app)
        openAskFromOverflow(app)

        let bubble = suggestionBubbles(app).element(boundBy: 0)
        XCTAssertTrue(bubble.waitForExistence(timeout: 8))
        let asked = bubble.label
        bubble.tap()

        let question = app.descendants(matching: .any)["ask.message.user"].firstMatch
        XCTAssertTrue(
            question.waitForExistence(timeout: 12),
            "A bubble must send its prompt, not merely fill the field"
        )
        XCTAssertEqual(question.label, asked, "The bubble asks exactly what it says")
        XCTAssertTrue(
            app.descendants(matching: .any)["ask.message.assistant"].waitForExistence(timeout: 15),
            "Expected a mock BookBot answer"
        )

        let input = app.descendants(matching: .any)["ask.input"].firstMatch
        let value = (input.value as? String) ?? ""
        XCTAssertTrue(value.isEmpty || value == Self.placeholder, "The composer stays clear after a bubble send")
        attach(app, "ask-bubble-sent")
    }

    // MARK: - Voice mode v1

    func testVoiceModeTranscribesAndAsksWithoutTyping() {
        // `-mockVoice` swaps in StubVoiceDictation: no mic, no permission dialog.
        let app = launchApp(extraArguments: ["-useMockAI", "-mockVoice"])
        defer { app.terminate() }
        openArgentina(app)
        openAskFromOverflow(app)

        let mic = app.descendants(matching: .any)["ask.voice.button"].firstMatch
        XCTAssertTrue(mic.waitForExistence(timeout: 8), "Voice mode needs a mic control in the composer")
        // Short press stays under holdThreshold so Listening latches instead of hold-to-send.
        mic.press(forDuration: 0.05)

        let status = app.descendants(matching: .any)["ask.voice.status"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 8), "Listening state must be visible")
        XCTAssertTrue(
            status.label.contains("Listening"),
            "Voice status: \(status.label)"
        )
        attach(app, "ask-voice-listening")

        mic.press(forDuration: 0.05)

        let question = app.descendants(matching: .any)["ask.message.user"].firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 12), "The transcript must be asked as a question")
        XCTAssertEqual(question.label, Self.stubPhrase)
        XCTAssertTrue(
            app.descendants(matching: .any)["ask.message.assistant"].waitForExistence(timeout: 15),
            "Expected a BookBot answer to the spoken question"
        )
        attach(app, "ask-voice-answered")

        // Reading is never blocked by voice.
        app.buttons["ask.close"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["reader.screen"].waitForExistence(timeout: 8))
    }

    // MARK: - Helpers

    private func launchApp(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uitesting",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-livingreader.reader.fontSize", "18",
            "-livingreader.reader.colorScheme", "system",
            "-livingreader.reader.fontFamily", "original",
            "-livingreader.reader.lineSpacing", "1.28",
            "-livingreader.reader.marginInset", "22",
            "-livingreader.reader.pageDim", "0",
            "-livingreader.reader.scrollMode", "scroll"
        ] + extraArguments
        app.launch()
        return app
    }

    private func openArgentina(_ app: XCUIApplication) {
        let book = app.descendants(matching: .any)[Self.argentinaBookID].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 14), "Expected the Argentina library row")
        book.tap()
        XCTAssertTrue(app.descendants(matching: .any)["reader.screen"].waitForExistence(timeout: 14))
        XCTAssertTrue(app.descendants(matching: .any)["reader.textkit.text"].waitForExistence(timeout: 10))
    }

    /// The overflow route is the stable one-tap entry to Ask; the selection
    /// route is asserted separately so a Selection chrome change can't take the
    /// chat-surface assertions down with it.
    private func openAskFromOverflow(_ app: XCUIApplication) {
        let more = app.buttons["reader.more.button"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        XCTAssertTrue(app.descendants(matching: .any)["reader.overflow.sheet"].waitForExistence(timeout: 8))

        let ask = app.buttons["reader.ask.button"].firstMatch
        XCTAssertTrue(ask.waitForExistence(timeout: 6))
        XCTAssertEqual(ask.label, "Ask BookBot", "The overflow entry says what it does")
        ask.tap()
        XCTAssertTrue(app.descendants(matching: .any)["ask.sheet"].waitForExistence(timeout: 12))
    }

    private func suggestionBubbles(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "ask.suggestion."))
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
