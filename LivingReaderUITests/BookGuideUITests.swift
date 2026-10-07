import XCTest
import UIKit

final class BookGuideUITests: XCTestCase {
    private let argentinaTitle = "A Little History of Argentina"
    private let firstChapter = "00000000-0000-4000-8000-0000000000C1"
    private let secondChapter = "00000000-0000-4000-8000-0000000000C2"
    private let sourceLimits = [
        ("scope", "This guide shows saved book information, not a bibliography or an independent fact-check."),
        ("notes", "Editorial notes describe the edition’s stated approach; they do not independently verify its claims."),
        ("revisions", "Overview, timeline and editorial notes are saved separately from chapter revisions and may not reflect later adaptations."),
        ("sources.empty", "No retained source snapshots are attached to this book. Per-passage citations are not available in this Guide.")
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testArgentinaSourceLimitsRemainReadableAtAccessibilityXXXL() {
        XCUIDevice.shared.orientation = .portrait
        let app = launchReader(bookID: "00000000-0000-4000-8000-000000000001",
                               title: argentinaTitle, accessibilityXXXL: true)
        let chapterBefore = currentChapter(in: app).label
        let progress = app.staticTexts["reader.progress.label"]
        XCTAssertTrue(progress.waitForExistence(timeout: 6))
        let progressBefore = progress.label

        openContents(app)
        openGuide(app)
        assertSourceLimitsCollapsed(in: app)
        tapSourceLimitsAtLargeType(in: app)
        for (suffix, copy) in sourceLimits {
            let disclosure = text(in: app, id: "reader.guide.sourceLimits.\(suffix)", containing: copy)
            revealWholeDisclosure(disclosure, in: app)
            XCTAssertEqual(disclosure.label, copy, "The complete source limitation must stay available")
            let font = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith:
                UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge))
            let fullTextHeight = (copy as NSString).boundingRect(
                with: CGSize(width: disclosure.frame.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font], context: nil).height
            XCTAssertGreaterThanOrEqual(disclosure.frame.height, ceil(fullTextHeight) - 2,
                "A full accessibility label must not hide a visually truncated paragraph")
            XCTAssertTrue(app.buttons["reader.guide.done"].isHittable,
                          "Done must remain reachable while reading long disclosures")
            attachScreenshot("guide-xxxl-\(suffix)", app: app)
        }

        tapSourceLimitsAtLargeType(in: app, scrollingBack: true)
        assertSourceLimitsCollapsed(in: app)
        closeGuide(app)
        XCTAssertEqual(currentChapter(in: app).label, chapterBefore)
        XCTAssertEqual(progress.label, progressBefore, "Inspecting source limits must not move the reader")
    }

    func testArgentinaGuideShowsStoredMetadataAndDisclosuresWithoutMovingReader() {
        let app = launchReader(bookID: "00000000-0000-4000-8000-000000000001", title: argentinaTitle)
        let chapterBefore = currentChapter(in: app).label
        let progress = app.staticTexts["reader.progress.label"]
        XCTAssertTrue(progress.waitForExistence(timeout: 6))
        let progressBefore = progress.label

        openContents(app)
        openGuide(app)
        XCTAssertTrue(text(in: app, id: "reader.guide.title", containing: argentinaTitle).waitForExistence(timeout: 6))
        XCTAssertTrue(text(in: app, id: "reader.guide.author", containing: "Living Reader").exists)
        XCTAssertTrue(text(in: app, id: "reader.guide.edition", containing: "Phase 6 living manuscript").exists)
        XCTAssertFalse(app.staticTexts["reader.guide.synopsis"].exists, "Overview begins collapsed")
        XCTAssertFalse(app.staticTexts["reader.guide.note.0"].exists, "Editorial notes begin collapsed")
        assertSourceLimitsCollapsed(in: app)
        XCTAssertFalse(app.staticTexts["This timeline covers the whole book, including unread chapters."].exists,
                       "Whole-book events must not be disclosed until Timeline is opened")
        attachScreenshot("guide-argentina-collapsed", app: app)

        tapControl(in: app, id: "reader.guide.overview", label: "Overview · whole book")
        XCTAssertTrue(text(in: app, id: "reader.guide.synopsis", containing: "chronological narrative history")
            .waitForExistence(timeout: 5))
        tapControl(in: app, id: "reader.guide.overview", label: "Overview · whole book")

        tapControl(in: app, id: "reader.guide.notes", label: "Editorial notes")
        let note = text(in: app, id: "reader.guide.note.0",
                        containing: "Narrative synthesis for personal reading; not a peer-reviewed monograph.")
        reveal(note, in: app)
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        attachScreenshot("guide-argentina-editorial-notes", app: app)
        tapControl(in: app, id: "reader.guide.notes", label: "Editorial notes")

        inspectSourceLimits(in: app, screenshotName: "guide-argentina-sources-and-limits")

        tapControl(in: app, id: "reader.guide.timeline", label: "Timeline · whole book")
        let warning = text(in: app, id: "reader.guide.timeline.warning",
                           containing: "This timeline covers the whole book, including unread chapters.")
        reveal(warning, in: app)
        XCTAssertTrue(warning.waitForExistence(timeout: 5))
        let event = text(in: app, id: "reader.guide.event.00000000-0000-4000-8000-000000007000",
                         containing: "Indigenous worlds")
        reveal(event, in: app)
        XCTAssertTrue(event.exists, "Guide must show this book's first stored timeline event")
        attachScreenshot("guide-argentina-timeline", app: app)

        closeGuide(app)
        XCTAssertEqual(currentChapter(in: app).label, chapterBefore)
        XCTAssertEqual(progress.label, progressBefore, "Reading progress must survive a read-only Guide visit")
    }

    func testGuideBackRoundTripKeepsScrollProgressAndContentsStillJumpsChapters() {
        let app = launchReader(bookID: "00000000-0000-4000-8000-000000000001", title: argentinaTitle)
        openContents(app)
        jumpToChapter(firstChapter, in: app)
        let progress = app.staticTexts["reader.progress.label"]
        XCTAssertTrue(progress.waitForExistence(timeout: 6))
        let startProgress = progress.label
        let reader = app.textViews["reader.textkit.text"]
        for _ in 0..<3 where progress.label == startProgress {
            reader.swipeUp()
        }
        wait(for: progress, predicate: NSPredicate(format: "label != %@", startProgress),
             message: "Read beyond the starting position before visiting Guide")
        let progressBefore = progress.label
        let chapterBefore = currentChapter(in: app).label

        openContents(app)
        openGuide(app)
        let back = app.navigationBars.buttons["Contents"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Guide uses the existing Contents navigation stack")
        back.tap()
        XCTAssertTrue(app.navigationBars["Contents"].waitForExistence(timeout: 5))
        tapNavigationDone(in: app, id: "reader.toc.done")
        waitForReader(app)
        XCTAssertEqual(progress.label, progressBefore, "Back through Contents must keep the same displayed reading progress")
        XCTAssertEqual(currentChapter(in: app).label, chapterBefore)
        attachScreenshot("guide-scroll-round-trip", app: app)

        openContents(app)
        jumpToChapter(secondChapter, in: app)
        let chapterAfter = currentChapter(in: app)
        wait(for: chapterAfter, predicate: NSPredicate(format: "label != %@", chapterBefore),
             message: "Contents must still navigate to another chapter after visiting Guide")
        XCTAssertTrue(progress.waitForExistence(timeout: 5), "Chapter navigation must retain Scroll progress")
    }

    func testQuranGuideUsesItsOwnTitleAuthorAndEdition() throws {
        try OptionalQuranUIFixture.requirePresence()
        let app = launchReader(bookID: "00000000-0000-4000-8000-000000000002", title: "The Quran")
        let chapterBefore = currentChapter(in: app).label
        let progress = app.staticTexts["reader.progress.label"]
        XCTAssertTrue(progress.waitForExistence(timeout: 6))
        let progressBefore = progress.label
        openContents(app)
        openGuide(app)

        XCTAssertTrue(text(in: app, id: "reader.guide.title", containing: "The Quran").waitForExistence(timeout: 6))
        XCTAssertTrue(text(in: app, id: "reader.guide.author", containing: "Mohammed Marmaduke Pickthall").exists)
        XCTAssertTrue(text(in: app, id: "reader.guide.edition",
                           containing: "Pickthall 1930 public-domain English translation").exists)
        XCTAssertFalse(app.staticTexts[argentinaTitle].exists, "Guide must not load an Argentina-only companion")
        XCTAssertFalse(app.staticTexts["Indigenous worlds"].exists)
        assertSourceLimitsCollapsed(in: app)
        tapControl(in: app, id: "reader.guide.overview", label: "Overview · whole book")
        XCTAssertTrue(text(in: app, id: "reader.guide.synopsis", containing: "English translation")
            .waitForExistence(timeout: 5))
        attachScreenshot("guide-quran-overview", app: app)
        tapControl(in: app, id: "reader.guide.overview", label: "Overview · whole book")
        inspectSourceLimits(in: app, screenshotName: "guide-quran-sources-and-limits")
        closeGuide(app)
        XCTAssertEqual(currentChapter(in: app).label, chapterBefore)
        XCTAssertEqual(progress.label, progressBefore, "Reading progress must survive inspecting the edition's limits")
    }

    private func assertSourceLimitsCollapsed(in app: XCUIApplication) {
        for (suffix, copy) in sourceLimits {
            XCTAssertFalse(text(in: app, id: "reader.guide.sourceLimits.\(suffix)", containing: copy).exists,
                           "Sources and limits must stay hidden until its disclosure is opened")
        }
    }

    private func inspectSourceLimits(in app: XCUIApplication, screenshotName: String) {
        tapControl(in: app, id: "reader.guide.sourceLimits", label: "Sources and limits")
        for (suffix, copy) in sourceLimits {
            let disclosure = text(in: app, id: "reader.guide.sourceLimits.\(suffix)", containing: copy)
            reveal(disclosure, in: app)
            XCTAssertTrue(disclosure.waitForExistence(timeout: 5), "Missing source limitation: \(suffix)")
        }
        attachScreenshot(screenshotName, app: app)
        tapControl(in: app, id: "reader.guide.sourceLimits", label: "Sources and limits")
        assertSourceLimitsCollapsed(in: app)
    }

    private func launchReader(bookID: String, title: String, mode: String = "scroll",
                              accessibilityXXXL: Bool = false) -> XCUIApplication {
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
            "-livingreader.reader.scrollMode", mode,
            "-livingreader.reader.searchScope", "readSoFar"
        ]
        if accessibilityXXXL {
            app.launchArguments += [
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
            ]
        }
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["library.screen"].firstMatch.waitForExistence(timeout: 12))
        let identified = app.descendants(matching: .any)["library.book.\(bookID)"].firstMatch
        let book = identified.waitForExistence(timeout: 8) ? identified : app.staticTexts[title].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 5))
        book.tap()
        waitForReader(app)
        return app
    }

    private func waitForReader(_ app: XCUIApplication) {
        wait(for: app.navigationBars["Contents"], predicate: NSPredicate(format: "exists == false"),
             message: "Contents must dismiss before inspecting the underlying reader")
        wait(for: app.navigationBars["Book Guide"], predicate: NSPredicate(format: "exists == false"),
             message: "Book Guide must dismiss before inspecting the underlying reader")
        XCTAssertTrue(app.descendants(matching: .any)["reader.screen"].firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["reader.textkit.text"].firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(currentChapter(in: app).waitForExistence(timeout: 6))
    }

    private func currentChapter(in app: XCUIApplication) -> XCUIElement {
        app.staticTexts["reader.currentChapter"].firstMatch
    }

    private func openContents(_ app: XCUIApplication) {
        tapControl(in: app, id: "reader.toc.button", label: "Table of contents")
        XCTAssertTrue(app.navigationBars["Contents"].waitForExistence(timeout: 6))
    }

    private func openGuide(_ app: XCUIApplication) {
        tapControl(in: app, id: "reader.toc.guide", label: "Book Guide")
        let identified = app.descendants(matching: .any)["reader.guide.screen"].firstMatch
        XCTAssertTrue(identified.waitForExistence(timeout: 3)
                      || app.navigationBars["Book Guide"].waitForExistence(timeout: 3))
    }

    private func closeGuide(_ app: XCUIApplication) {
        tapNavigationDone(in: app, id: "reader.guide.done")
        waitForReader(app)
        XCTAssertFalse(app.navigationBars["Book Guide"].exists)
    }

    private func tapNavigationDone(in app: XCUIApplication, id: String) {
        let identified = app.buttons[id].firstMatch
        let done = identified.exists ? identified : app.navigationBars.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
    }

    private func jumpToChapter(_ id: String, in app: XCUIApplication) {
        let chapter = app.buttons["reader.toc.chapter.\(id)"].firstMatch
        reveal(chapter, in: app)
        XCTAssertTrue(chapter.waitForExistence(timeout: 5))
        let expectedTitle = chapter.label.replacingOccurrences(of: ", current chapter", with: "")
        chapter.tap()
        waitForReader(app)
        wait(for: currentChapter(in: app), predicate: NSPredicate(format: "label CONTAINS %@", expectedTitle),
             message: "Wait for the selected chapter before inspecting its page")
    }

    private func text(in app: XCUIApplication, id: String, containing value: String) -> XCUIElement {
        let identified = app.descendants(matching: .any)[id].firstMatch
        let matchingText = NSPredicate(format: "label CONTAINS %@", value)
        if identified.exists {
            if identified.label.contains(value) { return identified }
            return identified.descendants(matching: .staticText).matching(matchingText).firstMatch
        }
        return app.staticTexts.matching(matchingText).firstMatch
    }

    private func tapControl(in app: XCUIApplication, id: String, label: String) {
        let button = app.buttons[id].firstMatch
        let identified = app.descendants(matching: .any)[id].firstMatch
        let labelled = app.buttons[label].firstMatch
        // SwiftUI toolbar wrappers can inherit the button's identifier. Tap the
        // actual button, not its non-actionable container.
        let control = button.exists ? button : (labelled.exists ? labelled
            : (identified.exists ? identified : app.staticTexts[label].firstMatch))
        reveal(control, in: app)
        wait(for: control, predicate: NSPredicate(format: "exists == true AND hittable == true AND enabled == true"),
             message: "Control must be ready to tap: \(label)")
        control.tap()
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<3 {
            if element.exists && element.isHittable { return }
            let guide = app.collectionViews["reader.guide.screen"].firstMatch
            let visibleLists = app.collectionViews.allElementsBoundByIndex
                + app.tables.allElementsBoundByIndex + app.scrollViews.allElementsBoundByIndex
            guard let list = guide.exists && guide.isHittable ? guide
                : visibleLists.first(where: { $0.isHittable }) else { return }
            if element.exists && element.frame.minY < list.frame.minY {
                list.swipeDown()
            } else {
                list.swipeUp()
            }
        }
    }

    private func tapSourceLimitsAtLargeType(in app: XCUIApplication, scrollingBack: Bool = false) {
        let button = app.buttons["reader.guide.sourceLimits"].firstMatch
        let list = app.collectionViews["reader.guide.screen"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        // List rows outside the viewport may not exist yet. Keep querying the
        // real disclosure button as scrolling materializes it.
        for _ in 0..<12 {
            if button.exists && button.isHittable && button.isEnabled {
                revealWholeDisclosure(button, in: app)
                button.tap()
                return
            }
            let towardTop = button.exists
                ? button.frame.minY < app.navigationBars["Book Guide"].frame.maxY : scrollingBack
            // A full swipe also expands the initial half-height sheet. Short
            // drags can spring back to that detent without scrolling its list.
            if towardTop { list.swipeDown() } else { list.swipeUp() }
        }
        attachScreenshot("guide-xxxl-source-control-unreachable", app: app)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.lifetime = .keepAlways
        add(tree)
        XCTFail("Sources and limits must remain reachable at Accessibility XXXL")
    }

    private func revealWholeDisclosure(_ element: XCUIElement, in app: XCUIApplication) {
        let list = app.collectionViews["reader.guide.screen"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        let navigation = app.navigationBars["Book Guide"]
        // Hittable alone also accepts a partially clipped paragraph. Bring the
        // entire disclosure below the fixed navigation bar and above the fold.
        func readableBounds() -> CGRect {
            let bounds = list.frame.intersection(app.windows.firstMatch.frame)
            let top = max(bounds.minY, navigation.frame.maxY) + 8
            return CGRect(x: bounds.minX, y: top, width: bounds.width,
                          height: max(0, bounds.maxY - top - 16))
        }
        for _ in 0..<16 {
            let visible = readableBounds()
            if element.exists && element.isHittable && visible.contains(element.frame) { break }
            guard element.exists else { list.swipeUp(); continue }
            // Center the paragraph with a measured drag. Fixed-distance swipes
            // can oscillate past both edges of a nearly screen-height paragraph.
            let distance = element.frame.midY - visible.midY
            let limit = visible.height * 0.35
            let delta = max(-limit, min(limit, distance))
            let startY = visible.minY + visible.height * (delta > 0 ? 0.75 : 0.25)
            let start = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: visible.midX, dy: startY))
            let end = start.withOffset(CGVector(dx: 0, dy: -delta))
            // Holding at the endpoint avoids momentum flinging the paragraph
            // beyond the measured destination when the finger lifts.
            start.press(forDuration: 0.05, thenDragTo: end,
                        withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        XCTAssertTrue(element.exists && element.isHittable)
        XCTAssertTrue(readableBounds().contains(element.frame),
                      "Each complete limitation must fit inside the visible Guide after scrolling: \(element.frame)")
    }

    private func wait(for element: XCUIElement, predicate: NSPredicate, message: String) {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: 6)
        if result != .completed {
            attachScreenshot("guide-wait-failed", app: XCUIApplication())
        }
        XCTAssertEqual(result, .completed, message)
    }

    private func attachScreenshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
