import XCTest
import CryptoKit

/// Offline rejection smoke: deliberately invalid configuration cannot enable a
/// paid slot, Ask sheet or microphone, even when combined with a mock flag.
final class SourceContinuationIsolationUITests: XCTestCase {
    func testMalformedTrialClosesAskBeforeMicrophone() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uitesting", "-sourceContinuationTrial", "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US", "-livingreader.reader.scrollMode", "scroll"]
        app.launchEnvironment = ["SOURCE_CONTINUATION_TRIAL_ID": "invalid-offline-test-not-an-attempt"]
        defer { app.terminate() }
        app.launch()
        let book = app.buttons["library.book.00000000-0000-4000-8000-000000000001"].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 15))
        book.tap()
        let reader = app.textViews["reader.textkit.text"].firstMatch
        XCTAssertTrue(reader.waitForExistence(timeout: 12))
        let originalText = try XCTUnwrap(reader.value as? String)
        app.buttons["reader.more.button"].tap()
        let ask = app.buttons["reader.ask.button"].firstMatch
        XCTAssertTrue(ask.waitForExistence(timeout: 8))
        ask.tap()
        let notice = app.staticTexts["reader.banner"].firstMatch
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            notice.exists || app.descendants(matching: .any)["ask.sheet"].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 8), .completed)
        XCTAssertEqual(notice.label, "Ask and voice are unavailable in this isolated continuation trial.")
        XCTAssertFalse(app.descendants(matching: .any)["ask.sheet"].exists)
        XCTAssertFalse(app.buttons["ask.voice.button"].exists)
        XCTAssertEqual(reader.value as? String, originalText)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "offline-invalid-trial-ask-and-mic-refused"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}

/// Staged acceptance only. Ordinary suites skip before reading files or launching.
/// A later authorized runner supplies an already copied, frozen book and a fresh
/// capped trial. This file never copies books, creates markers, retrieves sources,
/// installs credentials or sends a request outside the app's one explicit action.
/// Word entry is mapped into actual rendered prose, not a physical-finger test.
final class SourceContinuationLiveUITests: XCTestCase {
    private let bundleID = "com.jarvis.livingreader.codex.continuationtrial"
    private let instructions = "Continue with clear, direct-subject nonfiction using only the saved source. Explain the remaining historical progression without repeating the frozen opening or inventing causes, scenes or dialogue."

    override func setUpWithError() throws { continueAfterFailure = false }

    func testActualReaderContinuationPublishesReopensAndRestoresOriginal() throws {
        let input = try configuration(optIn: "SOURCE_CONTINUATION_LIVE_ACCEPTANCE")
        XCTAssertNotEqual(ProcessInfo.processInfo.environment["SOURCE_CONTINUATION_SAVED_ACCEPTANCE"], "1",
                          "Live and display-only acceptance must be separate invocations.")
        let frozen = try loadBook(input.expectationURL)
        try validateFrozen(frozen, input: input)
        let frozenBytes = try Data(contentsOf: input.expectationURL)
        XCTAssertEqual(digest(frozenBytes), "9393c49128fcbadf1de614310193ee3c34bc70f2bb610c8a5fc2daed3be3e210")
        defer { XCTAssertEqual(try Data(contentsOf: input.expectationURL), frozenBytes) }
        XCTAssertTrue(try requestSlots(input).isEmpty, "A consumed trial must never be replayed.")

        let app = configuredApp(input, book: frozen, selectWord: false, liveRoute: true)
        defer { app.terminate() }
        app.launch()
        try openBook(frozen, in: app)
        let initial = try observeBook(input, name: "continuation-trial-original-disk")
        XCTAssertEqual(try json(initial.object), try json(frozen.object), "The runner must copy the exact original book once.")
        XCTAssertEqual(try readerBytes(app), Data(try expectedReader(frozen.active).utf8))
        screenshot("continuation-trial-original-reader", app: app)

        // First inspect the unobscured original reader; only the next launch maps
        // the runner's exact block/UTF-16 location into the existing selection UI.
        app.terminate()
        app.launchArguments.append("-sourceContinuationTrialSelection")
        app.launch()
        try openBook(frozen, in: app)
        tap(app.buttons["selection.regenFromWord"].firstMatch)
        let status = app.staticTexts["wordRegen.source.status"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 12))
        XCTAssertEqual(status.value as? String, "unprepared", "Never resume an earlier prepared or failed paid attempt.")
        XCTAssertFalse(app.buttons["wordRegen.intent.moreImages"].exists)
        XCTAssertFalse(app.buttons["wordRegen.intent.moreStories"].exists)
        let field = sourceInstructionField(in: app)
        tap(field)
        field.typeText(instructions)
        XCTAssertEqual(field.value as? String, instructions)
        reveal(app.buttons["wordRegen.preview.button"].firstMatch, in: app, towardTop: true)
        tap(app.buttons["wordRegen.preview.button"].firstMatch)
        let prepared = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            status.value as? String == "prepared"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [prepared], timeout: 12), .completed)
        XCTAssertTrue(try requestSlots(input).isEmpty, "Prepare must not reserve or forward either paid request.")
        XCTAssertEqual(try json(loadBook(input.observedURL).object), try json(frozen.object))
        let savedRequest = try observedAttempt(input, name: "continuation-trial-prepared-facts")
        XCTAssertEqual(savedRequest["phase"] as? String, "prepared")
        XCTAssertNil(savedRequest["candidate"])
        XCTAssertEqual(savedRequest["bookID"] as? String, frozen.id)
        XCTAssertEqual(savedRequest["chapterID"] as? String, frozen.chapterID)
        XCTAssertEqual(try json(dictionary(savedRequest, "source")), try json(frozen.source))
        let attemptID = try string(savedRequest, "id")
        let apply = app.buttons["wordRegen.apply"].firstMatch
        XCTAssertEqual(apply.label, "Write and review")
        screenshot("continuation-trial-prepared", app: app)

        // The ONLY writing/review action in this test. Failure consumes its slot;
        // there is no retry, Start new, Generate, or replacement trial identity.
        tap(apply)
        let error = app.staticTexts["wordRegen.error"].firstMatch
        let outcome = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            error.exists || (!apply.exists && app.textViews["reader.textkit.text"].exists)
        }, object: nil)
        let result = XCTWaiter.wait(for: [outcome], timeout: 210)
        screenshot("continuation-trial-write-review-result", app: app)
        guard result == .completed, !error.exists, !apply.exists else {
            if let bytes = try? Data(contentsOf: input.observedURL) {
                attachJSON(bytes, name: "continuation-trial-failed-observed-book")
            }
            throw failure(error.exists ? error.label : "The single write/review did not finish within 210 seconds; never replay it.")
        }
        let published = try observeBook(input, name: "continuation-trial-published-disk")
        try assertPublication(published, original: frozen, input: input)
        let savedResult = try observedAttempt(input, name: "continuation-trial-published-facts")
        XCTAssertEqual(savedResult["id"] as? String, attemptID)
        XCTAssertEqual(savedResult["phase"] as? String, "published")
        XCTAssertEqual(try json(dictionary(savedResult, "source")), try json(frozen.source))
        let candidate = try dictionary(savedResult, "candidate")
        XCTAssertEqual(try json(try XCTUnwrap(candidate["blocks"])), try json(try XCTUnwrap(published.active["blocks"])))
        XCTAssertEqual(try json(dictionary(candidate, "sourceReview")), try json(dictionary(published.active, "sourceReview")))
        try assertTransportEvidence(input, original: frozen, published: published)
        XCTAssertEqual(try readerBytes(app), Data(try expectedReader(published.active).utf8))
        let slots = try requestSlots(input)
        XCTAssertEqual(slots.count, 2, "Exactly one writer and one reviewer slot must be consumed.")
        attachJSON(try json(slots), name: "continuation-trial-consumed-request-digests")
        screenshot("continuation-trial-published-reader", app: app)
        app.terminate()

        try reopenAndRestore(input, original: frozen, published: published, slots: slots)
    }

    /// A separately authorized recovery may inspect/restore an already published
    /// result. It never enables trial routing or taps a writing/review control.
    func testSavedContinuationReopensAndRestoresWithoutWriting() throws {
        let input = try configuration(optIn: "SOURCE_CONTINUATION_SAVED_ACCEPTANCE")
        XCTAssertNotEqual(ProcessInfo.processInfo.environment["SOURCE_CONTINUATION_LIVE_ACCEPTANCE"], "1")
        let original = try loadBook(input.expectationURL)
        try validateFrozen(original, input: input)
        let frozenBytes = try Data(contentsOf: input.expectationURL)
        XCTAssertEqual(digest(frozenBytes), "9393c49128fcbadf1de614310193ee3c34bc70f2bb610c8a5fc2daed3be3e210")
        defer { XCTAssertEqual(try Data(contentsOf: input.expectationURL), frozenBytes) }
        let published = try loadBook(input.observedURL)
        try assertPublication(published, original: original, input: input)
        try assertTransportEvidence(input, original: original, published: published)
        let slots = try requestSlots(input)
        XCTAssertEqual(slots.count, 2)
        try reopenAndRestore(input, original: original, published: published, slots: slots)
    }

    private struct Configuration {
        let trialID: UUID
        let blockID: UUID
        let utf16Offset: Int
        let expectationURL: URL
        let observedURL: URL
        let artifactURL: URL
        let factsURL: URL
    }

    private func configuration(optIn: String) throws -> Configuration {
        let environment = ProcessInfo.processInfo.environment
        guard environment[optIn] == "1" else {
            throw XCTSkip("Requires explicit \(optIn)=1 and runner-supplied frozen/observed paths; live mode may incur capped charges.")
        }
        let trialID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(environment["SOURCE_CONTINUATION_TRIAL_ID"])))
        let blockID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(environment["SOURCE_CONTINUATION_BLOCK_ID"])))
        let offset = try XCTUnwrap(Int(try XCTUnwrap(environment["SOURCE_CONTINUATION_UTF16_OFFSET"])))
        XCTAssertGreaterThanOrEqual(offset, 0)
        let evidenceDirectory = try UITestArtifactDirectory.require(sourceFile: #filePath)
        let root = evidenceDirectory.deletingLastPathComponent().resolvingSymlinksInPath().path + "/"
        let simulator = try XCTUnwrap(environment["SIMULATOR_UDID"])
        XCTAssertNotNil(UUID(uuidString: simulator), "This opt-in acceptance route only runs on a simulator.")
        func requiredURL(_ key: String) throws -> URL {
            let path = try XCTUnwrap(environment[key])
            XCTAssertTrue(path.hasPrefix("/"), "\(key) must be an explicit absolute path.")
            return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        }
        let expectation = try requiredURL("SOURCE_CONTINUATION_EXPECTATION_BOOK_PATH")
        let observed = try requiredURL("SOURCE_CONTINUATION_OBSERVED_BOOK_PATH")
        let artifacts = try requiredURL("SOURCE_CONTINUATION_TRIAL_ARTIFACT_PATH")
        let facts = try requiredURL("SOURCE_CONTINUATION_FACTS_PATH")
        XCTAssertTrue(expectation.path.hasPrefix(root))
        XCTAssertNotEqual(expectation, observed, "Expectations must not point at the mutable app manuscript.")
        XCTAssertTrue(observed.path.contains("/CoreSimulator/Devices/\(simulator)/"))
        XCTAssertTrue(artifacts.path.contains("/CoreSimulator/Devices/\(simulator)/"))
        XCTAssertTrue(facts.path.contains("/CoreSimulator/Devices/\(simulator)/"))
        XCTAssertEqual(artifacts.lastPathComponent, trialID.uuidString)
        return Configuration(trialID: trialID, blockID: blockID, utf16Offset: offset,
                             expectationURL: expectation, observedURL: observed, artifactURL: artifacts, factsURL: facts)
    }

    private struct SavedBook {
        let object: [String: Any]
        let chapter: [String: Any]
        let active: [String: Any]
        let source: [String: Any]
        let id: String
        let chapterID: String
        let revisionID: String
        let title: String
    }

    private func loadBook(_ url: URL) throws -> SavedBook {
        let bytes = try Data(contentsOf: url)
        XCTAssertLessThanOrEqual(bytes.count, 2 * 1_024 * 1_024)
        let book = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let chapters = try XCTUnwrap(book["chapters"] as? [[String: Any]])
        XCTAssertEqual(chapters.count, 1)
        let chapter = try XCTUnwrap(chapters.first)
        let activeID = try string(chapter, "activeRevisionId")
        let revisions = try XCTUnwrap(chapter["revisions"] as? [[String: Any]])
        let matches = revisions.filter { $0["id"] as? String == activeID }
        XCTAssertEqual(matches.count, 1, "Never silently select a fallback revision.")
        let active = try XCTUnwrap(matches.first)
        XCTAssertEqual(active["isConsumed"] as? Bool, false)
        let requirement = try dictionary(chapter, "sourceGrounding")
        return SavedBook(object: book, chapter: chapter, active: active, source: try dictionary(requirement, "source"),
                         id: try string(book, "id"), chapterID: try string(chapter, "id"), revisionID: activeID,
                         title: try string(book, "title"))
    }

    private func validateFrozen(_ book: SavedBook, input: Configuration) throws {
        XCTAssertEqual(book.title, "Argentina — Source Preview Trial")
        XCTAssertNotNil(UUID(uuidString: book.id))
        XCTAssertNotNil(UUID(uuidString: book.chapterID))
        XCTAssertNotNil(UUID(uuidString: book.revisionID))
        XCTAssertEqual(input.observedURL.lastPathComponent, book.id + ".json")
        XCTAssertEqual(book.source["scope"] as? String, "wikipediaOpeningExcerpt")
        XCTAssertEqual(book.source["title"] as? String, "History of Argentina")
        XCTAssertEqual(book.source["revisionID"] as? Int, 1_371_307_195)
        let blocks = try orderedBlocks(book.active)
        let paragraphs = Array(blocks.dropFirst().dropLast(2))
        XCTAssertEqual(paragraphs.count, 5)
        XCTAssertEqual(try paragraphs.reduce(0) { $0 + (try string($1, "text")).dropLast(4).split(whereSeparator: \.isWhitespace).count }, 414)
        let selected = try XCTUnwrap(blocks.firstIndex { $0["id"] as? String == input.blockID.uuidString })
        XCTAssertGreaterThan(selected, 0)
        XCTAssertLessThan(selected, blocks.count - 2)
        let prose = String(try string(blocks[selected], "text").dropLast(4)) as NSString
        XCTAssertLessThan(input.utf16Offset, prose.length)
        guard input.utf16Offset < prose.length else { throw failure("Selected offset is outside the frozen prose.") }
        XCTAssertEqual(prose.rangeOfComposedCharacterSequence(at: input.utf16Offset).location, input.utf16Offset)
        let review = try dictionary(book.active, "sourceReview")
        XCTAssertEqual(review["bookID"] as? String, book.id)
        XCTAssertEqual(review["chapterID"] as? String, book.chapterID)
        XCTAssertEqual(review["contentHash"] as? String, try contentHash(blocks))
        XCTAssertEqual(book.source["textSHA256"] as? String, digest(Data(try string(book.source, "text").utf8)))
    }

    private func configuredApp(_ input: Configuration, book: SavedBook, selectWord: Bool, liveRoute: Bool) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: bundleID)
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-livingreader.reader.scrollMode", "scroll", "-livingreader.reader.fontSize", "18",
            "-livingreader.reader.fontFamily", "original", "-livingreader.reader.colorScheme", "system"]
        app.launchEnvironment = [:]
        if liveRoute {
            app.launchArguments += ["-sourceContinuationTrial", "-livingreader.ai.generationModel", "gpt-6-astra"]
            if selectWord { app.launchArguments.append("-sourceContinuationTrialSelection") }
            app.launchEnvironment = ["SOURCE_CONTINUATION_TRIAL_ID": input.trialID.uuidString,
                "SOURCE_CONTINUATION_BOOK_ID": book.id, "SOURCE_CONTINUATION_BASE_REVISION_ID": book.revisionID,
                "SOURCE_CONTINUATION_BLOCK_ID": input.blockID.uuidString,
                "SOURCE_CONTINUATION_UTF16_OFFSET": String(input.utf16Offset)]
        }
        XCTAssertTrue(Set(app.launchArguments).isDisjoint(with: ["-uitesting", "-useMockAI", "-phase4MockAsk",
            "-phase5AdaptationDemo", "-sourceContinuationOfflineFixture", "-sourcePreviewTrial", "-resetConsumedLedger"]))
        return app
    }

    private func openBook(_ book: SavedBook, in app: XCUIApplication) throws {
        XCTAssertTrue(app.buttons["library.create.button"].firstMatch.waitForExistence(timeout: 15))
        let row = app.buttons["library.book.\(book.id)"].firstMatch
        reveal(row, in: app)
        XCTAssertTrue(row.label.contains(book.title), "Open the exact persisted ID and title, not a seed book.")
        tap(row)
        XCTAssertTrue(app.textViews["reader.textkit.text"].firstMatch.waitForExistence(timeout: 15))
    }

    private func observeBook(_ input: Configuration, name: String) throws -> SavedBook {
        let book = try loadBook(input.observedURL)
        attachJSON(try json(book.object), name: name)
        return book
    }

    private func observedAttempt(_ input: Configuration, name: String) throws -> [String: Any] {
        let bytes = try Data(contentsOf: input.factsURL)
        XCTAssertLessThanOrEqual(bytes.count, 2 * 1_024 * 1_024)
        let facts = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        attachJSON(bytes, name: name)
        return try dictionary(facts, "sourceContinuation")
    }

    private func assertPublication(_ published: SavedBook, original: SavedBook, input: Configuration) throws {
        XCTAssertEqual(published.id, original.id)
        XCTAssertEqual(published.chapterID, original.chapterID)
        XCTAssertNotEqual(published.revisionID, original.revisionID)
        XCTAssertEqual(try json(published.source), try json(original.source))
        let history = try XCTUnwrap(published.chapter["revisions"] as? [[String: Any]])
        let old = try XCTUnwrap(history.first { $0["id"] as? String == original.revisionID })
        XCTAssertEqual(try json(old), try json(original.active), "Publication must retain the exact vetted original revision.")
        let blocks = try orderedBlocks(published.active)
        let oldBlocks = try orderedBlocks(original.active)
        let origin = try dictionary(published.active, "origin")
        XCTAssertEqual(origin["kind"] as? String, "regenerateFromWord")
        let cut = try dictionary(origin, "sourceWordCut")
        XCTAssertEqual(cut["baseRevisionID"] as? String, original.revisionID)
        XCTAssertEqual(cut["blockID"] as? String, input.blockID.uuidString)
        let selected = try XCTUnwrap(oldBlocks.firstIndex { $0["id"] as? String == input.blockID.uuidString })
        XCTAssertGreaterThanOrEqual(blocks.count, selected + 3)
        for index in 0..<selected { XCTAssertEqual(try json(blocks[index]), try json(oldBlocks[index])) }
        XCTAssertEqual(blocks[selected]["id"] as? String, input.blockID.uuidString)
        let start = try XCTUnwrap(cut["wordStartUTF16"] as? Int)
        let end = try XCTUnwrap(cut["endUTF16"] as? Int)
        let oldText = try string(oldBlocks[selected], "text")
        XCTAssertGreaterThanOrEqual(start, 0)
        XCTAssertLessThanOrEqual(start, input.utf16Offset)
        XCTAssertGreaterThan(end, input.utf16Offset)
        XCTAssertLessThanOrEqual(end, (oldText as NSString).length - 4)
        guard start >= 0, end > start, end <= (oldText as NSString).length - 4 else { throw failure("Invalid persisted word cut.") }
        let prefix = Data((oldText as NSString).substring(to: end).utf8)
        XCTAssertTrue(Data(try string(blocks[selected], "text").utf8).starts(with: prefix), "Frozen prefix comparison is byte-exact, including Unicode and spaces.")
        if end == (oldText as NSString).length - 4 {
            XCTAssertEqual(try json(blocks[selected]), try json(oldBlocks[selected]), "End-of-paragraph selection retains its original citation and identity.")
        }
        for (before, after) in zip(oldBlocks.suffix(2), blocks.suffix(2)) {
            XCTAssertEqual(before["id"] as? String, after["id"] as? String)
            XCTAssertEqual(before["kind"] as? String, after["kind"] as? String)
            XCTAssertEqual(Data(try string(before, "text").utf8), Data(try string(after, "text").utf8))
        }
        XCTAssertNotEqual(try contentHash(blocks), try contentHash(oldBlocks), "A published no-op is not live continuation proof.")
        let receipt = try dictionary(published.active, "sourceReview")
        let oldReceipt = try dictionary(original.active, "sourceReview")
        XCTAssertEqual(receipt["bookID"] as? String, original.id)
        XCTAssertEqual(receipt["chapterID"] as? String, original.chapterID)
        XCTAssertEqual(receipt["baseRevisionID"] as? String, original.revisionID)
        XCTAssertEqual(receipt["contentHash"] as? String, try contentHash(blocks))
        XCTAssertEqual(receipt["sourceHash"] as? String, oldReceipt["sourceHash"] as? String)
        XCTAssertEqual(receipt["model"] as? String, "gpt-6-astra")
        XCTAssertEqual(receipt["promptVersion"] as? String, "source-preview-1")
        XCTAssertNotNil(receipt["wordCutHash"] as? String)
        XCTAssertNotNil(receipt["reviewedAt"] as? String)
        let response = try dictionary(receipt, "response")
        let units = try XCTUnwrap(response["units"] as? [[String: Any]])
        XCTAssertEqual(units.count, blocks.count - 3, "Every complete assembled prose paragraph needs coverage.")
        XCTAssertEqual(try units.map { try XCTUnwrap($0["index"] as? Int) }.sorted(), Array(0..<units.count))
        let sourceBytes = Data(try string(original.source, "text").utf8)
        for unit in units {
            XCTAssertEqual(unit["assessment"] as? String, "supported")
            let quotes = try XCTUnwrap(unit["quotes"] as? [String])
            XCTAssertFalse(quotes.isEmpty)
            for quote in quotes {
                XCTAssertFalse(quote.isEmpty)
                XCTAssertNotNil(sourceBytes.range(of: Data(quote.utf8)), "Quotation must match exact retained source bytes, not normalization-equivalent text.")
            }
        }
    }

    /// Separate disk evidence from visible reader equality. No trial route is
    /// enabled during relaunch/restore, even when called by the live test.
    private func reopenAndRestore(_ input: Configuration, original: SavedBook, published: SavedBook,
                                  slots: [String: String]) throws {
        let app = configuredApp(input, book: original, selectWord: false, liveRoute: false)
        defer { app.terminate() }
        app.launch()
        try openBook(published, in: app)
        XCTAssertEqual(try readerBytes(app), Data(try expectedReader(published.active).utf8))
        let reopened = try observeBook(input, name: "continuation-trial-reopened-disk")
        XCTAssertEqual(try json(reopened.object), try json(published.object))
        XCTAssertEqual(try requestSlots(input), slots)
        screenshot("continuation-trial-reopened-reader", app: app)
        tap(app.buttons["reader.more.button"].firstMatch)
        tap(app.buttons["reader.versionHistory.button"].firstMatch)
        let restore = app.buttons.matching(identifier: "versionHistory.row.\(original.revisionID)")
            .matching(NSPredicate(format: "label == %@", "Restore this version")).firstMatch
        reveal(restore, in: app)
        tap(restore)
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let observed = try? self.loadBook(input.observedURL) else { return false }
            return observed.revisionID != published.revisionID
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 15), .completed)
        tap(app.buttons["versionHistory.done"].firstMatch)
        let restored = try observeBook(input, name: "continuation-trial-restored-disk")
        XCTAssertNotEqual(restored.revisionID, original.revisionID)
        XCTAssertNotEqual(restored.revisionID, published.revisionID)
        XCTAssertEqual(try contentHash(orderedBlocks(restored.active)), try contentHash(orderedBlocks(original.active)))
        XCTAssertEqual(try json(restored.source), try json(original.source))
        let review = try dictionary(restored.active, "sourceReview")
        var expectedReview = try dictionary(original.active, "sourceReview")
        expectedReview["baseRevisionID"] = published.revisionID
        XCTAssertEqual(try json(review), try json(expectedReview), "Exact restore reuses its original assessment, not a new review.")
        XCTAssertEqual(try dictionary(restored.active, "origin")["kind"] as? String, "restore")
        XCTAssertEqual(try readerBytes(app), Data(try expectedReader(original.active).utf8))
        XCTAssertEqual(try requestSlots(input), slots, "Display and restore must not forward or replace a consumed request.")
        screenshot("continuation-trial-restored-reader", app: app)
        app.terminate()
        app.launch()
        try openBook(restored, in: app)
        XCTAssertEqual(try readerBytes(app), Data(try expectedReader(original.active).utf8))
        XCTAssertEqual(try json(observeBook(input, name: "continuation-trial-restored-reopened-disk").object), try json(restored.object))
        XCTAssertEqual(try requestSlots(input), slots)
        screenshot("continuation-trial-restored-reopened-reader", app: app)
    }

    private func requestSlots(_ input: Configuration) throws -> [String: String] {
        let names = try FileManager.default.contentsOfDirectory(atPath: input.artifactURL.path)
        let requests = names.filter { $0.hasPrefix("request") && $0.hasSuffix(".json") }.sorted()
        XCTAssertTrue(Set(requests).isSubset(of: ["request-0.json", "request-1.json"]), "Unexpected request slot; never allocate a third call.")
        var result: [String: String] = [:]
        for name in requests { result[name] = digest(try Data(contentsOf: input.artifactURL.appendingPathComponent(name))) }
        return result
    }

    private func assertTransportEvidence(_ input: Configuration, original: SavedBook, published: SavedBook) throws {
        func artifact(_ name: String) throws -> Data {
            let bytes = try Data(contentsOf: input.artifactURL.appendingPathComponent(name))
            XCTAssertLessThanOrEqual(bytes.count, 256_000)
            return bytes
        }
        func requestPayload(_ bytes: Data) throws -> [String: Any] {
            let request = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            XCTAssertEqual(request["model"] as? String, "gpt-6-astra")
            let messages = try XCTUnwrap(request["messages"] as? [[String: Any]])
            XCTAssertEqual(messages.count, 2)
            let message = try XCTUnwrap(messages.last)
            XCTAssertEqual(message["role"] as? String, "user")
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try string(message, "content").utf8)) as? [String: Any])
        }
        func responsePayload(_ bytes: Data) throws -> [String: Any] {
            let response = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let choices = try XCTUnwrap(response["choices"] as? [[String: Any]])
            XCTAssertEqual(choices.count, 1)
            let choice = try XCTUnwrap(choices.first)
            XCTAssertEqual(choice["finish_reason"] as? String, "stop")
            let message = try dictionary(choice, "message")
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try string(message, "content").utf8)) as? [String: Any])
        }
        let writerBytes = try artifact("request-0.json")
        let writer = try requestPayload(writerBytes)
        let review = try requestPayload(artifact("request-1.json"))
        for index in 0...1 { XCTAssertEqual(try artifact("status-\(index).txt"), Data("200".utf8)) }
        let witness = try XCTUnwrap(JSONSerialization.jsonObject(with: artifact("success-0.json")) as? [String: Any])
        XCTAssertEqual(witness["requestSHA"] as? String, digest(writerBytes))
        XCTAssertEqual(witness["responseSHA"] as? String, digest(try artifact("response-0.json")))
        let source = Data(try string(original.source, "text").utf8)
        XCTAssertEqual(Data(try string(writer, "source1").utf8), source)
        XCTAssertEqual(Data(try string(review, "source1").utf8), source)
        let paragraphs = try orderedBlocks(published.active).dropFirst().dropLast(2).map { try string($0, "text") }
        XCTAssertEqual(try XCTUnwrap(review["paragraphs"] as? [String]).map { Data($0.utf8) }, paragraphs.map { Data($0.utf8) })
        let old = try orderedBlocks(original.active)
        let cut = try dictionary(dictionary(published.active, "origin"), "sourceWordCut")
        let selected = try XCTUnwrap(old.firstIndex { $0["id"] as? String == cut["blockID"] as? String })
        let end = try XCTUnwrap(cut["endUTF16"] as? Int)
        let selectedProse = String(try string(old[selected], "text").dropLast(4)) as NSString
        guard end >= 0, end <= selectedProse.length else { throw failure("Invalid retained writer boundary.") }
        var frozen = try old[1..<selected].map { String(try string($0, "text").dropLast(4)) }
        frozen.append(selectedProse.substring(to: end))
        var suffix = end < selectedProse.length ? [selectedProse.substring(from: end)] : []
        suffix += try old[(selected + 1)..<(old.count - 2)].map { String(try string($0, "text").dropLast(4)) }
        XCTAssertEqual(try XCTUnwrap(writer["frozenParagraphs"] as? [String]).map { Data($0.utf8) }, frozen.map { Data($0.utf8) })
        XCTAssertEqual(try XCTUnwrap(writer["oldSuffix"] as? [String]).map { Data($0.utf8) }, suffix.map { Data($0.utf8) })
        XCTAssertEqual(writer["joinsSelectedParagraph"] as? Bool, end < selectedProse.length)
        let output = try responsePayload(artifact("response-0.json"))
        let tail = try XCTUnwrap(output["paragraphs"] as? [[String: Any]])
        XCTAssertFalse(tail.isEmpty)
        for paragraph in tail { XCTAssertEqual(paragraph["citations"] as? [String], ["source1"]) }
        var assembled = frozen
        var tailTexts = try tail.map { try string($0, "text") }
        if end < selectedProse.length {
            guard !tailTexts.isEmpty, !assembled.isEmpty else { throw failure("Writer output cannot reconstruct the joined paragraph.") }
            assembled[assembled.count - 1] += tailTexts.removeFirst()
        }
        assembled += tailTexts
        XCTAssertEqual(assembled.map { Data(($0 + " [1]").utf8) }, paragraphs.map { Data($0.utf8) },
                       "Published prose must reconstruct exactly from this writer response and frozen text.")
        let actualReview = try responsePayload(artifact("response-1.json"))
        XCTAssertEqual(try json(try XCTUnwrap(actualReview["units"])),
                       try json(try XCTUnwrap(dictionary(dictionary(published.active, "sourceReview"), "response")["units"])),
                       "The saved assessment must be the separate review response for this candidate.")
        attachJSON(try json(["writerRequestSHA256": digest(writerBytes), "reviewRequestSHA256": digest(try artifact("request-1.json")),
                             "writerHTTPStatus": 200, "reviewHTTPStatus": 200, "assembledParagraphCount": paragraphs.count]),
                   name: "continuation-trial-local-transport-evidence")
    }

    private func orderedBlocks(_ revision: [String: Any]) throws -> [[String: Any]] {
        let raw = try XCTUnwrap(revision["blocks"] as? [[String: Any]])
        let indexed = try raw.map { (try XCTUnwrap($0["orderIndex"] as? Int), $0) }.sorted { $0.0 < $1.0 }
        XCTAssertEqual(indexed.map { $0.0 }, Array(0..<indexed.count))
        let blocks = indexed.map { $0.1 }
        XCTAssertGreaterThanOrEqual(blocks.count, 5)
        guard blocks.count >= 5 else { throw failure("Incomplete source-prose block structure.") }
        XCTAssertEqual(blocks.first?["kind"] as? String, "heading")
        XCTAssertEqual(blocks[blocks.count - 2]["kind"] as? String, "callout")
        XCTAssertEqual(blocks.last?["kind"] as? String, "paragraph")
        for block in blocks.dropFirst().dropLast(2) {
            XCTAssertEqual(block["kind"] as? String, "paragraph")
            XCTAssertTrue(try string(block, "text").hasSuffix(" [1]"))
        }
        return blocks
    }

    private struct ContentUnit: Encodable { let kind: String; let text: String; let order: Int }
    private func contentHash(_ blocks: [[String: Any]]) throws -> String {
        let units = try blocks.map { ContentUnit(kind: try string($0, "kind"), text: try string($0, "text"),
                                                order: try XCTUnwrap($0["orderIndex"] as? Int)) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return digest(try encoder.encode(units))
    }
    private func expectedReader(_ revision: [String: Any]) throws -> String {
        try orderedBlocks(revision).map { try string($0, "text") }.joined(separator: "\n\n") + "\n\n\n"
    }
    private func readerBytes(_ app: XCUIApplication) throws -> Data {
        let body = app.textViews["reader.textkit.text"].firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 12))
        return Data(try XCTUnwrap(body.value as? String).utf8)
    }
    private func dictionary(_ object: [String: Any], _ key: String) throws -> [String: Any] { try XCTUnwrap(object[key] as? [String: Any], "Missing \(key)") }
    private func string(_ object: [String: Any], _ key: String) throws -> String { try XCTUnwrap(object[key] as? String, "Missing \(key)") }
    private func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]) }
    private func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private func failure(_ message: String) -> NSError { NSError(domain: "SourceContinuationLiveAcceptance", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, towardTop: Bool = false) {
        for _ in 0..<8 where !element.isHittable { if towardTop { app.swipeDown() } else { app.swipeUp() } }
        XCTAssertTrue(element.isHittable)
    }
    private func sourceInstructionField(in app: XCUIApplication) -> XCUIElement {
        for _ in 0..<8 {
            for field in [app.textFields["wordRegen.freeText"].firstMatch, app.textViews["wordRegen.freeText"].firstMatch]
                where field.exists && field.isHittable { return field }
            app.swipeUp()
        }
        XCTFail("The source continuation instructions must be editable before Prepare.")
        return app.textFields["wordRegen.freeText"].firstMatch
    }
    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true AND enabled == true"), object: element)], timeout: 10), .completed)
        element.tap()
    }
    private func screenshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func attachJSON(_ bytes: Data, name: String) {
        let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.json")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
