import XCTest
@testable import LivingReader

final class ModelCodableTests: XCTestCase {
    func testBookCodableRoundTrip() throws {
        let block = ContentBlock(
            id: UUID(),
            kind: .paragraph,
            text: "Argentina's early history is a tapestry of peoples and places.",
            orderIndex: 0
        )
        let chapterId = UUID()
        let bookId = UUID()
        let revision = ChapterRevision(
            id: UUID(),
            chapterId: chapterId,
            revisionIndex: 0,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            blocks: [block],
            isConsumed: true
        )
        let chapter = Chapter(
            id: chapterId,
            bookId: bookId,
            title: "Origins",
            orderIndex: 0,
            activeRevisionId: revision.id,
            revisions: [revision]
        )
        let edition = BookEdition(
            id: UUID(),
            bookId: bookId,
            label: "test",
            localeIdentifier: "en"
        )
        let book = Book(
            id: bookId,
            title: "A Little History of Argentina",
            author: "Living Reader",
            edition: edition,
            chapters: [chapter]
        )

        let data = try JSONCoding.encoder.encode(book)
        let decoded = try JSONCoding.decoder.decode(Book.self, from: data)

        XCTAssertEqual(decoded, book)
        XCTAssertEqual(decoded.chapters.first?.revisions.first?.isConsumed, true)
        XCTAssertEqual(decoded.chapters.first?.revisions.first?.blocks.first?.text, block.text)
        XCTAssertEqual(decoded.edition?.label, "test")
    }

    func testReadingCheckpointCodableRoundTrip() throws {
        let checkpoint = ReadingCheckpoint(
            id: UUID(),
            bookId: UUID(),
            chapterId: UUID(),
            blockId: UUID(),
            characterOffset: 42,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let data = try JSONCoding.encoder.encode(checkpoint)
        let decoded = try JSONCoding.decoder.decode(ReadingCheckpoint.self, from: data)
        XCTAssertEqual(decoded, checkpoint)
    }

    func testConsumedAndCandidateCodableRoundTrip() throws {
        let consumed = ConsumedChapterRevision(
            id: UUID(),
            bookId: UUID(),
            chapterId: UUID(),
            revisionId: UUID(),
            revisionIndex: 1,
            consumedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        let candidate = CandidateRevision(
            id: UUID(),
            bookId: consumed.bookId,
            chapterId: consumed.chapterId,
            proposedRevisionIndex: 2,
            createdAt: Date(timeIntervalSince1970: 1_700_000_300),
            blocks: [ContentBlock(id: UUID(), kind: .paragraph, text: "staged", orderIndex: 0)],
            status: .staged,
            rejectionReason: nil
        )
        XCTAssertEqual(try JSONCoding.decoder.decode(ConsumedChapterRevision.self, from: JSONCoding.encoder.encode(consumed)), consumed)
        XCTAssertEqual(try JSONCoding.decoder.decode(CandidateRevision.self, from: JSONCoding.encoder.encode(candidate)), candidate)
    }

    func testArgentinaFixtureDecodesWithMultipleChaptersAndBlocks() throws {
        let book = try BundleFixtureLoader.loadArgentinaMinimal()
        XCTAssertEqual(book.title, "A Little History of Argentina")
        XCTAssertEqual(book.subtitle, "A Living Book")
        XCTAssertGreaterThanOrEqual(book.chapters.count, ArgentinaFixtureIDs.expectedMinChapters)
        let blocks = book.chapters.flatMap(\.revisions).flatMap(\.blocks)
        XCTAssertGreaterThanOrEqual(blocks.count, 4)
        XCTAssertNotNil(book.edition)
        XCTAssertFalse(book.timeline.isEmpty)
        XCTAssertFalse(book.provenanceNotes.isEmpty)
        XCTAssertGreaterThanOrEqual(book.polishedChapterCount, ArgentinaFixtureIDs.expectedMinPolishedChapters)
        XCTAssertGreaterThan(book.outlineChapterCount, 0)
        let words = blocks.reduce(0) { $0 + $1.text.split { $0.isWhitespace || $0.isNewline }.count }
        XCTAssertGreaterThanOrEqual(words, ArgentinaFixtureIDs.expectedMinWordCount)
        let joined = blocks.map(\.text).joined(separator: " ").lowercased()
        XCTAssertFalse(joined.contains("lorem ipsum"))
        XCTAssertFalse(joined.contains("lorem"))
    }
}
