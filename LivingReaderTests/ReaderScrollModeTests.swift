import XCTest
import CoreGraphics
@testable import LivingReader

@MainActor
final class ReaderScrollModeTests: XCTestCase {
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!

    override func setUpWithError() throws {
        defaultsSuiteName = "LivingReaderTests.ScrollMode.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDownWithError() throws {
        if let defaultsSuiteName {
            defaults?.removePersistentDomain(forName: defaultsSuiteName)
        }
    }

    func testDefaultScrollModeIsContinuousScroll() {
        let store = ReaderSettingsStore(defaults: defaults)
        XCTAssertEqual(store.scrollMode, .scroll)
    }

    func testScrollModePersistsAcrossReopen() {
        let store = ReaderSettingsStore(defaults: defaults)
        store.scrollMode = .pages

        let reopened = ReaderSettingsStore(defaults: defaults)
        XCTAssertEqual(reopened.scrollMode, .pages)
        XCTAssertEqual(reopened.scrollMode.displayName, "Pages")
    }

    func testUnknownPersistedScrollModeFallsBackToScroll() {
        defaults.set("flipbook", forKey: "livingreader.reader.scrollMode")
        let store = ReaderSettingsStore(defaults: defaults)
        XCTAssertEqual(store.scrollMode, .scroll)
    }

    func testVoiceOverForcesScrollEvenWhenPagesPreferred() {
        XCTAssertEqual(
            ReaderScrollMode.effective(.pages, voiceOverRunning: true),
            .scroll
        )
        XCTAssertEqual(
            ReaderScrollMode.effective(.pages, voiceOverRunning: false),
            .pages
        )
        XCTAssertEqual(
            ReaderScrollMode.effective(.scroll, voiceOverRunning: true),
            .scroll
        )
    }

    func testPageGeometrySnapAndCounts() {
        let ph = ReaderPageGeometry.pageHeight(viewportHeight: 700.4)
        XCTAssertEqual(ph, 700)

        let maxY = ReaderPageGeometry.maxOffsetY(contentHeight: 3500, viewportHeight: 700)
        XCTAssertEqual(maxY, 2800)

        XCTAssertEqual(ReaderPageGeometry.pageIndex(offsetY: 0, pageHeight: ph), 0)
        XCTAssertEqual(ReaderPageGeometry.pageIndex(offsetY: 699, pageHeight: ph), 1)
        XCTAssertEqual(ReaderPageGeometry.pageIndex(offsetY: 1400, pageHeight: ph), 2)

        XCTAssertEqual(
            ReaderPageGeometry.offsetY(forPage: 2, pageHeight: ph, maxOffsetY: maxY),
            1400
        )
        XCTAssertEqual(
            ReaderPageGeometry.offsetY(forPage: 99, pageHeight: ph, maxOffsetY: maxY),
            maxY
        )

        XCTAssertEqual(
            ReaderPageGeometry.pageCount(contentHeight: 3500, viewportHeight: 700),
            5
        )
        XCTAssertEqual(
            ReaderPageGeometry.displayPage(indexZeroBased: 0, count: 5),
            1
        )
        XCTAssertEqual(
            ReaderPageGeometry.displayPage(indexZeroBased: 4, count: 5),
            5
        )
    }

    func testEdgeTapZonesMatchCodexFractions() {
        let width: CGFloat = 390
        XCTAssertEqual(ReaderPageGeometry.edgeTapDirection(x: 10, width: width), -1)
        XCTAssertEqual(ReaderPageGeometry.edgeTapDirection(x: 50, width: width), -1)
        XCTAssertNil(ReaderPageGeometry.edgeTapDirection(x: 195, width: width))
        XCTAssertEqual(ReaderPageGeometry.edgeTapDirection(x: 340, width: width), 1)
        XCTAssertEqual(ReaderPageGeometry.edgeTapDirection(x: 380, width: width), 1)
    }

    func testPageChromeLabel() {
        let state = ReaderPageChromeState(index: 2, count: 12)
        XCTAssertEqual(state.displayLabel, "3 of 12")
    }

    func testModeSwitchPreservesOtherComfortSettings() {
        let store = ReaderSettingsStore(defaults: defaults)
        store.fontSize = 22
        store.colorScheme = .sepia
        store.scrollMode = .pages

        let reopened = ReaderSettingsStore(defaults: defaults)
        XCTAssertEqual(reopened.fontSize, 22)
        XCTAssertEqual(reopened.colorScheme, .sepia)
        XCTAssertEqual(reopened.scrollMode, .pages)
    }
}
