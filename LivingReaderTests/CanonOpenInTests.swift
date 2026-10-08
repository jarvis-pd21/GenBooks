import XCTest
@testable import LivingReader

/// RDR-944 — Files / Share Open in GenBooks. Host URL + ingest are testable;
/// the system Share sheet / extension process is not (see UX_CLICK_PATH).
final class CanonOpenInTests: XCTestCase {
    func testIncomingFileURLClassifiesAsFile() {
        let url = URL(fileURLWithPath: "/tmp/PlazaEvening.epub")
        XCTAssertEqual(IncomingCanonURL.parse(url), .file(url))
    }

    func testIncomingShareSchemeOpensInbox() {
        XCTAssertEqual(IncomingCanonURL.parse(URL(string: "genbooks://import")!), .shareInbox)
        XCTAssertEqual(IncomingCanonURL.parse(URL(string: "genbooks://import/")!), .shareInbox)
        XCTAssertEqual(IncomingCanonURL.parse(URL(string: "GENBOOKS://Import")!), .shareInbox)
    }

    func testIncomingUnknownSchemeIsUnsupported() {
        XCTAssertEqual(IncomingCanonURL.parse(URL(string: "https://example.com/book.epub")!), .unsupported)
        XCTAssertEqual(IncomingCanonURL.parse(URL(string: "livingreader://import")!), .unsupported)
    }

    func testPrepareFriendCanonEPUBIsVerbatimCanon() throws {
        let url = try BundleFixtureLoader.urlForFriendCanonEPUB()
        let prepared = try CanonFileIngest.prepare(from: url)
        XCTAssertEqual(prepared.sourceKind, .epubExtract)
        XCTAssertEqual(prepared.title, "Plaza Evening")
        XCTAssertTrue(prepared.plainText.contains("The plaza kept the river's last light on the stones."))
        XCTAssertFalse(prepared.plainText.contains("<p>"))

        let book = try ManuscriptImporter.importPlainText(
            text: prepared.plainText,
            title: prepared.title,
            author: prepared.author,
            sourceKind: prepared.sourceKind
        )
        XCTAssertTrue(book.isCanonImport)
        XCTAssertEqual(book.edition?.label, "Canon")
        XCTAssertEqual(book.subtitle, "Canon · EPUB")
        XCTAssertEqual(book.chapters.count, 2)
    }

    func testEPUBReferencesDecodeOnceThroughMetadataHeadingsAndCanonicalText() throws {
        let heading = "Reader&#x2019;s &#X1F642; &amp;gt; &lt;limit&gt;"
        let paragraph = "It&#39;s the reader&#x2019;s example: &#x1F642; &amp;gt; &amp;#x2019; &quot;yes&quot; &apos;no&apos;."
        let prepared = try CanonFileIngest.prepare(
            data: fidelityEPUB(title: "Symbols &amp;gt; &#x1F642;", author: "O&#x2019;Brien",
                body: "<h1>\(heading)</h1><p>\(paragraph)</p>"), filename: "symbols.epub")
        XCTAssertEqual(prepared.title, "Symbols &gt; 🙂")
        XCTAssertEqual(prepared.author, "O’Brien")
        let book = try ManuscriptImporter.importPlainText(text: prepared.plainText,
            title: prepared.title, author: prepared.author, sourceKind: prepared.sourceKind)
        XCTAssertEqual(book.chapters.map(\.title), ["Reader’s 🙂 &gt; <limit>"])
        let blocks = try XCTUnwrap(book.chapters.first?.activeRevision).blocks
        XCTAssertTrue(blocks.contains { $0.text == "It's the reader’s example: 🙂 &gt; &#x2019; \"yes\" 'no'." })
    }

    func testEPUBLeadingComparisonSymbolsSurviveCanonicalSaveWithoutQuoteDecoration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanonSymbols-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let packets = try FilePEPacketStore(rootDirectory: root)
        let versioning = try ManuscriptVersioningService(rootDirectory: root, packets: packets)
        let ai = MockAIService()
        let wizard = CreateBookWizardService(versioning: versioning,
            preferenceStore: try FileReaderPreferenceStore(rootDirectory: root), packets: packets,
            drafts: try FileCreateBookDraftStore(rootDirectory: root), ai: ai)
        let prose = "The following symbols are source material and must remain exactly as written in this reading edition."
        let prepared = try CanonFileIngest.prepare(data: fidelityEPUB(
            body: "<h1>Comparisons</h1><p>\(prose)</p><p>&gt; 5</p><p>&gt;</p><p>&gt;&gt; literal text</p>"),
            filename: "comparisons.epub")
        var draft = CreateBookDraft.blank()
        draft.title = prepared.title ?? ""
        draft.author = prepared.author ?? ""
        draft.importedText = prepared.plainText
        draft.importSourceKind = prepared.sourceKind
        let saved = try await wizard.importAndSave(draft: draft)
        let loadedValue = try await versioning.loadBook(id: saved.id)
        let loaded = try XCTUnwrap(loadedValue)
        let blocks = try XCTUnwrap(loaded.chapters.first?.activeRevision).blocks
        XCTAssertEqual(blocks.map(\.text), ["Comparisons", prose, "> 5", ">", ">> literal text"])
        XCTAssertFalse(blocks.contains { $0.kind == .quote }, "The reader adds quotation marks to quote blocks")
        XCTAssertFalse(blocks.contains { $0.text.isEmpty })
        XCTAssertEqual(ai.totalCallCount, 0)
    }

    func testEPUBInvalidNumericReferencesArePreservedRatherThanDeleted() throws {
        let literal = "Invalid &#xD800; and &#x110000; and &#999999999999999999999; remain visible."
        let prepared = try CanonFileIngest.prepare(data: fidelityEPUB(body: "<h1>References</h1><p>\(literal)</p>"),
            filename: "references.epub")
        XCTAssertTrue(prepared.plainText.contains(literal))
        let book = try ManuscriptImporter.importPlainText(text: prepared.plainText,
            title: prepared.title, author: prepared.author, sourceKind: prepared.sourceKind)
        XCTAssertTrue(book.chapters.flatMap { $0.activeRevision?.blocks ?? [] }.contains { $0.text == literal })
    }

    private func fidelityEPUB(title: String = "Symbols", author: String = "Test Author", body: String) -> Data {
        TestStoreZip.make([
            "mimetype": Data("application/epub+zip".utf8),
            "META-INF/container.xml": Data(#"<container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>"#.utf8),
            "OEBPS/content.opf": Data("""
                <package xmlns:dc="http://purl.org/dc/elements/1.1/">
                <metadata><dc:title>\(title)</dc:title><dc:creator>\(author)</dc:creator></metadata>
                <manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest>
                <spine><itemref idref="chapter"/></spine></package>
                """.utf8),
            "OEBPS/chapter.xhtml": Data("<html><body>\(body)</body></html>".utf8)
        ])
    }

    func testEncryptedEPUBFailsClosedWithoutExtractingText() throws {
        let zip = TestStoreZip.make([
            "mimetype": Data("application/epub+zip".utf8),
            "META-INF/container.xml": Data("<container><rootfile full-path=\"OEBPS/content.opf\"/></container>".utf8),
            "META-INF/encryption.xml": Data("<encryption xmlns=\"http://www.w3.org/2001/04/xmlenc#\"/>".utf8),
            "OEBPS/content.opf": Data("<package><metadata><dc:title>Secret</dc:title></metadata></package>".utf8)
        ])
        XCTAssertThrowsError(try CanonFileIngest.prepare(data: zip, filename: "locked.epub")) { error in
            XCTAssertEqual(error as? CreateBookError, .drmProtected)
        }
        XCTAssertThrowsError(try EPUBTextExtractor.extract(from: zip)) { error in
            XCTAssertEqual(error as? CreateBookError, .drmProtected)
        }
    }

    func testFairPlaySinfEPUBFailsClosed() throws {
        let zip = TestStoreZip.make([
            "mimetype": Data("application/epub+zip".utf8),
            "META-INF/sinf.xml": Data("<sinf>FairPlay</sinf>".utf8)
        ])
        XCTAssertThrowsError(try EPUBTextExtractor.extract(from: zip)) { error in
            XCTAssertEqual(error as? CreateBookError, .drmProtected)
        }
    }

    func testEncryptedPDFMarkerFailsClosed() throws {
        let pdf = Data("%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Encrypt 2 0 R >>\nendobj\ntrailer\n<< /Encrypt 2 0 R >>\n%%EOF\n".utf8)
        XCTAssertThrowsError(try CanonFileIngest.prepare(data: pdf, filename: "locked.pdf")) { error in
            XCTAssertEqual(error as? CreateBookError, .drmProtected)
        }
        XCTAssertThrowsError(try CanonFileIngest.assertPDFNotEncrypted(pdf)) { error in
            XCTAssertEqual(error as? CreateBookError, .drmProtected)
        }
    }

    func testUnsupportedTypeFailsClosed() {
        let data = Data("just a note".utf8)
        XCTAssertThrowsError(try CanonFileIngest.prepare(data: data, filename: "note.txt")) { error in
            XCTAssertEqual(error as? CreateBookError, .unsupportedImportType)
        }
    }

    func testShareInboxWriteThenTakeHandsOffFilename() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanonInbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }

        let bytes = Data("PK-placeholder".utf8)
        try CanonShareInbox.write(data: bytes, filename: "Plaza Evening.epub", container: container)
        let taken = try CanonShareInbox.take(container: container)
        XCTAssertEqual(taken?.filename, "Plaza Evening.epub")
        XCTAssertEqual(try Data(contentsOf: taken!.url), bytes)
        XCTAssertNil(try CanonShareInbox.take(container: container), "Inbox must be empty after take")
    }

    func testShareExtensionMetaJSONStillYieldsFilename() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanonInboxExt-\(UUID().uuidString)", isDirectory: true)
        let folder = container.appendingPathComponent(CanonShareInbox.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        try Data("epub-bytes".utf8).write(to: folder.appendingPathComponent(CanonShareInbox.payloadFileName))
        try JSONSerialization.data(withJSONObject: ["filename": "from-files.epub"])
            .write(to: folder.appendingPathComponent(CanonShareInbox.metaFileName))
        let taken = try CanonShareInbox.take(container: container)
        XCTAssertEqual(taken?.filename, "from-files.epub")
    }

    func testOpenURLIngestSavesCanonWithoutAI() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanonOpenIn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let packets = try FilePEPacketStore(rootDirectory: root)
        let versioning = try ManuscriptVersioningService(rootDirectory: root, packets: packets)
        let drafts = try FileCreateBookDraftStore(rootDirectory: root)
        let prefs = try FileReaderPreferenceStore(rootDirectory: root)
        let ai = MockAIService()
        let wizard = CreateBookWizardService(
            versioning: versioning,
            preferenceStore: prefs,
            packets: packets,
            drafts: drafts,
            ai: ai
        )

        let prepared = try CanonFileIngest.prepare(from: try BundleFixtureLoader.urlForFriendCanonEPUB())
        var draft = CreateBookDraft.blank()
        draft.title = prepared.title ?? ""
        draft.author = prepared.author ?? ""
        draft.importedText = prepared.plainText
        draft.importSourceKind = prepared.sourceKind
        let book = try await wizard.importAndSave(draft: draft)
        XCTAssertEqual(book.title, "Plaza Evening")
        XCTAssertTrue(book.isCanonImport)
        XCTAssertEqual(ai.totalCallCount, 0)
        let loaded = try await versioning.loadBook(id: book.id)
        XCTAssertNotNil(loaded)
    }
}

/// Minimal STORE zip so DRM fixtures do not need a checked-in encrypted book.
private enum TestStoreZip {
    static func make(_ files: [String: Data]) -> Data {
        var locals = Data()
        var central = Data()
        for (name, payload) in files.sorted(by: { $0.key < $1.key }) {
            let nameData = Data(name.utf8)
            let crc = crc32(payload)
            let localOffset = UInt32(locals.count)
            locals.append(contentsOf: u32(0x0403_4b50))
            locals.append(contentsOf: u16(20))
            locals.append(contentsOf: u16(0))
            locals.append(contentsOf: u16(0))
            locals.append(contentsOf: u16(0))
            locals.append(contentsOf: u16(0))
            locals.append(contentsOf: u32(crc))
            locals.append(contentsOf: u32(UInt32(payload.count)))
            locals.append(contentsOf: u32(UInt32(payload.count)))
            locals.append(contentsOf: u16(UInt16(nameData.count)))
            locals.append(contentsOf: u16(0))
            locals.append(nameData)
            locals.append(payload)

            central.append(contentsOf: u32(0x0201_4b50))
            central.append(contentsOf: u16(20))
            central.append(contentsOf: u16(20))
            central.append(contentsOf: u16(0))
            central.append(contentsOf: u16(0))
            central.append(contentsOf: u16(0))
            central.append(contentsOf: u16(0))
            central.append(contentsOf: u32(crc))
            central.append(contentsOf: u32(UInt32(payload.count)))
            central.append(contentsOf: u32(UInt32(payload.count)))
            central.append(contentsOf: u16(UInt16(nameData.count)))
            central.append(contentsOf: u16(0))
            central.append(contentsOf: u16(0))
            central.append(contentsOf: u16(0))
            central.append(contentsOf: u16(0))
            central.append(contentsOf: u32(0))
            central.append(contentsOf: u32(localOffset))
            central.append(nameData)
        }
        let cdOffset = UInt32(locals.count)
        let cdSize = UInt32(central.count)
        var eocd = Data()
        eocd.append(contentsOf: u32(0x0605_4b50))
        eocd.append(contentsOf: u16(0))
        eocd.append(contentsOf: u16(0))
        eocd.append(contentsOf: u16(UInt16(files.count)))
        eocd.append(contentsOf: u16(UInt16(files.count)))
        eocd.append(contentsOf: u32(cdSize))
        eocd.append(contentsOf: u32(cdOffset))
        eocd.append(contentsOf: u16(0))
        var out = locals
        out.append(central)
        out.append(eocd)
        return out
    }

    private static func u16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }

    private static func u32(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ]
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ 0xEDB8_8320
                } else {
                    crc >>= 1
                }
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
