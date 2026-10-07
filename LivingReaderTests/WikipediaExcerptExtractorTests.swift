import XCTest
@testable import LivingReader

final class WikipediaExcerptExtractorTests: XCTestCase {
    private let prose = String(repeating: "People studied this historical period using records and archaeological evidence. ", count: 10).trimmingCharacters(in: .whitespaces)

    func testShortLeadPlusOpeningSectionKeepsOrderedParagraphsAndExactEntities() throws {
        let lead = "Earth &amp; people &lt;discuss&gt; &amp;lt;history&amp;gt;."
        let result = try extract("<p>\(lead)</p><h2 id='History'>History</h2><p>\(prose)<sup class='reference'><a href='https://invalid.test'>[1]</a></sup></p><p>\(prose)</p>")
        XCTAssertEqual(result.text, "Earth & people <discuss> &lt;history&gt;.\n\n\(prose)\n\n\(prose)")
        XCTAssertEqual(result.metadata.paragraphLocators, [
            .init(sectionAnchor: nil, sectionTitle: "Introduction", paragraphIndex: 1),
            .init(sectionAnchor: "History", sectionTitle: "History", paragraphIndex: 1),
            .init(sectionAnchor: "History", sectionTitle: "History", paragraphIndex: 2)])
        XCTAssertTrue(result.metadata.isValid(for: result.text))
        XCTAssertTrue(result.metadata.scopeDescription.contains("not the full article"))
        XCTAssertTrue(result.metadata.renderingCaveat.contains("later changes"))
    }

    func testNavigationAssetsTablesScriptsAndReferencesDoNotBecomeProse() throws {
        let result = try extract("""
        <script>fetch('https://invalid.test/secret')</script><style>p{background:url(https://invalid.test/x)}</style>
        <link rel="stylesheet" href="https://invalid.test/style"><iframe src="https://invalid.test/frame"></iframe>
        <div class="hatnote"><p>Wrong navigation</p></div><table><tr><td><p>Wrong infobox</p></td></tr></table>
        <figure><img src="https://invalid.test/image"><figcaption>Wrong caption</figcaption></figure>
        <h2><span class="mw-headline" id="History">History</span></h2>
        <p>\(prose)</p><p>\(prose)</p><ol class="references"><li>Wrong reference</li></ol>
        """)
        XCTAssertEqual(result.text, "\(prose)\n\n\(prose)")
    }

    func testNestedAndDuplicateHeadingNamesUseActualDistinctAnchors() throws {
        let sections: [WikipediaExcerptExtractor.Section] = [
            .init(anchor: "History", line: "History", hLevel: 2, fromTitle: "Earth"),
            .init(anchor: "History_2", line: "History", hLevel: 3, fromTitle: "Earth")]
        let result = try extract("<h2 id='History'>History</h2><p>\(prose)</p><div class='mw-heading mw-heading3'><h3 id='History_2'>History</h3></div><p>\(prose)</p>", sections: sections)
        XCTAssertEqual(result.metadata.paragraphLocators.map(\.sectionAnchor), ["History", "History_2"])
        XCTAssertEqual(result.metadata.paragraphLocators.map(\.paragraphIndex), [1, 1])
    }

    func testCeilingStopsBeforeWholeParagraphAndNeverSkipsAheadToSmallerText() throws {
        let result = try extract("<h2 id='History'>History</h2><p>\(prose)</p><p>\(prose)</p><p>\(String(repeating: "x", count: 8_000))</p><p>Later small paragraph.</p>")
        XCTAssertEqual(result.text, "\(prose)\n\n\(prose)")
        XCTAssertEqual(result.metadata.paragraphLocators.count, 2)
    }

    func testShortOrOversizedFirstParagraphRejectsWithoutPadding() throws {
        assertFailure(.insufficientExcerpt, "<h2 id='History'>History</h2><p>Only 32 words would still be too short.</p>")
        assertFailure(.insufficientExcerpt, "<h2 id='History'>History</h2><p>\(String(repeating: "x", count: 8_001))</p><p>\(prose)</p><p>\(prose)</p>")
        XCTAssertThrowsError(try WikipediaExcerptExtractor.extract(html: String(repeating: "x", count: 2 * 1024 * 1024 + 1), sections: [], articleTitle: "Earth")) {
            XCTAssertEqual($0 as? WikipediaSourceError, .oversizedResponse)
        }
    }

    func testOverflowBoundaryIgnoresUnsupportedLaterProseAndHeadings() throws {
        let result = try extract("""
        <h2 id='History'>History</h2><p>\(prose)</p><p>\(prose)</p>
        <p>\(String(repeating: "x", count: 8_000))</p>
        <p>Later <math>x=2</math> must not affect the retained prefix.</p>
        <h2 id='Unlisted'>Unlisted section</h2><div>Unsupported later prose</div>
        """)
        XCTAssertEqual(result.text, "\(prose)\n\n\(prose)")
        XCTAssertEqual(result.metadata.paragraphLocators.map(\.sectionAnchor), ["History", "History"])
    }

    func testReferencesBoundaryIgnoresUnsupportedTailAndUnconsumedMetadata() throws {
        let sections: [WikipediaExcerptExtractor.Section] = [
            .init(anchor: "History", line: "History", hLevel: 2, fromTitle: "Earth"),
            .init(anchor: "References", line: "References", hLevel: 2, fromTitle: "Earth"),
            .init(anchor: nil, line: nil, hLevel: nil, fromTitle: "Template:Unrelated")]
        let result = try extract("""
        <h2 id='History'>History</h2><p>\(prose)</p><p>\(prose)</p>
        <h2 id='References'>References</h2><p>Reference <math>x=2</math></p>
        <h2 id='Later'>Unknown later section</h2><div>Unsupported later prose</div>
        """, sections: sections)
        XCTAssertEqual(result.text, "\(prose)\n\n\(prose)")
        XCTAssertEqual(result.metadata.paragraphLocators.count, 2)
    }

    func testUnknownTrailingSectionMetadataDoesNotRejectBoundedPrefix() throws {
        let sections: [WikipediaExcerptExtractor.Section] = [
            .init(anchor: "History", line: "History", hLevel: 2, fromTitle: "Earth"),
            .init(anchor: "Later", line: "<math>unsupported</math>", hLevel: 1, fromTitle: "Template:Other")]
        let result = try extract("<h2 id='History'>History</h2><p>\(prose)</p><p>\(prose)</p><p>\(String(repeating: "x", count: 8_000))</p><h2 id='Later'>Later</h2>", sections: sections)
        XCTAssertEqual(result.text, "\(prose)\n\n\(prose)")
        // The same unknown section still rejects when the opening prefix reaches it.
        XCTAssertThrowsError(try extract("<h2 id='History'>History</h2><p>\(prose)</p><p>\(prose)</p><h2 id='Later'>Later</h2>", sections: sections))
    }

    func testMismatchedMissingDuplicateForeignOrAmbiguousSectionMetadataRejects() throws {
        for heading in ["<h2 id='Wrong'>History</h2>", "<h3 id='History'>History</h3>", "<h2 id='History'>Different title</h2>", "", "<h2 id='History'>History</h2><h2 id='History'>History</h2>"] {
            assertFailure(.invalidExcerptStructure, "\(heading)<p>\(prose)</p><p>\(prose)</p>")
        }
        let html = "<h2 id='History'>History</h2><p>\(prose)</p><p>\(prose)</p>"
        for sections: [WikipediaExcerptExtractor.Section] in [
            [.init(anchor: nil, line: "History", hLevel: 2, fromTitle: nil)],
            [.init(anchor: "History", line: "History", hLevel: 2, fromTitle: "Template:Other")],
            [.init(anchor: "History", line: "History", hLevel: 2, fromTitle: nil), .init(anchor: "History", line: "History", hLevel: 2, fromTitle: nil)]
        ] { XCTAssertThrowsError(try extract(html, sections: sections)) }
    }

    func testAmbiguousProseRegionsAndMeaningfulInlineAssetsReject() throws {
        for bad in ["unwrapped prose", "<div>unwrapped prose</div>", "<p>words <math>x=2</math></p>", "<p>words <img alt='not' src='https://invalid.test'></p>", "<p>words <span hidden>not</span></p>", "<p>words<div>misnested prose</div>tail</p>"] {
            assertFailure(.invalidExcerptStructure, "<h2 id='History'>History</h2><p>\(prose)</p><p>\(prose)</p>\(bad)")
        }
        XCTAssertThrowsError(try WikipediaExcerptExtractor.extract(html: "<div class='mw-parser-output'><p>\(prose)</p></div><p>other region</p>", sections: [], articleTitle: "Earth"))
    }

    func testDecodedMetadataMustMatchParagraphCountAndIndices() throws {
        let metadata = RetrievedResearchSource.ExtractionMetadata(extractionVersion: "wikipedia-opening-paragraphs-v1", paragraphLocators: [.init(sectionAnchor: nil, sectionTitle: "Introduction", paragraphIndex: 1)])
        XCTAssertTrue(metadata.isValid(for: prose))
        XCTAssertFalse(metadata.isValid(for: "\(prose)\n\n\(prose)"))
        XCTAssertFalse(metadata.isValid(for: "\(prose)\nother line"))
        let wrongIndex = RetrievedResearchSource.ExtractionMetadata(extractionVersion: "wikipedia-opening-paragraphs-v1", paragraphLocators: [.init(sectionAnchor: nil, sectionTitle: "Introduction", paragraphIndex: 2)])
        XCTAssertFalse(wrongIndex.isValid(for: prose))
    }

    private func extract(_ body: String, sections: [WikipediaExcerptExtractor.Section]? = nil) throws -> WikipediaExcerptExtractor.Excerpt {
        try WikipediaExcerptExtractor.extract(html: "<div class='mw-parser-output'>\(body)</div>",
            sections: sections ?? [.init(anchor: "History", line: "History", hLevel: 2, fromTitle: "Earth")], articleTitle: "Earth")
    }

    private func assertFailure(_ error: WikipediaSourceError, _ html: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try extract(html), file: file, line: line) { XCTAssertEqual($0 as? WikipediaSourceError, error, file: file, line: line) }
    }
}
