import XCTest
import UIKit
@testable import LivingReader

/// Wave 2 Apple Books reading surface: comfort settings, page palettes,
/// word-based time estimates, the page scrubber and search navigation.
@MainActor
final class Wave2BooksUXTests: XCTestCase {
    private var tempRoot: URL!
    private var versioning: ManuscriptVersioningService!
    private var checkpoints: FileReadingCheckpointStore!
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LR-Wave2Books-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        versioning = try ManuscriptVersioningService(rootDirectory: tempRoot)
        checkpoints = try FileReadingCheckpointStore(rootDirectory: tempRoot)
        defaultsSuiteName = "LivingReaderTests.Wave2Books.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDownWithError() throws {
        if let defaultsSuiteName {
            defaults?.removePersistentDomain(forName: defaultsSuiteName)
        }
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func makeReader(settings: ReaderSettingsStore) async throws -> (ReaderViewModel, Book) {
        let book = try await BundleFixtureLoader.seedIfNeeded(into: versioning)
        let model = ReaderViewModel(
            book: book,
            versioning: versioning,
            checkpoints: checkpoints,
            settings: settings,
            annotations: try FileAnnotationStore(rootDirectory: tempRoot),
            vocabulary: try FileVocabularyStore(rootDirectory: tempRoot),
            bookmarks: try FileBookmarkStore(rootDirectory: tempRoot),
            feedbackStore: try FileFeedbackStore(rootDirectory: tempRoot),
            preferenceStore: try FileReaderPreferenceStore(rootDirectory: tempRoot)
        )
        await model.open()
        XCTAssertTrue(model.isReady, "Reader should open offline")
        return (model, book)
    }

    // MARK: - Comfort settings

    func testEditedSearchInvalidatesOldPreviewUntilSubmitted() async throws {
        let (model, _) = try await makeReader(settings: ReaderSettingsStore(defaults: defaults))
        model.setSearchScope(.wholeBook)
        model.searchQuery = "Geography"
        XCTAssertFalse(model.hasSubmittedSearch)
        model.runSearch()
        XCTAssertFalse(model.searchHits.isEmpty)
        model.previewSearchHit(at: 0)
        XCTAssertNotNil(model.previewedSearchHit)
        model.searchQuery = "unsubmitted replacement"
        XCTAssertFalse(model.hasSubmittedSearch)
        XCTAssertTrue(model.searchHits.isEmpty)
        XCTAssertNil(model.previewedSearchHit)
        XCTAssertFalse(model.continueFromSearchPreview())
        model.runSearch()
        XCTAssertTrue(model.hasSubmittedSearch)
        XCTAssertTrue(model.searchHits.isEmpty)
        model.clearSearch()
        XCTAssertFalse(model.hasSubmittedSearch)
    }

    func testSavedPassageJumpKeepsReturnToPreviousReadingPlace() async throws {
        let (model, _) = try await makeReader(settings: ReaderSettingsStore(defaults: defaults))
        let document = try XCTUnwrap(model.document)
        let origin = try XCTUnwrap(document.location(atUtf16: 0))
        let target = try XCTUnwrap(document.anchors.last)
        model.jumpToBlock(blockId: target.block.id)
        XCTAssertEqual(model.returnLocation?.blockId, origin.blockId)
        model.returnToRememberedLocation()
        XCTAssertEqual(model.currentLocation?.blockId, origin.blockId)
        XCTAssertNil(model.returnLocation)
    }

    func testBooksComfortSettingsPersistAcrossReopen() {
        let store = ReaderSettingsStore(defaults: defaults)
        store.fontFamily = .serif
        store.colorScheme = .sepia
        store.lineSpacing = 1.40
        store.marginInset = 28
        store.pageDim = 0.35
        store.wordsPerMinute = 190

        let reopened = ReaderSettingsStore(defaults: defaults)
        XCTAssertEqual(reopened.fontFamily, .serif)
        XCTAssertEqual(reopened.colorScheme, .sepia)
        XCTAssertEqual(reopened.lineSpacing, 1.40, accuracy: 0.001)
        XCTAssertEqual(reopened.marginInset, 28, accuracy: 0.001)
        XCTAssertEqual(reopened.pageDim, 0.35, accuracy: 0.001)
        XCTAssertEqual(reopened.wordsPerMinute, 190)

        let typography = reopened.typography
        XCTAssertEqual(typography.fontFamily, .serif)
        XCTAssertEqual(typography.horizontalInset, 28, accuracy: 0.1)
        XCTAssertEqual(typography.lineHeightMultiple, 1.40, accuracy: 0.001)
        // Sepia keeps a light status bar / light SwiftUI scheme.
        XCTAssertEqual(reopened.swiftUIColorScheme, .light)
    }

    func testSearchScopeDefaultsReadSoFarAndPersistsExplicitWholeBook() {
        let store = ReaderSettingsStore(defaults: defaults)
        XCTAssertEqual(store.searchScope, .readSoFar)
        XCTAssertEqual(BookSearchScope.readSoFar.displayName, "Read so far")
        XCTAssertTrue(
            BookSearchScope.wholeBook.displayName.localizedCaseInsensitiveContains("spoiler"),
            "The whole-book choice must label its spoiler risk"
        )

        store.searchScope = .wholeBook
        let reopened = ReaderSettingsStore(defaults: defaults)
        XCTAssertEqual(reopened.searchScope, .wholeBook)
    }

    func testOutOfRangePersistedComfortValuesAreClamped() {
        defaults.set(9.9, forKey: "livingreader.reader.lineSpacing")
        defaults.set(-40.0, forKey: "livingreader.reader.marginInset")
        defaults.set(4.0, forKey: "livingreader.reader.pageDim")
        defaults.set(100_000, forKey: "livingreader.reader.wordsPerMinute")

        let store = ReaderSettingsStore(defaults: defaults)
        XCTAssertEqual(store.lineSpacing, Double(ReaderTypography.maxLineHeight), accuracy: 0.001)
        XCTAssertEqual(store.marginInset, Double(ReaderTypography.minInset), accuracy: 0.001)
        XCTAssertEqual(store.pageDim, 1.0, accuracy: 0.001)
        XCTAssertEqual(store.wordsPerMinute, ReaderSettingsStore.maxWordsPerMinute)
        // Dim never fully blacks out the page.
        XCTAssertLessThanOrEqual(store.dimOpacity, ReaderSettingsStore.maxDimOpacity)
    }

    // MARK: - Page palettes

    func testSepiaPaletteIsWarmPaperNotGreyLight() {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        ReaderPagePalette.sepia.background.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        XCTAssertGreaterThan(red, 0.9, "Sepia paper should be bright")
        XCTAssertGreaterThan(red, blue, "Sepia paper should be warm (more red than blue)")
        XCTAssertGreaterThan(green, blue)

        XCTAssertNotEqual(ReaderPagePalette.sepia.background, ReaderPagePalette.light.background)
        XCTAssertNotEqual(ReaderPagePalette.sepia.text, ReaderPagePalette.light.text)
    }

    func testEveryThemeResolvesToADistinctPagePalette() {
        let light = ReaderPagePalette.forScheme(.light)
        let sepia = ReaderPagePalette.forScheme(.sepia)
        let dark = ReaderPagePalette.forScheme(.dark)
        XCTAssertNotEqual(light.background, sepia.background)
        XCTAssertNotEqual(light.background, dark.background)
        XCTAssertNotEqual(sepia.background, dark.background)
        // `system` always resolves to one of the explicit palettes.
        let system = ReaderPagePalette.forScheme(.system)
        XCTAssertTrue(system == light || system == dark)
    }

    func testTypographyClampsFontSizeSpacingAndInset() {
        let tiny = ReaderTypography.make(
            bodyPointSize: 2,
            colorScheme: .sepia,
            fontFamily: .serif,
            lineHeightMultiple: 0.1,
            horizontalInset: -100
        )
        XCTAssertEqual(tiny.bodyPointSize, ReaderTypography.minBodySize)
        XCTAssertEqual(tiny.lineHeightMultiple, ReaderTypography.minLineHeight)
        XCTAssertEqual(tiny.horizontalInset, ReaderTypography.minInset)

        let huge = ReaderTypography.make(
            bodyPointSize: 900,
            colorScheme: .dark,
            lineHeightMultiple: 9,
            horizontalInset: 900
        )
        XCTAssertEqual(huge.bodyPointSize, ReaderTypography.maxBodySize)
        XCTAssertEqual(huge.lineHeightMultiple, ReaderTypography.maxLineHeight)
        XCTAssertEqual(huge.horizontalInset, ReaderTypography.maxInset)
    }

    // MARK: - Typeface

    func testSerifFamilyResolvesAwayFromTheSystemFont() {
        let system = ReaderFontFamily.original.uiFont(size: 19)
        let serif = ReaderFontFamily.serif.uiFont(size: 19)
        XCTAssertNotEqual(serif.fontName, system.fontName, "Serif should resolve to New York or Georgia")
        XCTAssertEqual(serif.pointSize, 19, accuracy: 0.01)
    }

    func testQuoteBlocksStayItalicInEveryFamily() throws {
        for family in ReaderFontFamily.allCases {
            let typography = ReaderTypography.make(bodyPointSize: 19, colorScheme: .sepia, fontFamily: family)
            let font = try XCTUnwrap(typography.attributes(for: .quote)[.font] as? UIFont)
            XCTAssertTrue(
                font.fontDescriptor.symbolicTraits.contains(.traitItalic),
                "\(family.rawValue) quote should be italic"
            )
        }
    }

    func testHeadingsAreLargerAndBolderThanBody() throws {
        let typography = ReaderTypography.make(bodyPointSize: 19, colorScheme: .light, fontFamily: .serif)
        let body = try XCTUnwrap(typography.bodyAttributes[.font] as? UIFont)
        let heading = try XCTUnwrap(typography.attributes(for: .heading)[.font] as? UIFont)
        XCTAssertGreaterThan(heading.pointSize, body.pointSize)
        XCTAssertTrue(heading.fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    // MARK: - Reading time

    func testReadingTimeUsesWordsNotPages() {
        let prefs = ReadingTimePreferences(wordsPerMinute: 230, secondsPerVisual: 30, toleranceFraction: 0.2)
        let blocks = [
            ContentBlock(id: UUID(), kind: .paragraph, text: Array(repeating: "word", count: 460).joined(separator: " "), orderIndex: 0),
            ContentBlock(id: UUID(), kind: .imagePlaceholder, text: "map", orderIndex: 1),
            ContentBlock(id: UUID(), kind: .imagePlaceholder, text: "portrait", orderIndex: 2)
        ]
        let estimate = ReadingTimeEstimator.estimate(blocks: blocks, preferences: prefs)
        XCTAssertEqual(estimate.proseWordCount, 460)
        XCTAssertEqual(estimate.visualBlockCount, 2)
        XCTAssertEqual(estimate.proseMinutes, 2.0, accuracy: 0.001)
        XCTAssertEqual(estimate.visualMinutes, 1.0, accuracy: 0.001)
        XCTAssertEqual(estimate.remainingMinutes, 3.0, accuracy: 0.001)
        XCTAssertEqual(estimate.compactLabel, "3 min")
        XCTAssertFalse(estimate.compactLabel.lowercased().contains("page"))
    }

    func testReadingTimeLabelsCoverSubMinuteAndMultiHour() {
        let prefs = ReadingTimePreferences.default
        let short = ReadingTimeEstimator.estimate(plainText: "only a few words here", preferences: prefs)
        XCTAssertEqual(short.compactLabel, "Under a minute")

        let long = ReadingTimeEstimate(
            proseWordCount: 230 * 85,
            visualBlockCount: 0,
            wordsPerMinute: 230,
            secondsPerVisual: 12
        )
        XCTAssertEqual(long.compactLabel, "1 h 25 min")
        XCTAssertTrue(long.accessibilityLabel.contains("hour"))
    }

    func testChangingReadingPaceChangesTheEstimateNotTheContent() {
        let base = ReadingTimeEstimate(
            proseWordCount: 1_000,
            visualBlockCount: 0,
            wordsPerMinute: 200,
            secondsPerVisual: 12
        )
        XCTAssertEqual(base.remainingMinutes, 5.0, accuracy: 0.001)

        var slower = ReadingTimePreferences.default
        slower.wordsPerMinute = 125
        let restamped = base.applying(slower)
        XCTAssertEqual(restamped.proseWordCount, 1_000, "Re-stamping must not change the content counts")
        XCTAssertEqual(restamped.remainingMinutes, 8.0, accuracy: 0.001)
    }

    func testDegenerateReadingPreferencesCannotDivideByZero() {
        let hostile = ReadingTimePreferences(wordsPerMinute: 0, secondsPerVisual: -50, toleranceFraction: 0)
        let estimate = ReadingTimeEstimator.estimate(plainText: "one two three", preferences: hostile)
        XCTAssertEqual(estimate.wordsPerMinute, 1)
        XCTAssertEqual(estimate.secondsPerVisual, 0)
        XCTAssertTrue(estimate.remainingMinutes.isFinite)
        XCTAssertGreaterThanOrEqual(hostile.safeToleranceFraction, 0.01)
    }

    func testTimeLeftInChapterShrinksAsTheReaderAdvances() async throws {
        let settings = ReaderSettingsStore(defaults: defaults)
        let (model, _) = try await makeReader(settings: settings)

        let chapterId = ArgentinaFixtureIDs.chapter1
        let whole = model.chapterEstimate(chapterId)
        XCTAssertGreaterThan(whole.proseWordCount, 0, "Fixture chapter should have prose")

        let document = try XCTUnwrap(model.document)
        let start = try XCTUnwrap(document.chapterStarts.first { $0.chapterId == chapterId })
        let end = try XCTUnwrap(document.chapterStarts.first { $0.chapterId == ArgentinaFixtureIDs.chapter2 })
        let threeQuarters = start.utf16Location + Int(Double(end.utf16Location - start.utf16Location) * 0.75)
        let location = try XCTUnwrap(document.location(atUtf16: threeQuarters, visibleProgress: 0.2))

        model.handleLocationChange(location)
        XCTAssertEqual(model.currentChapterId, chapterId)
        XCTAssertGreaterThan(model.chapterLocalProgress, 0.5)
        XCTAssertLessThan(
            model.timeLeftInChapter.proseWordCount,
            whole.proseWordCount,
            "Time left should shrink as the reader moves through the chapter"
        )
        XCTAssertTrue(model.timeLeftLabel.hasSuffix("left in chapter"))
    }

    // MARK: - Scrubber

    func testSeekToProgressMovesTheReaderWithoutConsumingChapters() async throws {
        let settings = ReaderSettingsStore(defaults: defaults)
        let (model, book) = try await makeReader(settings: settings)

        model.seekToProgress(1.0)
        XCTAssertEqual(model.progress, 1.0, accuracy: 0.001)
        XCTAssertNotNil(model.currentLocation)
        XCTAssertNotNil(model.jumpUtf16)

        // Scrubbing is exploratory: it must never lock the immutable past.
        let ledger = try await versioning.ledgerSnapshot().filter { $0.bookId == book.id }
        XCTAssertTrue(ledger.isEmpty, "Scrubbing must not write consumed-chapter entries")
        XCTAssertTrue(model.consumedChapterIds.isEmpty, "Scrubbing must not mark chapters consumed")
    }

    func testSeekToProgressOffersAWayBackToWhereReadingStopped() async throws {
        let settings = ReaderSettingsStore(defaults: defaults)
        let (model, _) = try await makeReader(settings: settings)

        let document = try XCTUnwrap(model.document)
        let origin = try XCTUnwrap(document.location(atUtf16: 5, visibleProgress: 0.01))
        model.handleLocationChange(origin)
        XCTAssertNil(model.returnLocation, "No jump yet, so nothing to return to")

        model.seekToProgress(0.9)
        XCTAssertGreaterThan(model.progress, 0.5)
        let remembered = try XCTUnwrap(model.returnLocation, "A long scrub should be undoable")
        XCTAssertEqual(remembered.blockId, origin.blockId)
        XCTAssertFalse(model.returnLocationLabel.isEmpty)

        model.returnToRememberedLocation()
        XCTAssertNil(model.returnLocation)
        XCTAssertEqual(model.currentLocation?.blockId, origin.blockId)
    }

    /// A scrub straight after opening still has somewhere to go back to: the start.
    func testScrubbingBeforeAnyScrollStillOffersAWayBack() async throws {
        let settings = ReaderSettingsStore(defaults: defaults)
        let (model, _) = try await makeReader(settings: settings)
        XCTAssertNil(model.currentLocation, "Fresh open with no checkpoint records no location yet")

        model.seekToProgress(0.8)
        let remembered = try XCTUnwrap(model.returnLocation)
        XCTAssertEqual(remembered.chapterId, ArgentinaFixtureIDs.chapter1)
    }

    func testTinyScrubsDoNotSpamTheReturnAffordance() async throws {
        let settings = ReaderSettingsStore(defaults: defaults)
        let (model, _) = try await makeReader(settings: settings)

        let document = try XCTUnwrap(model.document)
        let origin = try XCTUnwrap(document.location(atUtf16: 40, visibleProgress: 0.01))
        model.handleLocationChange(origin)

        // A nudge of a few characters is not a navigation event.
        model.seekToProgress(Double(60) / Double(max(1, document.length - 1)))
        XCTAssertNil(model.returnLocation)
    }

    func testScrubPreviewDoesNotSeekUntilEditingEnds() async throws {
        let settings = ReaderSettingsStore(defaults: defaults)
        let (model, book) = try await makeReader(settings: settings)
        let document = try XCTUnwrap(model.document)
        let tokenBefore = model.jumpToken

        model.scrubberEditingChanged(true)
        model.scrubberChanged(0.35)
        model.scrubberChanged(0.72)
        XCTAssertTrue(model.isScrubbing)
        XCTAssertEqual(model.progress, 0.72, accuracy: 0.001)
        XCTAssertEqual(model.jumpToken, tokenBefore, "Drag ticks must not commit a seek")
        XCTAssertNil(model.jumpUtf16)
        XCTAssertTrue(model.consumedChapterIds.isEmpty)

        model.scrubberEditingChanged(false)
        XCTAssertFalse(model.isScrubbing)
        XCTAssertNotEqual(model.jumpToken, tokenBefore, "Finger-up must commit one seek")
        let committed = try XCTUnwrap(model.jumpUtf16)
        XCTAssertEqual(committed, document.utf16Location(forProgress: 0.72))
        XCTAssertEqual(model.progress, document.progressFraction(atUtf16: committed), accuracy: 0.002)

        let ledger = try await versioning.ledgerSnapshot().filter { $0.bookId == book.id }
        XCTAssertTrue(ledger.isEmpty, "Committed scrub still must not consume chapters")
        XCTAssertTrue(model.consumedChapterIds.isEmpty)
    }

    func testScrubChangeBeforeEditingBeginDoesNotSeek() async throws {
        let settings = ReaderSettingsStore(defaults: defaults)
        let (model, _) = try await makeReader(settings: settings)
        let tokenBefore = model.jumpToken

        // Slider can emit a value tick before onEditingChanged(true).
        model.scrubberChanged(0.41)
        XCTAssertEqual(model.jumpToken, tokenBefore, "First tick must not seek immediately")
        model.scrubberEditingChanged(true)
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(model.jumpToken, tokenBefore, "Drag-begin must cancel the a11y commit")
        XCTAssertTrue(model.isScrubbing)

        model.scrubberEditingChanged(false)
        XCTAssertNotEqual(model.jumpToken, tokenBefore)
    }

    func testScrubAccessibilityAdjustCommitsOnce() async throws {
        let settings = ReaderSettingsStore(defaults: defaults)
        let (model, _) = try await makeReader(settings: settings)
        let tokenBefore = model.jumpToken

        model.scrubberChanged(0.4)
        XCTAssertEqual(model.jumpToken, tokenBefore)
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertNotEqual(model.jumpToken, tokenBefore, "VoiceOver/UITest adjust must commit once")
        XCTAssertEqual(model.progress, 0.4, accuracy: 0.01)
    }

    func testSeekThenSettledUtf16ProgressDoesNotSnapBack() async throws {
        let settings = ReaderSettingsStore(defaults: defaults)
        let (model, _) = try await makeReader(settings: settings)
        let document = try XCTUnwrap(model.document)

        model.seekToProgress(0.6)
        let committed = model.progress
        let utf16 = try XCTUnwrap(model.jumpUtf16)
        XCTAssertEqual(utf16, document.utf16Location(forProgress: 0.6))
        XCTAssertEqual(committed, document.progressFraction(atUtf16: utf16), accuracy: 0.002)

        // After the jump-ignore window, a settled callback in UTF-16 space must
        // keep the same fraction. The old viewport-progress path snapped the slider.
        try await Task.sleep(nanoseconds: 500_000_000)
        let settled = try XCTUnwrap(document.location(atUtf16: utf16))
        model.handleLocationChange(settled)
        XCTAssertEqual(model.progress, committed, accuracy: 0.002)
    }

    func testTextBottomInsetGrowsWithChromeSoTextIsNotOccluded() {
        let hidden = ReaderChromeMetrics.textBottomInset(chromeHeight: 0, homeIndicator: 34)
        XCTAssertEqual(hidden, 42, accuracy: 0.1)

        let progressOnly = ReaderChromeMetrics.textBottomInset(chromeHeight: 72, homeIndicator: 34)
        XCTAssertGreaterThan(progressOnly, 72 + 34)

        let withSearchBar = ReaderChromeMetrics.textBottomInset(chromeHeight: 160, homeIndicator: 34)
        XCTAssertGreaterThan(withSearchBar, progressOnly)
        XCTAssertEqual(withSearchBar, 160 + 34 + ReaderChromeMetrics.clearance, accuracy: 0.1)
    }

    // MARK: - Search chrome

    func testReadSoFarSearchExcludesFutureHitsUntilWholeBookIsChosen() async throws {
        let settings = ReaderSettingsStore(defaults: defaults)
        let (model, _) = try await makeReader(settings: settings)
        let document = try XCTUnwrap(model.document)
        let firstBlock = try XCTUnwrap(document.anchors.first)
        let firstBlockText = firstBlock.block.text as NSString
        let unreadWord = firstBlockText.range(of: "Nation")
        XCTAssertNotEqual(unreadWord.location, NSNotFound)
        let readingUtf16 = firstBlock.utf16Range.lowerBound + unreadWord.location
        let origin = try XCTUnwrap(document.location(atUtf16: readingUtf16))
        model.handleLocationChange(origin)

        XCTAssertEqual(settings.searchScope, .readSoFar)
        XCTAssertEqual(
            model.readSoFarSearchUpperBound,
            document.searchBoundary(atOrBeforeUtf16: readingUtf16)
        )
        XCTAssertLessThanOrEqual(model.readSoFarSearchUpperBound, readingUtf16)

        model.searchQuery = "Before"
        model.runSearch()
        XCTAssertFalse(model.searchHits.isEmpty, "Words behind the reading boundary should remain searchable")
        XCTAssertFalse(
            model.searchHits.contains { $0.snippet.localizedCaseInsensitiveContains("Nation") },
            "Read-so-far snippets must be clipped at the same spoiler boundary"
        )

        model.searchQuery = "Nation"
        model.runSearch()
        XCTAssertTrue(model.searchHits.isEmpty, "Unread text later in the same block must not leak")

        model.searchQuery = "Dirty War"
        model.runSearch()
        XCTAssertTrue(model.searchHits.isEmpty, "Unread late-book text must be absent by default")

        model.setSearchScope(.wholeBook)
        XCTAssertFalse(model.searchHits.isEmpty, "Explicit whole-book search should include future chapters")
        XCTAssertTrue(model.searchHits.allSatisfy { $0.range.location >= model.readSoFarSearchUpperBound })
    }

    func testSearchPreviewDoesNotCommitButContinueAndBackDo() async throws {
        let settings = ReaderSettingsStore(defaults: defaults)
        settings.searchScope = .wholeBook
        let (model, book) = try await makeReader(settings: settings)
        let document = try XCTUnwrap(model.document)
        let firstBlock = try XCTUnwrap(document.anchors.first)
        let origin = try XCTUnwrap(document.location(atUtf16: firstBlock.utf16Range.lowerBound))
        model.handleLocationChange(origin)
        await model.persist(origin)
        try await Task.sleep(nanoseconds: 320_000_000)

        let checkpointBefore = try XCTUnwrap(checkpoints.loadCheckpoint(bookId: book.id))
        let progressBefore = model.progress
        let jumpTokenBefore = model.jumpToken

        model.searchQuery = "Dirty War"
        model.runSearch()
        let previewIndex = try XCTUnwrap(
            model.searchHits.firstIndex { $0.range.location > firstBlock.utf16Range.upperBound + 400 }
        )
        let targetHit = model.searchHits[previewIndex]
        model.previewSearchHit(at: previewIndex)

        try await Task.sleep(nanoseconds: 320_000_000)
        XCTAssertEqual(model.previewedSearchHit, targetHit)
        XCTAssertNil(model.activeSearchHitIndex)
        XCTAssertEqual(model.currentLocation, origin, "A preview must not move the reading place")
        XCTAssertEqual(model.progress, progressBefore, accuracy: 0.0001)
        XCTAssertEqual(model.jumpToken, jumpTokenBefore)
        XCTAssertNil(model.returnLocation, "Back-to is created only by a committed jump")
        let checkpointAfterPreview = try XCTUnwrap(checkpoints.loadCheckpoint(bookId: book.id))
        XCTAssertEqual(checkpointAfterPreview, checkpointBefore)
        let ledgerAfterPreview = try await versioning.ledgerSnapshot().filter { $0.bookId == book.id }
        XCTAssertTrue(
            ledgerAfterPreview.isEmpty,
            "Preview must not consume or pin unread chapters"
        )

        XCTAssertTrue(model.continueFromSearchPreview())
        let committedLocation = try XCTUnwrap(document.location(atUtf16: targetHit.range.location))
        XCTAssertEqual(model.activeSearchHitIndex, previewIndex)
        XCTAssertEqual(model.currentLocation, committedLocation)
        XCTAssertNotEqual(model.jumpToken, jumpTokenBefore)
        XCTAssertEqual(model.returnLocation?.blockId, origin.blockId)
        XCTAssertEqual(model.returnLocation?.characterOffset, origin.characterOffset)

        try await Task.sleep(nanoseconds: 650_000_000)
        // Simulate a renderer settle callback arriving after the jump-ignore
        // window; search navigation still must not consume skipped chapters.
        model.handleLocationChange(committedLocation)
        let checkpointAfterContinue = try XCTUnwrap(checkpoints.loadCheckpoint(bookId: book.id))
        XCTAssertEqual(checkpointAfterContinue.blockId, committedLocation.blockId)
        XCTAssertEqual(checkpointAfterContinue.characterOffset, committedLocation.characterOffset)
        let ledgerAfterContinue = try await versioning.ledgerSnapshot().filter { $0.bookId == book.id }
        XCTAssertTrue(
            ledgerAfterContinue.isEmpty,
            "A search jump changes the checkpoint, not the immutable consumed ledger"
        )

        model.returnToRememberedLocation()
        XCTAssertNil(model.returnLocation)
        XCTAssertEqual(model.currentLocation, origin)
        try await Task.sleep(nanoseconds: 320_000_000)
        let checkpointAfterBack = try XCTUnwrap(checkpoints.loadCheckpoint(bookId: book.id))
        XCTAssertEqual(checkpointAfterBack.blockId, origin.blockId)
        XCTAssertEqual(checkpointAfterBack.characterOffset, origin.characterOffset)
        let ledgerAfterBack = try await versioning.ledgerSnapshot().filter { $0.bookId == book.id }
        XCTAssertTrue(ledgerAfterBack.isEmpty)
    }

    func testSearchSettleSuppressionIsOneShotAndNormalConsumptionResumes() async throws {
        let settings = ReaderSettingsStore(defaults: defaults)
        settings.searchScope = .wholeBook
        let (model, book) = try await makeReader(settings: settings)
        let document = try XCTUnwrap(model.document)

        model.searchQuery = "Dirty War"
        model.runSearch()
        let previewIndex = try XCTUnwrap(model.searchHits.indices.first)
        model.previewSearchHit(at: previewIndex)
        XCTAssertTrue(model.continueFromSearchPreview())
        let committed = try XCTUnwrap(
            document.location(atUtf16: model.searchHits[previewIndex].range.location)
        )

        try await Task.sleep(nanoseconds: 650_000_000)
        model.handleLocationChange(committed)
        let afterSyntheticSettle = try await versioning.ledgerSnapshot().filter { $0.bookId == book.id }
        XCTAssertTrue(afterSyntheticSettle.isEmpty, "Synthetic search settle must not consume skipped chapters")

        let chapter2Start = try XCTUnwrap(
            document.chapterStarts.first { $0.chapterId == ArgentinaFixtureIDs.chapter2 }
        )
        let ordinaryReading = try XCTUnwrap(document.location(atUtf16: chapter2Start.utf16Location))
        model.handleLocationChange(ordinaryReading)
        try await Task.sleep(nanoseconds: 320_000_000)

        let afterOrdinaryReading = try await versioning.ledgerSnapshot().filter { $0.bookId == book.id }
        XCTAssertTrue(
            afterOrdinaryReading.contains { $0.chapterId == ArgentinaFixtureIDs.chapter1 },
            "Retained search controls must not disable normal consumed-past updates"
        )
    }

    func testSearchAdvanceStepsAndWrapsAroundHits() async throws {
        let settings = ReaderSettingsStore(defaults: defaults)
        settings.searchScope = .wholeBook
        let (model, _) = try await makeReader(settings: settings)

        model.searchQuery = "Argentina"
        model.runSearch()
        try XCTSkipIf(model.searchHits.count < 2, "Fixture needs at least two matches for wrap-around")
        model.previewSearchHit(at: 0)
        XCTAssertTrue(model.continueFromSearchPreview())

        XCTAssertEqual(model.activeSearchHitIndex, 0)
        XCTAssertEqual(model.searchStatusLabel, "1 of \(model.searchHits.count)")

        model.advanceSearch(by: 1)
        XCTAssertEqual(model.activeSearchHitIndex, 1)

        model.advanceSearch(by: -1)
        XCTAssertEqual(model.activeSearchHitIndex, 0)

        // Wrap backwards from the first hit to the last.
        model.advanceSearch(by: -1)
        XCTAssertEqual(model.activeSearchHitIndex, model.searchHits.count - 1)

        // …and forwards from the last back to the first.
        model.advanceSearch(by: 1)
        XCTAssertEqual(model.activeSearchHitIndex, 0)
    }

    func testAdvanceSearchKeepsProgressInSyncWithHit() async throws {
        let settings = ReaderSettingsStore(defaults: defaults)
        settings.searchScope = .wholeBook
        let (model, _) = try await makeReader(settings: settings)
        let document = try XCTUnwrap(model.document)

        model.searchQuery = "Argentina"
        model.runSearch()
        try XCTSkipIf(model.searchHits.count < 2, "Fixture needs at least two matches")
        model.previewSearchHit(at: 0)
        XCTAssertTrue(model.continueFromSearchPreview())

        func assertProgressMatchesActiveHit() throws {
            let index = try XCTUnwrap(model.activeSearchHitIndex)
            let hit = model.searchHits[index]
            let location = try XCTUnwrap(model.currentLocation)
            let expected = document.progressFraction(atUtf16: hit.range.location)
            XCTAssertEqual(model.progress, expected, accuracy: 0.0001)
            XCTAssertEqual(location.progress, expected, accuracy: 0.0001)
            XCTAssertEqual(location.chapterId, hit.chapterId)
            XCTAssertEqual(location.blockId, hit.blockId)
        }

        try assertProgressMatchesActiveHit()
        let firstProgress = model.progress

        model.advanceSearch(by: 1)
        try assertProgressMatchesActiveHit()
        let secondProgress = model.progress
        XCTAssertNotEqual(secondProgress, firstProgress, "Next hit should move book progress")

        model.advanceSearch(by: -1)
        try assertProgressMatchesActiveHit()
        XCTAssertEqual(model.progress, firstProgress, accuracy: 0.0001)

        model.advanceSearch(by: -1)
        try assertProgressMatchesActiveHit()
        XCTAssertEqual(model.activeSearchHitIndex, model.searchHits.count - 1)
    }

    func testClearSearchRemovesHitsAndStatus() async throws {
        let settings = ReaderSettingsStore(defaults: defaults)
        settings.searchScope = .wholeBook
        let (model, _) = try await makeReader(settings: settings)

        model.searchQuery = ArgentinaFixtureIDs.searchablePhrase
        model.runSearch()
        XCTAssertFalse(model.searchHits.isEmpty)
        model.previewSearchHit(at: 0)

        model.clearSearch()
        XCTAssertTrue(model.searchHits.isEmpty)
        XCTAssertNil(model.previewSearchHitIndex)
        XCTAssertNil(model.activeSearchHitIndex)
        XCTAssertNil(model.activeSearchRange)
        XCTAssertEqual(model.searchStatusLabel, "No matches")
    }

    func testAdvanceSearchWithNoHitsIsANoOp() async throws {
        let settings = ReaderSettingsStore(defaults: defaults)
        let (model, _) = try await makeReader(settings: settings)

        model.advanceSearch(by: 1)
        XCTAssertNil(model.activeSearchHitIndex)
        XCTAssertTrue(model.searchHits.isEmpty)
    }

    // MARK: - Offline guarantee

    func testBooksChromeNeverPullsAIOnOpen() async throws {
        let ai = MockAIService()
        let book = try await BundleFixtureLoader.seedIfNeeded(into: versioning)
        let settings = ReaderSettingsStore(defaults: defaults)
        settings.colorScheme = .sepia
        settings.fontFamily = .serif

        let model = ReaderViewModel(
            book: book,
            versioning: versioning,
            checkpoints: checkpoints,
            settings: settings,
            annotations: try FileAnnotationStore(rootDirectory: tempRoot),
            vocabulary: try FileVocabularyStore(rootDirectory: tempRoot),
            bookmarks: try FileBookmarkStore(rootDirectory: tempRoot),
            feedbackStore: try FileFeedbackStore(rootDirectory: tempRoot),
            preferenceStore: try FileReaderPreferenceStore(rootDirectory: tempRoot),
            ai: ai
        )
        await model.open()

        _ = model.timeLeftLabel
        model.seekToProgress(0.4)
        model.setSearchScope(.wholeBook)
        model.searchQuery = "Argentina"
        model.runSearch()
        model.previewSearchHit(at: 0)
        _ = model.continueFromSearchPreview()
        model.advanceSearch(by: 1)

        XCTAssertEqual(ai.adaptCallCount, 0, "Reading chrome must never call AI")
        XCTAssertEqual(ai.askCallCount, 0)
    }
}
