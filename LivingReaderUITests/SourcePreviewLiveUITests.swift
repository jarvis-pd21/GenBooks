import XCTest

/// Opt-in paid acceptance and a separate saved-book display check. Ordinary UI
/// suites skip both before launching. The DEBUG transport owns the spending cap;
/// this suite neither
/// installs a key nor substitutes an AI service, source, manuscript or receipt.
final class SourcePreviewLiveUITests: XCTestCase {
    private let bundleID = "com.jarvis.livingreader.codex.createtrial"
    private let title = "Argentina — Source Preview Trial"
    private let topic = "Explain the historical periods covered by the opening Wikipedia excerpt of History of Argentina, using only supported details."
    private let voice = "Clear, warm nonfiction with concrete detail and a natural progression."

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCreateOpeningExcerptTrialPublishesAndReopensReviewedBook() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SOURCE_PREVIEW_LIVE_ACCEPTANCE"] == "1",
              let trialID = environment["SOURCE_PREVIEW_TRIAL_ID"],
              UUID(uuidString: trialID) != nil else {
            throw XCTSkip("Requires SOURCE_PREVIEW_LIVE_ACCEPTANCE=1 and a valid SOURCE_PREVIEW_TRIAL_ID; may incur capped provider charges.")
        }

        let app = XCUIApplication(bundleIdentifier: bundleID)
        app.launchArguments = [
            "-sourcePreviewTrial",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-livingreader.ai.generationModel", "gpt-6-astra",
            "-livingreader.reader.scrollMode", "scroll",
            "-livingreader.reader.fontSize", "18",
            "-livingreader.reader.fontFamily", "original",
            "-livingreader.reader.colorScheme", "system"
        ]
        app.launchEnvironment = ["SOURCE_PREVIEW_TRIAL_ID": trialID]
        XCTAssertTrue(Set(app.launchArguments).isDisjoint(with: [
            "-uitesting", "-useMockAI", "-phase4MockAsk", "-phase5AdaptationDemo"
        ]))
        app.launch()
        defer { app.terminate() }
        waitForLibrary(app)
        XCTAssertFalse(exactText(title, in: app).exists,
                       "Use an isolated app without an earlier trial book; this test never replaces or retries one.")
        tap(app.buttons["library.create.button"].firstMatch)
        let generateTab = app.buttons["create.tab.generate"].firstMatch
        tap(generateTab)
        let titleField = app.textFields["create.gen.title"].firstMatch
        tap(titleField)
        titleField.typeText(title)
        XCTAssertEqual(titleField.value as? String, title)
        answer(topic, in: app)
        answer(voice, in: app)

        tap(app.buttons["create.source.open"].firstMatch)
        let article = app.textFields["create.source.article"].firstMatch
        XCTAssertTrue(article.waitForExistence(timeout: 8))
        XCTAssertEqual(article.value as? String, "History of Argentina")
        tap(app.buttons["create.source.scope"].firstMatch)
        tap(app.buttons["Opening excerpt"].firstMatch)
        let disclosure = app.staticTexts["create.source.disclosure"].firstMatch
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        XCTAssertTrue(disclosure.label.contains("opening Wikipedia excerpt"))
        XCTAssertTrue(disclosure.label.contains("not the full article"))
        XCTAssertTrue(disclosure.label.contains("independent fact-check"))
        attach("source-trial-approved-brief", app: app)

        // The sole Generate tap in this test. Never retry after an error/timeout.
        tap(app.buttons["create.source.generate"].firstMatch)
        let body = app.textViews["reader.textkit.text"].firstMatch
        let error = app.staticTexts["create.gen.error"].firstMatch
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            body.exists || error.exists
        }, object: app)
        let outcome = XCTWaiter.wait(for: [finished], timeout: 210)
        attach("source-trial-generation-result", app: app)
        guard outcome == .completed, body.exists, !error.exists else {
            let detail = error.exists ? error.label : "No reader appeared within 210 seconds."
            throw NSError(domain: "SourcePreviewLiveAcceptance", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Single Generate attempt failed: \(detail)"])
        }
        let firstReader = try readerText(app)
        let firstGuide = try inspectGuide(app, readerText: firstReader, screenshotPrefix: "source-trial-published")
        tap(app.buttons["reader.guide.done"].firstMatch)

        // Same trial identity and launch configuration, without another Generate.
        app.terminate()
        app.launch()
        waitForLibrary(app)
        let saved = exactText(title, in: app)
        reveal(saved, in: app)
        tap(saved)
        let reopenedReader = try readerText(app)
        XCTAssertEqual(reopenedReader, firstReader, "Relaunch must reopen the same saved text, not regenerate it.")
        attach("source-trial-reopened-reader", app: app)
        let reopenedGuide = try inspectGuide(app, readerText: reopenedReader, screenshotPrefix: "source-trial-reopened",
                                            expected: firstGuide)
        XCTAssertEqual(reopenedGuide.opening, firstGuide.opening)
        XCTAssertEqual(reopenedGuide.wordCount, firstGuide.wordCount)
        XCTAssertEqual(reopenedGuide.source, firstGuide.source)
        tap(app.buttons["reader.guide.done"].firstMatch)
    }

    /// Display-only follow-up to the retained paid attempt, not a retry of it.
    /// The frozen JSON supplies expectations; it is never copied into the app.
    func testSavedTrialBookReopensWithExactSourceWithoutGeneration() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SOURCE_PREVIEW_SAVED_ACCEPTANCE"] == "1",
              let path = environment["SOURCE_PREVIEW_SAVED_BOOK_PATH"], !path.isEmpty else {
            throw XCTSkip("Requires SOURCE_PREVIEW_SAVED_ACCEPTANCE=1 and SOURCE_PREVIEW_SAVED_BOOK_PATH; displays an already saved trial only.")
        }
        let url = URL(fileURLWithPath: path)
        let frozenBytes = try Data(contentsOf: url)
        let book = try XCTUnwrap(JSONSerialization.jsonObject(with: frozenBytes) as? [String: Any])
        XCTAssertEqual(book["title"] as? String, title)
        let chapters = try XCTUnwrap(book["chapters"] as? [[String: Any]])
        XCTAssertEqual(chapters.count, 1)
        let chapter = try XCTUnwrap(chapters.first)
        let activeID = try XCTUnwrap(chapter["activeRevisionId"] as? String)
        let revisions = try XCTUnwrap(chapter["revisions"] as? [[String: Any]])
        let active = revisions.filter { ($0["id"] as? String) == activeID }
        XCTAssertEqual(active.count, 1)
        let revision = try XCTUnwrap(active.first)
        let receipt = try XCTUnwrap(revision["sourceReview"] as? [String: Any])
        XCTAssertEqual(receipt["bookID"] as? String, book["id"] as? String)
        XCTAssertEqual(receipt["chapterID"] as? String, chapter["id"] as? String)
        let requirement = try XCTUnwrap(chapter["sourceGrounding"] as? [String: Any])
        let source = try XCTUnwrap(requirement["source"] as? [String: Any])
        XCTAssertEqual(source["scope"] as? String, "wikipediaOpeningExcerpt")
        XCTAssertEqual(source["title"] as? String, "History of Argentina")
        let sourceText = try XCTUnwrap(source["text"] as? String)
        let rawBlocks = try XCTUnwrap(revision["blocks"] as? [[String: Any]])
        let blocks = try rawBlocks.map { block -> (index: Int, kind: String, text: String) in
            (try XCTUnwrap(block["orderIndex"] as? Int), try XCTUnwrap(block["kind"] as? String),
             try XCTUnwrap(block["text"] as? String))
        }.sorted { $0.index < $1.index }
        XCTAssertGreaterThanOrEqual(blocks.count, 5)
        XCTAssertEqual(blocks.map { $0.index }, Array(0..<blocks.count))
        XCTAssertEqual(blocks.first?.kind, "heading")
        XCTAssertEqual(blocks[blocks.count - 2].kind, "callout")
        XCTAssertEqual(blocks.last?.kind, "paragraph")
        let paragraphs = Array(blocks.dropFirst().dropLast(2))
        XCTAssertTrue(paragraphs.allSatisfy { $0.kind == "paragraph" && $0.text.hasSuffix(" [1]") })
        let opening = try XCTUnwrap(paragraphs.first?.text)
        let wordCount = paragraphs.reduce(0) { $0 + $1.text.dropLast(4).split(whereSeparator: \.isWhitespace).count }
        let expected = (opening: opening, wordCount: wordCount, source: sourceText)
        // ReaderDocumentBuilder preserves these kinds verbatim, separates blocks
        // by two newlines and appends three trailing layout-padding newlines.
        let expectedReader = blocks.map { $0.text }.joined(separator: "\n\n") + "\n\n\n"

        let app = XCUIApplication(bundleIdentifier: bundleID)
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-livingreader.reader.scrollMode", "scroll",
            "-livingreader.reader.fontSize", "18",
            "-livingreader.reader.fontFamily", "original",
            "-livingreader.reader.colorScheme", "system"
        ]
        app.launchEnvironment = [:] // No trial identifier, credentials or opt-in provider flag.
        defer { app.terminate() }
        for inspection in 1...2 {
            app.launch()
            waitForLibrary(app)
            let saved = exactText(title, in: app)
            reveal(saved, in: app)
            tap(saved)
            let displayed = try readerText(app)
            XCTAssertEqual(displayed, expectedReader, "The full reader must match the frozen active revision.")
            attach("source-trial-saved-\(inspection)-reader", app: app)
            let observed = try inspectGuide(app, readerText: displayed,
                                            screenshotPrefix: "source-trial-saved-\(inspection)", expected: expected)
            XCTAssertEqual(observed.opening, opening)
            XCTAssertEqual(observed.source, sourceText)
            XCTAssertEqual(observed.wordCount, wordCount)
            tap(app.buttons["reader.guide.done"].firstMatch)
            app.terminate()
        }
        XCTAssertEqual(try Data(contentsOf: url), frozenBytes, "The frozen expectation artifact must remain unchanged.")
    }

    private func waitForLibrary(_ app: XCUIApplication) {
        let create = app.buttons["library.create.button"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 15))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: create)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
    }

    private func answer(_ text: String, in app: XCUIApplication) {
        let view = app.textViews["create.gen.input"].firstMatch
        let input = view.exists ? view : app.textFields["create.gen.input"].firstMatch
        tap(input)
        input.typeText(text)
        tap(app.buttons["create.gen.send"].firstMatch)
        let echoed = app.staticTexts.matching(identifier: "create.gen.message.reader")
            .matching(NSPredicate(format: "label == %@", text)).firstMatch
        XCTAssertTrue(echoed.waitForExistence(timeout: 8), "The actual chat must accept the reader's answer.")
    }

    private func readerText(_ app: XCUIApplication) throws -> String {
        let body = app.textViews["reader.textkit.text"].firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 12))
        let text = try XCTUnwrap(body.value as? String)
        XCTAssertTrue(text.contains(title))
        XCTAssertTrue(text.contains(" [1]"), "Published prose must retain source citations.")
        XCTAssertGreaterThan(text.count, 300)
        return text
    }

    private func inspectGuide(_ app: XCUIApplication, readerText: String, screenshotPrefix: String,
                              expected: (opening: String, wordCount: Int, source: String)? = nil) throws
        -> (opening: String, wordCount: Int, source: String) {
        tap(app.buttons["reader.toc.button"].firstMatch)
        tap(app.buttons["reader.toc.guide"].firstMatch)
        let guideTitle = app.staticTexts["reader.guide.title"].firstMatch
        XCTAssertTrue(guideTitle.waitForExistence(timeout: 8))
        XCTAssertEqual(guideTitle.label, title)
        let countLabel = app.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH %@ AND label ENDSWITH %@", "Source-checked preview · ", " prose words"
        )).firstMatch
        XCTAssertTrue(countLabel.waitForExistence(timeout: 6))
        let countText = countLabel.label
            .replacingOccurrences(of: "Source-checked preview · ", with: "")
            .replacingOccurrences(of: " prose words", with: "")
        let count = try XCTUnwrap(Int(countText))
        XCTAssertGreaterThan(count, 0) // Actual count, not a fabricated exact 400-word claim.

        let overview = "Opening passage · preview"
        let opening = try disclosedText(overview, in: app, expected: expected?.opening) { label in
            label.hasSuffix(" [1]") && readerText.contains(label)
        }
        XCTAssertNotEqual(opening, topic)
        XCTAssertNotEqual(opening, voice)
        attach("\(screenshotPrefix)-opening", app: app)
        try tapNamedDisclosure(overview, in: app, towardTop: true)

        try tapNamedDisclosure("Sources and limits", in: app)
        let savedSource = "Saved opening excerpt: History of Argentina"
        let source = try disclosedText(savedSource, in: app, expected: expected?.source) { label in
            label.split(whereSeparator: \.isWhitespace).count > 160
                && label.count <= 8_000
                && label.components(separatedBy: "\n\n").filter { !$0.isEmpty }.count > 1
        }
        attach("\(screenshotPrefix)-retained-source", app: app)
        let observed = try JSONSerialization.data(withJSONObject: [
            "opening": opening, "source": source, "wordCount": count
        ], options: [.sortedKeys])
        let attachment = XCTAttachment(data: observed, uniformTypeIdentifier: "public.json")
        attachment.name = "source-trial-observed-guide"
        attachment.lifetime = .keepAlways
        add(attachment)
        // These are visible-prose and persistence checks, not a literary-quality
        // score, independent factual verification, or proof of proxy accounting.
        return (opening, count, source)
    }

    /// Nested DisclosureGroups can inherit their parent's accessibility ID.
    /// Bind the observed text to the named control's closed/open/closed/open
    /// transitions instead of selecting an arbitrary long label elsewhere.
    private func disclosedText(_ disclosure: String, in app: XCUIApplication,
                               expected: String?, accepts: (String) -> Bool) throws -> String {
        let before = Set(app.staticTexts.allElementsBoundByIndex.map(\.label))
        if let expected { XCTAssertFalse(exactText(expected, in: app).exists) }
        try tapNamedDisclosure(disclosure, in: app)
        let label: String
        if let expected {
            let exact = exactText(expected, in: app)
            XCTAssertTrue(exact.waitForExistence(timeout: 6))
            XCTAssertEqual(exact.label, expected)
            label = expected
        } else {
            var candidates = Set<String>()
            let deadline = Date().addingTimeInterval(6)
            repeat {
                let after = Set(app.staticTexts.allElementsBoundByIndex.map(\.label))
                candidates = Set(after.subtracting(before).filter(accepts))
                if !candidates.isEmpty { break }
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            } while Date() < deadline
            guard candidates.count == 1, let found = candidates.first else {
                throw NSError(domain: "SourcePreviewLiveAcceptance", code: 2,
                              userInfo: [NSLocalizedDescriptionKey:
                                "Expected one newly exposed body in \(disclosure); found \(candidates.count)."])
            }
            label = found
        }
        XCTAssertTrue(accepts(label))
        try tapNamedDisclosure(disclosure, in: app, towardTop: true)
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !self.exactText(label, in: app).exists
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 6), .completed,
                       "The observed text must belong to this disclosure, not another visible section.")
        try tapNamedDisclosure(disclosure, in: app)
        let reopened = exactText(label, in: app)
        XCTAssertTrue(reopened.waitForExistence(timeout: 6))
        XCTAssertEqual(reopened.label, label)
        return label
    }

    private func exactText(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == %@", text)).firstMatch
    }

    /// Do not retain or tap a named nested-disclosure XCUIElement: resolving it
    /// again can select another control with its inherited identifier. Read fresh
    /// indexed buttons and tap the disclosure's visible chevron. The label can
    /// overlap selectable content; the nested chevron is the actual toggle.
    private func tapNamedDisclosure(_ label: String, in app: XCUIApplication,
                                    towardTop: Bool = false) throws {
        for attempt in 0...8 {
            let viewport = app.frame
            let buttons = app.buttons.allElementsBoundByIndex.map { (label: $0.label, frame: $0.frame) }
            let frames = buttons.filter { $0.label == label }.map(\.frame)
            guard frames.count <= 1 else {
                throw NSError(domain: "SourcePreviewLiveAcceptance", code: 3,
                              userInfo: [NSLocalizedDescriptionKey:
                                "Expected a unique exact disclosure label for \(label); found \(frames.count)."])
            }
            if let frame = frames.first, !frame.isNull, !frame.isInfinite,
               frame.width > 0, frame.height > 0, viewport.contains(frame) {
                let chevrons = buttons.filter {
                    $0.label.isEmpty && frame.contains($0.frame) && $0.frame.width > 0
                        && $0.frame.width < 30 && $0.frame.height > 0 && $0.frame.height < 30
                        && $0.frame.midX > frame.midX
                }
                guard chevrons.count == 1 else {
                    throw NSError(domain: "SourcePreviewLiveAcceptance", code: 5,
                                  userInfo: [NSLocalizedDescriptionKey:
                                    "Expected one visible chevron inside \(label); found \(chevrons.count)."])
                }
                let target = chevrons[0].frame
                app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
                    .withOffset(CGVector(dx: target.midX - viewport.minX, dy: target.midY - viewport.minY))
                    .tap()
                return
            }
            guard attempt < 8 else { break }
            // Every scroll is followed by a new indexed label/frame scan.
            if let frame = frames.first, frame.height > 0, frame.minY < viewport.minY {
                app.swipeDown()
            } else if let frame = frames.first, frame.height > 0, frame.maxY > viewport.maxY {
                app.swipeUp()
            } else if towardTop {
                app.swipeDown()
            } else {
                app.swipeUp()
            }
        }
        throw NSError(domain: "SourcePreviewLiveAcceptance", code: 4,
                      userInfo: [NSLocalizedDescriptionKey:
                        "No unique exact disclosure label inside the app viewport: \(label)."])
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, towardTop: Bool = false) {
        for _ in 0..<8 where !element.isHittable {
            if towardTop { app.swipeDown() } else { app.swipeUp() }
        }
        XCTAssertTrue(element.isHittable)
    }

    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 8))
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [hittable], timeout: 8), .completed)
        element.tap()
    }

    private func attach(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
