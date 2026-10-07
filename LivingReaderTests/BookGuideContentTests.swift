import XCTest
import CryptoKit
@testable import LivingReader

final class BookGuideContentTests: XCTestCase {
    func testGuideUsesSelectedBooksMetadataWithoutChangingManuscript() throws {
        let book = try BundleFixtureLoader.loadArgentinaMinimal()
        let before = try JSONCoding.encoder.encode(book)
        let guide = BookGuideContent(book: book)

        XCTAssertEqual(guide.title, book.title)
        XCTAssertEqual(guide.author, book.author)
        XCTAssertEqual(guide.synopsis, book.synopsis)
        XCTAssertEqual(guide.overviewTitle, "Overview · whole book")
        XCTAssertEqual(guide.overviewEmptyText, "No overview saved for this book.")
        XCTAssertEqual(guide.edition, book.edition?.label)
        XCTAssertEqual(guide.notes, book.provenanceNotes)
        XCTAssertEqual(try JSONCoding.encoder.encode(book), before)
    }

    func testMissingMetadataDoesNotInventOverviewSourcesOrTimeline() {
        let book = Book(id: UUID(), title: "Imported notes", author: "", chapters: [])
        let guide = BookGuideContent(book: book)

        XCTAssertEqual(guide.title, "Imported notes")
        XCTAssertNil(guide.author)
        XCTAssertNil(guide.subtitle)
        XCTAssertNil(guide.edition)
        XCTAssertNil(guide.synopsis)
        XCTAssertEqual(guide.overviewTitle, "Overview · whole book")
        XCTAssertEqual(guide.overviewEmptyText, "No overview saved for this book.")
        XCTAssertTrue(guide.notes.isEmpty)
        XCTAssertTrue(guide.timeline.isEmpty)
    }

    func testBlankMetadataIsOmittedWithoutDiscardingUnicodeOrDuplicateNotes() {
        var book = Book(id: UUID(), title: " \n", author: "\t", chapters: [])
        book.subtitle = " "
        book.synopsis = "\n"
        book.edition = BookEdition(id: UUID(), bookId: book.id, label: "\t", localeIdentifier: "en")
        book.provenanceNotes = [" ", " Café — العربية 👩🏽‍🚀 ", "Café — العربية 👩🏽‍🚀", "\n"]
        let guide = BookGuideContent(book: book)

        XCTAssertEqual(guide.title, "Untitled book")
        XCTAssertNil(guide.author)
        XCTAssertNil(guide.subtitle)
        XCTAssertNil(guide.synopsis)
        XCTAssertNil(guide.edition)
        XCTAssertEqual(guide.notes, ["Café — العربية 👩🏽‍🚀", "Café — العربية 👩🏽‍🚀"])
    }

    func testTimelineSortsChronologyAndKeepsStoredOrderForTies() {
        let late = event("Late", order: 2)
        let tiedFirst = event("Tied first", order: 1)
        let early = event("Early", order: 0)
        let tiedSecond = event("Tied second", order: 1)
        var book = Book(id: UUID(), title: "Timeline", author: "Author", chapters: [])
        book.timeline = [late, tiedFirst, early, tiedSecond]

        XCTAssertEqual(BookGuideContent(book: book).timeline, [early, tiedFirst, tiedSecond, late])
        XCTAssertEqual(book.timeline, [late, tiedFirst, early, tiedSecond])
    }

    func testGuideDoesNotProjectChangingChapterContentOrRevisionStatus() throws {
        var book = try BundleFixtureLoader.loadArgentinaMinimal()
        let before = BookGuideContent(book: book)
        book.chapters[0].title = "A newer chapter title"
        book.chapters[0].manuscriptStatus = .outline
        book.chapters[0].revisions[0].blocks[0].text = "UNREAD SECRET"
        book.chapters[0].revisions[0].isConsumed.toggle()

        XCTAssertEqual(BookGuideContent(book: book), before)
    }

    func testPublishedOpeningExcerptGuideUsesExactReviewedPassageAndMeasuredSubtitleWithoutMutation() async throws {
        try await assertReviewedGuide(scope: .wikipediaOpeningExcerpt, consumed: false)
    }

    func testConsumedLegacyIntroductionGuidePreservesReceiptManuscriptAndLedger() async throws {
        try await assertReviewedGuide(scope: .wikipediaIntroduction, consumed: true)
    }

    func testPendingSourceGuideHidesWritingBriefAndRetainsNotReviewedSubtitle() throws {
        for scope: RetrievedResearchSource.Scope in [.wikipediaIntroduction, .wikipediaOpeningExcerpt] {
            let fixture = try makeSourceFixture(scope: scope)
            for hasRetrievedSource in [false, true] {
                var book = fixture.book
                if !hasRetrievedSource { book.chapters[0].sourceGrounding = nil }
                XCTAssertEqual(book.chapters[0].sourceGrounding != nil, hasRetrievedSource)
                let before = try JSONCoding.encoder.encode(book)
                let guide = BookGuideContent(book: book)

                XCTAssertTrue(guide.isSourcePreview)
                XCTAssertEqual(guide.overviewTitle, "Opening passage · preview")
                XCTAssertEqual(guide.overviewEmptyText, "No reviewed opening passage saved yet.")
                XCTAssertNil(guide.synopsis, "A pending preview must not expose its writing brief before or after source retrieval")
                XCTAssertEqual(guide.subtitle, "Source preview · not reviewed")
                XCTAssertEqual(guide.sources, hasRetrievedSource ? [fixture.source] : [])
                XCTAssertEqual(try JSONCoding.encoder.encode(book), before)
            }
        }
    }

    func testCorruptReviewedSourceGuideCannotExposeBriefOrClaimChecked() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeSourceFixture(scope: .wikipediaOpeningExcerpt)
        let saved = try await publish(fixture, root: root, consumed: false)
        let file = manuscriptURL(root: root, bookID: saved.id)
        let diskBefore = try fileState(file)
        let activeIndex = try XCTUnwrap(saved.chapters[0].revisions.firstIndex {
            $0.id == saved.chapters[0].activeRevisionId
        })
        var missingReview = saved
        missingReview.chapters[0].revisions[activeIndex].sourceReview = nil
        var changedProse = saved
        changedProse.chapters[0].revisions[activeIndex].blocks[1].text = "UNREVIEWED REPLACEMENT PASSAGE [1]"
        var missingPointer = saved
        missingPointer.chapters[0].activeRevisionId = nil
        var unknownPointer = saved
        unknownPointer.chapters[0].activeRevisionId = UUID()

        for invalid in [missingReview, changedProse, missingPointer, unknownPointer] {
            let before = try JSONCoding.encoder.encode(invalid)
            let guide = BookGuideContent(book: invalid)
            XCTAssertEqual(guide.overviewTitle, "Opening passage · preview")
            XCTAssertEqual(guide.overviewEmptyText, "No reviewed opening passage saved yet.")
            XCTAssertNil(guide.synopsis, "Neither the raw brief nor invalid active prose is a reviewed opening")
            XCTAssertNil(guide.subtitle, "Invalid review state must not inherit the stored checked label")
            XCTAssertEqual(try JSONCoding.encoder.encode(invalid), before)
            XCTAssertEqual(try fileState(file), diskBefore)
        }
    }

    private func assertReviewedGuide(scope: RetrievedResearchSource.Scope, consumed: Bool) async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeSourceFixture(scope: scope)
        let book = try await publish(fixture, root: root, consumed: consumed)
        let revision = try XCTUnwrap(book.chapters.first?.activeRevision)
        XCTAssertEqual(revision.isConsumed, consumed)
        let before = try JSONCoding.encoder.encode(book)
        let watched = [manuscriptURL(root: root, bookID: book.id),
                       root.appendingPathComponent("Ledger/consumed-ledger.json")]
        let diskBefore = try watched.map { try fileState($0) }

        let guide = BookGuideContent(book: book)

        XCTAssertEqual(guide.overviewTitle, "Opening passage · preview")
        XCTAssertEqual(guide.overviewEmptyText, "No reviewed opening passage saved yet.")
        XCTAssertEqual(guide.synopsis, fixture.firstParagraph + " [1]")
        XCTAssertEqual(guide.synopsis, revision.blocks[1].text, "Do not paraphrase, truncate, or strip its citation")
        XCTAssertNotEqual(guide.synopsis, book.synopsis)
        XCTAssertEqual(guide.subtitle, "Source-checked preview · 380 prose words",
            "Count only authored prose, excluding heading, citation markers, disclosure and source footer")
        XCTAssertEqual(book.subtitle, "Source-checked preview · 400 words", "Guide presentation must not rewrite legacy metadata")
        XCTAssertEqual(guide.sources, [fixture.source])
        XCTAssertEqual(guide.notes, book.provenanceNotes)
        XCTAssertEqual(revision.sourceReview?.promptVersion, "source-preview-1")
        if scope == .wikipediaIntroduction {
            XCTAssertNil(fixture.source.extractionMetadata)
            XCTAssertEqual(revision.sourceReview?.sourceHash, try legacyIntroductionHash(fixture.source))
        }
        XCTAssertEqual(try JSONCoding.encoder.encode(book), before)
        XCTAssertEqual(try watched.map { try fileState($0) }, diskBefore)
        let reopened = try ManuscriptVersioningService(rootDirectory: root)
        let reloaded = try await reopened.loadBook(id: book.id)
        XCTAssertEqual(reloaded, book)
        XCTAssertEqual(BookGuideContent(book: try XCTUnwrap(reloaded)), guide)
        XCTAssertEqual(try watched.map { try fileState($0) }, diskBefore)
    }

    private struct SourceFixture {
        let book: Book
        let source: RetrievedResearchSource
        let candidate: CandidateRevision
        let firstParagraph: String
    }

    private func makeSourceFixture(scope: RetrievedResearchSource.Scope) throws -> SourceFixture {
        // Each sentence is 19 whitespace-separated words; the two 10-sentence
        // prose paragraphs are deliberately 380 words, not the old 400-word label.
        let first = "The river archive records how neighboring communities shared boats and kept written accounts of harvests, trade, and public meetings."
        let second = "The surviving records describe seasonal journeys and the councils that coordinated schedules for exchanges between settlements along the river."
        let paragraphs = [first, second].map {
            SourceDraftParagraph(text: Array(repeating: $0, count: 10).joined(separator: " "), citations: ["source1"])
        }
        XCTAssertEqual(paragraphs.map(\.text).joined(separator: " ").split(whereSeparator: \.isWhitespace).count, 380)
        let text = [first, second].map { Array(repeating: $0, count: 5).joined(separator: " ") }
            .joined(separator: scope == .wikipediaOpeningExcerpt ? "\n\n" : "\n")
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let source = RetrievedResearchSource(requestedTitle: "River Archive", title: "River Archive",
            canonicalURL: URL(string: "https://en.wikipedia.org/wiki/River_Archive")!, pageID: 42, revisionID: 9001,
            revisionURL: URL(string: "https://en.wikipedia.org/w/index.php?oldid=9001")!,
            revisionTimestamp: timestamp, retrievedAt: timestamp, scope: scope, text: text,
            textSHA256: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined(),
            attribution: "Authored fixture, not a real Wikipedia retrieval.",
            attributionURL: URL(string: "https://en.wikipedia.org/w/index.php?title=River_Archive&action=history")!,
            licenseName: "Fixture CC BY-SA 4.0", licenseURL: URL(string: "https://creativecommons.org/licenses/by-sa/4.0/")!,
            extractionMetadata: scope == .wikipediaOpeningExcerpt ? .init(
                extractionVersion: "wikipedia-opening-paragraphs-v1", paragraphLocators: [
                    .init(sectionAnchor: nil, sectionTitle: "Introduction", paragraphIndex: 1),
                    .init(sectionAnchor: "Records", sectionTitle: "Records", paragraphIndex: 1)
                ]) : nil)
        let bookID = UUID(), chapterID = UUID(), outlineID = UUID()
        let outlineBlocks = [ContentBlock(id: UUID(), kind: .paragraph,
            text: "UNREVIEWED OUTLINE — do not show as an opening passage.", orderIndex: 0)]
        let requirement = SourceGroundingRequirement(source: source, outlineRevisionID: outlineID,
            outlineContentHash: try SourceGrounding.contentHash(outlineBlocks), approvedBriefHash: "fixture-brief")
        let outline = ChapterRevision(id: outlineID, chapterId: chapterID, revisionIndex: 1,
            createdAt: timestamp, blocks: outlineBlocks, isConsumed: false)
        let chapter = Chapter(id: chapterID, bookId: bookID, title: "River Archive", orderIndex: 0,
            activeRevisionId: outlineID, revisions: [outline], manuscriptStatus: .outline, sourceGrounding: requirement)
        var book = Book(id: bookID, title: "River Archive", author: "GenBooks", chapters: [chapter])
        book.subtitle = "Source preview · not reviewed"
        book.synopsis = "UNREVIEWED WRITING BRIEF: explain only this source; do not expose these instructions."
        book.provenanceNotes = ["Pending preview: no source-support review has been completed."]
        let blocks = try SourceGrounding.blocks(title: chapter.title, paragraphs: paragraphs, source: source)
        let response = SourceReviewResponse(units: [
            .init(index: 0, assessment: .supported, quotes: [first]),
            .init(index: 1, assessment: .supported, quotes: [second])
        ])
        let issued = try SourceGrounding.receipt(bookID: bookID, chapterID: chapterID, baseRevisionID: outlineID,
            blocks: blocks, source: source, model: OpenAIModelOption.defaultGeneration.rawValue, response: response)
        let receipt = SourceReviewReceipt(bookID: bookID, chapterID: chapterID, baseRevisionID: outlineID,
            contentHash: issued.contentHash,
            sourceHash: scope == .wikipediaIntroduction ? try legacyIntroductionHash(source) : issued.sourceHash,
            model: issued.model, promptVersion: "source-preview-1", reviewedAt: timestamp, response: response)
        let candidate = CandidateRevision(id: UUID(), bookId: bookID, chapterId: chapterID, proposedRevisionIndex: 2,
            createdAt: timestamp, blocks: blocks, status: .staged, rejectionReason: nil,
            origin: .generated(style: "Fixture"), sourceReview: receipt)
        return SourceFixture(book: book, source: source, candidate: candidate, firstParagraph: paragraphs[0].text)
    }

    private func publish(_ fixture: SourceFixture, root: URL, consumed: Bool) async throws -> Book {
        let service = try ManuscriptVersioningService(rootDirectory: root)
        try await service.saveBook(fixture.book)
        try await service.stageCandidate(fixture.candidate)
        let revision = try await service.activateCandidate(id: fixture.candidate.id)
        try await service.markChapterPolished(bookId: fixture.book.id, chapterId: fixture.candidate.chapterId,
            expectedRevisionId: revision.id)
        if consumed {
            try await service.consume(bookId: fixture.book.id, chapterId: fixture.candidate.chapterId,
                revisionId: revision.id)
        }
        let loaded = try await service.loadBook(id: fixture.book.id)
        var book = try XCTUnwrap(loaded)
        book.subtitle = "Source-checked preview · 400 words"
        book.provenanceNotes = [SourcePilotPlan.disclosure(for: fixture.source.scope)]
        try await service.saveBook(book)
        let reopened = try ManuscriptVersioningService(rootDirectory: root)
        let saved = try await reopened.loadBook(id: book.id)
        return try XCTUnwrap(saved)
    }

    private func legacyIntroductionHash(_ source: RetrievedResearchSource) throws -> String {
        struct LegacySource: Encodable {
            let requestedTitle: String; let title: String; let canonicalURL: URL
            let pageID: Int64; let revisionID: Int64; let revisionURL: URL
            let revisionTimestamp: Date; let retrievedAt: Date; let scope: String
            let text: String; let textSHA256: String; let attribution: String
            let attributionURL: URL; let licenseName: String; let licenseURL: URL
        }
        let legacy = LegacySource(requestedTitle: source.requestedTitle, title: source.title,
            canonicalURL: source.canonicalURL, pageID: source.pageID, revisionID: source.revisionID,
            revisionURL: source.revisionURL, revisionTimestamp: source.revisionTimestamp, retrievedAt: source.retrievedAt,
            scope: "wikipediaIntroduction", text: source.text, textSHA256: source.textSHA256,
            attribution: source.attribution, attributionURL: source.attributionURL,
            licenseName: source.licenseName, licenseURL: source.licenseURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return SHA256.hash(data: try encoder.encode(legacy)).map { String(format: "%02x", $0) }.joined()
    }

    private struct FileState: Equatable {
        let data: Data?
        let modifiedAt: Date?
    }

    private func fileState(_ url: URL) throws -> FileState {
        guard FileManager.default.fileExists(atPath: url.path) else { return FileState(data: nil, modifiedAt: nil) }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return FileState(data: try Data(contentsOf: url), modifiedAt: attributes[.modificationDate] as? Date)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BookGuideContentTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func manuscriptURL(root: URL, bookID: UUID) -> URL {
        root.appendingPathComponent("Manuscripts/\(bookID.uuidString).json")
    }

    private func event(_ title: String, order: Int) -> TimelineEvent {
        TimelineEvent(id: UUID(), yearLabel: "era", title: title, summary: "Saved summary", orderIndex: order)
    }
}
