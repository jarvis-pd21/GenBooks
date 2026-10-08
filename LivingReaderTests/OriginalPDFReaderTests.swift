import XCTest
import PDFKit
import UIKit
@testable import LivingReader

/// Only generated fixtures are used; no private or published book content is bundled.
@MainActor
final class OriginalPDFReaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("OriginalPDFTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testLoadingKeepsEveryPageIncludingImageOnlyPageAndPreservesSourceBytes() throws {
        let url = try fixture()
        let original = try Data(contentsOf: url)
        var callbacks = 0
        let model = OriginalPDFReaderModel(url: url, initialPageIndex: 2, initialPoint: nil) { _, _ in callbacks += 1; return true }
        model.load()
        let document = try XCTUnwrap(model.document)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.pageCount, 3)
        XCTAssertEqual(model.pageIndex, 2)
        XCTAssertEqual(document.page(at: 1)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", "")
        XCTAssertNotNil(model.thumbnail(at: 1), "Image-only pages must be visible without extracted text")
        XCTAssertEqual(document.page(at: 0)?.annotations.filter { $0.action is PDFActionGoTo }.count, 1,
            "Internal source links must survive loading")
        model.load()
        XCTAssertTrue(model.document === document, "An unrelated update must not recreate the document and reset its position")
        XCTAssertEqual(callbacks, 0, "Loading must not overwrite a stored location before restoration")
        XCTAssertEqual(try Data(contentsOf: url), original, "Reading and thumbnail rendering must not rewrite the source PDF")
    }

    func testActualPDFOutlineRetainsNestedDestinationsAndFilePageIndices() throws {
        let model = OriginalPDFReaderModel(url: try fixture(), initialPageIndex: 0, initialPoint: nil) { _, _ in true }
        model.load()
        XCTAssertEqual(model.outline.map(\.title), ["Tables & diagrams", "Practice", "A footnote"])
        XCTAssertEqual(model.outline.map(\.depth), [0, 0, 1])
        XCTAssertEqual(model.outline.map(\.pageIndex), [0, 2, 2])
        XCTAssertTrue(model.outline.allSatisfy { $0.destination != nil })
    }

    func testVerifiedChapterMapSuppliesContentsOnlyWhenPDFHasNoOutline() throws {
        // PDFKit can retain a serialized outline when outlineRoot is later set to nil.
        // Construct this source without one so the fallback is genuinely exercised.
        let url = try fixture(includeOutline: false)
        XCTAssertNil(try XCTUnwrap(PDFDocument(url: url)).outlineRoot)
        let locations = [
            OriginalChapterLocation(chapterID: UUID(), title: "Verified chapter", pageIndex: 2),
            OriginalChapterLocation(chapterID: UUID(), title: "Invalid location", pageIndex: 99)
        ]
        let model = OriginalPDFReaderModel(url: url, initialPageIndex: 0, initialPoint: nil,
            chapterLocations: locations) { _, _ in true }
        model.load()
        XCTAssertEqual(model.outline.map(\.title), ["Verified chapter"])
        XCTAssertEqual(model.outline.map(\.pageIndex), [2])
        XCTAssertNotNil(model.outline.first?.destination)
    }

    func testEmbeddedOutlineTakesPrecedenceOverVerifiedChapterMap() throws {
        let model = OriginalPDFReaderModel(url: try fixture(), initialPageIndex: 0, initialPoint: nil,
            chapterLocations: [OriginalChapterLocation(chapterID: UUID(), title: "Fallback chapter", pageIndex: 1)]) { _, _ in true }
        model.load()
        XCTAssertEqual(model.outline.map(\.title), ["Tables & diagrams", "Practice", "A footnote"])
    }

    func testTextLayerSearchReturnsSourcePageAndRangeWithoutChangingFile() throws {
        let url = try fixture()
        let original = try Data(contentsOf: url)
        let matches = try OriginalPDFSearch.find("DURABLE", in: url)
        XCTAssertEqual(matches.count, 1)
        let match = try XCTUnwrap(matches.first)
        XCTAssertEqual(match.pageIndex, 2)
        XCTAssertTrue(match.excerpt.contains("durable learning"))
        let document = try XCTUnwrap(PDFDocument(url: url))
        let selection = try XCTUnwrap(document.page(at: 2)?.selection(for: match.range))
        XCTAssertEqual(selection.string?.lowercased(), "durable")
        XCTAssertTrue(try OriginalPDFSearch.find("missing expression", in: url).isEmpty)
        XCTAssertTrue(try OriginalPDFSearch.find("   ", in: url).isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testMissingAndCorruptFilesFailVisiblyWithoutPositionCallback() throws {
        var callbacks = 0
        let missing = OriginalPDFReaderModel(url: directory.appendingPathComponent("missing.pdf"), initialPageIndex: 3,
            initialPoint: nil) { _, _ in callbacks += 1; return true }
        missing.load()
        XCTAssertNil(missing.document)
        XCTAssertTrue(missing.error?.contains("missing") == true)
        let corruptURL = directory.appendingPathComponent("corrupt.pdf")
        try Data("This is not a PDF".utf8).write(to: corruptURL)
        let corrupt = OriginalPDFReaderModel(url: corruptURL, initialPageIndex: 3, initialPoint: nil) { _, _ in callbacks += 1; return true }
        corrupt.load()
        XCTAssertNil(corrupt.document)
        XCTAssertTrue(corrupt.error?.contains("could not be read") == true)
        XCTAssertEqual(callbacks, 0)
    }

    func testSavedPageIsClampedButFiniteViewportAnchorIsNotClippedToPage() {
        XCTAssertEqual(OriginalPDFLocation.clampPage(-1, count: 3), 0)
        XCTAssertEqual(OriginalPDFLocation.clampPage(3, count: 3), 2)
        XCTAssertEqual(OriginalPDFLocation.clampPage(2, count: 3), 2)
        XCTAssertEqual(OriginalPDFLocation.clampPage(5, count: 0), 0)
        XCTAssertNil(OriginalPDFLocation.finitePoint(nil))
        XCTAssertNil(OriginalPDFLocation.finitePoint(CGPoint(x: CGFloat.nan, y: 40)))
        XCTAssertNil(OriginalPDFLocation.finitePoint(CGPoint(x: 40, y: CGFloat.infinity)))
        XCTAssertEqual(OriginalPDFLocation.finitePoint(CGPoint(x: -100, y: 900)), CGPoint(x: -100, y: 900),
            "An anchor outside the current page can represent the visible margin or preceding page")
    }

    func testContinuousPDFPageAndVisiblePointSurviveRemountWithoutAdvancingAPage() throws {
        let url = try fixture()
        var saved: (Int, CGPoint?)?
        let original = OriginalPDFReaderModel(url: url, initialPageIndex: 0, initialPoint: nil) { page, point in
            saved = (page, point); return true
        }
        original.load()
        let view = continuousView(document: try XCTUnwrap(original.document))
        original.restorePosition(in: view)
        original.go(to: 2)
        original.go(to: 0)
        XCTAssertEqual(original.pageIndex, 0)
        let firstPage = try XCTUnwrap(original.document?.page(at: 0))
        let expectedPoint = view.convert(view.bounds.origin, to: firstPage)
        original.finishReading()
        let position = try XCTUnwrap(saved)
        XCTAssertEqual(position.0, original.pageIndex, "Persist the page shown in the footer, not currentDestination's adjacent page")
        XCTAssertEqual(position.1, expectedPoint, "Retain the actual viewport origin in PDF page coordinates")

        // Simulate PDFKit reflow during removal; callbacks must not overwrite the exit snapshot.
        view.go(to: try XCTUnwrap(original.document?.page(at: 1)))
        original.updatePosition()
        original.persistPosition()
        XCTAssertEqual(saved?.0, position.0)
        XCTAssertEqual(saved?.1, position.1)

        let reopened = OriginalPDFReaderModel(url: url, initialPageIndex: position.0, initialPoint: position.1) { _, _ in true }
        reopened.load()
        let newView = continuousView(document: try XCTUnwrap(reopened.document))
        reopened.restorePosition(in: newView)
        XCTAssertEqual(reopened.pageIndex, 0, "Opening Text and returning must not turn the source page")
        let restored = newView.convert(newView.bounds.origin, to: try XCTUnwrap(reopened.document?.page(at: 0)))
        XCTAssertEqual(restored.x, expectedPoint.x, accuracy: 2)
        // go(to: page) includes PDFKit's outer page-break margin; go(to: destination)
        // can clamp that background space above the first sheet. Compare the first
        // visible source point, not the amount of gray margin above the document.
        // The interior-position test below still compares raw coordinates within 2pt.
        let sourceTop = firstPage.bounds(for: .cropBox).maxY
        XCTAssertGreaterThanOrEqual(expectedPoint.y, sourceTop, "This branch must exercise only the outer top margin")
        XCTAssertEqual(min(restored.y, sourceTop), min(expectedPoint.y, sourceTop), accuracy: 2,
            "Restoration must retain the top of the source page even if PDFKit removes its outer margin")
    }

    func testSavedPDFPointTracksAnInteriorViewportInsteadOfPageBottom() throws {
        var saved: (Int, CGPoint?)?
        let model = OriginalPDFReaderModel(url: try fixture(), initialPageIndex: 1, initialPoint: nil) { page, point in
            saved = (page, point); return true
        }
        model.load()
        let view = continuousView(document: try XCTUnwrap(model.document))
        view.autoScales = false
        view.scaleFactor = 2
        model.restorePosition(in: view)
        let page = try XCTUnwrap(model.document?.page(at: 1))
        view.go(to: PDFDestination(page: page, at: CGPoint(x: 80, y: 450)))
        model.updatePosition()
        model.persistPosition()
        let current = try XCTUnwrap(view.currentPage)
        let expected = view.convert(view.bounds.origin, to: current)
        let actual = try XCTUnwrap(saved)
        XCTAssertEqual(actual.0, model.document?.index(for: current))
        XCTAssertEqual(actual.1, expected)
        XCTAssertGreaterThan(try XCTUnwrap(actual.1).y, 0, "An interior reading point must not collapse to the bottom edge")

        let reopened = OriginalPDFReaderModel(url: model.url, initialPageIndex: actual.0, initialPoint: actual.1) { _, _ in true }
        reopened.load()
        let newView = continuousView(document: try XCTUnwrap(reopened.document))
        newView.autoScales = false
        newView.scaleFactor = view.scaleFactor
        reopened.restorePosition(in: newView)
        XCTAssertEqual(reopened.pageIndex, actual.0)
        let reopenedPage = try XCTUnwrap(reopened.document?.page(at: actual.0))
        let restored = newView.convert(newView.bounds.origin, to: reopenedPage)
        XCTAssertEqual(restored.x, expected.x, accuracy: 2, "Interior horizontal reading location must survive remount")
        XCTAssertEqual(restored.y, expected.y, accuracy: 2, "Interior vertical reading location must survive remount")
    }

    private func continuousView(document: PDFDocument) -> PDFView {
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 390, height: 660))
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.autoScales = true
        view.document = document
        view.layoutIfNeeded()
        return view
    }

    func testFailedPositionWriteRetriesSameLocationThenDeduplicatesSuccessfulWrite() throws {
        var attempts: [(Int, CGPoint?)] = []
        let model = OriginalPDFReaderModel(url: try fixture(), initialPageIndex: 1, initialPoint: nil) { page, point in
            attempts.append((page, point))
            return attempts.count > 1
        }
        model.load()
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        view.displayMode = .singlePage
        view.document = try XCTUnwrap(model.document)
        view.layoutIfNeeded()
        model.restorePosition(in: view)
        _ = try XCTUnwrap(view.currentDestination, "The test needs an actual PDF viewport destination")
        XCTAssertTrue(attempts.isEmpty, "Restoration must not write before the user has navigated")
        model.persistPosition()
        XCTAssertEqual(attempts.count, 1)
        model.persistPosition()
        XCTAssertEqual(attempts.count, 2, "A rejected save must remain retryable at the same location")
        XCTAssertEqual(attempts[0].0, attempts[1].0)
        XCTAssertEqual(attempts[0].1, attempts[1].1)
        model.persistPosition()
        XCTAssertEqual(attempts.count, 2, "Only a confirmed successful save may be deduplicated")
    }

    private func fixture(includeOutline: Bool = true) throws -> URL {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 600)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let data = renderer.pdfData { context in
            context.beginPage()
            draw("Tables and diagrams", at: CGPoint(x: 30, y: 30))
            let table = UIBezierPath(rect: CGRect(x: 30, y: 90, width: 340, height: 150))
            table.move(to: CGPoint(x: 200, y: 90)); table.addLine(to: CGPoint(x: 200, y: 240))
            table.move(to: CGPoint(x: 30, y: 140)); table.addLine(to: CGPoint(x: 370, y: 140))
            UIColor.black.setStroke(); table.stroke()
            draw("Input", at: CGPoint(x: 40, y: 105)); draw("Outcome", at: CGPoint(x: 210, y: 105))
            draw("Practice", at: CGPoint(x: 40, y: 165)); draw("Retention", at: CGPoint(x: 210, y: 165))
            draw("1. A source footnote.", at: CGPoint(x: 30, y: 540))
            context.beginPage()
            UIColor.systemBlue.setFill()
            UIBezierPath(ovalIn: CGRect(x: 40, y: 100, width: 120, height: 120)).fill()
            UIColor.systemOrange.setFill()
            UIBezierPath(rect: CGRect(x: 240, y: 100, width: 120, height: 120)).fill()
            let connector = UIBezierPath()
            connector.move(to: CGPoint(x: 160, y: 160)); connector.addLine(to: CGPoint(x: 240, y: 160))
            UIColor.black.setStroke(); connector.stroke()
            context.beginPage()
            draw("Practice for durable learning.", at: CGPoint(x: 30, y: 30))
            draw("A footnote: revisit the original example.", at: CGPoint(x: 30, y: 540))
        }
        let document = try XCTUnwrap(PDFDocument(data: data))
        let first = try XCTUnwrap(document.page(at: 0))
        let last = try XCTUnwrap(document.page(at: 2))
        let root = PDFOutline()
        let tables = PDFOutline()
        tables.label = "Tables & diagrams"
        tables.destination = PDFDestination(page: first, at: CGPoint(x: 0, y: 600))
        let practice = PDFOutline()
        practice.label = "Practice"
        practice.destination = PDFDestination(page: last, at: CGPoint(x: 0, y: 600))
        let footnote = PDFOutline()
        footnote.label = "A footnote"
        footnote.destination = PDFDestination(page: last, at: CGPoint(x: 30, y: 60))
        practice.insertChild(footnote, at: 0)
        root.insertChild(tables, at: 0); root.insertChild(practice, at: 1)
        if includeOutline { document.outlineRoot = root }
        let link = PDFAnnotation(bounds: CGRect(x: 30, y: 40, width: 100, height: 20), forType: .link, withProperties: nil)
        link.action = PDFActionGoTo(destination: PDFDestination(page: last, at: CGPoint(x: 30, y: 60)))
        first.addAnnotation(link)
        let url = directory.appendingPathComponent("synthetic.pdf")
        try XCTUnwrap(document.dataRepresentation()).write(to: url)
        return url
    }

    private func draw(_ text: String, at point: CGPoint) {
        (text as NSString).draw(at: point, withAttributes: [.font: UIFont.systemFont(ofSize: 14), .foregroundColor: UIColor.black])
    }
}
