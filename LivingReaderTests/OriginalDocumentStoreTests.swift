import XCTest
import UIKit
import PDFKit
@testable import LivingReader

final class OriginalDocumentStoreTests: XCTestCase {
    private var root: URL!
    private var store: OriginalDocumentStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("OriginalPDF-\(UUID().uuidString)")
        store = try OriginalDocumentStore(rootDirectory: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testRetainsExactBytesAndSharedSourceWithoutChangingManuscriptFiles() throws {
        let untouched = root.appendingPathComponent("existing-text-and-notes.json")
        let sentinel = Data("existing manuscript, notes, and text checkpoint".utf8)
        try sentinel.write(to: untouched)
        let data = syntheticPDF()
        let bookID = UUID()
        let chapter = OriginalChapterLocation(chapterID: UUID(), title: "A table", pageIndex: 1)
        let result = try store.attach(data: data, filename: "Synthetic.pdf", bookID: bookID, chapters: [chapter])
        XCTAssertEqual(try Data(contentsOf: result.url), data)
        XCTAssertEqual(result.attachment.source.pageCount, 3)
        XCTAssertTrue(result.attachment.source.hasExtractedText)
        XCTAssertEqual(result.url.lastPathComponent, result.attachment.source.sha256 + ".pdf")
        let reopened = try XCTUnwrap(OriginalDocumentStore(rootDirectory: root).load(bookID: bookID))
        XCTAssertEqual(reopened.attachment.chapters, [chapter])
        let second = try store.attach(data: data, filename: "Same bytes.pdf", bookID: UUID())
        XCTAssertEqual(second.url, result.url)
        XCTAssertEqual(try Data(contentsOf: untouched), sentinel)
        XCTAssertThrowsError(try store.attach(data: syntheticPDF(pageCount: 1), filename: "Different.pdf", bookID: bookID))
        XCTAssertEqual(try store.load(bookID: bookID)?.attachment.source, result.attachment.source)
    }

    func testChangedOrMissingPDFIsAnErrorNotMissingAttachment() throws {
        let bookID = UUID()
        let result = try store.attach(data: syntheticPDF(), filename: "Fixture.pdf", bookID: bookID)
        try Data("damaged".utf8).write(to: result.url)
        XCTAssertThrowsError(try store.load(bookID: bookID))
        try FileManager.default.removeItem(at: result.url)
        XCTAssertThrowsError(try store.load(bookID: bookID))
        XCTAssertNil(try store.load(bookID: UUID()))
    }

    func testStagingDoesNotSilentlyRepairAChangedAsset() throws {
        let data = syntheticPDF()
        let reference = try store.stage(data: data, filename: "Fixture.pdf")
        let asset = store.directory.appendingPathComponent(reference.sha256 + ".pdf")
        try Data("changed".utf8).write(to: asset)
        XCTAssertThrowsError(try store.stage(data: data, filename: "Fixture.pdf"))
        XCTAssertEqual(try Data(contentsOf: asset), Data("changed".utf8))
    }

    func testRejectsWrongBookIdentityTraversalPageMapAndSymlink() throws {
        let bookID = UUID()
        let original = try store.attach(data: syntheticPDF(), filename: "Fixture.pdf", bookID: bookID)
        let manifest = store.directory.appendingPathComponent("Attachments/\(bookID.uuidString).json")
        var bad = original.attachment
        bad.bookID = UUID()
        try JSONCoding.encoder.encode(bad).write(to: manifest)
        XCTAssertThrowsError(try store.load(bookID: bookID))
        bad = original.attachment
        bad.source.sha256 = "../../outside"
        try JSONCoding.encoder.encode(bad).write(to: manifest)
        XCTAssertThrowsError(try store.load(bookID: bookID))
        bad = original.attachment
        bad.source.filename = "../outside.pdf"
        try JSONCoding.encoder.encode(bad).write(to: manifest)
        XCTAssertThrowsError(try store.load(bookID: bookID))
        bad = original.attachment
        bad.chapters = [.init(chapterID: UUID(), title: "Beyond end", pageIndex: 3)]
        try JSONCoding.encoder.encode(bad).write(to: manifest)
        XCTAssertThrowsError(try store.load(bookID: bookID))
        try JSONCoding.encoder.encode(original.attachment).write(to: manifest)
        let external = root.appendingPathComponent("outside.pdf")
        try FileManager.default.moveItem(at: original.url, to: external)
        try FileManager.default.createSymbolicLink(at: original.url, withDestinationURL: external)
        XCTAssertThrowsError(try store.load(bookID: bookID))
        XCTAssertThrowsError(try store.stage(data: syntheticPDF(), filename: "../bad.pdf"))
    }

    func testRejectsRedirectedStorageDirectory() throws {
        let alternate = root.appendingPathComponent("alternate", isDirectory: true)
        try FileManager.default.createDirectory(at: alternate, withIntermediateDirectories: true)
        let attachments = store.directory.appendingPathComponent("Attachments")
        try FileManager.default.removeItem(at: attachments)
        try FileManager.default.createSymbolicLink(at: attachments, withDestinationURL: alternate)
        XCTAssertThrowsError(try OriginalDocumentStore(rootDirectory: root))
        XCTAssertThrowsError(try store.load(bookID: UUID()))
    }

    func testPDFPositionsAreIndependentByBookAndSourceAndLeaveTextCheckpointAlone() throws {
        let bookID = UUID(), otherBookID = UUID()
        let data = syntheticPDF()
        let source = try store.attach(data: data, filename: "Fixture.pdf", bookID: bookID).attachment.source
        _ = try store.attach(data: data, filename: "Fixture.pdf", bookID: otherBookID)
        let textStore = try FileReadingCheckpointStore(rootDirectory: root)
        let checkpoint = ReadingCheckpoint(id: UUID(), bookId: bookID, chapterId: UUID(), blockId: UUID(),
            characterOffset: 21, updatedAt: Date(timeIntervalSince1970: 10))
        try textStore.saveCheckpoint(checkpoint)
        try store.savePosition(bookID: bookID, sourceSHA256: source.sha256, pageIndex: 2, pagePointX: 20, pagePointY: 100)
        let position = try XCTUnwrap(store.loadPosition(bookID: bookID, sourceSHA256: source.sha256))
        XCTAssertEqual(position.pageIndex, 2)
        XCTAssertEqual(position.pagePointX, 20)
        XCTAssertEqual(position.pagePointY, 100)
        XCTAssertNil(try store.loadPosition(bookID: otherBookID, sourceSHA256: source.sha256))
        XCTAssertEqual(try textStore.loadCheckpoint(bookId: bookID), checkpoint)
        XCTAssertThrowsError(try store.loadPosition(bookID: bookID, sourceSHA256: String(repeating: "0", count: 64)))
        XCTAssertThrowsError(try store.savePosition(bookID: bookID, sourceSHA256: source.sha256, pageIndex: -1))
        XCTAssertThrowsError(try store.savePosition(bookID: bookID, sourceSHA256: source.sha256, pageIndex: 3))
        XCTAssertThrowsError(try store.savePosition(bookID: bookID, sourceSHA256: source.sha256, pageIndex: 0,
            pagePointX: .infinity, pagePointY: 0))
        XCTAssertThrowsError(try store.savePosition(bookID: bookID, sourceSHA256: source.sha256, pageIndex: 0,
            pagePointX: 1, pagePointY: nil))
        XCTAssertEqual(try store.loadPosition(bookID: bookID, sourceSHA256: source.sha256), position)
    }

    func testAlteredPositionIdentityCannotRestoreIntoAnotherBook() throws {
        let bookID = UUID()
        let source = try store.attach(data: syntheticPDF(), filename: "Fixture.pdf", bookID: bookID).attachment.source
        try store.savePosition(bookID: bookID, sourceSHA256: source.sha256, pageIndex: 1)
        let url = store.directory.appendingPathComponent("Positions/\(bookID.uuidString)-\(source.sha256).json")
        let tampered = OriginalReadingPosition(bookID: UUID(), sourceSHA256: source.sha256, pageIndex: 1,
            pagePointX: nil, pagePointY: nil)
        try JSONCoding.encoder.encode(tampered).write(to: url)
        XCTAssertThrowsError(try store.loadPosition(bookID: bookID, sourceSHA256: source.sha256))
    }

    func testStagedImportSurvivesDraftSaveAndMissingOriginalFailsBeforeManuscriptPublish() async throws {
        let (wizard, versioning, drafts, ai) = try makeWizard()
        let data = syntheticPDF()
        let payload = try CanonFileIngest.prepare(data: data, filename: "Reading.pdf")
        XCTAssertEqual(payload.originalPDF, data)
        let draft = try await wizard.prepareImport(draft: .blank(), payload: payload)
        try drafts.save(draft)
        let restored = try XCTUnwrap(drafts.load(id: draft.id))
        XCTAssertEqual(restored.importedOriginal, draft.importedOriginal)
        let book = try await wizard.importAndSave(draft: restored)
        XCTAssertEqual(book.id, draft.id)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.load(bookID: book.id)).url), data)
        XCTAssertTrue(book.provenanceNotes.contains { $0.contains("extracted PDF text") })
        XCTAssertEqual(ai.totalCallCount, 0)

        var failed = restored
        failed.id = UUID()
        let asset = store.directory.appendingPathComponent(try XCTUnwrap(failed.importedOriginal).sha256 + ".pdf")
        try FileManager.default.removeItem(at: asset)
        do { _ = try await wizard.importAndSave(draft: failed); XCTFail("Missing source must fail import") }
        catch { XCTAssertTrue(error is OriginalDocumentError) }
        let absent = try await versioning.loadBook(id: failed.id)
        XCTAssertNil(absent)
    }

    @MainActor
    func testCreatePickerPathKeepsImageOnlyPDFWithClearlyLabeledGuidance() async throws {
        let (wizard, _, _, ai) = try makeWizard()
        let defaults = UserDefaults(suiteName: "OriginalPicker-\(UUID().uuidString)")!
        let model = CreateBookViewModel(wizard: wizard, modelPrefs: AIModelPreferenceStore(defaults: defaults))
        let data = syntheticPDF(includeText: false)
        let payload = try CanonFileIngest.prepare(data: data, filename: "Illustrated.pdf")
        XCTAssertTrue(payload.plainText.contains("Editorial guidance — text extraction unavailable"))
        await model.importFile(payload)
        let book = try XCTUnwrap(model.createdBook, model.errorMessage ?? "No import result")
        let loaded = try XCTUnwrap(store.load(bookID: book.id))
        XCTAssertFalse(loaded.attachment.source.hasExtractedText)
        XCTAssertEqual(try Data(contentsOf: loaded.url), data)
        XCTAssertTrue(book.chapters.flatMap { $0.activeRevision?.blocks ?? [] }.contains { $0.text.contains("not text from the author") })
        XCTAssertEqual(ai.totalCallCount, 0)
    }

    @MainActor
    func testLibraryOpenInPathPreservesPDFAndReportsIndependentPagePosition() async throws {
        let data = syntheticPDF()
        let input = root.appendingPathComponent("open-in.pdf")
        try data.write(to: input)
        let model = LibraryViewModel(rootDirectory: root)
        await model.load()
        try await model.importCanonFile(at: input)
        let bookID = try XCTUnwrap(model.pendingOpenBookID)
        let original = try XCTUnwrap(store.load(bookID: bookID))
        XCTAssertEqual(try Data(contentsOf: original.url), data)
        try store.savePosition(bookID: bookID, sourceSHA256: original.attachment.source.sha256, pageIndex: 1)
        await model.refreshProgress()
        XCTAssertEqual(model.chapterLabelByBookId[bookID], "PDF page 2 of 3")
        XCTAssertEqual(model.progressByBookId[bookID] ?? -1, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertTrue(model.originalPageBookIDs.contains(bookID))
        XCTAssertNil(try model.checkpoints?.loadCheckpoint(bookId: bookID))
    }

    private func makeWizard() throws -> (CreateBookWizardService, ManuscriptVersioningService, FileCreateBookDraftStore, MockAIService) {
        let packets = try FilePEPacketStore(rootDirectory: root)
        let versioning = try ManuscriptVersioningService(rootDirectory: root, packets: packets)
        let drafts = try FileCreateBookDraftStore(rootDirectory: root)
        let ai = MockAIService()
        return (CreateBookWizardService(versioning: versioning,
            preferenceStore: try FileReaderPreferenceStore(rootDirectory: root), packets: packets,
            drafts: drafts, ai: ai), versioning, drafts, ai)
    }

    /// Authored synthetic pages only: a simple table/diagram and an optional text layer.
    private func syntheticPDF(pageCount: Int = 3, includeText: Bool = true) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400)).pdfData { context in
            for index in 0..<pageCount {
                context.beginPage()
                let cg = context.cgContext
                cg.setStrokeColor(UIColor.blue.cgColor)
                cg.stroke(CGRect(x: 20, y: 100, width: 240, height: 120))
                cg.move(to: CGPoint(x: 140, y: 100)); cg.addLine(to: CGPoint(x: 140, y: 220))
                cg.move(to: CGPoint(x: 20, y: 160)); cg.addLine(to: CGPoint(x: 260, y: 160)); cg.strokePath()
                if includeText {
                    ("Synthetic source page \(index + 1). This text and the drawn table are original test material." as NSString)
                        .draw(in: CGRect(x: 20, y: 20, width: 260, height: 70),
                              withAttributes: [.font: UIFont.systemFont(ofSize: 12)])
                }
            }
        }
    }
}
